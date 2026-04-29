import 'package:flutter/material.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/tools/translations.dart';
import 'package:picakeep/components/select.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/local_favorites.dart';

part 'app_settings.dart';
part 'explore_settings.dart';
part 'reading_settings.dart';
part 'local_favorite_settings.dart';

class SettingsPage extends StatefulWidget {
  static void open([int initialPage = -1]) {
    App.globalTo(() => SettingsPage(initialPage: initialPage));
  }

  const SettingsPage({this.initialPage = -1, super.key});

  final int initialPage;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int _currentPage = -1;

  final _categories = <String>["浏览", "阅读", "外观", "本地收藏", "APP", "关于"];

  final _icons = <IconData>[
    Icons.explore,
    Icons.book,
    Icons.color_lens,
    Icons.collections_bookmark_rounded,
    Icons.apps,
    Icons.info,
  ];

  @override
  void initState() {
    super.initState();
    _currentPage = widget.initialPage;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("设置"),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => App.globalBack(),
        ),
      ),
      body: Row(
          children: [
          SizedBox(
            width: 180,
            child: _buildCategoryList(),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: _currentPage == -1
                ? const Center(child: Text("请选择一个设置类别"))
                : _buildPage(_currentPage),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryList() {
    return ListView.builder(
      itemCount: _categories.length,
      itemBuilder: (context, index) {
        final selected = index == _currentPage;
        return ListTile(
          leading: Icon(_icons[index]),
          title: Text(_categories[index]),
          selected: selected,
          selectedTileColor: Theme.of(context).colorScheme.primaryContainer,
          onTap: () => setState(() => _currentPage = index),
        );
      },
    );
  }

  Widget _buildPage(int index) {
    switch (index) {
      case 0:
        return buildExploreSettings(context);
      case 1:
        return const ReadingSettings();
      case 2:
        return _buildAppearanceSettings();
      case 3:
        return const LocalFavoritesSettings();
      case 4:
        return buildAppSettings(context);
      case 5:
        return _buildAbout();
      default:
        return const SizedBox();
    }
  }

  Widget _buildAppearanceSettings() {
    return Scaffold(
      body: ListView(
        children: [
          const SettingsTitle("外观"),
          ListTile(
            leading: const Icon(Icons.dark_mode),
            title: const Text("深色模式"),
            trailing: Select(
              initialValue: appdata.settings[32],
              values: const ["0", "1", "2"],
              titles: const ["跟随系统", "禁用", "启用"],
              onChanged: (value) {
                appdata.settings[32] = value;
                appdata.updateSettings();
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAbout() {
    return Scaffold(
      body: ListView(
        children: const [
          SizedBox(height: 32),
          Center(
            child: Icon(Icons.info_outline, size: 64),
          ),
          SizedBox(height: 16),
          Center(
            child: Text(
              "PicaKeep",
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
          ),
          Center(
            child: Text("本地漫画阅读器 / 收藏管理器"),
          ),
          SizedBox(height: 16),
          Center(
            child: Text("V1.0.0"),
          ),
        ],
      ),
    );
  }
}

class SwitchSetting extends StatefulWidget {
  const SwitchSetting({
    super.key,
    required this.title,
    this.subTitle,
    required this.settingsIndex,
  });

  final String title;
  final String? subTitle;
  final int settingsIndex;

  @override
  State<SwitchSetting> createState() => _SwitchSettingState();
}

class _SwitchSettingState extends State<SwitchSetting> {
  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(widget.title),
      subtitle: widget.subTitle != null ? Text(widget.subTitle!) : null,
      trailing: Switch(
        value: appdata.settings[widget.settingsIndex] == '1',
        onChanged: (value) {
          setState(() {
            appdata.settings[widget.settingsIndex] = value ? '1' : '0';
            appdata.updateSettings();
          });
        },
      ),
    );
  }
}

class SelectSetting extends StatefulWidget {
  const SelectSetting({
    super.key,
    required this.title,
    required this.settingsIndex,
    required this.values,
    required this.titles,
    this.onChanged,
  });

  final String title;
  final int settingsIndex;
  final List<String> values;
  final List<String> titles;
  final void Function(String value)? onChanged;

  @override
  State<SelectSetting> createState() => _SelectSettingState();
}

class _SelectSettingState extends State<SelectSetting> {
  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(widget.title),
      trailing: Select(
        width: 140,
        initialValue: appdata.settings[widget.settingsIndex],
        values: widget.values,
        titles: widget.titles,
        onChanged: (value) {
          setState(() {
            appdata.settings[widget.settingsIndex] = value;
            appdata.updateSettings();
          });
          widget.onChanged?.call(value);
        },
      ),
    );
  }
}

class SettingsTitle extends StatelessWidget {
  const SettingsTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(
        text,
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
    );
  }
}

class NewPageSetting extends StatelessWidget {
  const NewPageSetting({
    super.key,
    required this.title,
    required this.page,
  });

  final String title;
  final Widget page;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title),
      trailing: const Icon(Icons.arrow_right),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => page),
        );
      },
    );
  }
}

class PopUpWidgetScaffold extends StatelessWidget {
  const PopUpWidgetScaffold({
    super.key,
    required this.title,
    required this.child,
  });

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            }
          },
        ),
      ),
      body: child,
    );
  }
}
