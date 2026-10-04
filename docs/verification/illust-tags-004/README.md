# 第十九轮 004 · 标签区按行懒加载验证记录

2026-10-04，承接用户“标签区内部滑动仍卡”的反馈，在 `main` / `83a47ff161758adc15b1f756b072b6beb92ca8b6` 的未提交工作区执行。[004计划](../../../Z-plan/新需求-主线-第十九轮/004-修复-003标签滚动语义耗时.md)保持正文不变。本轮源码调整、专项/全量测试、静态分析与profile构建已完成。新包未安装，尚无004真机复录；目前确认屏外标签挂载减少，不能宣称FPS或毫秒收益。

## 为什么build/raster绿仍会卡

用户新导出含725帧，Flutter3.41.6 / Android / profile / 120Hz。除首帧外，UI/raster均未超8.333ms阶段预算；完整帧UI p50为0.501ms、raster为1.952ms。但SDK在 `compositeFrame` 提交画面后继续执行 `flushSemantics`，这部分UI线程工作没有计入提交前的 `FrameTiming.build`，仍会推迟下一帧回调。

解析出的306个 `SEMANTICS (root)` 对应后段 `#3303–#3608`：最近秩p50 **5.786ms**、p90 **6.825ms**、最大 **12.967ms**，14次超过阶段预算；这14次之后的buildStart间隔p50为16.409ms。全部306次语义更新在提交后开始，209次结束晚于raster完成。同期根绘制p50只有0.018ms，支持003绘制复用已经生效、剩余耗时集中在提交后语义阶段的判断。

该306次仅是可解码的UI阶段覆盖范围，不能代表整段手势。根/子PipelineOwner的语义阶段嵌套，不能相加；612次子阶段调用也不是612个节点。约1049.762ms根语义时间不在命名子阶段内，SDK随后进行排序、序列化与平台更新，但没有CPU样本，不能把余量全归给某个函数。首帧 `#2884` 的UI **84.197ms**没有匹配UI trace，不在本轮可归因范围内。

## 改动与适用范围

[IllustSearchTagList](../../../lib/pages/illust_search_tag_list.dart)先缓存文字和标准chip稳态尺寸，按实际可用宽度规划自然换行，再懒加载可见行。标签、count、选中集合、宽度、主题、字号、locale和方向等变化使缓存失效；滚动的extent回调只读取规划高度。每行仍使用标准 `FilterChip`，保留6dp横间距、2dp行距、288dp上限及30dp底部留白，前12/全部、已选置顶与面板操作保持原流程。

计划提到 `ListView.builder`；实现选用 `ListView.custom`，因为builder把 `semanticChildCount` 限制为行数，而一行含多个标签。custom委托可关闭重复的行级自动索引，由每个 `IndexedSemantics` 提供绝对标签索引，总数按实际标签数报告。

几何规划纳入label/checkmark、ChipTheme padding、ShapeDecoration边框内边距、visualDensity与tap target。选中动画仍由真实chip执行，行槽保留终态宽度以避免动画期间溢出；不声称逐帧行位移与旧Wrap完全相同。焦点/悬停/按压会改变边框尺寸的自定义主题，回退到原滚动Wrap，保留自然布局，此分支仍全量挂载。

普通屏外行回收；保留委托默认自动保活，让chip请求保留主动键盘焦点或墨水反馈，可能暂留少量屏外行，焦点转移后可释放。尚未挂载的行无法直接用Tab遍历，需要先滚动；可见chip的focus/tap、列表读屏滚动及末段索引保留。首次仍需规划全部标签，SDK也会累加此前行extent，不能把实现描述为所有工作都与可见行数成正比。

## 验证证据与当前门槛

| Evidence | Finding | Path |
| --- | --- | --- |
| [sample_summary.json](sample_summary.json)、[analyze_scroll.py](analyze_scroll.py) | 提交后语义耗时确实存在，且早期FrameTiming与后段trace覆盖不同 | 原始导出→匹配时间窗→根阶段与下一帧间隔 |
| [geometry-tests.txt](geometry-tests.txt) | 12项通过：M3/M2、深色、RTL大字、bold、长标签、自定义padding/字体/边框、compact及checkmark等稳态尺寸与旧Wrap一致；宽度/字号变化、列表缩短/清空有效 | 真实旧Wrap↔新组件坐标/尺寸比较 |
| [panel-tests.txt](panel-tests.txt)、[性能回归测试](../../../test/illust_search_panel_performance_test.dart) | 10项通过，覆盖140项滚动到末项、选择/取消/重开、普通屏外回收、语义总数/绝对索引、主动焦点保活 | 行规划→有限挂载→标准标签/滚动语义 |

