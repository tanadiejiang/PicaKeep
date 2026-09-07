# AI 自动下载免确认修复

对应问题：PK-01。基于 main 的 V1.9.65（c32bc9de65d9cb9dd3cfd61db46f5199cf1220bc），本地分支 codex/fix-ai-auto-download。

## 问题与原因

用户开启“下载漫画”和“允许AI自动下载”后，仍需逐项确认。settings[149] 原先仅控制 download_comic 是否出现在模型工具列表里；对话控制器收到下载调用后，无条件加入 PendingDownload 队列。此外，固定 system 提示词要求所有下载等待确认，模型可能在发出工具调用前就停下来询问。

## 修改后的行为

- 两个开关同时开启：直接复用工具注册表执行 download_comic，加入 OnlineDownloadManager 下载队列，回填工具结果后继续对话。
- 同轮多本下载：按调用顺序逐个执行；成功、失败或工具异常均回填对应 tool_call_id，所有结果齐全后才请求下一轮模型。
- 执行过程中关闭任一开关：后续调用不自动执行，保留原来的待确认流程。关闭状态下工具仍不向模型暴露，页面手动下载行为不变。
- 提示词按当前工具可用性说明免确认行为；仅搜索或查看详情不视为下载请求。明确区分“已入队”和“下载完成”。使用固定条件规则，不把动态开关值插入 system 前缀。
- 设置页文案明确“无需确认，直接加入下载队列”。

修改入口：lib/foundation/ai/ai_conversation.dart、lib/foundation/ai/ai_settings.dart、lib/pages/settings/ai_settings_page.dart。

现有下载引擎、任务去重和持久化未改动。原有范围规则保持不变：localOnly/onlineOnly 限制的是对应搜索/查询工具，并非全面禁用下载。

## 回归验证

新增 test/ai_auto_download_test.dart，使用可记录调用的下载工具替身，运行真实对话工具循环，不访问漫画站点或发起实际下载。

7 个用例覆盖：单本免确认、多本混合展示工具的完整回填与模型续跑、返回失败、抛出异常、父开关关闭、自动下载子开关关闭，以及执行中关闭开关。多本用例同时检查固定提示词不再要求所有下载等待确认。

2026-09-07 验证结果（Flutter 3.41.6 / Dart 3.11.4，原 pubspec.lock，通过 pub get --enforce-lockfile 安装）：

- 新增自动下载回归：7/7 通过。
- 扩展回归：57 项通过、1 项失败。运行范围为 ai_auto_download_test、ai_conversation_test、ai_conversation_prompt_test、ai_conversation_cache_prefix_test、ai_download_queue_test。
- 失败项：ai_conversation_test.dart:631，“content 为空但存在待展示的工具结果（清单卡）时：不追加轻量提示气泡，只展示清单卡”。期望无 assistant 提示气泡，实际出现一个。
- 基线对照：临时使用 HEAD 原始 ai_conversation.dart 重跑，该清单卡用例同样失败；新增“单本免确认”用例在基线上也按预期失败（下载工具没有执行）。对照完成后已完整恢复修复代码。清单卡问题属于既有问题，不归入此次 PK-01 修复。
- 修改的三个 Dart 实现文件与新增测试文件定向静态分析：No issues found。
- 新测试文件格式检查及 git diff --check 通过。既有文件保留原排版，未引入整文件格式化或依赖升级。

真实模型与设备上的下载入队、设置操作仍需端到端验收；本次未构建安装包或发布版本。问题清单已同步 PK-01 修复状态及其余 5 项待办。

复核命令：

```text
flutter test --no-pub test/ai_auto_download_test.dart test/ai_conversation_test.dart test/ai_conversation_prompt_test.dart test/ai_conversation_cache_prefix_test.dart test/ai_download_queue_test.dart --reporter expanded
dart analyze lib/foundation/ai/ai_conversation.dart lib/foundation/ai/ai_settings.dart lib/pages/settings/ai_settings_page.dart test/ai_auto_download_test.dart
dart format --output=none --set-exit-if-changed test/ai_auto_download_test.dart
git diff --check
```
