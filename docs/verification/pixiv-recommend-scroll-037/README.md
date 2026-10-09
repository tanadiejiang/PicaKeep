# Pixiv Explore 推荐分区滚动调查 037

已用真实 ExplorePage 稳定重现分区边界附近的向顶部回跳。生产计数对照仅有两个分区：推荐 10 条、我的收藏 48 条；另外六个压力场景保留三个独立 SliverMasonryGrid。所有场景只请求一次 fixture overview，未请求续页、目录、封面或真实 Pixiv 网络。

本次只新增[独立调查测试](<D:/Flutter_Projucts/PicaComic/PicaKeep/test/explore/pixiv_recommend_scroll_investigation_test.dart>)和本目录内的日志、JSON、汇总脚本。生产代码及依赖源码均未修改，没有 build、install、release 或用户数据删除。

测试当前明确断言“已存在 bug 的签名”：向下滚动时 frameDelta < -100px 且 unnotifiedResidual < -100px。**诊断测试通过代表复现了旧 bug，并不代表修复通过。** 修复后应将这项断言改成正常向下滚动的单调性检查。

初始六个压力用例在同一次运行中完成，6/6、exit 0，见[六场景运行日志](<D:/Flutter_Projucts/PicaComic/PicaKeep/docs/verification/pixiv-recommend-scroll-037/independent-test.log>)。随后根据实测添加 known-signature 断言和生产 10/48 场景，仅过滤运行新增场景，1/1、exit 0，见[生产计数运行日志](<D:/Flutter_Projucts/PicaComic/PicaKeep/docs/verification/pixiv-recommend-scroll-037/production-10-48-test.log>)。没有重复运行已完成的六个压力场景；其原手势序列保留不变。最终文件的 dart analyze 为 No issues found，见[静态分析日志](<D:/Flutter_Projucts/PicaComic/PicaKeep/docs/verification/pixiv-recommend-scroll-037/analyze.log>)。

| 场景 | 视口 / 列数 / 导航壳 | 每分区条数 | 帧数 | 异常次数 | 最小向下帧位移 px | 最小隐式 residual px |
|---|---|---|---:|---:|---:|---:|
| mobile-2col-balanced | 375×812 / 2 / Scaffold | 24,24,24 | 859 | 3 | -3988.635 | -4047.715 |
| mobile-2col-pane | 375×812 / 2 / 生产 NaviPane | 24,24,24 | 859 | 3 | -3979.544 | -4038.397 |
| mobile-2col-seeded | 375×812 / 2 / Scaffold，seed=37037，不限标签行 | 24,24,24 | 814 | 3 | -3568.026 | -3611.436 |
| mobile-3col | 375×812 / 3 / Scaffold | 24,24,24 | 679 | 4 | -2030.926 | -2101.555 |
| mobile-2col-compact | 375×812 / 2 / Scaffold，较矮卡片 | 18,18,18 | 634 | 5 | -1642.500 | -1712.537 |
| large-2col-pane | 1200×900 / 2 / 生产 NaviPane | 24,24,24 | 1354 | 2 | -9472.260 | -9506.093 |
| mobile-production-10-48 | 375×812 / 2 / Scaffold，真实生产计数和收藏“查看更多”header | 10,48 | 718 | 6 | -1579.820 | -1690.550 |

七场景均为 overview=1、comics=0、directory=0、layout errors=0。异常次数包括反向滚动的隐式校正，最小 residual 也包含反向阶段；表中最小向下帧位移仅筛选 phase 含 down 的帧。跨分区前的慢速 viewport 进入步骤没有大跳变；新增生产场景进一步慢速越过前一 grid 的 cache 边界，也能复现。

