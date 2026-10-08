# 036 · Pixiv 收藏队列数量显示设置

本轮依据用户圈出的“3 项等待 · 0 项完成”文字，新增“设置 → 浏览 → 在线浏览 → 显示 Pixiv 收藏队列数量”，默认关闭。爱心、＋N与实际等待／结果／具体失败原因保留；开启后才显示等待、完成及失败数量。

## 可视证据

- [默认关闭](counts-off.png)：三个等待爱心和“正在提交收藏…”。
- [手动开启](counts-on.png)：同一Host、同三张票据，显示“3 项等待 · 0 项完成 · 正在提交收藏…”。

两图为实际375×180dp Flutter离线渲染；不是设备截图。历史035资料保留。设置项使用现有SwitchSetting和Appdata.settings，追加166号、'0'默认、只有'1'开启；保存到原设置文件和SharedPreferences，旧长度和无效值按关闭处理。Host监听现有显示偏好通知，更新文字时operationId、visualEpoch、队列状态及原停留计时保留。

## 验证结果

执行者：Codex · 2026-10-08 20:05 +08:00。

- 新增[设置专项测试](../../../test/pixiv_bookmark_feedback_settings_test.dart)12/12通过：真实SettingsPage第0页的在线浏览入口、默认关、实际点击开／关、控件自身SharedPreferences＋文件保存、新建Appdata重读、长度166／151／20的旧数组补齐、无效值与缺项、真实JSON导入与自发保存。
- Host等待3项时收到显示通知，控制器、票据有效性、operationId、visualEpoch、完整记录与item State不变；完成后700ms开／1999ms关仍在原2000ms结束停留。销毁后通知安全。混合失败的具体原因始终可见，读屏数量保留。
- 最终16份定向回归225/225通过，涵盖队列、生产无Scaffold导航、菜单、卡片／详情、设置分区、旧显示配置／阅读策略、导入导出。见[完整回归日志](regression.log)，结尾为 `00:28 +225: All tests passed!`。
- 11个本轮源码／测试文件定向分析为No issues found，见[分析日志](analyze.log)；设置存储和入口的git diff --check通过。

## 复跑

仓库根目录，Windows PowerShell：

```powershell
New-Item -ItemType Directory -Force .dart_tool/036-temp | Out-Null
$env:TEMP = Join-Path (Get-Location) '.dart_tool/036-temp'
$env:TMP = $env:TEMP
$tests = @(
  'test/pixiv_bookmark_feedback_settings_test.dart'
  'test/pixiv_bookmark_queue_widget_test.dart'
  'test/pixiv_bookmark_feedback_test.dart'
  'test/pixiv_bookmark_queue_integration_test.dart'
  'test/pixiv_bookmark_queue_capture_test.dart'
  'test/pixiv_bookmark_queue_reduced_host_test.dart'
  'test/explore/pixiv_bookmark_feedback_navigation_test.dart'
  'test/pixiv_network_favorites_feedback_test.dart'
  'test/explore/online_recommendation_card_test.dart'
  'test/pixiv_detail_bookmark_shared_test.dart'
  'test/pixiv_online_detail_scroll_test.dart'
  'test/settings_section_divider_test.dart'
  'test/comic_tile_display_config_test.dart'
  'test/waterfall_tag_settings_test.dart'
  'test/reader_image_pipeline_settings_test.dart'
  'test/user_data_transfer_test.dart'
)
flutter test --no-pub --concurrency=1 @tests
```

## 当场经验与范围

- 纯视图默认showCounts=false，Host从同一166号设置读取。旧纯视图数量用例明确传true以验证开启场景；实际Host默认用例断言可见文字无统计、单一读屏标签仍含数量。
- 旧的补齐边界只看readerImagePipelineSettingIndex165，长度166会跳过追加新项；改为按当前默认长度补齐167，原值保持。
- 旧文件缺166号时，不能拿当前内存值归一化：如果内存已开会错误继承。读取与导入依据原始载入数组elementAtOrNull，缺项明确关闭；保存归一化当前选择，开启可持久恢复。
- JSON测试需模拟真实jsonDecode数组；直接构造Dart List<String>会在既有导入的动态List拼接处异常。夹具改成真正编码／解码，未借此修改无关导入业务。
- 验证控件／导入自发持久化时不能额外调用updateSettings掩盖忘保存，专项实际等待自身落盘后读取。
- 显示偏好通知只重建文本，key和epoch保持，listener在Host销毁时移除。没有新增网络查询、修改Store或改变左退计时。
- 仅此数量前缀默认关闭，＋N、心形状态、真实结果、具体错误与辅助语义保留。036视图证据另存，未覆写035历史资料。
- 未构建、安装、真机运行或发真实收藏请求；本轮为离线Flutter与临时隔离设置持久化验收。
