import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/untranslated_tags/untranslated_tag_store.dart';
import 'package:picakeep/tools/tags_translation.dart';

void main() {
  late Directory tempDirectory;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('picakeep-tags-');
    setTagTranslationsForTesting({
      'artist': {'known': '已翻译'},
      'female': {'same': 'same'},
    });
  });

  tearDown(() async {
    resetTagTranslationsForTesting();
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test('lookup exposes found even when translated text equals raw text', () {
    final result = lookupTagTranslation(' same ', 'artists');

    expect(result.translationReady, isTrue);
    expect(result.found, isTrue);
    expect(result.missing, isFalse);
    expect(result.normalizedNamespace, 'artist');
  });

  test('lookup reports not loaded instead of treating every tag as missing',
      () {
    setTagTranslationsForTesting({}, ready: false);

    final result = lookupTagTranslation('unknown', 'artist');

    expect(result.translationReady, isFalse);
    expect(result.found, isFalse);
    expect(result.missing, isFalse);
  });

  test('candidate collection keeps the first colon and merges NH buckets', () {
    final candidates = collectUntranslatedTagCandidates(
      flatTags: const ['artist:alpha:beta', 'artist:alpha:beta', 'plain'],
      categorizedTags: const {
        'Artists': ['alpha:beta'],
        'Tags': ['plain'],
      },
    );

    expect(
      candidates
          .map((item) => '${item.normalizedNamespace}:${item.normalizedRawTag}')
          .toList(),
      ['artist:alpha:beta', 'tags:plain'],
    );

    final nhCandidates = collectUntranslatedTagCandidates(
      source: 'nhentai',
      categorizedTags: const {
        'Pages': ['20'],
        'Time': ['2024-01-01'],
        'Artists': ['unknown'],
      },
    );
    expect(nhCandidates.map((item) => item.rawTag), ['unknown']);
  });

  test('collector counts an observation once and persists records', () async {
    final file = File('${tempDirectory.path}/untranslated.json');
    final repository = UntranslatedTagRepository(file: file);
    final collector = UntranslatedTagCollector(repository: repository);

    expect(
      await collector.observe(
        source: 'ehentai',
        observationId: 'session-op-1',
        context: 'online',
        flatTags: const ['artist:unknown', 'artist:unknown', 'artist:known'],
        categorizedTags: const {
          'Artists': ['unknown']
        },
      ),
      1,
    );
    expect(repository.records.single.encounterCount, 1);

    expect(
      await collector.observe(
        source: 'ehentai',
        observationId: 'session-op-1',
        context: 'online',
        flatTags: const ['artist:unknown'],
      ),
      0,
    );
    expect(
      await collector.observe(
        source: 'ehentai',
        observationId: 'session-op-2',
        context: 'download',
        flatTags: const ['artist:unknown'],
      ),
      1,
    );
    expect(repository.records.single.encounterCount, 2);

    final restored = UntranslatedTagRepository(file: file);
    await restored.load();
    expect(restored.records.single.rawTag, 'unknown');
    expect(restored.records.single.contexts, {'download', 'online'});
  });

  test('translated records are removed during revalidation', () async {
    final repository = UntranslatedTagRepository(
      file: File('${tempDirectory.path}/untranslated.json'),
    );
    final collector = UntranslatedTagCollector(repository: repository);
    await collector.observe(
      source: 'nhentai',
      observationId: 'op-1',
      context: 'local',
      flatTags: const ['artist:later'],
    );
    expect(repository.records, hasLength(1));

    setTagTranslationsForTesting({
      'artist': {'later': '后来翻译'}
    });
    await repository.pruneTranslated();
    expect(repository.records, isEmpty);
  });

  test('not-ready observations are bounded and replayed after loading',
      () async {
    final repository = UntranslatedTagRepository(
      file: File('${tempDirectory.path}/untranslated.json'),
    );
    final collector = UntranslatedTagCollector(repository: repository);
    setTagTranslationsForTesting({}, ready: false);
    expect(
      await collector.observe(
        source: 'ehentai',
        observationId: 'queued',
        context: 'online',
        flatTags: const ['artist:waiting'],
      ),
      0,
    );

    setTagTranslationsForTesting({
      'artist': {'known': '已翻译'}
    });
    await UntranslatedTagCollector.flushPending(repository);
    expect(repository.records.single.rawTag, 'waiting');
  });
}
