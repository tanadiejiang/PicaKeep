# 022 原生图像后端验证

执行者：native_engine 子任务；2026-10-05，Asia/Singapore。

本文件只描述底层解码、编码及接口验证，不代表 Flutter 阅读器三布局、首帧、GPU 上传、封面产品入口或整个 022 计划已验收。完整执行状态由主任务回写。

## 实现与构建

- 普通项目内 Flutter 插件：`packages/picakeep_image_engine`，Android Kotlin 注册 + JNI/CMake，Windows 注册 + CMake，统一 C ABI 版本 1；插件依赖由 Flutter 生成，无手改 generated registrant。
- C++17 共用 core；libjpeg-turbo 3.1.3、libpng 1.6.59、zlib 1.3.1、libwebp 1.6.0、Little CMS 2.17。源码归档、SHA-256、上游链接和完整许可见插件 `DEPENDENCIES.md` / `LICENSE`。Windows NASM 2.16.03 启用 JPEG SIMD；Android arm64 启用 NEON。
- Windows VS 2026 / MSVC 19.50，独立 CMake Debug；Android NDK 28.2.13676358、API 24、arm64-v8a、CMake 3.22.1。原生 codec/core 在应用 debug/profile 内启用 `/O2` / `-O2`，没有构建应用 release。
- 源文件只读。区域坐标固定为 EXIF 方向规范化原像素；默认输出 RGBA8 straight alpha、sRGB。`premultiplyAlpha: true` 可在已有 worker 内原地转换，返回真实 `premultipliedAlpha` 标志，避免 UI isolate 逐像素处理；native elapsed 仍为 codec 耗时。Dart FFI worker-isolate → TransferableTypedData → Flutter 原始像素桥是有复制的路径，不声称零拷贝。
- 主设备：192.168.5.4:5555，Xiaomi 22127RK46C / socrates，MemTotal 约 11 GiB。运行前 MemAvailable 约 2.8–3.2 GiB，每次返回后约 3.0–3.3 GiB。只向 `/data/local/tmp/picakeep-native-022` 写本任务工具/合成图片/暂存，不安装应用或修改用户图库。

## Android 主格式矩阵

以下为 **每例 1 次冷准备、1 次同区域重复读取**，不是 30 次性能分位数；冷缓存仅指本次没有对应派生 backing，并未清 OS 页缓存。所取 512×512 ROI 位于图底部；没有用缩图替代原像素。完整原始输出见 `native-results.json`。

| 合成原文件 | 第一次 ms | 重复 ms | request 计费峰值 | 进程 RSS 峰值 | 磁盘峰值 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 8000×12000 baseline JPEG，快 crop/skip | 1256.681 | 610.728 | 1,267,200 B | 6,062,080 B | 0 B |
| 8000×12000 progressive JPEG，磁盘系数 | 5767.928 | 8.127 | 22,415,854 B | 27,054,080 B | 960,000,128 B |
| 8000×12000 PNG，非交错 | 1390.682 | 5.056 | 1,304,576 B | 6,324,224 B | 384,000,128 B |
| 8000×12000 PNG，Adam7 | 7128.467 | 5.180 | 1,304,576 B | 6,569,984 B | 384,000,128 B |
| 8000×12000 WebP，有损 | 7681.889 | 9.087 | 389,042,225 B | 10,960,896 B | 384,000,128 B |
| 8000×12000 WebP，无损 | 4574.704 | 5.177 | 771,743,038 B | 407,289,856 B | 384,000,128 B |
| 800×30000 PNG | 606.316 | 2.554 | 1,111,242 B | 5,959,680 B | 96,000,128 B |
| 800×30000 baseline JPEG，快 crop/skip | 117.701 | 167.375 | 1,095,168 B | 6,053,888 B | 0 B |

baseline JPEG 快路没有永久 backing，两次都会按需熵解码前缀，故第二次不能当作持久层暖命中。通过 `prepareBacking` 在闲时完成后，后续 random ROI 使用统一原像素磁盘层。IDCT 1/2、1/4、1/8 等比例且对齐区域也支持快路；非支持比例使用通用 backing。原始 1:1 与同 codec 全图零新增像素误差。

WebP 内部数组不是区域大小。计费包含完整 mapped 输入、mapped 输出的保守驻留费用及内部安全分配，96MP 无损实际要求约 736 MiB，测试 cap 896 MiB；有损 cap 512 MiB。RSS 比保守计费低不能据此声称常量内存。不足时 resourceLimited，禁止无界整图 fallback。原生还基于系统可用 RAM 预留 256 MiB + 可用量 25% 后准入。

progressive JPEG 的 IJG memory-system adapter 支持系数文件，内存约 22 MiB 而非把全图系数放入 RAM；本素材 4:4:4 系数暂存约 576 MB，输出 raw 384 MB，总峰值 960 MB。`diskBytes` 是本次费用峰值，最终 backing 只有 128-byte header + 4×原像素数，系数临时文件已清理。文件系统可用空间及调用者 diskBudget 都参与准入。

首次整图准备的等待仍明显，尤其 progressive、Adam7 和 WebP；这是必须由下载/扫描后预处理、闲时准备与来源已有派生层解决的真实成本。底层接口验证不将这些结果冒称产品首次秒开。

### Whole-page fit experiment

After the original-pixel checks, the PNG path gained a bounded streaming fit
route for non-interlaced, <=8-bit, orientation-1 files without ICC. It reads
each decoded source row once, uses libwebp's pinned fixed-point area rescaler
(premultiplied-alpha accumulation, then unpremultiply), and emits only the
requested output. It never writes the full raw backing on a cold fit. PNG with
ICC, Adam7, 16-bit precision, orientation, or a persisted full backing keeps
the exact backing route. The native 1:1 path remains a direct byte copy.

