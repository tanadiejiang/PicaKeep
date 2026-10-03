# AI 搜图 HTTP 415 验证

日期：2026-10-03，Asia/Singapore。执行位置：PicaKeep 主 checkout 的 main。

## 可复核证据

- 公开协议：[站点主页](https://soutubot.moe/)、[公开前端 JS](https://soutubot.moe/static/app.js?v=20260913-manhuacat)。快照 `homepage.html` / `public-app.js`。前端通过 `new FormData(form)` 加入原始 File 或压缩后 JPEG，文件 part 有实际 image MIME 和扩展名。
- `synthetic-probe.png`：本轮程序生成的 128×128 白底蓝色矩形、金色圆几何 PNG，657 字节。不是用户图片。
- `live-multipart-comparison.json`：同一图字节，旧 `filename=image` / `application/octet-stream` 返回 HTTP 415，detail 为“仅支持常见图片格式”；`filename=image.png` / `image/png` 返回 HTTP 200、75 个原始结果。
- `generate-multipart.dart`：直接导入本次生产 multipart 构造函数生成 `dart-multipart.bin`，配套 Content-Type 在 `dart-multipart-content-type.txt`。
- `live-dart-multipart-result.json`：将上述 Dart 生产构造出的 1042 字节完整 body 原样 POST 至站点，HTTP 200、75 个原始结果。body SHA256 `15946cc42238c9d02f9c7238fdb12aff227dd021e487032c63052097aefb0544`。
- `tests.log`：51 项搜图相关测试全部通过。测试通过 Dio `HttpClientAdapter.fetch` 捕获真正的 `requestStream`，核对 PNG/JPEG/WebP/GIF/BMP 的 part 头、二进制体与结束 boundary；未知格式不发送，415 映射为图片类型错误。既有模型、签名兼容测试和工具结果阈值测试继续通过。
- `analyze.log`：修改网络/工具源码与相关测试静态分析 No issues found。

## 结果与范围

生产上传改为根据真实签名字节确定 MIME 与安全扩展名，保留图片原字节，不发送原始附件文件名。旧 octet-stream 头已移除。未知容器会明确拒绝，415 不再误报服务故障。插件 schema、字段适配、目标白名单、附件白名单、能力开关和 CF 人工验证接线保持既有契约。

57 号曾通过 Python 构造的正确 PNG 请求验证站点，但未核对实际 Dart 生产 multipart 文件头；因此曾误以为请求链路已完整验收。这次用相同图片只换文件头做 A/B，并用生产构造函数生成完整请求体直传，补齐该验证缺口。

没有上传用户图片、使用账号 cookie 或凭据；未安装/构建/卸载/清数据。本目录仅证明桌面公开服务上传及自动化请求链路。手机代理、CF WebView 与真实模型对话交互需要后续用户设备验证。格式签名识别不等同于完整图片解码；附件导入已有 codec 校验/压缩，服务端仍可拒绝损坏内容。


## 主任务合并交付补充 · 2026-10-04 00:05

独立子任务未构建，主任务随后完成60/61统一全量验收与profile构建。全量2351通过/14跳过/0失败，静态分析无问题。包和身份见[60合并验证](../illust-performance-60/README.md)。未安装，未上传用户图片。
