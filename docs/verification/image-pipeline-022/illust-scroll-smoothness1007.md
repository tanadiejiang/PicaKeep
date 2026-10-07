# 2026-10-07 · 插画加载时滚动卡顿续修

用户在上一份正常包上仍反馈封面稍慢、加载时滚动卡顿。本轮继续主力机普通 Android 全部文件权限路径；桌面验证仍暂缓，022 仍执行中。

## 改动与依据

1. 插画 `SliverLayoutBuilder` 原先每次 scrollOffset 变化都创建新瀑布流内容和 child delegate，连屏内已有卡片也重新构建。现在父页面构建一次内容 widget，滚动布局仅更新真实列宽及封面档位并返回同一对象；筛选、设置、列数及逐卡片 revision 更新仍生效。没有改变图片比例、文字高度、标签布局或内容裁切。
2. 已有磁盘 PNG 的 buffer、descriptor、codec 和首帧原先绕过解码调度。现在进入同一 cover 队列并在分配前预留输出及编码副本预算；排队、预算和取消错误直接传播，不误删有效缩略图或触发原件重解码。完成的内存缓存仍直接复用。
3. 大尺寸普通 JPEG 封面增加 Flutter 目标尺寸解码：只接受完整 first-scan header、SOF0、8-bit、1/3 components、无 ICC、无旋转的静态图片，拒绝 progressive/CMYK/异常或超限 header。源 RGBA 在 64–256MiB、编码文件最多32MiB、源边最多16384，输出仍最多4096边/4Mi像素；预算保守计两个完整源位图、编码副本及输出，另保留实际可用内存余量。其它格式及阅读原像素路径保持现有实现；读头、排队、codec、源变化和取消均检查。既有合法 native 缩略图继续有效，没有使整个缓存失效。
4. 可选 PNG 持久化等待可见工作结束并连续空闲400ms；如果排队后又开始滚动，释放调度槽后等待重试，保留持久化机会。后台预热也在解码和编码前等待空闲。已运行的编码仍无法抢占，不能承诺滚动时完全没有后台编码。

## 定向验证

11 个测试文件共 **172 项通过**，覆盖真实暖 PNG 入队前零 buffer 分配、队列/预算拒绝不删图、离页及发布失效、持久化等待时恢复滚动后重试、跨页内存复用、坏缓存恢复、真实大 baseline JPEG 的目标解码/原件不变/无 raw backing、源替换、取消/可用内存下降、卡片布局、瀑布流和阅读缓存。6 个改动文件静态分析无问题，diff whitespace 检查通过。

- [最终测试](D:/picakeep-image-pipeline-022-work/illust-scroll-tests-final1007.log)
- [分析](D:/picakeep-image-pipeline-022-work/illust-scroll-analyze-fixed1007.log)

首次测试暴露闭包捕获 nullable descriptor/codec 的编译问题，已修正。新增暖加载测试最初跨 fake/real 异步环境等待未完成 ticket 挂起，已中断并改成有界 pump 和 runAsync；JPEG 首次绘制测试最初在 wrapper 尚未返回图像时读取 RawImage，已补有界等待。素材另经 Pillow 完整解码验证。最终172项全部重跑通过，没有放宽像素、取消或资源期望。

## 主力机实际采样

临时计时包为正常 `lib/main.dart` profile 加 `PIKAKEEP_COVER_DIAGNOSTICS=true`。每窗口6次相同坐标/650ms滑动，不在录制期间截图或 dump UI，不清缓存、不删除下载。UI 使用 Framework Frame wall scope，raster 使用 GPURasterizer::Draw，通过 engine frame_number 配对；8.333ms来自实际120Hz引擎预算。它们不是 SurfaceFlinger 呈现时间、GPU完成或屏幕掉帧统计。

| 窗口 | UI帧数 | UI P95 / max ms | raster P95 / max ms | UI / raster >8.333ms |
| --- | ---: | ---: | ---: | ---: |
| 旧包首次混合窗口 | 196 | 7.396 / 33.595 | 1.833 / 9.822 | 7 / 1 |
| 旧包重进暖窗口 | 196 | 7.154 / 13.431 | 1.471 / 11.035 | 2 / 1 |
| 新包首次混合窗口 | 227 | 5.110 / 23.318 | 1.987 / 9.670 | 1 / 1 |
| 新包重进暖窗口 | 255 | 4.491 / 6.496 | 2.279 / 11.309 | 0 / 2 |

