// Explicit diagnostic target, not part of the normal production test sweep.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'image_pipeline_022_color_precision_probe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('022 integer-ROI transparent intermediate precision diagnosis',
      (tester) async {
    final fixtures = Platform.environment['PICAKEEP_022_PRECISION_FIXTURES'] ??
        r'E:\picakeep-image-pipeline-022-fixtures';
    final output = Platform.environment['PICAKEEP_022_PRECISION_REPORT'] ??
        r'D:\picakeep-image-pipeline-022-work\color-precision-flutter-tester.json';
    final report = await tester.runAsync(() =>
        runImagePipeline022ColorPrecisionProbe(fixtures,
            artifactsPath: '$output-artifacts'));
    expect(report, isNotNull);
    await tester.runAsync(() async {
      final file = File(output);
      await file.parent.create(recursive: true);
      await file.writeAsString(
          const JsonEncoder.withIndent('  ').convert(report),
          flush: true);
    });
    print('PICAKEEP_022_COLOR_PRECISION_REPORT $output');
    expect(report!['errors'], isEmpty);
    expect(report['cases'], hasLength(4));
    expect(report['status'], 'measured');
    for (final item in report['cases'] as List) {
      final record = item as Map;
      expect(record['sourceUnchanged'], isTrue);
      expect((record['repeatCodecVsOriginal'] as Map)['rgba8Exact'], isTrue);
      expect(record['regions'], hasLength(2));
      for (final region in record['regions'] as List) {
        final variants = (region as Map)['variants'] as List;
        expect(variants.length, inInclusiveRange(16, 17));
        for (final variant in variants.cast<Map>().where((variant) =>
            (variant['operation'] as String).endsWith('-none') &&
            !(variant['operation'] as String).contains('overlay-twice'))) {
          expect(variant['rgba8Exact'], isTrue,
              reason: '${record['fixture']}: ${variant['operation']}');
        }
      }
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
