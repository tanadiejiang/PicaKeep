# 029／030：详情爱心与搜索封面修复

日期：2026-10-08（Asia/Singapore）。执行者：Codex及隔离回归子任务。用户明确“执行”后实施，基线main `3f42c957f927f17dcbb346f9f6976f709b927539`、工作区干净，项目版本`1.9.93+10`。029／030代码及隔离自动化验收均完成，真实设备复验待进行。原计划正文保留，最终状态以各计划末尾的新执行回写为准。

计划：[029](../../../Z-plan/新需求-主线-第十九轮/029-修复-Pixiv在线详情横图首屏爱心误隐藏.md)、[030](../../../Z-plan/新需求-主线-第十九轮/030-修复-本地搜索结果封面解析与失效恢复.md)。隔离任务目录：`D:/picakeep-pixiv-fixes-029-030-work`。本轮没有构建／安装APK、操作设备或真实账号，未提交／推送，版本未再调整；022优化仍暂停。

## 已证实的故障与修复

| 修前证据 | 根因 | 最终行为 |
| --- | --- | --- |
| 400×800、单横图、短详情，offset0爱心opacity实际0，期望1；[旧逻辑失败](D:/picakeep-pixiv-fixes-029-030-work/logs/favorite-before.log) | 作者区首屏已经经过按钮边界，显隐只考虑作者区几何 | 实际minScrollExtent及顶部回弹优先显示；离开顶部仍按作者区隐藏。滚动／几何变化同帧合并，回调读取最新状态 |
| 真实LocalSearchPage下载范围，managed原件有效、旧派生封面已删除，结果有文字却无RenderImage；[搜索修前](D:/picakeep-pixiv-fixes-029-030-work/logs/search-before.log) | 搜索同步检查旧File路径，不接正常下载列表的惰性来源解析 | 结果卡片通过来源resolver和现有manager解析、重建，解码到实际参考像素 |
| 同一真实搜索页，只有HTTP封面的未下载收藏也没有RenderImage；有效本地封面对照通过；同上日志为1通过／2失败 | 合法URL被当作本地File，无网络封面分支 | 按来源区分本地／关联下载／网络，带当前来源headers及会话隔离；回退包含异步读取或解码失败 |
| 插画真实页面阻塞两条源探测，筛到零结果后释放，旧逻辑仍读取第三条源，预期2／实际3；[旧队列失败](D:/picakeep-pixiv-fixes-029-030-work/logs/inline-before.log) | 零结果移除瀑布流，不再有新布局回调清空旧可见集合 | 过滤结果列表改变时立即清旧布局／可见准入，新布局重新报告；已完成封面及原预算保留 |

以上是隔离夹具的确定失败，尚不能据此确认用户当时具体漫画／入口的全部根因，尤其队列准入问题不能等同历史漫画破图。

## 文件职责与契约

- [详情共享壳](../../../lib/pages/online_comic/pixiv_detail_shell.dart)：仅调整几何显隐同步。保持单一scroll controller、原200ms居中缩放／淡出、hit-test／语义规则和busy50%锁定；权限、账号与收藏写入仍由原在线详情流程决定。
- [搜索来源resolver](../../../lib/foundation/local_search_cover.dart)：独立于元数据匹配，复用LocalLibraryManager与OnlineImageManager，不依赖收藏UI私有静态缓存；来源列表有界，读取和解码失败可转到后续允许来源。
- [统一本地搜索页](../../../lib/pages/local_search_page.dart)：下载／收藏卡片传imageProvider并启用现有双轴CoverDecodeTarget，搜索结果匹配、排序、范围和打开目标保持原逻辑。
- [图集／插画页](../../../lib/pages/local_library_page.dart)：只在filtered列表身份变化时清旧可见集合，完成provider保留；相同过滤条件列表身份稳定，正常滚动不会每帧清任务。
- 回归新增或扩充：[爱心真实壳](../../../test/pixiv_detail_favorite_visibility_test.dart)、[在线详情](../../../test/pixiv_online_detail_scroll_test.dart)、[搜索实际封面](../../../test/local_search_cover_recovery_test.dart)、[图集／插画内联](../../../test/local_library_search_cover_test.dart)、[已下载内联](../../../test/download_managed_cover_recovery_test.dart)。

