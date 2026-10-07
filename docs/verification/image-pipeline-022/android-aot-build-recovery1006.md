# Android profile AOT packaging recovery

Date: 2026-10-06. This is build evidence, not reader performance acceptance.

The profile APK `reader-prepared1006-before-format-helper.apk` reported a
successful Flutter build but contained no `libapp.so` in any of its three ABI
directories. The engine libraries were present. Launch reported `VM snapshot
invalid and could not be inferred from settings`, then failed to create the
Dart VM. The intermediate Flutter output directory was empty and `libs.jar`
was only 261 bytes, although the compiler cache held three nonempty `app.so`
files. This failure is separate from the earlier Debug STL low-budget abort.

The task snapshot's build path was C -> E -> D through two junctions. Old
Flutter stamps recorded E paths and new stamps recorded D paths referring to
the same physical files. This SDK compares stale output paths as strings before
deleting them; this is a concrete risk of deleting newly generated output via
an old alias. Gradle's packing task already depends on Flutter compilation.
No verbose file-operation trace was collected, so the evidence does not prove
that the same cleanup step caused every failed packaging attempt.

Recovery used new empty physical directories, with one junction per directory:

- Snapshot: `C:/Users/tanad/.codex/tmp/picakeep-022-flutter-build`.
- `build` -> `D:/picakeep-image-pipeline-022-work/flutter-build-v2`.
- `.dart_tool/flutter_build` ->
  `D:/picakeep-image-pipeline-022-work/flutter-compiler-cache-v2`.
- Old junctions and the task snapshot's `android/.gradle` were renamed and
  retained for inspection. Global Gradle/Pub caches were not cleared.

The rebuilt profile target was `tools/image_pipeline_022_profile_main.dart`,
SHA-256 `81387ebe6c25cc5e1b19de7341ebe7fde43a08d2038fc97d76926cd2a6216f59`.
Build log: `E:/picakeep-image-pipeline-022-work/reader-flat-v2-final-android-build.log`.
The build completed in 117.2 seconds. Before installation, actual intermediate
files, `libs.jar`, and the final APK were all checked for nonempty AOT output:

| ABI | Intermediate app.so / packaged libapp.so bytes |
| --- | ---: |
| arm64-v8a | 6423472 |
| armeabi-v7a | 7029340 |
| x86_64 | 6489008 |

Verified package:

- `D:/picakeep-image-pipeline-022-work/reader-flat-v2-final1006.apk`.
- SHA-256 `9ecb0bd996dfdca7408aa91accded1bf61bc7200215b4c40bb04b485cd5ca1fb`.
- Package `lingxue.picakeep`, versionCode 9, versionName 1.9.92.
- Existing debug certificate SHA-256
  `31b4434516ccc1f58add7cc5cd4b6786e995c957d5891d3685e4c75a7a58d7c7`.

Explicit `adb -s 8021129d install -r` succeeded. No uninstall or data clear was
performed. The independent test entrypoint started as PID 19388 and emitted
real Flutter frame timing, confirming VM startup. Its prepared-read canvas and
cache quality report must be assessed separately; successful launch is not a
pixel or speed pass. This APK is a test target, not the final normal app package.

Future installation gates must inspect actual intermediate files, packing
archive and final APK. A successful build line or output manifest alone is
insufficient after build-directory migration.
