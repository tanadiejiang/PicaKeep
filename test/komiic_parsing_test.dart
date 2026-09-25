/// Komiic 解析纯函数与 GraphQL 构造的夹具测试（第十八轮）。
///
/// 全程不出网：只调 `komiic_parsing.dart` 与 `komiic_graphql.dart` 的顶层纯函数。
///
/// 覆盖计划 04 号点名的风险：
/// - GraphQL query 手抄漏字段（用「字段非空 + 关键 operation 名」做防回归）
/// - 搜索接口不接受分页参数
/// - 章节 `type == book` 的「卷 / 话」命名
/// - `kids` 生成图片 URL 且过滤空值
/// - 防御式解析（null / String / num 混合、缺字段）
library;

import 'dart:convert';

import 'package:picakeep/network/komiic_network/komiic_graphql.dart';
import 'package:picakeep/network/komiic_network/komiic_parsing.dart';
import 'package:test/test.dart';

/// 一份贴近真实 `comicByIds` 单项的漫画对象。
Map<String, dynamic> _comic(Object? id, {String title = '测试漫画'}) =>
    <String, dynamic>{
      'id': id,
      'title': title,
      'status': 'ONGOING',
      'year': 2024,
      'imageUrl': 'https://komiic.com/cover.jpg',
      'authors': <dynamic>[
        <String, dynamic>{'id': 'a1', 'name': '作者甲'},
        <String, dynamic>{'id': 'a2', 'name': '作者乙'},
      ],
      'categories': <dynamic>[
        <String, dynamic>{'id': 'c1', 'name': '熱血'},
        <String, dynamic>{'id': 'c2', 'name': '校園'},
      ],
      'dateUpdated': '2026-01-02T03:04:05.000000',
      'monthViews': 10,
      'views': 200,
      'favoriteCount': 30,
      'lastBookUpdate': '2026-01-01',
      'lastChapterUpdate': '2026-01-02',
    };

