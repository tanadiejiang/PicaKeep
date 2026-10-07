# Prepared backing read candidate

## Scope

This is an opt-in candidate for an already complete original-pixel backing. It
does not change the source file, pixel coordinates, filtering, alpha handling,
or the existing writer path. The normal `pki_decode_region` entry remains the
full read/prepare path. The optional `pki_decode_prepared_region` entry validates
the source snapshot and the immutable raw header under the shared backing lock,
then samples the backing directly.

The prepared entry is intentionally fail-closed:

- status `5` means the backing is missing, stale, corrupt, or otherwise not a
  valid exact match; the Dart backend then performs the normal, fully admitted
  path;
- status `3`, cancellation (`2`), source changes, bounds errors, and all other
  errors are propagated and are never converted into a write attempt;
- disk budget `0` is valid only for this read-only entry, and the result reports
  existing raw occupancy rather than reserving new disk space;
- the source and backing file leases, scheduler memory budget, cancellation
  borrower, and native result ownership live until the native call and any
  Flutter image creation have finished.

The symbol is optional so an older DLL keeps the original path. The product
default is `false`; profile harnesses must state `prepared-read=true` to measure
it. This candidate does not claim that Surface's first backing admission or
metadata estimation disappears, nor that Flutter upload/raster time is solved.

## Evidence

The Windows Debug native verification completed with DLL SHA-256
`039E09EAE0A232418865E7F308637712C9AAED2ACDEFC7A59AB75225B09114B4`:

- 22 source-coordinate format/orientation/alpha/ICC/tile/cancel/budget cases
  matched the original pixels; no source or backing mutation was observed;
- concurrent prepared reads returned exact pixels and left no `.partial` or
  coefficient residue;
- native status cases covered valid, missing, corrupt, truncated, stale,
  cancelled, low budget, bounds, and repeated concurrent access; the Dart API
  additionally rejects negative prepared-read budgets before the FFI call;
- Flutter backend tests covered exact prepared pixels with write-admission
  failure injected, status-5 fallback with late `ui.Image` cancellation and
  disposal, non-miss error propagation, and an older DLL without the symbol;
- the worker lifecycle report covered bounded startup failure, queue capacity
  and cancellation, mixed startup recovery, pre-FFI and post-cleanup worker
  exit, with final active jobs, queue, and workers at zero.

The exact pixel regression was rerun against the final DLL (`verify_pixels.py`:
22 successful records). Dart analyzer reported no issues for the engine,
backend, Page, profile harness, and prepared-read tests.

Small reports and original diagnostic logs are retained beside this document:

| Evidence | Result |
| --- | --- |
| `native-prepared-read-verification.json` | 22 exact prepared reads plus miss/stale/corrupt/low-budget/cancel/concurrent checks; 30 concurrent exact samples |
| `native-prepared-worker-test.json` | 4 completed, 5 expected failed: code 5 = 1, code 3 = 3, code 2 = 1; other = 0 |
| `native-prepared-worker-lifecycle.json` | Six bounded fault groups; each final alive/active/queue = 0; non-native errors classified separately |
| `native-prepared-backend-test.log` | Three new-symbol tests passed, including 0/1/1024-byte budgets; one old-symbol test skipped |
| `native-prepared-old-symbol-test.log` | One old-symbol fallback test passed; new-symbol tests skipped |
| `native-prepared-pixel-regression.json` | 22 existing independent decoder regression records |
| `native-prepared-final-analyze.log` | No issues found |

## Low-budget crash correction

The earlier Windows popups were not codec corruption or an FFI unwind bug. A
Debug MSVC `std::vector` constructed `Info`'s hidden iterator proxy in a
`noexcept` allocator path before the native `Failure(3)` could reach the C ABI.
The process therefore terminated for memory budgets `0`/`1` instead of returning
the expected error. A process-local no-GUI probe captured the stack at
`std::_Container_base12::_Alloc_proxy` → `Info` construction → `decode_region`.

