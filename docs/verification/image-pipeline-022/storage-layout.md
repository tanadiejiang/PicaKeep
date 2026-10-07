# 022 验证产物存储记录

记录时间：2026-10-05 20:26（Asia/Singapore）。仅处理本轮生成的构建、基准和测试产物，未删除用户库或应用数据。

## 当前布局

| 原位置 / 逻辑入口 | 实际存储位置 | 说明 |
| --- | --- | --- |
| `C:\Users\tanad\.codex\tmp\picakeep-022-flutter-build\build` | `E:\picakeep-image-pipeline-022-work\flutter-build` | 目录联接；保持 Gradle/CMake 的绝对路径有效 |
| 项目 `android\.gradle` | `E:\picakeep-image-pipeline-022-work\project-gradle-cache` | 目录联接；本轮缓存约 209MB |
| 项目 `build\test_cache` | `E:\picakeep-image-pipeline-022-work\project-test-cache` | 目录联接；本轮测试缓存约 44MB |
| 基线源码快照及基线 APK | `E:\picakeep-image-pipeline-022-baseline` | 已移动并保留，约 1.26GB |
| 合成原图及参考图 | `E:\picakeep-image-pipeline-022-fixtures` | 约 104.5MB；生成器支持 `PICAKEEP_IMAGE_ENGINE_FIXTURES` / `--output-dir` |
| Windows 原生巨图实验 backing | `E:\picakeep-native-022-artifacts` | 约 2.11GB；可重新生成的实验产物 |
| Windows 阅读基准运行目录 | `E:\picakeep-image-pipeline-022-runtime` | 工具独立 data/cache；不打开用户库 |
| Windows 封面基准运行目录 | `E:\picakeep-image-pipeline-022-cover-profile` | 工具独立 data/cache；不打开用户库 |

Flutter 源码快照仍位于 C 盘。`tools/capture_image_pipeline_022_snapshot.ps1` 逐个复制 Git 已跟踪及非忽略的普通源码文件，排除构建目录、`.dart_tool` 和插件目录联接，不跟随目录链接。第三方 codec 源码归项目依赖，构建产物归上述独立目录。

## 实际问题与修正

依赖 SDK 放在 E 盘，并不会自动改变 Flutter 项目的 `build` 目录。本轮基线快照及原生实验产物累计写入 D 盘，出现不足 200MB 可用空间；验证随后暂停并迁移本轮产物。

一次跨盘移动完整 Flutter 生成快照时，PowerShell 遍历插件目录联接，误移动了部分 Pub 缓存插件文件。已按 `.dart_tool/package_config.json` 的真实 package root 恢复普通文件；后续 Dart 测试和 Android / Windows profile 构建均通过。今后不能移动包含 `.plugin_symlinks` 的完整生成 checkout；应复制普通源码文件，或只移动已核实不含 ReparsePoint 的独立产物目录。

清理阶段自动审批拒绝了递归删除构建备份。改为保留产物并可逆迁移，未再次尝试删除。恢复布局时，先核实各联接目标和剩余空间；只移除联接本身，不递归删除真实目标，再把对应独立目录移回。

20:26 实测剩余：C 盘 4,874,395,648 字节；D 盘 29,442,072,576 字节；E 盘 4,491,055,104 字节。D 盘新增空闲也可能包含用户清理，不归因于本轮迁移。后续大产物继续使用 E 盘并监测余量。

## 2026-10-06 构建产物二次迁移

本轮 E 盘低于巨图工作区准入所需余量时，Windows 8000×12000 progressive JPEG 的三项画布检查被明确拒绝。旧失败报告保留，任务构建产物从 E 移到 D 后另起 recovery run，66/66 exact、quota rejected=0；没有降低 headroom 或删除原文件来使检查通过。

当前快照 build 入口仍为 `C:/Users/tanad/.codex/tmp/picakeep-022-flutter-build/build`，它指向 E 的原入口，而 `E:/picakeep-image-pipeline-022-work/flutter-build` 现在是指向 `D:/picakeep-image-pipeline-022-work/flutter-build` 的目录联接。快照 `.dart_tool/flutter_build` 指向 `D:/picakeep-image-pipeline-022-work/flutter-compiler-cache`。保持既有绝对入口以避免 Gradle/CMake 路径失效；仅移动了已核实的任务构建目录，未遍历 Pub 插件链接。

三个已确认退出的本轮 `flutter_tools.*` 临时目录移至 `D:/picakeep-image-pipeline-022-work/preserved-flutter-test-temp` 保留。后续测试/构建的 TEMP/TMP 显式使用 D 的 task test-temp。13:28 余量约 C1.07GiB、D28.71GiB、E3.07GiB；不需要外接盘，仍需持续核对 E 的 backing/cache 与 C 的工具临时写入。
