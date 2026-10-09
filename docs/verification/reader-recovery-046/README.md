# Reader recovery 046 verification

本目录记录 046 执行结果。证据按“代码/自动化回归、正式 profile、真实设备工作流、独立 codec 对照”分层，不把热样本结果写成真实未读首读。

## Code and regression

- `lib/pages/reader/comic_reading_page.dart` 以局部 alias 引入既有可交互 Select。
- `lib/pages/reader/reading_settings.dart` 提供 `sharpFirst` / `previewFirst` 两个 String 选项，当前值和写回均可见。
- `lib/pages/settings/reading_settings.dart` 的两个类别在 callback 内重新解析当前完整设置，交错修改不会覆盖另一类别。
- `test/reader_display_mode_settings_workflow_test.dart`、`test/reader_image_pipeline_settings_test.dart`、`test/reader_image_quality_test.dart`、`test/reader_page_image_recovery_test.dart` 合计 37 项通过。
- `test/reader_continuous_boundary_test.dart` 与 `test/reader_zoom_test.dart` 合计 59 项通过；覆盖滚动清累计、axis/depth、单指缩放、wheel 和 PointerPanZoom 分支。

## Formal profile package

- APK: `build/reader-recovery-046/app-profile-formal.apk`
- Package/version: `lingxue.picakeep`, versionCode `12`, versionName `1.9.95`
- SHA-256: `8969605D97B351B9A6955AD570A4A46E6ED692FB488B1E82F35E7194365CCA9F`
- Install: `adb -s 192.168.5.13:5555 install -r ...` returned `Success`; no uninstall, clear-data or cache reset.
- Signing certificate SHA-256: `31b4434516ccc1f58add7cc5cd4b6786e995c957d5891d3685e4c75a7a58d7c7`.

## Real device workflow

设备为 `192.168.5.13:5555`，正式 profile 包运行在 Android 14。已下载列表第一本新 JM 书显示为单章 101 页，原件在阅读前没有做 hash/probe/复制读取。

1. 从下载列表进入第 1 章，阅读器显示 `1/101`，首屏两个 ImageView 均已创建。
2. 打开阅读器设置的“图片显示”菜单，实际出现“清晰优先”和“预览优先”两个按钮；选择“预览优先”后设置面板 content-desc 更新为“图片显示 / 预览优先”。
3. 关闭设置继续连续滚动，页码从首段推进到 `19/101`，再推进到 `100/101`；远端页段仍有 ImageView，未出现“图片暂时无法显示”。
4. 到尾部继续上滑 4 次，仍停留在 `100/101`，没有重新定位到前段。设备不具备滚轮/触控板，因此这两类真实硬件输入只由自动化测试覆盖。
5. 本轮结束时漫画档位恢复为 `previewFirst`，插画档位保持 `sharpFirst`；应用数据未清理。

## Codec evidence

`codec-report.json` 是同一设备上三个已读热样本的独立任务副本完整像素对照：JM PNG 两张、Komiic JPEG 一张。Flutter/native 输出 RGBA 尺寸和 SHA-256 一致，源文件未改变，scheduler active/pending/reserved 和 source lease 均归零，任务临时产物已删除。它证明 codec、预算和释放契约，不替代真实未读首读证据。

## Remaining boundary

本轮没有制造第二个全新未读样本，也没有重新破坏原件以重现 045 的 502/失败提示；完整的“两档各自独立未读首读 + 同页失败重试”矩阵应在后续计划中用保数据方式继续。若后续出现非 ctime-only 失败，需按新的日志阶段重新定位。
