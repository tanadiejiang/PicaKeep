#include "picakeep_image_engine.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <limits>
#include <memory>
#include <mutex>
#include <shared_mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>
#include "jpeglib.h"
#include "jerror.h"
#include "png.h"
#include "webp/decode.h"
#include "webp/encode.h"
#include "src/utils/rescaler_utils.h"
#include "lcms2.h"
#include "lcms2_plugin.h"
#ifdef _WIN32
#include <windows.h>
#else
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#endif

namespace {
constexpr uint64_t kMetadataLimit = 8 * 1024 * 1024;
constexpr uint64_t kRawHeaderSize = 128;
struct Failure : std::runtime_error {
  Failure(int code, const std::string &message) : std::runtime_error(message), code(code) {}
  int code;
};
struct Budget {
  uint64_t limit, disk_limit, used = 0, peak = 0, disk = 0;
  std::atomic<bool> *cancel;
  std::string backing;
  bool denied = false;
  bool cancelled = false;
  uint64_t next_coefficient = 0;
  std::unordered_map<FILE *, std::string> coefficients;
  explicit Budget(uint64_t memory, uint64_t storage, void *token, std::string path)
    : limit(memory), disk_limit(storage), cancel(static_cast<std::atomic<bool> *>(token)), backing(std::move(path)) {}
  void check() const {
    if (cancel && cancel->load(std::memory_order_relaxed)) throw Failure(2, "Image decoding cancelled");
  }
  void reserve(uint64_t bytes) {
    check();
    if (bytes > limit || used > limit - bytes) {
      denied = true;
      throw Failure(3, "Codec memory budget exhausted");
    }
    used += bytes; peak = std::max(peak, used);
  }
  void reserve_disk(uint64_t bytes) {
    check();
    if (bytes > disk_limit || disk > disk_limit - bytes)
      throw Failure(3, "Image backing storage budget exhausted");
    disk += bytes;
  }
  ~Budget() {
    for (const auto &file : coefficients) {
      fclose(file.first);
      std::error_code ignored;
      std::filesystem::remove(std::filesystem::u8path(file.second), ignored);
    }
  }
};
thread_local Budget *active_budget = nullptr;
struct Allocation { uint64_t bytes; Budget *owner; };
struct ActiveBudget {
  explicit ActiveBudget(Budget *value) : previous(active_budget) { active_budget = value; }
  ~ActiveBudget() { active_budget = previous; }
  Budget *previous;
};
template <typename T> struct CodecAllocator {
  using value_type = T;
  CodecAllocator() = default;
  template <typename U> CodecAllocator(const CodecAllocator<U> &) {}
  T *allocate(size_t count) {
    if (count > std::numeric_limits<size_t>::max() / sizeof(T)) throw std::bad_alloc();
    auto *pointer = static_cast<T *>(pki_codec_alloc(count * sizeof(T)));
    if (!pointer) throw std::bad_alloc(); return pointer;
  }
  void deallocate(T *pointer, size_t) { pki_codec_free(pointer); }
  template <typename U> bool operator==(const CodecAllocator<U> &) const { return true; }
  template <typename U> bool operator!=(const CodecAllocator<U> &) const { return false; }
};
using ProfileBytes = std::vector<uint8_t, CodecAllocator<uint8_t>>;
struct File {
  FILE *value = nullptr;
  File() = default;
  File(const std::string &path, const char *mode) {
#ifdef _WIN32
    const auto wide = std::filesystem::u8path(path).wstring();
    std::wstring wide_mode;
    while (*mode) wide_mode.push_back(static_cast<wchar_t>(*mode++));
    value = _wfopen(wide.c_str(), wide_mode.c_str());
#else
    value = fopen(path.c_str(), mode);
#endif
    if (!value) throw Failure(1, "Unable to open image or backing file");
  }
  ~File() { if (value) fclose(value); }
  File(const File &) = delete;
  File &operator=(const File &) = delete;
};
void seek(FILE *file, uint64_t offset) {
#ifdef _WIN32
  if (_fseeki64(file, static_cast<int64_t>(offset), SEEK_SET) != 0)
#else
  if (fseeko(file, static_cast<off_t>(offset), SEEK_SET) != 0)
#endif
    throw Failure(1, "Image file seek failed");
}
void read_exact(FILE *file, void *data, size_t bytes) {
  if (fread(data, 1, bytes, file) != bytes) throw Failure(1, "Truncated image data");
}
void write_exact(FILE *file, const void *data, size_t bytes) {
  if (fwrite(data, 1, bytes, file) != bytes) throw Failure(3, "Image backing write failed");
}
uint32_t le32(const uint8_t *p) {
  return p[0] | (uint32_t(p[1]) << 8) | (uint32_t(p[2]) << 16) | (uint32_t(p[3]) << 24);
}
uint32_t be32(const uint8_t *p) {
  return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | p[3];
}
uint32_t tiff16(const uint8_t *p, bool little) {
  return little ? p[0] | (uint32_t(p[1]) << 8) : (uint32_t(p[0]) << 8) | p[1];
}
uint32_t tiff32(const uint8_t *p, bool little) { return little ? le32(p) : be32(p); }
uint32_t exif_orientation(const uint8_t *bytes, size_t size) {
  if (size >= 6 && memcmp(bytes, "Exif\0\0", 6) == 0) { bytes += 6; size -= 6; }
  if (size < 8 || (memcmp(bytes, "II", 2) != 0 && memcmp(bytes, "MM", 2) != 0)) return 1;
  bool little = bytes[0] == 'I';
  uint32_t offset = tiff32(bytes + 4, little);
  if (offset > size || size - offset < 2) return 1;
  uint32_t count = tiff16(bytes + offset, little);
  for (uint32_t i = 0; i < count; ++i) {
    uint64_t entry = uint64_t(offset) + 2 + uint64_t(i) * 12;
    if (entry > size || size - entry < 12) break;
    const uint8_t *p = bytes + entry;
    if (tiff16(p, little) == 0x112 && tiff16(p + 2, little) == 3 && tiff32(p + 4, little) == 1) {
      uint32_t value = tiff16(p + 8, little);
      return value >= 1 && value <= 8 ? value : 1;
    }
  }
  return 1;
}
struct Info {
  pki_metadata metadata{};
  ProfileBytes profile;
  bool progressive = false;
  bool lossless = false;
  bool interlaced = false;
};
struct JpegError {
  jpeg_error_mgr manager;
  char message[JMSG_LENGTH_MAX];
};
void jpeg_error(j_common_ptr pointer) {
  auto *error = reinterpret_cast<JpegError *>(pointer->err);
  pointer->err->format_message(pointer, error->message);
  throw Failure(active_budget && active_budget->cancelled ? 2 :
    active_budget && active_budget->denied ? 3 : 1, error->message);
}
void jpeg_quiet_output(j_common_ptr) {}
thread_local boolean (*jpeg_original_fill)(j_decompress_ptr) = nullptr;
boolean jpeg_checked_fill(j_decompress_ptr codec) {
  if (active_budget && active_budget->cancel &&
      active_budget->cancel->load(std::memory_order_relaxed)) {
    active_budget->cancelled = true;
    ERREXIT(codec, JERR_FILE_READ);
  }
  return jpeg_original_fill(codec);
}
void jpeg_checked_source(j_decompress_ptr codec, FILE *file) {
  jpeg_stdio_src(codec, file);
  jpeg_original_fill = codec->src->fill_input_buffer;
  codec->src->fill_input_buffer = jpeg_checked_fill;
}
bool has_baseline_jpeg_frame(const std::string &path, const Budget &budget) {
  // progressive_mode alone also accepts extended/lossless sequential JPEGs.
  // Only this new scaled-whole shortcut needs an actual SOF0. stdio buffers
  // these tiny marker reads; no encoded pixel data is read or aggregated.
  File input(path, "rb");
  if (fgetc(input.value) != 0xff || fgetc(input.value) != 0xd8) return false;
  uint64_t position = 2;
  while (position < kMetadataLimit) {
    budget.check();
    if (fgetc(input.value) != 0xff) return false;
    ++position;
    int marker;
    do { marker = fgetc(input.value); ++position; }
    while (marker == 0xff && position < kMetadataLimit);
    if (marker == EOF || position >= kMetadataLimit) return false;
    if (marker >= 0xc0 && marker <= 0xcf && marker != 0xc4 && marker != 0xc8 && marker != 0xcc)
      return marker == 0xc0;
    if (marker == 0xda || marker == 0xd9 || marker == 0xd8 ||
      marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) return false;
    int high = fgetc(input.value), low = fgetc(input.value);
    if (high == EOF || low == EOF) return false;
    uint64_t length = uint64_t(high) * 256 + uint64_t(low);
    if (length < 2 || length > kMetadataLimit - position) return false;
    position += length;
    seek(input.value, position);
  }
  return false;
}
void parse_jpeg(File &file, Info &info) {
  jpeg_decompress_struct codec{};
  JpegError error{};
  codec.err = jpeg_std_error(&error.manager);
  error.manager.error_exit = jpeg_error;
  error.manager.output_message = jpeg_quiet_output;
  try {
  jpeg_create_decompress(&codec);
  jpeg_checked_source(&codec, file.value);
  jpeg_save_markers(&codec, JPEG_APP0 + 1, 0xffff);
  jpeg_save_markers(&codec, JPEG_APP0 + 2, 0xffff);
  jpeg_read_header(&codec, TRUE);
  info.metadata.encoded_width = codec.image_width;
  info.metadata.encoded_height = codec.image_height;
  info.metadata.bit_depth = codec.data_precision;
  info.progressive = codec.progressive_mode != 0;
  std::array<ProfileBytes, 256> chunks;
  int expected = 0;
  uint64_t total = 0;
  for (jpeg_saved_marker_ptr marker = codec.marker_list; marker; marker = marker->next) {
    if (marker->marker == JPEG_APP0 + 1) {
      info.metadata.orientation = exif_orientation(marker->data, marker->data_length);
    } else if (marker->marker == JPEG_APP0 + 2 && marker->data_length > 14 &&
               memcmp(marker->data, "ICC_PROFILE\0", 12) == 0) {
      int sequence = marker->data[12], count = marker->data[13];
      total += marker->data_length - 14;
      if (total > kMetadataLimit || sequence == 0 || count == 0) {
        throw Failure(3, "JPEG profile exceeds metadata budget");
      }
      expected = count;
      chunks[sequence].assign(marker->data + 14, marker->data + marker->data_length);
    }
  }
  for (int i = 1; i <= expected; ++i) {
    if (chunks[i].empty()) { info.profile.clear(); break; }
    info.profile.insert(info.profile.end(), chunks[i].begin(), chunks[i].end());
  }
  jpeg_destroy_decompress(&codec);
  } catch (...) { jpeg_destroy_decompress(&codec); throw; }
}
void parse_png(File &file, Info &info) {
  uint8_t signature[8]; read_exact(file.value, signature, 8);
  if (png_sig_cmp(signature, 0, 8)) throw Failure(1, "Invalid PNG signature");
  // Header and ancillary chunks are streamed. Pixel payload never enters probe.
  for (;;) {
    uint8_t head[8]; read_exact(file.value, head, 8);
    uint32_t size = be32(head); const uint8_t *kind = head + 4;
    if (!memcmp(kind, "IDAT", 4) || !memcmp(kind, "IEND", 4)) break;
    if (size > kMetadataLimit && (!memcmp(kind, "iCCP", 4) || !memcmp(kind, "eXIf", 4)))
      throw Failure(3, "PNG metadata exceeds budget");
    if (!memcmp(kind, "IHDR", 4)) {
      if (size != 13) throw Failure(1, "Invalid PNG IHDR");
      uint8_t data[13]; read_exact(file.value, data, 13);
      info.metadata.encoded_width = be32(data); info.metadata.encoded_height = be32(data + 4);
      info.metadata.bit_depth = data[8];
      info.interlaced = data[12] != 0;
    } else if (!memcmp(kind, "acTL", 4)) {
      info.metadata.animated = 1; seek(file.value, uint64_t(ftell(file.value)) + size);
    } else if (!memcmp(kind, "eXIf", 4)) {
      ProfileBytes data(size); read_exact(file.value, data.data(), size);
      info.metadata.orientation = exif_orientation(data.data(), size);
    } else {
      if (!memcmp(kind, "iCCP", 4)) info.metadata.has_profile = 1;
      seek(file.value, uint64_t(ftell(file.value)) + size);
    }
    uint8_t crc[4]; read_exact(file.value, crc, 4);
  }
}
void parse_webp(File &file, Info &info) {
  uint8_t head[12]; read_exact(file.value, head, 12);
  if (memcmp(head, "RIFF", 4) || memcmp(head + 8, "WEBP", 4)) throw Failure(1, "Invalid WebP signature");
  uint64_t remaining = le32(head + 4) - 4;
  while (remaining >= 8) {
    uint8_t chunk[8]; read_exact(file.value, chunk, 8);
    uint64_t bytes = le32(chunk + 4), padded = bytes + (bytes & 1);
    if (padded > remaining - 8) throw Failure(1, "Invalid WebP chunk length");
    uint64_t position = uint64_t(ftell(file.value));
    if (!memcmp(chunk, "VP8X", 4)) {
      if (bytes < 10) throw Failure(1, "Invalid VP8X header");
      uint8_t data[10]; read_exact(file.value, data, 10);
      info.metadata.animated = (data[0] & 2) != 0;
      info.metadata.has_profile = (data[0] & 0x20) != 0;
      info.metadata.encoded_width = 1 + data[4] + (uint32_t(data[5]) << 8) + (uint32_t(data[6]) << 16);
      info.metadata.encoded_height = 1 + data[7] + (uint32_t(data[8]) << 8) + (uint32_t(data[9]) << 16);
    } else if (!memcmp(chunk, "VP8 ", 4) || !memcmp(chunk, "VP8L", 4)) {
      uint8_t data[10]{};
      read_exact(file.value, data, size_t(std::min<uint64_t>(10, bytes)));
      info.lossless = chunk[3] == 'L';
      if (!info.metadata.encoded_width) {
        if (info.lossless && bytes >= 5 && data[0] == 0x2f) {
          uint32_t bits = le32(data + 1);
          info.metadata.encoded_width = (bits & 0x3fff) + 1;
          info.metadata.encoded_height = ((bits >> 14) & 0x3fff) + 1;
        } else if (!info.lossless && bytes >= 10 && !memcmp(data + 3, "\x9d\x01\x2a", 3)) {
          info.metadata.encoded_width = (data[6] | (uint32_t(data[7]) << 8)) & 0x3fff;
          info.metadata.encoded_height = (data[8] | (uint32_t(data[9]) << 8)) & 0x3fff;
        }
      }
    } else if (!memcmp(chunk, "EXIF", 4) || !memcmp(chunk, "ICCP", 4)) {
      if (bytes > kMetadataLimit) throw Failure(3, "WebP metadata exceeds budget");
      ProfileBytes data(size_t(bytes), uint8_t(0));
      read_exact(file.value, data.data(), data.size());
      if (chunk[0] == 'E') info.metadata.orientation = exif_orientation(data.data(), data.size());
      else { info.profile = std::move(data); info.metadata.has_profile = 1; }
    }
    seek(file.value, position + padded); remaining -= 8 + padded;
  }
  info.metadata.bit_depth = 8;
}
Info inspect(const std::string &path) {
  File file(path, "rb"); uint8_t bytes[12]; read_exact(file.value, bytes, 12); seek(file.value, 0);
  Info info; info.metadata.orientation = 1;
  if (bytes[0] == 0xff && bytes[1] == 0xd8) { info.metadata.format = 1; parse_jpeg(file, info); }
  else if (!png_sig_cmp(bytes, 0, 8)) { info.metadata.format = 2; parse_png(file, info); }
  else if (!memcmp(bytes, "RIFF", 4) && !memcmp(bytes + 8, "WEBP", 4)) { info.metadata.format = 3; parse_webp(file, info); }
  else throw Failure(4, "Native regions support static JPEG, PNG and WebP");
  if (!info.metadata.encoded_width || !info.metadata.encoded_height ||
      info.metadata.encoded_width > 1000000 || info.metadata.encoded_height > 1000000)
    throw Failure(1, "Invalid or oversized image dimensions");
  info.metadata.width = info.metadata.orientation >= 5 ? info.metadata.encoded_height : info.metadata.encoded_width;
  info.metadata.height = info.metadata.orientation >= 5 ? info.metadata.encoded_width : info.metadata.encoded_height;
  info.metadata.has_profile |= !info.profile.empty();
  uint64_t row = uint64_t(info.metadata.encoded_width) * 8;
  info.metadata.estimated_working_bytes = info.metadata.format == 3
    ? uint64_t(info.metadata.encoded_width) * info.metadata.encoded_height * (info.lossless ? 8 : 4)
      + std::filesystem::file_size(std::filesystem::u8path(path)) + 32 * 1024 * 1024
    : 32 * 1024 * 1024 + row * 4;
  return info;
}
class Bytes {
 public:
  explicit Bytes(size_t bytes) : size(bytes), data(static_cast<uint8_t *>(pki_codec_alloc(bytes))) {
    if (!data) throw Failure(3, "Codec allocation refused by budget");
  }
  ~Bytes() { pki_codec_free(data); }
  size_t size; uint8_t *data;
};
class TemporaryStage {
 public:
  explicit TemporaryStage(std::string path) : path(std::move(path)), file(std::make_unique<File>(this->path, "w+b")) {}
  ~TemporaryStage() {
    file.reset(); std::error_code ignored;
    std::filesystem::remove(std::filesystem::u8path(path), ignored);
  }
  std::string path;
  std::unique_ptr<File> file;
};
class ColorTransform {
 public:
  explicit ColorTransform(const ProfileBytes &profile, bool sixteen = false) {
    if (profile.empty()) return;
    input_sixteen = sixteen;
    cmsPluginMemHandler allocator = {
      {cmsPluginMagicNumber, LCMS_VERSION, cmsPluginMemHandlerSig, nullptr},
      [](cmsContext, cmsUInt32Number bytes) -> void * { return pki_codec_alloc(bytes); },
      [](cmsContext, void *pointer) { pki_codec_free(pointer); },
      [](cmsContext, void *pointer, cmsUInt32Number bytes) -> void * {
        if (!pointer) return pki_codec_alloc(bytes);
        auto *allocation = static_cast<Allocation *>(pointer) - 1;
        auto *next = pki_codec_alloc(bytes);
        if (!next) return nullptr;
        memcpy(next, pointer, size_t(std::min<uint64_t>(allocation->bytes, bytes)));
        pki_codec_free(pointer); return next;
      }, nullptr, nullptr, nullptr
    };
    try {
      context = cmsCreateContext(&allocator, nullptr);
      if (!context) throw Failure(3, "Color-management context exceeds budget");
      source = cmsOpenProfileFromMemTHR(context, profile.data(), static_cast<cmsUInt32Number>(profile.size()));
      if (!source) throw Failure(active_budget && active_budget->denied ? 3 : 1, "Invalid image ICC profile");
      auto signature = cmsGetColorSpace(source);
      gray = signature == cmsSigGrayData;
      if (signature != cmsSigRgbData && !gray)
        throw Failure(4, "ICC profile requires a supported color-space adapter");
      destination = cmsCreate_sRGBProfileTHR(context);
      uint32_t format = gray ? (sixteen ? TYPE_GRAYA_16 : TYPE_GRAYA_8)
        : (sixteen ? TYPE_RGBA_16 : TYPE_RGBA_8);
      transform = cmsCreateTransformTHR(context, source, format,
        destination, TYPE_RGBA_8, INTENT_RELATIVE_COLORIMETRIC,
        cmsFLAGS_COPY_ALPHA | cmsFLAGS_BLACKPOINTCOMPENSATION);
      if (!transform) throw Failure(active_budget && active_budget->denied ? 3 : 1, "Cannot build ICC color transform");
    } catch (...) { release(); throw; }
  }
  void apply(const void *input, uint8_t *output, uint32_t pixels) const {
    if (transform && gray) {
      Bytes packed(uint64_t(pixels) * (input_sixteen ? 4 : 2));
      if (input_sixteen) {
        auto *source_pixels = static_cast<const uint16_t *>(input);
        auto *target_pixels = reinterpret_cast<uint16_t *>(packed.data);
        for (uint32_t i = 0; i < pixels; ++i) {
          target_pixels[i * 2] = source_pixels[i * 4];
          target_pixels[i * 2 + 1] = source_pixels[i * 4 + 3];
        }
      } else {
        auto *source_pixels = static_cast<const uint8_t *>(input);
        for (uint32_t i = 0; i < pixels; ++i) {
          packed.data[i * 2] = source_pixels[i * 4];
          packed.data[i * 2 + 1] = source_pixels[i * 4 + 3];
        }
      }
      cmsDoTransform(transform, packed.data, output, pixels);
    } else if (transform) cmsDoTransform(transform, input, output, pixels);
    else if (input != output) memcpy(output, input, uint64_t(pixels) * 4);
  }
  ~ColorTransform() { release(); }
 private:
  void release() {
    if (transform) cmsDeleteTransform(transform);
    if (source) cmsCloseProfile(source);
    if (destination) cmsCloseProfile(destination);
    if (context) cmsDeleteContext(context);
    transform = nullptr; source = destination = nullptr; context = nullptr;
  }
  bool gray = false, input_sixteen = false;
  cmsContext context = nullptr;
  cmsHPROFILE source = nullptr, destination = nullptr;
  cmsHTRANSFORM transform = nullptr;
};
struct RawHeader {
  char magic[8];
  uint64_t source_bytes, source_time, source_fingerprint;
  uint32_t width, height, orientation, algorithm;
  uint8_t padding[80];
};
static_assert(sizeof(RawHeader) == kRawHeaderSize, "Backing header layout");
uint64_t fingerprint(FILE *file) {
  uint8_t bytes[4096]; size_t size = fread(bytes, 1, sizeof(bytes), file);
  uint64_t hash = 1469598103934665603ULL;
  for (size_t i = 0; i < size; ++i) { hash ^= bytes[i]; hash *= 1099511628211ULL; }
  seek(file, 0); return hash;
}
RawHeader make_header(const std::string &path, const Info &info) {
  RawHeader result{}; memcpy(result.magic, "PKIRAW3", 8);
  auto actual = std::filesystem::u8path(path);
  result.source_bytes = std::filesystem::file_size(actual);
  result.source_time = static_cast<uint64_t>(std::filesystem::last_write_time(actual).time_since_epoch().count());
  File file(path, "rb"); result.source_fingerprint = fingerprint(file.value);
  result.width = info.metadata.encoded_width; result.height = info.metadata.encoded_height;
  result.orientation = info.metadata.orientation; result.algorithm = 3;
  return result;
}
std::mutex locks_mutex;
using BackingMutex = std::shared_timed_mutex;
std::unordered_map<std::string, std::weak_ptr<BackingMutex>> locks;
std::shared_ptr<BackingMutex> backing_mutex(const std::string &path) {
  std::lock_guard<std::mutex> guard(locks_mutex);
  auto &weak = locks[path]; auto current = weak.lock();
  if (!current) { current = std::make_shared<BackingMutex>(); weak = current; }
  if (locks.size() > 256) {
    for (auto i = locks.begin(); i != locks.end();) {
      if (i->second.expired()) i = locks.erase(i); else ++i;
    }
  }
  return current;
}
bool backing_matches(const std::string &backing, const RawHeader &header) {
  const auto actual = std::filesystem::u8path(backing);
  const uint64_t bytes = kRawHeaderSize + uint64_t(header.width) * header.height * 4;
  if (!std::filesystem::exists(actual) || std::filesystem::file_size(actual) != bytes)
    return false;
  File existing(backing, "rb"); RawHeader old{};
  read_exact(existing.value, &old, sizeof(old));
  return !memcmp(&old, &header, sizeof(header));
}
void build_jpeg(const std::string &path, File &output, const Info &info, Budget &budget) {
  if (info.metadata.bit_depth != 8) throw Failure(4, "High-precision JPEG requires the compatible full-frame path");
  File input(path, "rb");
  jpeg_decompress_struct codec{}; JpegError error{};
  codec.err = jpeg_std_error(&error.manager); error.manager.error_exit = jpeg_error;
  error.manager.output_message = jpeg_quiet_output;
  uint8_t *row = nullptr;
  std::unique_ptr<ColorTransform> color;
  try {
    jpeg_create_decompress(&codec);
    // This controls virtual coefficient arrays; the allocation hook enforces
    // the complete request budget, including non-virtual codec allocations.
    codec.mem->max_memory_to_use = static_cast<long>(std::min<uint64_t>(budget.limit / 3, 32 * 1024 * 1024));
    jpeg_checked_source(&codec, input.value); jpeg_read_header(&codec, TRUE);
    codec.out_color_space = JCS_EXT_RGBA;
    jpeg_start_decompress(&codec);
    row = static_cast<uint8_t *>(pki_codec_alloc(uint64_t(codec.output_width) * 4));
    if (!row) throw Failure(3, "JPEG row allocation exceeds budget");
    color = std::make_unique<ColorTransform>(info.profile);
    while (codec.output_scanline < codec.output_height) {
      budget.check(); JSAMPROW scanline = row;
      jpeg_read_scanlines(&codec, &scanline, 1);
      color->apply(row, row, codec.output_width);
      write_exact(output.value, row, uint64_t(codec.output_width) * 4);
    }
    jpeg_finish_decompress(&codec);
    pki_codec_free(row); row = nullptr; jpeg_destroy_decompress(&codec);
  } catch (...) {
    pki_codec_free(row); jpeg_destroy_decompress(&codec); throw;
  }
}
void png_error_callback(png_structp png, png_const_charp message) {
  (void)png;
  throw Failure(active_budget && active_budget->denied ? 3 : 1, message);
}
void png_warning_callback(png_structp, png_const_charp) {}
png_voidp png_allocate(png_structp, png_alloc_size_t bytes) { return pki_codec_alloc(bytes); }
void png_free_memory(png_structp, png_voidp pointer) { pki_codec_free(pointer); }
void build_png(const std::string &path, File &output, const Info &info, Budget &budget) {
  File input(path, "rb");
  png_structp png = png_create_read_struct_2(PNG_LIBPNG_VER_STRING, nullptr,
    png_error_callback, png_warning_callback, nullptr, png_allocate, png_free_memory);
  if (!png) throw Failure(3, "PNG allocation exceeds budget");
  png_infop metadata = png_create_info_struct(png);
  uint8_t *row = nullptr, *converted = nullptr;
  ProfileBytes profile;
  std::unique_ptr<ColorTransform> color;
  std::unique_ptr<TemporaryStage> precision_stage;
  if (!metadata) {
    pki_codec_free(row); pki_codec_free(converted);
    png_destroy_read_struct(&png, &metadata, nullptr);
    throw Failure(budget.denied ? 3 : 1, "PNG decode failed (invalid data or metadata)");
  }
  try {
    png_init_io(png, input.value);
    png_set_chunk_malloc_max(png, kMetadataLimit);
    png_set_user_limits(png, 1000000, 1000000);
    png_read_info(png, metadata);
    char *name; int compression; png_bytep profile_bytes; png_uint_32 profile_length;
    if (png_get_iCCP(png, metadata, &name, &compression, &profile_bytes, &profile_length))
      profile.assign(profile_bytes, profile_bytes + profile_length);
    bool sixteen = png_get_bit_depth(png, metadata) == 16;
    if (png_get_color_type(png, metadata) == PNG_COLOR_TYPE_PALETTE) png_set_palette_to_rgb(png);
    if (png_get_color_type(png, metadata) == PNG_COLOR_TYPE_GRAY && png_get_bit_depth(png, metadata) < 8)
      png_set_expand_gray_1_2_4_to_8(png);
    bool transparency = png_get_valid(png, metadata, PNG_INFO_tRNS) != 0;
    if (transparency) png_set_tRNS_to_alpha(png);
    if (png_get_color_type(png, metadata) == PNG_COLOR_TYPE_GRAY || png_get_color_type(png, metadata) == PNG_COLOR_TYPE_GRAY_ALPHA)
      png_set_gray_to_rgb(png);
    if (!(png_get_color_type(png, metadata) & PNG_COLOR_MASK_ALPHA) && !transparency)
      png_set_add_alpha(png, sixteen ? 65535 : 255, PNG_FILLER_AFTER);
    // Preserve 16-bit values through profile conversion, then quantize once to
    // the same sRGB8 display target used by the existing Flutter renderer.
    if (sixteen && !profile.empty()) {
      uint16_t host = 1; if (*reinterpret_cast<uint8_t *>(&host)) png_set_swap(png);
    } else if (sixteen) {
      png_set_scale_16(png); sixteen = false;
    }
    int passes = png_set_interlace_handling(png);
    png_read_update_info(png, metadata);
    size_t row_bytes = png_get_rowbytes(png, metadata);
    size_t rgba_bytes = uint64_t(info.metadata.encoded_width) * 4;
    row = static_cast<uint8_t *>(pki_codec_alloc(row_bytes));
    converted = static_cast<uint8_t *>(pki_codec_alloc(rgba_bytes));
    if (!row || !converted) throw Failure(3, "PNG row allocation exceeds budget");
    color = std::make_unique<ColorTransform>(profile, sixteen);
    if (sixteen && passes > 1) {
      uint64_t precision_bytes = uint64_t(row_bytes) * info.metadata.encoded_height;
      budget.reserve_disk(precision_bytes);
      if (precision_bytes > std::filesystem::space(std::filesystem::u8path(budget.backing).parent_path()).available)
        throw Failure(3, "Insufficient storage for 16-bit PNG interlace workspace");
      precision_stage = std::make_unique<TemporaryStage>(budget.backing + ".png16");
      seek(precision_stage->file->value, precision_bytes - 1);
      uint8_t zero = 0; write_exact(precision_stage->file->value, &zero, 1);
    }
    if (passes > 1) {
      // Extend without allocating a whole image in memory. Untouched Adam7
      // rows read as zeros until their first pass writes real pixels.
      seek(output.value, kRawHeaderSize + uint64_t(info.metadata.encoded_height) * rgba_bytes - 1);
      uint8_t zero = 0; write_exact(output.value, &zero, 1);
      seek(output.value, kRawHeaderSize);
    }
    for (int pass = 0; pass < passes; ++pass) {
      for (uint32_t y = 0; y < info.metadata.encoded_height; ++y) {
        budget.check();
        static constexpr uint32_t starts[7] = {0, 0, 4, 0, 2, 0, 1};
        static constexpr uint32_t steps[7] = {8, 8, 8, 4, 4, 2, 2};
        if (passes > 1 && (y < starts[pass] || (y - starts[pass]) % steps[pass] != 0)) {
          png_read_row(png, nullptr, nullptr);
          continue;
        }
        uint64_t offset = kRawHeaderSize + uint64_t(y) * rgba_bytes;
        if (pass == 0) memset(row, 0, row_bytes);
        else if (precision_stage) {
          seek(precision_stage->file->value, uint64_t(y) * row_bytes);
          read_exact(precision_stage->file->value, row, row_bytes);
        } else { seek(output.value, offset); read_exact(output.value, row, rgba_bytes); }
        png_read_row(png, row, nullptr);
        if (precision_stage) {
          seek(precision_stage->file->value, uint64_t(y) * row_bytes);
          write_exact(precision_stage->file->value, row, row_bytes);
          continue;
        }
        // Interlace combines source-space rows; color transform after the last
        // pass so previously stored pixels never get transformed twice.
        if (passes == 1 || pass >= 5) color->apply(row, converted, info.metadata.encoded_width);
        else memcpy(converted, row, rgba_bytes);
        if (passes > 1) seek(output.value, offset);
        write_exact(output.value, converted, rgba_bytes);
      }
    }
    if (precision_stage) {
      seek(precision_stage->file->value, 0); seek(output.value, kRawHeaderSize);
      for (uint32_t y = 0; y < info.metadata.encoded_height; ++y) {
        budget.check(); read_exact(precision_stage->file->value, row, row_bytes);
        color->apply(row, converted, info.metadata.encoded_width);
        write_exact(output.value, converted, rgba_bytes);
      }
      precision_stage.reset();
    }
    png_read_end(png, metadata);
    pki_codec_free(row); row = nullptr; pki_codec_free(converted); converted = nullptr;
    png_destroy_read_struct(&png, &metadata, nullptr);
  } catch (...) {
    pki_codec_free(row); pki_codec_free(converted);
    png_destroy_read_struct(&png, &metadata, nullptr); throw;
  }
}
class Mapping {
 public:
  Mapping(const std::string &path, uint64_t size, bool writable) : size(size) {
#ifdef _WIN32
    file = CreateFileW(std::filesystem::u8path(path).wstring().c_str(),
      writable ? GENERIC_READ | GENERIC_WRITE : GENERIC_READ,
      FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
      FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) throw Failure(1, "Cannot open mapped image backing");
    mapping = CreateFileMappingW(file, nullptr, writable ? PAGE_READWRITE : PAGE_READONLY,
      DWORD(size >> 32), DWORD(size), nullptr);
    if (!mapping) { CloseHandle(file); file = INVALID_HANDLE_VALUE; throw Failure(3, "Cannot map image backing"); }
    data = static_cast<uint8_t *>(MapViewOfFile(mapping, writable ? FILE_MAP_WRITE : FILE_MAP_READ, 0, 0, size_t(size)));
#else
    file = open(path.c_str(), writable ? O_RDWR : O_RDONLY);
    if (file < 0) throw Failure(1, "Cannot open mapped image backing");
    if (writable && ftruncate(file, static_cast<off_t>(size)) != 0) {
      close(file); file = -1; throw Failure(3, "Cannot extend mapped image backing");
    }
    data = static_cast<uint8_t *>(mmap(nullptr, size_t(size), writable ? PROT_READ | PROT_WRITE : PROT_READ, MAP_SHARED, file, 0));
    if (data == MAP_FAILED) data = nullptr;
#endif
    if (!data) { close_mapping(); throw Failure(3, "Cannot map image backing"); }
  }
  void flush(uint64_t offset, uint64_t length, bool discard) {
    if (!length) return;
#ifdef _WIN32
    FlushViewOfFile(data + offset, size_t(length));
    // Windows working-set trimming is process-wide and is deliberately not
    // used here. Mapped residency is conservatively charged by admission.
    (void)discard;
#else
    uint64_t page = uint64_t(sysconf(_SC_PAGESIZE));
    uint64_t start = offset - offset % page;
    uint64_t count = std::min(size - start, offset + length - start);
    msync(data + start, size_t(count), MS_SYNC);
    if (discard) madvise(data + start, size_t(count), MADV_DONTNEED);
#endif
  }
  ~Mapping() { close_mapping(); }
  uint8_t *data = nullptr; uint64_t size;
 private:
  void close_mapping() {
#ifdef _WIN32
    if (data) UnmapViewOfFile(data);
    if (mapping) CloseHandle(mapping);
    if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
#else
    if (data) munmap(data, size_t(size));
    if (file >= 0) close(file);
#endif
    data = nullptr;
  }
#ifdef _WIN32
  HANDLE file = INVALID_HANDLE_VALUE, mapping = nullptr;
#else
  int file = -1;
#endif
};
void build_webp(const std::string &path, const std::string &partial,
                const Info &info, Budget &budget) {
  uint64_t source_size = std::filesystem::file_size(std::filesystem::u8path(path));
  uint64_t raw_size = uint64_t(info.metadata.encoded_width) * info.metadata.encoded_height * 4;
  // libwebp does not guarantee viewport-sized workspace. Count mapped output
  // and source residency as memory as well; no silent unbounded fallback.
  budget.reserve(raw_size + source_size);
  Mapping input(path, source_size, false);
  Mapping output(partial, kRawHeaderSize + raw_size, true);
  WebPDecoderConfig config{};
  if (!WebPInitDecoderConfig(&config)) throw Failure(1, "WebP ABI mismatch");
  config.output.colorspace = MODE_RGBA;
  config.output.is_external_memory = 1;
  config.output.u.RGBA.rgba = output.data + kRawHeaderSize;
  config.output.u.RGBA.stride = int(info.metadata.encoded_width * 4);
  config.output.u.RGBA.size = size_t(raw_size);
  config.options.use_threads = 0;
  WebPIDecoder *decoder = WebPIDecode(nullptr, 0, &config);
  if (!decoder) { budget.used -= raw_size + source_size; throw Failure(3, "WebP decoder allocation exceeds budget"); }
  try {
    uint64_t supplied = 0; int flushed_rows = 0;
    while (supplied < source_size) {
      budget.check(); supplied = std::min(source_size, supplied + 4096);
      VP8StatusCode status = WebPIUpdate(decoder, input.data, size_t(supplied));
      int rows = 0; WebPIDecGetRGB(decoder, &rows, nullptr, nullptr, nullptr);
      if (rows > flushed_rows) {
        output.flush(kRawHeaderSize + uint64_t(flushed_rows) * info.metadata.encoded_width * 4,
          uint64_t(rows - flushed_rows) * info.metadata.encoded_width * 4, true);
        flushed_rows = rows;
      }
      if (status == VP8_STATUS_OK) break;
      if (status != VP8_STATUS_SUSPENDED) throw Failure(budget.denied ? 3 : 1, "WebP decoding failed");
      if (supplied == source_size) throw Failure(1, "Truncated WebP image");
    }
    WebPIDelete(decoder); decoder = nullptr;
    if (!info.profile.empty()) {
      ColorTransform color(info.profile);
      for (uint32_t y = 0; y < info.metadata.encoded_height; ++y) {
        budget.check(); uint8_t *row = output.data + kRawHeaderSize + uint64_t(y) * info.metadata.encoded_width * 4;
        color.apply(row, row, info.metadata.encoded_width);
      }
    }
    output.flush(kRawHeaderSize, raw_size, true);
    budget.used -= raw_size + source_size;
  } catch (...) {
    if (decoder) WebPIDelete(decoder);
    budget.used -= raw_size + source_size; throw;
  }
}
void ensure_backing(const std::string &path, const std::string &backing,
                    const Info &info, Budget &budget) {
  auto parent = std::filesystem::u8path(backing).parent_path();
  if (parent.empty()) throw Failure(1, "A managed backing directory is required");
  std::filesystem::create_directories(parent);
  RawHeader header = make_header(path, info);
  uint64_t bytes = kRawHeaderSize + uint64_t(header.width) * header.height * 4;
  if (backing_matches(backing, header)) {
    budget.reserve_disk(bytes); return;
  }
  budget.reserve_disk(bytes);
  auto available = std::filesystem::space(parent).available;
  uint64_t coefficient_reserve = info.progressive
    ? uint64_t(header.width) * header.height * 6 : 0;
  if (bytes > available || coefficient_reserve > available - bytes)
    throw Failure(3, "Insufficient free storage for lossless image backing");
  std::string partial = backing + ".partial";
  try {
    {
      Bytes disk_buffer(1024 * 1024);
      File output(partial, "w+b");
      setvbuf(output.value, reinterpret_cast<char *>(disk_buffer.data), _IOFBF, disk_buffer.size);
      write_exact(output.value, &header, sizeof(header));
      if (info.metadata.format == 1) build_jpeg(path, output, info, budget);
      else if (info.metadata.format == 2) build_png(path, output, info, budget);
    }
    if (info.metadata.format == 3) build_webp(path, partial, info, budget);
    budget.check();
    auto after = make_header(path, info);
    if (memcmp(&header, &after, sizeof(header)))
      throw Failure(1, "Original image changed while deriving pixels");
    std::error_code ignored;
    std::filesystem::remove(std::filesystem::u8path(backing), ignored);
    std::filesystem::rename(std::filesystem::u8path(partial), std::filesystem::u8path(backing));
  } catch (...) {
    std::error_code ignored; std::filesystem::remove(std::filesystem::u8path(partial), ignored); throw;
  }
}
std::pair<uint32_t, uint32_t> encoded_coordinate(uint32_t x, uint32_t y, const pki_metadata &info) {
  uint32_t w = info.encoded_width, h = info.encoded_height;
  switch (info.orientation) {
    case 2: return {w - 1 - x, y};
    case 3: return {w - 1 - x, h - 1 - y};
    case 4: return {x, h - 1 - y};
    case 5: return {y, x};
    case 6: return {y, h - 1 - x};
    case 7: return {w - 1 - y, h - 1 - x};
    case 8: return {w - 1 - y, x};
    default: return {x, y};
  }
}
void quick_jpeg_region(const std::string &path, const Info &info,
  const pki_request &request, pki_result &result, Budget &budget, uint32_t denominator) {
  pki_request normalized = request;
  pki_metadata sampled_info = info.metadata;
  if (denominator > 1) {
    normalized.x /= denominator; normalized.y /= denominator;
    normalized.width = request.output_width; normalized.height = request.output_height;
    sampled_info.width = sampled_info.encoded_width = (info.metadata.encoded_width + denominator - 1) / denominator;
    sampled_info.height = sampled_info.encoded_height = (info.metadata.encoded_height + denominator - 1) / denominator;
  }
  auto a = encoded_coordinate(normalized.x, normalized.y, sampled_info);
  auto b = encoded_coordinate(normalized.x + normalized.width - 1,
    normalized.y + normalized.height - 1, sampled_info);
  uint32_t left = std::min(a.first, b.first), top = std::min(a.second, b.second);
  uint32_t width = std::max(a.first, b.first) - left + 1;
  uint32_t height = std::max(a.second, b.second) - top + 1;
  File input(path, "rb"); jpeg_decompress_struct codec{}; JpegError error{};
  codec.err = jpeg_std_error(&error.manager); error.manager.error_exit = jpeg_error;
  error.manager.output_message = jpeg_quiet_output;
  uint8_t *row = nullptr; std::unique_ptr<ColorTransform> color;
  try {
    jpeg_create_decompress(&codec);
    jpeg_checked_source(&codec, input.value); jpeg_read_header(&codec, TRUE);
    codec.out_color_space = JCS_EXT_RGBA;
    codec.scale_num = 1; codec.scale_denom = denominator;
    jpeg_start_decompress(&codec);
    // Leave a full iMCU neighborhood around the exact ROI so fancy chroma
    // interpolation is identical at neighboring tile edges.
    JDIMENSION crop_left = left > 16 ? left - 16 : 0;
    JDIMENSION crop_width = std::min(sampled_info.encoded_width - crop_left,
      left + width + 16 - crop_left);
    jpeg_crop_scanline(&codec, &crop_left, &crop_width);
    row = static_cast<uint8_t *>(pki_codec_alloc(uint64_t(codec.output_width) * 4));
    if (!row) throw Failure(3, "JPEG region row exceeds budget");
    uint64_t bytes = uint64_t(request.output_width) * request.output_height * 4;
    budget.reserve(bytes); result.pixels = static_cast<uint8_t *>(malloc(size_t(bytes)));
    if (!result.pixels) throw Failure(3, "JPEG region output allocation failed");
    result.byte_length = bytes; result.width = request.output_width;
    result.height = request.output_height; result.stride = request.output_width * 4;
    color = std::make_unique<ColorTransform>(info.profile);
    uint32_t warmup_top = top > 16 ? top - 16 : 0;
    if (jpeg_skip_scanlines(&codec, warmup_top) != warmup_top) throw Failure(1, "JPEG region skip failed");
    for (uint32_t encoded_y = warmup_top; encoded_y < top + height; ++encoded_y) {
      budget.check(); JSAMPROW scanline = row; jpeg_read_scanlines(&codec, &scanline, 1);
      if (encoded_y < top) continue;
      color->apply(row, row, codec.output_width);
      for (uint32_t encoded_x = left; encoded_x < left + width; ++encoded_x) {
        uint32_t x = encoded_x, y = encoded_y;
        uint32_t ew = sampled_info.encoded_width, eh = sampled_info.encoded_height;
        switch (info.metadata.orientation) {
          case 2: x = ew - 1 - encoded_x; break;
          case 3: x = ew - 1 - encoded_x; y = eh - 1 - encoded_y; break;
          case 4: y = eh - 1 - encoded_y; break;
          case 5: x = encoded_y; y = encoded_x; break;
          case 6: x = eh - 1 - encoded_y; y = encoded_x; break;
          case 7: x = eh - 1 - encoded_y; y = ew - 1 - encoded_x; break;
          case 8: x = encoded_y; y = ew - 1 - encoded_x; break;
          default: break;
        }
        memcpy(result.pixels + (uint64_t(y - normalized.y) * request.output_width + x - normalized.x) * 4,
          row + uint64_t(encoded_x - crop_left) * 4, 4);
      }
    }
    jpeg_abort_decompress(&codec);
    pki_codec_free(row); row = nullptr; jpeg_destroy_decompress(&codec);
  } catch (...) {
    pki_codec_free(row); jpeg_destroy_decompress(&codec); throw;
  }
}
void allocate_pixels(const pki_request &request, pki_result &result, Budget &budget) {
  uint64_t output_bytes = uint64_t(request.output_width) * request.output_height * 4;
  budget.reserve(output_bytes);
  result.pixels = static_cast<uint8_t *>(malloc(size_t(output_bytes)));
  if (!result.pixels) throw Failure(3, "Unable to allocate image output");
  result.byte_length = output_bytes; result.width = request.output_width;
  result.height = request.output_height; result.stride = request.output_width * 4;
}
class AreaRescaler {
 public:
  AreaRescaler(const pki_request &request, pki_result &result, Budget &budget, bool opaque = false)
    : request(request), result(result), budget(budget), opaque(opaque), work(uint64_t(request.output_width) * 4 * 2 * sizeof(rescaler_t)) {
    allocate_pixels(request, result, budget);
    if (!WebPRescalerInit(&scaler, int(request.width), int(request.height), result.pixels,
      int(request.output_width), int(request.output_height), int(result.stride), 4,
      reinterpret_cast<rescaler_t *>(work.data))) throw Failure(1, "Cannot initialize bounded area rescaler");
  }
  void row(uint8_t *pixels) {
    if (!opaque) for (uint32_t x = 0; x < request.width; ++x) {
      auto *p = pixels + uint64_t(x) * 4; uint32_t alpha = p[3];
      if (alpha != 255) for (int c = 0; c < 3; ++c) p[c] = uint8_t((p[c] * alpha + 127) / 255);
    }
    int consumed = WebPRescalerImport(&scaler, 1, pixels, int(request.width * 4));
    if (consumed != 1) throw Failure(1, "Area rescaler did not consume source row");
    WebPRescalerExport(&scaler);
  }
  void finish() {
    if (!WebPRescalerOutputDone(&scaler)) throw Failure(1, "Incomplete area rescaler output");
    for (uint64_t i = 0; i < result.byte_length; i += 4) {
      if (i % result.stride == 0) budget.check();
      auto *p = result.pixels + i; uint32_t alpha = p[3];
      if (alpha != 255) for (int c = 0; c < 3; ++c)
        p[c] = alpha ? uint8_t(std::min(255U, (p[c] * 255U + alpha / 2) / alpha)) : 0;
    }
  }
 private:
  const pki_request &request; pki_result &result; Budget &budget; const bool opaque; Bytes work; WebPRescaler scaler{};
};
void quick_png_fit(const std::string &path, const Info &info,
  const pki_request &request, pki_result &result, Budget &budget) {
  File input(path, "rb");
  png_structp png = png_create_read_struct_2(PNG_LIBPNG_VER_STRING, nullptr,
    png_error_callback, png_warning_callback, nullptr, png_allocate, png_free_memory);
  if (!png) throw Failure(3, "PNG allocation exceeds budget");
  png_infop metadata = png_create_info_struct(png);
  if (!metadata) { png_destroy_read_struct(&png, &metadata, nullptr); throw Failure(3, "PNG metadata allocation exceeds budget"); }
  try {
    png_init_io(png, input.value); png_set_chunk_malloc_max(png, kMetadataLimit);
    png_set_user_limits(png, 1000000, 1000000); png_read_info(png, metadata);
    int type = png_get_color_type(png, metadata);
    if (type == PNG_COLOR_TYPE_PALETTE) png_set_palette_to_rgb(png);
    if (type == PNG_COLOR_TYPE_GRAY && png_get_bit_depth(png, metadata) < 8) png_set_expand_gray_1_2_4_to_8(png);
    bool transparency = png_get_valid(png, metadata, PNG_INFO_tRNS) != 0;
    if (transparency) png_set_tRNS_to_alpha(png);
    if (type == PNG_COLOR_TYPE_GRAY || type == PNG_COLOR_TYPE_GRAY_ALPHA) png_set_gray_to_rgb(png);
    if (!(type & PNG_COLOR_MASK_ALPHA) && !transparency) png_set_add_alpha(png, 255, PNG_FILLER_AFTER);
    png_read_update_info(png, metadata);
    Bytes row(png_get_rowbytes(png, metadata));
    AreaRescaler rescaler(request, result, budget, !(type & PNG_COLOR_MASK_ALPHA) && !transparency);
    for (uint32_t y = 0; y < info.metadata.encoded_height; ++y) {
      budget.check(); png_read_row(png, row.data, nullptr); rescaler.row(row.data);
    }
    png_read_end(png, metadata); rescaler.finish(); png_destroy_read_struct(&png, &metadata, nullptr);
  } catch (...) { png_destroy_read_struct(&png, &metadata, nullptr); throw; }
}
void sample_backing(const std::string &backing, const Info &info,
  const pki_request &request, pki_result &result, Budget &budget) {
  uint64_t output_bytes = uint64_t(request.output_width) * request.output_height * 4;
  budget.reserve(output_bytes);
  result.pixels = static_cast<uint8_t *>(malloc(size_t(output_bytes)));
  if (!result.pixels) throw Failure(3, "Unable to allocate image output");
  result.byte_length = output_bytes; result.width = request.output_width;
  result.height = request.output_height; result.stride = request.output_width * 4;
  File input(backing, "rb");
  if (info.metadata.orientation == 1 &&
      request.output_width == request.width && request.output_height == request.height) {
    for (uint32_t y = 0; y < request.height; ++y) {
      budget.check(); seek(input.value, kRawHeaderSize +
        (uint64_t(request.y + y) * info.metadata.encoded_width + request.x) * 4);
      read_exact(input.value, result.pixels + uint64_t(y) * result.stride, result.stride);
    }
    return;
  }
  // prepareBacking's 1x1 handoff must not read the entire raw layer again.
  if (info.metadata.orientation == 1 && request.output_width > 1 && request.output_height > 1 &&
      request.output_width < request.width && request.output_height < request.height) {
    free(result.pixels); result.pixels = nullptr; budget.used -= output_bytes;
    AreaRescaler rescaler(request, result, budget); Bytes row(uint64_t(request.width) * 4);
    for (uint32_t y = 0; y < request.height; ++y) {
      budget.check(); seek(input.value, kRawHeaderSize +
        (uint64_t(request.y + y) * info.metadata.encoded_width + request.x) * 4);
      read_exact(input.value, row.data, row.size); rescaler.row(row.data);
    }
    rescaler.finish(); return;
  }
  // A small fixed row cache covers horizontal sampling and rotated images.
  // Native 1:1 returns byte-identical normalized source pixels.
  uint64_t row_bytes = uint64_t(info.metadata.encoded_width) * 4;
  constexpr size_t cache_size = 8;
  std::array<std::unique_ptr<Bytes>, cache_size> rows;
  std::array<uint32_t, cache_size> row_ids;
  row_ids.fill(std::numeric_limits<uint32_t>::max());
  for (auto &row : rows) row = std::make_unique<Bytes>(size_t(row_bytes));
  auto get_pixel = [&](uint32_t x, uint32_t y) {
    auto encoded = encoded_coordinate(x, y, info.metadata);
    size_t slot = encoded.second % cache_size;
    if (row_ids[slot] != encoded.second) {
      budget.check(); seek(input.value, kRawHeaderSize + uint64_t(encoded.second) * row_bytes);
      read_exact(input.value, rows[slot]->data, size_t(row_bytes));
      row_ids[slot] = encoded.second;
    }
    std::array<uint8_t, 4> value;
    memcpy(value.data(), rows[slot]->data + uint64_t(encoded.first) * 4, 4);
    return value;
  };
  bool native = request.output_width == request.width && request.output_height == request.height;
  for (uint32_t y = 0; y < request.output_height; ++y) {
    budget.check();
    double sy = request.y + (y + 0.5) * request.height / request.output_height - 0.5;
    sy = std::clamp(sy, double(request.y), double(request.y + request.height - 1));
    uint32_t y0 = uint32_t(sy), y1 = std::min(y0 + 1, request.y + request.height - 1);
    double fy = sy - y0;
    for (uint32_t x = 0; x < request.output_width; ++x) {
      uint8_t *destination = result.pixels + (uint64_t(y) * request.output_width + x) * 4;
      if (native) { auto value = get_pixel(request.x + x, request.y + y); memcpy(destination, value.data(), 4); continue; }
      double sx = request.x + (x + 0.5) * request.width / request.output_width - 0.5;
      sx = std::clamp(sx, double(request.x), double(request.x + request.width - 1));
      uint32_t x0 = uint32_t(sx), x1 = std::min(x0 + 1, request.x + request.width - 1);
      double fx = sx - x0;
      auto a = get_pixel(x0, y0), b = get_pixel(x1, y0), c = get_pixel(x0, y1), d = get_pixel(x1, y1);
      double weights[4] = {(1 - fx) * (1 - fy), fx * (1 - fy), (1 - fx) * fy, fx * fy};
      std::array<uint8_t, 4> values[4] = {a, b, c, d}; double alpha = 0;
      for (int i = 0; i < 4; ++i) alpha += values[i][3] * weights[i];
      destination[3] = uint8_t(std::clamp(std::round(alpha), 0.0, 255.0));
      for (int channel = 0; channel < 3; ++channel) {
        double premultiplied = 0;
        for (int i = 0; i < 4; ++i) premultiplied += values[i][channel] * values[i][3] * weights[i];
        destination[channel] = alpha > 0 ? uint8_t(std::clamp(std::round(premultiplied / alpha), 0.0, 255.0)) : 0;
      }
    }
  }
}
void set_error(uint8_t *output, uint64_t size, const char *message) {
  if (!output || !size) return;
  size_t count = std::min(size_t(size - 1), strlen(message)); memcpy(output, message, count); output[count] = 0;
}
class EncodedSink {
 public:
  explicit EncodedSink(uint64_t limit) : limit(limit) {}
  ~EncodedSink() { pki_codec_free(data); }
  void append(const uint8_t *bytes, size_t count) {
    if (active_budget) active_budget->check();
    if (count > limit || size > limit - count) throw Failure(3, "Encoded image exceeds output limit");
    if (size + count > capacity) {
      uint64_t next = std::min(limit, std::max(size + count, std::max<uint64_t>(4096, capacity * 2)));
      auto *replacement = static_cast<uint8_t *>(pki_codec_alloc(size_t(next)));
      if (!replacement) throw Failure(3, "Image encoder output exceeds memory budget");
      if (size) memcpy(replacement, data, size_t(size));
      pki_codec_free(data); data = replacement; capacity = next;
    }
    memcpy(data + size, bytes, count); size += count;
  }
  uint8_t *detach() {
    if (data) (reinterpret_cast<Allocation *>(data) - 1)->owner = nullptr;
    auto *result = data; data = nullptr; return result;
  }
  uint8_t *data = nullptr;
  uint64_t size = 0, capacity = 0, limit;
};
void encode_png(const uint8_t *rgba, const pki_encode_request &request, EncodedSink &sink) {
  png_structp png = png_create_write_struct_2(PNG_LIBPNG_VER_STRING, nullptr,
    png_error_callback, png_warning_callback, nullptr, png_allocate, png_free_memory);
  if (!png) throw Failure(3, "PNG encoder allocation exceeds budget");
  png_infop info = png_create_info_struct(png);
  if (!info) {
    png_destroy_write_struct(&png, &info);
    throw Failure(active_budget && active_budget->denied ? 3 : 1, "PNG encoding failed");
  }
  try {
    png_set_write_fn(png, &sink, [](png_structp codec, png_bytep bytes, png_size_t count) {
      static_cast<EncodedSink *>(png_get_io_ptr(codec))->append(bytes, count);
    }, [](png_structp) {});
    png_set_IHDR(png, info, request.width, request.height, 8, PNG_COLOR_TYPE_RGBA,
      PNG_INTERLACE_NONE, PNG_COMPRESSION_TYPE_DEFAULT, PNG_FILTER_TYPE_DEFAULT);
    png_set_sRGB(png, info, PNG_sRGB_INTENT_RELATIVE);
    png_set_compression_level(png, 3);
    png_write_info(png, info);
    for (uint32_t y = 0; y < request.height; ++y) {
      if (active_budget) active_budget->check();
      png_write_row(png, const_cast<uint8_t *>(rgba + uint64_t(y) * request.stride));
    }
    png_write_end(png, info); png_destroy_write_struct(&png, &info);
  } catch (...) { png_destroy_write_struct(&png, &info); throw; }
}
struct JpegDestination {
  jpeg_destination_mgr manager;
  EncodedSink *sink;
  uint8_t bytes[4096];
};
void encode_jpeg(const uint8_t *rgba, const pki_encode_request &request, EncodedSink &sink) {
  for (uint32_t y = 0; y < request.height; ++y)
    for (uint32_t x = 0; x < request.width; ++x)
      if (rgba[uint64_t(y) * request.stride + uint64_t(x) * 4 + 3] != 255)
        throw Failure(4, "JPEG would discard image transparency");
  jpeg_compress_struct codec{}; JpegError error{}; JpegDestination destination{};
  codec.err = jpeg_std_error(&error.manager); error.manager.error_exit = jpeg_error;
  error.manager.output_message = jpeg_quiet_output;
  try {
    jpeg_create_compress(&codec);
    destination.sink = &sink;
    destination.manager.init_destination = [](j_compress_ptr encoder) {
      auto *dest = reinterpret_cast<JpegDestination *>(encoder->dest);
      dest->manager.next_output_byte = dest->bytes;
      dest->manager.free_in_buffer = sizeof(dest->bytes);
    };
    destination.manager.empty_output_buffer = [](j_compress_ptr encoder) -> boolean {
      auto *dest = reinterpret_cast<JpegDestination *>(encoder->dest);
      dest->sink->append(dest->bytes, sizeof(dest->bytes));
      dest->manager.next_output_byte = dest->bytes;
      dest->manager.free_in_buffer = sizeof(dest->bytes); return TRUE;
    };
    destination.manager.term_destination = [](j_compress_ptr encoder) {
      auto *dest = reinterpret_cast<JpegDestination *>(encoder->dest);
      dest->sink->append(dest->bytes, sizeof(dest->bytes) - dest->manager.free_in_buffer);
    };
    codec.dest = &destination.manager; codec.image_width = request.width;
    codec.image_height = request.height; codec.input_components = 4;
    codec.in_color_space = JCS_EXT_RGBA; jpeg_set_defaults(&codec);
    jpeg_set_quality(&codec, int(request.quality), TRUE);
    // Covers preserve fine ink by using 4:4:4 rather than chroma subsampling.
    for (int i = 0; i < codec.num_components; ++i) {
      codec.comp_info[i].h_samp_factor = 1; codec.comp_info[i].v_samp_factor = 1;
    }
    jpeg_start_compress(&codec, TRUE);
    while (codec.next_scanline < codec.image_height) {
      if (active_budget) active_budget->check();
      JSAMPROW row = const_cast<uint8_t *>(rgba + uint64_t(codec.next_scanline) * request.stride);
      jpeg_write_scanlines(&codec, &row, 1);
    }
    jpeg_finish_compress(&codec); jpeg_destroy_compress(&codec);
  } catch (...) { jpeg_destroy_compress(&codec); throw; }
}
void encode_webp(const uint8_t *rgba, const pki_encode_request &request, EncodedSink &sink) {
  WebPConfig config{};
  if (!WebPConfigInit(&config)) throw Failure(1, "WebP encoder ABI mismatch");
  config.lossless = request.lossless != 0; config.quality = float(request.quality);
  config.method = 3; config.thread_level = 0; config.exact = 1;
  if (!WebPValidateConfig(&config)) throw Failure(1, "Invalid WebP encoder options");
  WebPPicture picture{};
  if (!WebPPictureInit(&picture)) throw Failure(1, "WebP picture ABI mismatch");
  picture.width = int(request.width); picture.height = int(request.height);
  picture.use_argb = 1; picture.custom_ptr = &sink;
  picture.writer = [](const uint8_t *bytes, size_t count, const WebPPicture *image) -> int {
    // No exception may cross the encoder's cleanup logic. Returning 0 makes
    // WebPEncode unwind its own working arrays before we report the failure.
    try { static_cast<EncodedSink *>(image->custom_ptr)->append(bytes, count); return 1; }
    catch (...) { return 0; }
  };
  picture.progress_hook = [](int, const WebPPicture *) -> int {
    return !active_budget || !active_budget->cancel || !active_budget->cancel->load(std::memory_order_relaxed);
  };
  try {
    if (!WebPPictureImportRGBA(&picture, rgba, int(request.stride)))
      throw Failure(3, "WebP source allocation exceeds budget");
    if (!WebPEncode(&config, &picture)) {
      if (active_budget) active_budget->check();
      throw Failure(active_budget && active_budget->denied ? 3 :
        picture.error_code == VP8_ENC_ERROR_BAD_WRITE ? 3 : 1, "WebP image encoding failed");
    }
    WebPPictureFree(&picture);
  } catch (...) { WebPPictureFree(&picture); throw; }
}
uint64_t estimate_working(const char *path, const char *backing_path,
  const Info &info, uint32_t output_width, uint32_t output_height) {
  RawHeader expected = make_header(path, info);
  uint64_t bytes = kRawHeaderSize + uint64_t(expected.width) * expected.height * 4;
  uint64_t output = uint64_t(output_width) * output_height * 4;
  if (std::filesystem::exists(std::filesystem::u8path(backing_path)) &&
      std::filesystem::file_size(std::filesystem::u8path(backing_path)) == bytes) {
    File existing(backing_path, "rb"); RawHeader old{}; read_exact(existing.value, &old, sizeof(old));
    if (!memcmp(&old, &expected, sizeof(expected)))
      return output + uint64_t(expected.width) * 4 * 8 + 32 * 1024 * 1024;
  }
  return info.metadata.estimated_working_bytes + output;
}
}

