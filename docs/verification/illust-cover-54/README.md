# 54 号：本地插画封面加载优化验收记录

代码直接修改于 `D:/Flutter_Projucts/PicaComic/PicaKeep` 的 `main`，基线 `f195aa5`。本轮只完成源码和本机自动化阶段；真实设备首屏时间、120Hz 帧指标、root/Shizuku 和内存平台仍需复测。不得把代码中的等待关系消除，表述为已经实测解决了“12 秒”。

## 原因与证据边界

| 证据 | 结论 | 本次落点 |
| --- | --- | --- |
| 原 `_resolveIllustDecoration` 等待 cover 后又等待 `resolveIllustEntryInfo`，最后才 publish | 封面已经准备好仍会被页数/尺寸补齐拖延；代码上可确认 | `illust_work_queue.dart` 分封面与元数据两阶段；可见封面优先，元数据最多占一条通道，共享总并发 2 |
| 原 `prepareDisplay` 原子发布后 await 全局缓存遍历，仍占串行生成队列 | 配额维护阻塞当前结果返回及后续缩略图；代码上可确认 | 维护合并为独立异步任务；新发布的文件持有保护引用，清理前再次检查 |
| 普通 provider 构造 key 时 `statSync`，但 51 后实际插画卡片主要消费 `_illustCovers` | 确有同步 I/O 缺口，但不能说每卡每帧都调用，更不能认定是全部尖峰的原因 | 指纹只在异步解析时准备；build 读取内存身份和版本号，图集已有 FileImage 快路径保留 |
| 未托管的封面走整份字节读取；managed 已有统一缓存和分档缩略图 | 应补齐未托管分支，不是从零建立缩略图架构 | 外部封面先经原有普通/特权读取到应用内缓存，后续统一走 prepareDisplay，暖加载不读原图字节 |
| 旧负缓存已有 10 分钟 TTL，存储 helper 将权限失败与空目录折叠为 null | 不是永久失败，也不能把 null 当“确定无封面” | 不再持久化新 sentinel；不明/读取失败 4 秒 TTL，队列 5 秒间隔最多自动重试 2 次；页面重进/恢复/权限重载清负记录但保留成功缓存 |

53 号尖峰数值重复本身不能证明确定性阻塞：呈现时间差天然按刷新周期量化。SurfaceFlinger 的 present 间隔也不是 Flutter UI/raster 的执行耗时。保留 52/53 原始观测，但后续应同时读取 Flutter FrameTiming/DevTools 和系统呈现；不得把 1.29% 直接代入 UI/raster 指标。“等待 12 秒后截图全可见”也不足以计算精确加载时长或阶段占比。

## 行为与保存位置

- 原图、目录、ZIP 都只读取。新增封面和分档缩略图位于 `App.dataPath/local_library_cache/covers` 及 `thumbs`。
- root/Shizuku 读取保持现有存储 helper。只有应用内文件进入插画列表的 FileImage；不以外部 `exists` 为读取权限证明。
- 普通图集已有封面依旧使用原来的文件缓冲读取，不为此次插画优化强制进入原始字节堆缓存。
- 384/768/1536 分档和长图限制保留；大于 1536 或缩略图失败时的内部原尺寸回退使用带指纹的 FileImage，避免同路径覆盖后继续显示旧图。
- 同一外部封面暂存/缩略图生成可被多个页面共享，首个调用者取消不影响其他活跃消费者；全部消费者取消后停止后续阶段。已经开始的文件读取/解码不能强行中断。
- 元数据与封面总并发仍为 2；元数据至多 1 项。滚动/后台/覆盖路由不启动新的队列任务；取消、重载、图像错误重试均校验代次，过期结果不能覆盖新结果。
- 不新增数据库协议，不移动用户文件，不更改下载队列或后台下载服务。

## 自动化与复跑

最终回归：全量 **2210 通过、14 跳过、0 失败**（`full-tests-final.txt`）；定向 **65 通过**（`targeted-tests.txt`）；`dart analyze lib test` **No issues found**（`analyze.txt`）；profile 构建成功（`profile-build.txt`）。`full-tests.txt` 是复核边界修正前的一次全量结果，最终结论以 `full-tests-final.txt` 为准。

