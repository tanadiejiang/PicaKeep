# 55 号：滚动补图与信息跳变

用户试用 54 后确认封面加载快、滚动卡顿明显缓解；本轮处理“停滚才出图”和 p2 晚到推开下方卡片。源码直接修改于主仓库 main；54 的尚待真机量化项仍保留。

## 原因与改动

| 证据 | 结论 | 实现位置 |
| --- | --- | --- |
| 旧队列 `_canRun` 同时检查 scrolling 与 140ms idle，启动/继续/publish 共用它 | 连已经准备好的封面也等停滚；开始滑动还可能取消进行中的读取 | `illust_work_queue.dart` 分开运行存活、封面准入和元数据空闲条件 |
| 页数未知时片段为空，`buildIllustCardInfoSpans` 丢弃空项和分隔符 | null→p2 新增一行，卡片高度增加 | `local_library_illust_card.dart` 信息布局预留，页面传实际模板 |
| 下载记录 JSON 没有 pageCount，目录/ZIP 需异步统计 | 不能假称“取已有数据库页数”或用文件名 pN 猜 | 单图片产物由扩展名提前确认为 1，其余继续原统计链 |
| Flutter `Image` 内部包 `ScrollAwareImageProvider` | 高速甩动时 uncached 解码仍可能延后；区别于应用层所有滚动都停 | 保留框架保护和现有滚动物理；不全局强制预解码 |

滚动及停滚后的 140ms 过渡窗口内，新 cover 启动间隔为 120ms、最多一条 cover 在途；空闲恢复原总并发 2。若开始滚动前已有两项运行，允许它们完成，不强行取消重算，也不追加超限工作。图片结果可在滚动期发布；元数据结果先缓存，空闲才发布，避免比例变化打断手势。后台/遮挡与离屏继续受 liveness 约束，reset/retry/dispose 拒绝过期结果。

页数/尺寸预留只面向用户已开启的异步字段，排版跟随模板顺序、分隔符、文字样式和字号缩放；测量用占位不进入可见文字和语义。初始未知后来确认单图的卡片在同一生命周期内保留高度，避免反向收缩；重新构造时已知单图不需页数行。没有勾选动态字段的默认标题/作者模板不新增空位。

## 本机验证与复跑

```powershell
dart analyze lib test
flutter test --no-pub --reporter expanded
flutter build apk --profile --no-pub --dart-define=PIKAKEEP_COVER_DIAGNOSTICS=true
```

本机结果：全量 **2224 通过、14 跳过、0 失败**（`full-tests.txt`）；队列/视图/锚点 **70 通过**（`queue-view-tests.txt`）；卡片/信息配置 **64 通过**（`card-tests.txt`）；静态分析 **No issues found**（`analyze.txt`）。最终产物身份在 `artifact.json`；不以相同版本名替代 APK SHA。

profile 构建成功并通过 `apksigner verify`。独立包为 `build/verification/illust-scroll-55/app-after55-profile.apk`，`lingxue.picakeep` / `1.9.88+5`，132,933,859 字节；SHA-256 `1E30F8301414444328820A1B83825A764B10830375D50C7F2183144ED6285AD6`。54 的留存包未覆盖。`source-manifest.json` 保存当前未提交的 54+55 源码身份；本轮未改其他会话先前新增的 analysis_options 排除配置。

2026-10-03 18:05 ADB 显示设备已在线，本轮只查询连接状态，未安装或操作手机；计划标记部分完成，等待新包体验和性能复验。

## 真机复验

使用最终 profile 包，在原库慢拖且保持手指不抬起，观察新进入屏幕的封面陆续出现；停滚时页数补齐不应再将下一张卡片推开。分别复测两列/三列、大字体、页数在首/中/尾、换行/横杠模板，单图片、老目录和 ZIP；长按多选、图片阅读、文字详情仍需可用。

高速甩动快速略过的未缓存图片仍可能被 Flutter 延后解码，这不是队列等待停滚的旧逻辑。保留该保护是为避免一次性解码大量不会停留在视口的图片。120ms 是保守的限速初值，尚无本轮真机帧数据证明最优；若需继续调整，应同设备复测，不能根据视觉截图编造帧指标。

安装须用户另有明确授权并核对显式设备 ID、APK 路径、包名与签名；仅 debug/profile。禁止卸载或清数据。封面缓存仍位于应用内，本轮无用户文件迁移、数据库协议或后台下载服务改动。
