# 066 offline real-format and safety fixtures

All inputs are task-owned synthetic images. No network, external samples, user
comic files, accounts, or device build/install are involved. The scripts require
no package installation. This directory is exclusive to the 066 tests.

## F4 / R3 fixed quality reference

Generator: [reader_format_fixtures_066.py](<../../support/reader_format_fixtures_066.py>).
Manifest: [manifest.json](<manifest.json>). Test:
[reader_real_format_matrix_066_test.dart](<../../reader_real_format_matrix_066_test.dart>).

- Bundled Pillow **12.3.0**, libjpeg-turbo **3.1.4.1**, libwebp **1.6.0**.
- Eleven real encodings: JPEG EXIF 1–8 (quality 95, 4:4:4, baseline,
  non-progressive, no optimization); one RGBA PNG (compression 9); one lossless
  RGBA WebP (quality 100/method 6/exact); one lossy RGB WebP (quality 95/method 6).
- Encoded size 96×64; EXIF 5–8 normalize to 64×96. Distinct red/green/blue/yellow
  corner patches, unequal shapes and white/black offset marks distinguish
  rotation, reflection and width/height swaps. PNG/lossless WebP include alpha
  0, 32 and 128 in addition to opaque pixels.
- Eleven committed `.rgba` files are independently decoded using Pillow and
  EXIF-normalized. They are row-major premultiplied RGBA8, computed as
  `(channel * alpha + 127) // 255`. No Flutter/reader output constructs the
  oracle. Independent EXIF coordinate formulas cross-check marker positions.
- Per-file original and reference SHA256, encoding parameters, semantic marker
  coordinates/colors and tolerances are committed in the manifest.

The error contract was fixed **before the first Flutter run**:

| Format | Full-image RGB comparison to encoded reference | Alpha |
|---|---|---|
| JPEG | absolute channel maximum ≤3 **and** mean over all RGB channels ≤0.75 | exact |
| Lossy WebP | maximum ≤2 **and** mean ≤0.25 | exact |
| PNG / lossless WebP | opaque and alpha-zero RGB exact; translucent RGB maximum ≤1 solely for integer premultiplication | exact |

Lossy results are not compared byte-for-byte to pre-encoding artwork. Thresholds
are fixed in both the generator/manifest and test; do not loosen them to obtain
a passing run. On a difference, preserve evidence and investigate decoder,
orientation or color handling before deciding any production change.

### Coverage mapping

The quality test uses the real `LocalPathReadingData` and its provider/source,
production `buildComicView` in a `Stack` host, preview provider and sharp whole
renderer. It reads actual visible `ui.Image` RGBA, not a screenshot or a fake
raster. Letterboxing is accounted for with the actual RawImage fit/scale and
render-box size; the painted destination must retain the original aspect.

- All eleven fixtures: single-page layout 1.
- JPEG EXIF 6, PNG, lossless WebP, lossy WebP: additionally double layout 5 and
  continuous layout 4. Total **19 format/layout cells**; not an all-orientations
  × all-layouts Cartesian product.
- Each cell: cold entry and warm source reopen; unchanged preview resident
  rebuild; same-session preview → sharp safe → sharp strict → preview; pixel
  checks at seven checkpoints per entry (**266 minimum frame comparisons**,
  additional visible images may increase the comparison count).
- PhotoView scale/rotation and viewport rotation keep actual frame pixels
  intact. Single pages own their PhotoView; double pages use the gallery owner;
  continuous layout has an outer PhotoView using controller index 0. The inner
  continuous page images do not each create an additional PhotoView.
- Preview resolver/provider separation; unchanged resident preview does not
  recreate its provider; all original/normalized dimensions and whole bounds,
  no Surface/ROI, original-source stream export SHA, task original SHA and
  committed asset SHA are asserted. Export-stream coverage joins the existing
  full-workflow save/share/favorite UI tests; it does not independently claim to
  repeat every platform export UI.
- Cold/warm reopen is source/cache-state coverage, **not a guaranteed disk hit**.
  Native-unavailable compatibility metadata conservatively marks color profile
  unknown and disables persisted raster caching. The test accepts only a real
  Flutter codec sample or a recorded real disk raster hit, never a fabricated
  hit. ImageCache is retired on exit; resident warm reuse is checked separately.
