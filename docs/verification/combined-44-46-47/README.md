# 第44、46、47号合并验证

日期：2026-10-02（Asia/Singapore）。代码目录：C:/Users/tanad/.codex/worktrees/500c/PicaKeep。

## 最终结果

- dart analyze lib test：No issues found。见[静态分析](analyze-final.txt)。
- flutter test --no-pub --reporter expanded：2123通过、14跳过、1失败。见[最终全量输出](full-tests-final.txt)。
- 唯一失败为test/ai_conversation_test.dart:631：清单卡场景Expected empty / Actual AiChatMessage。交接文档历史记录已确认相同基线失败，本轮未修改AI实现或该测试。
- 第44号专项：54通过，包含23项新测试及既有回归。见[通知/后台验收记录](../download-notification-44/README.md)。
- 第47号根迁移恢复：12通过，见[最终根恢复输出](root-recovery-final.txt)。
- 第46号初次定向146通过/13跳过，后续变化已由最终全量覆盖；见[46号执行记录](../pixiv-folders-46/README.md)。
- flutter build apk --debug --no-pub：成功，最后Gradle执行66.1秒。见[最终Debug构建](debug-build-final.txt)。
- git diff --check：通过，只有已有平台行尾转换提示。

## APK

- 路径：build/app/outputs/flutter-apk/app-debug.apk。
- 文件大小：215516627字节。
- 生成时间：2026-10-02 13:28:28。
- SHA256：8EA5FB92625B87332943B03EF2E535DA8F282927AB4D09D6D8C6D4E685EB84C0。
- 本轮未安装、卸载、清数据或操作Android设备；只构建debug。

## 功能及验收边界

- 46号：Pixiv自定义下载文件夹、目录管理、作品多选、目标固定的下载队列、复制/移动/删除策略及应用内封面缓存。旧目录接管UI未提供；非空目标根合并与共用漫画根的整体迁移安全拒绝。
- 44号：聚合进度通知、冷/热启动跳转、独立下载前台服务、有限CPU唤醒、网络等待/恢复、队列初始化保护及图片流原子发布。
- 47号：根迁移各阶段恢复的目标再验证、内部写入互斥、空目录保留和新增源内容保护。
- 44/46保持部分完成，Android锁屏、Doze、厂商省电、真实网络和Root/Shizuku权限仍需真机验收；不能以桌面测试、通知出现或构建成功保证后台永不中断。进程/Flutter引擎彻底结束后读取保存的暂停队列继续。
- 47号限定代码/自动化范围完成；没有扩大为Android平台全面验收。

## 记录位置

工作树Z-plan/新需求-主线-第十八轮下44、46、47号计划均有执行回写，原D:计划副本同步更新。三份交接文档补充完整版§178–180、经验版§157–159及精简版入口。第一轮全量和初期恢复日志保留为时间点证据，以带final的日志作为最终代码验证结果。