封面身份包含来源／作品／路径／manager版本、网络URL、headers摘要与会话／服务代次；不按标题共享。页面provider缓存最多128条，单源几何target最多8条；解码沿用4096边长／4Mi像素上限，原有本地卡片最多一次5秒自动恢复。完成图可复用，不能把取消工作当作失败再启动下一来源。待完成provider必须单独跟踪，LRU逐出不能让离页取消失去所有权。实际source／codec工作收尾前不伪报已释放资源。

## 已验证的操作矩阵

| 范围 | 实际验证 |
| --- | --- |
| 029首屏与几何 | 短横图、高视口／横屏、安全区、DPR／大字、不可滚动、回弹、无图片、实际解码比例与旋转；检查实际opacity／scale和tap／long press |
| 029滚动与状态 | 同一指针跨边界往返、hidden实际SemanticsNode无访问动作且不命中；busy完成保留真实saved态；mock公开／私密写成功、失败、能力false／未知、账号变化、未登录账号页往返 |
| 下载页内联 | 实际点击搜索、输入匹配／零结果／清空、等待280ms防抖，检查同一manager provider、来源ID与绿色像素；派生删除／重新加载仍走已有恢复 |
| 图集内联 | 真实本地目录子页，关键词匹配／零结果／清空恢复，检查manager provider及各作品真实像素 |
| 插画内联 | 空结果后旧排队源不再准入，在途句柄收尾；新匹配作品优先且迟到源不串卡片；作者过滤／清空复用已完成provider；关键词＋标签＋Alpha／Beta目录交集与恢复 |
| 远程对照 | 既有loopback provider验证服务声明尺寸、横图档位升级、DPR与编码缓存隔离、实际解码图尺寸；不是完整远程GUI搜索UAT |

029最终两文件26项通过（14壳／12在线，净新增21）；六个既有详情／会话／本地入口文件71项通过，文件无重叠，合计97个不同用例；根任务将这八文件统一复跑仍97项全部通过。[统一97项](D:/picakeep-pixiv-fixes-029-030-work/logs/final-029-suite.log)、[029清单与SHA](D:/picakeep-pixiv-fixes-029-030-work/logs/favorite-validation-manifest.json)。

030专项17项封面实际像素／生命周期测试、scope7项通过；根最终十文件统一82项全部通过，包含内联4项、已下载扩展原case、online manager4项、local cache／tile恢复／decode target／remote target／work queue。[最终82项](D:/picakeep-pixiv-fixes-029-030-work/logs/final-030-suite-after.log)。与扩展封面180项有重叠，不能把批次相加。产品四文件及测试六文件统一静态分析无问题、format零修改；[分析](D:/picakeep-pixiv-fixes-029-030-work/logs/final-analyze-after.log)、[格式](D:/picakeep-pixiv-fixes-029-030-work/logs/final-format-after.log)。完整命令及SHA见[最终清单](D:/picakeep-pixiv-fixes-029-030-work/logs/final-validation-manifest.json)。

最终命令（均为`--no-pub --concurrency=1 --reporter expanded`，任务TEMP／TMP隔离）：

```powershell
flutter test --no-pub --concurrency=1 --reporter expanded test/pixiv_detail_favorite_visibility_test.dart test/pixiv_online_detail_scroll_test.dart test/pixiv_detail_shell_test.dart test/pixiv_detail_session_test.dart test/pixiv_comic_page_test.dart test/local_comic_detail_info_layout_test.dart test/local_comic_detail_tag_display_test.dart test/local_comic_detail_online_entry_test.dart
flutter test --no-pub --concurrency=1 --reporter expanded test/local_search_cover_recovery_test.dart test/local_library_search_cover_test.dart test/download_managed_cover_recovery_test.dart test/online_image_manager_test.dart test/local_search_page_scope_test.dart test/local_cover_cache_test.dart test/comic_tile_cover_recovery_test.dart test/cover_decode_target_test.dart test/remote_cover_target_test.dart test/illust_work_queue_test.dart
flutter test --no-pub --concurrency=1 --reporter expanded test/cover_decode_target_test.dart test/comic_tile_cover_density_test.dart test/comic_tile_cover_recovery_test.dart test/local_cover_cache_test.dart test/local_favorite_cover_open_test.dart test/online_image_manager_test.dart test/local_library_illust_view_test.dart test/illust_card_info_config_test.dart test/illust_card_info_editor_test.dart
```

