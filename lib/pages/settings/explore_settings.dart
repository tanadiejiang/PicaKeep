
// ignore_for_file: avoid_unused_constructor_params, unused_element, no_leading_underscores_for_local_identifiers

part of 'settings_page.dart';

Widget buildExploreSettings(double width, BuildContext context) {
  return buildTwoColumnLayout(width, [
        // 分区依据 = **该设置实际改变页面上的哪一块**（用户第 4 点：「按实际功能
        // 区块分区」）。所以「浏览列表 / 布局」「卡片显示」「插画瀑布流」是三个
        // 独立分区，而不是笼统的"漫画卡片"。
        //
        // ⚠️ 历史沿革：本页原来只有 6 个分区（启动与列表 / 漫画卡片 / 在线浏览 /
        // 阅读器 / 内容过滤 / 其它）。本轮重新分区**只动分区标题的归属**，
        // 不增删任何设置项，也不改变各设置项的 `settingsIndex`
        // （移动设置项位置会改变用户已习惯的入口，24 号计划决策 4 明确禁止）。
        SettingsTitle('启动与运行'.tl),
        SelectSetting(
          title: "初始页面".tl,
          settingsIndex: 23,
          values: const ["0", "1"],
          titles: ["我".tl, "收藏".tl],
        ),
        SettingsTitle('列表与视图'.tl),
        SelectSetting(
          title: "漫画列表显示方式".tl,
          settingsIndex: 25,
          values: const ["0", "1"],
          titles: ["连续".tl, "分页".tl],
        ),
        SettingsTitle('卡片显示'.tl),
        SelectSetting(
          title: "漫画块显示模式".tl,
          settingsIndex: 44,
          values: const ["0", "1"],
          titles: ["详细".tl, "简略".tl],
          onChanged: (value) {
            appdata.appSettings.comicTileDisplayType = int.parse(value);
          },
        ),
        ListTile(
          title: Text("漫画块大小".tl),
          subtitle: const _ComicTileSizeSlider(),
        ),
        SelectSetting(
          title: "漫画块缩略图布局".tl,
          settingsIndex: 66,
          values: const ["0", "1"],
          titles: ["覆盖".tl, "容纳".tl],
        ),
        SwitchSetting(
          title: "显示收藏状态".tl,
          settingsIndex: 72,
        ),
        SwitchSetting(
          title: "显示阅读位置".tl,
          settingsIndex: 73,
        ),
        NewPageSetting(
          title: "卡片信息显示".tl,
          page: const ComicCardDisplaySetting(),
        ),
        // 插画视图（图集页的「插画」并列视图）专属：瀑布流列数与悬浮切换按钮位置。
        // 与「卡片显示」分开，是因为它们只作用于插画瀑布流，不作用于漫画卡片。
        SettingsTitle('插画列表'.tl),
        SelectSetting(
          title: "瀑布流列数".tl,
          settingsIndex: illustWaterfallColumnsSettingIndex,
          values: const ["2", "3"],
          titles: const ["2", "3"],
          onChanged: (_) => App.notifyDisplaySettingsChanged(),
        ),
        SelectSetting(
          title: "视图切换按钮位置".tl,
          settingsIndex: illustViewSwitcherPositionSettingIndex,
          values: const [illustViewSwitcherRight, illustViewSwitcherLeft],
          titles: ["靠右".tl, "靠左".tl],
          // 按钮位置现在由 `Scaffold.floatingActionButtonLocation` 决定，
          // 而它在图集页的 `build` 里读 —— 设置页 pop 回去不重建那一页，
          // 不通知就会出现"选了靠左、返回后还在右边"。
          onChanged: (_) => App.notifyDisplaySettingsChanged(),
        ),
        // 卡片底部显示哪些信息（`settings[158]`）。交互形态与「下载目录名模板」
        // 一致（勾选 + 拖拽排序 + 预览），用户明确要求"和下载命名一样可以自由选择"。
        const _IllustCardInfoTile(),
        SettingsTitle('在线浏览'.tl),
        SelectSetting(
          title: "浏览时远程图片并发".tl,
          settingsIndex: remoteBrowseImageConcurrencySettingIndex,
          controlWidth: 120,
          values: const [
            "1",
            "2",
            "3",
            "4",
            "5",
            "6",
            "7",
            "8",
            "9",
            "10",
            "11",
            "12"
          ],
          titles: const [
            "1",
            "2",
            "3",
            "4",
            "5",
            "6",
            "7",
            "8",
            "9",
            "10",
            "11",
            "12"
          ],
        ),
        SettingsTitle('阅读器'.tl),
        SwitchSetting(
          title: "启用侧边翻页栏".tl,
          settingsIndex: 64,
        ),
        SettingsTitle('内容过滤'.tl),
        NewPageSetting(
          title: "关键词屏蔽".tl,
          page: const KeywordBlockingSetting(),
        ),
        SwitchSetting(
          title: "完全隐藏屏蔽的作品".tl,
          settingsIndex: 83,
        ),
        SettingsTitle('其它'.tl),
        ListTile(
          title: Text("图片收藏大小".tl),
          subtitle: const _ImageFavoriteSizeSlider(),
        ),
        SwitchSetting(
          title: "检查剪切板中的链接".tl,
          settingsIndex: 61,
        ),
  ]);
}

