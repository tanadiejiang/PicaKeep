# Prepared-read 候选与下一轮性能诊断

## 结论

当前不应因为独立 native prepared-read 验证通过就切换默认阅读路线。该候选只证明：已有完整原像素 backing 时，可以在共享读锁下校验源快照并读取原像素，且不启动新的 backing 写入。它尚未有启用 `prepared-read=true` 的 Android 或 Windows 阅读器 N30，因此没有设备端速度收益证据。

下一轮最有价值的实验是同一 APK、同一源文件、同一 layout/mode/缓存定义下做 `prepared-read=false` 与 `true` 的配对 N30，且把“backing 已在计时外准备好”和“首个 backing 还不存在”分成两组。首组才能测只读入口本身；后者必须验证 status 5 回退到完整准入路径，不能把 miss 样本从分布里删掉。

## 已有性能边界

计划 022 的目标是 `T_nativeROI` 热层 P95 100--200 ms，同时不降低原文件像素质量；普通清晰首显和原像素区域必须分别报告。

| 场景 | 代表结果 | 结论 |
| --- | --- | --- |
| Redmi 3000x4000 普通 PNG adaptive cold | baseline 99.657 ms，surface 166.556 ms P95 | 首显比同源直接 Flutter 基线慢约 67 ms；不能靠把预览当清晰结果掩盖 |
| Redmi 3000x4000 普通 PNG full cold | baseline 102.282 ms，surface 121.373 ms | 比 adaptive 稳定，但仍慢约 19 ms；Windows full 70.479 对 54.550 ms，也有回退 |
| Redmi 512 tile 原像素 ROI，raw-sync=false | single sharp 612.630 ms，continuous 655.251 ms，double 608.516 ms | 远高于 100--200 ms；仍有 jobsFailed 混合计数，不能只看 UI errors=0 |
| Redmi 512 tile 原像素 ROI，raw-sync=true | single sharp 511.986 ms，continuous 579.238 ms，double 578.575 ms | 同步候选部分改善，但仍不达标，且两轮顺序/OS 旁路条件不完全相同，默认仍关闭 |
| Redmi viewport-region 视口候选 | single sharp 513.022 ms，continuous 519.652 ms，double 561.246 ms | 减少了部分多余区域，却没有达到目标；不能默认替换 512 grid |
| Redmi 1024 tile 候选 | single sharp 450.71 ms，continuous 615.06 ms，double 386.43 ms | 布局差异很大，单页/连续变慢；不能全局默认 1024 |
| Redmi 4000x6000 PNG bounded fit | baseline 161.708 ms，surface sharp cold 278.835 ms | 比此前多 ROI 的 1008 ms 有诊断改善，但仍比同轮基线慢约 72% |
| Redmi 4000x6000 JPEG native-large-fit | 同轮 baseline 530.827 ms，single sharp cold 333.268 ms | 同轮约改善 37.2%，但源码仍是 default-off 候选，且后续所有权/配额修复后需要重测 |
| Windows viewport-region | 各布局原像素 P95 约 51.7--113.8 ms | native/UI 设备能力足以达热 ROI 目标；不能外推 Redmi |

历史 `native_roi_prepared` 组是“计时外先准备 backing”的旧 profile 路径，不等同于当前新增的只读 ABI。它只能说明准备状态会显著影响结果，不能作为新 `pki_decode_prepared_region` 的性能证明。

## 瓶颈判断

普通 3000x4000 PNG 的 Redmi cold 回退不是 native codec 本身已被证明过慢。现有阶段数据中，page resolve、metadata 和 Flutter codec 各自都只有可测部分；剩余时间包含 scheduler admission、源快照、Surface 首次 build、image 创建和真正 raster。Windows adaptive 甚至接近基线，说明设备/引擎路径差异很大。最小、可验证的普通图候选仍是已实现的 `earlyOriginalRaster`：Page 完成 resolved source/metadata 后，在同一 scheduler 和预算下提前提交一次原图 first-raster，让正常 Surface 接管；它必须用同源 baseline N30 证明首显没有回退，不能改成另一个无预算的 Image provider。

1:1 ROI 的 native codec 阶段通常只有数毫秒到低十毫秒，较长的 worker wall 还包含 probe、header/source 校验、workspace/磁盘准入、finish/abort 和调度。prepared-only 能跳过 backing 写入准入，但不能消除 Flutter `ui.Image` 创建、GPU 上传、多个 tile 的 CustomPaint 更新、跨 frame 的 Surface pending-resident 计账，因而不应预期单独把 500--700 ms 降到 100--200 ms。

## 推荐的下一轮 A/B

