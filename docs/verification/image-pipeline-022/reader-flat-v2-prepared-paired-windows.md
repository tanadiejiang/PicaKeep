# Prepared read paired Windows N30

This document preserves two Windows prepared-read comparisons. The first, from
the earlier pre-Surface-fix runner, is historical and incomplete; the later
Surface-fix build recheck is recorded at the end. Use that later section for
the repaired Surface's speed and lifecycle evidence.

## Finding

The Windows profile run with `prepared-read=true` produced substantially lower
P95 presentation times than the preceding `prepared-read=false` run in most
groups. The candidate run is **incomplete**: one sample in
`native_roi_prepared:continuous:previewFirst` timed out after two minutes while
one of 15 visible original-pixel tiles remained absent. The candidate is not a
performance or lifecycle acceptance pass, and this result does not support
turning the flag on by default.

Both runs used the same copied Windows Profile runner, static 8-bit sRGB
8000x12000 Adam7 PNG, 512-pixel tiles, `raw-sync=false`,
`persist-raster=true`, and 30 requested samples per group. The disabled run
completed all 360 samples. The enabled run completed 11 groups and recorded 24
of 30 samples in its last group before that group was aborted. Its JSON
therefore contains 354 measurements, not 360. The timing
comparison below is descriptive: `prepared-read=false` ran first,
`prepared-read=true` ran second, operating-system file-cache state was not
controlled, and the Android paired run occurred concurrently.

## Evidence

The frozen runner at
`D:/picakeep-image-pipeline-022-work/reader-flat-v2-frozen-runner` contained 45
ordinary files (41,625,108 bytes) and no reparse points. Its component hashes
were:

| Component | SHA-256 |
| --- | --- |
| `picakeep.exe` | `e0ee4da717332e62419216d4450dcbe359d37770da6d1424dda01f9ed1c420f0` |
| `data/app.so` | `cab50bc899541e9511b61302c323042768f192cca77c7cb3eb5732f31fb53128` |
| Native DLL | `3069a410228201b128079e33df0c586d29403ff17ba8acada3021af5dd380e16` |

Fixture SHA-256 was
`af84cbdfa6c67ff61cfbc8747bb0b5f33bbed0a267f1e7a8777d1c00f99fec0d`; the
file remained 1,209,123 bytes with its recorded modification time unchanged.
The separate Windows Surface quality report records the same before/after
SHA-256 in all three quality cases for this fixture, with exact RGBA comparisons
and `sourceUnchanged=true`.

| Run | Result | JSON SHA-256 | Full samples |
| --- | --- | --- | ---: |
| `prepared-read=false` | completed | `37857f77c9ae01a34a8dfce4efcd936878a6e71f04a8f95c5318d62e354801db` | 360/360 |
| `prepared-read=true` | incomplete | `ed979915ffbac3cb52c0551431850e5d1bf1c21400cf057528fbdb13f55ba163` | 354/360 |

Each run's complete `.log` and `.stderr` files are stored beside its JSON. The
enabled run's stderr contains Skia cross-context texture warnings; the previous
66-case Windows quality run still had exact pixel readbacks. The warnings are
not evidence of blank frames by themselves.

## P95 comparison

Times below are request-to-matched-raster-finish presentation P95 in
milliseconds. All disabled groups had 30 samples. All enabled groups had 30
except the explicitly marked incomplete group, which had 24.

| Layout / mode | Disabled P95 | Enabled P95 | Change |
| --- | ---: | ---: | ---: |
| Single, sharp first | 346.667 | 202.984 | -41.45% |
| Single, preview first | 338.489 | 206.222 | -39.08% |
| Continuous, sharp first | 363.023 | 198.754 | -45.25% |
| Continuous, preview first | 363.517 | 196.402 | -45.97% |
| Double, sharp first | 319.687 | 206.553 | -35.39% |
| Double, preview first | 352.000 | 212.805 | -39.54% |
| Single prepared, sharp first | 354.237 | 208.819 | -41.05% |
| Single prepared, preview first | 383.744 | 213.410 | -44.39% |
| Continuous prepared, sharp first | 354.938 | 198.806 | -43.99% |
| Continuous prepared, preview first | 374.384 | 194.066 | -48.16%* |
| Double prepared, sharp first | 320.015 | 192.650 | -39.80% |
| Double prepared, preview first | 339.845 | 219.630 | -35.37% |

`*` This group has only 24 samples and is not a complete N30 result.