The native entry now rejects budgets below the existing 32 MiB metadata floor
before constructing codec metadata. The DLL target also uses
`_ITERATOR_DEBUG_LEVEL=0` in Debug, keeping the real budget allocator and Debug
runtime while removing this MSVC-only hidden proxy allocation. All C++ TUs in
the DLL use the same setting; the exported ABI contains only C structs,
pointers, and integers, and the linked codec dependencies are C, so no STL
object crosses the DLL boundary. This reduces Debug iterator diagnostics inside
this target and must be revisited if a future C++ STL type is exported.

The no-GUI regressions passed for both original and prepared entries at
`0`/`1`/`1024`-byte budgets, exhausted metadata default/move and real
allocator failures, 40 MiB APP1 metadata pressure, and JPEG/PNG/WebP encoder
low budgets. They exited normally with status `3`; no host abort occurred.

The original failing probe is preserved in
`native-prepared-budget-crash-original.log`, with the nonzero terminate result;
it must not be treated as a passing candidate. Corrected evidence is in
`native-prepared-low-budget.json`, `native-prepared-exhausted-stl.log`,
`native-prepared-metadata-pressure.log`, and
`native-prepared-exhausted-encode.log`. Diagnostic executables disabled dialogs
only in their own process, retained error output, and made unexpected fatal
termination nonzero. No global CRT/WER settings were changed.

## Frozen files

Production and profile-harness edits stopped before the parent task's unified
snapshot. The following SHA-256 values identify this implementation:

| File | SHA-256 |
| --- | --- |
| `native/src/image_core.cpp` | `9110413eeae496707cdf3239c4f4371bbe060c42430976ee3e79613824834087` |
| `native/src/disk_space.cpp` | `d32b5eb924d799f6470839ec7a82fc4ffb7c1297903518a548eed9a217c0cfc1` |
| `native/include/picakeep_image_engine.h` | `a3ca0b7cb87e95b79fe661cffb8c821427098c393086ce596f642e2a47c2aad1` |
| `native/CMakeLists.txt` | `c02d4daf671e98962463146a4b2a156d33da816d158dbad81e272a0b54cf8611` |
| `lib/picakeep_image_engine.dart` | `fa69db72e7c33d8b9e107e1410e003f53bc39c7f13bad913c1074ac7a29ed914` |
| `lib/src/bindings.dart` | `873f8a5f42b02a304ca44b5497a587eb7aaef6adc36a53a0b8bc16c9f544e887` |
| `lib/src/worker_pool.dart` | `0780a2169c4b2c27e88f91e02b3e8c200efe08cd33f53f2c80b2fd64c8863175` |
| `reader_raster_backend.dart` | `e0df476b1aa7b6b210447fdc43c600f0c5e6b120873639465f977dce231c648c` |
| `reader_page_image.dart` | `ecb6ee103504251a05d52c4c7cc75984c3cff52643c17c4f922fead070ce1e6a` |
| `image_pipeline_022_profile_main.dart` | `01bdeb49b483b7e6fc199deeac81cf94bdeb71dd494fbd557af9b473e54ce13a` |
| `image_pipeline_022_surface_quality_checks.dart` | `aefe7504fe48939a5eab449e9213e89774e495417d0278846c8837737c0b0464` |

The first seven paths are relative to `packages/picakeep_image_engine`.
Independent Windows Debug build/configuration logs remain in
`E:/picakeep-image-pipeline-022-work/prepared-read-allocator-build.log`, and the
DLL remains under `prepared-read-native-build/Debug/picakeep_image_engine.dll`.
The source fixtures are at `E:/picakeep-image-pipeline-022-fixtures`.

## Android quality evidence with the candidate

`reader-flat-v2-prepared-quality-redmi-66.json` is the first final physical-v2
Android run with `preparedBackingReadCandidate=true`, `rawSync=false`, and
`persistRaster=true` (profile, DPR 2.75, 1080x2270 view). It completed from
2026-10-06T06:47:29Z to 06:48:41Z with no harness errors:

- 66/66 Surface quality cases matched a real raster frame and had exact RGBA
  readback (`differentPixels=0`, `differentChannels=0`); all 66 source SHA
  values matched after the case;
