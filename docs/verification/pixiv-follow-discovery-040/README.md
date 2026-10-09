# Pixiv follow discovery sheet — focused offline verification 040

This directory records the delegated review of the production follow discovery bottom sheet. Only the new sheet test and this directory are changed by the reviewer. Production bugs are reported to the main agent, who owns fixes.

## Scope and fixture

- Real Flutter widget engine, `MaterialApp` and `showModalBottomSheet` with `isScrollControlled`, safe area and drag handle.
- Logical viewport 375 × 1000; light and dark Material 3 themes; text scale 1 and 2; capture pixel ratio 2.
- Fonts loaded from `C:/Windows/Fonts/msyh.ttc` and `build/unit_test_assets/fonts/MaterialIcons-Regular.otf`. Missing fonts fail the test rather than using Ahem silently.
- Synthetic 2- or 5-author read data, each author with 3 embedded illustration briefs. Unicode names exercise two-line ellipsis. Empty embedded work lists exercise the production placeholder.
- All recommendation loads and follow/bookmark writes are injected. Per-test `HttpOverrides` forbids HTTP client creation, and every test asserts zero attempts. No account cookie is read, no real GET/POST is sent, and no build or installation is run.
- Avatar and cover URLs are intentionally empty. Images in captures are the actual production missing-image placeholders; no image canvas recreates the sheet UI. This validates modal geometry, typography, clipping, controls and their actual engine rendering, not remote image delivery.
- The sheet retains its parent's bookmark controller. A local shared store validates confirmations and duplicate-work write locks. Unknown bookmark states do not start a preload; their injected store confirmation can subsequently enable removal. The sheet does not expose an injected on-tap bookmark-state read callback, so actual unknown-state network resolution is left to the compact-card agent's separate tests.

## Behavioral checks

The test exercises independent load error and retry, a thrown load, legal empty response, empty-work cards without author hydration, closing a pending load, stale mounted owner/account results, nested horizontal gestures, explicit follow/unfollow targets, per-author busy locks, inline failure and retry, stale/closed follow completions, inactive-account controls, heart/image tap isolation, author-local open-work scope, a 48dp heart target, duplicate-heart shared lock, external store confirmation, missing-state no-prefetch, bookmark failure and stale bookmark completion.

The screenshot matrix additionally checks sheet/card geometry, follow-button and heart hit sizes, available thumbnail height, author name line limits, and Flutter framework errors at the requested real font scales. Every PNG is written by `RenderRepaintBoundary.toImage`; a JSON sidecar records rendering, font, fixture, geometry and network-attempt metadata.

## Initial verification

- First test run `pwsh-631`: compile stopped before test execution because the concurrently edited production detail shell referenced `_collapsedGallery` and `_gallerySliver` before their definitions were available. Main agent notified; reviewer did not alter production code.
- Scoped static analysis `pwsh-633`: `No issues found!` for the new sheet test and production sheet.
- Second test run `pwsh-637`: compile stopped before execution while the compact-card agent was adding `ownerIsCurrent`; the constructor argument appeared before its instance-field declaration. Main agent notified; no UI result or screenshot is inferred from this intermediate state.
- Read review identified an account change before the next Flutter rebuild as an action-validity boundary. A focused regression now checks it directly; main/compact-card agents own the dynamic guard fix.

- First complete runtime suite `pwsh-644`: 20 passed, 6 failed. Two failures were reviewer fixture assertions (record equality with a nested List, and expecting the inner list to own scrolling when all three previews fit); those assertions were corrected. The four visual cases measured a real production panel height of 952dp instead of the intended maximum 480dp. The feedback host's expanding Stack imposed its own full-height constraints before the inner SizedBox could enforce the bound. Main agent owns the outer height constraint fix.
- Scoped analysis `pwsh-645`: `No issues found!`; its complete output is saved in `sheet-analysis.log`.
- The gesture test now covers both the requested 375dp width (all three previews fit; the outer strip may accept a thumbnail-origin drag) and a 320dp fixture (three previews overflow; the inner list accepts image-origin dragging while author-header dragging moves the outer list).

