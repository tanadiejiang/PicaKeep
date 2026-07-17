import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/untranslated_tags/untranslated_tag_coordinator.dart';
import 'package:picakeep/foundation/untranslated_tags/untranslated_tag_store.dart';
import 'package:picakeep/tools/tags_translation.dart';

void main() {
  late Directory tempDirectory;

  setUp(() async {
    tempDirectory =
        await Directory.systemTemp.createTemp('picakeep-coordinator-');
    setTagTranslationsForTesting({
      'artist': {'known': '已翻译'}
    });
  });

  tearDown(() async {
    resetTagTranslationsForTesting();
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  UntranslatedTagCoordinator createCoordinator({
    TagTranslationLookupResult Function(String, String)? lookup,
  }) {
    return UntranslatedTagCoordinator(
      repository: UntranslatedTagRepository(
        file: File('${tempDirectory.path}/untranslated.json'),
      ),
      lookup: lookup ?? lookupTagTranslation,
    );
  }

  test('observation exposes neutral per-comic fields and canonical identity',
      () {
    final observation = UntranslatedTagObservation(
      source: ' EHentai ',
      comicId: ' Comic-A ',
      flat: const ['artist:unknown'],
      categorized: const {
        'Artists': ['unknown']
      },
      context: 'online',
      operationId: 'op-1',
    );

    expect(observation.source, ' EHentai ');
    expect(observation.comicId, ' Comic-A ');
    expect(observation.flatTags, ['artist:unknown']);
    expect(observation.categorizedTags['Artists'], ['unknown']);
    expect(observation.normalizedSource, 'ehentai');
    expect(observation.canonicalComicId, 'comic-a');
    expect(observation.operationId, 'op-1');
  });

  test('deduplicates flat and categorized tags per operation and comic',
      () async {
    final coordinator = createCoordinator();

    final accepted = await coordinator.observe(UntranslatedTagObservation(
      source: 'ehentai',
      comicId: '  Comic-A ',
      flat: const ['artist:unknown', 'artist:UNKNOWN'],
      categorized: const {
        'Artists': ['unknown']
      },
      context: 'online',
      operationId: 'operation-1',
    ));

    expect(accepted, 1);
    expect(coordinator.repository.records.single.encounterCount, 1);
  });

  test('counts two comics independently within one operation', () async {
    final coordinator = createCoordinator();
    final observations = [
      for (final id in ['comic-a', 'comic-b'])
        UntranslatedTagObservation(
          source: 'nhentai',
          comicId: id,
          flat: const ['artist:unknown'],
          context: 'online',
          operationId: 'operation-1',
        ),
    ];

    expect(await coordinator.observeBatch(observations), 2);
    expect(coordinator.repository.records.single.encounterCount, 2);
  });

  test('skips non EH/NH observations', () async {
    var lookedUp = false;
    final coordinator = createCoordinator(
      lookup: (rawTag, namespace) {
        lookedUp = true;
        return lookupTagTranslation(rawTag, namespace);
      },
    );

    expect(
      await coordinator.observe(UntranslatedTagObservation(
        source: 'jm',
        comicId: 'comic-a',
        flat: const ['artist:unknown'],
        context: 'online',
        operationId: 'operation-1',
      )),
      0,
    );
    expect(lookedUp, isFalse);
    expect(coordinator.repository.records, isEmpty);
    expect(coordinator.pendingObservationCount, 0);
  });

  test('retains a complete operation beyond the old 256 observation limit',
      () async {
    final coordinator = createCoordinator();
    setTagTranslationsForTesting({}, ready: false);
    final observations = [
      for (var index = 0; index < 300; index++)
        UntranslatedTagObservation(
          source: 'ehentai',
          comicId: 'comic-$index',
          flat: const ['artist:unknown'],
          context: 'online',
          operationId: 'operation-1',
        ),
    ];

    expect(await coordinator.observeBatch(observations), 0);
    expect(coordinator.pendingOperationCount, 1);
    expect(coordinator.pendingObservationCount, 300);

    setTagTranslationsForTesting({}, ready: true);
    expect(await coordinator.flushPending(), 300);
    expect(coordinator.repository.records.single.encounterCount, 300);
  });

  test('repeated callbacks while translations are unavailable count once',
      () async {
    final coordinator = createCoordinator();
    setTagTranslationsForTesting({}, ready: false);
    final observation = UntranslatedTagObservation(
      source: 'nhentai',
      comicId: '123',
      flat: const ['artist:unknown'],
      context: 'online-search',
      operationId: 'search-operation',
    );

    await coordinator.observeBatch(List.filled(20, observation));
    expect(coordinator.pendingOperationCount, 1);
    expect(coordinator.pendingObservationCount, 20);

    setTagTranslationsForTesting({}, ready: true);
    expect(await coordinator.flushPending(), 1);
    expect(coordinator.repository.records.single.encounterCount, 1);
    expect(await coordinator.flushPending(), 0);
  });

  test('replaying an operation beyond 4096 observations does not recount',
      () async {
    final coordinator = createCoordinator();
    final observations = [
      for (var index = 0; index < 4200; index++)
        UntranslatedTagObservation(
          source: 'ehentai',
          comicId: 'comic-$index',
          flat: const ['artist:unknown'],
          context: 'restore',
          operationId: 'operation-large',
        ),
    ];

    expect(await coordinator.observeBatch(observations), 4200);
    expect(await coordinator.observeBatch(observations), 0);
    expect(coordinator.repository.records.single.encounterCount, 4200);
  });

  test('does not write when lookup explicitly reports failure', () async {
    final coordinator = createCoordinator(
      lookup: (rawTag, namespace) => TagTranslationLookupResult(
        displayText: rawTag,
        found: false,
        normalizedNamespace: normalizeTagNamespace(namespace),
        normalizedRawTag: normalizeTagValue(rawTag),
        matchedNamespace: '',
        translationReady: false,
      ),
    );

    expect(
      await coordinator.observe(UntranslatedTagObservation(
        source: 'ehentai',
        comicId: 'comic-a',
        flat: const ['artist:failure'],
        context: 'online',
        operationId: 'operation-1',
      )),
      0,
    );
    expect(coordinator.repository.records, isEmpty);
  });
}
