# Pixiv 插画详情页改版：013 计划准备的核验记录

本轮只核验 011 调研、原始响应及现有代码，供后续 013 执行计划使用。用户要求先写计划、稍后再执行；本轮没有修改应用代码、测试、原调研或预览，没有运行 Flutter 测试／构建，也没有使用真实账号写收藏、关注、评论或下载内容。

本目录新增公开游客 GET 的 JSON 和请求摘要，以及已存在反编译文件的参数摘要；没有保存 Cookie、账号令牌或鉴权请求头。用户最新确认作为计划决策：页码表示**当前作品内的图片页／该作品图片总数**；在线悬浮爱心是 Pixiv 平台收藏，本地悬浮爱心是离线本地收藏；详情页 FAB 用白圆及轻阴影。011 中不同位置相互冲突的爱心背景／阴影描述，以这次确认为准。

## 证据与结论

| Evidence | Finding | Path |
| --- | --- | --- |
| 旧详情响应 `body.userIllusts` 有 78 个键 | 13 个完整对象、65 个 null；13 个含当前作品，去掉当前作品只有 12 张其他作品，均属作者 UID `1960050` | [原详情 JSON](D:/Flutter_Projucts/PicaComic/PicaKeep/Z-plan/新需求-主线-第十九轮/005-附件-Pixiv响应实测/illust_150378023.json:1)、[核验汇总](D:/Flutter_Projucts/PicaComic/PicaKeep/docs/verification/pixiv-detail-013/verified-inputs.json) |
| 13 个完整作品对象均有标签数组、作者 UID、真实尺寸和 `isBookmarkable:true` | 可以复用 brief 单项解析；本样本 `bookmarkData` 全 null、`isMasked` 全 false、`xRestrict` 全 0，不能证明账号态／R-18／遮罩表现；12 个有头像，当前作品对象缺头像 | [brief 解析](D:/Flutter_Projucts/PicaComic/PicaKeep/lib/network/pixiv_network/pixiv_parsing.dart:275) |
| 现有详情模型和解析器不读取 `userIllusts` | 需增加同作者其他作品字段；按完整对象解析、去重、去当前作品、跳 null／坏对象，不为 65 个 null 逐项补请求 | [详情模型](D:/Flutter_Projucts/PicaComic/PicaKeep/lib/network/pixiv_network/pixiv_models.dart:163)、[详情解析](D:/Flutter_Projucts/PicaComic/PicaKeep/lib/network/pixiv_network/pixiv_parsing.dart:182) |
| 旧评论样本只有 3 条，内容均空、贴纸为 303／202／303 | 不能只渲染非空文本；旧归档 JSON 自身只能证明成功响应结构，采集时 HTTP 状态和无 Cookie 仍属于原调研陈述 | [旧评论 JSON](D:/Flutter_Projucts/PicaComic/PicaKeep/Z-plan/新需求-主线-第十九轮/005-附件-Pixiv响应实测/comments_150378023.json:1) |
| 本轮匿名 roots 读取返回 20 条，6 文本／14 贴纸、`hasNext:true` | 已直接核实根评论公开读取；有一条 `hasReplies:true`，据此选择真实根评论核实回复 | [新 roots JSON](D:/Flutter_Projucts/PicaComic/PicaKeep/docs/verification/pixiv-detail-013/comments-roots-150378023.json:1) |
| 本轮匿名 replies 返回 1 条真实回复、`hasNext:false` | 二级回复读取可按点击接入；回复缺 `hasReplies/isDeletedUser`，`replyToUserName/stampLink` 为 null，模型需独立容错 | [新 replies JSON](D:/Flutter_Projucts/PicaComic/PicaKeep/docs/verification/pixiv-detail-013/comments-replies-235308916.json:1) |
| roots／replies 都只有 `comments/hasNext`，没有 total／cursor／offset 回显 | roots 以请求 offset 和收到的原始条数推进；replies 以 page 推进；不能拿详情 `commentCount:48` 当根评论总页数 | [请求证据摘要](D:/Flutter_Projucts/PicaComic/PicaKeep/docs/verification/pixiv-detail-013/guest-comment-read-verification.json) |
| 收藏网络方法只有 `isAdding`，新增写体固定 `restrict:0`；详情只保留 boolean 和书签 ID | 私密收藏需要新增可选可见性参数和 nullable 隐私状态；默认仍公开，既有推荐／作者页调用保持原默认值 | [收藏方法](D:/Flutter_Projucts/PicaComic/PicaKeep/lib/network/pixiv_network/pixiv_network.dart:1336)、[写体 restrict](D:/Flutter_Projucts/PicaComic/PicaKeep/lib/network/pixiv_network/pixiv_network.dart:1394)、[收藏状态解析](D:/Flutter_Projucts/PicaComic/PicaKeep/lib/network/pixiv_network/pixiv_parsing.dart:193) |
| 已读取 XML 的 peek=48dp、爱心占位=72dp、margin=16dp；`mm4.Q` 的计数分母直接为作品 `pageCount` | 支持抽屉参数及作品图片页计数，不能把进入详情的列表下标当图片页码；反编译输出有类型还原异常，只采纳可直接观察的表达式 | [独立保存的布局／计数证据](D:/Flutter_Projucts/PicaComic/PicaKeep/docs/verification/pixiv-detail-013/preserved-layout-page-counter-evidence.json) |

