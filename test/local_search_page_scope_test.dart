import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/local_search_data_source.dart';
import 'package:picakeep/pages/local_search_page.dart';

class _Request {
  _Request(this.keyword, this.scope, this.aliases);
  final String keyword;
  final LocalSearchType scope;
  final List<String> aliases;
  final result = Completer<List<LocalSearchResult>>();
}

class _Source extends LocalSearchDataSource {
  final requests = <_Request>[];
  final chipRequests = <LocalSearchType>[];
  final chips = <LocalSearchType, Completer<List<String>>>{};

  @override
  Future<List<String>> collectChips(LocalSearchType scope) {
    chipRequests.add(scope);
    return chips.putIfAbsent(scope, Completer<List<String>>.new).future;
  }

  @override
  Future<List<LocalSearchResult>> search(String keyword, LocalSearchType scope,
      {List<String> aliases = const []}) {
    final request = _Request(keyword, scope, aliases);
    requests.add(request);
    return request.result.future;
  }
}

LocalSearchResult _result(String title) => LocalSearchResult(
      title: title,
      author: 'Fixture',
      sourceLabel: '收藏',
      favoriteItem: FavoriteItemWithFolderInfo(
        FavoriteItem(
          target: title,
          name: title,
          coverPath: '',
          author: 'Fixture',
          type: FavoriteType.pixiv,
          tags: [],
        ),
        'Test folder',
      ),
    );

Future<void> _open(WidgetTester tester, _Source source,
    {double width = 400, double textScale = 1}) async {
  tester.view.physicalSize = Size(width, 850);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(colorSchemeSeed: Colors.purple),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
      ),
      child: child!,
    ),
    home: LocalSearchPage(
      searchType: LocalSearchType.favoritesOnly,
      dataSource: source,
    ),
  ));
  await tester.pump();
}

Future<void> _submit(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(TextField), query);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pump();
}

void main() {
  testWidgets('changing scope reruns same query and ignores old response',
      (tester) async {
    final source = _Source();
    await _open(tester, source);
    await _submit(tester, 'query');
    await tester.tap(find.byKey(
      const ValueKey('local-search-scope-downloadsOnly'),
    ));
    await tester.pump();
    expect(source.requests.map((e) => e.scope), [
      LocalSearchType.favoritesOnly,
      LocalSearchType.downloadsOnly,
    ]);
    expect(source.requests.last.keyword, 'query');
    source.requests.last.result.complete([_result('Current download')]);
    await tester.pump();
    expect(find.text('Current download'), findsOneWidget);
    source.requests.first.result.complete([_result('Stale favorite')]);
    await tester.pump();
    expect(find.text('Stale favorite'), findsNothing);
    expect(find.text('Current download'), findsOneWidget);
    expect(source.chipRequests, [
      LocalSearchType.favoritesOnly,
      LocalSearchType.downloadsOnly,
    ]);
  });

  testWidgets('clearing input cancels loading and prevents late results',
      (tester) async {
    final source = _Source();
    await _open(tester, source);
    await _submit(tester, 'query');
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.byTooltip('清空搜索'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    source.requests.single.result.complete([_result('Stale favorite')]);
    await tester.pump();
    expect(find.text('Stale favorite'), findsNothing);
    expect(find.text('输入关键词搜索收藏夹漫画'), findsOneWidget);
  });

  testWidgets('editing pending query drops old results before next submit',
      (tester) async {
    final source = _Source();
    await _open(tester, source);
    await _submit(tester, 'old query');
    await tester.enterText(find.byType(TextField), 'new query');
    source.requests.single.result.complete([_result('Old result')]);
    await tester.pump();
    expect(find.text('Old result'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(source.requests, hasLength(1));
  });

  testWidgets('late suggestions do not cover submitted search results',
      (tester) async {
    final source = _Source();
    await _open(tester, source);
    await _submit(tester, 'query');
    source.requests.single.result.complete([_result('Search result')]);
    await tester.pump();
    source.chips[LocalSearchType.favoritesOnly]!.complete(['query suggestion']);
    await tester.pump();
    expect(find.text('Search result'), findsOneWidget);
    expect(find.text('query suggestion'), findsNothing);
  });

  testWidgets(
      'suggestions follow current scope even when old collection is slow',
      (tester) async {
    final source = _Source();
    await _open(tester, source);
    await tester.tap(find.byKey(
      const ValueKey('local-search-scope-downloadsOnly'),
    ));
    await tester.pump();
    source.chips[LocalSearchType.downloadsOnly]!.complete(['tag downloaded']);
    await tester.pump();
    source.chips[LocalSearchType.favoritesOnly]!.complete(['tag favorite']);
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'tag');
    await tester.pump();
    expect(find.text('tag downloaded'), findsOneWidget);
    expect(find.text('tag favorite'), findsNothing);
  });

  testWidgets('failed search offers retry in the same scope', (tester) async {
    final source = _Source();
    await _open(tester, source);
    await _submit(tester, 'query');
    source.requests.single.result.completeError(StateError('Fixture failure'));
    await tester.pump();
    expect(find.text('读取本地内容失败，请重试'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(source.requests, hasLength(2));
    expect(source.requests.last.scope, LocalSearchType.favoritesOnly);
    source.requests.last.result.complete([]);
    await tester.pump();
    expect(find.text('未找到匹配的漫画'), findsOneWidget);
  });

  testWidgets('scope controls remain usable at 320dp with large text',
      (tester) async {
    await _open(tester, _Source(), width: 320, textScale: 1.6);
    expect(tester.takeException(), isNull);
    for (final scope in LocalSearchType.values) {
      final chip = find.byKey(ValueKey('local-search-scope-${scope.name}'));
      expect(chip, findsOneWidget);
      expect(tester.getSize(chip).height, greaterThanOrEqualTo(48));
    }
  });
}