| 门槛 | 最终状态 | 证据位置 |
| --- | --- | --- |
| 最终专项测试 | 五文件组合 **48通过 / 0失败**，11秒；其中geometry12项、panel性能10项 | [tag-tests.txt](tag-tests.txt) |
| 全量 `flutter test` | **2387通过 / 14跳过 / 0失败**，96秒 | [all-tests.txt](all-tests.txt) |
| `flutter analyze` | **No issues found**，15.0秒 | [analyze.txt](analyze.txt) |
| `flutter build apk --profile --target-platform android-arm64` | **成功**，Gradle assembleProfile 101.3秒 | [build-profile.txt](build-profile.txt)、[apk-metadata.json](apk-metadata.json) |
| 004真机after复录 | 尚未执行 | 同设备同操作的新Performance/CPU导出与比较结果 |

这些组件和语义数量验证能证明全量挂载被削减，不能代替真机语义耗时或流畅度的after测量。焦点保活测试使用 `skipOffstage:false` 检查实际仍在树中的屏外节点：默认finder跳过它们，不能据默认查找结果认定焦点节点已释放。

## 样本与运行代码身份

原始文件为 `C:/Users/tanad/Downloads/标签滚动dart_devtools_2026-10-04_12_51_58.237.json`，10406110字节，SHA256：`573567591B4C11DD0909A227583C36153C57BFA406D82897214F2BDC9E75C511`。未改原导出或历史003证据。

进入004前已核对main的774个构建输入与003源码清单一致；设备安装包与12:47本地arm64 profile包相同，71945266字节，整包SHA256：`7E32E368A373EE10463057E20094FD5649DC7B5BE22AF9EFAE178BDC08ECE2F3`。其arm64 `libapp.so` 与003保留APK一致，因此新样本运行的是003优化后的Dart代码，而非未包含改动的旧包。该设备核查见[004计划诊断记录](../../../Z-plan/新需求-主线-第十九轮/004-修复-003标签滚动语义耗时.md)。

003保留的多架构APK身份见[apk-metadata.json](../illust-tags-003/apk-metadata.json)和[source-manifest.json](../illust-tags-003/source-manifest.json)：包名 `lingxue.picakeep`，版本1.9.89 / code6，APK SHA256 `1EA5B66B19A10E7726BA184C7D3BCC76475D662154EF329467B472440EDFA53B`。这是003保留产物指纹，不等同于arm64安装包整包指纹；旧metadata的 `installed:false` 描述当时构建状态。

004独立产物为 `build/verification/illust-tags-004/app-after004-profile.apk`，71945266字节，SHA256：`2C9F9A15EDA87B1C3F593273D53D7B3550211B14BD9C358C3CCCBD2C98A2BAB4`，未安装。构建使用 `--target-platform android-arm64`，已确认Dart AOT仅有 `arm64-v8a/libapp.so`，SHA256 `7052C54FDEE8E6E76774CAE792D0967D0AF523E0C5999E6142D5ED20847073DE`，与003不同；插件native库可含其他ABI，不将该命令解读为整包所有native库仅含arm64。包名与版本同上，详情见本轮[apk-metadata.json](apk-metadata.json)；[source-manifest.json](source-manifest.json)中775个采集输入在构建前后哈希一致。

分析器再次复算出的 [sample_summary_recomputed.json](sample_summary_recomputed.json) 与 [sample_summary.json](sample_summary.json) 文件哈希完全一致，支持本轮统计可复现；这份导出仍是003运行代码的反馈样本，不是004新包的after性能结果。

## 如何复算和复录

在仓库根目录运行标准库脚本即可复算本机导出，其他机器使用 `--perf` 和 `--out` 指向各自文件；解析器支持当前导出的绝对时钟、直接命名begin/end事件，并报告缺失/不支持记录。

```powershell
python docs/verification/illust-tags-004/analyze_scroll.py
python docs/verification/illust-tags-004/analyze_scroll.py --perf sample.json --out summary.json
```

复验004时先核对profile APK、安装包及 `libapp.so` 身份，并保持同设备、120Hz、文字缩放、主题与无障碍环境。分别录制“只展开不滚动”“前12标签内部滚动”“全部标签内部滚动”；全标签操作保持相近速度和距离，正常对比时关闭额外widget build/layout/paint追踪。CPU和Performance同步起止，并保留原始文件与SHA256。

对照记录应检查：挂载/语义节点数量、实际trace覆盖、提交后语义分布、下一帧间隔及UI/raster各阶段。可单独定位首帧尖峰，但不要将无手势标记的索引切片称为连续滚动，也不要将全段平均帧数当FPS。安装按项目规则使用已验证的debug/profile APK和显式设备ID，保留用户数据，不卸载或清数据。
