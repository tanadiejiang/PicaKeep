part of 'settings_page.dart';

Widget buildAppCapabilitiesSettings(double width, BuildContext context) {
  return buildTwoColumnLayout(
    width,
    [
      ...buildAppCapabilitiesContent(context, includeOverview: false),
      Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom),
      ),
    ],
  );
}
