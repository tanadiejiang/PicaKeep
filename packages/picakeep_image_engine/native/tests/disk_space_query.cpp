#include "picakeep_image_engine.h"
#include <cstdio>

// Read-only standalone query, for device-side validation without an app install.
int main(int argc, char **argv) {
  if (argc != 2) { fprintf(stderr, "Usage: pki_disk_query <absolute-path>\n"); return 1; }
  uint64_t available = 0; uint8_t volume[256]{}; uint8_t error[512]{};
  const int status = pki_query_disk_space(argv[1], &available, volume, sizeof(volume), error, sizeof(error));
  printf("status=%d\navailableBytes=%llu\nvolumeId=%s\nerror=%s\n", status,
    static_cast<unsigned long long>(available), volume, error);
  return status ? 1 : 0;
}
