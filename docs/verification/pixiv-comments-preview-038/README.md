# 038 · Pixiv 在线评论四条预览验证

实际执行了 Flutter 离线 widget 测试与 `RenderRepaintBoundary.toImage` 截图，没有请求真实 Pixiv、构建或安装应用。夹具使用生产 `PixivOnlineDetailView` 与 `PixivDetailPager`，通过 main 提供的评论/作者/推荐 loader 注入离线数据，HTTP 创建器直接拒绝真实连接；详情/Pager 验证记录 `httpClientsCreated: 0`。

## 实现范围

本子任务的唯一生产修改是 [评论组件](../../../lib/pages/online_comic/pixiv_comments_section.dart)，新增 [预览测试](../../../test/pixiv_comments_preview_test.dart)。既有 [评论回归测试](../../../test/pixiv_comments_section_test.dart)未修改。在线入口的 `previewLimit: 4` 由 main 接入；没有改计划文件、网络/source、详情 shell 或整页 controller。

`previewLimit` 默认 null，保留本地 `autoLoad: false` 手动加载、limit20 与原分页语义。四条模式首批 limit4；只排入前四个有效根评论，超量回包保留缓存。展开有隐藏缓存时先直接显示缓存；否则最多追加一批 limit20，后续需点击“加载更多评论”。分页 offset 始终累计 `originalCount`，保留 ID 去重、rawCount0 停止与 generation 丢弃旧请求。收起保留根评论、回复、offset 和分页缓存，并隐藏已展开回复；在途响应可补缓存但不会重新展开。自动加载同时要求评论接近视口、EntryScope 活跃与 TickerMode 开启。

评论标题通过该 sliver 内的常驻 GlobalKey 锚定。收起使用 `Scrollable.ensureVisible(...keepVisibleAtStart)`；没有整页 `jumpTo(0)` 或 controller 替换。真实长正文完整显示，表情仍为 64dp；有限预算只应用于占位。

## 执行结果

```powershell
$taskTemp = 'D:\Flutter_Projucts\PicaComic\PicaKeep\.dart_tool\038-temp'
$env:TEMP = $taskTemp
$env:TMP = $taskTemp
flutter test --no-pub test/pixiv_comments_section_test.dart test/pixiv_comments_preview_test.dart
dart analyze lib/pages/online_comic/pixiv_comments_section.dart test/pixiv_comments_section_test.dart test/pixiv_comments_preview_test.dart
```

- 定向 tests：**27/27 通过**（既有 5、新增组件边界 20、实际详情/Pager 2）。
- 定向 analyze：**No issues found**。
- 0/1/4/5/20 根评论、超量返回、重复和无效行、raw offset、rawCount0、单次展开、忙时重复触发、请求中收起、回复专属/多页/错误/缓存隐藏、初次/追加重试、本地手动触发、未活跃与视口外不请求、四槽/字号/窄宽、切作品的旧根评论及回复等均由上述用例覆盖。
- 正常/大字详情均验证相邻页部分露出时 `isActive: false`、TickerMode 关闭、无评论请求；完整切换到相邻页及返回后都显示四条且全部请求 limit4。

## 实际截图与布局数据

截图为 375×1000，分别使用 textScale 1.0 和 2.0，加载真实字体 `C:/Windows/Fonts/msyh.ttc`，MaterialIcons 来自 `build/unit_test_assets/fonts/MaterialIcons-Regular.otf`。截图没有采用 Ahem。

| 场景 | PNG | 记录 |
| --- | --- | --- |
| 普通字号等待响应：4 槽 | [加载占位](375-normal-loading.png) | [几何](375-normal-loading.json) |
| 普通字号加载完成：4 根评论 | [预览](375-normal-collapsed.png) | [几何](375-normal-collapsed.json) |
| 普通字号展开后收起 | [收起](375-normal-recollapsed.png) | [几何](375-normal-recollapsed.json) |
| 2 倍字号等待响应：4 槽 | [大字占位](375-large-text-loading.png) | [几何](375-large-text-loading.json) |
| 2 倍字号加载完成：4 根评论 | [大字预览](375-large-text-collapsed.png) | [几何](375-large-text-collapsed.json) |
| 2 倍字号展开后收起 | [大字收起](375-large-text-recollapsed.png) | [几何](375-large-text-recollapsed.json) |
| 完整 Pager 切换及返回 | — | [普通字号](375-normal-pager.json)、[大字](375-large-text-pager.json) |

普通字号每槽 164dp，四槽共 656dp；2 倍字号每槽 220dp，四槽共 880dp。预算依据有限昵称/短正文/日期行与 64dp 表情槽计算，字号和可用宽度会改变测量高度。加载完成移除占位，不足四条不保留空槽。普通字号截图可同时看到四条预览与相关推荐；大字收起截图末端可见相关推荐标题。

加载完成、展开、收起期间保持同一个 `ScrollPosition`。收起后普通字号 pixels=241.5、评论头 top=318（短夹具受最大滚动范围约束但仍可读）；大字号详见对应几何记录。两者均没有回到整页 offset0。

**现有 Pager 生命周期限制**：完整换页时生产 Pager 会销毁离开的详情 state；再次返回会创建新的 `ScrollPosition` 并再发 offset0/limit4 请求。两份 Pager 记录明确保留 `samePositionAfterFullVisit: false` 和实际请求列表。部分预加载返回以及当前页加载/展开/收起保持原 state；本子任务没有越权修改 Pager 或 shell 来改变整页生命周期。

PNG 和普通 JSON 按工作区现有忽略规则保留为本地验证证据；本 README 可直接纳入版本控制。所有本子任务运行的后台 job 均已收齐。
