/// 第十八轮 34 号：作者页链路的**纯函数**验收（不起页面、不联网）。
///
/// 覆盖三块：
/// 1. 三步链路的 URL 与实证来源一致（`PixivNetwork` 的静态构造器，可脱离网络调用）；
/// 2. 三步链路的解析：作者资料 / 作品 id / 作品详情；
/// 3. 诊断工具 `describePixivJsonShape`：形状变化时必须"如实报出实际形状"。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/network/pixiv_network/pixiv_network.dart';
import 'package:picakeep/network/pixiv_network/pixiv_parsing.dart';

/// 构造一条和真实 `profile/illusts` 响应单项同构的作品对象。
///
/// 字段取自 pixiv-ajax-api-docs 的样例响应（`profile/all` 的 `pickup` 项与
/// `profile/illusts` 的 `works` 项同构）：`id` / `title` / `url` / `tags` /
/// `illustType` / `pageCount` / `userName`。
Map<String, dynamic> _workJson(String id) => <String, dynamic>{
      'id': id,
      'title': 'title-$id',
      'illustType': 0,
      'xRestrict': 0,
      'url': 'https://i.pximg.net/c/250x250_80_a2/img-master/img/${id}_p0_square1200.jpg',
      'tags': <String>['tagA', 'tagB'],
      'userId': '9153585',
      'userName': 'haku89',
      'width': 1000,
      'height': 1500,
      'pageCount': 2,
      'createDate': '2024-01-01T00:00:00+09:00',
    };