旧详情响应为 40,133 bytes，SHA256 `411900DB1A6D5C80AEF09F2144AB3AE3947B969477C260803F4A1B89903EAF77`。旧评论响应为 1,185 bytes，SHA256 `25BDBA882F2FFC315425D179C0F0A4413EAD6D775A114DDF3C2F245EF89A960C`。

## 本轮两次匿名评论读取

两次请求均 GET，没有 Cookie、账号 session 或 token；结果 `error:false`，Content-Type 均为 `application/json; charset=utf-8`。时间以下按 UTC+8 展示，机器摘要保留 UTC 原始时间。

| 项目 | roots | replies |
| --- | --- | --- |
| UTC+8 时间 | 2026-10-04 15:54:28.018654 | 2026-10-04 15:54:28.573288 |
| URL | `https://www.pixiv.net/ajax/illusts/comments/roots?illust_id=150378023&offset=0&limit=20&lang=zh` | `https://www.pixiv.net/ajax/illusts/comments/replies?comment_id=235308916&page=1&lang=zh` |
| HTTP | 200 | 200 |
| bytes | 7,337 | 433 |
| SHA256 | `663935F4F2BF593283A94C9ED37329A7E20502F959B357EA8CBCB08C46A9DB14` | `55A604FEFD1D9BB286D8A391AF14493D4284593B74DD64F3EA4E5E02C4EDC2F3` |
| comments／hasNext | 20／true | 1／false |

roots 根评论 `235308916` 是贴纸 304，标记 `hasReplies:true`。读取到回复 `235320186`，其 `commentRootId/commentParentId` 均为 `235308916`，`replyToUserId:6064850`、`replyToUserName:null`，内容为贴纸 304，头像是 `no_profile_s.png`。两响应均无服务器 total、cursor、offset；未请求 roots 第二页或 replies 第二页，不能据此承诺所有分页／深层回复结构一致。

roots 20 条 ID 未重复，本样本按 ID 倒序；保留服务端顺序而不强制自行排序。文本含 `(heaven)/(heart)` 这样的 Pixiv 内联表情标记，第一轮可保留原文字，不猜映射表。用户无头像时服务端返回 `no_profile.png`／`no_profile_s.png`，UI 需正常占位。服务端 `commentDate` 没有时区标识，本轮没有核实其格式化时区，不能强行套用 UTC。

## 贴纸和开源契约来源

