import 'dart:convert';

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/pages/explore/explore_category_label_metrics.dart';

class _NonlinearScaler extends TextScaler {
  const _NonlinearScaler();

  @override
  double scale(double fontSize) =>
      fontSize <= 16 ? fontSize * 1.7 : fontSize * 1.3;

  @override
  double get textScaleFactor => 1.7;
}

class _LabelSizePreservingScaler extends TextScaler {
  const _LabelSizePreservingScaler();

  @override
  double scale(double fontSize) => fontSize == 14 ? 14 : fontSize * 1.7;

  @override
  double get textScaleFactor => 1.7;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void expectOriginalWidths(
    List<String> labels, {
    TextStyle style =
        const TextStyle(fontSize: 14, height: 20 / 14, letterSpacing: .1),
    TextScaler scaler = TextScaler.noScaling,
    TextDirection direction = TextDirection.ltr,
  }) {
    const locale = Locale('zh');
    final widths = measureCategoryLabelWidths(labels,
        style: style,
        textScaler: scaler,
        textDirection: direction,
        locale: locale);
    expect(widths.length, labels.length);
    final painter = TextPainter(
        textDirection: direction, textScaler: scaler, locale: locale);
    try {
      for (var index = 0; index < labels.length; index++) {
        painter.text = TextSpan(text: labels[index], style: style);
        painter.layout();
        expect(widths[index], closeTo(painter.width, .02),
            reason: labels[index]);
        expect(widths[index].ceilToDouble() + 32,
            painter.width.ceilToDouble() + 32,
            reason: 'Rounded button width must not change: ${labels[index]}');
      }
    } finally {
      painter.dispose();
    }
  }

  test('batch widths preserve mixed scripts, direction and scaled bold text',
      () {
    const labels = [
      'Topic',
      'Long translated topic',
      '风景与自然观察',
      'mixed 中文 and English',
      'ＡＢＣ',
      'عربي',
      'עברית',
      '123 العربية',
      'Emoji \u{1f600}',
      'e\u0301',
      'a\u200bb',
      'soft\u00adhyphen',
    ];
    for (final direction in TextDirection.values) {
      for (final scaler in const [
        TextScaler.noScaling,
        TextScaler.linear(1.3),
        TextScaler.linear(2),
        _NonlinearScaler(),
        _LabelSizePreservingScaler(),
      ]) {
        expectOriginalWidths(labels,
            direction: direction,
            scaler: scaler,
            style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                height: 20 / 14,
                letterSpacing: .1));
      }
    }
  });

  test('blank, whitespace and hard-break labels preserve standalone widths',
      () {
    const labels = [
      '',
      ' ',
      ' leading',
      'trailing ',
      ' x ',
      'trailing\u00a0',
      'multi\nline',
      'multi\r\nline',
      'vertical\vtab',
      'form\ffeed',
      'next\u0085line',
      'line\u2028separator',
      'paragraph\u2029separator',
      'a\tb',
      'normal',
      '\u202aunclosed embedding',
      '\u202bunclosed RTL embedding',
      '\u202doverride',
      '\u202ereversed',
      '\u2066unclosed LTR isolate',
      '\u2067unclosed RTL isolate',
      '\u2068unclosed first-strong isolate',
      'unmatched \u202c\u2069 pop',
      'normal after bidi controls',
      'Long label deliberately exceeding one hundred and twenty eight characters '
          'must still preserve the exact original standalone paragraph width '
          'without changing category wrapping.',
      '',
    ];
    for (final direction in TextDirection.values) {
      expectOriginalWidths(labels, direction: direction);
      expectOriginalWidths(labels,
          direction: direction, scaler: const _NonlinearScaler());
    }
    expectOriginalWidths(const []);
    expectOriginalWidths(const ['']);
    expectOriginalWidths(const ['single']);
  });

  test('button theme typography keeps the same rounded widths', () {
    const labels = [
      'office ffi',
      '0123456789',
      'Long topic with spaces',
      '大小',
      '风景与自然观察',
      'mixed 中文 and English',
      '123 العربية',
    ];
    for (final style in const [
      TextStyle(fontSize: 14, letterSpacing: .1, height: 20 / 14),
      TextStyle(fontSize: 14, letterSpacing: -.1, wordSpacing: 2),
      TextStyle(
        fontSize: 18,
        fontStyle: FontStyle.italic,
        fontWeight: FontWeight.bold,
        letterSpacing: .3,
        wordSpacing: .4,
        fontFeatures: [
          FontFeature.tabularFigures(),
          FontFeature.disable('liga')
        ],
      ),
    ]) {
      for (final direction in TextDirection.values) {
        for (final scaler in const [
          TextScaler.noScaling,
          TextScaler.linear(1.3),
          _NonlinearScaler(),
        ]) {
          expectOriginalWidths(labels,
              style: style, scaler: scaler, direction: direction);
        }
      }
    }
  });

  test('real local tag batches keep the original rounded layout widths',
      () async {
    final data = jsonDecode(await rootBundle.loadString('assets/tags.json'))
        as Map<String, dynamic>;
    for (final namespace in data.values.whereType<Map>()) {
      final firstBatch = namespace.entries.take(50).toList();
      for (final labels in [
        firstBatch.map((entry) => entry.key.toString()).toList(),
        firstBatch.map((entry) => entry.value.toString()).toList(),
      ]) {
        expectOriginalWidths(labels,
            style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                height: 20 / 14,
                letterSpacing: .1));
        expectOriginalWidths(labels, scaler: const TextScaler.linear(2));
      }
    }
  });
}
