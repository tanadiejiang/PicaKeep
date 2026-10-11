# 050 · Pixiv加载、封面预显与翻页恢复

状态：源码与离线验收完成，真实设备／CDN待验（2026-10-10 00:29 +08:00）。最终36套、531项测试通过，28个文件静态分析 No issues found，diff检查退出码0。未构建／安装应用，未访问真实登录账号、升级依赖或清理真实应用数据。所有本轮PNG／JSON都是离线Flutter证据，不是真机截图或真实Pixiv响应。

## 完成的生产改动

1. [详情壳层](../../../lib/pages/online_comic/pixiv_detail_shell.dart)新增在线opt-in首帧门控。作者／下载条保留布局但在可用封面／高清首帧之前关闭绘制、命中与语义；明确图片错误可恢复，不永久隐藏。049固定爱心坐标和048面板／主滚动交接未重写。
2. [在线详情](../../../lib/pages/online_comic/pixiv_online_detail_view.dart)接入首图封面预显、账号／作品／owner守卫和加载epoch；元数据等待时只有封面、返回和加载反馈，没有虚构收藏／下载权威信息。高清首帧才替换，失败保留封面和至少48dp的显式重试。单图使用48dp头像槽（32dp圆形），已知头像不额外读profile，缺头像只读一次；资料补读不附带feed或评论。
3. [列表入口](../../../lib/pages/online_common/online_comic_list_item.dart)、[推荐卡](../../../lib/pages/online_common/online_recommendation_card.dart)、[瀑布流卡](../../../lib/pages/online_common/online_waterfall_card.dart)登记实际解码首帧的精确provider，普通列表通过[通用tile可选回调](../../../lib/components/comic_tile.dart)登记，非Pixiv默认关闭。seed经过[源构造器](../../../lib/comic_source/built_in/pixiv.dart)、[作品页](../../../lib/pages/online_comic/pixiv_comic_page_v2.dart)与[会话Scope](../../../lib/foundation/pixiv_detail_session.dart)传递；暖封面不重新包全屏ResizeImage，避免丢缓存键。
4. [预显模块](../../../lib/foundation/pixiv_detail_preview.dart)登记上限128；相邻封面队列只有current→next→previous、最多2并发、最多3候选。快翻立即清旧pending，失败不会自动循环；覆盖／关闭释放预取自身ImageStream监听及8秒Timer。取消不等于中断共享HTTP传输。
5. [规格helper](../../../lib/network/pixiv_network/pixiv_parsing.dart)为Pixiv瀑布流按实际宽度×DPR（1..3）×1.35及竖图长边预算选择540／720／1200框、quality80；失败顺序高规格→原360→原API URL，去重最多3次。仅已知Pixiv `/c/` 路径一起修改目录／后缀，未知host/path不猜，query和fragment保留。旧360 helper和compact推荐方槽不变。

## 用户追加问题

### 两张横图后只有作者条，正文全空

多图正文原先必须等一次用户向下滚动到图集尾部才挂载；两张横图整组加作者条和既有88dp尾部都短于视口时，页面不能滚动，因而没有触发机会。现在在线启用短图集条件：metadata/pages已定、首屏像素或明确错误就绪、整组确实短于视口、当前活跃路由，下一帧直接挂载原正文树。主Position保持0，作者条自然位置不移动；长图集、加载中、inactive和直接Shell默认行为保持原契约。

见[短多图PNG](short-multipage-body-visible.png)／[JSON](short-multipage-body-visible.json)：400×800视口，两张400×200合成图片，作者条top=400，正文可见；无需任何拖动。这不是用户作品的图片素材。

### 已加载作品翻回仍重读

之前current±1仅是itemBuilder挂载条件，**不代表Flutter会保留这些State**；PageView没有真正保活，相邻页也可能销毁。[Pager](../../../lib/pages/online_comic/pixiv_detail_pager.dart)现用AutomaticKeepAliveClientMixin和独立索引notifier保留当前±1已访问页，远页释放，只有current启用activity／TickerMode。新session清旧bucket并按initialKey建立新controller，原entry子树key保留。

远页仍会释放组件树，但[会话](../../../lib/foundation/pixiv_detail_session.dart)最多保留64份轻量成功响应（detail／pages分别算一份），按account＋work＋kind隔离，合并in-flight。翻回不再无条件重读详情和页URL，手动刷新与明确重试失效相应条目，失败不缓存；关闭路由释放。它不是永久离线数据库，也不保留无限份高清像素或全部作者／评论feed状态。图片仍受Flutter/ImageManager缓存预算管理，缓存淘汰后可能再次解码／下载。

[实际Pager恢复测试](../../../test/pixiv_detail_revisit_050_test.dart)验证0→1→0仍为同State、同ScrollPosition、312px及已有memo；多页遍历live≤3，远页释放，换会话同ID不混用。另有[真实View响应复用](../../../test/pixiv_detail_entry_preview_050_test.dart)和[缓存隔离／上限／重试](../../../test/pixiv_detail_response_cache_050_test.dart)覆盖。

### 作品150343763作者／详情空白与评论“不正确的请求。”

