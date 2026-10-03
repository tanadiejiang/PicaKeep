# 57 号：AI 搜图新版接口与可维护工具插件

2026-10-03。公开主页 GET 200，现行 `/static/app.js?v=20260913-manhuacat` 直接 multipart POST `/api/search`，**没有旧的 `GLOBAL.m` / `x-api-key` 链路**；返回结构从 `data` / `id` 变为 `results` / `path_segments` / `result_id`。本轮修复 AI 对话搜图，并把站点适配规则做成**能独立于 APK 导入、诊断、更新、回退**的插件。源码直接改于主仓库 `main`，未提交；真机端到端未验。

## 原因与改动

| 证据 | 结论 | 实现位置 |
| --- | --- | --- |
| 公开主页与现行 JS 实读 | 新版首页没有 `m` ⇒ 旧实现**上传前就失败**；即便去掉 `m`，仍会按旧 `data` 误判 ⇒ **请求与响应必须一起改**，只修报错文案无效 | `lib/network/soutubot_network/soutubot_signature.dart`（multipart）、`soutubot_network.dart`、`soutubot_models.dart` |
| 程序生成 256×256 几何 PNG 真实上传 | 上传 HTTP 200；75 命中展开 **84 条路径**，Dart 模型转 `AiResultItem` **84/84 零丢失** | 同上；旧 `data` 响应保留兼容 |
| 声明式 JSON + 执行器分派 | 不给模型任意执行 Dart / shell 的权限；当前两个 kind（`image_search`、`http_json`） | `lib/foundation/ai/ai_tool_plugin.dart`（schema 校验）、`ai_tool_plugin_runtime.dart`、`ai_tool_plugin_store.dart`（64 KiB 清单 / 32 插件 / 4 MiB 库，串行原子落盘、保留上一版） |
| 插件管理入口 | 设置 → AI → AI 工具插件；维护开关**默认关**，开启后可 list / read / diagnose / update / rollback，受同 origin / kind 约束 | `lib/pages/ai/ai_tool_plugins_page.dart` |

关键取舍：搜索能力开关与插件管理**独立生效**（搜图仍需原有"以图搜源"能力）；"仅本地"会话在 schema 与执行两处阻止；公共 GET 不继承应用凭据、拒绝私网与重定向；搜图仍走既有 Cloudflare 人工验证链路，验证成功后重试会**重新检查能力与适配版本**。

## 本机验证与复跑

```powershell
dart analyze lib test
flutter test --no-pub --reporter expanded
```

- 全量 **2315 通过、14 跳过、0 失败**；`dart analyze` No issues found；`git diff --check` 通过（stderr 仅既有 LF/CRLF 提示）。
- 定向：`integration-tests.log` **63 项**、`network-tests.log` **32 项**、`turn-output-integration-tests.log` **34 项**，均 All tests passed。
- 公开诊断（`plugin-public-diagnostic.json`）：真实 TLS 公开 GET `https://soutubot.moe/`，**HTTP 200 / 674 ms**，`operation: "public GET; no images or app credentials"` —— 未上传用户图片、未读取账号密钥、未发送 Cookie 做探测。
- 合成响应（`live-model-test.log`）：`rawHits 75 / paths 84 / converted 84 / discarded 0`，原生来源分布 `ehentai 35`、未识别 `27`、`nhentai 21`、`pixiv 1`。
- profile 构建与包名/签名核验通过：`build/verification/pixiv-experience-56-58/app-after56-58-profile.apk`，`lingxue.picakeep` / `1.9.88+5`，**未安装**。

## 未验边界

- **真实模型自动维护对话、手机文件选择器、本机 CF 人机验证都没有端到端操作**，只用 controller 模拟了工具请求 / 组件 / 持久化接线。
- 泛型示例 `http-json.example.json` 的 `example.org` 需换成真实接口才能用。
- 新增原生执行器、任意代码、新的登录与签名机制**不属当前可热更新范围**；站点后续变动仍可能超出现有执行器能力。
- 维护后提示"**规则已更新**"，不等于"搜索已验证成功"。

## 本目录文件说明

- **入库**：本 README（交接文档与 `docs/ai-tool-plugins/README.md` 的引用目标）。
- **本地留档，不入库**：上述各 `*.log` / `plugin-*.txt` / `plugin-public-diagnostic.json` 等过程证据。
- 生成这些证据的**一次性脚本已移到 `docs/verification/_raw/ai-image-search-57/`**（`parse_live_response_test.dart`、`synthetic_probe.py`、`synthetic-*.json`，以及抓包素材 `app.js`、`homepage.html`）；诊断脚本为 `tool/_tmp_ai_plugin_diag_57_test.dart`（按项目惯例忽略）。

## 关联

- 使用说明与清单格式：`docs/ai-tool-plugins/README.md`
- 内置搜图清单硬编码于 `lib/foundation/ai/ai_tool_plugin.dart` 的 `builtinImageSearchPlugin()`，`docs/ai-tool-plugins/soutubot.json` 是同内容的可读副本
- 计划文档：`Z-plan/新需求-主线-第十八轮/57-修复-AI搜图接口与工具插件化.md`
