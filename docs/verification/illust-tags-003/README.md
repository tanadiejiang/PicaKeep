# 第十九轮 003 · 插画标签区绘制与重建优化

2026-10-04，基于 `main` / `83a47ff161758adc15b1f756b072b6beb92ca8b6` 和上一轮未提交搜索改动。计划与回写见 [003 计划](../../../Z-plan/新需求-主线-第十九轮/003-计划-插画标签区绘制与重建优化.md)。本轮已验证重复绘制和无效页面重建被消除；尚未进行优化后的真机录制，不能报告 FPS、毫秒收益或宣称首帧尖峰已解决。

## 已实施的行为

1. 在 `SingleChildScrollView` **内部**给标签 `Wrap` 增加一个 `RepaintBoundary`，滚动时复用内容显示列表。SDK 滚动视口本来就是绘制边界，外包一个边界不能解决内部内容重绘，因此没有重复增加视口层或每个 chip 的图层。
2. 缓存标签排序及标准 `FilterChip` 子树。关键词、作品数等无关父状态变化不重新创建它们；标签内容/count、原地修改的选中集合和前12/全部切换仍能正确失效。回调读取当前 `widget.onToggleTag`，继承主题、字号与方向仍由子组件订阅。
3. 父页面搜索监听比较**原始文本**快照，忽略光标、选区及输入法 composing-only 更新；文本输入、空白变化和清空仍立即重建页面并触发原过滤流程，没有防抖延迟。

没有改变标准标签的外观、触控反馈、无障碍语义、已选置顶、多标签交集、搜索范围开关、面板高度、悬浮按钮或220ms过渡。

## 原报告的口径纠正

原始 CPU / Performance JSON 均在 Downloads，指纹与旧报告一致。未更改 `002` 报告、旧分析脚本/摘要或原始采样；本轮生成了 [sample_summary.json](sample_summary.json) 和 [trace_findings.json](trace_findings.json)，脚本可复算。

| 核查项 | 正确口径 | 对原结论的影响 |
| --- | --- | --- |
| 全段帧数 | 292帧；按vsyncStart到rasterFinish覆盖约8.079s | 录制平均帧数含无新帧需求的间隔，不能当持续FPS |
| 全段120Hz阶段预算 | UI/raster任一阶段超过8.333ms：3/292=1.03% | elapsed超过预算63/292=21.58%回答另一问题；不能直接称为掉帧率 |
| “20%–70%滚动段” | 实际索引 `[58:204]`，146帧，包含约3832.468ms未记录帧覆盖间隔 | 未有手势标记，不应声称是连续滚动段；其elapsed超预算60/146=41.10% |
| CPU权重与时间 | 权重779.636ms；时间戳跨度3478.518ms | `timeExtentMicros`不是录制墙钟时长 |
| 两份记录对齐 | 共享单调时钟假设下，CPU起点比Performance终点晚32858.940ms，无重叠 | CPU热点不能直接归因首帧或该帧索引切片 |
| 首帧UI106.281ms | 包含布局与绘制，不能解释为纯widget build | 不据此改变动画或认定瀑布流是主因 |
| 首帧之后126.058ms | 是buildStart到下一buildStart；rasterFinish到下一buildStart为9.151ms | 不存在“首帧结束后又停126ms”的证据 |
| 二进制标记词频 | root与普通阶段嵌套；字符串出现次数不是事件/帧/GPU saveLayer次数 | 不能据584等词频宣称每帧语义重刷或每chip saveLayer |

新摘要使用最近秩百分位 `ceil(p*N)-1`，与旧脚本取整索引略有不同；切片p50为UI4.741ms、raster2.688ms、elapsed8.055ms，这些仍不是连续滚动专项测量。CPU自身窗口的 `Wrap` 与滚动视口绘制链热点仍成立，结合SDK全量 `Wrap` paint行为，可以支持本轮保留显示列表的选择。

## 首帧现在能确认什么

解析 Performance 内嵌 Perfetto 记录，首帧 `#2244` 相对于 `buildStart` 有如下证据：

| 记录 | 起点→终点 | 时长 | 限制 |
| --- | --- | --- | --- |
| LAYOUT (root) | 51.283→98.113ms | 46.830ms | 该根阶段涉及整页面布局，不能全算某一个widget |
| RenderParagraph.getDryLayout | 上述布局内140次 | 合计26.124ms | 无widget身份信息，不能断言140次全来自标签 |
| PAINT (root) | 98.426→106.075ms | 7.649ms | 根绘制；子事件不可重复相加 |
| SEMANTICS (root) | 106.358→122.511ms | 16.153ms | 提交之后，与raster重叠，不能串行加到build/elapsed |
| MournWeakHandles GC | 45.765→48.976ms | 3.211ms | 不能据此认定整个前段皆GC |