This is a quality-preserving bounded route, not a claim that native PNG beats
the platform decoder for every image. Independent native timings for the
synthetic 8000x12000 PNG at 750x1125 on the Android device were:

| Route | P50 | Peak | Disk | Backend |
| --- | ---: | ---: | ---: | --- |
| cold stream fit, N=30 | 1,446.521 / 1,656.254 ms P50/P95 | 3.38 MiB | 0 | `libpng/budgeted-stream-area-fit` |
| cold raw preparation + area 1x1 handoff before guard, N=30 | 1,724.033 / 1,909.606 ms P50/P95 | 1.17 MiB | 384,000,128 B | `libpng/backing-area-fit` |
| warm fit from backing, N=30 | 726.262 / 880.574 ms P50/P95 | 3.27 MiB | 384,000,128 B | `libpng/backing-area-fit` |

The streaming route reduces disk work and avoids a 384 MiB raw layer, but the
96 MP PNG still pays the source inflate cost; it does not meet a 170 ms target.
On Windows with a 3000x4000 PNG, 750x1000 cold stream fit was 165.9 ms (N=5),
and 1500x2000 was 198.0 ms (N=5). The actual Android reader profile remains
the authority for Flutter copy/upload and first presentation; native elapsed
does not include those stages. Parent-side routing may retain Flutter's
bounded adaptive path for ordinary <=64 MiB images and use this route only when
it is an admitted large-image candidate.

The N=30 preparation run exposed an unnecessary area read of the newly written
raw file for `prepareBacking`'s 1x1 handoff. A final guard keeps that handoff on
the constant-output generic sampler. The subsequent N=1 smoke was 1,214.748 ms
with the expected disk-interlace backend; it is not a new 30-sample percentile.
Fit output is area filtered rather than a bitwise reproduction of Flutter's
display filtering. A Windows 3000x4000 -> 750x1000 comparison to Pillow Lanczos
had max channel difference 32 and mean 1.74, documenting algorithm differences;
the original 1:1 quality checks still remain exact.

## 同 codec、同原文件 30 次比较

另对普通 3000×4000 JPEG / PNG，每路线 1 次预热 + **30 次样本**。全解码基线读取原文件并返回完整 RGBA8；冷 ROI 读取同一原文件的底部 512×512 原像素；暖 ROI 读取该原文件已完成的原像素 backing。每次都对照对应同 codec 全解码区域，所有检查逐字节零差。统计只含 native operation elapsed，不含 Dart isolate 调度、transfer/copy、Flutter decode/upload 或首帧。

| 平台 / 源文件 | 完整原图 P50 / P95 ms | 冷 ROI P50 / P95 ms | 暖 backing ROI P50 / P95 ms | 计费完整 / 冷 ROI / 暖 ROI 峰值 |
| --- | --- | --- | --- | --- |
| Windows JPEG | 73.754 / 95.356 | 22.225 / 25.106 | 10.820 / 12.092 | 48,108,648 / 1,147,416 / 1,144,592 B |
| Windows PNG | 191.709 / 233.836 | 81.591 / 93.983 | 12.919 / 17.746 | 48,096,016 / 1,146,442 / 1,144,592 B |
| Android JPEG | 149.535 / 154.442 | 41.416 / 41.863 | 5.047 / 6.347 | 48,108,640 / 1,147,408 / 1,144,576 B |
| Android PNG | 208.756 / 254.644 | 105.755 / 135.190 | 4.019 / 5.888 | 48,096,000 / 1,146,442 / 1,144,576 B |

每轮释放完整输出后仅保留 1 MiB golden ROI，并串行清理本工具创建的 full/cold backing；暖 backing 只保留 1 个，结束清理。没有同时堆积多份大 raw 文件。冷仅指派生层不存在，未清 OS 页缓存；顺序是 full → cold ROI → warm ROI，不能据此推断真实磁盘冷启动。P50 为排序第 16/30 个，P95 为第 29/30 个。30 次比较没有逐路线采集 RSS、UI copy/upload 或 T_visible，相关字段明确未测。原始输出及条件见 `native-decode-benchmark.json`。

以上 30 次性能数据在最终 metadata 预算复用修复之前采集，保留当时源码 / 二进制 hash；该修复只去掉重复 probe 并提高暖估计余量，没有更换 codec 或像素算法。修复后另跑 Windows 完整逐像素/取消/预算套件、Dart alpha 桥 smoke，以及 Android 同进程损坏数据回归；没有用修复后的二进制 hash 冒充之前的性能数据。

## 原像素和生命周期

- Android pull 回的 PNG 与无损 WebP 512×512 ROI 对规范化原 PNG 逐像素相同。Android JPEG ROI 与 Windows 同 codec 输出逐像素相同。所有主矩阵区域 hash 记录在 JSON，未用 SSIM 容差替代原像素核验。
- Windows JSON 有 22 条成功解码输出与 3 条跨 codec 对照；另核验 1/8 IDCT 整图与拼块一致。检查包含 EXIF 1–8、sRGB ICC、alpha 与透明像素 RGB、相邻瓦片拼接、四 worker 冷读相同 backing、源变化后失效、JPEG 4:2:0 非 iMCU 边界 crop。PNG / lossless WebP 的参考像素零差。
- Windows 40 次损坏 JPEG/PNG 解码、运行中 progressive 取消、预取消、低预算拒绝均返回明确终态，没有输出残留、`.partial` / 系数文件残留。最新 Android 交叉构建在同进程另连续 40 次损坏 JPEG/PNG 实测通过，预算 code 3、预取消 code 2、null 输出及安全 release；最终修复后 RSS 峰值 6,725,632 B，无残留。Dart FFI smoke 检查 isolate 传输、decode、encode、token 提前 dispose 自动延迟 free、buffer dispose、JPEG 透明输入拒绝，以及 alpha 0/1/128/255 的原隐藏 RGB 默认保留、worker premultiply 逐字节及标志一致。
- 深度自审把 JPEG/PNG 错误 callback 的 longjmp 改为 core 内 C++ 异常并统一 try/destroy；避免跳过 C++ 析构或依赖 O2 下非 volatile 局部状态。异常在 C ABI 内捕获转 status，不跨 Dart/JNI ABI。codec C 目标启用可展开异常标志，ICC vector 与 Little CMS context/transform 也通过请求预算分配。
- 最终预算自审移除了 decode 准入内部的第二次独立 metadata probe，复用当前请求已有 metadata，避免同时出现未合并的 32 MiB probe 费用。暖 backing 估计仍为 output + 8 行工作区，额外明确保留 32 MiB metadata 余量，覆盖大 ICC 头部读取，不能把暖命中说成完全没有 metadata 费用。
- 同 backing 路径有进程内 shared mutex，等待时每 5 ms 检查取消，只有一个冷生成 worker；完成原子发布，源 size/mtime/header fingerprint 发布前复核。刷新仍需改变版本身份；廉价头部指纹不是完整内容哈希。

