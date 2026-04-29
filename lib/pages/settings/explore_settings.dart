
// ignore_for_file: avoid_unused_constructor_params, unused_element, no_leading_underscores_for_local_identifiers

part of 'settings_page.dart';

Widget buildExploreSettings(BuildContext context) {
  return Scaffold(
    body: ListView(
      children: [
        SettingsTitle("浏览".tl),
        SelectSetting(
          title: "初始页面".tl,
          settingsIndex: 23,
          values: const ["0", "1"],
          titles: ["我".tl, "收藏".tl],
        ),
        SelectSetting(
          title: "漫画列表显示方式".tl,
          settingsIndex: 25,
          values: const ["0", "1"],
          titles: ["连续".tl, "分页".tl],
        ),
        NewPageSetting(
          title: "关键词屏蔽".tl,
          page: const KeywordBlockingSetting(),
        ),
        SwitchSetting(
          title: "完全隐藏屏蔽的作品".tl,
          settingsIndex: 83,
        ),
        SwitchSetting(
          title: "启用侧边翻页栏".tl,
          settingsIndex: 64,
        ),
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
          subtitle: Slider(
            value: double.parse(
                    appdata.settings[44].split(',').length == 2
                        ? appdata.settings[44].split(',')[1]
                        : "1.0")
                .clamp(0.5, 1.5),
            min: 0.5,
            max: 1.5,
            divisions: 20,
            label: (double.parse(
                        appdata.settings[44].split(',').length == 2
                            ? appdata.settings[44].split(',')[1]
                            : "1.0")
                    .clamp(0.5, 1.5))
                .toStringAsFixed(2),
            onChanged: (value) {
              _setSliderValue(value);
            },
          ),
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
        ListTile(
          title: Text("图片收藏大小".tl),
          subtitle: Slider(
            value: double.tryParse(appdata.settings[74]) ?? 1.0,
            min: 0.5,
            max: 1.5,
            divisions: 10,
            label: (double.tryParse(appdata.settings[74]) ?? 1.0)
                .toStringAsFixed(1),
            onChanged: (value) {
              _setImageFavoriteSize(value);
            },
          ),
        ),
        SwitchSetting(
          title: "检查剪切板中的链接".tl,
          settingsIndex: 61,
        ),
      ],
    ),
  );
}

void _setSliderValue(double value) {
  var values = appdata.settings[44].split(',');
  if (values.length != 2) {
    values = ['0', '1.0'];
  }
  values[1] = value.toStringAsFixed(2);
  appdata.settings[44] = values.join(',');
  appdata.updateSettings();
}

void _setImageFavoriteSize(double value) {
  appdata.settings[74] = value.toStringAsFixed(1);
  appdata.updateSettings();
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