void main() {
  group('Komiic 列表解析', () {
    test('核心字段与标签、作者提取正确', () {
      final list = parseKomiicComicList(<dynamic>[_comic('1')]);
      expect(list, hasLength(1));
      final brief = list.first;
      expect(brief.id, '1');
      expect(brief.title, '测试漫画');
      expect(brief.author, '作者甲');
      expect(brief.tags, <String>['熱血', '校園']);
      expect(brief.cover, 'https://komiic.com/cover.jpg');
      expect(brief.views, 200);
      expect(brief.favoriteCount, 30);
    });

    test('updateTime 被格式化为 yyyy-MM-dd', () {
      final list = parseKomiicComicList(<dynamic>[_comic('1')]);
      expect(list.first.updateTime, '2026-01-02');
    });

    test('按 id 去重且保留首个', () {
      final list = parseKomiicComicList(<dynamic>[
        _comic('1', title: '第一个'),
        _comic('1', title: '重复项'),
        _comic('2', title: '第二个'),
      ]);
      expect(list, hasLength(2));
      expect(list[0].title, '第一个');
      expect(list[1].title, '第二个');
    });

    test('坏 id 项被跳过而不是抛异常', () {
      final list = parseKomiicComicList(<dynamic>[
        _comic('1'),
        _comic(null),
        _comic(''),
      ]);
      expect(list, hasLength(1));
      expect(list.first.id, '1');
    });

    test('raw count 反映原始条数（用于判停），含坏项', () {
      expect(
        parseKomiicRawCount(<dynamic>[_comic('1'), _comic(null), _comic('2')]),
        3,
      );
    });

    test('空数组与非数组输入都不崩', () {
      expect(parseKomiicComicList(<dynamic>[]), isEmpty);
      expect(parseKomiicComicList(null), isEmpty);
      expect(parseKomiicComicList('not a list'), isEmpty);
    });
  });

  group('Komiic 章节解析', () {
    test('book 显示为「卷N」，其它显示 serial', () {
      final chapters = parseKomiicChapters(<dynamic>[
        <String, dynamic>{
          'id': 'ch1',
          'serial': '1',
          'type': 'book',
          'size': 100,
        },
        <String, dynamic>{
          'id': 'ch2',
          'serial': '12',
          'type': 'chapter',
          'size': 50,
        },
      ]);
      expect(chapters, hasLength(2));
      expect(chapters[0].isBook, isTrue);
      expect(chapters[0].displayName, '卷1');
      expect(chapters[1].isBook, isFalse);
      expect(chapters[1].displayName, '12');
    });

    test('serial 为空的章节被过滤（否则会出现无名章节）', () {
      final chapters = parseKomiicChapters(<dynamic>[
        <String, dynamic>{'id': 'ok', 'serial': '1', 'type': 'chapter'},
        <String, dynamic>{'id': 'bad', 'serial': '', 'type': 'chapter'},
        <String, dynamic>{'id': 'bad2', 'serial': null, 'type': 'chapter'},
      ]);
      expect(chapters, hasLength(1));
      expect(chapters.first.id, 'ok');
    });
  });

  group('Komiic 图片 URL 生成', () {
    test('由 kid 生成 /api/image/{kid} 并过滤空 kid', () {
      final urls = parseKomiicImageUrls(<dynamic>[
        <String, dynamic>{
          'id': 'i1',
          'kid': 'k1',
          'width': 800,
          'height': 1200
        },
        <String, dynamic>{'id': 'i2', 'kid': '', 'width': 1, 'height': 1},
        <String, dynamic>{'id': 'i3', 'kid': null, 'width': 1, 'height': 1},
        <String, dynamic>{'id': 'i4', 'kid': 'k4', 'width': 2, 'height': 2},
      ]);
      expect(urls, <String>[
        'https://komiic.com/api/image/k1',
        'https://komiic.com/api/image/k4',
      ]);
    });
  });

  group('Komiic 详情组装', () {
    test('章节与推荐被挂到 info 上，页数为 null 语义（无 pageCount 字段）', () {
      final chapters = parseKomiicChapters(<dynamic>[
        <String, dynamic>{'id': 'ch1', 'serial': '1', 'type': 'chapter'},
      ]);
      final recommendations = parseKomiicComicList(<dynamic>[_comic('9')]);
      final info = parseKomiicComicInfo(
        _comic('1'),
        chapters: chapters,
        recommendations: recommendations,
      );
      expect(info.id, '1');
      expect(info.authors, <String>['作者甲', '作者乙']);
      expect(info.tags, <String>['熱血', '校園']);
      expect(info.chapters, hasLength(1));
      expect(info.recommendations, hasLength(1));
      expect(info.recommendations.first.id, '9');
    });
  });

  group('Komiic 收藏夹与 ID 列表解析', () {
    test('folders 解析与 string ids 兼容 num / String 混合', () {
      final folders = parseKomiicFolders(<dynamic>[
        <String, dynamic>{
          'id': 'f1',
          'key': 'k1',
          'name': '默认夹',
          'comicCount': 3,
        },
      ]);
      expect(folders, hasLength(1));
      expect(folders.first.name, '默认夹');
      expect(folders.first.comicCount, 3);

      expect(parseKomiicStringIds(<dynamic>['1', 2, '', null]), <String>[
        '1',
        '2',
      ]);
    });
  });

  // ── GraphQL 构造：防手抄漏字段（04 号计划 R1 的直接对策）────────────────────

  group('Komiic GraphQL 构造', () {
    test('分页 offset 按 (page-1)*limit 计算', () {
      expect(komiicPagination(page: 1)['offset'], 0);
      expect(komiicPagination(page: 2)['offset'], 20);
      expect(komiicPagination(page: 3, limit: 30)['offset'], 60);
    });

    test('每个 query 都带 operationName 且可被 jsonEncode（无语法错误）', () {
      final queries = <Map<String, dynamic>>[
        recentUpdateQuery(page: 1),
        hotComicsQuery(page: 1),
        searchComicAndAuthorQuery(keyword: 'k'),
        comicByIdsQuery(comicIds: const <String>['1']),
        recommendComicByIdQuery(comicId: '1'),
        chapterByComicIdQuery(comicId: '1'),
        imagesByChapterIdQuery(chapterId: 'c1'),
        myFolderQuery(),
        comicInAccountFoldersQuery(comicId: '1'),
        folderComicIdsQuery(folderId: 'f1', page: 1),
        addComicToFolderMutation(comicId: '1', folderId: 'f1'),
        removeComicToFolderMutation(comicId: '1', folderId: 'f1'),
        comicByCategoriesQuery(categoryId: const <String>['1'], page: 1),
      ];
      for (final query in queries) {
        expect(query['operationName'], isA<String>());
        expect((query['operationName'] as String).isNotEmpty, isTrue);
        expect(query['query'], isA<String>());
        // 查操作以 `query ` 开头，写操作以 `mutation ` 开头，二者都必须有。
        final body = query['query'] as String;
        expect(
          body.contains('query ') || body.contains('mutation '),
          isTrue,
          reason: '${query['operationName']} 既非 query 也非 mutation',
        );
        expect(() => jsonEncode(query), returnsNormally);
      }
    });

    test('搜索 query 不带 pagination 变量（接口不支持分页）', () {
      final query = searchComicAndAuthorQuery(keyword: 'k');
      final variables = query['variables'] as Map<String, dynamic>;
      expect(variables.containsKey('pagination'), isFalse);
      expect(variables['keyword'], 'k');
    });

    test('漫画字段串包含详情页与卡片都要用的关键字段', () {
      for (final field in <String>[
        'id',
        'title',
        'status',
        'imageUrl',
        'authors',
        'categories',
        'dateUpdated',
        'views',
        'favoriteCount',
      ]) {
        expect(komiicComicFields.contains(field), isTrue,
            reason: '漫画字段串缺少 $field，卡片或详情会静默拿不到值');
      }
    });

    test('章节 query 含 type 字段（卷/话区分依赖它）', () {
      final query = chapterByComicIdQuery(comicId: '1')['query'] as String;
      expect(query.contains('type'), isTrue);
      expect(query.contains('serial'), isTrue);
    });

    test('图片 query 含 kid 字段（图片 URL 由它生成）', () {
      final query = imagesByChapterIdQuery(chapterId: 'c1')['query'] as String;
      expect(query.contains('kid'), isTrue);
    });
  });

  // ── 登录 token 提取：真机实测"HTTP 200 但按原假设解析不出"后的容错 ──────────

  group('Komiic 登录 token 提取', () {
    test('标准形态：{"token": "..."}（参考实现读的键）', () {
      expect(parseKomiicLoginToken('{"token":"abc123"}'), 'abc123');
    });

    test('兼容其它常见键名', () {
      expect(parseKomiicLoginToken('{"access_token":"t1"}'), 't1');
      expect(parseKomiicLoginToken('{"accessToken":"t2"}'), 't2');
    });

    test('兼容网关多包一层：data / result', () {
      expect(parseKomiicLoginToken('{"data":{"token":"nested"}}'), 'nested');
      expect(parseKomiicLoginToken('{"result":{"access_token":"r1"}}'), 'r1');
    });

    test('裸 JSON 字符串正文也能取到', () {
      expect(parseKomiicLoginToken('"bare-token"'), 'bare-token');
    });

    test('前后空白被 trim（服务端偶发带换行）', () {
      expect(parseKomiicLoginToken('  {"token":"  t  "}  '), 't');
    });

    test('token 为空白串视为没有', () {
      expect(parseKomiicLoginToken('{"token":"   "}'), isNull);
      expect(parseKomiicLoginToken('{"token":""}'), isNull);
    });

    test('非 JSON 正文一律不猜（HTML 风控页不能被当 token）', () {
      // 这是刻意的保守：猜错会把垃圾当 token 存下来，
      // 之后每个请求都带着它失败，比直接报错更难排查。
      expect(
        parseKomiicLoginToken('<html><body>challenge</body></html>'),
        isNull,
      );
      expect(parseKomiicLoginToken('not json at all'), isNull);
    });

    test('空体 / null / 结构不符都返回 null', () {
      expect(parseKomiicLoginToken(null), isNull);
      expect(parseKomiicLoginToken(''), isNull);
      expect(parseKomiicLoginToken('   '), isNull);
      expect(parseKomiicLoginToken('{}'), isNull);
      expect(parseKomiicLoginToken('[1,2,3]'), isNull);
      expect(parseKomiicLoginToken('{"error":"bad password"}'), isNull);
    });

    // ── 以下为"过度容错"的回归防线 ─────────────────────────────────────────
    // 背景：容错版的 `_tokenFromDecoded` 会对 data/result 递归下钻，
    // 于是 `{"result":"success"}` 这种"网关回了状态词"被当成 token 写进源数据，
    // 之后每个请求都带着假 token 失败——比直接报错难查得多。

    test('包装层里的状态词不能被当 token（{"result":"success"}）', () {
      expect(parseKomiicLoginToken('{"result":"success"}'), isNull);
      expect(parseKomiicLoginToken('{"data":"success"}'), isNull);
      expect(parseKomiicLoginToken('{"result":"ok"}'), isNull);
      expect(parseKomiicLoginToken('{"result":"true"}'), isNull);
      expect(parseKomiicLoginToken('{"data":"error"}'), isNull);
      expect(parseKomiicLoginToken('{"result":"failed"}'), isNull);
    });

    test('包装层是对象时仍然下钻（true positive 不能被误杀）', () {
      expect(parseKomiicLoginToken('{"result":{"token":"deep"}}'), 'deep');
      expect(
          parseKomiicLoginToken('{"data":{"access_token":"deep2"}}'), 'deep2');
    });

    test('裸字符串必须"像凭据"：短词与状态词被拒绝', () {
      expect(parseKomiicLoginToken('"success"'), isNull);
      expect(parseKomiicLoginToken('"ok"'), isNull);
      expect(parseKomiicLoginToken('"abc"'), isNull, reason: '过短，不像 token');
      expect(parseKomiicLoginToken('"has space"'), isNull);
      // 足够长且无空格 → 接受（后端直接返回裸 token 的情况）。
      expect(parseKomiicLoginToken('"eyJhbGciOiJIUzI1NiJ9"'),
          'eyJhbGciOiJIUzI1NiJ9');
    });

    test('带明确键名的不做形态过滤（键名已表达语义）', () {
      // 服务端若真返回短 token，也不应被形态过滤误杀。
      expect(parseKomiicLoginToken('{"token":"short"}'), 'short');
    });

    test('looksLikeKomiicToken 的边界', () {
      expect(looksLikeKomiicToken('12345678'), isTrue, reason: '恰好 8 位');
      expect(looksLikeKomiicToken('1234567'), isFalse, reason: '7 位过短');
      expect(looksLikeKomiicToken('abc defgh'), isFalse, reason: '含空格');
      expect(looksLikeKomiicToken('SUCCESS'), isFalse, reason: '状态词大小写不敏感');
      expect(looksLikeKomiicToken('  tokenvalue  '), isTrue, reason: '先 trim');
    });
  });
}