## 色彩与格式边界

- 原文件永不重写。EXIF 恰好处理一次；ICC RGB / gray 由 Little CMS 转到明确的 sRGB8 显示目标，所有内部分配计入预算。
- 16-bit PNG 非交错含 ICC，以及 Adam7 含 ICC，先按高位深值转换后量化到 sRGB8。Adam7 16-bit ICC 使用 8 B/pixel 磁盘 staging，不假装 RGBA8 可保留 HDR 全精度。小素材两条路径输出 hash 一致。
- 主路径没有验证 HDR/广色域显示等价。高精度 JPEG、CMYK ICC 等不在本后端支持集合，必须由上层保真兼容路径/能力终态处理，不能 silent 转低清。动画明确拒绝静态瓦片路由，留原动画路径。
- 本机 Pillow 10.4.0 用 IJG JPEG 9.0，4:4:4 JPEG 对照最大通道差 1；高频彩线 4:2:0 的 IJG9 与 libjpeg-turbo3.1.3 存在显著色度插值差（三个区域最大 122/131/130）。同 libjpeg-turbo 的整图与区域仍逐像素相同，不能将跨 codec 差异掩盖为区域无损误差，也不能用宽容差通吃全部图。原始结果见 `native-pixel-verification.json`。Flutter 实际 renderer 对照由产品 profile harness 验证，这份 native 报告不将其冒称已完成。
- 实际 Android Flutter 小样已由主任务测得：JPEG444/420、EXIF+sRGB、PNG8 alpha、PNG16sRGB及Adam7的原像素 rawRgba max0；grayICC8 max1、gray16 max2（alpha max1），属于转换量化/舍入差异而非区域降采样。native 固定输出 sRGB8，不能保留 Display P3/AdobeRGB 超出 sRGB 的颜色或 HDR。普通含 ICC 页应在共享预算内使用 Flutter 原图解码/裁区一致路径，最高放大阶段也应遵循；保留原文件不能代替显示质量核验。巨图宽色域/HDR尚未通过代表样本，不属于已完成验收集合。