## Final verification

- `flutter test --no-pub test/pixiv_follow_recommendations_sheet_test.dart`: **26 passed**, job `pwsh-660`, exit 0. The saved final log is [sheet-tests-final.log](sheet-tests-final.log). This includes all behaviors described above and the four real-font screenshot cases.
- Visual-only suite `pwsh-658`: **4 passed**, exit 0, after the main height fix appeared in the compiled production snapshot. No further production issues remain from this review.
- Final `dart analyze` of the new test and production sheet: **No issues found**, job `pwsh-667`, exit 0; output is saved in [sheet-analysis-final.log](sheet-analysis-final.log).
- Main-agent production fixes verified by these regressions: the bottom-sheet height bound is applied before the expanding feedback host; dynamic `ownerIsCurrent` is rechecked for compact actions at invocation and after awaits. The reviewer did not modify production code.
- Every test used the active deny-all override and reported **zero HTTP client attempts**. No real account/network operation, build, installation, per-author hydration or full-library lookup was used.

All four matrix sidecars record a **375 × 480dp** panel with top coordinate 520dp in the 375 × 1000 viewport. At scale 1 the first work occupies 92 × 264dp; at scale 2 it occupies **92 × 188dp**. Each compact heart reserves **48 × 48dp**. Follow controls are 48dp tall at both scales, while the author-card width stays 315dp. The framework error arrays are empty for all four combinations.

Visual inspection used `read_image` on all four full viewports and both scale-2 modal panel crops. The modal has a visible drag handle and close action, a persistent confirmed-follow badge, a readable title and swipe hint, two-line Unicode author names with an ellipsis at scale 2, and three unclipped work previews with hearts. Both themes preserve readable surface/control contrast. The next author card peeks in at the right edge to indicate horizontal continuation. No RenderFlex overflow, overlapping follow control, clipped heart or displaced bottom boundary was observed.

## Screenshot artifacts

The recommended review images include the actual modal ancestor Material background, preserved by cropping existing engine-capture pixels using [crop_panels.py](crop_panels.py). The script creates no UI or new painted content, and each cropped-image sidecar records source SHA-256 and exact pixel bounds.

| Theme | Text scale | Full viewport | Modal panel |
| --- | --- | --- | --- |
| Light | 1 | [Viewport](375-light-scale1-viewport.png) | [Panel](375-light-scale1-modal-panel.png) |
| Light | 2 | [Viewport](375-light-scale2-viewport.png) | [Panel](375-light-scale2-modal-panel.png) |
| Dark | 1 | [Viewport](375-dark-scale1-viewport.png) | [Panel](375-dark-scale1-modal-panel.png) |
| Dark | 2 | [Viewport](375-dark-scale2-viewport.png) | [Panel](375-dark-scale2-modal-panel.png) |

Full viewport PNGs are 750 × 2000 pixels, and modal panel crops are 750 × 960 pixels, from the 2× capture ratio. Each has a matching JSON metadata file. The additional `*-panel.png` files are raw inner RepaintBoundary captures; they retain transparency outside their child surfaces because their ancestor Material lies outside that boundary. They should not be interpreted as a black production background. Use the viewport or `*-modal-panel.png` for visual review.

[manifest.json](manifest.json) records artifact hashes and the exact test, sheet and compact-card source hashes. The test source is new and isolated; the review scope remains the new test plus this evidence directory.

## UX review basis

The UI/UX skill's review checklist was applied to dynamic text, light/dark state contrast, touch targets, modal escape, loading/error recovery and gesture conflicts. Its bundled search-script pointer resolved to a missing source directory in this runtime, so no generated design system was used or persisted; the requested scope remains review of the existing production sheet.
