# 果核调查与022现代码对照

2026-10-07，Asia/Singapore。侧会话交接已由主会话接收；022保持执行中。本文件用于安排后续诊断与优化，不改变原计划目标和验收门槛。本轮只读复核报告/证据与当前源码，并更新交接文档，未改产品代码、构建或操作设备。

随后按用户“继续做”要求已实施阅读队列、native取消与本地漫画封面有界恢复，见 [实现与回归](reader-cover-recovery1007.md)。以下现代码对照保留接收调查时的状态，不作为随后修复后的行为描述。

## 用户问题与当前交付

用户反馈：分块加载和大图放大的视觉体验差；普通本地漫画阅读容易报错，需逐页手动重载；已下载漫画封面不加载、插画封面慢；希望理解参考程序的机制收益，排除只用Windows硬件强解释速度的做法。以上均为真实体验反馈，尚无本轮故障复现或确认的代码根因。

上一轮已交付正常 `lib/main.dart` 的1.9.92（versionCode 9）Profile APK，主力机显式 `192.168.5.4:5555` 覆盖安装并启动，签名匹配、保留应用数据。APK身份见 [CHECKPOINT](CHECKPOINT.md) 的“主力机正常 Profile 交付”。该交付证明构建、安装和启动，不证明本次用户数据集的问题已修复。桌面验证继续按用户要求暂缓。

## 接收证据与范围

参考对象是GuoheView 3.4.4.110、ghde 1.1.0.174、core-ui 1.8.0.307。侧会话没有改PicaKeep源码、git、构建或设备；生成样本与运行缓存位于独立分析目录。主会话重新逐文件复核清单的334项SHA-256，0缺失、0差异；综合报告SHA也与侧会话最终检查一致。

| 证据 | 来源与身份 | 用途及边界 |
| --- | --- | --- |
| E-G01 | [综合报告](D:/Flutter_Projucts/ReCall/GuoheView/docs/2026-10-07_逆向-GuoheView-comprehensive-report.md)，SHA `6BDF4E7FBFF61677ECB5039679671D065AEC91D0628F40D8E57D20FF8A5C16D9` | 静态调用链与隔离生成样本DLL实测；不是参考软件GUI首帧/缩放或手机性能 |
| E-G02 | [快开深挖](D:/Flutter_Projucts/ReCall/GuoheView/docs/2026-10-07_逆向-GuoheView-fast-open-deep-report.md)，SHA `0C4CE51B1D957A91EEA7998B2877AA3437E3E81E7D7AD792C9D8F34020107DED`；[初次报告](D:/Flutter_Projucts/ReCall/GuoheView/docs/2026-10-07_逆向-GuoheView-report.md) | 同机同DLL机制对照，不能将调用时间视为应用完整首显 |
| E-G03 | [334项证据清单](D:/ReverseTools/analysis/GuoheView-20261007/comprehensive-evidence-manifest.json)；[侧会话最终检查](D:/ReverseTools/analysis/GuoheView-20261007/comprehensive-final-verification.json) | 主会话只读核哈希；未重跑破坏生成缓存的实验、未再反编译或启动参考GUI |
| E-P01 | 下节当前Reader/封面代码链接 | 工作区只读对照，行号对应接收时源码；不代表当前APK中候选启用 |
| E-P02 | [封面A/B](cover-server-results.md)、[准入诊断](prepared-admission-and-roi-diagnostics1006.md)、[色彩矩阵](color-animation-profile-results.md)、[CHECKPOINT](CHECKPOINT.md) | 各自固定快照的PicaKeep证据，历史测量不得拼成全范围通过 |

公开ghde接口101项和core-ui相关方法100项的提取成功不等于全部代码或格式验收。报告中的格式/阈值、错误码、色彩和取消结论保留各自的样本限制；尤其Guohe与PicaKeep native错误码属于不同命名空间，不直接复制数字含义。

## 参考程序机制如何用于判断

