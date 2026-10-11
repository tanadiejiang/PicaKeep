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

  test('large-image policy defaults and migrates without changing modes', () {
    const original = ReaderImagePipelineSettings(
      comic: ReaderDisplayMode.previewFirst,
      legacyComic: 'comic-fact',
      legacyIllust: 'illust-fact',
    );
    expect(original.largeImagePolicy, ReaderLargeImagePolicy.safeWhole);
    final raw = jsonDecode(original.encode()) as Map<String, dynamic>;
    raw.remove('largeImagePolicy');
    for (final value in [
      jsonEncode(raw),
      for (final invalid in [null, '', 'invalid', 'StrictOriginal', 1, {}, []])
        jsonEncode({...raw, 'largeImagePolicy': invalid}),
    ]) {
      final normalized = normalizeReaderImagePipelineSettings(value);
      final config = ReaderImagePipelineSettings.tryParse(normalized)!;
      expect(config.largeImagePolicy, ReaderLargeImagePolicy.safeWhole);
      expect(config.comic, ReaderDisplayMode.previewFirst);
      expect(config.illust, ReaderDisplayMode.sharpFirst);
      expect(config.legacyComic, original.legacyComic);
      expect(config.legacyIllust, original.legacyIllust);
      expect(normalizeReaderImagePipelineSettings(normalized), normalized);
    }
  });

  test('withMode and withLargeImagePolicy preserve each other and legacy facts',
      () {
    var config = const ReaderImagePipelineSettings(
      legacyComic: 'comic-fact',
      legacyIllust: 'illust-fact',
    ).withLargeImagePolicy(ReaderLargeImagePolicy.strictOriginal);
    for (final isComic in [true, false]) {
      config = config.withMode(isComic, ReaderDisplayMode.previewFirst);
      expect(config.largeImagePolicy, ReaderLargeImagePolicy.strictOriginal);
    }
    config = config.withLargeImagePolicy(ReaderLargeImagePolicy.safeWhole);
    expect(config.comic, ReaderDisplayMode.previewFirst);
    expect(config.illust, ReaderDisplayMode.previewFirst);
    expect(config.legacyComic, 'comic-fact');
    expect(config.legacyIllust, 'illust-fact');
    expect(ReaderImagePipelineSettings.tryParse(config.encode())!.encode(),
        config.encode());
  });

  test('backup fallback applies only to a missing policy field', () {
    final raw = jsonDecode(const ReaderImagePipelineSettings(
      comic: ReaderDisplayMode.previewFirst,
    ).encode()) as Map<String, dynamic>;
    raw.remove('largeImagePolicy');
    ReaderImagePipelineSettings parse(Map<String, dynamic> data) =>
        ReaderImagePipelineSettings.tryParse(
          jsonEncode(data),
          missingLargeImagePolicy: ReaderLargeImagePolicy.strictOriginal,
        )!;
    expect(parse(raw).largeImagePolicy, ReaderLargeImagePolicy.strictOriginal);
    for (final incoming in ['safeWhole', 'invalid', null]) {
      final config = parse({...raw, 'largeImagePolicy': incoming});
      expect(config.largeImagePolicy, ReaderLargeImagePolicy.safeWhole);
      expect(config.comic, ReaderDisplayMode.previewFirst);
    }
    expect(
        parse({...raw, 'largeImagePolicy': 'strictOriginal'}).largeImagePolicy,
        ReaderLargeImagePolicy.strictOriginal);
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