Display P3 / AdobeRGB 小源由 `make_color_animation_fixtures.py` 使用本机 Little CMS 2.12 独立生成 ICC，不分发第三方 ICC 文件；参数依据 [ICC Display P3 registry](https://registry.color.org/rgb-registry/displayp3) 和 [AdobeRGB1998 encoding specification](https://www.adobe.com/digitalimag/pdfs/AdobeRGB1998.pdf)。这些 fixture 的版本 / SHA 已写源清单。2026-10-05 22:20 Android profile 的两项实际日志都显示 Flutter `colorSpace=sRGB`，`rawExtendedRgba128` 各 RGB 范围 0..1，native 原像素 ROI 的 `rawRgba` 对照零差；这是该设备本次 sRGB 显示输出的一致证据，不能宣称保留源 ICC 的扩展颜色。完整产品 JSON 由主任务回写，原日志为 E 任务产物中的 `reader-android-quality-animation-stalled.log`。质量 helper 额外读取 `rawExtendedRgba128` 的范围：普通 `rawRgba` 自身会把 extended gamut 压回8bit，不能仅凭此比较零差宣称广色域保真。另 16×16 GIF / animated WebP 各两帧合成源可核验动画 fallback，Pillow 已验证第二帧像素不同，Flutter helper 返回 frameCount / 两帧像素变化与 duration，不能把生成器检查冒称产品动画验收。动画 helper 每个异步 codec / frame / readback 阶段有 10 秒超时和阶段日志，超时保留 error，不能自动改为通过。

## Android 原文件导出与平台检查

现有图库插件的 `saveFile` 返回 void，不暴露刚保存的 MediaStore URI，且内部重命名，无法在不扫描图库的条件下完成实际目标文件 SHA 闭环。为此 Android `storage_access.saveOriginalToGallery` 只接收 localFile：读取图片签名选择 JPEG / PNG / WebP / GIF / BMP 的正确 MIME 与扩展名，创建 UUID 唯一文件名，以 64 KiB 流式复制并 SHA-256，重新读取本次创建的 URI 验证同长度和 SHA。Android 10+ 使用 `IS_PENDING=1`，验证后才发布；失败只删除本次 URI，清理无法确认则显式报错。每次源文件 ≤2 GiB，已有两 worker、有界队列限制并发。没有 Bitmap 解码、转码或全文件字节缓冲。

产品 `saveImage` Android 已接这条 bridge；iOS 保留当前文件保存插件，桌面保留用户选择路径的文件复制。桌面复制与本地收藏的原字节检查由主任务负责；iOS 实际图库导出未验证，不能借 Android 成功推断其保真。

独立 `runImagePipeline022OriginalExportChecks(fixturesPath)` 只导出本任务 `640x960.png`，记录保存前后源 SHA，以及 bridge 返回的唯一 URI / 目标 SHA / 字节数，成功保留测试图片供查看，不列出图库。辅助函数、bridge Dart 层和产品保存文件已通过 dart analyze；首次代码就绪时未宣称实际导出通过，后续 Redmi 实际 SHA 闭环结果列于下文。

`android-native-16kb-check.json` 对当时的 `reader-profile-final.apk`（SHA-256 `e686904cf82f0aa173569239bb18ff7c788ea4c9a2499a23097b6f156e409299`）记录 ZIP 与 ELF program headers。`zipalign -c -P 16 4` 返回 0，全部未压缩 so 的 ZIP 偏移均 16 KiB 对齐，所有 64-bit `PT_LOAD` 对齐值至少 16 KiB。虽然 APK 含部分其他 ABI 的依赖，Flutter runtime / app 只含 arm64-v8a。部分 `GNU_RELRO` 末端不满足 [Android 官方页面](https://developer.android.com/guide/practices/page-sizes) 的 `(VirtAddr+MemSiz)%0x4000==0` 检查；官方将其列为 16 KiB 运行崩溃来源，因此本 APK 的官方结构检查**尚未全部通过**。本二进制向上取整的保护末端都在下一 LOAD 之前，仅为附加观察，不能替代该官方检查或运行证明。修复应同时复核本插件和全部预编译依赖的 max-page-size / common-page-size 设置。实际手机为 API34、4 KiB 页；没有 16 KiB 真机/模拟器证据。新 APK 重建后应重新核验该 APK 的 SHA 与对齐。

只读复核工具为 `native/tests/check_android_alignment.py`，接收已有 APK、`--output <本任务 JSON 路径>` 与可选 `--zipalign <zipalign.exe>`，同时记录输入 APK / 每个 so SHA。工具不解包安装或启动应用，检查前后复核 APK 未变化。独立复跑输出 `E:/picakeep-native-022-artifacts/android-native-16kb-reproduction.json` 与上述 hash / 对齐结果一致。

随后仅对本插件 Android target 显式增加 max-page-size=16384 和 common-page-size=16384，两参数限定 Android CMake，未更改 codec 算法或 Windows flags。独立 NDK28.2 aarch64 Debug / -O2 重链接后的 `libpicakeep_image_engine.so`（SHA `3f72eefd9485e4d35b23bc0d101b199734d22e24b8a527a838ce2cf4532c5a0b`）LOAD 与 RELRO 末端检查均通过，证据为 `android-native-16kb-plugin.json`。这不是旧 APK 自动变更的证据；新 APK 由主任务重新打包后检查。当前 APK 中 libc++ / dartjni / sqlite / datastore 等预编译库仍有上述 RELRO 检查不通过项，本轮没有扩展为全部依赖的 16 KiB 平台修复。

权限能力只检查身份和连接：显式设备 `192.168.5.4:5555` 的 `su -c id` 返回 uid=0；Shizuku 包已安装，当时未观察到 server 进程，应用 binder / permission 状态由上述 export helper 只读查询。没有凭安装就认定 Shizuku 可用，也没有读取其用户文件。

后续用户另外提供 Redmi K30i 5G（USB `8021129d`，Wi-Fi `192.168.5.3:5555`）换机验证。两入口 ro.serialno / ro.boot.serialno / boot_id / fingerprint 同一，操作固定选择 USB。独立输入见 `device-input-redmi-k30i-5g.json`：Android10/API29、4 KiB 页、1080×2400 / density440、MemTotal5,557,608 KiB，素材传输前 MemAvailable2,526,940 KiB。旧安装 PicaKeep1.9.39/versionCode1 的 APK与签名只读记录；没有安装、启动、读取用户文件或发起 root/Shizuku prompt。仅将本任务 51 个合成图片/JSON（90,039,777 B）推至该新机的独立 task 目录，全部设备 SHA-256 与源相等。原机96MP / 长图及30样本性能数据不与此输入合并，新输入本身没有性能结论。

主任务随后在该 USB 设备上使用 profile APK 完成固定 ROI smoke（报告 `reader-redmi-roi-fixed-smoke.json`）。11 个静态图片案例全部完成；JPEG 444/420、EXIF、PNG8 alpha、PNG16 sRGB / Adam7、P3 / AdobeRGB 的 ROI 均为 `maxChannelDifference=0`，gray ICC8 为 max1 / mean0.119，gray ICC16 为 max2 / mean0.303。Flutter 本次两个 ICC 宽色域源回报 `colorSpace=sRGB`、`rawExtendedRgba128` RGB 范围 0..1，故这只证明该设备当前显示输出与 native sRGB8 ROI 一致，不能证明源广色域被保留。GIF 与 animated WebP 的 Flutter codec helper 都测得 2 帧、120/180 ms、帧间变化 768 通道，证明本机动画解码可用；native 静态路径有动画拒绝能力，但这个 helper 没有实际绘制三种阅读布局，不能代替完整产品动画播放验收。

同一 smoke 的原图导出实际闭环为 `status=measured`：本次生成的 MediaStore URI `content://media/external/images/media/2225`，源 / 目标均 10,237 B，SHA-256 `d9070a909d982cb52e1380b3af4a089a953b3edcae2de0a56f0c98acbd5f9034`，`atomicPending=true`。只读取 bridge 返回的这一 URI，没有扫描图库；root 与 Shizuku 均 false。

该 smoke 的 ROI 首次 single/sharpFirst `postFrame=368.237 ms`、总 presentation `370.036 ms`；native worker wall 30 个 tile 合计 200.421 ms，UI `ImmutableBuffer` 合计 21.924 ms，`uiImageCreation` 合计 155.687 ms。阶段和是并行/分项时间，不能相加当作首帧；它们显示当前主要优化机会在 Dart→engine image 创建和 tile 调度，而不是 native codec 本身。single/previewFirst 为 629.337 ms，continuous/sharpFirst 为 549.546 ms；double 布局约 3.15 s，因并行两页冷 native 任务，不应用单页数字冒充。该文件每组仅 1 个首样本，不是 N=30 热分布。

当前工程 `reader_raster_backend.dart` 的 `ImageDescriptor.raw` 路径和 Flutter `ui.decodeImageFromPixels` 都会建立 raw `ImmutableBuffer`，并由 `instantiateCodec/getNextFrame` 创建 `ui.Image`。Flutter engine 的 `decodeImageFromPixelsSync` 在 Impeller 下用 `SkData::MakeWithCopy` 后构造 `PixelDeferredImageGPUImpeller`，再投递 raster task 创建纹理；Skia 下直接不支持。因此它不是零拷贝，也不应假设同步返回时间等于 GPU 可见时间。建议优先级为：先复用持久 worker / 批量相邻 tile 并削减 Isolate 与 image 创建次数；再以 Android Impeller 的 sync raw A/B 实测首帧、raster、alpha 与逐像素结果；TextureRegistry 适合后端自主刷新的视频类纹理，本阅读器三种布局仍需要独立 tile 图层、裁剪和 sharp/preview 策略，不应盲目改成单 Texture。

新 profile APK `reader-profile-roi-fixed.apk` SHA-256 `7f771bb3bc3fc56ed773b6f2a15efe5d3b47cbc1737e7de2f5df25b9d0ef9182` 的对齐证据为 `android-native-16kb-roi-fixed.json`：插件三 ABI 的 LOAD 与 RELRO 均满足 16 KiB 检查；整包 `libc++_shared.so`、`libdartjni.so`、sqlite / datastore 等预编译依赖仍有 RELRO 末端不整除项，因此整包仍不能宣称16 KiB结构或运行兼容。设备本身为 4 KiB 页，未做 16 KiB 运行验证。

## P9 持久 worker 实验

主任务后续 `reader-redmi-fixed-30.json` 六个原像素 ROI 组 N=30，P95 443.659–536.215 ms，尚未达到100–200 ms目标，保留原真实失败结果。single/sharpFirst 的545个tile分项中，native codec P50/P95为2.273/7.608 ms，worker wall减codec P50/P95为5.443/12.831 ms，ui.Image创建P50/P95为4.999/12.537 ms。每tile新建Isolate和绑定初始化因此是有依据的优化机会，但不是已经证明全部额外worker耗时都能消除。

package Dart 层新增 `lib/src/worker_pool.dart`，probe / estimate / decode 共用最多2个长期worker；native buffer仍在执行worker内分配、premultiply、生成TTD后释放，不跨worker共享codec/指针。编码暂保留原路径。排队仅持有参数，最多128个请求，满队列返回resourceLimited；取消token从排队到执行完成都保持原retain/release语义，取消排队项直接移除，执行中继续native原取消检测。源文件lease、优先级、共享内存预算仍由原caller控制。空闲10秒或显式关闭仅对闲置worker发送正常退出消息，不kill执行中FFI。启动失败不会因一个worker把全部无关队列立即清空；连续初始化失败有有界终态，后续请求可重建。

`NativePixelBuffer` 新增 workerQueueMicroseconds / workerStartupMicroseconds / workerExecutionMicroseconds / workerTransportMicroseconds / workerId。queue包含等待初始化时段；startup只记录该worker首个任务，其余为0；execution包含codec、alpha转换和TTD构建；transport为派发至响应之间扣除execution。`PicakeepImageEngine.workerDiagnostics` 回报active/queued/created/binding初始化累计时段，首帧仍由产品FrameTiming度量，不能用这些分项代替GPU可见计时。

独立 Windows Dart FFI定向通过：既有 `native/tests/dart_smoke.dart` 的解码/编码、token提前dispose、透明JPEG拒绝、alpha0/1/128/255原隐藏RGB及premultiply通过；`native/tests/dart_worker_pool_test.dart` 验证两worker上限、128 queue峰值、140并发11个明确预算拒绝、原像素输出与pool暖复用逐字节一致、请求失败后继续成功、idle shutdown与新probe竞争仍成功、结束active/queued/alive均0。没有强制kill执行中FFI，也没有实际制造worker runtime fatal exit；这两类系统故障未测。当前测试取消样本被执行worker快速接走，验证的是执行取消，不冒充强排队取消。设备端优化后的同条件N30仍待主任务统一debug/profile构建复测，没有将Windows功能回归声称为Android速度达标。

## 封面编码候选

Windows 同一 3000×4000 原 PNG 的 Lanczos 封面像素，192/384/768 每候选 1 次预热 + 30 次编码，另 Pillow 30 次解码；JSON 为 `native-cover-encoder-benchmark.json`。Windows JPEG85 为 4:4:4；alpha 不能转 JPEG。

| 768 候选 | 编码 P50 / P95 ms | 字节 | 解码 P50 ms | 像素差异 |
| --- | --- | ---: | ---: | --- |
| PNG level 3 | 27.514 / 28.029 | 310,887 | 8.268 | 零差 |
| JPEG85 | 2.413 / 2.557 | 434,385 | 8.035 | PSNR 29.24，max60 |
| WebP85 | 83.606 / 85.690 | 183,492 | 13.632 | 高频色线 PSNR21.10，max181 |
| 无损 WebP | 210.267 / 219.392 | 125,354 | 7.276 | 零差 |

Android 另固定简单合成像素 30 次编码，768 JPEG85 P50/P95 3.688/3.733 ms，PNG17.306/18.502，WebP85 44.224/44.529，无损WebP253.551/266.619；此素材与 Windows Lanczos 素材不同，不作跨设备直接比较。

冷封面可用 JPEG 减少编码等待，透明图保留 PNG；无损 WebP 的磁盘收益适合后台准备，编码不应挡首显。WebP 有损在高频线条候选上损伤明显，不作为普遍默认。实际封面入口选择仍须上层同条件 T_visible / cache 命中/尺寸/观感共同验收。

## 素材、证据与空间处理

源素材均由本任务生成，没有取用户私图或上传。源文件名、字节、SHA-256 见 `native-results.json`，素材位于 `E:/picakeep-image-pipeline-022-fixtures`，大 raw backing 位于 `E:/picakeep-native-022-artifacts`。生成器支持 `--output-dir` / `PICAKEEP_IMAGE_ENGINE_FIXTURES`，不再默认写 D 项目目录。

独立构建位于 `C:/Users/tanad/.codex/tmp/picakeep-native-022-build`，最新 30 次 / 异常原始 log 位于 E 任务产物目录；早期产物完整可逆备份在 `C:/Users/tanad/.codex/tmp/picakeep-native-022-artifacts`。D 空间不足时，只有经核实无 reparse point 的本任务生成目录被可逆移动到 C/E；原应用文件、用户原图、未知缓存未删除。copy/delete 方案曾被自动审核拒绝，改用可逆 Move 后完成空间恢复。

JSON / Markdown 为小证据并留在项目中，大素材和可再生构建产物没有加入仓库。可复跑测试：插件 native/tests 下 `make_fixtures.py`、`verify_pixels.py`、`benchmark_encoders.py`、`dart_smoke.dart`、原生 `pki_validate`。

## 证据与下一步

| 证据 | 可支持的结论 | 后续路径 |
| --- | --- | --- |
| `native-decode-benchmark.json` 同原文件 30 次逐字节 ROI 对照 | 本 codec 区域路由没有新增原像素误差；性能只含原生操作 | 主任务测同质量 Flutter 首显、copy/upload 与布局 |
| `native-results.json` Android 96MP / 长图 N=1 | 实际格式工作区和磁盘开销已验证，无损 WebP 需要受控大工作区 | 用真实系统 RAM 与共享预算准入，闲时准备复杂格式 |
| `native-pixel-verification.json` 同 codec 与跨 codec 分离 | JPEG 高频色度跨 decoder 有差异，不能直接用宽容差接受 | `tools/image_pipeline_022_pixel_checks.dart` 对实际 Flutter decoder 逐通道核验 |
| 最新 Android 40 次 malformed 回归与 Dart alpha smoke | 异常释放、取消、预算拒绝、worker premultiply 基本生命周期通过 | 产品入口仍须核验 stale/cancel、原图租约和后台恢复 |

在项目根目录复跑 Windows 独立 native（输出明确选 E，应用构建仍由主任务协调）：

```powershell
$engineSource = 'D:/Flutter_Projucts/PicaComic/PicaKeep/packages/picakeep_image_engine/native'
$engineBuild = 'E:/picakeep-native-022-artifacts/reproduction-windows'
$engineCmake = 'D:/IDE Program/Microsoft Visual Studio/18/Community/Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'
& $engineCmake -S $engineSource -B $engineBuild -G 'Visual Studio 18 2026' -A x64 -DPKI_BUILD_TESTS=ON
& $engineCmake --build $engineBuild --config Debug --target pki_validate --parallel 4
$env:PICAKEEP_IMAGE_ENGINE_LIBRARY = "$engineBuild/Debug/picakeep_image_engine.dll"
$env:PICAKEEP_IMAGE_ENGINE_FIXTURES = 'E:/picakeep-image-pipeline-022-fixtures'
$env:PICAKEEP_IMAGE_ENGINE_ARTIFACTS = 'E:/picakeep-native-022-artifacts'
python packages/picakeep_image_engine/native/tests/verify_pixels.py
& "$engineBuild/Debug/pki_validate.exe" --decode-benchmark 'E:/picakeep-image-pipeline-022-fixtures/3000x4000.png' 'E:/picakeep-native-022-artifacts/picakeep-reproduction-png' 30
```

小源可用 `make_fixtures.py --output-dir E:/picakeep-image-pipeline-022-fixtures` 重建 JPEG444/420、透明 PNG、EXIF/ICC；16-bit / grayICC 的生成器为 native 工具：`pki_validate --png-fixture <输出 PNG 路径> 640 960 <8 或 16> <0 或 1> <icc 或 gray>`。Flutter 质量 helper 返回原始 JSON，不自动设容差或替产品验收作“合格”判断。

## 2026-10-06 持久 worker 生命周期补验

已补齐原接续点尚缺的强排队取消、启动异常和受控 worker 退出。范围为 Windows 独立 Dart + 真实 native FFI；设备 Flutter raster、应用源文件/工作预算租约以及执行中 FFI 系统崩溃不在本结果范围内。生产构造默认仍 `_imageWorkerMain`，没有环境变量或公共 API 的故障开关。测试在 E 盘生成生产 library/parts 的精确副本并追加私有测试声明，允许注入入口仅存在 private constructor。

| Evidence | 实际观察 | Finding | Path |
| --- | --- | --- | --- |
| E-pool-lifecycle-01：`native-worker-pool-lifecycle-regression.json`，SHA-256 `f3b078d4e73ba0024eb6fc0d3099e1ad1a65c00a95d6cc1c90277fbc9abdd5ed` | 初始化抛异常与初始化前直接退出，各12请求，只创建2worker，12请求均有界error；同一pool下一轮成功恢复原像素，最终alive/active/queue为0 | F-pool-startup：旧计数把未初始化兄弟当成可服务者，会反复替换；无error的早期退出也没计入启动失败。现按当前worker数+连续失败限制2次启动，并统一早期退出失败路径 | P-pool-startup：run → bounded spawn → error/exit → 完成排队caller → 新cohort重试；验证状态为passed |
| E-pool-lifecycle-01 的 `queuedCancellation` | 两worker受控停在FFI前，128队列确实占满；第129请求resourceLimited；120排队项取消，8未取消decode逐字节匹配原buffer；token dispose时120借用仍保留，caller返回后0 | F-pool-cancel：排队项没有执行native，队列取消及token延迟销毁符合现有语义；该项明确使用私有test pool的相同 `cancelQueued`，不是公共singleton或UI集成证明 | P-pool-cancel：retain → queue → cancelQueued → completion error → finally release；全部caller完成且工作池清零 |
| E-pool-lifecycle-01 的 `exitBeforeFFI` / `exitAfterCleanup` | FFI调用前、真实 `_decode` 的finally清理后各制造1次正常isolate退出但丢失响应；每次仅当前caller失败，后续decode恢复精确原像素，token借用最终0 | F-pool-exit：调用前/清理后的丢失响应可恢复；没有kill执行中FFI，因此不能据此宣称系统native crash不泄漏 | P-pool-exit：安全故障点 → onExit → 当前caller error → replacement → decode → idle shutdown |
| E-pool-lifecycle-02：production lib/driver与generated完整library analyzer；旧公共 `dart_worker_pool_test.dart` 实跑passed | 旧公共pool复用、无效probe后恢复、shutdown竞争及140并发11拒绝继续通过；新增全部五组结束active/queued/alive为0 | F-pool-idle：正常shutdown关闭第一个worker时原drain会给仍在closing的兄弟重新挂10秒timer；现仅全部非closing的闲置worker才挂timer，独立程序约3秒退出 | P-pool-idle：shutdown message → 正常native cleanup/port close → onExit → 不重挂closing timer |

该初轮 `worker_pool.dart` SHA-256 为 `4d4c59436cc963615cde103cceb2c3dc3cacabfeff9996fbc17e9748592f93dc`；主 library仍 `db2609d171c701d0910fadbbe3e8cef37526fcdc8a57086a08a6b0c69c93e00d`。两worker、128队列和每调用native buffer/tokenretain保持不变；codec、坐标、原像素、source/budget lease准入未变更。正在执行的主任务性能报告应注明快照究竟为前版还是此生命周期修正版，不能拿此功能测试替代N30呈现数据。

在项目根目录复现（现有 native debug DLL 和合成素材是前提，均只读取；新输出明确为 E）：

```powershell
$env:PICAKEEP_IMAGE_ENGINE_LIBRARY = 'C:/Users/tanad/.codex/tmp/picakeep-native-022-build/windows/Debug/picakeep_image_engine.dll'
dart --packages=.dart_tool/package_config.json packages/picakeep_image_engine/native/tests/dart_worker_pool_lifecycle_test.dart E:/picakeep-image-pipeline-022-fixtures/640x960.png E:/picakeep-native-022-artifacts/worker-pool-lifecycle/tiles.pixels E:/picakeep-native-022-artifacts/worker-pool-lifecycle
```

driver自身只复制本包的普通源码和解析现有package config，不跟随plugin链接；生成library先analyze再运行。证据JSON保留源码/native DLL/素材hash及未测范围，后续采用同一入口补应用级取消/租约和真机N30。

补加混合启动顺序回归：worker1先成功初始化且受控占用，worker2后初始化失败，只错误完成一个排队caller；worker1成功reply后恢复worker3容量，12成功/1失败，最终idle/jobs/queue0。成功reply现在清理连续startup失败计数，避免成功兄弟在失败前已初始化时永久停留单worker。最终pool SHA-256 `47df117fd66ba69b680b45adb9a6ac782bf0e3b4876e63dc54428215ed5b0aa4`，六项完整证据为 `native-worker-pool-lifecycle-final.json`，SHA-256 `5b7e8824304e9d2edf7c587b4ee060905d0fbe392a95e9907d23bae90eb2e6ab`。该轮使用下节新native DLL，所有exact pixel恢复断言继续通过，初轮证据保留。

## 2026-10-06 稳定原像素 backing 共享读取候选

主任务 `reader-pool-windows-full-30.json` 已证实单页sharp/preview ROI P95约173/178ms，continuous约271/293ms、double约540/541ms仍未达标。double/sharpFirst第7样本native约406.530/427.832ms，worker交接和image创建较小；其后多个native约5.5/11/16.7ms呈现原5ms轮询等待阶梯。仅凭该现象不能把整段400ms归为锁：第一项workingPeak1,226,410B而大多暖项1,048,576B，提示此时发生96MP层构建，应继续检查上层原始层是否被缓存回收或错过准备。

候选将同backing mutex改为shared_timed_mutex：完整文件长度与128B header（原文件size、mtime、前4KiB fingerprint、尺寸、方向、算法）匹配时共享读取；创建、错误header重建和替换仍独占。切换独占后重新核原快照，整个读取结束再核快照，仍检取消、区域边界、工作内存、系统可用内存及磁盘预算。等待采用可唤醒的1ms timed acquisition，没有移除取消检查或改变采样。原文件由上层source lease保护；这里并不声称能够对抗保留size/mtime/首4KiB的外部恶意改写，完整source身份仍由产品层负责。

| Evidence | 同条件实测 | Finding | Path |
| --- | --- | --- | --- |
| E-shared-01：`native-shared-backing-baseline-30.json`；E-shared-02：`native-shared-backing-candidate-30.json` | Windows独立native Debug，同96MP原PNG，同稳定raw，9个512×512原像素ROI/轮，1轮预热+N30。1caller wall P95 59.126→49.042ms；2caller63.276→29.814ms；2caller每ROI270样本P95 60.635→5.580ms | F-shared-performance：共享稳定层消除读者间串行和5ms等待，在该native实验有收益；它没有包含Flutter/UI/GPU呈现，不能代替产品目标 | P-shared-performance：stable header/size+源快照 → shared guard → 原像素ROI row读取 → exact SHA核验 |
| E-shared-02及`native-shared-backing-safety.json` | 各ROI SHA与旧DLL原始层逐字节一致，working peak两版本均1,048,592B；4caller冷构建发布和2caller60暖项exact；错误header4caller仅exclusive重建；内存/disk不足均3/null | F-shared-quality：原像素、预算和发布互斥没有回退；此次上层并发仍按原caller预算准入 | P-shared-quality：invalid/missing layer → exclusive guard → prepare→publish → per-call sample；valid layer允许共享 |
| E-shared-03：`native-shared-backing-safety.json` | 96MP真实冷构建`.partial`期间另caller取消，返回2/null，完成耗时9.337ms；writer原像素正常成功，最终partial/coeff0 | F-shared-cancel：等待独占writer可协作取消，未kill执行中FFI；1ms acquisition不等于系统完成延迟1ms承诺 | P-shared-cancel：实际writer持锁 → waiter timed acquire+check → token取消 → error cleanup；writer独立继续 |
| E-shared-04：`verify_pixels.py` 22成功记录实跑passed | 8EXIF方向、ICC sRGB、alpha、tile缝隙、冷4caller、取消/预算、source-version失效继续通过 | F-shared-regression：本轮native结果支持安全候选；Android与Flutter帧仍需主任务同viewport profile复测 | P-shared-regression：新Debug DLL → 现有原像素/异常回归 → 构建快照冻结 → 正式profile N30 |

native源 `image_core.cpp` 冻结SHA-256 `3f41c832b687f2b42c60b4c8d6450a22a24a0a18420e066cefea4a0de54dded1`。旧DLL为 `1c063646b4d3a9cf211368dddacd454536c230f9495e9a3e2616b9def9c47681`，新DLL为 `d07fc3648c8e8488c89b9c6a05e193136cc3c588137819f89a48892dd2285f2f`。两N30/安全报告完整数据和hash均保留；测试生成的3个384,000,128B raw已在核实任务目录、文件长度及非reparse后清理释放E盘，素材/JSON/旧DLL均保留，可按命令重建。

项目根目录复现新候选native实验：

```powershell
python packages/picakeep_image_engine/native/tests/benchmark_shared_backing.py --library C:/Users/tanad/.codex/tmp/picakeep-native-022-build/windows/Debug/picakeep_image_engine.dll --fixture E:/picakeep-image-pipeline-022-fixtures/8000x12000.png --artifact-dir E:/picakeep-native-022-artifacts/picakeep-shared-backing-512 --samples 30 --reference-report docs/verification/image-pipeline-022/native-shared-backing-baseline-30.json --output E:/picakeep-native-022-artifacts/picakeep-shared-backing-candidate/reproduction.json
python packages/picakeep_image_engine/native/tests/verify_shared_backing.py --library C:/Users/tanad/.codex/tmp/picakeep-native-022-build/windows/Debug/picakeep_image_engine.dll --fixture E:/picakeep-image-pipeline-022-fixtures/8000x12000.png --artifact-dir E:/picakeep-native-022-artifacts/picakeep-shared-backing-safety --output E:/picakeep-native-022-artifacts/picakeep-shared-backing-candidate/safety-reproduction.json
```

Redmi新pool原独占锁报告 `reader-pool-redmi-full-30.json` 的double长尾进一步核查：sharp/preview两模式均只有index0、5的native stage出现output字节外约177,866B的build-like working peak，约0.98–1.13s，其余index的peak均为output字节。因此数据支持“新访问原像素层首次构建”的候选原因，尚不能声称每轮重建/LRU。该harness独立入口不调用BackgroundImagePreparer.activate，未启用500MiB全局trim，不能把这次长尾归给正常缓存清理。大PNG适屏quick path只stream-fit不写backing，surface现idle准备限定jpeg或FlutterBackend，Native PNG不准备，故“fit已暖”的描述仅说明适屏/压缩源被访问，不能证明原像素层完整可用。sharp在切到新y行的index6/12/18/24有约125–229ms暖native长尾，preview同类index大多7–16ms，仍须区分raw IO、paging/写回与锁等待。

下一产品采样应同时保留首次构建原像素ROI与原路线N30，并明确记录backing存在/长度/ready状态；若额外测“完整原像素层准备后”的warm组，应另列组并注明准备成本。不能为了达到P95而静默预热、删掉index0/5或换lower-density。PNG闲时准备与共享读是可以分开A/B的机会，正式适屏速度和用户马上放大的初建结果仍要一起评估。

## 2026-10-06 PNG cold fit 热循环选优

已采用opaque-row-skip：仅PNG无alpha通道且无tRNS时省去源行对恒255 alpha的遍历，保持RGBA四通道area与原finish unpremultiply。生产与独立已测candidate源码完全相同，冻结SHA-256 `11a0063e451188e4d9852d403563b164b537b0ef104646d640a114007a6f5b07`。同4096²→384、3轮预热+轮换次序N30，Windows独立native baseline P50/P95 137.977/145.124ms，最终候选122.857/129.127ms，改善10.96%/11.02%；峰701114B、disk0保持原样。未包含Flutter/GPU，不代表Redmi冷封面改善或20%达标，阈值未改。

opaque-skip与RGB3更快但极端比例失去字节一致性，已否决：4000×6000→2×2原area把常量255 alpha舍入为254，原finish继续unpremultiply；跳finish或强填255会改变输出。真实失败数据与初轮N30保留。最终71正常像素组、7极端组、1:1隐藏alpha、低位深、ICC/interlace、预算与前/运行中取消后恢复全通过，既有verify_pixels.py22成功记录也全部通过。详 `png-hotloop-study.md`、`native-png-hotloop-{initial,final}-30.json`、`native-png-row-skip-quality.json`，小补丁为 `native-png-row-skip.patch`。旧3f41 native的设备报告仍保留旧来源，下一主任务profile快照才统一新hash。
