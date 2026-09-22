import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/pages/settings/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('flutter_display_mode');
const _modes = [
  {'id': 1, 'width': 1080, 'height': 2400, 'refreshRate': 60.0},
  {'id': 2, 'width': 1080, 'height': 2400, 'refreshRate': 120.0},
  {'id': 3, 'width': 1440, 'height': 3200, 'refreshRate': 144.0},
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String originalSetting;
  late List<MethodCall> calls;

  Future<Object?> handleCall(MethodCall call) async {
    calls.add(call);
    return switch (call.method) {
      'getSupportedModes' => _modes,
      'getActiveMode' => _modes.first,
      _ => null,
    };
  }

  setUp(() {
    originalSetting = appdata.settings[38];
    calls = [];
    App.debugDisplayModeAndroidOverride = true;
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, handleCall);
  });

  tearDown(() {
    appdata.settings[38] = originalSetting;
    App.debugDisplayModeAndroidOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  List<Object?> preferredModeIds() => calls
      .where((call) => call.method == 'setPreferredMode')
      .map((call) => (call.arguments as Map)['mode'])
      .toList();

  test('disabled high refresh follows system automatic mode, never forces 60Hz',
      () async {
    appdata.settings[38] = '0';
    await App.applyDisplayModePreference();
    expect(calls.map((call) => call.method), ['setPreferredMode']);
    expect(preferredModeIds(), [0]);
  });

  test('enabled high refresh chooses highest rate at the current resolution',
      () async {
    appdata.settings[38] = '1';
    await App.applyDisplayModePreference();
    expect(preferredModeIds(), [2]);
  });

  test(
      'an in-flight high refresh request cannot win over a later automatic one',
      () async {
    final discoveryStarted = Completer<void>();
    final supported = Completer<List<Map<String, Object>>>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'getSupportedModes') {
        calls.add(call);
        discoveryStarted.complete();
        return supported.future;
      }
      return handleCall(call);
    });
    appdata.settings[38] = '1';
    final high = App.applyDisplayModePreference();
    await discoveryStarted.future;
    appdata.settings[38] = '0';
    final automatic = App.applyDisplayModePreference();
    supported.complete(_modes);
    await Future.wait([high, automatic]);
    expect(preferredModeIds(), [2, 0]);
  });

  test('rapid queued changes coalesce to the final preference', () async {
    appdata.settings[38] = '1';
    final first = App.applyDisplayModePreference();
    appdata.settings[38] = '0';
    final second = App.applyDisplayModePreference();
    appdata.settings[38] = '1';
    final last = App.applyDisplayModePreference();
    await Future.wait([first, second, last]);
    expect(preferredModeIds(), [2]);
  });

  test('a failed platform request does not block later preferences', () async {
    var fail = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      if (fail) throw PlatformException(code: 'unsupported');
      return handleCall(call);
    });
    appdata.settings[38] = '1';
    await App.applyDisplayModePreference();
    fail = false;
    appdata.settings[38] = '0';
    await App.applyDisplayModePreference();
    expect(preferredModeIds(), [0]);
  });

  test('non-Android platforms do not invoke the display-mode plugin', () async {
    App.debugDisplayModeAndroidOverride = false;
    await App.applyDisplayModePreference();
    expect(calls, isEmpty);
  });

  testWidgets('reading setting applies both switch directions immediately',
      (tester) async {
    appdata.settings[38] = '0';
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: ReadingSettings(width: 360)),
      ),
    ));
    final setting = find.byWidgetPredicate(
        (widget) => widget is SwitchSetting && widget.settingsIndex == 38);
    final toggle = find.descendant(of: setting, matching: find.byType(Switch));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(appdata.settings[38], '1');
    expect(preferredModeIds(), [2]);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(appdata.settings[38], '0');
    expect(preferredModeIds(), [2, 0]);
  });
}
