/* IJG memory-system extension point. The codec remains upstream code. */
#define JPEG_INTERNALS
#include "jinclude.h"
#include "jpeglib.h"
#include "jmemsys.h"
#include "picakeep_image_engine.h"

GLOBAL(void *) jpeg_get_small(j_common_ptr info, size_t bytes) {
  (void)info;
  return pki_codec_alloc(bytes);
}
GLOBAL(void) jpeg_free_small(j_common_ptr info, void *pointer, size_t bytes) {
  (void)info; (void)bytes;
  pki_codec_free(pointer);
}
GLOBAL(void *) jpeg_get_large(j_common_ptr info, size_t bytes) {
  (void)info;
  return pki_codec_alloc(bytes);
}
GLOBAL(void) jpeg_free_large(j_common_ptr info, void *pointer, size_t bytes) {
  (void)info; (void)bytes;
  pki_codec_free(pointer);
}
GLOBAL(size_t) jpeg_mem_available(j_common_ptr info, size_t minimum,
  size_t maximum, size_t allocated) {
  size_t budget = (size_t)info->mem->max_memory_to_use;
  (void)minimum;
  if (budget <= allocated) return 0;
  return budget - allocated < maximum ? budget - allocated : maximum;
}
static void read_store(j_common_ptr info, backing_store_ptr store,
  void *buffer, long offset, long count) {
  pki_codec_io_check();
#ifdef _WIN32
  if (_fseeki64(store->temp_file, offset, SEEK_SET) != 0)
#else
  if (fseeko(store->temp_file, offset, SEEK_SET) != 0)
#endif
    ERREXIT(info, JERR_TFILE_SEEK);
  if (fread(buffer, 1, (size_t)count, store->temp_file) != (size_t)count)
    ERREXIT(info, JERR_TFILE_READ);
}
static void write_store(j_common_ptr info, backing_store_ptr store,
  void *buffer, long offset, long count) {
  pki_codec_io_check();
#ifdef _WIN32
  if (_fseeki64(store->temp_file, offset, SEEK_SET) != 0)
#else
  if (fseeko(store->temp_file, offset, SEEK_SET) != 0)
#endif
    ERREXIT(info, JERR_TFILE_SEEK);
  if (fwrite(buffer, 1, (size_t)count, store->temp_file) != (size_t)count)
    ERREXIT(info, JERR_TFILE_WRITE);
}
static void close_store(j_common_ptr info, backing_store_ptr store) {
  (void)info;
  pki_coeff_closed(store->temp_file);
  store->temp_file = NULL;
}
GLOBAL(void) jpeg_open_backing_store(j_common_ptr info, backing_store_ptr store,
  long bytes) {
  store->temp_file = pki_coeff_file(bytes);
  if (!store->temp_file) ERREXIT(info, JERR_TFILE_CREATE);
  store->read_backing_store = read_store;
  store->write_backing_store = write_store;
  store->close_backing_store = close_store;
}
GLOBAL(long) jpeg_mem_init(j_common_ptr info) {
  (void)info; return 16L * 1024L * 1024L;
}
GLOBAL(void) jpeg_mem_term(j_common_ptr info) { (void)info; }
