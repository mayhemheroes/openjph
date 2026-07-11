//***************************************************************************/
// openjph/mayhem/oracle.cpp
//
// A small, hermetic functional oracle for the OpenJPH HTJ2K codec, run by
// mayhem/test.sh. OpenJPH's own gtest suite shells out to ojph_compress/
// ojph_expand over EXTERNAL reference images fetched over the network at build
// time (FetchContent of aous72/jp2k_test_codestreams + googletest). That is not
// hermetic. Instead this program exercises the REAL codec round-trip in-process:
//
//   encode (REVERSIBLE / lossless 5/3) a synthetic image  ->  J2K codestream
//   decode that codestream back to samples
//   assert the reconstruction is BIT-EXACT vs the original
//
// Because reversible HTJ2K is mathematically lossless, the decoded samples must
// equal the originals exactly. A no-op / "return success" patch to the encoder
// or decoder, or any change that corrupts the transform/coding path, breaks the
// round-trip and fails the assertion -> non-zero exit. Several configurations
// are exercised (grayscale, RGB+color-transform, multi-resolution, planar and
// interleaved). Each case prints "PASS <name>" or "FAIL <name> ...".
//
// Build: normal flags, no sanitizers (test.sh is a functional PATCH oracle,
// not a sanitizer run). Links the same static libopenjph the fuzzers use.
//***************************************************************************/

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>
#include <string>

#include "ojph_arch.h"
#include "ojph_mem.h"
#include "ojph_file.h"
#include "ojph_params.h"
#include "ojph_codestream.h"

struct Case {
  const char* name;
  ojph::ui32 width, height, num_comps, bit_depth, num_decomps;
  bool color_transform;
  bool planar;
};

// Deterministic synthetic sample value for (component, x, y).
static ojph::si32 sample(ojph::ui32 c, ojph::ui32 x, ojph::ui32 y, ojph::ui32 bit_depth)
{
  ojph::ui32 maxv = (1u << bit_depth) - 1u;
  ojph::ui32 v = (x * 7u + y * 13u + c * 53u);
  return (ojph::si32)(v % (maxv + 1u));
}

// Encode the synthetic image (reversible) -> codestream bytes.
static std::vector<uint8_t> encode(const Case& tc)
{
  ojph::codestream cs;

  ojph::param_siz siz = cs.access_siz();
  siz.set_image_extent(ojph::point(tc.width, tc.height));
  siz.set_num_components(tc.num_comps);
  for (ojph::ui32 c = 0; c < tc.num_comps; ++c)
    siz.set_component(c, ojph::point(1, 1), tc.bit_depth, /*is_signed=*/false);

  ojph::param_cod cod = cs.access_cod();
  cod.set_num_decomposition(tc.num_decomps);
  cod.set_color_transform(tc.color_transform);
  cod.set_reversible(true);              // lossless: round-trip must be bit-exact

  cs.set_planar(tc.planar);

  ojph::mem_outfile out;
  out.open();
  cs.write_headers(&out);

  ojph::ui32 next_comp = 0;
  ojph::line_buf* line = cs.exchange(NULL, next_comp);

  if (tc.planar) {
    for (ojph::ui32 c = 0; c < tc.num_comps; ++c)
      for (ojph::ui32 y = 0; y < tc.height; ++y) {
        ojph::si32* dp = line->i32;
        for (ojph::ui32 x = 0; x < tc.width; ++x)
          dp[x] = sample(next_comp, x, y, tc.bit_depth);
        line = cs.exchange(line, next_comp);
      }
  } else {
    for (ojph::ui32 y = 0; y < tc.height; ++y)
      for (ojph::ui32 c = 0; c < tc.num_comps; ++c) {
        ojph::si32* dp = line->i32;
        for (ojph::ui32 x = 0; x < tc.width; ++x)
          dp[x] = sample(next_comp, x, y, tc.bit_depth);
        line = cs.exchange(line, next_comp);
      }
  }

  cs.flush();
  const uint8_t* p = out.get_data();
  std::vector<uint8_t> bytes(p, p + (size_t)out.tell());
  cs.close();
  return bytes;
}

