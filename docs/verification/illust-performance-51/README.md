# 第51号：插画页与阅读入口性能优化

代码目录：D:/Flutter_Projucts/PicaComic/PicaKeep，main工作区，未提交。本轮没有安装、卸载、清数据或更改无障碍权限。

## 当前结论

代码及自动化已实施，最终全量 **2193通过、14跳过、0失败**，静态分析无问题。整份51号仍必须标记“部分完成”：没有同设备三种场景各3次的新profile录制，也没有真实root/Shizuku和已授权无障碍环境的优化后复测，不能声称达成120Hz性能门槛。

用户补充“如果没执行的话那就是刚才的版本了”，据此把50号两份记录作为优化前定位资料。原文件未覆盖、未复制到用户数据目录、未上传；SHA-256与50号一致，见[基线清单](baseline-manifest.json)。该录制混合进入页、往返滚动和开图，仍不能代替独立场景的3次中位数比较。

## 实施内容

| 工作包 | 实际实现 | 证据/限制 |
| --- | --- | --- |
| A 数据入口 | 插画入口不等待图集远程可用性探测；普通文件exists/list/read前检查改真正异步，空列表及失败保留特权回退；读取既有DB快照的SQLite句柄在worker开关；插画JSON装配与标签汇总在worker；元数据规范化按32条让出事件循环 | 主扫描契约、普通目录/ZIP/单图和复制/迁移回归通过；小型文件夹登记查询仍在加载阶段同步读取，不在build内 |
| A 版本快照 | 只给插画页显式启用cacheSnapshot；数据/设置版本失效、手动强制刷新、并发加载合并、代次防旧结果覆盖 | 既有getManagedDownloads调用仍保持新鲜读取，避免直接复制/移动调用后看到旧表 |
| B 补齐队列 | 页面持有IllustWorkQueue，布局真实索引范围＋250dp预布局项，合并封面/尺寸/页数；总并发2、缩略图生成串行1；纵向depth=0滚动暂停、140ms idle恢复、route/app/dispose门控 | 队列并发/取消/代次/位置ID/生命周期单元测试；仅控制列表装饰，不改后台下载队列 |
| C 图片通路 | manager解析后使用应用内thumb-v2缩略图；384/768/1536px档、4096长边/4Mi像素保护、小图不放大；stat在解析阶段，原子临时文件发布、前后版本复核；内部FileImage走文件缓冲，外部fallback禁用raw byte cache | 实际编码/解码测试覆盖尺寸、长图、同键、替换、删除、失败及重试；原图不改、不裁；超过档位仍用原封面限尺寸解码 |
| C 配额/清理 | thumbs加入现有统计、LRU及用户主动缓存清理；发布后节流trim保护当前文件/part；仅清理可再生缓存 | 没有新增全局ImageCache.clear行为；单项解码错误evict对应ResizeImage key，回队重试；手机实际权限仍待验 |
| D 局部更新 | FAB ValueNotifier；每卡局部revision；筛选/信息spans按输入版本缓存；位置ID稳定key；idle尺寸变化按实际RenderBox保持可见锚点 | 实际滚动锚点、 stale代次和原卡片交互/尺寸测试通过 |
| D 语义 | 图片/信息两个明确操作节点，保留tap/longPress/selected；排除装饰重复语义，不做全页屏蔽 | 真Widget验证阅读/详情与多选；实际服务节点计数、耗时与cacheExtent 250/半屏/一屏AB仍待profile |
| E 历史 | find/findSync先来源过滤，再主/副库参数化target查询；去掉为单项建立全表成员缓存 | 0/1000/10000条测试最多1～2次查询、EXPLAIN使用主键索引、主库优先与副库回退、隐藏来源不读取；不改schema/getAll/写入策略 |

所有封面/衍生缩略图仍在应用目录；尺寸缓存也统一到App.dataPath，保存串行且先part后发布。旧资料目录、下载记录和迁移事务没有被当作缓存删除。

## 验证

- [全量最终输出](full-tests-final.txt)：2193通过、14跳过、0失败。相比49号2174通过，新增19项：队列5、主键历史5、缩略图4、锚点2、语义1、快照与prepared provider集成2。
- [静态分析](analyze-final.txt)：No issues found。
- [定向记录](targeted-tests.txt)：早期222通过/13平台跳过；后续源代码调整均由最终全量覆盖，最终结论以全量日志及[源码摘要](final-source-manifest.json)为准。
- [真正异步页面与文件夹回归](async-regression.txt)、[锚点/缩略图/页面细化测试](refined-tests.txt)。
- [构建输出](profile-build.txt)：只运行flutter build apk --profile --no-pub。已成功（Gradle173.3秒），127314147字节，生成2026-10-02T20:58:25；SHA256 6A762B2906BEDBD425DD18A307983BA29D99ECCBE1B486504E20EFF65F77BB07。详见[产物清单](artifact.json)，未安装。
- [差异检查](diff-check.txt)：通过，行尾转换提示不代表内容错误。

