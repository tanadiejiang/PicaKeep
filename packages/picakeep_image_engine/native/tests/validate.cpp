#include "picakeep_image_engine.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <chrono>
#include <vector>
#include <algorithm>
#include <filesystem>
#include "png.h"
#include "lcms2.h"
#ifndef _WIN32
#include <sys/resource.h>
#endif
int generate_png(int argc, char **argv) {
  if (argc < 7) return 1;
  uint32_t width = uint32_t(atoi(argv[3])), height = uint32_t(atoi(argv[4]));
  int depth = atoi(argv[5]), interlace = atoi(argv[6]);
  bool gray = argc > 7 && !strcmp(argv[7], "gray");
  uint32_t channels = gray ? 2 : 4;
  FILE *file = fopen(argv[2], "wb"); if (!file) return 1;
  png_structp png = png_create_write_struct(PNG_LIBPNG_VER_STRING, nullptr, nullptr, nullptr);
  png_infop info = png_create_info_struct(png);
  if (setjmp(png_jmpbuf(png))) { png_destroy_write_struct(&png, &info); fclose(file); return 1; }
  png_init_io(png, file);
  png_set_IHDR(png, info, width, height, depth, gray ? PNG_COLOR_TYPE_GRAY_ALPHA : PNG_COLOR_TYPE_RGBA,
    interlace ? PNG_INTERLACE_ADAM7 : PNG_INTERLACE_NONE,
    PNG_COMPRESSION_TYPE_DEFAULT, PNG_FILTER_TYPE_DEFAULT);
  if (argc > 7 && (!strcmp(argv[7], "icc") || gray)) {
    cmsToneCurve *gamma = gray ? cmsBuildGamma(nullptr, 2.2) : nullptr;
    cmsHPROFILE color = gray ? cmsCreateGrayProfile(cmsD50_xyY(), gamma) : cmsCreate_sRGBProfile();
    cmsUInt32Number size = 0; cmsSaveProfileToMem(color, nullptr, &size);
    std::vector<uint8_t> bytes(size); cmsSaveProfileToMem(color, bytes.data(), &size);
    png_set_iCCP(png, info, "sRGB", PNG_COMPRESSION_TYPE_BASE, bytes.data(), size);
    cmsCloseProfile(color);
    if (gamma) cmsFreeToneCurve(gamma);
  }
  png_write_info(png, info);
  int passes = png_set_interlace_handling(png);
  std::vector<uint8_t> row(uint64_t(width) * channels * (depth == 16 ? 2 : 1));
  for (int pass = 0; pass < passes; ++pass) {
    for (uint32_t y = 0; y < height; ++y) {
      for (uint32_t x = 0; x < width; ++x) {
        uint8_t rgb[4] = {uint8_t((x + y) % 256), uint8_t(((x / 48 + y / 48) % 2) * 255),
          uint8_t((x / 16 + y / 16) % 256), uint8_t((x + y) % 256)};
        for (uint32_t channel = 0; channel < channels; ++channel) {
          uint32_t color_channel = gray && channel == 1 ? 3 : channel;
          if (depth == 16) {
            uint16_t value = uint16_t(rgb[color_channel] * 257U);
            if (gray) value = uint16_t(x * 193U + y * 517U + channel * 7919U);
            row[(uint64_t(x) * channels + channel) * 2] = uint8_t(value >> 8);
            row[(uint64_t(x) * channels + channel) * 2 + 1] = uint8_t(value);
          } else row[uint64_t(x) * channels + channel] = rgb[color_channel];
        }
      }
      png_write_row(png, row.data());
    }
  }
  png_write_end(png, info); png_destroy_write_struct(&png, &info); fclose(file);
  return 0;
}
int benchmark_cover(int argc, char **argv) {
  if (argc < 3) return 1;
  for (uint32_t edge : {192U, 384U, 768U}) {
    uint32_t width = edge * 3 / 4;
    std::vector<uint8_t> rgba(uint64_t(width) * edge * 4);
    for (uint32_t y = 0; y < edge; ++y) for (uint32_t x = 0; x < width; ++x) {
      auto *pixel = rgba.data() + (uint64_t(y) * width + x) * 4;
      pixel[0] = uint8_t(x + y); pixel[1] = ((x / 8 + y / 8) % 2) ? 255 : 0;
      pixel[2] = uint8_t(x / 2 + y / 2); pixel[3] = 255;
    }
    for (uint32_t candidate = 0; candidate < 4; ++candidate) {
      pki_encode_request request{};
      request.width = width; request.height = edge; request.stride = width * 4;
      request.input_bytes = rgba.size(); request.memory_budget = 128ULL * 1024 * 1024;
      request.output_limit = 32ULL * 1024 * 1024; request.quality = 85;
      request.format = candidate == 0 ? 2 : candidate == 1 ? 1 : 3;
      request.lossless = candidate == 3;
      const char *name = candidate == 0 ? "PNG" : candidate == 1 ? "JPEG85"
        : candidate == 2 ? "WebP85" : "WebP-lossless";
      std::vector<uint64_t> samples;
      uint64_t bytes = 0, peak = 0;
      for (int i = 0; i < 31; ++i) {
        pki_encoded_result result{}; uint8_t error[512]{};
        int status = pki_encode_rgba(rgba.data(), &request, &result, error, sizeof(error));
        if (status) { fprintf(stderr, "encode failed %s: %d %s\n", name, status, error); return status; }
        if (i) samples.push_back(result.elapsed_micros);
        bytes = result.byte_length; peak = std::max(peak, result.working_peak);
        if (i == 30) {
          std::string path = std::string(argv[2]) + "/cover-" + std::to_string(edge) + "-" + name + ".bin";
          FILE *file = fopen(path.c_str(), "wb");
          if (!file) { pki_encoded_release(&result); return 1; }
          fwrite(result.bytes, 1, size_t(result.byte_length), file); fclose(file);
        }
        pki_encoded_release(&result);
      }
      std::sort(samples.begin(), samples.end());
      printf("cover edge=%u format=%s bytes=%llu encode_p50_us=%llu encode_p95_us=%llu peak=%llu\n",
        edge, name, (unsigned long long)bytes, (unsigned long long)samples[15],
        (unsigned long long)samples[28], (unsigned long long)peak);
      fflush(stdout);
    }
  }
  return 0;
}
int benchmark_decode(int argc, char **argv) {
  if (argc < 4) return 1;
  pki_metadata metadata{}; uint8_t error[512]{};
  int status=pki_probe(argv[2],&metadata,error,sizeof(error));
  if(status) { fprintf(stderr,"probe %d %s\n",status,error); return status; }
  std::filesystem::path root=std::filesystem::u8path(argv[3]);
  if(!root.is_absolute() || root.filename().string().find("picakeep") == std::string::npos) {
    fprintf(stderr,"benchmark needs an absolute task-owned picakeep directory\n");return 1;
  }
  std::filesystem::create_directories(root);
  auto warm_path=(root/"warm.raw").u8string();
  std::vector<uint64_t> full_times,cold_times,warm_times;
  uint64_t full_peak=0,cold_peak=0,warm_peak=0;
  int repeats=argc>4?atoi(argv[4]):30;
  for(int iteration=0;iteration<repeats+1;++iteration) {
    auto full_path=(root/("full-"+std::to_string(iteration)+".raw")).u8string();
    auto cold_path=(root/("region-"+std::to_string(iteration)+".raw")).u8string();
    pki_request req{};
    req.width=metadata.width;req.height=metadata.height;
    req.output_width=req.width;req.output_height=req.height;
    req.memory_budget=896ULL*1024*1024;req.disk_budget=1536ULL*1024*1024;
    pki_result full{};
    status=pki_decode_region(argv[2],full_path.c_str(),&req,&full,error,sizeof(error));
    if(status) { fprintf(stderr,"full %d %s\n",status,error);return status; }
    uint32_t w=std::min(metadata.width,512U),h=std::min(metadata.height,512U);
    uint32_t x=(metadata.width-w)/2,y=metadata.height-h;
    std::vector<uint8_t> golden(uint64_t(w)*h*4);
    for(uint32_t row=0;row<h;++row)
      memcpy(golden.data()+uint64_t(row)*w*4,full.pixels+(uint64_t(y+row)*metadata.width+x)*4,uint64_t(w)*4);
    if(iteration)full_times.push_back(full.elapsed_micros);
    full_peak=std::max(full_peak,full.working_peak);pki_release(&full);
    std::error_code ignored;std::filesystem::remove(std::filesystem::u8path(full_path),ignored);
    req.x=x;req.y=y;req.width=w;req.height=h;req.output_width=w;req.output_height=h;
    pki_result region{};
    status=pki_decode_region(argv[2],cold_path.c_str(),&req,&region,error,sizeof(error));
    if(status) { fprintf(stderr,"cold %d %s\n",status,error);return status; }
    if(region.byte_length!=golden.size() || memcmp(region.pixels,golden.data(),golden.size())) {
      fprintf(stderr,"cold ROI differs from same-codec whole image\n");pki_release(&region);return 1;
    }
    if(iteration)cold_times.push_back(region.elapsed_micros);
    cold_peak=std::max(cold_peak,region.working_peak);pki_release(&region);
    std::filesystem::remove(std::filesystem::u8path(cold_path),ignored);
    if(iteration==0) {
      pki_request prepare=req;prepare.x=prepare.y=0;prepare.width=metadata.width;prepare.height=metadata.height;
      prepare.output_width=prepare.output_height=1;
      status=pki_decode_region(argv[2],warm_path.c_str(),&prepare,&region,error,sizeof(error));
      if(status) { fprintf(stderr,"prepare %d %s\n",status,error);return status; }pki_release(&region);
    }
    status=pki_decode_region(argv[2],warm_path.c_str(),&req,&region,error,sizeof(error));
    if(status) { fprintf(stderr,"warm %d %s\n",status,error);return status; }
    if(region.byte_length!=golden.size() || memcmp(region.pixels,golden.data(),golden.size())) {
      fprintf(stderr,"warm ROI differs from same-codec whole image\n");pki_release(&region);return 1;
    }
    if(iteration)warm_times.push_back(region.elapsed_micros);
    warm_peak=std::max(warm_peak,region.working_peak);pki_release(&region);
  }
  auto report=[&](const char*name,std::vector<uint64_t>&times,uint64_t peak) {
    std::sort(times.begin(),times.end());
    printf("decode source=%ux%u format=%u mode=%s samples=%zu p50_us=%llu p95_us=%llu tracked_peak=%llu same_codec_roi_error=0\n",
      metadata.width,metadata.height,metadata.format,name,times.size(),
      (unsigned long long)times[times.size()/2],(unsigned long long)times[size_t(times.size()*.95)],(unsigned long long)peak);
  };
  report("whole-source-cold",full_times,full_peak);report("region-source-cold",cold_times,cold_peak);report("region-backing-warm",warm_times,warm_peak);
  std::error_code ignored;std::filesystem::remove(std::filesystem::u8path(warm_path),ignored);
  return 0;
}
int failure_regression(int argc, char **argv) {
  if (argc < 5) return 1;
  auto root = std::filesystem::u8path(argv[4]);
  if (!root.is_absolute() || root.filename().string().find("picakeep") == std::string::npos) return 1;
  std::filesystem::create_directories(root);
  auto damage = [&](const char *source, const char *name, bool jpeg) {
    FILE *file = fopen(source, "rb"); if (!file) return std::string{};
    fseek(file, 0, SEEK_END); auto length = ftell(file); rewind(file);
    std::vector<uint8_t> bytes(static_cast<size_t>(length));
    auto count = fread(bytes.data(), 1, bytes.size(), file); fclose(file);
    if (count != bytes.size() || bytes.size() < 100) return std::string{};
    if (jpeg) bytes.resize(80); else bytes[bytes.size() / 2] ^= 0x7f;
    auto output = (root / name).u8string(); file = fopen(output.c_str(), "wb");
    if (!file) return std::string{};
    fwrite(bytes.data(), 1, bytes.size(), file); fclose(file); return output;
  };
  auto jpeg = damage(argv[2], "damaged.jpg", true), png = damage(argv[3], "damaged.png", false);
  if (jpeg.empty() || png.empty()) return 1;
  auto backing = (root / "failure.raw").u8string();
  pki_request request{}; request.width = request.height = request.output_width = request.output_height = 64;
  request.memory_budget = 64ULL << 20; request.disk_budget = 64ULL << 20;
  for (int iteration = 0; iteration < 20; ++iteration) for (const auto &source : {jpeg, png}) {
    pki_result result{}; uint8_t error[512]{};
    int status = pki_decode_region(source.c_str(), backing.c_str(), &request, &result, error, sizeof(error));
    if (status == 0 || result.pixels) { fprintf(stderr, "Malformed source did not fail safely\n"); pki_release(&result); return 1; }
    pki_release(&result);
  }
  pki_result result{}; uint8_t error[512]{};
  request.memory_budget = 1024;
  if (pki_decode_region(argv[3], backing.c_str(), &request, &result, error, sizeof(error)) != 3 || result.pixels) return 1;
  request.memory_budget = 64ULL << 20; request.cancel_token = pki_token_create(); pki_token_cancel(request.cancel_token);
  int status = pki_decode_region(argv[3], backing.c_str(), &request, &result, error, sizeof(error));
  pki_token_destroy(request.cancel_token); request.cancel_token = nullptr;
  if (status != 2 || result.pixels) return 1;
  for (const auto &entry : std::filesystem::directory_iterator(root)) {
    auto name = entry.path().filename().u8string();
    if (name.find("partial") != std::string::npos || name.find("coeff") != std::string::npos || name == "failure.raw") {
      fprintf(stderr, "Error cleanup left workspace %s\n", name.c_str()); return 1;
    }
  }
  std::error_code ignored; std::filesystem::remove(std::filesystem::u8path(jpeg), ignored);
  std::filesystem::remove(std::filesystem::u8path(png), ignored);
  printf("PASS 40 malformed JPEG/PNG requests; budget=3 cancellation=2; null output, safe release, no partial/coeff/backing residual\n");
#ifndef _WIN32
  struct rusage usage{}; getrusage(RUSAGE_SELF, &usage);
  printf("process_peak_rss_bytes=%llu\n", static_cast<unsigned long long>(usage.ru_maxrss) * 1024ULL);
#endif
  return 0;
}
int benchmark_fit(int argc, char **argv) {
  if (argc < 6) return 1;
  pki_metadata meta{}; uint8_t error[512]{};
  int status = pki_probe(argv[2], &meta, error, sizeof(error)); if (status) return status;
  auto root = std::filesystem::u8path(argv[3]);
  if (!root.is_absolute() || root.filename().string().find("picakeep") == std::string::npos) return 1;
  std::filesystem::create_directories(root);
  auto backing = (root / "fit.raw").u8string();
  uint32_t width = uint32_t(atoi(argv[4])), height = uint32_t(atoi(argv[5]));
  int repeats = argc > 6 ? atoi(argv[6]) : 5;
  pki_request req{}; req.width = meta.width; req.height = meta.height;
  req.memory_budget = 896ULL << 20; req.disk_budget = 1536ULL << 20;
  std::error_code ignored;
  for (const char *mode : {"fit-cold", "prepare-raw", "fit-warm"}) {
    std::vector<uint64_t> times; uint64_t peak = 0, disk = 0;
    for (int i = 0; i < repeats; ++i) {
      if (strcmp(mode, "fit-warm")) std::filesystem::remove(std::filesystem::u8path(backing), ignored);
      req.output_width = !strcmp(mode, "prepare-raw") ? 1 : width;
      req.output_height = !strcmp(mode, "prepare-raw") ? 1 : height;
      pki_result result{};
      status = pki_decode_region(argv[2], backing.c_str(), &req, &result, error, sizeof(error));
      if (status) { fprintf(stderr, "fit %d %s\n", status, error); return status; }
      if (i == 0 && strcmp(mode, "prepare-raw")) {
        auto path = (root / (std::string(mode) + ".rgba")).u8string();
        FILE *file = fopen(path.c_str(), "wb"); if (!file) { pki_release(&result); return 1; }
        fwrite(result.pixels, 1, size_t(result.byte_length), file); fclose(file);
      }
      times.push_back(result.elapsed_micros); peak = std::max(peak, result.working_peak); disk = std::max(disk, result.disk_bytes);
      if (i == 0) printf("fit mode=%s backend=%s\n", mode, result.backend);
      pki_release(&result);
    }
    std::sort(times.begin(), times.end());
    printf("fit source=%ux%u output=%ux%u mode=%s samples=%d p50_us=%llu p95_us=%llu peak=%llu disk=%llu\n",
      meta.width, meta.height, width, height, mode, repeats, static_cast<unsigned long long>(times[times.size()/2]),
      static_cast<unsigned long long>(times[size_t(times.size()*.95)]), static_cast<unsigned long long>(peak), static_cast<unsigned long long>(disk));
    fflush(stdout);
  }
  std::filesystem::remove(std::filesystem::u8path(backing), ignored);
  return 0;
}
int main(int argc, char **argv) {
  if (argc > 1 && !strcmp(argv[1], "--png-fixture")) return generate_png(argc, argv);
  if (argc > 1 && !strcmp(argv[1], "--cover-benchmark")) return benchmark_cover(argc, argv);
  if (argc > 1 && !strcmp(argv[1], "--decode-benchmark")) return benchmark_decode(argc, argv);
  if (argc > 1 && !strcmp(argv[1], "--failure-regression")) return failure_regression(argc, argv);
  if (argc > 1 && !strcmp(argv[1], "--fit-benchmark")) return benchmark_fit(argc, argv);
  if (argc < 3) {
    fprintf(stderr, "usage: pki_validate input backing [budgetMiB] [output.rgba]\n");
    return 1;
  }
  uint64_t available_before = pki_available_memory_bytes();
  pki_metadata metadata{}; uint8_t error[512]{};
  int status = pki_probe(argv[1], &metadata, error, sizeof(error));
  if (status) { fprintf(stderr, "probe failed (%d): %s\n", status, error); return status; }
  printf("source %ux%u encoded %ux%u format=%u orientation=%u bitDepth=%u ICC=%u animated=%u\n",
    metadata.width, metadata.height, metadata.encoded_width, metadata.encoded_height,
    metadata.format, metadata.orientation, metadata.bit_depth, metadata.has_profile, metadata.animated);
  pki_request request{};
  request.width = std::min(metadata.width, 512U);
  request.height = std::min(metadata.height, 512U);
  request.x = (metadata.width - request.width) / 2;
  request.y = metadata.height - request.height;
  request.output_width = request.width; request.output_height = request.height;
  request.memory_budget = uint64_t(argc > 3 ? atoi(argv[3]) : 384) * 1024 * 1024;
  request.disk_budget = 1536ULL * 1024 * 1024;
  pki_result result{};
  for (int i = 0; i < 2; ++i) {
    status = pki_decode_region(argv[1], argv[2], &request, &result, error, sizeof(error));
    if (status) { fprintf(stderr, "decode failed (%d): %s\n", status, error); return status; }
    uint64_t hash = 1469598103934665603ULL;
    for (uint64_t j = 0; j < result.byte_length; ++j) { hash ^= result.pixels[j]; hash *= 1099511628211ULL; }
    printf("%s ROI %u,%u %ux%u out=%ux%u peak=%llu disk=%llu us=%llu hash=%016llx backend=%s\n",
      i == 0 ? "cold" : "warm", request.x, request.y, request.width, request.height,
      result.width, result.height, (unsigned long long)result.working_peak,
      (unsigned long long)result.disk_bytes, (unsigned long long)result.elapsed_micros,
      (unsigned long long)hash, result.backend);
    if (i == 0 && argc > 4) {
      FILE *output = fopen(argv[4], "wb");
      if (!output) return 1;
      fwrite(result.pixels, 1, (size_t)result.byte_length, output); fclose(output);
    }
    pki_release(&result);
  }
  // Deterministic resource/cancellation terminal states never crash or leave
  // a result buffer behind, including already prepared sources.
  request.memory_budget = 1024;
  status = pki_decode_region(argv[1], argv[2], &request, &result, error, sizeof(error));
  if (status != 3 || result.pixels) { fprintf(stderr, "budget contract failed: %d\n", status); return 1; }
  request.memory_budget = 384ULL * 1024 * 1024;
  request.cancel_token = pki_token_create(); pki_token_cancel(request.cancel_token);
  status = pki_decode_region(argv[1], argv[2], &request, &result, error, sizeof(error));
  pki_token_destroy(request.cancel_token);
  if (status != 2 || result.pixels) { fprintf(stderr, "cancel contract failed: %d\n", status); return 1; }
  printf("budget/cancellation/release passed\n");
#ifndef _WIN32
  struct rusage usage{};
  getrusage(RUSAGE_SELF, &usage);
  printf("process_peak_rss_bytes=%llu memory_available_before=%llu after=%llu\n",
    (unsigned long long)(uint64_t(usage.ru_maxrss) * 1024),
    (unsigned long long)available_before,
    (unsigned long long)pki_available_memory_bytes());
#else
  printf("memory_available_before=%llu after=%llu\n",
    (unsigned long long)available_before,
    (unsigned long long)pki_available_memory_bytes());
#endif
  return 0;
}