/// Slider whose thumb tracks the finger in real time. The plain inline Slider
/// read its value straight from `appdata.settings`, but `buildExploreSettings`
/// is a stateless function, so dragging triggered no rebuild and the thumb only
/// jumped to the new position when something else rebuilt the page. Holding the
/// drag value in local state and setState-ing on change makes it follow.
class _ComicTileSizeSlider extends StatefulWidget {
  const _ComicTileSizeSlider();

  @override
  State<_ComicTileSizeSlider> createState() => _ComicTileSizeSliderState();
}

class _ComicTileSizeSliderState extends State<_ComicTileSizeSlider> {
  static double _readValue() {
    final parts = appdata.settings[44].split(',');
    final raw = parts.length == 2 ? parts[1] : "1.0";
    return (double.tryParse(raw) ?? 1.0).clamp(0.5, 1.5);
  }

  late double _value = _readValue();

  void _write(double value) {
    var values = appdata.settings[44].split(',');
    if (values.length != 2) {
      values = ['0', '1.0'];
    }
    values[1] = value.toStringAsFixed(2);
    appdata.settings[44] = values.join(',');
    appdata.updateSettings();
  }

  @override
  Widget build(BuildContext context) {
    return Slider(
      value: _value,
      min: 0.5,
      max: 1.5,
      divisions: 20,
      label: _value.toStringAsFixed(2),
      onChanged: (value) {
        setState(() => _value = value);
        _write(value);
      },
    );
  }
}

class _ImageFavoriteSizeSlider extends StatefulWidget {
  const _ImageFavoriteSizeSlider();

  @override
  State<_ImageFavoriteSizeSlider> createState() =>
      _ImageFavoriteSizeSliderState();
}

class _ImageFavoriteSizeSliderState extends State<_ImageFavoriteSizeSlider> {
  late double _value =
      (double.tryParse(appdata.settings[74]) ?? 1.0).clamp(0.5, 1.5);

  void _write(double value) {
    appdata.settings[74] = value.toStringAsFixed(1);
    appdata.updateSettings();
  }

  @override
  Widget build(BuildContext context) {
    return Slider(
      value: _value,
      min: 0.5,
      max: 1.5,
      divisions: 10,
      label: _value.toStringAsFixed(1),
      onChanged: (value) {
        setState(() => _value = value);
        _write(value);
      },
    );
  }
}

class KeywordBlockingSetting extends StatefulWidget {
  const KeywordBlockingSetting({super.key});

  @override
  State<KeywordBlockingSetting> createState() => _KeywordBlockingSettingState();
}

class _KeywordBlockingSettingState extends State<KeywordBlockingSetting> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "关键词屏蔽".tl,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: InputDecoration(
                      hintText: "输入关键词".tl,
                    ),
                    onSubmitted: (value) {
                      _addKeyword(value);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () {
                    _addKeyword(_controller.text);
                  },
                  child: Text("添加".tl),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: appdata.blockingKeyword.length,
              itemBuilder: (context, index) {
                return ListTile(
                  title: Text(appdata.blockingKeyword[index]),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete),
                    onPressed: () {
                      _removeKeyword(index);
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _addKeyword(String keyword) {
    if (keyword.trim().isEmpty) return;
    if (appdata.blockingKeyword.contains(keyword.trim())) return;
    setState(() {
      appdata.blockingKeyword.add(keyword.trim());
    });
    _controller.clear();
    appdata.updateSettings();
  }

  void _removeKeyword(int index) {
    setState(() {
      appdata.blockingKeyword.removeAt(index);
    });
    appdata.updateSettings();
  }
}
