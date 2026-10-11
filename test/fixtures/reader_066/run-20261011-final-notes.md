# 066 R3 / F4 / F5 offline final evidence — 2026-10-11

## Final independent runs (do not add these to another gate)

| Group | Result | Evidence | Source/input freeze |
| --- | --- | --- | --- |
| Reader PhotoView ownership, actual loading/error gaps, overlapping generations, custom-child fit, delayed real gesture callback, single/double/continuous retirement | **7 pass / 0 fail / 0 skip**, 1s | [Owner log](<test/fixtures/reader_066/run-owner-vendor-20261011-200505-flutter.log>), [summary](<test/fixtures/reader_066/run-owner-vendor-20261011-200505-summary.json>) | 541 paths, 0 SHA changes |
| Real-format F4 + long/large safety F5 | **4 pass / 0 fail / 0 skip**, 27s | [Matrix/safety log](<test/fixtures/reader_066/run-formats-safety-final-20261011-200827-flutter.log>), [summary](<test/fixtures/reader_066/run-formats-safety-final-20261011-200827-summary.json>) | 542 paths, 0 SHA changes |
| Existing zoom + display-mode/settings regression | **24 pass / 0 fail / 0 skip**, 15s | [Regression log](<test/fixtures/reader_066/run-zoom-settings-final-20261011-200901-flutter.log>), [summary](<test/fixtures/reader_066/run-zoom-settings-final-20261011-200901-summary.json>) | 542 paths, 0 SHA changes |

Each run has separate `-before.json` and `-after.json` records beside its log.
The last regression group had already been queued before the parent requested
omitting the redundant standalone repeat; cancellation returned “already finished,
exit code 0”. Its actual result is retained, not described as an interruption.
The parent owns the subsequent low-level / workflow / final combined gate.

## What the format run actually completed

- All **19 format/layout cells**, cold and warm reopen, **312 actual `ui.Image`
  RGBA whole-frame comparisons** against independent committed Pillow references.
- JPEG EXIF 1–8 in single layout; EXIF6, alpha PNG, lossless alpha WebP and lossy
  WebP additionally in double and continuous layouts. This is not the full
  orientations × layouts Cartesian product.
- Original preview → sharp safe → sharp strict → transform → viewport rotation
  → reset → preview sequence remained intact. The first original JPEG failure
  sequence was not rearranged or skipped.
- Original JPEG/lossy/lossless/alpha error thresholds remain unchanged. Original
  dimensions, fitted aspect, whole-source bounds, no Surface/ROI, original stream
  export SHA, committed/runtime source SHA, provider/sharp separation, page anchor
  and real exit resource/budget-zero assertions all passed.
- F5 retained real long-image whole samples and compressed-large pre-frame safety
  rejection. No 8192×8192 RGBA frame was decoded by the guarded renderer.
- Continuous layout does have an **outer PhotoView at controller index 0**; its
  individual image children do not each add a PhotoView.

## Red evidence retained and resolved, not suppressed

1. The original first run failed when a reused stable controller notified a
   disposed scale-state notifier. Reader-local stable roots, per-owner forwarding
   leases, independent scale-state streams, exact A/B Core retirement and
   token/identity-guarded callbacks/state writes now cover the actual lifecycle.
2. The real direct gesture callback probe separately exposed the dependency's
   `onScaleEnd` continuation after its 200ms await: `animatePosition` and
   `animateScale` touched disposed private AnimationControllers. The
   [pre-vendor owner log](<test/fixtures/reader_066/run-owner-20261011-195506-flutter.log>)
   preserves both stacks. A narrowly authorized local vendor adds **only one
   `if (!mounted) return;` line** after the await, with no delay, exception
   suppression, sentinel getter or change to mounted-Core behavior.
3. The unchanged global resident factory-count assertion then failed for EXIF6
   continuous layout. The [instrumented probe](<test/fixtures/reader_066/run-format-count-probe-20261011-200519-flutter.log>)
   proved `before={0:1,1:1}`, `after={0:1,1:1,2:1}`: existing pages did not recreate
   providers; page 2 was newly built. The fixture now records a fresh historical
   baseline for each cold/warm entry, requires exact unchanged factory counts for
   already-acquired current-entry pages, and permits only the first acquisition
   of newly laid-out pages. It does not treat a previous entry's page counts as
   currently acquired leases. Sharp-mode global “no preview factory call” remains
   strict after the resident baseline. No pixel, source or resource assertion was
   relaxed. Final logs include all before/current-entry/after page-count maps.

## Minimal local vendor and dirty-baseline proof

- Source revision: `a1255d1b5945aad4b7323303ec2ecdf0c90ffc4c` from
  <https://github.com/wgh136/photo_view>, version `0.14.0`.
- Exactly 16 library Dart files plus original package manifest and MIT license
  copied. [Byte proof](<test/fixtures/reader_066/vendor-sha-proof.json>): 17 copied
  files byte-identical to the external cache; Core differs by exactly the one
  mounted guard, including preservation of original CRLF bytes. External Pub/SDK
  cache source was not edited.
- [Patch provenance](<packages/photo_view/READER_066_PATCH.md>) and
  [original license](<packages/photo_view/LICENSE>) remain in the local package.
- Root dependency change is only the approved PhotoView path override.
  [Actual pre-change manifest](<test/fixtures/reader_066/vendor-before-pubspec.yaml>)
  and [actual pre-change lock](<test/fixtures/reader_066/vendor-before-pubspec.lock>)
  were copied from the dirty working tree, not reconstructed from HEAD.
- [Offline resolution log](<test/fixtures/reader_066/vendor-offline-pub-get.log>)
  and [lock proof](<test/fixtures/reader_066/vendor-lock-proof.json>): 165 packages,
  only PhotoView source changed git → local path; all other 164 complete lock
  blocks/versions/refs and SDK constraints unchanged. Current generated package
  config resolves `../packages/photo_view`.
- No pre-change generated package-config copy was preserved; no such before-SHA
  is claimed or fabricated. The preserved dirty lock is the dependency-baseline
  evidence. No CLAUDE configuration was changed.

## Static checks, environment and limits

[Final nine-target analysis](<test/fixtures/reader_066/vendor-final-analyze.log>)
reported **No issues found**. The subsequent per-entry fixture correction was
formatted and separately analyzed (job 249), also **No issues found**.

Flutter test commands used `test --no-pub --concurrency=1 --reporter expanded`.
The supplied SDK directory is named `flutter_windows_3.38.5-stable`, but actual
SDK metadata is **Flutter 3.41.6 / Dart 3.11.4**, framework
`db50e20168db8fee486b9abf32fc912de3bc5b6a`, engine
`425cfb54d01a9472b3e81d9e76fd63a4a44cfbcb`.

`PICAKEEP_022_REAL_SOURCE_ROOT`, `PICAKEEP_022_REMOTE_WORKFLOW` and
`PICAKEEP_IMAGE_ENGINE_FIXTURES` were cleared. No application build or install,
real-account/site access, user original-file mutation or data clearing occurred.
Only the explicitly authorized offline dependency resolution was performed.

These are offline production-route/Flutter compatibility and logical resource
accounting results, not native device codec, RSS/GPU, platform export UI or device
interaction evidence. A verified warm source reopen is not a fabricated disk-hit
claim. Field/device verification remains with the user.
