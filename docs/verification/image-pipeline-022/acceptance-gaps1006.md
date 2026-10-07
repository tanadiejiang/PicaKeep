# 022 验收缺口审计（2026-10-06）

> 2026-10-07 20:43阶段收束：本页保留10月6日出口审计及后续增量。最新普通图/封面/回看/大图首幅默认行为、正常C1BB包两机交付和剩余缺口，以 [本版本全部行动](version-1.9.92-actions1007.md) 为准。已测Reader色彩/动画和Android单页JPEG系统操作不再视为完全未做；冷codec精度、完整UI、OS基线及绝对速度仍未关闭。当前暂停执行，P0--P10未整体验收。

依据022原P0--P10出口、验收A--D，只读核对现有证据；完整事实/经验和原出口边界已蒸馏到 [版本总记录](version-1.9.92-actions1007.md)。本页10月6日审计未重跑测试/构建/设备操作，也未改生产代码。缺证据不等于产品故障；以下当时“待收尾”判断按页首及各增量理解，不提前判通过。

## 出口核对

| 出口 | 判断 | 当前证据与剩余边界 |
| --- | --- | --- |
| P0 基线 | 已建立 | 有设备/素材哈希/预算和分阶段计时；最终性能配置尚待选定。Windows 格式质量报告已归档，Android 新 prepared 性能仍待收尾。 |
| P1 原文件/操作 | 主要契约通过，实际 UI/权限未闭环 | 真实 JPEG/ZIP × 三布局两模式，12 工作流、36 次输出哈希一致；系统 dialog 为替身。 |
| P2 原生 | 静态主路径通过，特殊色彩未闭环 | 双端 native 和画布 ROI 有精确证据，不能外推 ICC/HDR/16-bit 显示。 |
| P3 调度 | 内部链路通过，OS 压力未闭环 | 预算/依赖/取消/连接恢复和 60 次退出内部计数通过；真实 memory pressure、RSS 配对不足。 |
| P4 封面 | 功能通过，主要 PNG 速度门槛未闭环 | 动态 DPR/两轴目标/远端档位通过；旧包真实 JPEG384 冷改善约 35--39%，但主要 PNG 和最终新配额包 20% 门槛仍未收口。 |
| P5 画布 | 局部质量与几何通过，完整交互待收口 | 原像素区域/缓存精确；正常产品完整手势/操作及最终性能仍需证据。 |
| P6 大图 | 静态区域与 Windows 格式矩阵通过，完整格式矩阵未闭环 | Windows `reader-flat-v2-quality-formats-windows.json` 已完成 132/132；96MP/长图/EXIF/alpha/静态 JPEG/PNG/WebP 有双端区域证据；动画和真实特权大输入未覆盖。 |
| P7 派生/空间 | 配额发布通过，真实产品压力待验 | 63/63 writer、低空间拒绝/恢复和源保护通过；实际后台入库/清缓存/压力组合待验。 |
| P8 服务 | 正式 HTTP 与实际客户端链通过，GUI 边界待验 | 正常 profile `--server` 13 项通过，真实 Remote ReadingData 12 工作流通过；不是正常远程 App UI。 |
| P9 选优 | 有候选/否决依据，默认尚未定 | Texture 有不优先采用依据；新 prepared/encoded cover 等 opt-in 候选不由单测决定默认。 |
| P10 交付 | 自动化绿，完整 UAT 未闭环 | [最终全量](final-after-candidates-regression.md) 2881 passed / 15 skipped / 0 failed，analyze 无问题；不等于所有出口完成。 |

## 缺口优先级