| Finding与证据 | 已观察机制 | 对022的判断 |
| --- | --- | --- |
| F-G01 / E-G01 F-201/202/203 | 内容探测与解码能力分流；普通图/巨图策略参考像素开销、格式、内存；JPEG缩放解码减少展开像素 | 支持设备预算内稳定整页及格式专用快路；PNG不能据targetWidth推断同样收益。JPEG仍读完整压缩流 |
| F-G02 / E-G01 F-202 | 两边≤6000时单层，任一边>6000时逐次减半；6000×768与6001×768样本为1/5层 | 这是缓存层级规则，单层也有瓦片；与主程序whole-image选择不同，不直接移植6000手机阈值 |
| F-G03 / E-G01 F-204 | 预览/较粗层填缺失区域，再画清晰块；保留上一活动层并合并更新；提示延迟500ms | 支持改善缺块稳定性和重绘；未证明每块淡入。500ms为提示延迟，不能算速度承诺 |
| F-G04 / E-G01 F-205/206/208/209 | 源路径/存储模式/大小/mtime身份；临时构建后提交；stale重acquire再open一次；取消并非总能立即停止重解码 | 支持按类型有界恢复、有限并发、当前页优先及过期结果丢弃；未覆盖所有竞争/强杀场景 |
| F-G05 / E-G01 F-207/211/212 | 预览有损、部分存储模式不保原RGBA；源文件复制/完整源图转码独立于显示缓存 | 快显缓存不能冒充最终原像素。EXIF6/JPEG ICC实测不等于全格式色彩/HDR通过 |
| F-G06 / E-G01 F-210/213/214 | 动画、TIFF多页、Shell缩略图和WinRT PDF是不同路径 | Shell缩略图DLL不证明软件内漫画库封面缓存；多页不套用全部动画接口，PDF只有限定组件识别 |

机制对照可以说明速度存在软件策略因素；当前没有控制相同硬件、相同应用GUI首显的完整比较，不能量化排除Windows硬件贡献。DLL数值也不能换算为手机P95。

## 对照当前PicaKeep

### 阅读失败、取消和分块

- [Surface失败记录](D:/Flutter_Projucts/PicaComic/PicaKeep/lib/pages/reader/reader_image_surface.dart:144) 已按variant保存失败，失败variant暂不重请求；viewport淘汰、source/策略变化和显式重试会清相应状态。邻块成功只清自己的失败，避免掩盖未完成区域。[失败测试](D:/Flutter_Projucts/PicaComic/PicaKeep/test/reader_image_surface_test.dart:1072)刻意避免自动重试循环。风险是暂态异常若进入终态会等待用户操作，但尚未证明用户漫画错误发生在这里。
- source切换/离开viewport会取消token或ticket；回调复核generation/ticket，过期结果不发布。scheduler有 [ImageWorkCancelled](D:/Flutter_Projucts/PicaComic/PicaKeep/lib/foundation/image_pipeline/image_work_scheduler.dart:141)；native取消分类及错误转UI仍需实测。不要把主动取消当损坏源图，也不要对所有失败无界重试。
- [Reader backend选择](D:/Flutter_Projucts/PicaComic/PicaKeep/lib/pages/reader/reader_page_image.dart:167) 已在非动画、原RGBA和压缩文件均≤64MiB时选择Flutter；[Surface请求分支](D:/Flutter_Projucts/PicaComic/PicaKeep/lib/pages/reader/reader_image_surface.dart:480)已有缩小整页和网格等路线。因此不能描述为普通漫画全部强制分块。默认缩小整页还受density<1、输出≤16MiB及可见源覆盖≥75%约束。
- `fullOrdinaryImage`、`nativeLargeFit`、`viewportRegion`、`preparedReadAdmission`等实验开关默认关闭；[正常image_view入口](D:/Flutter_Projucts/PicaComic/PicaKeep/lib/pages/reader/image_view.dart:65)没有传入这些开关。profile工具启用候选所得结果不得写成正常主程序已启用或必然受益。
- [Painter](D:/Flutter_Projucts/PicaComic/PicaKeep/lib/pages/reader/reader_image_surface.dart:1183)在sharpFirst排除不足目标density的层，previewFirst允许粗层回退，并按清晰coverage裁剪低层，避免alpha重复合成。每块完成仍触发setState。后续可评估短暂缺块期间的合适旧层/预览、合并重绘；须保持最终清晰结果和alpha/gutter契约，不能简单取消质量判断。
- [native交接](D:/Flutter_Projucts/PicaComic/PicaKeep/lib/foundation/image_pipeline/reader_raster_backend.dart:639) 已用decodeRegion，premultiplied RGBA交给 [ImageDescriptor.raw](D:/Flutter_Projucts/PicaComic/PicaKeep/lib/foundation/image_pipeline/reader_raw_image_decoder.dart:123)。不能再以“显示主链路仍PNG编码中转”为改造依据；PNG用于另一条持久派生raster缓存。
- [native core](D:/Flutter_Projucts/PicaComic/PicaKeep/packages/picakeep_image_engine/native/src/image_core.cpp:1247)已有条件受限的quick JPEG、非交错PNG whole-fit及backing采样；其他cold路径先ensure_backing。decodeRegion接口不代表每种格式首次都只解码可见区域。prepared-only miss/stale已有独立cold准入回退，不能据API名称承诺成本。

### 封面持久性和恢复