产物为 `build/verification/illust-cover-54/app-after54-profile.apk`，版本 `1.9.88+5`，119,465,307 字节，SHA-256 `D110E7B9ED380BAC287CA10A87CE4F7F04BBE0E644A6E008EC4A8482E5F455EC`，`apksigner verify` 通过。旧包另存 `app-before54-profile.apk`，没有覆盖留存基线。最终 APK、源码摘要和运行身份见 `artifact.json` 与 `source-manifest.json`。

2026-10-03 16:02（UTC+8）`adb devices -l` 无设备。本轮未安装 APK、未卸载或清数据；包的签名已验证，但尚未完成与设备当前安装包的签名匹配核验。

```powershell
# 在主仓库根执行
dart analyze lib test
flutter test --no-pub --reporter expanded
flutter test --no-pub test/illust_thumbnail_test.dart test/illust_work_queue_test.dart test/local_cover_cache_test.dart test/pixiv_folder_cover_integration_test.dart test/local_library_page_view_scope_test.dart test/pixiv_folders_page_test.dart --reporter expanded
flutter build apk --profile --no-pub --dart-define=PIKAKEEP_COVER_DIAGNOSTICS=true
```

本次新增回归覆盖：阻塞元数据时先发布封面、新进入视口封面优先、后台/离屏/代次失效、有限失败重试、慢维护不挡下一张缩略图、共享任务取消、缓存保护引用计数、普通图集文件缓冲快路径、无磁盘访问的 provider 构造、真实替换后解码到新尺寸（含 2000 宽回退）、非托管封面暖缓存零源字节读取、短负缓存过期与重进恢复。现有目录/单图/ZIP、复制、根迁移、页面多选操作回归继续通过。

诊断只在 `kProfileMode` 且 `PIKAKEEP_COVER_DIAGNOSTICS=true` 时启用；默认关闭。不逐帧落盘、不输出作品路径/账号。DevTools 时间线事件为 `IllustCover.resolve`、`source.resolve`、`source.read`、`source.bytes`、`archive.index/extract`、`thumbnail.wait/read/decode/encode/generate`、`thumbnail.hit`、`provider.ready`、`queue.*`。异步 span 可能嵌套/含等待，不可把所有 span 相加当作 CPU 时间。`provider.ready` 是准备完成，不等于已经呈现在屏幕上。

## 真机余项与验收口径

1. 使用实际安装 APK 的 SHA、构建参数、设备 ID 核对身份；版本名相同不能证明源码相同。设备包名为 `lingxue.picakeep`。
2. 同一设备/库/权限/刷新率记录冷暖首屏、长滚动、开图返回各 3 次；首张和整屏可见从进入动作到实际 image frame 计时，记录每次值与中位数。无有效旧基线时只报告绝对值，不能编造提升百分比。
3. 读取 UI/raster 帧耗时、>33ms 尖峰、PSS 与队列，5 轮不持续增长；暖滚动 UI/raster 任一 >8.333ms 占比目标 <=1%。52 的 SurfaceFlinger 样本只作辅助，不混用口径。
4. 核对长图/高 DPI、可访问性、普通权限与 root/Shizuku、权限撤回恢复、缓存删除、复制/移动/根迁移后的图片身份。缓存失效验证不得删除作品或清除应用数据。
5. 安装必须另获明确授权，核对现有 debug/profile APK、签名、包名和显式设备 ID。禁止卸载、清数据、release。现有 52 号验收仍未关闭。

## 决策与残余风险

- 选择解除确定的等待依赖，不重写压缩包/图片库，不增加全库预热；避免把 53 的猜测当成主因。
- 选择保留全尺寸内部回退并给 provider 加指纹，不强行压到更小档位以掩盖清晰度问题。
- 选择短 TTL 加有限重试，不用持续轮询。原来保存的负缓存记录仍可读，新可选 `transient` 标记不丢弃正缓存索引；旧版本回读会退回旧 TTL。会话重进清理负记录保证恢复入口。
- 数据来源不可区分权限错误与确实无封面时按临时失败处理；真正无图也最多追加两次探测。root/Shizuku 的实际平台表现仍待真机。
- 同一路径内容改动且长度、mtime 都不变，仍需显式刷新；目录内部文件替换由显式刷新触发统一缓存重新验证。自动文件监控不在本轮范围。
- 新日志用于分段定位，尚无本轮设备 trace；缓存命中、队列上限与文件替换的自动化通过不等于真实设备耗时达标。