```powershell
# 在D:/Flutter_Projucts/PicaComic/PicaKeep运行
flutter test --no-pub test/illust_work_queue_test.dart test/illust_scroll_anchor_test.dart test/history_single_lookup_test.dart test/illust_thumbnail_test.dart test/local_library_illust_card_test.dart test/local_library_page_view_scope_test.dart test/pixiv_folder_cover_integration_test.dart test/pixiv_folders_page_test.dart --reporter expanded
dart analyze lib test
flutter test --no-pub --reporter expanded
flutter build apk --profile --no-pub
```

SDK实际回读：Flutter 3.41.6，Dart 3.11.4，DevTools 2.54.2。目录名含3.38.5不代表实际SDK版本。原始记录是profile/120Hz，与50号一致；本轮没有制造新的设备采样数据。

## V01～V12验收边界

| 项 | 已有证据 | 尚未验收 |
| --- | --- | --- |
| V01 | 普通目录、单图、ZIP的扫描/实际封面解码与文件夹缓存通过 | 手机共享存储/root/Shizuku权限组合 |
| V02 | 插画独立入口、快照失效/复用、页面切换回归通过 | 同设备冷暖首次时间、离线远程配置实机 |
| V03 | 卡片build只消费内存prepared provider，文件读取迁出；FAB局部监听 | 真机计数/trace确认UI同步I/O尖峰归零 |
| V04 | 2并发、140ms、反复滚动取消timer、真实布局范围代码及测试 | 快速滚动/惯性/横向标签混合的设备画面 |
| V05 | queue active/dispose/迟到结果测试、route与app监听接入 | 阅读器覆盖/后台root提示及实际下载并行的设备验证 |
| V06 | load/queue代次、位置key、RenderBox锚点实际Widget测试 | 极端排序/刷新/换目录同时尺寸变更的实机 |
| V07 | 两目录副本ID与位置独立；复制/迁移回归；应用内缩略图路径断言 | root跨卷迁移真实权限 |
| V08 | 同键共用、源替换新键、删缓存再生、生成失败/暂停无半文件 | 系统回收文件/权限恢复时长及长时间耐久 |
| V09 | 小图不放大、长图保持比例且受长边/像素上限约束；页数旧用例通过 | 1/2/多列、高DPI视觉对比和内存5轮平台 |
| V10 | 真Semantics tap/longPress/selected及独立标签验证 | 当前授权服务下节点数、语义P95下降30%或低于4ms |
| V11 | 临时0/1000/10000行单项主键、主副库优先和来源过滤测试 | 开阅读器的独立profile帧改善程度 |
| V12 | 静态分析/2193全量通过，无新增失败 | 无额外自动化阻塞 |

性能门槛全部等待新的同设备数据：UI/raster超预算比例、完整UI回调P95/P99、语义P95、>33ms尖峰分类、5轮内存/队列平台、冷首屏不得退化10%、阅读入口改善。旧totalSpan超预算次数不是实际丢帧数，后台图片解压时长也不是UI冻结时长。

## 实施中遇到的问题

1. 首次把快照长期缓存放到所有调用方，直接文件夹复制/迁移的既有测试读到旧内容。改为仅插画页opt-in，其他调用仍新鲜读取；恢复原测试通过。
2. 真正异步directory.exists使旧Widget测试的模拟时钟pumpAndSettle超时。曾用同步路径做隔离定位，但最终恢复了异步实现，并在测试中使用有上限的runAsync真实事件循环等待。进一步暴露缺SharedPreferences模拟，补齐后全部标题/工具栏原断言通过，未降低断言。
3. worker返回普通Map，原元数据辅助函数只收SQLite Row，改为兼容两者的Map接口；活跃句柄不跨isolate传递。
4. 缩略图测试复用同路径导致命中已生成图而非故障注入。用唯一paused.png与可控中止检查测试中途取消，保留“不能发布半图”的断言。
5. 初期日志/探针已移除。profile仅保留IllustWork.reset/scroll/idle/foreground/paused/dispose阶段计数，不逐帧落盘，不写作品路径或账号。

## 后续

51号必须保留为部分完成；52号承接同设备profile复测、cacheExtent AB、实际权限/无障碍/长图视觉与性能指标验收。未获得安装授权前只提供已核验的profile产物，不自动覆盖安装、更不卸载。现有44/46真机后台与功能边界不因本轮测试通过而改成完成。