## 验证过程中的问题

首轮隐藏语义检查曾以Widget finder误读ExcludeSemantics内部Element仍存在，改为遍历实际SemanticsNode；没有为此修改产品行为。短在线详情会进入评论区，夹具只接受评论GET并返回空列表，无socket或真实收藏写入。

扩展封面套件的第一轮为178通过／2失败；两个失败都在未改过的`online_image_manager_test.dart`：200响应先进入磁盘准入，测试没有注册任务卷空间probe，原生桥在该单测不可用，抛ImageDiskQuotaExceeded而挡住原SocketException／共享字节断言。[原扩展日志](D:/picakeep-pixiv-fixes-029-030-work/logs/root-cover-regression.log)。保留该失败记录，修正仅限既有测试隔离，不能放宽生产配额或删除原断言。

仅测试夹具安装现有任务磁盘probe，并在drain后恢复override；原四项行为断言全部保留。[夹具修后4项](D:/picakeep-pixiv-fixes-029-030-work/logs/online-manager-after.log)及[扩展九文件复跑180项](D:/picakeep-pixiv-fixes-029-030-work/logs/root-cover-regression-after.log)均通过，不把重叠批次相加。

030扩展验证暴露取消后ImageCache残留／快速同源重入，以及真正首帧失败的解码边界。隔离原生探针24个阶段中，16个Codec创建成功、首帧才失败；最小PNG为有效图前49字节，SHA256 `085203079da2540cfbbc977a6de25360638723fe6d0163dbf30cee27a9d9e944`。这确认只在`await decode(buffer)`外catch不足以实现计划中的坏图回退；[阶段探针](D:/picakeep-pixiv-fixes-029-030-work/logs/favorite-decode-phase-probe.log)。最终产品候选预取首帧并回放，真实卡片坏PNG→合法URL参考像素、GIF红／蓝／红、离页／清空／LRU淘汰取消及同词新请求均在82项中通过。后续动画帧失败仍走原错误处理，未宣称中途自动换源。

扩展期间管理／归档case跨Widget FakeAsync使串行保存Future停在旧测试zone，单测通过；修夹具以runAsync驱动实际IO／frame，未重置产品cache或删断言。404重试Timer在真实zone创建，改真实等待5.2秒核两次封顶。首个组合为80通过／2失败，纯元数据无封面仍访问App.dataPath；来源为空提前返回后原scope7及最终82项均通过。[组合修前记录](D:/picakeep-pixiv-fixes-029-030-work/logs/final-030-suite.log)保留；最终静态分析前删三处无用import及补if block，全部十文件分析通过。

## 真实设备与未验证边界

本轮不要求APK构建或安装；用户手机上的旧包不会因源码修改自行更新。最后两机正常包仍为历史`1.9.92+9` Profile `C1BB13A7…`，本轮工作区版本`1.9.93+10`。未清用户缓存／数据库／原件，封面生成、网络与写操作均为隔离夹具或mock。

未验证：用户历史故障素材／具体入口、真实Android动画与高刷新率、真实网络账号与尾延迟、受限Root／Shizuku桥、真实密码归档、远程图集完整GUI、桌面UI及当前全项目完整回归。本轮不保证源确已删除、真实密码／权限拒绝或网络故障时仍可显示封面，不以本次修复宣布022全部验收或所有性能达标。

## 接手经验

首屏可达性、遮挡、命中和语义须分别验；共享壳不承担账号能力放宽。搜索匹配有元数据不代表派生封面有效，来源解析应在显示层复用原manager。provider非空不代表像素可用，回退必须覆盖异步解码失败。过滤零结果后新布局不会发生，需要显式撤销旧准入并保留完成缓存。取消也涉及Flutter pending／live ImageStreamCompleter及源代次，须验证同源快速重入，不能只观察旧结果最后没出现在屏幕上。上述结论来源为本次失败夹具、源代码与实际像素／资源检查；设备体验和网络性能保持独立证据边界。