void main() {
  // ───────────────────────────────────────────────────────────────────────────
  //  A01 URL 契约（端点依据 PixivFE v3.0.3，写死在这里防回归）
  // ───────────────────────────────────────────────────────────────────────────

  group('A01 作者页三步 URL', () {
    test('作者资料 / 作品 id / 作品详情三条路径与实证来源一致', () {
      // 三条链路**都带 `lang=zh`**：Pixiv 的 Ajax 错误消息跟随该参数，
      // 不带时失败信息是日文、且会被原样显示给用户（2026-09 实测：
      // 404 →「リクエストされたページが見つかりませんでした」）。
      expect(
        PixivNetwork.authorInfoUrl('9153585'),
        'https://www.pixiv.net/ajax/user/9153585?full=1&lang=zh',
      );
      expect(
        PixivNetwork.authorWorkIdsUrl('9153585'),
        'https://www.pixiv.net/ajax/user/9153585/profile/all?lang=zh',
      );
      expect(
        PixivNetwork.authorWorksUrl('9153585', <String>['200', '100']),
        'https://www.pixiv.net/ajax/user/9153585/profile/illusts'
        '?work_category=illustManga&is_first_page=0&lang=zh'
        '&ids[]=200&ids[]=100',
      );
    });

    test('ids[] 是重复键（不能写成逗号拼接），且每页 30 条', () {
      final url = PixivNetwork.authorWorksUrl('1', <String>['1', '2', '3']);
      expect('&ids[]=1&ids[]=2&ids[]=3'.allMatches(url).length, 1);
      expect(url.contains('ids[]=1,2,3'), isFalse);
      expect(PixivNetwork.authorWorksPageSize, 30);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  //  A02 作者资料解析
  // ───────────────────────────────────────────────────────────────────────────

  group('A02 作者资料解析', () {
    test('读 userId/name/imageBig/following，并规范化纯文本简介', () {
      final author = parsePixivAuthorInfo(<String, dynamic>{
        'userId': '9153585',
        'name': 'haku89',
        'image': 'https://i.pximg.net/avatar_50.jpg',
        'imageBig': 'https://i.pximg.net/avatar_170.jpg',
        'following': 349,
        // 真实样例的 comment 是 CRLF；commentHtml 同时存在时**不该**被采用。
        'comment': '第一行\r\n第二行\r\n\r\n\r\n第三行',
        'commentHtml': '第一行<br />第二行<br /><br /><br />第三行',
      });

      expect(author.id, '9153585');
      expect(author.name, 'haku89');
      expect(author.avatar, 'https://i.pximg.net/avatar_170.jpg');
      expect(author.following, 349);
      expect(author.comment, '第一行\n第二行\n\n第三行');
    });

    test('comment 为空时回退 commentHtml 并清洗 HTML', () {
      final author = parsePixivAuthorInfo(<String, dynamic>{
        'userId': '1',
        'name': 'n',
        'comment': '   ',
        'commentHtml': 'a<br />b<a href="x">link</a>',
      });
      expect(author.comment, 'a\nblink');
    });

    test('只有 id 与 name 同时缺失才抛（其余字段一律兜底）', () {
      expect(
        () => parsePixivAuthorInfo(<String, dynamic>{'following': 1}),
        throwsA(isA<FormatException>()),
      );
      // 只有 id 没有 name 也算有效响应：名字留空，不抛。
      final author = parsePixivAuthorInfo(<String, dynamic>{'userId': '7'});
      expect(author.id, '7');
      expect(author.name, '');
      expect(author.avatar, '');
      expect(author.following, 0);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  //  A03 作品 id 解析（profile/all）
  // ───────────────────────────────────────────────────────────────────────────

  group('A03 作品 id 解析', () {
    test('从 illusts 与 manga 的**键**取值，去重后按数值倒序', () {
      final ids = parsePixivUserWorkIds(<String, dynamic>{
        // 刻意不按顺序、且混入重复与小说（novels 不计入作品列表）。
        'illusts': <String, dynamic>{'100': null, '9': null, '20': null},
        'manga': <String, dynamic>{'3': null, '100': null},
        'novels': <String, dynamic>{'777': null},
      });
      // 字符串序会是 ['9','3','20','100']，这里必须是数值序。
      expect(ids, <String>['100', '20', '9', '3']);
    });

    test('非数字键跳过；容器缺失当空；List 形态也吃', () {
      expect(
        parsePixivUserWorkIds(<String, dynamic>{
          'illusts': <String, dynamic>{'abc': null, '': null, '42': null},
          'manga': null,
        }),
        <String>['42'],
      );
      expect(parsePixivUserWorkIds(<String, dynamic>{}), isEmpty);
      expect(
        parsePixivUserWorkIds(<String, dynamic>{
          'illusts': <dynamic>['5', 7, <String, dynamic>{'id': '6'}],
        }),
        <String>['7', '6', '5'],
      );
    });

    test('容器形状判定：Map/List/null 认识，其它算形状变化（用于如实报错）', () {
      expect(isPixivWorkIdContainer(null), isTrue);
      expect(isPixivWorkIdContainer(<String, dynamic>{}), isTrue);
      expect(isPixivWorkIdContainer(<dynamic>[]), isTrue);
      expect(isPixivWorkIdContainer('error'), isFalse);
      expect(isPixivWorkIdContainer(3), isFalse);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  //  A04 作品详情解析（profile/illusts）
  // ───────────────────────────────────────────────────────────────────────────

  group('A04 作品详情解析', () {
    test('从 body.works 的 **map** 取值（不是数组遍历），按 id 数值倒序', () {
      final works = parsePixivUserWorks(<String, dynamic>{
        'works': <String, dynamic>{
          '200': _workJson('200'),
          '100': _workJson('100'),
        },
        'illustSeries': <dynamic>[],
        'zoneConfig': <String, dynamic>{},
      });

      expect(works.map((work) => work.id).toList(), <String>['200', '100']);
      expect(works.first.title, 'title-200');
      expect(works.first.cover, contains('i.pximg.net'));
      expect(works.first.tags, <String>['tagA', 'tagB']);
      expect(works.first.pageCount, 2);
      expect(works.first.author, 'haku89');
    });

    test('容忍数组形态；坏条目（缺 id / 非数字）跳过', () {
      final works = parsePixivUserWorks(<String, dynamic>{
        'works': <dynamic>[
          _workJson('5'),
          <String, dynamic>{'title': 'no-id'},
          <String, dynamic>{'id': 'abc', 'title': 'bad-id'},
          _workJson('5'), // 重复
        ],
      });
      expect(works.map((work) => work.id).toList(), <String>['5']);
    });

    test('works 缺失或形状不认识时返回空（由网络层带实际形状报错）', () {
      expect(parsePixivUserWorks(<String, dynamic>{}), isEmpty);
      expect(
        parsePixivUserWorks(<String, dynamic>{'works': 'oops'}),
        isEmpty,
      );
      // 关键区分：Map 但值是 null（profile/all 的 id→null 形态）也解析不出东西，
      // 网络层会据此报"一条都没解析出来"而不是静默当空列表。
      expect(
        parsePixivUserWorks(<String, dynamic>{
          'works': <String, dynamic>{'100': null},
        }),
        isEmpty,
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  //  A05 诊断工具
  // ───────────────────────────────────────────────────────────────────────────

  group('A05 形状描述', () {
    test('null / Map / List / String / 其它类型都能如实描述', () {
      expect(describePixivJsonShape(null), 'null');
      expect(
        describePixivJsonShape(<String, dynamic>{'works': 1, 'zoneConfig': 2}),
        contains('works'),
      );
      expect(describePixivJsonShape(<dynamic>[1, 2, 3]), contains('长度 3'));
      expect(describePixivJsonShape('<!DOCTYPE html>'), contains('String'));
      expect(describePixivJsonShape(3), contains('int'));
    });

    test('超长 Map 截断键名但给出总数（避免日志被巨量键名淹没）', () {
      final shape = describePixivJsonShape(<String, dynamic>{
        for (var i = 0; i < 15; i++) 'k$i': null,
      });
      expect(shape, contains('k0'));
      expect(shape, contains('+5'));
    });
  });
}
