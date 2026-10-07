# 阅读显示连续性与回滚复用 · 2026-10-07

用户反馈普通漫画与大图插画接入分块后显示体验变差，已看页面回滚重新加载。本轮处理了可在代码和测试中确认的显示机制：放大时清晰优先曾隐藏已有低密度画面，清晰块未齐即出现空白；部分可见页面会从整页切到网格；页面销毁会释放全部已解码像素，回看还重复打开、probe和codec检查。尚未在用户指定作品中完成体验对比，022继续执行。

## 当前行为

- 普通本地原文件的静态 JPEG/PNG/WebP 默认整页原像素显示：解码RGBA及压缩文件均≤16 MiB，最长边≤4096及已知纹理下界，8 bit、无ICC、Flutter descriptor与原生归一化尺寸一致。实验 early handoff、prepared-read等保持原开关。
- 巨图适屏输出在≤16 MiB及纹理边界内时，局部可见也保留整页；超过预算后使用ROI。清晰块逐区替换有效旧画面，透明像素只显示背景，避免重复alpha合成。重绘先筛掉不与可见区域相交的旧层。远程Raster仍保留原75%可见约束与协商网格。
- 阅读会话保存最近退场的本地画面，最多64 MiB/128项，并与所有可见/待交接画面共享192 MiB上限；可见工作优先驱逐闲置缓存。回看先打开原件并核对路径、身份、size/mtime/changed，再转移缓存图像句柄。缓存不持有原件租约。
- 元数据与整页codec准入结果另设128项LRU；命中后省去probe及descriptor，仍按当前纹理边界重新限制准入。缓存尺寸只用于等待阶段布局，像素仍须原件核验。源解析与Surface转圈均延迟500 ms，已有有效画面升级时不盖转圈。
- 刷新、内存警告、退出使缓存key失效，晚到旧工作不能回填。退出清理像素、元数据与路由所有权。

## 验证

不同测试合计 **141通过、1能力分支跳过**。包括实际PNG codec及native DLL probe的正常入口卸载/回看：第二次无需probe、descriptor或codec，没有短暂转圈；真实文件Surface回看像素一致、原件变化强制重解码、刷新旧层不能回填、退出账归零；局部巨图整页→ROI、alpha缺块、迟到旧源、远程局部网格；既有六种布局/清晰模式、缩放、原件保存分享冻结、取消与预算回归。

- [12文件组合](D:/picakeep-image-pipeline-022-work/reader-continuity-final-tests1007.log)：131通过、10因未配置外部fixtures跳过、1新测试诊断口径断言失败。诊断已将闲置会话像素计入resident，测试旧“卸载后resident=0”已改为保留量，关闭路由仍必须0。
- [整页/元数据最终8项](D:/picakeep-image-pipeline-022-work/reader-continuity-policy-final1007.log)：全部通过；native worker在widget test体结束前关闭，解决10秒idle FakeTimer的测试清理失败。
- [原生最终9项](D:/picakeep-image-pipeline-022-work/reader-continuity-native-final1007.log)：补配置既有E盘fixtures，9通过/1“缺prepared符号库”分支跳过。真实DLL取消、满队列、prepared miss与配额释放通过。
- [静态分析](D:/picakeep-image-pipeline-022-work/reader-continuity-analyze1007.log)：无问题。三项[Surface会话集成](D:/picakeep-image-pipeline-022-work/reader-continuity-retention1007.log)单独通过。重复测试未重复计入总数。

## 正常 Profile 交付

默认入口 `lib/main.dart`，D盘隔离快照869项、38,805,440 bytes，构建前后逐文件哈希0差异。首次增量APK有旧封装空洞，已仅在隔离目录clean、offline pub get后重建；最终assembleProfile118.0秒，最大ZIP间隙0，三个ABI原生库与上一正常包相同，Dart AOT哈希已改变且包含本轮会话缓存。见[干净构建](D:/picakeep-image-pipeline-022-work/reader-continuity-profile-build-clean1007.log)、[产物核验](D:/picakeep-image-pipeline-022-work/reader-continuity-profile-identity1007.json)。后续封面修复复用了快照脚本，误覆盖了该轮逐文件输入清单；原APK、构建日志和产物核验仍保留，不能把现有同名清单当成该轮输入。本轮后续脚本已改用独立清单文件名。

[正常APK](D:/picakeep-image-pipeline-022-work/picakeep-reader-continuity-profile1007.apk)：61,841,065 bytes，SHA256 `ACC866077394931559EC152767D46CAA20BD3F3514D63C15EB7C88905007118E`；package `lingxue.picakeep`，9/1.9.92，debug签名SHA256 `31b4434516ccc1f58add7cc5cd4b6786e995c957d5891d3685e4c75a7a58d7c7`。

显式备用机 `192.168.5.3:5555` 核对serial `8021129d`后，验证APK存在并 `adb install -r` 成功；首次安装时间仍为2026-06-29 16:42:23。正常MainActivity在前台、PID27720，主页及既有下载计数显示；该PID启动日志无所筛选的Flutter/FATAL错误。没有卸载、清应用数据、提交或push。主力机离线，保留此前正常包；桌面应用UI验收继续暂停。

## 尚未关闭的边界

像素与元数据复用本轮限定稳定的FileReaderPageSource；归档、远程、受限目录的Deferred临时原件未解决跨widget回看缓存，不能写成所有来源均已修复。超出会话容量、原件变更、内存警告或关闭阅读器后允许重解码；巨图最终仍收敛到当前可见原像素。真实用户作品的滚动/缩放帧时间、首帧等待及体验对比未测，新增真实入口codec主要为PNG，不能替代JPEG/WebP/EXIF与特殊色彩全质量验收。
