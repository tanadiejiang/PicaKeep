# 第十九轮 001 · 插画搜索面板收起按钮与标签搜索（验证记录）

- 执行者：执行 AI（第十九轮会话，用户在场逐步反馈）
- 时间：2026-10-04 11:23 → 11:40
- 计划：[Z-plan/新需求-主线-第十九轮/01-计划-插画搜索面板收起按钮与标签搜索.md](../../../Z-plan/新需求-主线-第十九轮/01-计划-插画搜索面板收起按钮与标签搜索.md)
- 分支：`main`（基线提交 `83a47ff`，本轮改动**未提交**）

## 1. 环境与门槛结果

| 项目 | 结果 |
| --- | --- |
| Flutter / Dart | 3.41.6 stable / 3.11.4 |
| 基线（改动前）`flutter test` | **2351 通过 / 14 跳过 / 0 失败** |
| 终态 `flutter test` | **2363 通过 / 14 跳过 / 0 失败**（+12 = 新增 `test/illust_search_match_test.dart`） |
| `flutter analyze` | **No issues found**（11.8s） |
| `flutter build apk --profile` | **成功**（末次 Gradle `assembleProfile` 85.9s） |
| 安装 / 清数据 | **未安装、未清数据**（用户未要求上机） |

复跑命令：

```powershell
Set-Location 'D:\Flutter_Projucts\PicaComic\PicaKeep'
flutter analyze
flutter test
flutter test test/illust_search_panel_test.dart test/illust_search_match_test.dart
flutter test tool/_tmp_experience_preview19_test.dart   # 重新生成下面的预览图
flutter build apk --profile
```

## 2. 产物身份

- **APK（对应当前代码）**：`build/verification/illust-search-19/app-after19-profile.apk`
  - 来源：`build/app/outputs/flutter-apk/app-profile.apk`
  - 大小：150,441,459 字节（143.5 MB）
  - SHA256：`C8A7CEDF1716B16325A6985AFF6A8852DA4EF6EC9DE4AE59AB542FE291EF53E3`
  - 构建时间：2026-10-04 11:40
  - ⚠️ 中途曾用同一路径放过一版 123.3 MB 的包（`1427A2B8…`），那版**不含**后来的"开关搬到「标签」标题行 / 底部按钮悬浮化"改动，已被此版覆盖；如需复现差异，请以本文件哈希为准。
- **真实组件预览**（widget test 直接渲染真实组件，不是截屏、不是生成图）：
  - `01-expanded-match-tags-off.png` 展开态（开关关）
  - `02-expanded-match-tags-on.png` 展开态（开关开）
  - `03-collapsed-with-filter.png` 折叠摘要态（有活跃筛选）
  - `04-narrow-large-text.png` 320dp + 1.6 字号（防溢出证据）
  - 生成脚本：`tool/_tmp_experience_preview19_test.dart`（被 `.gitignore` 的 `tool/_tmp_*` 忽略，属本地工具）；脚本内同时断言 `takeException() == null`。

## 3. 改了什么（对照计划步骤）

| 步骤 | 内容 | 文件 |
| --- | --- | --- |
| 1 | 新设置索引 163 + 归一化 + 布尔读取 + 关键词匹配纯函数 | `lib/foundation/local_library_illust_view.dart`、`lib/base.dart`（数组项 + `readSettings` / `readDataFromJson` 两处归一化） |
| 2 | 面板**右下角悬浮**「收起搜索」（与工具栏 × 等价） | `lib/pages/illust_search_panel.dart` |
| 3 | 「搜标签」开关（默认关，位于「标签」标题行右侧） | 同上 |
| 4 | `AnimatedSize` 展开/收起过渡（220ms / easeOutCubic / 零高非空 child） | 同上 |
| 5 | 父页面接线 + `_setIllustSearchMatchTags`（写 settings、落盘、发显示设置通知） | `lib/pages/local_library_page.dart` |
| 6 | 关键词按开关匹配标签 + 缓存键并入开关值 | 同上 |
| 7 | 设置区两处入口（设置页「插画列表」区 + 页内「资源库显示设置」） | `lib/pages/settings/explore_settings.dart`、`lib/pages/local_library_page.dart` |
| 8 | 图集侧标题 `AnimatedSwitcher` + 工具栏搜索图标切换（200ms） | `lib/pages/local_library_page.dart` |
| 9 | 新文案 `.tl` 与 `zh_TW` / `en_US` 译文（键含 `搜标签`、`搜索同时匹配标签` 等） | `assets/translation.json` |
| 10 | 测试同步与新增；56 号预览脚本补新参数 | `test/illust_search_panel_test.dart`、`test/illust_search_match_test.dart`、`tool/_tmp_experience_preview56_test.dart` |