- the cases cover center/partial-tile/cache-repeat checks across 22 PNG/JPEG/
  WebP/static long/orientation/alpha fixtures, including 8000x12000 and
  800x30000 sources; all presented frames were complete, density 1, and native;
- raster diagnostics recorded 228 prepared attempts: 116 successful
  read-only uses and 112 status-5 misses. The final worker diagnostic therefore
  reports `jobsFailedCode5=112`, `jobsFailedNonNative=0`, and no cancellations;
  these are expected fail-closed misses, not UI failures;
- final Surface, scheduler, resident, temporary, source-lease, pending raster,
  and disk quota counters were all zero. Two idle native workers remained alive
  after reader cleanup; this is not a claim that all threads were destroyed;
- all three application-UID disk queries succeeded on logical volume
  `posix-device:66322`, with about 93.37 GB available, and the nonexistent
  child path was not created.

This report runs only `surface-quality`, `surface-cache-quality`, and
`disk-space`; it has no timed fit/ROI samples, export/source-copy checks,
format workflow, or texture-capacity group. It proves exact pixels and the
prepared-read lifecycle on this Android snapshot, not the 100--200 ms ROI
target, ordinary first-raster speed, wide-gamut/HDR behavior, OS scanout, or
all product workflows. The report SHA-256 is
`e76a200920330e3a6e8d24fca2251079deb38e03ec2e8ba7767e395410639b07`.

The matching Windows physical-v2 quality/format run is
`reader-flat-v2-quality-formats-windows.json` (SHA-256
`0285a46ed34b0205d9d36f6ca920227ebea6849744e4faf0667b302dda34706a`). It
completed with 66/66 exact quality cases and unchanged sources, plus 132/132
format cases (22 fixtures x 3 layouts x 2 modes). All 132 native steps matched
real raster frames; 80 reused an already complete density-1 native frame as a
non-timed format step and 52 were actual timed ROI steps. It had no missing
raster samples and no format errors. Its final internal resident, scheduler,
lease, persistence, and quota counters were zero; 2 idle workers remained.
The Windows run recorded 372 prepared attempts, 198 uses, and 174 status-5
misses. It is quality/format evidence, not a speed N30; its format samples use
`samples=1` and the candidate remains default-off.

The copied Windows runner used for the subsequent paired speed run contains no
reparse links (45 ordinary files, 41,625,108 bytes): executable
`e0ee4da717332e62419216d4450dcbe359d37770da6d1424dda01f9ed1c420f0`, Dart
`data/app.so` `cab50bc899541e9511b61302c323042768f192cca77c7cb3eb5732f31fb53128`,
and native DLL
`3069a410228201b128079e33df0c586d29403ff17ba8acada3021af5dd380e16`.
The paired Windows `prepared-read=false/true` N30 is recorded in
`reader-flat-v2-prepared-paired-windows.md` and its JSON/log artifacts. The
disabled run completed 360/360 samples; the enabled run timed out with one of
15 desired density-1 tiles absent (354/360 measurements). Its completed groups
show descriptive P95 improvements, but most still exceed 200 ms and the
incomplete lifecycle result blocks acceptance. The flag remains default-off.

After that snapshot, a harness-only format correction produced profile-main
SHA-256 `81387ebe6c25cc5e1b19de7341ebe7fde43a08d2038fc97d76926cd2a6216f59`.
Format workflows may already have a complete density-1 frame before requesting
an upgrade, especially rotated small originals. They now record that frame's
exact matched build/raster timestamps as a non-timed `nativeSteps` entry and do
not wait for an identical callback. It is excluded from latency samples.
Canonical ROI and prepared ROI retain their original new-presentation timing
and two-pixel focus criterion. The revised harness passed analyzer; actual
format rerun remains the parent task's responsibility.

## Acceptance boundary

