
// ignore_for_file: no_leading_underscores_for_local_identifiers

part of 'settings_page.dart';

class ReadingSettings extends StatelessWidget {
  const ReadingSettings({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListView(
        children: [
          SettingsTitle("阅读".tl),
          SwitchSetting(
            title: "点击屏幕左右区域翻页".tl,
            settingsIndex: 0,
          ),
          SelectSetting(
            title: "翻页方式".tl,
            settingsIndex: 9,
            values: const ["1", "2", "3", "4"],
            titles: [
              "从左向右".tl,
              "从右向左".tl,
              "从上至下".tl,
              "从上至下(连续)".tl,
            ],
          ),
          ListTile(
            title: Text("自动翻页".tl),
            trailing: SizedBox(
              width: 120,
              child: Select(
                initialValue: appdata.settings[33],
                values: const [
                  "0", "1", "2", "3", "4",
                  "5", "6", "7", "8", "9", "10"
                ],
                titles: const [
                  "禁用", "1s", "2s", "3s", "4s",
                  "5s", "6s", "7s", "8s", "9s", "10s"
                ],
                onChanged: (value) {
                  appdata.settings[33] = value;
                  appdata.updateSettings();
                },
              ),
            ),
          ),
          SwitchSetting(
            title: "使用音量键翻页".tl,
            settingsIndex: 7,
          ),
          SwitchSetting(
            title: "翻页动画".tl,
            settingsIndex: 36,
          ),
          SwitchSetting(
            title: "阅读器中保持屏幕常亮".tl,
            settingsIndex: 14,
          ),
          SwitchSetting(
            title: "宽屏时显示前进后退关闭按钮".tl,
            settingsIndex: 4,
          ),
          SwitchSetting(
            title: "夜间模式降低图片亮度".tl,
            settingsIndex: 18,
          ),
          SelectSetting(
            title: "预加载".tl,
            settingsIndex: 28,
            values: const ["0", "1", "2", "3", "4", "5"],
            titles: const [
              "禁用",
              "1页",
              "2页",
              "3页",
              "4页",
              "5页",
            ],
          ),
          SelectSetting(
            title: "阅读器图片布局方式".tl,
            settingsIndex: 41,
            values: const ["0", "1"],
            titles: ["默认".tl, "左右".tl],
          ),
          SelectSetting(
            title: "阅读器内固定屏幕方向".tl,
            settingsIndex: 76,
            values: const ["0", "1", "2"],
            titles: [
              "禁用".tl,
              "横屏".tl,
              "竖屏".tl,
            ],
          ),
          SwitchSetting(
            title: "高刷新率".tl,
            settingsIndex: 38,
          ),
          SwitchSetting(
            title: "阅读器中双击放缩".tl,
            settingsIndex: 49,
          ),
          SwitchSetting(
            title: "长按缩放".tl,
            settingsIndex: 55,
          ),
          SwitchSetting(
            title: "限制图片宽度".tl,
            settingsIndex: 43,
          ),
          SwitchSetting(
            title: "显示页面信息".tl,
            settingsIndex: 57,
          ),
          ListTile(
            title: Text("点按翻页识别范围".tl),
            subtitle: Slider(
              value: double.tryParse(appdata.settings[40]) ?? 25,
              min: 0,
              max: 50,
              divisions: 50,
              label: (double.tryParse(appdata.settings[40]) ?? 25)
                  .toStringAsFixed(0),
              onChanged: (value) {
                appdata.settings[40] = value.toStringAsFixed(0);
                appdata.updateSettings();
              },
            ),
          ),
          SwitchSetting(
            title: "反转点按识别".tl,
            settingsIndex: 70,
          ),
        ],
      ),
    );
  }
}