完整矩阵及各 phase 统计见[矩阵 JSON](<D:/Flutter_Projucts/PicaComic/PicaKeep/docs/verification/pixiv-recommend-scroll-037/matrix.json>)。每帧、通知顺序、fixture 内容见各场景 JSON；需要先查看时，优先使用[两列压力原始 trace](<D:/Flutter_Projucts/PicaComic/PicaKeep/docs/verification/pixiv-recommend-scroll-037/mobile-2col-balanced.json>)和[生产 10/48 原始 trace](<D:/Flutter_Projucts/PicaComic/PicaKeep/docs/verification/pixiv-recommend-scroll-037/mobile-production-10-48.json>)。其余场景的同名 JSON 和 summary JSON 均在本目录。[跳变窗口汇总](<D:/Flutter_Projucts/PicaComic/PicaKeep/docs/verification/pixiv-recommend-scroll-037/trace-analysis.txt>)保留每次较大负 residual 前后各两帧的 grid 状态。

所有卡片 cover=''、bookmarkStateKnown=true、avatar 默认空，Pixiv metadata 提供 width/height，避免图片网络或收藏读态干扰。基础两列 fixture 按 short/tall/tall/short 四张一组，长短标题和标签按组变化；主压力场景实际观察到每列各 12 张，不是因为一列条数较少制造失衡。尺寸为 width=1000、推荐 height=600/1900，收藏=640/1830，关注=680/1760。生产推荐 10 张实际每列各 5 张，但最后两张高度不同。seed=37037 场景和较矮 18 张场景的具体尺寸均保存在原始 JSON 的 fixture 节点。

分区定位使用真实“我的收藏”Text 的 laid-out global rect，结合 scroll pixels 和 viewport top 反算 contentTop，没有用平均卡片高度猜测。压力场景我的收藏标题 contentTop=3996.5px；生产 10/48 场景为 1812.55px。生产收藏 header 保留“查看更多”按钮，因此标题在较高的 Row 中居中。三分区 trace 的最后一个关注标题可能完全屏外，位置仍受到前一未完全排布 grid 的 extent 估算影响；它只作辅助快照，不作为触发阈值依据。

生产 10/48 的慢速手指阶段给出最直接的前后关系：

| frame | pixels | 首 grid 存活 child | 首 grid column | ScrollUpdate delta | frameDelta | unnotifiedResidual | toolbar opacity / scale / outer padding |
|---:|---:|---|---|---:|---:|---:|---|
| 178 | 1802.550 | 8,9 | 0,1 | +10.000 | +10.000 | 0 | 0 / 0.8 / 0 |
| 179 | 1812.550 | 9 | 1 | +10.000 | +10.000 | 0 | 0 / 0.8 / 0 |
| 180 | 282.000 | 0…7 | 0,1 | +10.000 | -1530.550 | -1540.550 | 0 / 0.8 / 0 |

frame180 仍是手指向上移动 10px 的真实向下滚动，pixels 却下降 1530.55px。首 grid 实测短列末端为 1523.2px，长列末端为 1756.55px，首 grid 的内容起点为 32px，默认 cacheExtent=250px。因此丢失短列存活记录的阈值约为 32+1523.2+250=1805.2px；1812.55px 那帧已仅剩长列最后一项，下一次 layout 就回跳。这也解释了为什么推荐只有 10 条时，现象刚好出现在“我的收藏”附近。快速滚动并非必要条件。

生产快速阶段 frame265→266：1807.783650→282.000000，frameDelta=-1525.783650，而 ScrollUpdate=+42.413935，隐式 residual=-1568.197585。repeat-fast-down 阶段 frame431、450、476 在同一次惯性滚动中三次回到 282px。对照压力场景也有相同落点：frame413→414 为 4268.302367→282.000000，通知仍为 +35.695813，residual=-4021.998180。

282px 精确等于首 grid 的起点 32px 加默认 cache 250px。压力场景跳变后的 grid constraints.scrollOffset=250、cacheOrigin=-250，所以有效 masonry scrollOffset=0。生产慢速 frame180 正常通知后本应到 1822.55px；有效 masonry offset=1822.55-32-250=1540.55px，与实际未通知校正 -1540.55px 完全一致。