- Every exit waits for actual post-frame/native IO completion, source disposals,
  raster writers, preview/whole/work/temporary budgets and file leases to reach
  zero. This is logical accounting, not measured process/GPU memory.

Wider layout/source/selection/export interaction coverage is explicitly composed
with [production routes](<../../reader_production_whole_routes_test.dart>),
[full workflow](<../../reader_full_workflow_022_test.dart>) and
[whole renderer contract tests](<../../reader_whole_image_render_test.dart>).
No old test or assertion is modified.

## F5 / R4 narrow real safety evidence

Generator: [generate_safety.py](<generate_safety.py>). Manifest:
[safety_manifest.json](<safety_manifest.json>). Test:
[reader_real_safety_066_test.dart](<../../reader_real_safety_066_test.dart>).

- A real **24×6000 RGBA PNG**, 576,000 decoded RGBA bytes. Top/middle/bottom
  color bands and a distinct yellow left third make whole-image retention
  observable. Preview checks every original pixel. Safe whole checks the real
  delegated decoder demand (full source/raster rect, row/column −1), ≤4096
  output edge, original painted aspect and exact solid interior samples on
  both sides in all three vertical bands. Strict must reject rather than
  silently downsample.
- A real **8192×8192 RGBA PNG**, 268,435,456 decoded RGBA bytes but <1MiB encoded.
  It is generated and validated row-by-row with zlib/CRC and full inflated SHA,
  **never by allocating a huge bitmap**. The generator uses at most 32,769 bytes
  per uncompressed input row and 65,536-byte validation output chunks.
- Large preview uses the real production provider/pool. Both codec-delegate and
  frame-start hooks must remain zero on admission rejection. Large sharp safe
  uses a real Flutter backend estimate and rejects before `decode`; strict
  rejects before decoder estimation. The delegate only records and calls the
  real backend, never returns fake pixels or injects a passing refusal.
- Sharp safety evidence deliberately selects **Flutter compatibility backend**
  with metadata from a real encoded descriptor, not native large-file decode.
  F4 is the evidence for production page-factory integration. This safety test
  does not claim to measure descriptor-internal allocation, native backend
  peak memory, OS RSS, GPU textures, or hardware texture limits. 4096 is the
  existing policy bound, not a device capability query.

## Rebuild and verification

From repository root, using the bundled Python reported by
`load_workspace_dependencies` (shown here as `$python`):

```powershell
& $python test/support/reader_format_fixtures_066.py --write
& $python test/support/reader_format_fixtures_066.py --check
& $python test/fixtures/reader_066/generate_safety.py --write
& $python test/fixtures/reader_066/generate_safety.py --check
```

`--check` rebuilds in memory and compares all bytes without rewriting evidence.
Changing Pillow/codec/zlib versions may break reproducibility and requires an
explicit reference review, not automatic golden replacement.

After the main controller explicitly grants the Flutter serial lock:

```powershell
& 'E:\SDK\flutter_windows_3.38.5-stable\flutter\bin\flutter.bat' test --no-pub --concurrency=1 --reporter expanded test/reader_real_format_matrix_066_test.dart test/reader_real_safety_066_test.dart
```

The commands above are offline tests, **not application builds or installs**.
This document specifies coverage and procedure, not a pre-filled passing result.
Report the actual run result separately. Device validation remains with the user;
HDR/ICC/all bit depths/all image formats and the original field incident are
not proven by these local fixtures.

## Recorded final offline result (2026-10-11)

Actual completed results and red-to-green provenance are recorded in
[the final evidence note](<test/fixtures/reader_066/run-20261011-final-notes.md>):
F4/F5 **4 pass / 0 fail / 0 skip**, all **19 cells** and **312 actual whole-frame
pixel comparisons**; ownership/gesture regressions separately **7/0/0**; existing
zoom/settings separately **24/0/0**. These independent runs must not be added to
another consolidated gate. Full logs, source/dependency/test before/after SHA
records, exact local-vendor byte proof and the preserved dirty dependency baseline
are linked in that note. No quality tolerance or original hot-switch sequence was
relaxed; the proven continuous-list warm assertion was corrected to track exact
current-entry per-page lease reuse instead of counting newly built pages as reuse
failures. Device/RSS/GPU and external-source limits above remain unchanged.
