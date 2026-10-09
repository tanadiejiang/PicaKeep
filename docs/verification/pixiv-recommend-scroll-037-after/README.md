# 037 修复后验证

有限 overview 前分区已改为 SliverToBoxAdapter 中的 StaggeredGrid.count + StaggeredGridTile.fit，按卡片真实自然高度完整排布。最后一个分区继续使用懒加载 SliverMasonryGrid；真实首页的额外完整构建成本为 10 张推荐卡，48 张收藏继续懒加载。单分区 overview、单入口分页推荐和榜单继续使用原懒加载路径。工具栏显影和避让代码未修改。

具体实现见[共享卡片构造与分区布局](<D:/Flutter_Projucts/PicaComic/PicaKeep/lib/pages/explore/explore_page.dart:1375>)。两种布局共享原卡片 key、屏蔽提示、bookmark controller、账号与刷新回调、详情会话。未截断接口返回条数，没有内部可滚动 grid，也没有增加 cacheExtent 或强制滚动定位来遮盖问题。

[回归测试](<D:/Flutter_Projucts/PicaComic/PicaKeep/test/explore/pixiv_recommend_scroll_investigation_test.dart>)仍每 16ms 记录 metrics、scroll delta、隐式 residual、toolbar、末段 grid 和完整前段 box 的实际尺寸。原始[故障调查说明](<D:/Flutter_Projucts/PicaComic/PicaKeep/docs/verification/pixiv-recommend-scroll-037/README.md>)及 before JSON 全部保留，after 只写入本目录。断言已从 expectedKnownBugSignature=true 切为 false：向下手势或惯性阶段且非显式定位、非页尾正常物理回弹时，frameDelta 和未通知 residual 均不能低于 -2px。另断言自然手势能继续进入末段后半，并以真实 card rect 与 viewport 重叠确认可见，避免只用 cache 构建项冒充深处内容。

| 场景 | before 异常次数 / 最小向下位移 px | after 帧数 | after 异常 / layout error | after 最小向下位移 / 隐式 residual px | 初始构建数 |
|---|---|---:|---|---|---|
| mobile-2col-balanced | 3 / -3988.635 | 1237 | 0 / 0 | 0 / 0 | 24,24,1 |
| mobile-2col-pane | 3 / -3979.544 | 1237 | 0 / 0 | 0 / 0 | 24,24,1 |
| mobile-2col-seeded | 3 / -3568.026 | 1192 | 0 / 0 | 0 / 0 | 24,24,1 |
| mobile-3col | 4 / -2030.926 | 1057 | 0 / 0 | 0 / 0 | 24,24,1 |
| mobile-2col-compact | 5 / -1642.500 | 1012 | 0 / 0 | 0 / 0 | 18,18,1 |
| mobile-production-10-48 | 6 / -1579.820 | 1096 | 0 / 0 | 0 / 0 | 10,1 |
| large-2col-pane | 2 / -9472.260 | 2236 | 0 / 0 | 0 / 0 | 24,24,1 |
| mobile-production-large-text，textScale=1.5 | 新增，无 before | 1141 | 0 / 0 | 0 / 0 | 10,1 |

所有场景 overview 请求一次，comic/directory 请求为零，账号、入口与会话不变。生产 10/48 自然滚动达到 pixels=8243.480051，viewport 内真实可见收藏 index38…43；首完整 box 实测 371×1756.55px，“我的收藏”标题 contentTop=1812.55px，与 before 相同。修复没有靠改变原分区高度避开阈值。大窗口自然滚到 pixels=23460.704431，可见最后关注段 index10…14，并成功越过两个完整前分区。

三分区压力夹具的前两个分区共 48 张（compact 为 36 张）完整构建，最后一段初始只构建 1 张。这个成本高于真实首页的 10 张，用于验证连续多个可完全越过的分区。若未来 overview 有很大的非末分区，完整构建成本随返回数据增加，应另行评估；此次没有把真实 48 张收藏全量构建，也没有截断返回数据。

