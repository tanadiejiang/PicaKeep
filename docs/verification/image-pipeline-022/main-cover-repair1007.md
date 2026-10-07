# 2026-10-07 · 主力机已下载封面恢复，插画性能继续调查

用户自行构建后，已下载列表五本作品封面均为错误占位；清缓存也不能恢复。主力机只读核对发现，`current_download.json` 保留的五条应用内封面路径全部不存在。此前共享缓存改动纳入了可再生封面，但下载列表直接使用持久化路径，遗漏文件删除后的重新解析。该遗漏已经修复；不能确定首次删除是哪个具体清理动作造成的。

已下载条目现在通过统一解析器惰性读取，失效路径会从下载原件恢复；同源普通重建保留 provider，刷新代次更新解析回调。清理优先淘汰闲置 native/cover backing，再按时间淘汰其他缓存；仍遵守用户容量、活动租约和保护路径。插画缩略图补了非空坏文件的一次重建、准备图过期后的持久化以及旧发布拒绝。已解码的首图可以在队列暂停后直接显示。

## 验证与交付

- 封面、分页/分辨率升级、队列、收藏、文件缓存和配额回归142项；独立缓存保留回归19项，共161项通过。最终静态分析11个文件无问题，格式检查0变化。新下载测试初次清理遗漏 `LocalTrashStore` SQLite句柄，关闭后重跑通过；未改功能期望。
- 正常 `lib/main.dart` profile，`flutter build apk --profile --target-platform android-arm64`，无诊断开关。隔离快照869项/38,813,112 bytes与工作区SHA一致，450项实际编译输入用本地Flutter SDK算法核对0差异。干净构建114.3秒，版本1.9.92+9，签名匹配、ZIP CRC通过且最大间隙0，三个ABI原生引擎不变，Dart AOT已更新。
- [APK](D:/picakeep-image-pipeline-022-work/picakeep-main-cover-repair-profile1007.apk) 61,841,065 bytes，SHA256 `D55E307653785BF603FD3079AD73722173277C1A3142CF3A1D574ADB4A2BA0FD`；[身份核验](D:/picakeep-image-pipeline-022-work/main-cover-repair-profile-identity1007.json)、[测试日志](D:/picakeep-image-pipeline-022-work/main-cover-repair-regression-complete1007.log)、[缓存保留测试](D:/picakeep-image-pipeline-022-work/cover-cache-retention-final1007.log)。快照复制与clean构建曾并行，mtime本身不能证明编译顺序；实际编译器输入哈希补充核验已通过。
- 显式设备 `192.168.5.4:5555`、serial `f294cd23`、22127RK46C，核APK存在/哈希后 `adb install -r` 成功。首次安装时间仍为2026-10-01 23:32:23，未卸载/清数据。实际已下载首屏五张封面全部恢复；只读核原缺失缓存分别为95,415/66,546/64,091/96,397/97,121 bytes。用户随后确认“现在已下载漫画的封面加载正常”。[设备核验](D:/picakeep-image-pipeline-022-work/main-cover-recovery-device1007.json)、[已下载页面](D:/picakeep-image-pipeline-022-work/main-cover-repair-ui1007/startup.png)。

## 插画尚未收口

用户确认剩余问题为滑到没看过的图慢，返回后重新进页又加载。实际插画首屏六张已可显示，不代表首屏速度达标。`pixiv_download.json` 是另一来源，不能用它的22条旧缓存路径代表当前插画主目录；当前页面来自 `pixiv_folder...root.json`。

用户明确指出当前只授予Android读取全部文件权限；主力机只读核对Root/Shizuku设置均为0、`MANAGE_EXTERNAL_STORAGE` UID mode为allow。此前将源码中的特权回退及多次su静态成本归因为当前设备瓶颈不准确，已明确撤回。单图先判文件能省四次缺失子路径检查，但普通权限下可能只节省毫秒，不能声称解决当前加载慢。

下一步对真实正常页面记录来源解析/读取/写盘、缩略图codec、排队和热缓存重进页的阶段耗时。仅阶段或provider时间不能替代首次呈现；冷/热与页面重入分开核验。022继续执行中，桌面UI/性能按用户要求仍暂缓。