前段缺少一些匹配的起始事件，没有完整 `BUILD` slice，仍有约51.5ms UI工作未由上述命名根阶段解释。解码器仅支持当前记录的绝对时钟和直接命名begin/end事件；会报告未配对/不支持记录，并验证布局、绘制在UI阶段内、子文本时长不超过父布局。它不是任意Perfetto导出的通用解码器。

## 验证证据

| Evidence | 可复现观察 | Finding | Path |
| --- | --- | --- | --- |
| E-01 [regression-tests.txt](regression-tests.txt) | 9项真实组件测试通过；6次滚动offset变化时内容边界的symmetric paint为0、asymmetric paint大于0 | 不变标签内容显示列表在滚动中被复用 | 滚动视口更新位移/裁剪→复用Wrap内容层 |
| E-02 同上 | 140项末项选择、收起/清除/重开、原地Set/List更新、回调更新、主题/1.6字号、320dp RTL、语义通过 | 缓存未改变标签功能与继承更新 | 新数据/选中变化→失效重建；主题→后代依赖更新 |
| E-03 [page-search-tests.txt](page-search-tests.txt) | 26项通过，其中图集/插画各验证文本与空白编辑、清空立即重建，selection/composing-only不重建页面 | 无效控制器通知不再触发整页build | TextEditingController→文本快照比较→必要setState |
| E-04 [sample_summary.json](sample_summary.json)、[trace_findings.json](trace_findings.json) | 原始文件SHA256一致，时间窗、阶段、首帧布局与绘制可复算 | 可以修正统计误读，但无法量化优化后收益 | 文件→标准库分析→按时间窗与阶段解释 |

验收命令（在仓库根目录执行）：

```powershell
flutter test test/illust_search_panel_performance_test.dart --reporter expanded
flutter test test/local_library_page_view_scope_test.dart test/illust_search_panel_test.dart test/illust_search_match_test.dart --reporter expanded
flutter test --reporter expanded
flutter analyze
flutter build apk --profile
python docs/verification/illust-tags-003/analyze_samples.py
python docs/verification/illust-tags-003/decode_first_frame.py
```

两个Python脚本默认读取本机Downloads文件；第三方复算需用 `--cpu` / `--perf` / `--out` 指向自己的导出和新输出。样本不进入仓库。详细JSON、日志、脚本与改动前Dart快照按项目现有规则保存在本地证据目录；README与来源/产物manifest可跟踪。

全量 **2374通过、14跳过、0失败**（127秒）；`flutter analyze` **No issues found**。第一次页面计数测试错误使用SDK的 `builtOnce` 标记过滤，未开启打印时该标记一直false，已修测试观察器，不改生产逻辑来迁就测试；新语义测试也按SDK要求在测试结束前释放handle。保留了首次页面测试失败日志，最终日志为通过版本。

## 构建与交付

- `flutter build apk --profile` 成功，Gradle assembleProfile 159.6秒。
- 独立APK：`build/verification/illust-tags-003/app-after003-profile.apk`，129329379字节（123.3MiB）；SHA256：`1EA5B66B19A10E7726BA184C7D3BCC76475D662154EF329467B472440EDFA53B`。
- 包名 `lingxue.picakeep`，versionName `1.9.89`，versionCode `6`。身份与检查结果见 [apk-metadata.json](apk-metadata.json)。
- [source-manifest.json](source-manifest.json) 中774个构建输入在构建前后哈希一致；APK含上一轮未提交功能与本轮优化，不等同于单独基线提交。
- 本轮未安装、卸载、清除数据、重启或操作手机应用。

## 残余风险与真机复验

完整标签仍首次全量创建/布局；选择变化可能重绘完整内容；语义节点仍保留，没有关闭无障碍；完整display list的资源保留开销尚未真机量化。当前优化解决滚动录制重复工作，不能单独消除106ms展开尖峰。

继续复验时，使用同一设备、profile模式、APK指纹、刷新率和字体/无障碍环境，分别录制“只展开不滚动”“12个标签滚动”“全部标签滚动”“主列表滚动”“连续输入再删除”。CPU与Performance同步开始/结束。诊断展开时可单独开widget build/layout追踪，比较常规性能的录制应关闭额外追踪，避免测量开销混淆。

如果首帧复采样仍确认全量标签布局为主要瓶颈，再单开保留变宽换行、键盘/读屏showOnScreen与已选置顶的行级虚拟化计划。固定列宽网格改变外观、分批按钮改变“全部”的语义，本轮没有据未经验证的建议直接替换。
