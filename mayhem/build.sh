#!/usr/bin/env bash
#
# openjph/mayhem/build.sh — build aous72/OpenJPH's two OSS-Fuzz harnesses as sanitized libFuzzer
# targets (+ standalone reproducers), AND a small self-contained encode->decode->compare oracle
# for mayhem/test.sh.
#
# Fuzzed surface (the OpenJPH HTJ2K / JPEG2000 codec on attacker-controlled bytes):
#   ojph_expand_fuzz_target   — DECODE path. Input = 2 decoder-control bytes + a raw J2K/HTJ2K
#                               codestream; drives ojph::codestream read_headers/create/pull
#                               (with resilience enabled). This is the real image-parser surface.
#   ojph_compress_fuzz_target — ENCODE path. Input = 4 config bytes + raw pixel samples; drives
#                               codestream write_headers/exchange/flush. NOT a codestream parser.
#
# Build contract comes from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/
# STANDALONE_FUZZ_MAIN). We compile the OpenJPH library ITSELF with $SANITIZER_FLAGS (via
# CMAKE_*_FLAGS) so the codec code — not just the harness — is instrumented.
#
# SIMD: OpenJPH does RUNTIME SIMD dispatch (it probes the CPU and picks SSE/AVX/AVX2/AVX512 paths
# at run time; it does NOT compile with -march=native). We therefore keep the default baseline
# x86-64 flags and do not add -march — the library's own per-feature object files stay portable.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
# DEBUG_FLAGS: explicit DWARF < 4 so Mayhem triage can read symbols (clang-19 defaults to DWARF-5).
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

OUT="/mayhem"
FUZZ_SRC="$SRC/fuzzing/fuzz_targets"
INC="-I$SRC/src/core/openjph"

# ── 1) Build the OpenJPH static library + OSS-Fuzz fuzzers WITH sanitizers via CMake ──────────────
# This is the proven OSS-Fuzz recipe: -DOJPH_BUILD_FUZZER=ON adds fuzzing/, and the fuzzing
# CMakeLists links $LIB_FUZZING_ENGINE when it is set in the environment (libFuzzer main). We pass
# the sanitizer flags through CMAKE_{C,CXX}_FLAGS so the codec is instrumented. Static lib, no TIFF
# (the fuzzers and the oracle use the codec API directly, not the TIFF file I/O).
#
# COVERAGE: the org base ENV only ships ASan+UBSan in SANITIZER_FLAGS — NO SanitizerCoverage. The
# codec lib must be coverage-instrumented or libFuzzer/Mayhem sees zero edges inside OpenJPH (only
# the harness). Add -fsanitize=fuzzer-no-link to the COMPILE flags of every object so the whole
# codec is edge-instrumented; the harness link still pulls the full -fsanitize=fuzzer engine. Only
# do this when sanitizers are on (an empty SANITIZER_FLAGS = an explicit no-sanitizer build).
COV_FLAG=""
case "$SANITIZER_FLAGS" in *fsanitize=*) COV_FLAG="-fsanitize=fuzzer-no-link" ;; esac
BUILD="$SRC/mayhem-build"
rm -rf "$BUILD"; mkdir -p "$BUILD"
LIB_FUZZING_ENGINE="$LIB_FUZZING_ENGINE" \
  cmake -S "$SRC" -B "$BUILD" \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DOJPH_BUILD_FUZZER=ON \
    -DOJPH_BUILD_TESTS=OFF \
    -DOJPH_BUILD_EXECUTABLES=OFF \
    -DOJPH_ENABLE_TIFF_SUPPORT=OFF \
    -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $COV_FLAG $DEBUG_FLAGS" \
    -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $COV_FLAG $DEBUG_FLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS" \
    -DCMAKE_SHARED_LINKER_FLAGS="$SANITIZER_FLAGS"
cmake --build "$BUILD" -j"$MAYHEM_JOBS" \
  --target ojph_expand_fuzz_target ojph_compress_fuzz_target