The candidate is suitable for a separately labelled A/B on devices after the
root task builds the final Debug/Profile APK. It is not a performance pass by
itself: Android `ui.Image` creation/raster scheduling, first backing admission,
large cold-image construction, and wide-gamut/16-bit/HDR quality remain outside
this native exact-pixel evidence.

The Windows Skia `Trying to use texture on two GrContexts` warning does not by
itself establish a blank image. The installed SDK creates cross-context images
in `image_decoder_skia.cc:204`; `image_encoding_skia.cc:49` tries an IO-context
readback, then explicitly falls back to raster-thread draw/readback at lines
68-104. Reader raster persistence calls `clone.toByteData(PNG)` after paint, so
that readback attempt is a plausible warning trigger; no per-warning native
stack was collected, so this is an inference, not a proven attribution.
The previous Windows 66-case recovery quality run emitted this warning while
all 66 actual canvas RGBA comparisons were exact. New candidate acceptance
still requires actual nonblank canvas/readback comparison and cache-repeat
pixels. Layer completion callbacks and FrameTiming alone cannot prove pixel
contents or OS scanout.

## Redmi Surface-fix N30 recheck

After the missing-tile Surface fix, the same Android Profile APK and fixture
were run with `prepared-read=true` and then `false`, 30 samples for each of the
six layouts/modes in `roi` and `roi-prepared` (360 per run). The tested source
was the synthetic 8000x12000 interlaced PNG. These two runs were ordered rather
than randomized, and OS file-cache state was not controlled, so treat the
difference as descriptive device evidence.

| Layout / mode | Backing state | Enabled P95 ms | Disabled P95 ms | Enabled change |
| --- | --- | ---: | ---: | ---: |
| Single / sharp first | cold backing may be built in sample | 501.164 | 688.848 | -27.2% |
| Single / preview first | cold backing may be built in sample | 530.357 | 752.102 | -29.5% |
| Continuous / sharp first | cold backing may be built in sample | 466.342 | 882.340 | -47.1% |
| Continuous / preview first | cold backing may be built in sample | 498.682 | 1036.793 | -51.9% |
| Double / sharp first | cold backing may be built in sample | 619.547 | 1023.688 | -39.5% |
| Double / preview first | cold backing may be built in sample | 607.969 | 1057.246 | -42.5% |
| Single / sharp first | backing prepared outside timed sample | 467.022 | 655.390 | -28.7% |
| Single / preview first | backing prepared outside timed sample | 513.700 | 758.697 | -32.3% |
| Continuous / sharp first | backing prepared outside timed sample | 499.110 | 919.364 | -45.7% |
| Continuous / preview first | backing prepared outside timed sample | 513.775 | 1030.586 | -50.1% |
| Double / sharp first | backing prepared outside timed sample | 606.812 | 1022.942 | -40.7% |
| Double / preview first | backing prepared outside timed sample | 684.189 | 1068.529 | -36.0% |

Each run completed 360/360 with zero harness errors, zero missing raster
presentations, zero target/focus misses, and all sampled presentation layers
complete, `density=1`, and `nativePixels=true`. This verifies the Surface fix
does not silently leave a requested ROI absent in this matrix. It does not
show a speed pass: even enabled P95 is 466--684 ms, above the plan's 100--200
ms absolute range. The relative improvement is promising but cannot by itself
make this the default. The separate surface/cache quality run on the same new
APK was exact in 66/66 cases with all source hashes unchanged; it does not cover
ICC/16-bit or animation.

Run artifacts:

- `reader-flat-v2-surface-fix-prepared-on-redmi1006.json`, SHA-256
  `9babf992760e65a8edc1cf3c67a93cd92096664f4da67af5fa0cc17eef178e4f`.
- `reader-flat-v2-surface-fix-prepared-off-redmi1006.json`, SHA-256
  `2fef9f9d7f7aa70fdcdf9260f18155059725620def850fdb6fcd9d923d13ab1d`.
- `reader-flat-v2-surface-fix-quality-prepared-redmi1006.json`, SHA-256
  `6cc62db8aa8a20e489f09dcb3d5149d91d45bed2ea49199e8a89a7e81b8464f1`.