| 顺序 | 未关闭项目 | 已有证据，不能重复否定 | 最小关闭条件 |
| --- | --- | --- | --- |
| 1 | **放大显示质量：ICC、16-bit、广色域/HDR；动画真实播放。** 静态 native 目标是 sRGB8，保留原文件不等于保留其全部显示精度。 | [native](native-results.md) 有小源独立 codec/色彩/两帧时序；[prepared](native-prepared-read-candidate.md) Android 最新 66/66 画布/缓存精确，但不含这些正式 reader 场景。 | 正式三布局/两模式绘制代表图，核对既有显示基线、颜色/精度终态、动画帧依赖/时序和超预算终态；不把 sRGB8 exact 外推为 HDR 保真。 |
| 2 | **速度与帧门槛。** Redmi 热 ROI 仍有约 512--787 ms、viewport 约 464--813 ms；部分 4000×6000 冷读明显回退，100--200 ms/20%/10% 门槛未收口。 | [reader](reader-results.md) 保留成功及回退；[诊断](prepared-read-performance-diagnosis.md) 已比较 tile/viewport/raw-sync/fit/持久化，不是无尝试。 | 最终同源同包 N30，分冷源/磁盘热/解码热，报告 T_sharp、T_cover_visible、ROI、帧 P95/P99/超帧比例与预算；继续优化或由用户基于证据接受偏差。 |
| 3 | **正常 UI 保存/分享/收藏完整流程。** Windows 已到真实 JPEG 阅读器，只看见工具栏，未调用系统 dialogs；两端完整选页/重进未验。 | [正常 UI](normal-ui-isolated-entry.md) smoke 已实际执行；34/34 导出回归和真实来源输出 SHA 已通过。Android 合成 PNG 的 MediaStore 返回 URI/SHA 也已实测。 | 隔离正常 App 实际列表→阅读→放大→连续非当前页/双页选页→保存/分享/收藏→重进；核目标 SHA、格式、记录身份、异步切章及同名不串图。 |
| 4 | **Root/Shizuku App UID 真桥。** Root 的 ADB 只读取样不能替代应用 MethodChannel/binder；新机不可用不算通过。 | [真实来源](source-real-download-results.md) 的原文件/ZIP/HTTP 全链已绿，64 KiB copy/限额/取消契约有测试；未验证的只是实际特权目标链。 | 具备权限的目标真实授权/恢复/拒绝、stat、超一次性缓冲的大源/成员受控复制、取消/超限与 SHA；没有目标就保持明确未验。 |
| 5 | **OS pressure 和进程残留。** 没有真实 didHaveMemoryPressure 闭环，也没有预热后十轮配对 RSS/PSS 的 max(32 MiB,10%) 判定。 | [默认生命周期](reader-final-default-lifecycle.md) 六组 N10 共 60 次内部资源/配额归零；180 秒初段+60 秒完成后 smaps 稳定，不能拼成逐退出证明。 | 真实前后台/内存压力后保护可见源、释放自管资源并恢复；同 PID、同流程逐退出配对 OS 采样，区分引擎/GPU 驻留与持续增长。 |
| 6 | **动画/特权输入、交互和后台缓存产品入口。** Windows 格式矩阵已归档，但不含 ICC/16-bit/HDR/动画；harness 主动清自有缓存也不等于正常 LRU。 | [画布质量](surface-quality-results.md) 双端 exact；Windows `reader-flat-v2-quality-formats-windows.json` 为 22 fixture × 3 布局 × 2 模式、132/132 complete、实际 raster、资源出口 0；[quota](disk-quota-results.md) writer/清理代次/低空间拒绝恢复已绿。 | 补 Android 最终代表矩阵和特殊色彩/动画/Root/归档链；核焦点/历史/奇数反向双页、设置重启/导入；正常入库/扫描后台派生与清缓存交错，原源和 lease 保持安全。 |
| 7 | **P8 正常 GUI/远程 App 与兼容组合边界。** GUI 服务按钮/正常远程页面及外部旧能力组合没有同一次产品证据。 | [正式服务](cover-server-results.md) 新 quota 正常 headless 13 HTTP 已通过；真实 loopback 客户端、202/409/304/鉴权/坏正文/取消/恢复已有集成，不应写成“协议全未验”。 | 正常 task GUI 服务及 App 客户端实际消耗变体/tiles/原文件，补新旧组合与断连/重连；系统 UI 仍按第 3 项单独验收。 |
| 8 | **封面最终选优和交付默认。** native encoded fit 等候选默认关闭，主要 PNG 的最终两端 N30 尚无已归档 20% 收益，不以编码微基准代替首显。 | [封面](cover-server-results.md) 有旧包 JPEG384 冷改善约 35--39%、32/64 MiB 与真实 ZIP PNG 的 A/B、尺寸测试和远端 35/35；Texture 的 CPU/GPU/复杂度取舍有 [依据](flutter-raw-upload-study.md)。 | 保留已通过的 JPEG 组，集中最终相同 PNG 卡片/源/DPR/BoxFit 交替默认/候选，报告真实 raster、观感、冷/热/OS 资源；门槛与质量通过后决定默认，最后跑正常完整 UAT。 |