The raster-stage records for completed outputs in the enabled run contain 3,376
prepared-read uses and no status-5 misses. The process counters also include 20
status-5 misses and 43 status-2 cancellations; these do not appear as completed
image stages. Every recorded timing sample had a complete, density-1 native
frame containing its requested focus. The P95 nevertheless exceeded 200 ms in
most completed groups. A prepared-read hit avoids rebuilding the native
backing; it does not remove UI scheduling, tile admission, `ui.Image`
construction, or frame presentation costs. Rows labelled `prepared` in the
table describe the separately warmed backing state (`roi-prepared`); the
enabled/disabled comparison is the `prepared-read` flag.

## Incomplete sample

The timeout occurred at
`roi-prepared:continuous:previewFirst:24`, target original pixel `[1200, 10560]`.
In the JSON, the first error's `stage` text is hard-coded as
`native_roi:continuous:previewFirst:24`; the following `group-aborted` entry
identifies `roi-prepared:continuous:previewFirst`. The stage label is therefore
not a reliable indicator of the active backing-preparation group.
The last presented layer was a complete density-0.25 preview. The Surface
reported 15 desired density-1 tiles but only 14 resident tiles, with no ticket,
estimate, Surface error, active job, or queued job. Native counters showed 12
prepared-read status-5 misses and 2 cancellations at that point. The sample
then timed out after two minutes, aborting the `roi-prepared` group. This
resembles the Android prepared-run incomplete report and is
being investigated as a Surface demand/lifecycle problem; it is not evidence
that the native prepared-read call corrupted pixels.

At the end of harness cleanup, all internal resident, scheduler, working,
temporary, file-lease, pending-cache, and disk-quota counters were zero. Two
native workers were idle. This confirms cleanup after the aborted run, not
successful completion of the missing sample. Process RSS peaked at
226,127,872 bytes according to the harness; it is not an independent OS RSS
acceptance measurement.

## Reproduction

Run the commands sequentially with the frozen Profile executable; use a fresh
task-owned work/output path for each invocation:

```powershell
$exe = 'D:/picakeep-image-pipeline-022-work/reader-flat-v2-frozen-runner/picakeep.exe'
$common = @('--groups=roi,roi-prepared', '--samples=30', '--tile-pixels=512', '--raw-sync=false', '--persist-raster=true', '--fixtures=E:/picakeep-image-pipeline-022-fixtures')
& $exe @common '--prepared-read=false' '--work=D:/picakeep-image-pipeline-022-work/reader-flat-v2-prepared-off-windows' '--output=D:/picakeep-image-pipeline-022-work/reader-flat-v2-prepared-off-windows.json'
& $exe @common '--prepared-read=true' '--work=D:/picakeep-image-pipeline-022-work/reader-flat-v2-prepared-on-windows' '--output=D:/picakeep-image-pipeline-022-work/reader-flat-v2-prepared-on-windows.json'
```

The evidence files were copied from the completed processes without editing
their JSON or logs. Both process windows were closed normally after capture.

## Path

`reader profile flag` → `ReaderImageSurface` original-pixel tile demand →
`ReaderRasterBackend` prepared-only native call → read-only backing/header
validation and native region decode → Flutter `ui.Image` construction →
Surface tile residency → matched raster-frame report. The speed comparison
covers this path only for the selected synthetic fixture and listed layouts;
the exact-pixel assertion comes from the separate Surface quality capture.

## Surface-fix build recheck

The earlier incomplete run above used an older Surface implementation. This
recheck was built from the Surface whose SHA-256 was
`36dbda0a601f73ecd7684fc5aa74716d16ef15c63009945a7f97d058b269a9d4` and copied
to a separate runner before testing. The subsequent known alpha-compositing
issue in this Surface version was not corrected in this build; this matrix is
speed and lifecycle evidence only and does not establish alpha/preview image
quality. The prepared-read candidate remains default-off pending quality
validation on the corrected Surface and device acceptance.

The `prepared-read=true` run ran first, followed by `false`, each requesting
30 samples across single, continuous, and double layouts, sharp-first and
preview-first modes, with both in-sample cold-backing and explicitly prepared
backing groups (360 samples per run). Both completed. The OS file cache was not
controlled, so these sequential paired results are descriptive rather than a
randomized causal estimate. The fixture was the static sRGB8 8000x12000 Adam7
PNG above; `raw-sync=false`, `persist-raster=true`, and 512-pixel tiles were
held constant.