实际实现的贴纸 URL 模板为 `https://s.pximg.net/common/images/stamp/generated-stamps/{stampId}_s.jpg`，来源为 [PixivSource 固定 commit 的 jsLib](https://github.com/DowneyRem/PixivSource/blob/3f8a5f7c7803baf520fd550b770b8415538a72f2/pixiv.json)。本轮另以不带 Cookie 的公开 HEAD 核实 `303_s.jpg` 返回 HTTP 200／image/jpeg／Content-Length 5,192；`202_s.jpg` 返回 HTTP 200／image/jpeg／Content-Length 6,689。没有下载或存储这两张远程图片。

这些 HEAD 只验证两个已知 ID 的资源存在。新 roots 另有 304／407，未逐个核实图片；只接受数字贴纸 ID、防止拼接任意 URL，资源失败降级为“表情 {ID}”，不丢弃空文本评论。

roots offset／limit、书签 `restrict:0/1` 的参考是 [daydreamer-json 固定 commit](https://github.com/daydreamer-json/pixiv-ajax-api-docs/tree/561cb0d070a580f1ebf0e24acedc7d507ed11fe8)，其 README 明确说明长期未维护、API 已发生变化，是第三方参考而非官方稳定承诺。[本地副本](D:/Flutter_Projucts/PicaComic/PicaKeep/Z-plan/新需求-主线-第十九轮/005-附件-Pixiv响应实测/pixiv_web_ajax_api_docs.md) SHA256 为 `F5AC589405DC4736AA8F2CF7B8CBD496C8F88F5616D39E522A8B909F73D37C22`。replies 参数的补充参考为 [pixiv-utils 固定 commit](https://github.com/AgMonk/pixiv-utils/blob/5104eadcbf583a7fe3f3253966aef4ff2e9ec400/README.md)；本轮实际公开读取进一步确认了指定根评论的 page=1 返回结构。

## 计划应锁定的收藏与读取边界

在线未收藏时短按新增公开 `restrict:0`、长按新增私密 `restrict:1`；已有收藏（公开／私密／未知可见性）时两种手势都取消现有书签，不进行公开↔私密转换、不重复 add 覆盖原有 Web 标签／备注。取消继续重读详情取当前书签 ID，沿用既有 rpc 删除通道。缺失 `bookmarkData.private` 时保持未知，不当成公开；未收藏不需要隐私状态。短按和长按共用忙锁，换作品／账号后旧回包不得更新当前页面，登录返回只刷新而不自动继续写入。

本地爱心完全走离线本地收藏，不根据本地项的来源自动写 Pixiv 书签。在线“相关作品”本期只使用详情响应中已完整的同作者其他作品，维持零新增作品请求；不能把此来源称为平台个性化相关推荐。

评论按需要读取根评论及回复，不一次预取所有页／所有回复；加载失败保留已显示内容并提供重试。回复接口已核实读取，但发表评论、删除评论及点赞均不在本期，隐藏不工作的发表入口。游客 GET 成功、某写接口被 GET 返回 400，都不能推出真实账号 POST 可用。

后续执行阶段再补解析／Dio adapter／状态／抽屉手势与路由回归测试，覆盖 null 作品、重复页、空页却 hasNext、未知隐私、账号或作品切换、快速双手势、离线本地收藏与在线隔离。本轮没有执行这些 Flutter 测试，也没有生成新 APK。

## 复核本目录证据

在PowerShell中运行以下命令，会检查原始响应统计、SHA、预览尺寸和资源参数，并更新本目录的verified-inputs.json；它不发网络请求、不修改应用源码，也不运行Flutter。

```powershell
& 'D:/Anaconda3/python.exe' 'D:/Flutter_Projucts/PicaComic/PicaKeep/docs/verification/pixiv-detail-013/verify_research.py'
```

资源原文件仍存在时同时校验原文件SHA；以后build被清理时使用已保存的原行摘要复核参数。与006～010包源码清单的差异会如实输出，不据此断言差异作者或回滚并行任务。013的产品实施和设备验收结果应在计划执行后另外追加。

2026-10-04 16:25（UTC+8）：013计划经过在线、本地、网络三侧完整复读，修正坏图页重编号、远程身份缺失、阅读文件排序、AI入口、在线详情入口及收藏写后offset失效等问题；复查33个本地链接均存在，10个必需区块及v0.6执行约束全文齐备，原011的SHA未变。计划最终置为“待执行”，这不是产品功能验收记录。
