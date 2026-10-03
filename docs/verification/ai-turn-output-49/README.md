# AI多次清单后的空回复提示 · 第49号验证

代码目录：D:/Flutter_Projucts/PicaComic/PicaKeep，main工作区，未提交。侧会话原编号48与主目录已完成的Pixiv日志整理48冲突，接入主目录时顺延为49。侧会话原计划保留文件名，只同步状态与执行回写；原始交付快照见[delegated-plan-original.md](delegated-plan-original.md)。

## 修复结果

本轮清单即时显示后，不再因为_pendingDisplayItems已清空而追加“AI本轮未返回有效内容”。每次有效调用仍独立出卡，相同作品/相同内容不会跨调用合并。零结果及具体失败反馈保留；完全没有可用展示内容、仅泛化状态或原始JSON时仍显示一次轻量提示，且不写入模型历史。

运行时_TurnOutput记录已经展示的清单数、保留的正文/思考和具体反馈；只在新用户提问/新会话时重置，跨工具子轮和下载确认续跑保留。完成态阻止重复收尾，回合对象和请求取消令牌隔离迟到的响应/增量；下载确认互斥避免重复点击触发重复执行。此状态不落盘，不扫描旧消息推断本轮状态。

保持工具白名单display_result_list/search_by_image。没有引入全局toolCallId集合：空ID或跨轮复用ID不会吞掉新调用；正常生产结果通过单次await→append→flush路径只交付一次，重复收尾已测试。测试里的异常ID仅用于验证不误去重，不承诺上游服务接受异常协议。

## Evidence → Finding → Path

| 证据 | 观察 | 结论 |
| --- | --- | --- |
| [修复前确定性基线](baseline-test.txt) | 清单在收尾前已经出现，空正文后仍多一个AiChatMessage | 错误源于用已消费缓冲区判断本轮输出，不是清单校验失败 |
| [定向回归](targeted-tests.txt) | 130项通过；28项新控制器测试＋1项新Widget测试 | 清单、历史配对、流式封口、确认续跑和回合隔离符合新契约 |
| [静态分析](analyze.txt) | dart analyze lib test：No issues found | 无新增分析问题 |

调用链：用户send重置本轮摘要→工具成功追加resultList并记数→后续工具子轮/下载确认继续使用本轮摘要→最终空正文封口流式并读取摘要→仅本轮没有输出时追加一次展示用提示→finished阻止重复收尾。clear/dispose或新的send使旧异步身份失效，不把旧结果写到新回合。

## 验收映射

| 计划项 | 实测覆盖 |
| --- | --- |
| A01 | null/空串/纯空白三种终值，清单先出现且最终仍一张 |
| A02/A03 | 同工具子轮两次调用＋下一子轮一次，相同内容共三张即时卡 |
| A04 | 重复空正文/正常正文收尾不重复卡片或提示，确认重复点击只执行一次，历史按调用实例配对 |
| A05 | 空ID/重复ID在同轮和跨子轮独立出卡，结果数量正确 |
| A06 | 真正DisplayResultListTool校验失败→脚本模型修正→成功→空正文，retryable保留 |
| A07/A08 | 两个白名单零结果具体说明；明确失败原因/重试字段，均无泛化提示 |
| A09 | 完全空白、无message、工具执行成功、查询完成，以及非白名单原始items都仍只补一次提示，不进history |
| A10 | 前轮清单后下一轮空白、真实保存加载后新问题，旧清单不污染本轮 |
| A11 | 清单＋含首尾空白正文，展示与history原文保留 |
| A12 | captureStreamSinkForTesting驱动生产同一streamSink/onDelta/seal路径，思考气泡封口display-only；工具轮思考存档契约保持 |
| A13 | 停止前/后有流、异常/错误响应、最大轮次、clear后LLM/工具/增量迟到，均不污染新轮或追加重复提示 |
| A14 | 清单后暂停下载确认，确认成功用默认工具状态继续空正文，不误补提示；重复确认/旧确认返回均受保护 |
| A15 | display_result_list/search_by_image自动出卡，非白名单只含items不出卡 |
| A16 | 130项控制器/工具/结果项/Widget/会话存储/下载确认/思考/SSE/请求JSON测试通过，静态分析无问题 |

## 复跑

```powershell
# 在主目录执行；只使用注入脚本和隔离数据，无真实模型账号依赖
flutter test --no-pub test/ai_turn_output_test.dart test/ai_conversation_test.dart test/ai_chat_result_list_widget_test.dart test/ai_conversation_store_test.dart test/ai_reasoning_archive_test.dart test/ai_reasoning_section_test.dart test/ai_result_item_test.dart test/ai_auto_download_test.dart test/ai_download_queue_test.dart test/display_result_list_tool_test.dart test/sse_chat_parser_test.dart test/llm_request_json_test.dart --reporter expanded
dart analyze lib test
flutter test --no-pub --reporter expanded
```

## 最终全量结果

[全量输出](full-tests.txt)：**2174通过、14跳过、0失败**，最终状态All tests passed。上一轮2144通过/14跳过/1失败，本轮新增29用例且原唯一失败修复。全部验证结束后源码保持不变；[源码摘要](final-source-manifest.json)记录交付版本。

## 边界

- 本轮未改system prompt、工具schema/校验、持久化格式、清单外观或Pixiv/后台下载链路；48号相关源码摘要仍与之前manifest一致。
- 按计划未另行构建或安装。build/app/outputs/flutter-apk/app-debug.apk仍是48号16:30:51生成的debug产物，不包含49号AI修复，不能用旧包做本次真机复验。
- 流式验证使用生产同一控制器回调和封口逻辑，另跑SSE解析测试；没有连接真实LLM服务或Android设备，实际服务端/设备体验需后续受控验收。
- 不引入全局执行去重；如果将来新增可重复投递的工具结果入口，需要另加调用实例级幂等，不能按原始toolCallId或作品内容跨轮去重。