1. **Prepared-only paired N30。** 先用同一 source identity 在计时外完成完整 raw backing；跑 false/true 各 single、continuous、double × sharpFirst/previewFirst，保留 cold miss 组。JSON 必须报告 `preparedReadAttempted/Used/Miss`、native worker wall、native execution、image creation、matched rasterFinish、source/backing SHA、RSS 旁路和 jobsFailedCode 分类。
2. **Early-original paired N30。** 仅对符合静态 sRGB8、文件/decoded RGBA 均不超过 64 MiB 的普通 PNG，跑 adaptive、full、full+early 三个明确策略，同时保留同轮 baseline `Image.file`。重点看 Redmi 的 request→rasterFinish 和首个 image upload，不能只比较 Page resolve 子阶段；已有 early ticket 默认关闭，先验证它而不发明新的等价 provider。
3. **JPEG 完整适屏复测。** 在最终 ownership/quota 代码上重跑 `nativeLargeFit=true/false`，同源 4000x6000 JPEG、同 texture-capacity probe、同 75% 可见约束；质量仍用后续 1:1 原像素 ROI 检查，不能把完整适屏层当作原像素层。
4. **若 prepared-only 仍远高于目标，先消除重复估算队列。** Surface 每个 tile 都在提交 scheduler 之前 await `estimateWorkingBytes`；该 native 操作再次 probe 源并读 backing header。raw-sync/no-persist 的 360 样本累计约 29,000 个 worker jobs，而有完整 decode 阶段的输出仅约 6,100 个；jobs 总量不能全归 estimate，但足以值得按操作种类精确计数。用已绑定 source snapshot/lease 的 `ReaderResolvedOriginal.metadata` 计算只读 warm 公式 `32MiB + outputRGBA + normalizedSourceWidth*32`，可省一次 estimate 工作；native 每次读取仍校验 header/源。只有 prepared-only 路径可使用该 admission。status 5 必须回上层重新取 cold estimate、完整 disk quota 后重新提交，不能在小 warm 内存预算里隐式 cold fallback；source 变化/其他错误仍透传。
5. **再增加单次目标变换对照。** 当前 canonical ROI 每次计时内先升到原像素倍率、等完整画面，再平移到目标、等第二个完整画面，往往解码两个视口。保留原两步组和全部旧失败数据，另加一组合法 `scale+position` 一次目标变换的实际用户动作对照，保持同 source、target、density=1、两像素中心、预算和实际 raster/pixel 核验。该新组可以量化重复视口代价，不能冒充旧组已通过。

当前不值得优先做自定义 Texture：raw-sync/no-persist 每 tile UI image 创建 P95 已约 0.949 ms，而整体 ROI 仍数百毫秒。SDK API 对调不等于减少 texture upload，跨上下文/取消/GPU 生命周期成本也高。已经实测的 viewportRegion 在 Redmi 仍 464--813 ms，不能把同一个单视口方案重新包装为未测新路线；若未来结合新的只读/估算/目标变换策略重测，应显式说明组合候选。

不建议现在全局改成 1024、raw-sync、bounded PNG 或 prepared-only。每个候选都有至少一个布局或设备明显回退，且“完成/无 errors”不等于达到 100--200 ms；默认仍应保持清晰优先的原文件路径并保留预览优先切换。

## 质量与资源边界

所有候选必须继续使用原文件坐标，density=1 的原像素层不能由适屏缩略图放大得到。质量验收至少包括真实 Surface RGBA readback、方向/透明边缘/拼缝、源 SHA/size/mtime 未变、取消后无 partial/coeff 残留。`onPresented`、FrameTiming 或 layer complete 只能证明生命周期和帧执行，不能单独证明画面像素正确。

prepared-only 仍需保留 Surface 对 existing raw 的磁盘账和源/backing lease；它只是 native 调用内部不新增写入。Android `/data` 与 emulated storage 可能是同一物理卷，quota 不能只靠 `st_dev` 前缀合并。OS RSS 必须用 `/proc/<pid>/smaps_rollup` 或 Windows WorkingSet 旁路，Dart `ProcessInfo.currentRss` 的异常低值不能用作回收通过证据。

## 目前缺失

- 新 prepared-read flag 的 Android Reader N30 已完成同包 on/off 配对；Windows旧配对仍需区分其源码快照，不能与Android v6直接合并为跨平台结论。Android报告见当前交接快照；速度绝对门槛仍未达标。
- earlyOriginalRaster 最终包的首显 N30，尤其 Redmi 普通 PNG；
- 4000x6000 PNG/JPEG 候选在最终 ownership/quota/core 快照上的重跑；
- 1:1 ROI 目标在最终包上达到或未达到 100--200 ms 的明确分组结论；
- 超长图、动画、ICC/16-bit/HDR、真实下载/归档来源和正常 UI 工作流的完整主任务验收；
- 全流程 OS RSS 配对窗口，不能由内部 resident/lease 归零替代。

## 2026-10-06 当前交接状态

v6 profile APK 已在 Redmi `8021129d` 完成同包 prepared-read 配对：on/off 各360样本、0错误、0缺帧。prepared ROI on P95 `442.78–619.52 ms`，off `694.57–1132.28 ms`，相对下降约 `36.3%–49.0%`；普通 ROI 相对下降约 `24.1%–48.1%`。绝对 P95 仍不满足 `100–200 ms`，候选继续默认关闭。原始报告和 SHA 见 `CHECKPOINT.md` 当前交接快照。

恢复工作时不要复用旧 PID、旧 runId 或旧 APK 结论；使用 `reader-v6-prepared-on-redmi1006.json` / `reader-v6-prepared-off-redmi1006.json` 的明确 runId 和 SHA。若继续速度实验，应先分冷源、磁盘热、解码热，并增加同 PID 的 `/proc/<pid>/smaps_rollup` warm baseline；不要只重复同一顺序 N30。
