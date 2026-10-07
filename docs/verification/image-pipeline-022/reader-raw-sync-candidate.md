# Reader raw RGBA 同步候选封装 · 2026-10-06

已实现独立 `ReaderRawImageDecoder`，默认 `preferSync=false`，尚未据此替换生产默认路线。本次不修改 reader backend、native ABI 或原像素核心；由 backend 所有者冻结 quota 接入后再最小接线，root 单独控制 profile `raw-sync` A/B。

## 接口与约束

```dart
final result = await ReaderRawImageDecoder.shared.decode(
  pixels.bytes,
  width: pixels.width,
  height: pixels.height,
  rowBytes: pixels.stride,
  isCancelled: isCancelled,
  preferSync: false,
);
// image ownership transfers to caller after successful completion.
```

输入为已经 premultiplied、sRGB、RGBA8 的原区域像素；helper 不裁剪、不缩放、不再次 premultiply、不修改输入。宽高必须正数、rowBytes 不小于 width×4、字节覆盖每一完整行。只有显式 opt-in、实际 Android、紧密 rowBytes=width×4、输出≤4×1024×1024 pixels、每边≤16384 时尝试 `ui.decodeImageFromPixelsSync`。其他输入仍走同一 `ImmutableBuffer → ImageDescriptor.raw → instantiateCodec → getNextFrame` 异步路线，保留 padded-row 的语义。

本 SDK Skia 抛出的精确 String `decodeImageFromPixelsSync is not implemented on Skia.` 和 `UnsupportedError` 标记实例不支持，当前请求回退异步，后续请求不再尝试。真实分配/像素/GPU 等其他异常直接抛出，不借回退掩盖失败。缓存只在该 main-isolate 实例生命周期内有效；没有写磁盘或新增用户设置。

返回 `image`、`immutableBufferMicroseconds`、`imageCreationMicroseconds`、`syncAttempted`、`usedSync`、`syncUnsupported`、`uploadDeferred`。sync 的 `immutableBufferMicroseconds=0` 只表示没有单独调用 ImmutableBuffer，其 SkData 复制包含在 `imageCreationMicroseconds` 中，不能解释为没有复制。sync 的 `uploadDeferred=true` 明确对象已返回而 raster 上传可能仍未完成，不能以此对象时间充当清晰画面已经显示。

调用方须保持 pixels/bytes、取消 token、源文件 lease、scheduler 工作预算直到 helper await 完成。helper 仅拥有自己建立的 buffer/descriptor/codec，均在 finally 中释放。取消后刚创建的 image 由 helper dispose，不发布；成功 image 由调用方拥有，继续遵循现 surface 的 frame retirement 与预算生命周期。GPU deferred work 的内存与真实帧应由 profile/OS RSS 单独观察，不提前宣称已释放。当前 backend 提前 dispose pixels 或 token 的位置须在实际接线时由所有者整理；本文件没有越过 backend 所有权修改它。

## 已完成的验证

命令：`flutter test --no-pub test/reader_raw_image_decoder_test.dart`；结果 11 tests 全通过。`dart analyze lib/foundation/image_pipeline/reader_raw_image_decoder.dart test/reader_raw_image_decoder_test.dart` 结果 `No issues found!`。

| 证据 | 结果与边界 |
| --- | --- |
| 7×5 原尺寸、交替高频颜色、alpha 0/1/128/254/255 | async rawRgba 与输入每字节相同，1:1 Canvas 绘制后也相同；source view 未改变 |
| 字节 view 有非零 offset，返回后输入全改零 | 已返回 image 仍保留原内容，证明 engine 拷贝拥有存储 |
| 3×2 非紧密 RGBA，4 字节行 padding | 不尝试 sync；1:1 Canvas 绘制输出每字节相同 |
| 非 Android 显式 opt-in | 不触发 sync，仍异步输出原像素 |
| 真实 Windows Flutter tester Skia API | 首次真实 String 异常正确回退，二次不再触发 API，两次 async 图像逐字节相同 |
| injected UnsupportedError | 仅一次尝试并缓存异步恢复 |
| injected 资源异常后再请求 | 资源异常向上传播；不错误禁用候选，后一次允许重试 |
| 创建前取消、同步创建期间取消、异步返回 image 后取消 | 不发布；两个创建后取消分支的 ui.Image.debugDisposed=true |
| 返回错误尺寸或输入截断/错误 stride/零宽 | 明确失败；错误尺寸 image 被 dispose，后续有效请求正常 |

最初 padded-row 测试直接按 tight RGBA 解释 rawRgba readback 而失败；本 SDK readback 会保留底层行 padding。保留这项发现，改为真实 1:1 Canvas 画入紧密输出再验证，未改生产像素。native 输出原本是 packed RGBA。不要把 padded readback 中的 padding 当原图像素损坏。

同步成功逻辑、资源失败和取消以 dependency injection 在单元测试中验证；这里的成功替身是已创建的真实 ui.Image，**不是 Android Impeller 同步像素/上传质量证据**。实际 Android sync 的 ICC 归一像素、EXIF、alpha、边缘、1:1 高频画面、deferred 首帧、取消/drain、OS RSS 与 N30 尚需 root 真机验证。理论路线依据与 engine revision 在 `flutter-raw-upload-study.md` 和 `flutter-raw-upload-sdk-evidence.json`。

## 冻结来源

- `reader_raw_image_decoder.dart` SHA256 `181d8e7543987aea9c64ef2c08dd31a5a6f43e91b1e30b9f73e4a01526f55cd9`。
- `reader_raw_image_decoder_test.dart` SHA256 `c1d534d26a2a2dc63d70f98223f5b781da27f5a961aeda00e50b1fcbfb73a3f3`。
- `image_core.cpp` 再次核验仍为 `11a0063e451188e4d9852d403563b164b537b0ef104646d640a114007a6f5b07`，本次没有改动。

本次未运行 Flutter application build/run，未操作 Android 设备，未创建大图/大磁盘产物。