| Layout / display mode | Backing group | Enabled P50 / P95 ms | Disabled P50 / P95 ms | P95 change |
| --- | --- | ---: | ---: | ---: |
| Single / sharp first | cold (`roi`) | 65.530 / 205.952 | 113.695 / 380.717 | -45.90% |
| Single / preview first | cold (`roi`) | 64.153 / 208.718 | 116.965 / 384.601 | -45.73% |
| Continuous / sharp first | cold (`roi`) | 50.781 / 195.886 | 74.161 / 373.247 | -47.52% |
| Continuous / preview first | cold (`roi`) | 50.293 / 196.019 | 84.661 / 410.693 | -52.27% |
| Double / sharp first | cold (`roi`) | 70.516 / 221.070 | 105.595 / 329.323 | -32.87% |
| Double / preview first | cold (`roi`) | 82.360 / 220.531 | 116.013 / 375.863 | -41.33% |
| Single / sharp first | prepared backing (`roi-prepared`) | 69.116 / 212.431 | 123.637 / 375.851 | -43.48% |
| Single / preview first | prepared backing (`roi-prepared`) | 65.802 / 225.093 | 102.729 / 387.237 | -41.87% |
| Continuous / sharp first | prepared backing (`roi-prepared`) | 49.650 / 191.455 | 85.469 / 373.760 | -48.78% |
| Continuous / preview first | prepared backing (`roi-prepared`) | 49.808 / 199.742 | 75.476 / 398.423 | -49.87% |
| Double / sharp first | prepared backing (`roi-prepared`) | 71.636 / 198.974 | 112.370 / 326.900 | -39.13% |
| Double / preview first | prepared backing (`roi-prepared`) | 66.926 / 200.544 | 117.555 / 360.028 | -44.30% |

Each run produced 360/360 timed raster samples with no errors, missing raster
presentations, incomplete/non-native presentations, targets outside the
presented source rectangle, or focus deviations beyond two source pixels.
Enabled completed raster records contain 3,459 prepared-read uses and no
prepared misses; final native counters contain 20 expected status-5 misses and
34 cancellations. Disabled completed records contain no prepared reads; all
69 native job failures were status-2 cancellations. Both runs finished with
zero resident bytes, active surfaces/jobs, queued work, working/temporary
reservations, source leases, pending raster-cache bytes, quota bytes/claims/
operations, and zero non-native worker errors. Two native workers remained
idle after each run. Harness RSS peaks were 236,261,376 bytes enabled and
225,296,384 bytes disabled; these are process-reported values, not independent
OS memory-recovery evidence.

The enabled P95 was 191--225 ms and the disabled P95 was 327--411 ms. Three of
the enabled cold groups and five of the enabled explicitly prepared groups
remain above 200 ms (the prepared continuous-preview P95 is just below at
199.742 ms). Therefore the candidate has a strong descriptive Windows speed
benefit but does not consistently meet the plan's absolute P95 target. It also
does not prove original file pixels were bit-identical from timing frames;
use the separate quality report only for the Surface version and compositing
cases it actually covers.

Runner and build provenance:

| Artifact | SHA-256 |
| --- | --- |
| Surface source at snapshot | `36dbda0a601f73ecd7684fc5aa74716d16ef15c63009945a7f97d058b269a9d4` |
| Profile harness source | `81387ebe6c25cc5e1b19de7341ebe7fde43a08d2038fc97d76926cd2a6216f59` |
| Native core source | `9110413eeae496707cdf3239c4f4371bbe060c42430976ee3e79613824834087` |
| `picakeep.exe` | `ae63c0957915b093f0d11d42d83fbef3e755342cab10133af9b0cbf3ebdea644` |
| `data/app.so` | `25250a28b6cf254dc6df6669fe53d36e4a98e44ad184d4ff10c0d690a20e1e41` |
| `picakeep_image_engine.dll` | `df6b205a5ff71bb6256c887c83c876cd3433ce27393e02c07f02fe6af56d08f5` |
| Profile build log | `8cbe054f650b91aa181096208ecf7b3e661d5bb75a65e9533891bd67dd945004` |
| Runner manifest | `7cb9c8fbee12eb904dbbae44ed201d0c1dcfb46b069befeb609a3cb60f9e98223` |
| Enabled report JSON | `7f8518157efcabfacf5b937c42bc4287bb37ac2bea583f7f73131e8e0947c9ab` |
| Disabled report JSON | `7ff52b5cd16ef48ee7f97b948121ac510b77d740773347a816125d0914ea2e6c` |

The copied runner had 46 ordinary files, 41,429,057 bytes, and no reparse
points. Full stdout and stderr are retained as `reader-windows-surface-fix1006-
prepared-{on,off}.log` and `.stderr` beside the JSON reports. The run started
with fixture SHA-256
`af84cbdfa6c67ff61cfbc8747bb0b5f33bbed0a267f1e7a8777d1c00f99fec0d` (1,209,123
bytes; modification time `2026-10-05T11:23:19.0959455Z`). Both process windows
were closed normally after the completed reports were captured.
