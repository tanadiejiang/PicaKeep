# 原生只读磁盘容量接口 · 2026-10-06

已新增 `PicakeepImageEngine.availableDiskSpace(String absolutePath)`，返回具名 record `({int availableBytes, String volumeId})`；`availableDiskBytes(path)`是便捷包装。OS查询在独立 `Isolate.run`执行，不占UI或两codec worker执行槽。它不创建/删除/移动目录、文件、缓存，不修改用户下载或原图。

native additive ABI-1新增 `pki_query_disk_space(path,&available,volume,volumeSize,error,errorSize)` 与 `pki_available_disk_bytes`。现metadata/request/result布局及 `pki_abi_version()==1`不变，Dart binding按optional symbol加载；旧DLL仍probe/decode可用，但磁盘查询明确抛4。缺失native库在supported平台也明确4。未知不能当0或unlimited。

| status | 意义 | 输出/调用方规则 |
| --- | --- | --- |
| 0 | 查询成功 | available可合法为0；volumeId非空，quota仍需要headroom与全局pending准入 |
| 1 | 参数/OS/ancestor/容量范围错误 | available=0、volumeId空，Dart抛ImageEngineException1，停止准入 |
| 4 | 平台/volume身份不支持或旧native无symbol | 不创建独立无限容量池，Dart抛ImageEngineException4 |

输入要求绝对path；空/NUL/相对路径拒绝。目标不存在时逐层找最近既存目录；只有输入本身是existing regular file才查询其resolved parent。路径中间已有普通文件则显式失败，不能误把不可能创建的child当有效目标。拒绝权限错误，不把denied误当missing。失败信息包含系统错误码，不返回整段真实目录。FFI path/out/error缓冲在finally释放；结果只有ints/string可跨isolate。容量是瞬时值，不等同于实际OS磁盘预分配，外部writer仍可能使后续写入失败。

## 已测功能与冻结

Windows Debug完整native构建通过；native6路径与直接OS query对照全部一致，包含C/D/E卷、中文不存在多层目标、中文existingFile和既有C→E构建junction。junction虽然字符串始于C，其volumeGUID和容量均与E相同。六类非法/null/out-too-small/non-directoryancestor均显式失败且输出清零。Dart现目录、文件、missing中文target、relative/empty/NUL、convenience、无创建通过；旧DLL无query仍probe640成功且query4，missingDLL query4。测试分别为 `native-disk-space-{windows-os,dart-windows,old-dll,missing-dll}.json`。

| 当前冻结文件 | SHA-256 |
| --- | --- |
| `native/src/image_core.cpp`（像素核心未变） | `11a0063e451188e4d9852d403563b164b537b0ef104646d640a114007a6f5b07` |
| `native/src/disk_space.cpp` | `d32b5eb924d799f6470839ec7a82fc4ffb7c1297903518a548eed9a217c0cfc1` |
| `native/include/picakeep_image_engine.h` | `5e2133cb0d882f72662fc8b2cc3e930781c44173422e514412c394306fb1efd6` |
| `native/CMakeLists.txt` | `54c363a5824d7326377e06b47babc87e1c1f47804c2b8ddf8996302beab76cd6` |
| `lib/picakeep_image_engine.dart` | `d014e1443e58d02e744823c667cd37ef8fb37d0bf4347aaf2f7466cf4eb26c32` |
| `lib/src/bindings.dart` | `dec5540f3bd41173eda90713f71031f8f4972d9d608b4eed931846de46f7c26b` |
| Windows完整Debug DLL | `2b4b6caf2cbfe51701e1623700fc81a2de7b514e64c5486f86eb18964c392f11` |
| Android arm64完整Debug SO | `a97838ec6c0d6b4411ab5a7f594ca06143941a7746e31d0c91bf57099caa9ecf` |
| Android arm64独立只读CLI | `a631734a03fd071628f9b6fb674a31ae30edf1b872527ba27af799715462fe48` |

Analyzer对plugin lib/bindings/独立Dart测试无问题；Android arm64整native与独立CLI编译通过。CLI只输出status/bytes/id/error，参数一个绝对路径；由root显式设备推送并执行，当前owner未操作手机。root已实跑 `/data/local/tmp`、emulated、system等，真实包装app UID的cache查询待后续profile验证，不能把shell UID结果当app路径权限证明。

## Android FUSE 容量域必须保守合账

Windows使用 `GetDiskFreeSpaceExW` 的 caller-available容量与 `GetVolumePathNameW` / `GetVolumeNameForVolumeMountPointW` GUID。Windows官方说明query在symlink目标执行，caller配额会使available少于总free，junction也可以跨卷，所以不能按盘符/路径前缀合账。[Microsoft容量API](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getdiskfreespaceexw)、[卷定位](https://devblogs.microsoft.com/oldnewthing/20201020-00/?p=104385)。

Android/POSIX使用 `statvfs.f_bavail * f_frsize`（若frsize0则bsize）和 `stat.st_dev`。这标识OS逻辑filesystem，不能证明物理磁盘独立。root真实设备结果：`/data/local/tmp` status0/id66322、`/storage/emulated/0` status0/id33，`df`却显示同112240620K userdata容量，available约93.99GB；`/system` available0仍status0正确。仅按两个st_dev分别管理pending会过量预留，已要求source_workflow在Android额外扣全部容量域的总pending；每个target仍用其实际即时availableBytes，不让未知alias新开独立可用余额。多盘时该fallback可能保守超扣，优先保证有界准入。

不能硬把 `/storage/emulated`映射到`/data`：官方说明 emulated 可以由内部userdata或adopted盘提供。`Environment.isExternalStorageEmulated(File)`只证明emulated属性，不能单独证明具体内部卷；API26起可用 `StorageManager.getUuidForPath(File)`做具体volume UUID识别，unknown/IOException或低API仍保守共享pending。[Android Environment](https://developer.android.com/reference/android/os/Environment#isExternalStorageEmulated(java.io.File))、[StorageManager](https://developer.android.com/reference/android/os/storage/StorageManager#getUuidForPath(java.io.File))。

后续准确mapping可在已授权Java/MethodChannel桥查询existing ancestor的官方storage UUID、emulated属性和app internal/externalCache目标，再把已核实同UUID的逻辑filesystem归一个capacity domain；不得以`/proc/mountinfo`里仅见`/dev/fuse`或相近free bytes替代证明。当前native诚实保留逻辑ID，quota采用保守跨domain扣账，native像素/core冻结不变。

existingBacking认证没有加入本模块。image_core持锁核RawHeader/source stamp/readiness已有私有逻辑，简单复制128B私有layout会产生版本漂移且缺少相同互斥。quota当前应不抵扣未知existing raw，或后续由root安排正式locked readiness API，不能仅凭exists/size认定可复用。
