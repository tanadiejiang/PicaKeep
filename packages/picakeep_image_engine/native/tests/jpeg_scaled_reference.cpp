// Independent full-scanline reference for the vendored JPEG IDCT. This test
// tool never calls the application's region/crop/backing implementation.
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>
#include "jpeglib.h"

// The vendored codec's memory adapter normally calls the app's budget hooks.
// This independent baseline-only test decoder uses its own allocator, never
// enters the app's decoder, and refuses coefficient spill files entirely.
extern "C" void *pki_codec_alloc(size_t bytes) { return std::malloc(bytes); }
extern "C" void pki_codec_free(void *pointer) { std::free(pointer); }
extern "C" FILE *pki_coeff_file(long) { return nullptr; }
extern "C" void pki_coeff_closed(FILE *file) { if (file) std::fclose(file); }
extern "C" void pki_codec_io_check(void) {}

int main(int argc, char **argv) {
  if (argc != 4) return 1;
  const auto denominator = std::strtoul(argv[2], nullptr, 10);
  if (denominator != 1 && denominator != 2 && denominator != 4 && denominator != 8)
    return 1;
  FILE *input = std::fopen(argv[1], "rb");
  if (!input) return 1;
  jpeg_decompress_struct codec{};
  jpeg_error_mgr error{};
  codec.err = jpeg_std_error(&error);
  jpeg_create_decompress(&codec);
  jpeg_stdio_src(&codec, input);
  jpeg_read_header(&codec, TRUE);
  if (codec.progressive_mode) {
    jpeg_destroy_decompress(&codec);
    std::fclose(input);
    return 1;
  }
  codec.out_color_space = JCS_EXT_RGBA;
  codec.scale_num = 1;
  codec.scale_denom = static_cast<unsigned int>(denominator);
  jpeg_start_decompress(&codec);
  if (codec.output_width > 4096 || codec.output_height > 4096 ||
      uint64_t(codec.output_width) * codec.output_height * 4 > (16ULL << 20)) {
    jpeg_abort_decompress(&codec);
    jpeg_destroy_decompress(&codec);
    std::fclose(input);
    return 3;
  }
  FILE *output = std::fopen(argv[3], "wb");
  if (!output) return 1;
  std::vector<uint8_t> row(uint64_t(codec.output_width) * 4);
  while (codec.output_scanline < codec.output_height) {
    JSAMPROW scanline = row.data();
    jpeg_read_scanlines(&codec, &scanline, 1);
    if (std::fwrite(row.data(), 1, row.size(), output) != row.size()) return 3;
  }
  jpeg_finish_decompress(&codec);
  std::printf("%u %u\n", codec.output_width, codec.output_height);
  jpeg_destroy_decompress(&codec);
  std::fclose(input);
  return std::fclose(output) == 0 ? 0 : 3;
}