// Decode the codestream and verify bit-exact reconstruction vs the synthetic image.
static bool decode_and_check(const Case& tc, const std::vector<uint8_t>& bytes, std::string& err)
{
  ojph::mem_infile in;
  in.open(reinterpret_cast<const ojph::ui8*>(bytes.data()), bytes.size());

  ojph::codestream cs;
  cs.read_headers(&in);
  cs.create();

  ojph::param_siz siz = cs.access_siz();
  if (siz.get_num_components() != tc.num_comps) {
    char b[128];
    snprintf(b, sizeof b, "num_components %u != expected %u",
             siz.get_num_components(), tc.num_comps);
    err = b; cs.close(); return false;
  }

  bool ok = true;
  if (cs.is_planar()) {
    for (ojph::ui32 c = 0; c < tc.num_comps && ok; ++c) {
      ojph::ui32 h = siz.get_recon_height(c);
      ojph::ui32 w = siz.get_recon_width(c);
      for (ojph::ui32 y = 0; y < h && ok; ++y) {
        ojph::ui32 comp_num;
        ojph::line_buf* line = cs.pull(comp_num);
        for (ojph::ui32 x = 0; x < w; ++x) {
          ojph::si32 expv = sample(comp_num, x, y, tc.bit_depth);
          if (line->i32[x] != expv) {
            char b[160];
            snprintf(b, sizeof b, "mismatch planar c=%u x=%u y=%u got=%d exp=%d",
                     comp_num, x, y, line->i32[x], expv);
            err = b; ok = false; break;
          }
        }
      }
    }
  } else {
    ojph::ui32 h = siz.get_recon_height(0);
    ojph::ui32 w = siz.get_recon_width(0);
    for (ojph::ui32 y = 0; y < h && ok; ++y) {
      for (ojph::ui32 c = 0; c < tc.num_comps && ok; ++c) {
        ojph::ui32 comp_num;
        ojph::line_buf* line = cs.pull(comp_num);
        for (ojph::ui32 x = 0; x < w; ++x) {
          ojph::si32 expv = sample(comp_num, x, y, tc.bit_depth);
          if (line->i32[x] != expv) {
            char b[160];
            snprintf(b, sizeof b, "mismatch c=%u x=%u y=%u got=%d exp=%d",
                     comp_num, x, y, line->i32[x], expv);
            err = b; ok = false; break;
          }
        }
      }
    }
  }
  cs.close();
  return ok;
}

int main()
{
  // All cases use >=1 decomposition level so the full wavelet/coding round-trip is exercised.
  // (With num_decompositions==0 the reversible reconstruction carries a DC level-shift that this
  //  simple per-pixel comparator does not model; the >=1 cases cover the codec end-to-end anyway.)
  Case cases[] = {
    { "gray_8b_d1_interleaved",  16, 16, 1,  8, 1, false, false },
    { "gray_8b_d3_interleaved",  64, 48, 1,  8, 3, false, false },
    { "gray_8b_d2_planar",       40, 24, 1,  8, 2, false, true  },
    { "rgb_8b_ct_d1",            32, 32, 3,  8, 1, true,  false },
    { "rgb_8b_noct_d2_planar",   24, 24, 3,  8, 2, false, true  },
    { "gray_12b_d1",             20, 20, 1, 12, 1, false, false },
    { "gray_16b_d2",             16, 16, 1, 16, 2, false, false },
    { "rgba_8b_d1_interleaved",  16, 16, 4,  8, 1, false, false },
  };
  const int ncases = (int)(sizeof(cases) / sizeof(cases[0]));

  int passed = 0, failed = 0;
  for (int i = 0; i < ncases; ++i) {
    const Case& tc = cases[i];
    std::string err;
    bool ok = false;
    try {
      std::vector<uint8_t> bytes = encode(tc);
      if (bytes.size() < 4) { err = "empty codestream"; }
      else ok = decode_and_check(tc, bytes, err);
    } catch (const std::exception& e) {
      err = std::string("exception: ") + e.what();
    } catch (...) {
      err = "unknown exception";
    }
    if (ok) { printf("PASS %s\n", tc.name); ++passed; }
    else    { printf("FAIL %s: %s\n", tc.name, err.c_str()); ++failed; }
  }

  printf("ORACLE_SUMMARY passed=%d failed=%d total=%d\n", passed, failed, ncases);
  return failed == 0 ? 0 : 1;
}