extern "C" {
uint32_t pki_abi_version(void) { return 1; }
uint64_t pki_available_memory_bytes(void) {
#ifdef _WIN32
  MEMORYSTATUSEX status{}; status.dwLength = sizeof(status);
  return GlobalMemoryStatusEx(&status) ? status.ullAvailPhys : 0;
#else
  FILE *file = fopen("/proc/meminfo", "rb");
  if (!file) return 0;
  char line[256]; uint64_t available = 0;
  while (fgets(line, sizeof(line), file)) {
    unsigned long long kb = 0;
    if (sscanf(line, "MemAvailable: %llu kB", &kb) == 1) { available = uint64_t(kb) * 1024; break; }
  }
  fclose(file); return available;
#endif
}
uint64_t pki_estimate_working_bytes(const char *path, const char *backing_path,
  uint32_t output_width, uint32_t output_height) {
  try {
    if (!path || !backing_path) return 0;
    Budget budget(32 * 1024 * 1024, 0, nullptr, ""); ActiveBudget active(&budget);
    Info info = inspect(path);
    return estimate_working(path, backing_path, info, output_width, output_height);
  } catch (...) { return 0; }
}
void *pki_codec_alloc(size_t bytes) {
  if (bytes > std::numeric_limits<size_t>::max() - sizeof(Allocation)) return nullptr;
  auto *budget = active_budget;
  if (budget) {
    if (bytes > budget->limit || budget->used > budget->limit - bytes) { budget->denied = true; return nullptr; }
    budget->used += bytes; budget->peak = std::max(budget->peak, budget->used);
  }
  auto *allocation = static_cast<Allocation *>(malloc(bytes + sizeof(Allocation)));
  if (!allocation) { if (budget) { budget->used -= bytes; budget->denied = true; } return nullptr; }
  allocation->bytes = bytes; allocation->owner = budget; return allocation + 1;
}
void *pki_codec_calloc(size_t count, size_t bytes) {
  if (count && bytes > std::numeric_limits<size_t>::max() / count) return nullptr;
  auto *result = pki_codec_alloc(count * bytes); if (result) memset(result, 0, count * bytes); return result;
}
void pki_codec_free(void *pointer) {
  if (!pointer) return;
  auto *allocation = static_cast<Allocation *>(pointer) - 1;
  if (allocation->owner) allocation->owner->used -= allocation->bytes;
  free(allocation);
}
FILE *pki_coeff_file(long bytes) {
  if (!active_budget || bytes < 0) return nullptr;
  active_budget->reserve_disk(uint64_t(bytes));
  std::string path = active_budget->backing + ".coeff-" + std::to_string(active_budget->next_coefficient++);
  File file(path, "w+b"); FILE *result = file.value; file.value = nullptr;
  active_budget->coefficients.emplace(result, path); return result;
}
void pki_coeff_closed(FILE *file) {
  if (!file) return;
  fclose(file);
  if (active_budget) {
    auto found = active_budget->coefficients.find(file);
    if (found != active_budget->coefficients.end()) {
      std::error_code ignored; std::filesystem::remove(std::filesystem::u8path(found->second), ignored);
      active_budget->coefficients.erase(found);
    }
  }
}
void pki_codec_io_check(void) { if (active_budget) active_budget->check(); }
void *pki_token_create(void) { return new (std::nothrow) std::atomic<bool>(false); }
void pki_token_cancel(void *token) { if (token) static_cast<std::atomic<bool> *>(token)->store(true, std::memory_order_relaxed); }
void pki_token_destroy(void *token) { delete static_cast<std::atomic<bool> *>(token); }
int pki_probe(const char *path, pki_metadata *metadata, uint8_t *error, uint64_t error_size) {
  try {
    if (!path || !metadata) throw Failure(1, "Invalid probe request");
    Budget budget(32 * 1024 * 1024, 0, nullptr, ""); ActiveBudget active(&budget);
    *metadata = inspect(path).metadata; return 0;
  } catch (const Failure &failure) { set_error(error, error_size, failure.what()); return failure.code; }
  catch (const std::bad_alloc &) { set_error(error, error_size, "Image metadata allocation exceeds budget"); return 3; }
  catch (const std::exception &failure) { set_error(error, error_size, failure.what()); return 1; }
  catch (...) { set_error(error, error_size, "Unexpected native image probe error"); return 1; }
}
static int decode_region(const char *path, const char *backing_path,
  const pki_request *request, pki_result *result, uint8_t *error,
  uint64_t error_size, bool prepared_only) {
  if (result) memset(result, 0, sizeof(*result));
  try {
    if (!path || !backing_path || !request || !result) throw Failure(1, "Invalid region request");
    // Codec metadata uses the budgeted allocator for STL containers. Reject an
    // impossible sub-32MiB budget before constructing Info, whose debug STL
    // allocator proxy is noexcept and would otherwise terminate the process.
    if (request->memory_budget < 32ULL * 1024 * 1024)
      throw Failure(3, "Image memory budget is below the native metadata floor");
    if (!request->width || !request->height || !request->output_width || !request->output_height ||
        request->output_width > 16384 || request->output_height > 16384)
      throw Failure(3, "Region output exceeds safe image dimensions");
    Budget budget(request->memory_budget, request->disk_budget, request->cancel_token, backing_path);
    ActiveBudget active(&budget); budget.check();
    auto start = std::chrono::steady_clock::now(); Info info = inspect(path);
    if (info.metadata.animated) throw Failure(4, "Animation must use the animated image path");
    if (uint64_t(request->x) + request->width > info.metadata.width ||
        uint64_t(request->y) + request->height > info.metadata.height)
      throw Failure(1, "Region is outside orientation-normalized source");
    auto mutex = backing_mutex(backing_path);
    // Completed original-pixel layers are immutable while a shared reader holds
    // this guard. Builders and replacement retain an exclusive guard. Timed
    // acquisition wakes on unlock rather than imposing a 5 ms polling floor,
    // while preserving cancellation checks during a competing build.
    std::shared_lock<BackingMutex> reading(*mutex, std::defer_lock);
    while (!reading.try_lock_for(std::chrono::milliseconds(1))) budget.check();
    budget.check();
    const RawHeader before = make_header(path, info);
    bool backing_shared = backing_matches(backing_path, before);
    if (prepared_only && !backing_shared)
      throw Failure(5, "Prepared image backing is unavailable or stale");
    std::unique_lock<BackingMutex> building(*mutex, std::defer_lock);
    if (!backing_shared) {
      reading.unlock();
      while (!building.try_lock_for(std::chrono::milliseconds(1))) budget.check();
      budget.check();
      const RawHeader locked = make_header(path, info);
      if (memcmp(&before, &locked, sizeof(before)))
        throw Failure(1, "Original image changed while waiting for its backing");
    }
    uint64_t expected_memory = estimate_working(path, backing_path, info,
      request->output_width, request->output_height);
    uint64_t available_memory = pki_available_memory_bytes();
    uint64_t reserve = 256ULL * 1024 * 1024 + available_memory / 4;
    if (expected_memory > budget.limit ||
        (available_memory && (available_memory <= reserve || expected_memory > available_memory - reserve)))
      throw Failure(3, "Insufficient available memory for this image codec");
    uint32_t denominator = request->width / request->output_width;
    bool jpeg_sample_supported = denominator == 1
      ? request->width == request->output_width && request->height == request->output_height
      : info.metadata.orientation == 1 && denominator <= 8 && !(denominator & (denominator - 1)) &&
        request->width == request->output_width * denominator &&
        request->height == request->output_height * denominator &&
        request->x % denominator == 0 && request->y % denominator == 0;
    // libjpeg rounds each scaled source axis upward. An odd whole original
    // therefore cannot infer its IDCT denominator with integer division of
    // source/output widths. Admit only its exact ceil-sized 1/2, 1/4 or 1/8
    // whole raster; arbitrary crops and rotated/profiled sources retain the
    // existing exact region/backing paths.
    if (!jpeg_sample_supported && info.metadata.format == 1 && !info.progressive &&
      info.metadata.bit_depth == 8 && !info.metadata.has_profile && info.metadata.orientation == 1 &&
      !request->x && !request->y && request->width == info.metadata.width && request->height == info.metadata.height) {
      for (uint32_t scaled_denominator : {2U, 4U, 8U}) {
        if ((uint64_t(request->width) + scaled_denominator - 1) / scaled_denominator == request->output_width &&
          (uint64_t(request->height) + scaled_denominator - 1) / scaled_denominator == request->output_height) {
          if (has_baseline_jpeg_frame(path, budget)) {
            denominator = scaled_denominator;
            jpeg_sample_supported = true;
          }
          break;
        }
      }
    }
    bool quick_jpeg = info.metadata.format == 1 && !info.progressive && info.metadata.bit_depth == 8 &&
      jpeg_sample_supported &&
      !std::filesystem::exists(std::filesystem::u8path(backing_path));
    bool quick_png = info.metadata.format == 2 && !info.interlaced &&
      info.metadata.bit_depth <= 8 && !info.metadata.has_profile && info.metadata.orientation == 1 &&
      !request->x && !request->y && request->width == info.metadata.width && request->height == info.metadata.height &&
      request->output_width < request->width && request->output_height < request->height &&
      uint64_t(request->output_width) * request->output_height > 1 &&
      !std::filesystem::exists(std::filesystem::u8path(backing_path));
    budget.check();
    if (backing_shared) {
      const uint64_t existing_bytes = kRawHeaderSize + uint64_t(before.width) * before.height * 4;
      if (prepared_only) budget.disk = existing_bytes;
      else budget.reserve_disk(existing_bytes);
      sample_backing(backing_path, info, *request, *result, budget);
    }
    else if (quick_jpeg) quick_jpeg_region(path, info, *request, *result, budget, denominator);
    else if (quick_png) quick_png_fit(path, info, *request, *result, budget);
    else {
      ensure_backing(path, backing_path, info, budget);
      sample_backing(backing_path, info, *request, *result, budget);
    }
    budget.check();
    const RawHeader after = make_header(path, info);
    if (memcmp(&before, &after, sizeof(before)))
      throw Failure(1, "Original image changed while reading its pixels");
    result->working_peak = budget.peak; result->disk_bytes = budget.disk;
    result->elapsed_micros = uint64_t(std::chrono::duration_cast<std::chrono::microseconds>(
      std::chrono::steady_clock::now() - start).count());
    result->backend = quick_jpeg ? "libjpeg-turbo/budgeted-crop-skip"
      : quick_png ? "libpng/budgeted-stream-area-fit"
      : info.metadata.format == 2 && info.metadata.orientation == 1 &&
        request->output_width > 1 && request->output_height > 1 &&
        request->output_width < request->width && request->output_height < request->height
        ? "libpng/backing-area-fit"
      : info.metadata.format == 1 ? "libjpeg-turbo/disk-coefficients-scanlines"
      : info.metadata.format == 2 ? "libpng/disk-interlace-scanlines" : "libwebp/budgeted-disk-mapping";
    return 0;
  } catch (const Failure &failure) { pki_release(result); set_error(error, error_size, failure.what()); return failure.code; }
  catch (const std::bad_alloc &) { pki_release(result); set_error(error, error_size, "Image memory allocation failed"); return 3; }
  catch (const std::exception &failure) { pki_release(result); set_error(error, error_size, failure.what()); return 1; }
  catch (...) { pki_release(result); set_error(error, error_size, "Unexpected native image decode error"); return 1; }
}
int pki_decode_region(const char *path, const char *backing_path,
  const pki_request *request, pki_result *result, uint8_t *error, uint64_t error_size) {
  return decode_region(path, backing_path, request, result, error, error_size, false);
}
int pki_decode_prepared_region(const char *path, const char *backing_path,
  const pki_request *request, pki_result *result, uint8_t *error, uint64_t error_size) {
  return decode_region(path, backing_path, request, result, error, error_size, true);
}
void pki_release(pki_result *result) {
  if (!result) return; free(result->pixels); memset(result, 0, sizeof(*result));
}
int pki_encode_rgba(const uint8_t *rgba, const pki_encode_request *request,
  pki_encoded_result *result, uint8_t *error, uint64_t error_size) {
  if (result) memset(result, 0, sizeof(*result));
  try {
    if (!rgba || !request || !result || !request->width || !request->height ||
        request->width > 16383 || request->height > 16383 ||
        request->stride < uint64_t(request->width) * 4 ||
        request->input_bytes < uint64_t(request->stride) * request->height ||
        request->quality > 100 || request->format < 1 || request->format > 3)
      throw Failure(1, "Invalid RGBA encoder request");
    Budget budget(request->memory_budget, 0, request->cancel_token, ""); ActiveBudget active(&budget);
    budget.reserve(request->input_bytes);
    auto start = std::chrono::steady_clock::now();
    EncodedSink sink(request->output_limit);
    if (request->format == 1) encode_jpeg(rgba, *request, sink);
    else if (request->format == 2) encode_png(rgba, *request, sink);
    else encode_webp(rgba, *request, sink);
    budget.check(); result->byte_length = sink.size; result->bytes = sink.detach();
    result->working_peak = budget.peak; result->format = request->format;
    result->elapsed_micros = uint64_t(std::chrono::duration_cast<std::chrono::microseconds>(
      std::chrono::steady_clock::now() - start).count()); return 0;
  } catch (const Failure &failure) { pki_encoded_release(result); set_error(error, error_size, failure.what()); return failure.code; }
  catch (const std::bad_alloc &) { pki_encoded_release(result); set_error(error, error_size, "Image encoder memory allocation failed"); return 3; }
  catch (const std::exception &failure) { pki_encoded_release(result); set_error(error, error_size, failure.what()); return 1; }
  catch (...) { pki_encoded_release(result); set_error(error, error_size, "Unexpected image encoder error"); return 1; }
}
void pki_encoded_release(pki_encoded_result *result) {
  if (!result) return; pki_codec_free(result->bytes); memset(result, 0, sizeof(*result));
}
}
