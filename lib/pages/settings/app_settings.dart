
// ignore_for_file: no_leading_underscores_for_local_identifiers, unused_element

part of 'settings_page.dart';

Widget buildAppSettings(BuildContext context) {
  return Scaffold(
    body: ListView(
      children: [
        SettingsTitle("APP".tl),
        NewPageSetting(
          title: "日志".tl,
          page: const LogSetting(),
        ),
        NewPageSetting(
          title: "数据管理".tl,
          page: DataManageSetting(),
        ),
        SelectSetting(
          title: "语言".tl,
          settingsIndex: 50,
          values: const ["", "cn", "tw", "en"],
          titles: [
            "跟随系统".tl,
            "中文".tl,
            "繁体中文".tl,
            "英文".tl,
          ],
        ),
        SelectSetting(
          title: "下载目录".tl,
          settingsIndex: 22,
          values: const [""],
          titles: [
            appdata.settings[22].isEmpty
                ? "未设置".tl
                : appdata.settings[22]
          ],
        ),
        ListTile(
          title: Text("缓存大小限制".tl),
          subtitle: Text(
            "${(int.tryParse(appdata.settings[35]) ?? 500)} MB".tl,
          ),
          trailing: SizedBox(
            width: 120,
            child: Select(
              initialValue: appdata.settings[35],
              values: const [
                "100", "200", "500", "1000", "2000", "5000", "10000"
              ],
              titles: const [
                "100 MB", "200 MB", "500 MB", "1 GB",
                "2 GB", "5 GB", "10 GB"
              ],
              onChanged: (value) {
                appdata.settings[35] = value;
                appdata.updateSettings();
              },
            ),
          ),
        ),
        NewPageSetting(
          title: "权限管理".tl,
          page: const PermissionSetting(),
        ),
      ],
    ),
  );
}

class DataManageSetting extends StatelessWidget {
  DataManageSetting({super.key});

  final LocalFavoritesManager _favManager = LocalFavoritesManager();

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "数据管理".tl,
      child: ListView(
        children: [
          ListTile(
            title: Text("刷新数据".tl),
            onTap: () async {
              await appdata.readData();
              await _favManager.init();
              if (context.mounted) {
                context.pop();
              }
            },
          ),
        ],
      ),
    );
  }
}

class LogSetting extends StatelessWidget {
  const LogSetting({super.key});

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "日志".tl,
      child: const Center(
        child: Text("暂无日志"),
      ),
    );
  }
}

class PermissionSetting extends StatefulWidget {
  const PermissionSetting({super.key});

  @override
  State<PermissionSetting> createState() => _PermissionSettingState();
}

class _PermissionSettingState extends State<PermissionSetting> {
  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "权限管理".tl,
      child: ListView(
        children: [
          SettingsTitle("隐私".tl),
          SwitchSetting(
            title: "阻止屏幕截图".tl,
            settingsIndex: 12,
          ),
          SwitchSetting(
            title: "需要生物识别".tl,
            settingsIndex: 13,
          ),
        ],
      ),
    );
  }
}
