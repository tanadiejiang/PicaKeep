import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/network/jm_network/jm_network.dart';

// 04 计划：JM 列表卡片分类标签还原。
//
// 这里只测纯解析，不碰网络：`parseJmListTags` / `parseJmListBrief` 就是生产
// 链路 `search` / `getFavorites` / `getFolderComicsPage` 调用的同一份实现
// （经类内 `_parseBrief` 薄包装），因此断言的是真实行为而非测试副本。

/// 一份"真实形态"的 JM 列表接口条目：列表接口给的是 category 对象，
/// 不是详情接口那种 `tags` 名称数组。
Map<String, dynamic> _entry({
  Object? category = _sentinel,
  Object? categorySub = _sentinel,
  Object? tags = _sentinel,
}) =>
    <String, dynamic>{
      'id': 123456,
      'name': '测试本',
      'author': ['作者甲'],
      'description': '简介文本',
      if (!identical(category, _sentinel)) 'category': category,
      if (!identical(categorySub, _sentinel)) 'category_sub': categorySub,
      if (!identical(tags, _sentinel)) 'tags': tags,
    };

const Object _sentinel = Object();

/// 真实形态的 category 子对象：id + title 都在。
Map<String, dynamic> _category(int id, String title) =>
    <String, dynamic>{'id': id, 'title': title};

void main() {
  group('B01 条目含 category + category_sub', () {
    test('两个不同 title 都被收录，且 category 在 category_sub 之前', () {
      final tags = parseJmListTags(_entry(
        category: _category(1, '同人'),
        categorySub: _category(2, '單本'),
      ));
      expect(tags, orderedEquals(<String>['同人', '單本']));
    });

    test('同标题去重，只保留一个（用户要求只显示一个，与原项目不同）', () {
      final tags = parseJmListTags(_entry(
        category: _category(10, '同人'),
        categorySub: _category(10, '同人'),
      ));
      expect(tags, orderedEquals(<String>['同人']));
    });

    test('去重不改变 category 在前的顺序', () {
      final tags = parseJmListTags(_entry(
        category: _category(3, '同人'),
        categorySub: _category(4, '中文'),
      ));
      expect(tags, orderedEquals(<String>['同人', '中文']));
    });
  });

  group('B02 只含其中一个分类字段', () {
    test('只有 category → 单个 title', () {
      final tags = parseJmListTags(_entry(category: _category(1, '同人')));
      expect(tags, orderedEquals(<String>['同人']));
    });

    test('只有 category_sub → 单个 title', () {
      final tags =
          parseJmListTags(_entry(categorySub: _category(2, '單本')));
      expect(tags, orderedEquals(<String>['單本']));
    });

    test('id 缺失不影响收录（本项目不消费分类 id）', () {
      final tags = parseJmListTags(_entry(
        category: <String, dynamic>{'title': '同人'},
        categorySub: _category(2, '單本'),
      ));
      expect(tags, orderedEquals(<String>['同人', '單本']));
    });
  });

  group('B03 分类字段缺失 / null / 非 Map', () {
    test('两者都缺失 → 空列表', () {
      expect(parseJmListTags(_entry()), isEmpty);
    });

    test('两者都为 null → 空列表', () {
      expect(
        parseJmListTags(_entry(category: null, categorySub: null)),
        isEmpty,
      );
    });

    test('两者都不是 Map → 空列表且不含 "null" 文本', () {
      final tags =
          parseJmListTags(_entry(category: '同人', categorySub: <int>[1, 2]));
      expect(tags, isEmpty);
      expect(tags, isNot(contains('null')));
    });

    test('title 为 null / 空串 / 纯空白 / 非字符串 → 不收录', () {
      for (final bad in <Object?>[null, '', '   ', 123, <String, dynamic>{}]) {
        final tags = parseJmListTags(_entry(
          category: <String, dynamic>{'id': 1, 'title': bad},
          categorySub: _category(2, '單本'),
        ));
        expect(tags, orderedEquals(<String>['單本']),
            reason: 'title=$bad 不应被收录');
      }
    });

    test('title 前后空白被裁掉', () {
      final tags = parseJmListTags(
          _entry(category: _category(1, '  同人  ')));
      expect(tags, orderedEquals(<String>['同人']));
    });

    test('条目整体不是 Map 时返回空列表而不抛异常', () {
      for (final bad in <Object?>[null, 'str', 42, <int>[1]]) {
        expect(() => parseJmListTags(bad), returnsNormally);
        expect(parseJmListTags(bad), isEmpty);
      }
    });

    test('详情页 related_list 的畸形元素不会被解析成标签', () {
      expect(parseJmListTags(<String, dynamic>{'id': 1}), isEmpty);
    });
  });

  group('B04 tags 字段兜底与纯数字过滤', () {
    test('分类缺失时回落到 tags 名称数组', () {
      final tags = parseJmListTags(_entry(tags: <String>['同人', '中文']));
      expect(tags, orderedEquals(<String>['同人', '中文']));
    });

    test('tags 里的纯数字 id 被过滤掉', () {
      final tags = parseJmListTags(
          _entry(tags: <dynamic>['12345', '同人', 678, ' ']));
      expect(tags, orderedEquals(<String>['同人']));
      expect(tags, isNot(contains('12345')));
    });

    test('tags 里的重复项同样去重', () {
      final tags = parseJmListTags(
          _entry(tags: <dynamic>['同人', '同人', ' 同人 ', '單本']));
      expect(tags, orderedEquals(<String>['同人', '單本']));
    });

    test('分类存在时不使用 tags 兜底', () {
      final tags = parseJmListTags(_entry(
        category: _category(1, '同人'),
        categorySub: _category(2, '單本'),
        tags: <String>['兜底标签'],
      ));
      expect(tags, orderedEquals(<String>['同人', '單本']));
      expect(tags, isNot(contains('兜底标签')));
    });
  });

  group('JmComicBrief 构造契约（说明：需求为「不改构造契约」）', () {
    test('正常条目解析出 id / 标题 / 作者 / 封面 / 标签', () {
      final brief = parseJmListBrief(_entry(
        category: _category(1, '同人'),
        categorySub: _category(2, '單本'),
      ));
      expect(brief.id, '123456');
      expect(brief.title, '测试本');
      expect(brief.author, '作者甲');
      expect(brief.tags, orderedEquals(<String>['同人', '單本']));
      expect(brief.coverUrl, contains('123456'));
      // 收藏接口没有 description，默认不复用搜索页的 desc。
      expect(brief.desc, isEmpty);
    });

    test('withDesc 为 true 时读取 description（搜索接口形态）', () {
      final brief = parseJmListBrief(_entry(tags: <String>['同人']),
          withDesc: true);
      expect(brief.desc, '简介文本');
    });

    test('author 为字符串时也能解析', () {
      final brief = parseJmListBrief(<String, dynamic>{
        'id': 9,
        'name': 'n',
        'author': '作者乙',
        'category': _category(1, '同人'),
      });
      expect(brief.author, '作者乙');
      expect(brief.tags, orderedEquals(<String>['同人']));
    });

    test('字段大面积缺失时退化但不抛异常', () {
      final brief = parseJmListBrief(<String, dynamic>{'id': 7});
      expect(brief.id, '7');
      expect(brief.title, isEmpty);
      expect(brief.author, isEmpty);
      expect(brief.tags, isEmpty);
      expect(brief.tags, isNot(contains('null')));
    });
  });
}