- [LocalCoverCache](D:/Flutter_Projucts/PicaComic/PicaKeep/lib/foundation/local_cover_cache.dart:154)已有应用内持久封面副本，sourceId/originalId/源标识及路径/size/mtime身份，缺文件修索引，`.part`、flush、rename提交；[下载封面登记](D:/Flutter_Projucts/PicaComic/PicaKeep/lib/foundation/local_library.dart:1059)也已接入。先查真实失败走哪条来源和入口，不从零重复建缓存。
- [CoverThumbnailCache](D:/Flutter_Projucts/PicaComic/PicaKeep/lib/foundation/cover_thumbnail_cache.dart:126)的派生键包含源身份、尺寸桶与版本。warm命中持久结果，cold先交付ui.Image，消费帧后后台持久化；发布核generation和源身份，后台有预算及待写上限。普通图/特殊图已有解码分流。
- [插画队列](D:/Flutter_Projucts/PicaComic/PicaKeep/lib/pages/illust_work_queue.dart:142)已有可见封面优先、并发2、滚动时单路/120ms启动节流、最多两次有限重试和离屏/过期保护。读源失败4秒负缓存与真正无封面10分钟负缓存不同，新页面/权限session会清负缓存；不能将所有失败都解释成永久缓存。
- [漫画卡片](D:/Flutter_Projucts/PicaComic/PicaKeep/lib/components/comic_tile.dart:375)已有物理框解码目标和惰性本地provider，但普通errorBuilder只显示缺图图标。插画恢复不能概括为全部已下载漫画封面入口都已覆盖；需复现检查provider解析、源访问和恢复事件。
- native encoded PNG候选双端冷P95均退步，继续默认关闭。Android 4096 PNG→384默认/候选232.979/338.911ms，ZIP→768为192.403/475.305ms；Windows为104.379/129.735ms及80.736/225.293ms。暖命中收益不能作为启用冷路径依据，完整表见 [封面A/B](cover-server-results.md)。

## 后续执行顺序与验证

| 顺序 / Path | 操作及证据链 | 判断完成的条件 |
| --- | --- | --- |
| P-01 真实页失败→错误分类→有界恢复 | 用户反馈＋E-P01＋F-G04：记录实际源路径/身份、漫画/页ID、会话generation、decode/backend阶段、取消原因、原始错误码及缓存状态；区分主动取消、资源暂态、派生损坏与真实源失败 | 同一故障样本复现及诊断根因；可恢复失败无需逐页手动重载；不可恢复失败仍准确呈现；无循环/串图/泄漏 |
| P-02 封面入口→持久命中→失败恢复 | 用户反馈＋E-P01＋F-G01/04：分别复现已下载漫画与插画；检查已有身份/尺寸键、失效、权限session、可见队列、reader/封面预算竞争 | 首屏冷/暖指标分开；缺失/损坏/替换源和权限恢复受控；滚动可见封面可靠出现，原文件未改 |
| P-03 普通页预算→稳定整页→原件放大 | F-G01/02＋E-P01/02：按手机像素/工作内存/纹理预算及格式选择普通页路径；先对照正常入口默认策略与候选，超过预算才增加区域/多层任务 | 普通页不退步、巨图无OOM；原像素放大清晰；同源同快照profile对照、完整布局/模式与资源回收证据 |
| P-04 缺块→旧层填补→清晰局部替换 | F-G03＋E-P01：评估sharpFirst缺块过渡、保留有效层及合并重绘，结合连续缩放和快速翻页 | 录屏及计时验证空白/闪烁/串图/清晰收敛；最终像素、alpha/gutter不回退；不以延迟提示掩盖加载 |
| P-05 原文件→保真显示/原件导出 | F-G05/06＋E-P02：方向、ICC、alpha、动画/多页及原文件保存分开验证，保留现有Android/Windows能力边界 | 质量、原字节保存、真实UI、稳定OS baseline、性能与最终回归分别达到既有标准 |

以上是主会话接受的诊断优先顺序，不是以参考报告替代原022全量交付。prepared-read/准入等性能候选仍关闭；速度绝对门槛、稳定OS warm基线和完整正常UI/回归仍待完成。未经真实页面日志，不能把_tileFailures、路径解析、权限或缓存任一项写成已确认根因。

手机与桌面可共享调度、缓存身份/恢复、普通/巨图分流、回退绘制与原文件导出的设计。Android与Windows原生解码、系统交互、D2D/DirectComposition、Shell COM、WinRT PDF及显示器色彩分别验收；手机结果不替代桌面通过。

## 本轮校验

证据复核以只读 `Get-FileHash -Algorithm SHA256` 对清单每项比较；来源报告链接、本文与交接新增链接检查存在，新增Markdown无尾空白。文档改动不需要运行应用测试。本轮未重跑DLL实验、未构建/安装/启动任何程序，未修改用户媒体或应用数据，也未commit/push。
