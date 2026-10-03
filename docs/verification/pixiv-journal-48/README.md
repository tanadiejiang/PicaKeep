# Pixiv完成日志精简与主库空间整理 · 第48号验证

日期：2026-10-02 16:34（Asia/Singapore）。执行目录：D:/Flutter_Projucts/PicaComic/PicaKeep，分支main，未提交。本次直接修改主工作目录；500c保留上一轮状态，不是本次48号交付目录。

## 结果与使用方式

- 完整完成日志缩为summaryVersion=1摘要，保留ID（表列）、类型（表列）、完成时间（新记录）、整理时间、作品/文件夹ID、来源/目标或批次计数。删除row/json/snapshot/items冗余。
- 整个根空闲且所有完成记录可解释时，摘要历史保留最新100条。暂停/失败任务及其完成子任务、带error/未知kind/非法payload/不一致批次会推迟整库维护；trashed原payload永不纳入历史裁剪。
- 已有库在initialize时整理，新操作在exclusive结束、批次结束时整理。实际界面触发包括进入Pixiv下载文件夹管理、选择下载目录以及完成新建/改名/复制/移动等操作；不是依赖重装或手动删除download.db。
- 条件收缩仅作用于主库：空页至少64KiB且占25%以上、文件页容量不超过16MiB、进程内距上次VACUUM尝试至少1小时。更大的库仍做逻辑精简、保留空页供复用；不保证截图中的108KB立即变成32KB。
- 主库正式download、文件夹身份与各分类库继续保持原职责；不删除作品、元数据备份和回收站文件。维护事务失败回滚，外部锁冲突立即延后，诊断使用PixivLibrary日志；不会因维护失败把成功业务操作报告为失败。

## 验证结果

| 证据 | 可复跑命令/路径 | 观察与结论 |
| --- | --- | --- |
| E01 | [专项和关联测试](targeted-tests.txt) | 69通过，覆盖目录实体、封面缓存、队列目标、widget多选和复制、20项维护测试、13项根恢复测试 |
| E02 | [全量测试](full-tests.txt) | 2144通过、14跳过、1失败；唯一为既有ai_conversation_test.dart:631，Expected empty / Actual AiChatMessage |
| E03 | [静态分析](analyze.txt) | dart analyze lib test：No issues found |
| E04 | [Debug构建](debug-build.txt) | assembleDebug 109.4秒，debug APK成功 |
| E05 | targeted-tests.txt的48 fixture行 | 隔离样本130条旧日志：数据库1175552→69632字节，payload 1084381→21753字节；子库逐字节不变、作品文件不变、integrity_check=ok |

全量唯一失败与[上一轮原始输出](../combined-44-46-47/full-tests-final.txt)相同，本轮未修改AI源码/该用例。相对上一轮2123通过净增21：20项新维护测试＋1项迁移/回收站综合测试。旧根恢复6个阶段另加了“维护不改快照中字节”的断言。

```powershell
# 在D:/Flutter_Projucts/PicaComic/PicaKeep执行
flutter test --no-pub test/pixiv_library_maintenance_test.dart test/pixiv_library_test.dart test/pixiv_root_recovery_test.dart test/pixiv_folder_cover_integration_test.dart test/pixiv_folders_page_test.dart test/pixiv_download_target_queue_test.dart --reporter expanded
dart analyze lib test
flutter test --no-pub --reporter expanded
flutter build apk --debug --no-pub
```

## 恢复保护与证据链

- E01→完成子任务仍是父批次恢复依据→transfer complete、父items未记账样本中，维护保持payload；resume父批次只执行余项，源文件已消失的移动不重放。
- E01→根迁移按DB字节做快照→preparing/copy/published/cleaning/cleaned/rebased逐阶段中断时对源与目标调用maintain，均返回root-migration且数据库字节不变；继续迁移可成功。
- E01/E05→整理只改变终态日志与空页→正式作品及子库不变，trash仍能按原folderId还原，旧完整记录和新版摘要能一起迁根。
- E02/E03/E04→静态分析、关联流程和编译通过→本轮限定的代码/自动化交付完成，不能据此声称Android实库断电/权限或后台保活已经验收。

## APK

- [产物](../../../build/app/outputs/flutter-apk/app-debug.apk)
- 字节数：179341446。
- 生成时间：2026-10-02T16:30:51。
- SHA256：C25EA885D4256BC4AA7B0D499FAB71E3A5F2B76A3A5FE5C1B59397E176D6EC88。
- [源码与产物摘要](artifact.json)。未安装、卸载、清数据或运行adb设备操作；未构建release。

## 注意事项

- 自动整理是整根空闲策略。有长期未完成/异常任务时，完成摘要可能暂时超过100条，优先保留恢复能力。
- 原始旧日志没有完成时间，摘要只记真实整理时间，保留排序以原rowid兜底；不伪造旧业务时间。
- 空页收缩冷却记录在进程内；重启后重新判断阈值。库超过16MiB不自动VACUUM，避免交互线程长时间重写。
- 测试样本数据不代表手机108KB库中各表占比。本轮没有获取或修改手机实库，Android外置存储/权限/实际断电仍待受控真机验证。
- 初次测试中的活跃批次断言错误地期望维护穿过当前根锁；维护实际会等待锁。已改为两个作品之间的真实可调度窗口，证明确实因active-writer延后。根迁移旧测试原来依赖rename日志路径改变DB，现在rename为无路径摘要，改用仍保留sourceRoot的transfer摘要验证重定位，保留原测试目的。
