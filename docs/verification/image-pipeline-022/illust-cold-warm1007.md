# 2026-10-07 · 插画冷加载与重进页面复用

用户确认已下载封面恢复后，反馈插画滑到新图慢，退出后重进又加载。主力机只有Android全部文件权限，Root/Shizuku开关均0。此前将特权回退调用次数作为当前设备根因不准确，已经撤回；本轮以正常页面的实际阶段计时为依据。

## 实际发现

默认入口 `lib/main.dart` profile临时开启 `PIKAKEEP_COVER_DIAGNOSTICS=true`，在主力机正常插画页面采样，不清缓存、不删文件、不下载内容。旧管线一次滑动窗口里，5个解码队列等待303.859–2130.826ms，两次PNG持久化编码654.116/2053.504ms；原生probe306–407us，原图读取12.796/18.605ms。另有5499×7933 JPEG的nativeRaster阶段2135.571ms，不能把所有等待都归因读文件。数据见 [原始时间线](D:/picakeep-image-pipeline-022-work/illust-main-new-scroll1007.json) 与 [分段统计](D:/picakeep-image-pipeline-022-work/illust-main-new-scroll1007.summary.json)。这是小样本阶段时间，未做N30或首次呈现统计。

代码核对也发现：磁盘缩略图尚未生成时，`prepareProvider` 不看已完成的Flutter内存缓存，先重解原图；页面比例变化又让外层`CoverDecodeKey`变成不同尺寸键。阅读器退出还无条件清全局图像缓存，影响已经移除监听器的列表封面跨页面复用。

## 已实施

- 有界准备封面以源指纹、宽度档位和发布代次作为缓存身份；其像素自身已受4096边长/4Mi像素上限约束，普通`CoverDecodeTarget`直接显示并共用一个稳定键，不随占位比例变化重复解码。更严格的调用方尺寸上限仍保留原缩小路径。只接受已完成的live/keepAlive缓存，排除pending；每次保留当前页面的新取消回调，文件或代次变化拒绝旧图。
- 插画队列有可见封面任务或正在滚动/收尾时，延后可选PNG编码，等待发生在调度提交前，不占解码槽。暂停、切页、销毁释放等待；多页等待幂等，仍保留32项/32MiB克隆预算。已经开始的编码不能被抢占，这是当前限制。
- 在768/1536之间增加1024宽度档。主力机约935物理像素目标现在落1024，维持原1.35倍两轴采样目标；输出不低于请求，减少此前升1536带来的像素与编码量。没有启用尚未验收的native encoded候选。
- 阅读器退出恢复共享缓存限额，保留列表封面的已解码缓存；阅读会话Surface/像素LRU、原件租约与工作预算仍独立释放。单图JPG/PNG先判真实文件，省四次无效子路径探测；特权stat同时补只接受普通文件的契约，图片后缀目录继续回退。普通权限下此探测优化不能解释秒级速度改善。

## 验证

最终两组不同测试47+77，共124项全部通过，覆盖真实wrapper跨路由复用、持久化尚未完成时零重复原图解码、pending排除、源替换/发布失效、坏图/缓存删除恢复、尺寸/DPR升级、远程普通provider、native候选边界、可见队列/编码等待、reader资源全部归零。静态分析15个文件无问题。新目录探测计数初次遗漏字节读取器的存在性检查，按真实IO口径修正为四次并重跑；没有放宽功能期望。[第一组](D:/picakeep-image-pipeline-022-work/illust-cold-warm-fixes-first1007.log)、[第二组](D:/picakeep-image-pipeline-022-work/illust-cold-warm-regression-final1007.log)、[分析](D:/picakeep-image-pipeline-022-work/illust-cold-warm-analyze-final1007.log)。

固定后第一次进页的窗口实际包含不同位置的新图，不能称同一内容的前后速度对比，也不能用它计算改善百分比。该窗口原生阶段187–567ms、PNG编码369–880ms只是此次样本。[时间线](D:/picakeep-image-pipeline-022-work/illust-fixed-main-warm-reentry1007.json) 保留原文件名，但该窗口有7次原件读取，明确是冷/暖混合。

随后退出列表并重进同一“全部文件夹”首屏：9次 `thumbnail.memoryHit`，0原图读取、0cacheStat、0原生probe/原生解码、0Flutter冷/暖codec。来源验证每项1.101–6.877ms；仅此阶段时间，不是整页首次呈现。相同首屏截图显示已有封面正常。[真实重进时间线](D:/picakeep-image-pipeline-022-work/illust-fixed-main-warm-repeat1007.json)、[统计](D:/picakeep-image-pipeline-022-work/illust-fixed-main-warm-repeat1007.summary.json)、[页面](D:/picakeep-image-pipeline-022-work/main-cover-repair-ui1007/fixed-warm-reentry-repeat.png)。这是所观察的九张封面，不能扩展成全部资源永不淘汰或跨应用重启无需解码。

## 正常包交付

临时计时包实测后，已恢复不带Dart defines的正常 `lib/main.dart` profile。隔离快照869项/38,820,280 bytes与工作区逐文件SHA一致，且与固定计时包产品源完全相同；450项实际编译器输入哈希一致。clean、offline pub get后 `flutter build apk --profile --target-platform android-arm64` 成功，assembleProfile122.0秒；签名匹配、ZIP CRC通过/maxgap0、三个native ABI库保持原样，Dart AOT已更新且计时前缀不存在。此前固定计时版增量构建产生23,208,688字节ZIP空洞，已拒绝交付并clean重建，不曾安装该产物。

- [最终正常APK](D:/picakeep-image-pipeline-022-work/picakeep-illust-cold-warm-profile1007.apk)，61,841,065 bytes，SHA256 `AAB57CE156644DBB0F6ADEE69E9D9602A330AEAD6EEE19738CB41A51A9A7CFFD`，version9/1.9.92。
- [产物核验](D:/picakeep-image-pipeline-022-work/illust-cold-warm-profile-identity1007.json)、[输入清单](D:/picakeep-image-pipeline-022-work/illust-cold-warm-normal-inputs1007.json)、[正常构建](D:/picakeep-image-pipeline-022-work/illust-cold-warm-normal-build1007.log)。
- 主力机显式 `192.168.5.4:5555`、serial `f294cd23`，核APK存在/哈希后 `adb install -r` 成功；首次安装时间保持2026-10-01 23:32:23，最终更新时间14:50:46。无卸载、清数据、release、commit或push。已移除本次VM端口转发。正常主页与同一插画首屏均实机可进入、封面可见：[最终页面](D:/picakeep-image-pipeline-022-work/main-cover-repair-ui1007/normal-final-illust.png)。

当前主力机保留最终正常Profile。已下载故障已由用户确认恢复，插画重复解码在本次九张重进样本得到验证。新图的排队/尺寸成本已调整，但巨图首次原生解码、完整冷数据集与绝对首屏性能仍未验收；022继续执行中，桌面UI/性能仍按用户要求暂缓。
