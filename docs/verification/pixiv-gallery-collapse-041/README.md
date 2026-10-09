# 041 · Pixiv 多页图库收起验证

本子任务修改了生产 [详情 shell](../../../lib/pages/online_comic/pixiv_detail_shell.dart) 并新增 [图库测试](../../../test/pixiv_detail_gallery_collapse_test.dart)。在线入口、推荐控制器、source/网络及计划回写由 main 负责，未由本子任务修改。038 评论验证已独立完成，见 [038 验证](../pixiv-comments-preview-038/README.md)。

## 行为与兼容 API

- `galleryCollapsible: false` 是默认值，单图/本地入口继续使用原图库及原详情头。在线多页由 main 显式配置 true。
- `authorAvatarUrl: ''` 默认空，开启收起时提供 32dp 作者头像和相邻的 48dp 箭头按钮，带“收起图库/展开图库”提示及 expanded 语义。非空头像沿现有 onlineCoverProvider 缓存路径使用 Pixiv Referer/UA。
- `onGalleryExpansionChanged` 初始不发同步通知；仅用户切换时通知，作品身份重置的通知在 post-frame 发出并校验 epoch/mounted。图库初始展开。
- 展开保留全部页的自然比例纵向排列、当前页计数、阅读及原下载/收藏命令；收起换为首图等比 contain 封面，有限高度为 `min(240, max(144, viewportHeight * .24))`。收起图点击仅展开，不开启阅读；再次展开定位首图，首图的正常点击继续阅读。
- 同一 ScrollController 贯穿加载、收起、再展开。收起读取该详情头的局部 GlobalKey，在下一帧补偿删除图库造成的位置差，必要时 ensureVisible 该头部；没有新增整页 controller，也没有任意滚动回顶规则。
- 原展开图片与详情都在一条 sliver 滚动链中，末页之后自然接到作者/详情。没有增加 scroll-end 自动 snap；两页长图测试证明 idle 后不会纠正正常滚动位置。
- 同一作品的图片刷新保留收起状态；首图 key 身份变化恢复展开。相邻 EntryScope 的图库状态各自独立。

## 执行与证据范围

```powershell
$taskTemp = 'D:\Flutter_Projucts\PicaComic\PicaKeep\.dart_tool\038-temp'
$env:TEMP = $taskTemp
$env:TMP = $taskTemp
flutter test --no-pub test/pixiv_detail_shell_test.dart test/pixiv_detail_gallery_collapse_test.dart
dart analyze lib/pages/online_comic/pixiv_detail_shell.dart test/pixiv_detail_gallery_collapse_test.dart
```

组合定向测试 **37/37 通过**（原 shell 24，新图库 13）；定向 analyze **No issues found**。最后图像预解码与第三页截图对齐只重跑两个截图用例，均通过；未重跑全库或已完成的038评论套件。

新用例覆盖自然比例、初始展开、48dp 控件、折叠锚点/同一 position/同一评论 state、封面不阅读、再展开读取对应图、同作品刷新及换作品、默认禁用、两页长图没有 idle snap、375 大字、240 宽大字暗色、812×375 横屏/减少动画、空图/加载/失败，以及下载点击/长按、忙碌收藏等。夹具通过注入评论和推荐回调验证收起/单纯再展开不读取推荐，只有完整滚到推荐位置才读取。生产 OnlineDetailView 的推荐缓存和显示联动属于 main 集成验证范围。

所有新图库用例用 deny-all HTTP override，断言未创建 HTTP client。没有真实 Pixiv 网络请求、应用构建或安装；插画为离线 Canvas 绘制的 MemoryImage。截图使用真实生产 shell、评论 sliver、字体和 Flutter RenderRepaintBoundary；没有使用 Ahem 作为截图字体，也不是手工拼接的产品页面。

## 实际截图

375×1000，textScale 1.0/2.0；字体为 `C:/Windows/Fonts/msyh.ttc`，MaterialIcons 为 `build/unit_test_assets/fonts/MaterialIcons-Regular.otf`。截图先 precache 与生产一致的 ResizeImage，等待实际解码后拍帧。

| 状态 | 普通字号 | 2 倍字号 |
| --- | --- | --- |
| 第三页与详情交界 | [末页](375-normal-last-page.png)、[数据](375-normal-last-page.json) | [大字末页](375-large-text-last-page.png)、[数据](375-large-text-last-page.json) |
| 收起封面、作者与评论 | [收起](375-normal-collapsed-comments.png)、[数据](375-normal-collapsed-comments.json) | [大字收起](375-large-text-collapsed-comments.png)、[数据](375-large-text-collapsed-comments.json) |
| 收起后滚动到四条评论 | [四条评论](375-normal-four-comments.png)、[数据](375-normal-four-comments.json) | [大字四条](375-large-text-four-comments.png)、[数据](375-large-text-four-comments.json) |
| 点封面再次展开 | [再次展开](375-normal-expanded-again.png)、[数据](375-normal-expanded-again.json) | [大字再次展开](375-large-text-expanded-again.png)、[数据](375-large-text-expanded-again.json) |

收起封面高度 240dp。大字四条评论图记录 pixels=576、第四条底部=912，仍能继续在同一详情里查看完整评论，无推荐区或推荐请求。全部截图状态 `sameScrollPosition: true`，展开状态变化为 `[false, true]`。

**短内容的自然 clamp**：1000dp 视口的短夹具收起后无法保持原250dp标题 top，封面/标题自然位于240dp；可用滚动范围会把 offset 限制到0。此为删除图库后 Flutter 的有效范围约束，不是 controller 重置或自动回顶循环。850dp 可滚动锚点用例在收起前后标题 top=200 保持一致，且保留同一个 position 与评论 state。显式再次展开定位首图到视口属于用户动作。

当前证据为 shell 集中夹具，在线入口传参和相关推荐缓存隐藏由 main 的真实详情集成套件验证。PNG/普通JSON按工作区既有规则被忽略；README 可纳入版本控制。所有本子任务后台 job 均收齐。
