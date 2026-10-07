# 大图首幅画面续修 · 2026-10-07

用户确认大图均从插画瀑布流点入，但有些首图快、有些仍需等待。主力机只读设置确认插画为 `sharpFirst`：其缩放正式像素也可能显得模糊，不能据此认定启用了额外的 `previewFirst`。

## 实现与边界

瀑布流之前只传阅读条目，没有传已显示封面的 provider；封面可能来自原文件，也可能来自统一缓存副本，路径不同会使普通缓存查找失配。现在将点击条目的 prepared provider 经既有阅读工厂交给阅读数据，只克隆已解码的有界像素。缓存未命中不 resolve、不新增原图解码。

复用限定为能核对 work/page/URL、单张普通本地文件和原件 snapshot 的条目。原路径精确一致，或现有来源指纹索引核验的内部副本可以借用；多图、归档、错误来源、失效 snapshot/generation、形状不一致均回退原图。临时低密度层独立计入 Surface 预算，既不使正式分块 complete，也不写原件/session 像素缓存，不参与保存、分享或收藏的原件选择。

首次还没有像素时仅启动一个 estimate/decode，请求泵在实际首幅 build/post-frame 后放行其余块。预览不再被同源布局或 pan 的正式需求取消；失败继续请求正式块，换源迟到结果释放。帧结束还会复核当前可见区域，防止首块在 paint 前被平移出屏却误报。切换模式保留已显示图像；同源换网格不重新限制已经呈现过的会话。

新增 `onFirstRasterPresented` 与原 `onPresented` 分开。前者代表当前可见区域首次有 raster，可能只有一个正式块；后者仍只代表全部正式需求补齐。harness 用各自 build 时间匹配实际 `FrameTiming.rasterFinish`，不把 post-frame 或解码阶段时间当 GPU 呈现时间。

## 备用机同包对照

设备 `192.168.5.3:5555 / 8021129d`，Android profile。三种匿名源均为 8000×12000，single、sharpFirst、最终默认自适应网格；PNG/verified baseline fit 为 1024，渐进 JPEG 为 512，原像素策略未改。每条件 N=3，共 18 样本。

同一最终 harness APK，两个条件都在测量请求前准备并消费 768 档封面；只切换是否把该现成像素借给 reader。Reader 派生像素/backing 每次清理为任务冷态，OS cache、温度及封面准备成本未控制或计入。**这是已存在封面场景的同包工程对照，不是旧包/新包 N30，不证明首次封面解码变快。**

| 格式 | 不借封面首幅中位 ms | 借封面首幅中位 ms | 不借封面完整中位 ms | 借封面完整中位 ms |
| --- | ---: | ---: | ---: | ---: |
| PNG | 1018.932 | 27.889 | 1633.977 | 1584.163 |
| baseline JPEG | 218.798 | 29.727 | 1652.210 | 1609.871 |
| progressive JPEG | 13391.407 | 43.013 | 14403.567 | 14606.756 |

九个借封面样本首幅范围 24.223–44.704ms，均记录一次实际复用；不借条件均为零。18 样本全部 complete、errors 空，首幅和完整 raster 时间匹配。最终 Surface resident/pending、active/jobs/queued、working/temporary、originalFileLeases、pending raster cache、native active/queued 和 disk active 全归零。配置原字节恢复、host/device fixture SHA 不变、cleanupErrors 空。

渐进 JPEG 的完整补齐仍为 13.550–15.449 秒，未证明改善；不能把已有封面先出现说成完整清晰原图已经加载。用户真实三图同素材、冷 backing/首次原像素和完整 022 门槛仍开放，桌面实际验证继续暂缓。

原始依据：[18 样本与资源核验汇总](D:/picakeep-image-pipeline-022-work/large-open-1007/paired-20261007T115450495324Z/first-raster-summary.json)、[配置与源件恢复记录](D:/picakeep-image-pipeline-022-work/large-open-1007/paired-20261007T115450495324Z/session.json)、[实际 harness 身份](D:/picakeep-image-pipeline-022-work/large-open-1007/first-harness-identity1007.json)。汇总保留每个条件的全部值及六份原始报告路径。

## 回归与正常交付

135 项 reader/原件操作/会话保留/瀑布流及普通封面回归通过；缓存桥接 6 项和新增 Surface 缓存消费 6 项也通过，共 147 个不同用例。覆盖首次请求门控、失败回退、首 paint 前 pan、晚到换源/退出释放、缓存 miss 不启动 decode、内部副本来源、错误绑定及正式透明像素覆盖预览。定向分析无问题。

正常 `lib/main.dart`、无诊断 define 的 profile 经 clean/offline pub get 构建 108.9 秒。872 产品输入与快照/工作区 SHA 一致，451 实际 compiler 输入 hash 一致，APK 版本/签名/CRC 通过；三个 native ABI 与本轮 harness、上一份自适应正常包逐字节一致。本追加没有改变 native decoder。

交付 [picakeep-large-open-first-normal-profile1007.apk](D:/picakeep-image-pipeline-022-work/picakeep-large-open-first-normal-profile1007.apk)，61,906,601 B，SHA256 `C1BB13A72E01937BAB239AFA31722A0D79687EA44D7AF927CFF90793BAA1F895`，9 / 1.9.92，既有证书 `31b4434516ccc1f58add7cc5cd4b6786e995c957d5891d3685e4c75a7a58d7c7`。见 [正常包核验](D:/picakeep-image-pipeline-022-work/large-open-1007/first-normal-identity1007.json)。

- 主力机 `192.168.5.12:5555 / f294cd23` 于 19:59:17 显式 install-r 成功，未启动 PicaKeep；首次安装时间不变，前后同一 QQ SplashActivity 实例。见 [主力安装](D:/picakeep-image-pipeline-022-work/large-open-1007/first-normal-f294cd23-install1007.json)。
- 备用机测量 finally 先恢复上一正常自适应包，20:00:25 再显式 install-r 安装本轮正常包并启动，PID22690。首次安装时间不变；[正常客户端设置界面](D:/picakeep-image-pipeline-022-work/large-open-1007/first-normal-spare-ui1007.png) 可见，该 PID 启动 error/fatal 过滤为空。见 [备用安装](D:/picakeep-image-pipeline-022-work/large-open-1007/first-normal-8021129d-install1007.json)。

未卸载、清应用数据、修改用户源图、构建 release、提交或推送。两个设备最后均为本轮正常包；主力原 forward21173 未操作。022 保持执行中，本追加完成不能代替整计划验收。