# Locate + place the libFuzzer targets at /mayhem/<name>.
for h in ojph_expand_fuzz_target ojph_compress_fuzz_target; do
  bin="$(find "$BUILD" -type f -name "$h" -perm -u+x | head -1)"
  [ -n "$bin" ] || { echo "ERROR: built fuzzer $h not found under $BUILD" >&2; exit 1; }
  cp "$bin" "$OUT/$h"
  echo "placed $OUT/$h"
done

# ── 2) Build the standalone reproducers ───────────────────────────────────────────────────────────
# Both harnesses ship their own run-once main() under -DOJPH_FUZZ_TARGET_MAIN. Recompile the harness
# .cpp with that define against the sanitized static OpenJPH lib (no libFuzzer runtime). Find the
# archive CMake produced.
LIBOJPH="$(find "$BUILD" -name 'libopenjph*.a' | head -1)"
[ -n "$LIBOJPH" ] || { echo "ERROR: libopenjph*.a not found under $BUILD" >&2; exit 1; }
echo "using static lib $LIBOJPH"

for h in ojph_expand_fuzz_target ojph_compress_fuzz_target; do
  $CXX -std=c++14 $SANITIZER_FLAGS $DEBUG_FLAGS -DOJPH_FUZZ_TARGET_MAIN $INC \
      "$FUZZ_SRC/$h.cpp" "$LIBOJPH" -lm \
      -o "$OUT/$h-standalone"
  echo "built $OUT/$h-standalone"
done

# ── 3) Build the functional oracle (mayhem/test.sh runs it) ──────────────────────────────────────
# OpenJPH's own gtest suite (tests/) shells out to ojph_compress/ojph_expand over EXTERNAL reference
# images fetched from the aous72/jp2k_test_codestreams repo at configure time (FetchContent) and
# also FetchContent's googletest — i.e. it needs network + large external data. To keep test.sh a
# hermetic, self-contained PATCH oracle we instead build a small golden encode->decode->compare
# program (mayhem/oracle.cpp) that exercises the real codec round-trip against an in-memory
# synthetic image. See mayhem/test.sh for the verdict logic.
#
# The oracle uses NORMAL flags (no sanitizers) so test.sh stays an honest functional oracle without
# ASan/UBSan noise. The sanitized libopenjph.a above is instrumented, so we build a SEPARATE clean
# (un-instrumented) OpenJPH static lib in its own tree and link the oracle against THAT.
BUILD_CLEAN="$SRC/mayhem-tests"
rm -rf "$BUILD_CLEAN"; mkdir -p "$BUILD_CLEAN"
env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
  cmake -S "$SRC" -B "$BUILD_CLEAN" \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DOJPH_BUILD_FUZZER=OFF \
    -DOJPH_BUILD_TESTS=OFF \
    -DOJPH_BUILD_EXECUTABLES=OFF \
    -DOJPH_ENABLE_TIFF_SUPPORT=OFF
env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
  cmake --build "$BUILD_CLEAN" -j"$MAYHEM_JOBS" --target openjph
LIBOJPH_CLEAN="$(find "$BUILD_CLEAN" -name 'libopenjph*.a' | head -1)"
[ -n "$LIBOJPH_CLEAN" ] || { echo "ERROR: clean libopenjph*.a not found under $BUILD_CLEAN" >&2; exit 1; }
env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
  $CXX -std=c++14 -O1 -g $INC \
    "$SRC/mayhem/oracle.cpp" "$LIBOJPH_CLEAN" -lm \
    -o "$OUT/ojph_oracle"
echo "built $OUT/ojph_oracle"

echo "build.sh complete:"
ls -la "$OUT/ojph_expand_fuzz_target" "$OUT/ojph_compress_fuzz_target" \
       "$OUT/ojph_expand_fuzz_target-standalone" "$OUT/ojph_compress_fuzz_target-standalone" \
       "$OUT/ojph_oracle" 2>&1 || true
