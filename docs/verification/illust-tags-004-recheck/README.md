# 第十九轮004 · 13:36标签滚动复核

2026-10-04，用户提供004后的CPU与Performance导出。结论：这份捕获中的典型提交后语义耗时下降，仍有少量真实尖峰；最慢UI帧另有同步标签行规划/文字测量贡献。不同录制的动作与覆盖范围并不完全相同，数值差不能当严格A/B或显示FPS收益。当前源码仍在main，775个004构建输入一致，本轮只分析/保存新证据，不修改应用代码或历史004/003记录。

## 文件与运行代码

| 导出 | 内容 | 大小 | SHA256 |
| --- | --- | ---: | --- |
| `标签滚动dart_devtools_2026-10-04_13_36_46.723.json` | CPU | 16901246字节 | `AAC665B8E69ABDEEE3E905A30E6A130BC4CDA9DD6BEDF88C85ABEC2414ECA53E` |
| `标签滚动dart_devtools_2026-10-04_13_36_36.008.json` | Performance | 37279629字节 | `F3226A66DCC42D8711C9D1BCFBA41DDED95FDD07321215D5E16269FD37142435` |

原文件均在本机 `C:/Users/tanad/Downloads`，只读保留。环境Flutter3.41.6、Android profile、DevTools2.54.2、120Hz。CPU含14119个样本，实际时间包络32.001秒；324µs名义周期乘样本数得到4.575秒采样权重，不能当录制时长或精确CPU时间。

CPU/Performance原始时钟包络重叠28.585秒，14116/14119个CPU样本落在Performance包络中，可进行有限时间关联。[设备身份核对](device_identity.json)确认当前安装的 `libapp.so` SHA256 `7052C54FDEE8E6E76774CAE792D0967D0AF523E0C5999E6142D5ED20847073DE` 与004一致；CPU也直接出现新组件的行规划函数。手机APK与004归档的整包差异仅MaterialIcons字体内容，不能据整包hash不同认定优化代码缺失。设备当前状态及13:35:51更新时间不是严格的采样时刻证明。

## 语义更新改善与剩余尖峰

| 可解码根语义指标 | 12:51旧样本 | 13:36有效记录 |
| --- | ---: | ---: |
| 有效记录数 | 306 | 1090 |
| p50 | 5.786ms | 3.069ms |
| p90 | 6.825ms | 5.280ms |
| p95 | 7.525ms | 5.948ms |
| 最大值 | 12.967ms | 12.864ms |
| 超过8.333ms | 14/306（4.58%） | 7/1090（0.64%） |

中位数在这两份捕获中约低47%，支持减少整墙挂载的优化方向有效。统计包含不同状态，trace只覆盖部分帧，不把百分比解释成严格同操作收益或掉帧率。筛选根语义大于1ms时，旧210项p50为6.082ms、新682项为3.565ms，下降方向仍存在；这个筛选也不是手势分类。

新样本1090个有效根全部在画面提交后开始，637个晚于raster结束。真实例 `#565`：UI0.602ms、raster3.637ms，但提交后语义11.460ms，下一次buildStart间隔16.452ms；`#791`语义10.405ms、`#2491`10.068ms。build/raster绿依然不能排除语义阶段阻塞。最大12.864ms在开头 `#4`；排除最初两帧后最大仍11.460ms。

本次2713帧、帧时间包络34.492秒；UI p50=0.968ms、raster p50=1.797ms，阶段超预算并集19/2713（0.70%），elapsed超预算62/2713（2.29%）。长无帧区间、起始帧及混合动作使全段不能直接算显示FPS。新列表滚动需要布局可见行，根layout p50=0.200ms、paint p50=0.261ms；这是本次覆盖片段统计，不与旧近零布局/绘制直接作等条件比较。

## CPU确认的剩余工作

[CPU复核](cpu_focus.json)中，`flushSemantics`的inclusive样本占35.47%、flushLayout12.76%、flushPaint10.84%。这些祖先份额相互嵌套，不能相加；也不能把35.47%当语义占实际录制时间的比例。

最重单个self函数 `_reportTaskEvent` 占15.81%，是Timeline追踪事件写入。语义祖先的5008样本中，1238样本的叶函数为该写入函数；可匹配有效语义区间的1785样本中，327样本为该写入函数。因此采样/追踪自身开销明显，不能把整个语义热点都归给产品逻辑，也不能直接减去这些百分比估算无追踪性能。出现353次RenderParagraph.getDryLayout及712个原始BUILD记录，但这些可来自框架默认instrumentation，不能证明用户开启了额外追踪选项。

`#326`的UI **52.518ms** 是本次最慢UI帧。其UI时间窗内有63个CPU样本，38个调用链包含 `_IllustSearchTagListState._planRows` 及文字测量，证明同步行规划是尖峰贡献之一；不能说全部52.518ms都耗在该函数。全CPU只有54个行规划样本，集中在 `#266`（1）、`#326`（38）、`#2243`（15），支持它发生在少数重规划帧，而非每帧持续重测。没有手势标记，不能仅凭帧号确定是首次展开、全部切换还是再次打开。

下一轮应优先检查这些状态切换的文字尺寸/行规划缓存复用，以及剩余语义更新范围；保持标准标签和无障碍能力。常规对比与精细诊断分开录制，相同设备/状态/手势/刷新率和字体环境下复验，避免把录制开销当稳定产品成本。初始166.819ms elapsed帧发生在CPU开始前，不能由这份CPU归因。

## 缺失trace处理与可复算证据

原解析得到 `#796` 6997.383ms、`#1829` 5270.420ms根语义；UI trace存在缺失区间，其间Flutter帧仍连续产生，未闭合事件跨空洞错配。同步UI语义阶段不可能跨越同线程大量后续帧。两根及对应owner记录标为invalid并排除，未裁剪生成新时长。原始UI packet timestamp没有回退，问题是事件缺失。首个帧起点前的1个layout和8个BUILD不归到当前帧。

[validated_trace_summary.json](validated_trace_summary.json)是本轮语义统计依据；[performance_summary.json](performance_summary.json)保留原解析结果供检查，其中跨洞极值不能直接使用。[cpu_trace_match.json](cpu_trace_match.json)独立将CPU样本匹配到可靠根区间，1785个样本中1780个含flushSemantics祖先，支持时钟对齐。缺失trace片段的CPU样本未被算作闲置或无语义工作。

在仓库根目录复算（Python标准库）：

```powershell
python docs/verification/illust-tags-004-recheck/validate_trace.py
python docs/verification/illust-tags-004-recheck/analyze_cpu_focus.py
```

脚本依赖未改动的003/004分析器；第三方可用 `--perf`、`--cpu`、`--out` 指向自己的文件。样本、设备APK副本和大JSON按现有.gitignore留本地，README与[artifact.json](artifact.json)可跟踪。未运行构建、安装、卸载、清数据、重启或手机UI操作；没有增加可冒充此次真机结果的widget测试。