用户[作品链接](https://www.pixiv.net/artworks/150343763)和截图为问题来源。公开接口读取被工具网络边界拒绝，**没有获取该作品真实JSON，不能证明它的title/name/avatar字段或limit4就是实际原因**。截图中已有“加关注”和作品卡片，说明至少部分资料／作品读取成功，但不说明name/avatar一定非空。

已补可证明的健壮性问题：

- [View](../../../lib/pages/online_comic/pixiv_online_detail_view.dart)原来始终只显示detail.author，profile成功也不回填名称；现在优先非空profile.name，退回详情名，再退回明确作者ID标识。空标题显示作品ID，不从另一个作品借用资料，不伪造头像图片。
- [解析](../../../lib/network/pixiv_network/pixiv_parsing.dart)兼容数字类型作者UID。[网络](../../../lib/network/pixiv_network/pixiv_network.dart)保留缺冗余UID但有有效名称的requested身份，明确不同UID／作品ID拒绝，跨账号晚结果不落回当前账号。
- 小页评论成功保持原请求；仅明确invalid-request业务拒绝／已解析HTTP400业务失败，同work、同offset最多一次回退已验证的标准limit20。认证、403、404、429、一般业务错误、解析／传输失败不扩大页数重试。UI仍只展示4条；若回退成功，offset按原始20条推进、展开显示缓存。二次失败原文保留，不当作“无评论”。既有底层同URL解析重试未扩大。

[作者／评论离线Adapter测试](../../../test/pixiv_reported_author_050_test.dart)使用该请求ID但响应完全是合成fixture，绝不冒充作品实际平台响应。该作品仍需在更新后的debug/profile版本、真实设备与用户账号环境复测。

## 证据入口

| 场景 | PNG | JSON |
| --- | --- | --- |
| 首帧前作者／下载不可见 | [加载中](loading-header-hidden.png) | [状态](loading-header-hidden.json) |
| 高清首帧后作者栏出现，几何不变 | [首帧](first-frame-header-visible.png) | [状态](first-frame-header-visible.json) |
| 精确暖封面16×16先显示 | [预显](preview-before-high.png) | [像素](preview-before-high.json) |
| 高清32×32首帧才替换 | [高清](high-first-frame.png) | [像素](high-first-frame.json) |
| 单图240宽／字号2／安全区24 | [窄屏](single-240-light.png) | [几何](single-240-light.json) |
| 单图375深色 | [深色](single-375-dark.png) | [几何](single-375-dark.json) |
| 单图812横屏／reduced motion | [横屏](single-812-light.png) | [几何](single-812-light.json) |
| 短多图无需滚动即可出现正文 | [正文](short-multipage-body-visible.png) | [状态](short-multipage-body-visible.json) |

预显与高清截图同时断言真实渲染中心像素，分别为RGBA `[63,81,181,255]`（indigo）与`[103,58,183,255]`（deepPurple），不只是检查URL或Widget参数。单图截图部分为缺图terminal／头像占位，真实缓存头像首帧另有View测试断言，不能将占位图冒充真实作者头像。

048／049回归图存本轮独立子目录：[motion](049-regression/motion/)、[handoff](049-regression/handoff/)、[follow](049-regression/follow/)、[gallery](049-regression/gallery/)。评论最终回归另存[comments-regression](comments-regression/)。本轮没有覆盖048／049旧归档，也没有回退既有dirty源码。

## 最终回归与过程记录

- [合并最终日志](regressions-final.log)：36套、531项全部通过，退出码0，涵盖049原17套284项、新050七套、URL／metadata／source注册／瀑布流／作者／探索入口。
- [最终静态分析](analyze-final.log)：28个文件 No issues found，退出码0。
- [最终diff检查](diff-check-final.log)：退出码0，仅Git现有LF→CRLF转换提示，无空白错误。
- [首轮合并](regressions-first.log)：509通过、2失败；保活包装改变entry subtree key导致旧评论集成finder找不到页面。**修生产包装保留原key，而非删掉旧断言**；[定向回归](reported-author-key-compat.log)60项通过，最终合并也通过。
- [初次静态分析](analyze-first.log)：12条info，虽dart analyze退出0并不代表干净；全部修正并以flutter analyze完成最终无问题检查。
- [短图集首次](revisit-short-first.log)记录并行网络小批尚未写完导致的编译失败（_canRetryCommentPreview当时未落）；[补完整后](revisit-short-second.log)25项通过。
- [规格／预取初次](prefetch-quality-first.log)30项通过。

## 复现

从仓库根目录执行[验证脚本](verify.ps1)，使用现有Flutter3.38.5 SDK，全部只有离线测试、格式化、静态分析和diff检查：

```powershell
& 'docs/verification/pixiv-ui-050/verify.ps1'
```

真实CDN返回像素尺寸、设备解码内存／网络字节、全链路请求上限、触控手感与150343763实际接口结果均未验。新增队列预算不是对既有current±1详情加载的全局零网络保证；新增登记隔离不是对通用URL-only图片缓存的全局账号隔离保证。依[050计划](../../../Z-plan/新需求-主线-第十九轮/050-修复-Pixiv加载作者条与单图头像及封面渐进预显.md)，计划标部分完成，不以离线通过冒充真机／CDN全部完成。