同页暖窗口的 BUILD begin scopes 从2282降到281（每UI帧11.64到1.10）；ImageCache.putIfAbsent begin 从2052到6，这是查缓存事件，不能称2052次解码。LAYOUT P95从1.899降到0.304ms。此小样本支持消除重复布局，但窗口长度/帧数不同，没有N30或严格同原图冷加载A/B；raster没有同步改善，不能声称所有指标都改善或卡顿完全消除。

新包首次混合窗口最差23.318ms帧含19.741ms LAYOUT、0.436ms BUILD、2.882ms SEMANTICS，与GC/封面阶段均无时间重叠，仍是未细分布局长帧，不能归因图片解码或GC。旧33.595ms帧也以27.923ms布局为主。

实机确实观察到两个符合条件的5299×3240、5072×8848 JPEG走Flutter目标解码，输出1024×627、1024×1787；对应 getNextFrame 阶段239.753/543.137ms，不是首次呈现时间，也不能与另一尺寸旧图计算改善比例。归档提取、原件暂存及较大/特殊格式首解码仍可能慢。

新包暖窗口6张封面均复用内存，原图读/冷解码/暖codec均0次。随后另一位置窗口实际为6次磁盘暖加载，239 UI帧P95 4.816ms/max7.656ms，238 raster周期P95 2.391ms/max4.786ms；不得把文件名 `fixed-new` 当未看过原图冷样本。后台PNG编码仍有238–1467ms阶段，不在本轮宣称其全部消失。

只读 idle meminfo 两次 RSS为275140/476064KiB，状态与缓存驻留不同且没有峰值连续采样；本轮不宣称内存下降或完整RSS门槛通过。

- [旧首次帧分析](D:/picakeep-image-pipeline-022-work/illust-scroll-baseline-run1007.frames.json)、[旧暖分析](D:/picakeep-image-pipeline-022-work/illust-scroll-baseline-warm1007.frames.json)
- [新首次帧分析](D:/picakeep-image-pipeline-022-work/illust-scroll-fixed-first1007.frames.json)、[新暖分析](D:/picakeep-image-pipeline-022-work/illust-scroll-fixed-warm1007.frames.json)、[另一位置暖分析](D:/picakeep-image-pipeline-022-work/illust-scroll-fixed-new1007.frames.json)
- [暖窗口阶段](D:/picakeep-image-pipeline-022-work/illust-scroll-fixed-warm1007.summary.json)、[首次阶段](D:/picakeep-image-pipeline-022-work/illust-scroll-fixed-first1007.summary.json)
- [独立对照与证据哈希](D:/picakeep-image-pipeline-022-work/illust-scroll-comparison1007.json)、[可复现对照脚本](D:/picakeep-image-pipeline-022-work/compare-illust-scroll-captures1007.py)。JPEG事件只有尺寸/源字节数和时间窗口，没有共享源ID/SHA，不称同原图配对。

## 最终正常包

已经恢复正常 `lib/main.dart` profile，无用户Dart defines/诊断入口。独立快照870项产品文件与计时包/当前工作区完全一致，451项实际编译器输入哈希一致。clean、offline pub get后正常构建成功（122.6秒）；versionCode9/versionName1.9.92、既有debug签名匹配、ZIP CRC通过/maxgap0，三个native ABI库未改，Dart AOT已更新且封面计时前缀不存在。

- [正常APK](D:/picakeep-image-pipeline-022-work/picakeep-illust-scroll-profile1007.apk)，61,841,065 bytes，SHA256 `D5250610FD7BEDA7217E43D1A071A58534EBCDB475BFFD8DFD8720753C00E328`。
- [正常身份](D:/picakeep-image-pipeline-022-work/illust-scroll-profile-identity1007.json)、[构建](D:/picakeep-image-pipeline-022-work/illust-scroll-normal-build1007.log)、[安装](D:/picakeep-image-pipeline-022-work/illust-scroll-normal-install1007.json)。
- 主力机显式设备192.168.5.4:5555/serial f294cd23，核APK存在/哈希后install-r成功，firstInstallTime仍为2026-10-01 23:32:23，lastUpdateTime15:33:44。无卸载或清数据，正常主页/插画首屏已查看，六张完整封面可见；本进程启动/进页错误过滤命中0。[最终插画页面](D:/picakeep-image-pipeline-022-work/main-cover-repair-ui1007/normal-scroll-final-illust.png)、[错误检查范围](D:/picakeep-image-pipeline-022-work/illust-scroll-normal-errors1007.json)。
- 本轮38123 VM端口转发已移除，既有其它转发未动。没有release、提交或推送。当前主力机保留此正常Profile；未宣布022全链路验收完成。
