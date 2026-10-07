# 022 阅读显示阶段优化判断

依据 `reader-redmi-roi-fixed-smoke.json`（Redmi K30i 5G / USB8021129d / Android10 / profile）、本地 Flutter3.41.6 Dart UI 源码、engine revision `425cfb54d01a9472b3e81d9e76fd63a4a44cfbcb`。每布局/模式仅1个ROI首样本，不能用这里的首样本推断30次热分布。此文只读分析，没有修改显示后端。

## 实际机会

single / sharpFirst 为30个512×512原像素tile，合计 native codec66.250 ms、worker wall200.421 ms、ImmutableBuffer21.924 ms、ui.Image创建155.687 ms；引擎 raster 完成的首样本370.036 ms。buffer+创建占这些分项和的46.98%，但分项可能并行，不能当成首帧关键路径的46.98%。worker wall与codec差距还包含Isolate启动、premultiply、native→TransferableTypedData及调度。API正常复制不能假设已测到GPU上传本身。

double 的两种模式各有4项 native elapsed >1 s，single / continuous没有。native elapsed包含等待同backing锁的时间，所以不是4次整图解码的证明。首先检查双页source identity与backing是否分别准备，以及首次fit留下的派生状态，不能把这段成本归给UI image。

## 方案优先级

1. 原像素需求保持不变，先看主任务30次热区结果。若重复ROI已满足目标，保留当前可靠管线；首进大视窗仍可优化worker、tile数量和显示构建。
2. 复用固定少量native worker、合并邻近tile交接，让同一视窗减少Isolate和engine image创建次数。批量输出继续有工作区/输出上限，取消和source lease共用同一代；批量不等于全图解码。tile从512改1024能减少创建次数，但扩大读输出和过取区域，必须同viewport/原像素、内存与FrameTiming A/B；不能先认定更快。
3. 在Android Impeller候选中试 `ui.decodeImageFromPixelsSync`，保留当前 `ui.Image` / CanvasPainter / 布局接口。测试同原像素、alpha、取消后释放、memory pressure及真实raster presentation；Skia/Windows继续当前路径。每个tile同步return只能计为提交，不是GPU完成。
4. 只有前面证据仍表明实际显示瓶颈时，比较TextureRegistry版本。现阅读器依赖多tile、sourceRect裁剪、density层次、sharpFirst过滤和双页布局；Texture widget接收一个平台纹理ID，它本身不能代替Canvas里的ui.Image。可做每tile纹理widget，但需大量registry/lifecycle资源；或native合成一个viewport纹理/atlas，再同步gesture、代次、裁剪、色彩和纹理上限。单换Texture不保证零拷贝，不应盲目上复杂native compositor。

## SDK与engine的具体边界

本地 `sky_engine/lib/ui/painting.dart` 的异步 `decodeImageFromPixels` 内部仍为 `ImmutableBuffer.fromUint8List → ImageDescriptor.raw → instantiateCodec → getNextFrame`。当前后端已走这个路径，改函数名字没有省掉阶段。

[精确engine image.cc](https://raw.githubusercontent.com/flutter/flutter/425cfb54d01a9472b3e81d9e76fd63a4a44cfbcb/engine/src/flutter/lib/ui/painting/image.cc) 的sync接口在Skia抛异常；Impeller仍复制像素到SkData，再创建延迟图像。无rowBytes参数，RGBA8输入须紧密stride并使用premultiplied alpha；没有自由ICC色彩空间参数，不能因此补齐宽色域/HDR。

[PixelDeferredImageGPUImpeller](https://raw.githubusercontent.com/flutter/flutter/425cfb54d01a9472b3e81d9e76fd63a4a44cfbcb/engine/src/flutter/lib/ui/painting/pixel_deferred_image_gpu_impeller.cc) 将MakeTextureImage投递到raster线程。因此sync接口可能减少codec/异步调度等待，也可能把费用移到raster帧；两者要用同FrameTiming验证。API返回可Canvas绘制的Image，符合现Painter，而[Texture](https://api.flutter.dev/flutter/widgets/Texture-class.html) 需要平台registry管理的独立纹理ID。

native固有复制仍有：codec返回的native buffer → TTD构建复制 → engine ImmutableBuffer或sync SkData复制 → GPU纹理。TTD跨Isolate转移本身不复制，并不消除其fromList构建复制。消除native→TTD层需要新的指针所有权/engine导入路径，修改ABI与取消释放风险大，未实际验证前不能写成零拷贝收益。

## 已选择的受控实验

后续 `reader-redmi-fixed-30.json` 实际六组ROI P95为443.659–536.215 ms，100–200 ms目标尚未达到，旧结果保留。package已实施第2项中的固定两worker复用（probe/estimate/decode），加128参数队列上限、idle正常退出和队列/初始化/执行/交接诊断；未改codec、tile采样、Texture或原像素能力。Windows Dart功能回归与analyzer已通过，Android/Windows产品首帧复测由主任务统一构建，不能在取得数据前宣称优化已达目标。