本审计没有发现应把已绿色 source/server/quota 整体退回“未实现”的理由。剩余最高价值是**特殊显示质量、真实性能、正常系统操作和 OS/特权链**；全量测试通过、构建成功、图层 complete 和源 SHA 不变分别只证明自己的范围，不能互相替代。后续主任务完成的新 profile 报告应按其实际选项/版本更新此页，不覆盖失败日志，也不事后降低原验收门槛。

## 2026-10-06 18:46 执行增量

Windows当前alpha/gutter代码快照的ICC/16-bit/动画真实Reader矩阵现已36/36 measured、49帧匹配FrameTiming、0错误、素材SHA未变；测试帧对其同平台original-codec/sRGB Canvas参照均RGBA8 exact，见 [v6 Windows原始报告](color-animation-alpha-v6-windows.json)。结合Android v6的36/36结果，重复半透明preview覆盖问题在所测Android/Windows组合已消失；但Android RGBA16/gray+alpha16画布仍最大1级差，Windows exact也不证明其codec已保留全部16-bit面板精度。

此增量没有关闭速度N30、色彩/HDR端到端、原生瓦片gutter专测、OS稳定基线十轮回收、正常应用原图放大与系统保存/分享等验收项。不得将本次49帧质量矩阵表述成大图提速或P0—P10全部通过。

## 2026-10-06 19:56 继续执行核对

以下增量修正上表的历史“尚待收尾”描述，原始出口与验收标准不变：

- **Prepared 配对已经测完，绝对门槛仍未过。** Redmi v6 同包 on/off 各360样本、0错误、0缺帧；prepared ROI on P95 442.78–619.52 ms，off 694.57–1132.28 ms，相对改善36.3%–49.0%，仍超过100–200 ms。普通 ROI 改善24.1%–48.1%。候选继续默认关闭；详见[当前配对记录](prepared-read-performance-diagnosis.md)及[on](reader-v6-prepared-on-redmi1006.json)/[off](reader-v6-prepared-off-redmi1006.json)。不要再将该 Android 配对写成未运行，也不要将其写成已达绝对速度目标。
- **封面 encoded 候选双端八份最终报告已齐。** 四组候选冷 P95 全部回退；ZIP 候选比同轮默认慢至2.79倍（Windows）和2.47倍（Android），继续关闭。Android 默认4096 PNG冷232.979 ms对baseline217.266 ms、ZIP PNG冷192.403 ms对202.709 ms，仍无20%瓶颈组收益。见[最终封面记录](cover-server-results.md)。候选否决证据已完成，性能目标未关闭。
- **色彩/动画已形成双端真实 Reader 证据，16位残差单列。** Windows v6 36/36组合、49匹配帧全exact；Android v6 36/36组合中P3/Adobe/GIF/WebP exact，重复preview alpha大差已消失，RGBA16/gray+alpha16仍最大1级差。最新[v7真实诊断](color-diagnostics-v7-redmi1006.json)与[整数ROI精度控制](color-precision-v7-redmi1006.json)定位到整数1:1裁片使用medium滤波的附加量化；生产修复随后由主任务处理，未复测前不能记通过。这些sRGB画布记录不证明原16-bit码值、面板广色域或HDR端到端保留。
- **Native gutter后端契约已补验。** Windows独立prepared库4 passed、1按符号能力skip，包含扩边输出逐字节对应同原图ROI；见[color记录增量](color-animation-profile-results.md)。不能再将该后端gutter组写成未执行；真机所有分数缩放、压力和预算组合仍各自保留边界。
- **正常系统操作有可执行的新设施，但尚不计UAT通过。** [隔离入口](normal-ui-isolated-entry.md)现在提供两章各三页、不同作品同名PNG、真实share插件委托观测，以及来自WidgetsBinding的OS压力记录；12/12入口/隔离/委托测试通过。离线审计可核实际保存输出和收藏DB身份/SHA，始终保留`fullAcceptanceComplete:false`。主任务尚需实际点击放大、选页、保存/打开并取消分享、收藏与重进；测试或工具存在本身不关闭P1/P5/P10。

当前关键缺口仍是：最终普通/大图速度与帧门槛；Android16位残差生产修复后的精确复测与显示能力边界；双端正常原图系统操作；真实OS压力恢复与同PID预热后十轮RSS/PSS基线判定；应用UID Root/Shizuku授权和大输入复制；真实后台入库/清缓存竞争；正常GUI服务与远程App及新旧兼容组合。既有source/server/quota绿色证据保留，不整体退回“未实现”。
