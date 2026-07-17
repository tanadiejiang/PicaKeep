import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/pages/settings/settings_page.dart';
import 'package:picakeep/pages/settings/untranslated_tags_page.dart';

void main() {
  testWidgets('places the untranslated tags entry after Logs', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Builder(
              builder: (context) => buildAppSettings(360, context),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final logs = find.text('Logs');
    final untranslatedTags = find.text('待翻译标签');
    final storage = find.text('存储位置');

    expect(logs, findsOneWidget);
    expect(untranslatedTags, findsOneWidget);
    expect(storage, findsOneWidget);
    expect(find.byType(NewPageSetting), findsOneWidget);
    expect(
      tester.widget<NewPageSetting>(find.byType(NewPageSetting)).page,
      isA<UntranslatedTagsPage>(),
    );
    expect(
      tester.getTopLeft(logs).dy,
      lessThan(tester.getTopLeft(untranslatedTags).dy),
    );
    expect(
      tester.getTopLeft(untranslatedTags).dy,
      lessThan(tester.getTopLeft(storage).dy),
    );
  });
}
