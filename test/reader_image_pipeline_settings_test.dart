import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/reader_image_quality.dart';

void main() {
  test(
      'every old comic/illust combination migrates to sharpFirst without rewriting old values',
      () {
    for (final comic in ['0', '1']) {
      for (final illust in ['0', '1']) {
        final encoded = normalizeReaderImagePipelineSettings(null,
            legacyComic: comic, legacyIllust: illust);
        final config = ReaderImagePipelineSettings.tryParse(encoded)!;
        expect(config.comic, ReaderDisplayMode.sharpFirst);
        expect(config.illust, ReaderDisplayMode.sharpFirst);
        expect(config.legacyComic, comic);
        expect(config.legacyIllust, illust);
        expect(
            normalizeReaderImagePipelineSettings(encoded,
                legacyComic: 'changed', legacyIllust: 'changed'),
            encoded);
      }
    }
  });

  test(
      'missing/dirty legacy values remain diagnostic facts and do not cap v2 reading',
      () {
    final encoded = normalizeReaderImagePipelineSettings('invalid-json',
        legacyComic: 'dirty');
    final raw = jsonDecode(encoded);
    expect(raw['legacyQuality']['comic'], 'dirty');
    expect(raw['legacyQuality']['illust'], '<missing>');
    expect(readerDisplayMode(sourceKey: 'jm', pipelineSetting: encoded),
        ReaderDisplayMode.sharpFirst);
    expect(readerDisplayMode(sourceKey: 'pixiv', pipelineSetting: encoded),
        ReaderDisplayMode.sharpFirst);
  });

  test(
      'comic and illustration display modes restore independently from serialized backup',
      () {
    const config = ReaderImagePipelineSettings();
    final saved =
        config.withMode(true, ReaderDisplayMode.previewFirst).encode();
    final restored = ReaderImagePipelineSettings.tryParse(saved)!;
    expect(
        readerDisplayMode(
            sourceKey: 'Komiic', pipelineSetting: restored.encode()),
        ReaderDisplayMode.previewFirst);
    expect(
        readerDisplayMode(
            sourceKey: 'local_album', pipelineSetting: restored.encode()),
        ReaderDisplayMode.sharpFirst);
    final newSaved =
        restored.withMode(false, ReaderDisplayMode.previewFirst).encode();
    expect(ReaderImagePipelineSettings.tryParse(newSaved)!.comic,
        ReaderDisplayMode.previewFirst);
    expect(ReaderImagePipelineSettings.tryParse(newSaved)!.illust,
        ReaderDisplayMode.previewFirst);
  });

  test('unknown schema/modes have deterministic sharpFirst recovery', () {
    for (final raw in [
      '',
      '{}',
      '{"schema":3}',
      '{"schema":2,"comic":{"displayMode":"low"},"illust":{"displayMode":"sharpFirst"}}'
    ]) {
      final value = normalizeReaderImagePipelineSettings(raw);
      expect(ReaderImagePipelineSettings.tryParse(value)!.comic,
          ReaderDisplayMode.sharpFirst);
      expect(ReaderImagePipelineSettings.tryParse(value)!.illust,
          ReaderDisplayMode.sharpFirst);
    }
  });
}