## 4. 验收对照（计划「验收标准」逐条）

1. 收起按钮：展开态右下角**悬浮**出现「收起搜索」（01/02 图），点击走 `onCollapse` → 与工具栏 × 同一状态位（`_searchMode=false`）；面板测试断言 `collapseCount == 1` 且面板高度归零。
2. 展开入口：折叠且有筛选时摘要行保留、可点开（03 图）；展开为高度渐变。
3. 过渡动画：面板 220ms 高度过渡；图集侧标题与图标 200ms 交叉淡化。**真机观感未验证**（§5）。
4. 动画不破坏交互：窄屏 320dp + 1.6 字号用例 `takeException() == null` 通过；预览脚本同样断言无异常。
5. 搜标签开关：默认关；关闭时匹配范围与改动前一致（纯函数用例覆盖"只命中标签不算命中"）。
6. 开关生效：`illustEntryMatchesKeyword(..., matchTags: true)` 命中标签（子串、大小写不敏感）；页面计数随 `_filteredIllustEntries` 自动更新。
7. 持久化：写 `settings[163]` + `updateSettings()`；归一化用例覆盖 `null`/`'0'`/`'1'`/脏值。**跨重启真机验证未做**（§5）。
8. 设置区入口：设置页「插画列表」区 `SwitchSetting` + 页内「资源库显示设置」`SwitchListTile`（仅插画视图），三处共用 `_setIllustSearchMatchTags`。
9. 不回归：工具栏仍 4 个 action（`local_library_page_view_scope_test.dart` 通过）；全量 0 失败。
10. 门槛：见 §1。
11. 窄屏大字不溢出：面板测试第二个用例 + 预览 04 图均无 overflow。

## 5. 明确未覆盖 / 待验（真机项）

- **未安装 APK、未清数据**，以下只能等真机：
  - 展开/收起动画的实际流畅度（尤其瀑布流逐帧重排时的观感）；
  - 图集侧标题 ↔ 搜索框过渡期间**快速连点搜索按钮**是否出现两个 `TextField` 共用同一 `_searchController` 的光标/选区异常；
  - 开关跨应用重启后是否保持；
  - 键盘弹出与标题过渡同时发生时的观感。
- 本轮**未处理**（计划「额外发现的问题」已记录）：多选态整体移除搜索面板 sliver、关键词输入无防抖、图集侧与插画侧"收起是否清空关键词"不一致、插画筛选不跨重启。
- 悬浮方案的固有取舍：窄屏 + 大字号下，标签区可视区域的**右下角最后一行**会被悬浮按钮压住（滚动即可看到，滚动内容底部已留 30 让最后一行能滚到按钮上方）。

## 6. 与计划正文不一致之处（执行中按用户反馈调整，计划原文按"已执行保护"未改）

1. **开关提示文案**：计划写「搜索含标签」，用户要求精简为「**搜标签**」，已改（译文键同步为 `搜标签` / `搜標籤` / `Search tags`）。
2. **开关位置**：计划放在搜索框下方独立一行；用户指定放到「**标签」标题行右侧**（省掉一整行），已改；Key 移到 `Switch.adaptive` 上，测试用 Key 定位。
3. **底部动作悬浮化**：计划是"占一行的 `Wrap`"；用户要求「把折叠按钮做成悬浮按钮，让那块也能显示内容」，已改为 `Stack` + 左下/右下两个 `Positioned` 悬浮胶囊；标签区上限 240 → 288（正好是原按钮行高度），滚动内容底部留 30。
4. **计划未写到、实测才发现的坑**：裸 `Wrap(alignment: spaceBetween)` 放在 `Column(crossAxisAlignment: start)` 里会收缩成内容宽度 → 按钮跑到左下角；必须外包 `SizedBox(width: double.infinity)`（悬浮化后该行已删除，但同类布局仍需注意）。
