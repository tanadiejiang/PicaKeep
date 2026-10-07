#ifndef PICAKEEP_IMAGE_ENGINE_H
#define PICAKEEP_IMAGE_ENGINE_H
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#if defined(_WIN32) && defined(PKI_EXPORTS)
#define PKI_API __declspec(dllexport)
#elif defined(_WIN32)
#define PKI_API __declspec(dllimport)
#else
#define PKI_API __attribute__((visibility("default")))
#endif
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
  uint32_t width, height, encoded_width, encoded_height, format, orientation;
  uint32_t animated, bit_depth, has_profile;
  uint64_t estimated_working_bytes;
} pki_metadata;
typedef struct {
  uint32_t x, y, width, height, output_width, output_height;
  uint64_t memory_budget, disk_budget;
  void *cancel_token;
} pki_request;
typedef struct {
  uint8_t *pixels;
  uint64_t byte_length;
  uint32_t width, height, stride;
  uint64_t working_peak, disk_bytes, elapsed_micros;
  const char *backend;
} pki_result;
typedef struct {
  uint32_t width, height, stride, format, quality, lossless;
  uint64_t input_bytes, memory_budget, output_limit;
  void *cancel_token;
} pki_encode_request;
typedef struct {
  uint8_t *bytes;
  uint64_t byte_length, working_peak, elapsed_micros;
  uint32_t format;
} pki_encoded_result;
PKI_API uint32_t pki_abi_version(void);
PKI_API uint64_t pki_available_memory_bytes(void);
/* Read-only capacity of the actual target volume, or nearest existing ancestor.
 * 0 succeeds (available_bytes may be zero); 1 is a query/argument failure;
 * 4 means unsupported platform/volume identity. Outputs clear on failure. */
PKI_API int pki_query_disk_space(const char *path, uint64_t *available_bytes,
  uint8_t *volume_id, uint64_t volume_id_size, uint8_t *error, uint64_t error_size);
PKI_API int pki_available_disk_bytes(const char *path, uint64_t *available_bytes,
  uint8_t *error, uint64_t error_size);
PKI_API uint64_t pki_estimate_working_bytes(const char *path,
  const char *backing_path, uint32_t output_width, uint32_t output_height);
PKI_API int pki_probe(const char *path, pki_metadata *metadata,
                     uint8_t *error, uint64_t error_size);
PKI_API int pki_decode_region(const char *path, const char *backing_path,
  const pki_request *request, pki_result *result, uint8_t *error,
  uint64_t error_size);
/* Additive ABI-1 read-only feature. A validated complete backing is required.
 * Status 5 means missing/stale/invalid backing; it never builds or replaces it.
 * disk_budget may be zero: disk_bytes reports existing backing occupancy. */
PKI_API int pki_decode_prepared_region(const char *path, const char *backing_path,
  const pki_request *request, pki_result *result, uint8_t *error,
  uint64_t error_size);
PKI_API void pki_release(pki_result *result);
PKI_API int pki_encode_rgba(const uint8_t *rgba, const pki_encode_request *request,
  pki_encoded_result *result, uint8_t *error, uint64_t error_size);
PKI_API void pki_encoded_release(pki_encoded_result *result);
PKI_API void *pki_token_create(void);
PKI_API void pki_token_cancel(void *token);
PKI_API void pki_token_destroy(void *token);

/* Codec system adapter hooks, thread-local to the current decode request. */
void *pki_codec_alloc(size_t bytes);
void *pki_codec_calloc(size_t count, size_t bytes);
void pki_codec_free(void *pointer);
FILE *pki_coeff_file(long bytes);
void pki_coeff_closed(FILE *file);
void pki_codec_io_check(void);
#ifdef __cplusplus
}
#endif
#endif
