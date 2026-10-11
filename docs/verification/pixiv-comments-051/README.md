# 051 · 评论关闭状态与空白名称调查

状态：源码修补和离线验收完成（2026-10-10 01:11 +08:00），用户设备更新后待复测。用户确认此前最新源码已重新运行，该作者的多个作品同样报错，并提供Pixiv原站截图。

## 已定位的事实

- 原站作品页明确显示“作者已关闭评论区”。现有客户端只解析commentCount，遗漏了作品详情commentOff，再自动请求roots，导致把作者关闭这一正常业务状态显示为“不正确的请求”。上轮limit4→20兼容不可能重新开放作者已关闭的评论。
- 原站截图中作品标题与作者名也无可见文字，作者页还有正常简介与作品。这说明空白不是本应用独有现象；截图不能确定原始字段是空串、普通空白还是U+2800等不可见字符，更不能证明作者的主观意图。当前保留原始可解析标题／名称，不猜填其他作品文本。
- 调查未读取此作品真实JSON、真实登录Cookie／token或账号写接口；公开fetch被工具网络边界拒绝。不能用合成fixture冒充平台数据。

## 修补范围

- 详情模型新增nullable commentsDisabled，仅解析显式commentOff（bool或0/1及匹配字符串）；unknown保持null，不以commentCount=0推断关闭。bookmark copyWith保留此字段。
- 真实View将commentsDisabled==true传给评论组件。关闭时显示“作者已关闭评论区”，没有骨架／重试／展开／回复读取；参数默认false兼容既有调用。关闭／重开会失效旧epoch，晚回包不污染当前状态。开放和未知保持原正常读取。
- 收窄上轮过宽的HTTP400兼容：只有识别到invalid-request业务文案才扩大一次到20；任意一般400拒绝不能被后续空成功掩盖。这个策略瑕疵不是原站关闭评论的根因。

## 验证

- [定向最终日志](targeted-third.log)：5套72项通过，包含真实View的closed/open/unknown传递，关闭时rootRequests=0，旧根评论与回复epoch拒收。
- [合并最终日志](regressions-final.log)：38套550项全部通过，含原049/050详情／作者／评论／封面／分页回归及本轮两个新增测试文件，退出码0。
- [静态分析](analyze-final.log)：32个文件 No issues found，退出码0。[diff检查](diff-check-final.log)退出码0，仅LF/CRLF转换提示。
- 原站证据：[作品](user-original-work.jpg)／[作者页](user-original-author.jpg)，均为用户提供的JPEG原样复制。SHA256分别为`f4b125dbd066e9aea1475a2207c4431b936c3b558cb24523fc3ec3903735bce9`、`33e8daa8c56a8351acca95ee28eca86f593babfd3c41e90791d1590c0d4bb74d`，未当作网络JSON抓取。

| 离线关闭状态 | PNG | JSON |
| --- | --- | --- |
| 375亮色 | [图](disabled-375-light.png) | [数据](disabled-375-light.json) |
| 240暗色／字号2 | [图](disabled-240-dark.png) | [数据](disabled-240-dark.json) |
| 812横屏／reduced motion | [图](disabled-812-light.png) | [数据](disabled-812-light.json) |

三组都是合成metadata、真实Flutter渲染，不是用户设备更新后截图；记录关闭文案和rootRequests=0，断言无骨架、重试、展开、暂无评论误报、越界。真实头像／作者名字不由此证明。

## 修改入口

- [模型](../../../lib/network/pixiv_network/pixiv_models.dart)、[解析](../../../lib/network/pixiv_network/pixiv_parsing.dart)：显式nullable评论关闭状态与copy保留。
- [详情](../../../lib/pages/online_comic/pixiv_online_detail_view.dart)、[评论](../../../lib/pages/online_comic/pixiv_comments_section.dart)：关闭显示、零新请求、reopen和旧epoch保护。
- [网络](../../../lib/network/pixiv_network/pixiv_network.dart)：修正过宽的HTTP400兼容，未知关闭状态仍诚实保留错误。
- [解析测试](../../../test/pixiv_comment_off_parsing_051_test.dart)4项、[评论组件测试](../../../test/pixiv_comments_disabled_051_test.dart)9项；[真实View](../../../test/pixiv_detail_entry_preview_050_test.dart)增加3项，[错误兼容](../../../test/pixiv_reported_author_050_test.dart)增加3项，合成fixture不冒充150343763响应。

## 过程与边界

1. 首轮Tee日志目录未建立，报Could not find a part of the path但退出0；不能当通过。建立目录后增加ErrorActionPreference=Stop再执行。
2. [第二轮](targeted-second.log)完成69项但PNG的toByteData落在widget FakeAsync中，等待不结束；主动停止，不当作生产bug。整个toImage／toByteData阶段移入tester.runAsync并finally释放image后，第三轮72项与最终550项全部通过。
3. 旧013[guest记录](../pixiv-detail-013/guest-comment-read-verification.json)及响应hash支持其他作品的历史snake_case参数／limit20成功，不能推断本作者的开关、当前支持的page-size范围或授权条件。公开源fetch被网络边界拒绝，不绕过，也不把search线索当取得的实际代码或JSON。
4. 无构建／安装／SDK或依赖升级／真实登录账号请求／数据或缓存清除，无提交，既有dirty变动保留。050最终531项历史日志不重写，本轮最终日志独立放051。

从仓库根目录执行[验证脚本](verify.ps1)：

```powershell
& 'docs/verification/pixiv-comments-051/verify.ps1'
```

用户更新本次源码后，**在详情菜单刷新一次或完整重新进入会话**，以读取新加入的commentOff字段；仅热重载时旧内存详情对象可能仍是unknown。不要清应用数据／重新登录来测试。实际作品JSON字段、空白字符码点和用户设备新修补效果仍未实测，不能声称作者故意用了U+2800或该手机已经验收。

