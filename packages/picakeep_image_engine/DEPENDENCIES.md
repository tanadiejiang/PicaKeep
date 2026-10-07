# Native codec sources

These archives are pinned in native/CMakeLists.txt and verified by SHA-256.
Builds extract them into their own build directory and need no network fetch.
The complete upstream license and patent notices remain inside each archive.

| Archive | SHA-256 | License / original source |
| --- | --- | --- |
| libjpeg-turbo 3.1.3 | 3a13a5ba767dc8264bc40b185e41368a80d5d5f945944d1dbaa4b2fb0099f4e5 | IJG / BSD / zlib; https://github.com/libjpeg-turbo/libjpeg-turbo/tree/3.1.3 |
| libpng 1.6.59 | 2540302a1844ad2b2b501977abecfa850f265f97b78f065a712ab4074a89f5b5 | PNG Reference Library License v2; https://github.com/pnggroup/libpng/tree/v1.6.59 |
| zlib 1.3.1 | 17e88863f3600672ab49182f217281b6fc4d3c762bde361935e436a95214d05c | zlib; https://github.com/madler/zlib/tree/v1.3.1 |
| libwebp 1.6.0 | 93a852c2b3efafee3723efd4636de855b46f9fe1efddd607e1f42f60fc8f2136 | BSD + PATENTS; https://github.com/webmproject/libwebp/tree/v1.6.0 |
| Little CMS 2.17 | 6e6f6411db50e85ae8ff7777f01b2da0614aac13b7b9fcbea66dc56a1bc71418 | MIT; https://github.com/mm2/Little-CMS/tree/lcms2.17 |
| NASM 2.16.03 Windows x64 build tool | 3ee4782247bcb874378d02f7eab4e294a84d3d15f3f6ee2de2f47a46aa7226e6 | BSD; https://www.nasm.us/pub/nasm/releasebuilds/2.16.03/win64/ |

libjpeg-turbo uses the documented IJG system-memory adapter in jpeg_memory.c;
progressive coefficient arrays can spill to temporary files. Its CMake root
variables receive a reproducible subproject integration patch, with tools and
upstream tests disabled. Codec algorithms are unchanged.

libwebp's existing WebPSafeMalloc / WebPSafeCalloc / WebPSafeFree boundary is
redirected to the request-local budget. The generated adapter is inside each
build directory; upstream source and codec algorithms remain unchanged.

NASM is extracted only inside the build directory and enables Windows JPEG
SIMD. It is never installed system-wide or bundled in the application.

The raw backing is straight-alpha, orientation-normalized on region sampling,
and color-normalized to sRGB8 once. ICC RGB profiles use Little CMS before
quantization. Source files are always opened read-only. RGB and gray ICC
transforms use request-budgeted Little CMS contexts. Interlaced 16-bit ICC uses
an extra 8-byte/pixel disk staging file; transform before 8-bit quantization.
High-precision JPEG currently returns unsupported to the compatible source
path; animations never enter this static decoder. Wide-gamut/HDR displays must
retain their compatible higher-precision renderer rather than treating sRGB8
as an HDR-equivalent output.

WebP is not claimed to have viewport-sized decoder memory. Its mapped input,
mapped RGBA output and internal allocations are conservatively admitted and
charged. 96MP lossless may need about 736MiB; reject insufficient memory rather
than silently decode unbounded. JPEG / PNG raw output goes to sequential disk
rows and uses a small row working set. First preparation processes the image;
warm regions use the persistent exact pixel backing.

Application code owns source leases, task concurrency, disk quotas and backing
eviction. The decoder protects a shared backing with a process-local mutex,
validates source size/mtime/header fingerprint, rechecks before publication,
publishes a completed .partial by rename, and deletes transient coefficients.
Explicit source refresh should change the backing identity; a header sample
and file metadata are not a whole-content cryptographic fingerprint.