跳变前后工具栏测量高度恒为 32px（36 是生产 fallback，首帧测量后校正到 32）。向下跳变前、当帧、后，Opacity=0、Transform scale=0.8、外层 Padding.top=0。pixels 远大于 dock，byScroll=dock-pixels 已小于零，避让为零。现有 trace 没有看到“顶部显影累加条件先改变，然后导致 pixels 回顶”的顺序。生产反向步骤另有一次未通知 -1690.55px 校正，同时工具栏按正常 -20px ScrollUpdate 从 0 开始显影到 0.15625，但 outer padding 仍为 0；这不能解释千像素级回跳。

包内[RenderSliverMasonryGrid](<C:/Users/tanad/AppData/Local/Pub/Cache/hosted/pub.flutter-io.cn/flutter_staggered_grid_view-0.7.0/lib/src/rendering/sliver_masonry_grid.dart:334>)将各 column 的最早位置初始化为 Infinity，并只从存活 children 填充。一个 column 全部被回收后，Infinity 仍存在；[L391 的循环](<C:/Users/tanad/AppData/Local/Pub/Cache/hosted/pub.flutter-io.cn/flutter_staggered_grid_view-0.7.0/lib/src/rendering/sliver_masonry_grid.dart:391>)尝试回建 leading children，最终可能在没有更早 child、有效 scrollOffset 非零时返回[负 scrollOffsetCorrection](<C:/Users/tanad/AppData/Local/Pub/Cache/hosted/pub.flutter-io.cn/flutter_staggered_grid_view-0.7.0/lib/src/rendering/sliver_masonry_grid.dart:413>)。逐帧存活列状态和精确校正量均与这一路径吻合。生产每分区创建独立 grid 的位置见[overview 布局](<D:/Flutter_Projucts/PicaComic/PicaKeep/lib/pages/explore/explore_page.dart:1443>)。

每帧 pump 之后读取到的 geometry.scrollOffsetCorrection 为 null：viewport 会在同一次 layout 中消耗校正并重试，最终 geometry 已被正常布局覆盖。此次没有修改 renderer 或注入 performLayout hook，因此使用“实际 pixels 差 − 当帧所有 ScrollUpdate delta”作为校正证据，并保留 controller listener / metrics 通知的原顺序。没有宣称直接截获 renderer 返回值，也没有制造 layout exception；所有已完成场景都没有 layout error。

复跑可使用以下 PowerShell 命令。TEMP/TMP 限定在工作区，App.init 使用单独 fixture 数据目录，并保留它而不删除数据；只执行已有依赖下的 widget test，不触发 pub、应用 build 或安装：

```powershell
$tempPath = 'D:\Flutter_Projucts\PicaComic\PicaKeep\.dart_tool\037-temp'
New-Item -ItemType Directory -Force -Path $tempPath | Out-Null
New-Item -ItemType Directory -Force -Path 'docs/verification/pixiv-recommend-scroll-037' | Out-Null
$env:TEMP = $tempPath
$env:TMP = $tempPath
flutter test --no-pub --reporter expanded test/explore/pixiv_recommend_scroll_investigation_test.dart
```

仅复跑生产两分区计数的已知签名：

```powershell
flutter test --no-pub --reporter expanded --plain-name '037 mobile-production-10-48 records real overview boundary scroll' test/explore/pixiv_recommend_scroll_investigation_test.dart
```

[汇总脚本](<D:/Flutter_Projucts/PicaComic/PicaKeep/docs/verification/pixiv-recommend-scroll-037/summarize_traces.py>)只读取 JSON，不更改源码或依赖；重新运行它可更新矩阵和跳变窗口。

后续最小验证应保留：生产 10/48、主两列 24/24/24、生产 NaviPane、反向后连续 fling，以及较矮和 seed 不同尺寸对照。候选方案应先在独立 fixture 内对照完整排布的有限首分区或局部 renderer 校正处理，确认既能自然跨分区又不破坏 variable-height 和 scroll restoration；此次没有实施任何候选方案。主调查会话将另行提交修复计划，并等待用户下一步指令。