实际测试结果与日志：

- 八个逐帧滚动场景全部通过，完整 JSON 和 summary JSON 均在本目录。见[包含八场景结果的组合日志](<D:/Flutter_Projucts/PicaComic/PicaKeep/docs/verification/pixiv-recommend-scroll-037-after/targeted-tests.log>)。
- 同一组合运行的 waterfall 文件起初因新增测试引用包内未导出的 delegate 类型而编译失败，因此组合进程整体 exit 1；八个滚动场景仍全部执行完成且通过。类型断言随后改用公开 getCrossAxisCount API，仅复跑 waterfall 文件，**27/27、exit 0**，见[独立 waterfall 日志](<D:/Flutter_Projucts/PicaComic/PicaKeep/docs/verification/pixiv-recommend-scroll-037-after/waterfall-tests.log>)。为避免无意义重复，没有再重跑已通过的八场景。
- 原工具栏检查共 **4/4、exit 0**：靠近顶部显影、透明背景，见[显影日志](<D:/Flutter_Projucts/PicaComic/PicaKeep/docs/verification/pixiv-recommend-scroll-037-after/toolbar-tests.log>)；顶部避让收起与回顶恢复见[停泊日志](<D:/Flutter_Projucts/PicaComic/PicaKeep/docs/verification/pixiv-recommend-scroll-037-after/docking-tests.log>)；控制条高度与榜期操作见[高度日志](<D:/Flutter_Projucts/PicaComic/PicaKeep/docs/verification/pixiv-recommend-scroll-037-after/toolbar-font-tests.log>)。
- 三个修改文件定向 dart analyze 为 **No issues found**，见[分析日志](<D:/Flutter_Projucts/PicaComic/PicaKeep/docs/verification/pixiv-recommend-scroll-037-after/analyze.log>)；scoped git diff --check 通过。
- 新增 waterfall 回归实际检查完整推荐 10 张、收藏 lazy delegate=48，3 列／隐藏标签设置实时生效，同一 ScrollController 的 offset 保持，以及切榜单再回推荐不重新请求 overview。既有屏蔽分区、续页、刷新心态、详情返回、源切换缓存测试全部通过。

最初一次运行曾读到并行详情会话修改的中间状态，编译器提示 continuation 字段未声明，没有进入本次用例；待集成代码完成后才运行有效检查。一次 toolbar 过滤命令也因 Windows bat 对正则管道字符解释而未进入测试，随后使用三个独立安全关键词完成上述四项检查。没有将这些执行问题当作生产滚动功能失败或忽略掉。

[对比 JSON](<D:/Flutter_Projucts/PicaComic/PicaKeep/docs/verification/pixiv-recommend-scroll-037-after/comparison.json>)由[只读对比脚本](<D:/Flutter_Projucts/PicaComic/PicaKeep/docs/verification/pixiv-recommend-scroll-037-after/compare_traces.py>)生成；各原始 JSON 的 frames 节点保留完整分区 box 尺寸、实际构建数、lazy child range 与所有事件。[生产 after trace](<D:/Flutter_Projucts/PicaComic/PicaKeep/docs/verification/pixiv-recommend-scroll-037-after/mobile-production-10-48.json>)可直接与 before 同名数据对照。

复跑命令：

```powershell
$tempPath = 'D:\Flutter_Projucts\PicaComic\PicaKeep\.dart_tool\037-temp'
New-Item -ItemType Directory -Force -Path $tempPath | Out-Null
$env:TEMP = $tempPath
$env:TMP = $tempPath
flutter test --no-pub --reporter expanded test/explore/pixiv_recommend_scroll_investigation_test.dart test/explore/recommendation_waterfall_test.dart
```

本轮没有构建、安装、真实 Pixiv GET/POST 或用户数据删除。结果来自离线 widget 测试；真机帧率、完整手势视频与设备安装验收未执行。
