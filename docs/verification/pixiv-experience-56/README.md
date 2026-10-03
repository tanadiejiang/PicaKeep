# 第56/57/58号统一验证记录

源码位置：`D:/Flutter_Projucts/PicaComic/PicaKeep`，直接main，未提交。`source-manifest.json`保存构建源397个文件SHA256与HEAD；`changes-from-head.patch`为当时已跟踪改动（包含先前54/55，不能误当仅本轮差异）；新增文件以源码清单与实际工作树为准。

## 自动化

- `full-test-accepted.txt`：2315通过、14跳过、0失败。
- `analyze.txt`：No issues found。
- `git diff --check`通过，stderr仅既有LF/CRLF提示。
- 前面full-test/full-test-final保留定位历史，不能引用为最终状态；page-scope-final、插件integration等定向记录用于解释过程，测试组有重叠，不能相加。

## 已实现的工作流

56：新Pixiv下载完成记录保存pageCount/authorId，包装与JSON往返保留；旧目录/ZIP统计与应用内成功缓存；确认单图后立即释放页数行；搜索标签移入主题展开区且收起保留已用条件；作者资料/瀑布流改版与本地在线作者入口；收藏工具栏合并搜索、档位移至更新后，搜索范围/建议/旧异步响应隔离。

57：新版soutubot直接multipart上传及嵌套响应映射；声明式插件导入、启停、诊断、版本回退/恢复；对话AI维护工具与公共JSON查询执行器，能力和仅本地限制双侧接入。真实合成图POST HTTP200，75命中/84路径全部转换；真实默认TLS客户端公开诊断GET成功。证据在邻目录 `../ai-image-search-57`；协议与示例在 `../../ai-tool-plugins`。

58：文件夹菜单按档位风格采用圆角、图标块、选中底色和勾选；默认重启后保持选择，可改仅本次应用会话。设置-浏览-插画列表与页内显示设置共用组件。按root/libraryId/folderId记忆，重命名不丢，失效ID清理，根切换不串。

## 性能证据边界

55用户原录制复算在profile55-summary.json及profile55-findings.md：1090帧、120Hz、build或raster超预算去重7帧。不是本轮修改后的测量，不能宣称56性能提升/无掉帧。54/55的队列、降采样、应用内封面缓存约束保留。

## 真机待验

本轮未安装应用、未卸载、未清数据。仍需用户在profile包上检查单图空行/两页数据、慢拖快甩、搜索展开与文件夹返回重进/重启、作者联网/详情导航，以及本机文件选择器和Cloudflare人工验证。自动化通过不能代替这些真机体验，也不关闭第52号长期性能验收。

构建包与校验见下方追加记录。

## Profile 构建（2026-10-03 20:26）

`flutter build apk --profile --no-pub`成功（assembleProfile 131.5秒），已独立保存 `build/verification/pixiv-experience-56-58/app-after56-58-profile.apk`，132933859字节。

- 包名 `lingxue.picakeep`，版本 `1.9.88+5`。
- SHA-256 `7E0ABD1752056F12D2ACD8CA5953A4716233F51E22F803202D833F06B3BEEFCE`。
- APK签名验证成功，证书SHA256与54/55一致：`31b4434516ccc1f58add7cc5cd4b6786e995c957d5891d3685e4c75a7a58d7c7`。
- `apk-metadata.json`、`apk-signature.txt`、`apk-badging.txt`留证。未安装，不覆盖54/55独立留存包。

## 组件渲染复核

`search-panel-preview.png` 与 `folder-menu-preview.png` 使用真实Flutter组件在420dp、主题色和中文/图标字体下渲染并检查；圆角/选中底色/图标块/勾选/搜索字段与标签排布均符合预期。脚本 `tool/_tmp_experience_preview56_test.dart`，单独1项通过（不计入2315全量测试）。这是无业务图片的组件预览，不是手机截图；未改变构建源码。
