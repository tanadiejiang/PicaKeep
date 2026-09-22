/// 四源探索解析的夹具测试。
///
/// 覆盖计划里点名的风险：坏项计数、空数组 vs 全坏项、末页分母、EH 榜单名次列
/// 与相对 next、NH 裸 option ID 映射。全部是纯解析断言，不出网。
library;

import 'package:picakeep/foundation/explore/providers/nhentai_explore_options.dart';
import 'package:picakeep/network/eh_network/eh_brief_models.dart';
import 'package:picakeep/network/eh_network/eh_list_parsing.dart';
import 'package:picakeep/network/jm_network/jm_parsing.dart';
import 'package:picakeep/network/picacg_network/picacg_parsing.dart';
import 'package:test/test.dart';

// ── JM ──────────────────────────────────────────────────────────────────────

Map<String, dynamic> _jmComic(Object? id, {String name = 'N'}) =>
    <String, dynamic>{
      'id': id,
      'name': name,
      'author': <String>['A'],
      'category': <String, dynamic>{'id': 1, 'title': '同人'},
      'category_sub': <String, dynamic>{'id': 2, 'title': '短篇'},
    };

void main() {
  group('JM 列表解析', () {
    test('有效数字 id 通过，空串与字面量 null 被否掉', () {
      expect(isValidJmComicId(123), isTrue);
      expect(isValidJmComicId('456'), isTrue);
      expect(isValidJmComicId(''), isFalse);
      expect(isValidJmComicId(null), isFalse);
      expect(isValidJmComicId('null'), isFalse);
      expect(isValidJmComicId('abc'), isFalse);
    });

    test('部分坏项：保留合法结果并计数坏项', () {
      final result = parseJmListItems(<dynamic>[
        _jmComic(1),
        _jmComic(null),
        _jmComic('abc'),
        _jmComic(2),
      ]);
      expect(result.parsed.map((e) => e.id), <String>['1', '2']);
      expect(result.invalid, 2);
    });

    test('非空但全坏项：解析结果为空且 invalid 等于原始条数', () {
      final result = parseJmListItems(<dynamic>[
        _jmComic(null),
        _jmComic(''),
      ]);
      expect(result.parsed, isEmpty);
      expect(result.invalid, 2);
    });

    test('正常空数组：解析为空且没有坏项', () {
      final result = parseJmListItems(const <dynamic>[]);
      expect(result.parsed, isEmpty);
      expect(result.invalid, 0);
    });
  });

  group('JM 页数推算（末页不放大）', () {
    test('末页短页用原始记录数作分母', () {
      // total = 25，末页原始 5 条（解析成功 4 条）→ 应为 5 页，而不是 7 页。
      expect(jmPageCount(total: 25, rawCount: 5, page: 5), 5);
    });

    test('总分母靠原始记录数，不受解析成功数影响', () {
      expect(jmPageCount(total: 100, rawCount: 20, page: 1), 5);
    });

    test('total 缺失时按当前页收口（不编造假页数）', () {
      expect(jmPageCount(total: 0, rawCount: 20, page: 3), 3);
      expect(jmPageCount(total: -1, rawCount: 0, page: 2), 2);
    });
  });

  group('JM 分类目录', () {
    test('保留层级与原始 name/slug/CID', () {
      final categories = parseJmCategories(<String, dynamic>{
        'categories': <dynamic>[
          <String, dynamic>{
            'name': '成人A漫',
            'slug': 'adult',
            'sub_categories': <dynamic>[
              <String, dynamic>{'CID': 11, 'name': '同人', 'slug': 'doujin'},
              <String, dynamic>{'CID': 12, 'name': '單本', 'slug': 'single'},
            ],
          },
        ],
      });
      expect(categories, hasLength(1));
      expect(categories.single.name, '成人A漫');
      expect(categories.single.slug, 'adult');
      expect(categories.single.subCategories.map((e) => e.slug),
          <String>['doujin', 'single']);
      expect(categories.single.subCategories.first.cid, '11');
    });

    test('子分类 slug 缺失保留空串，不归零成 0', () {
      final categories = parseJmCategories(<String, dynamic>{
        'categories': <dynamic>[
          <String, dynamic>{
            'name': 'X',
            'slug': 'x',
            'sub_categories': <dynamic>[
              <String, dynamic>{'CID': 1, 'name': '未知'},
            ],
          },
        ],
      });
      expect(categories.single.subCategories.single.slug, isEmpty);
    });

    test('缺少 categories 字段抛 parse 而不是返回空目录', () {
      expect(
          () => parseJmCategories(<String, dynamic>{}), throwsFormatException);
    });
  });

  group('JM 排序与每周推荐类型', () {
    test('七项排序值与原项目一致，未知值不静默回落', () {
      expect(JmComicsOrder.tryFromValue('mr'), JmComicsOrder.latest);
      expect(JmComicsOrder.tryFromValue('mv'), JmComicsOrder.totalRanking);
      expect(JmComicsOrder.tryFromValue('mv_m'), JmComicsOrder.monthRanking);
      expect(JmComicsOrder.tryFromValue('mv_w'), JmComicsOrder.weekRanking);
      expect(JmComicsOrder.tryFromValue('mv_t'), JmComicsOrder.dayRanking);
      expect(JmComicsOrder.tryFromValue('mp'), JmComicsOrder.maxPictures);
      expect(JmComicsOrder.tryFromValue('tf'), JmComicsOrder.maxLikes);
      expect(JmComicsOrder.tryFromValue('nope'), isNull);
    });

    test('每周推荐三个月类型，每次只取一个', () {
      expect(JmWeekType.tryFromValue('hanman'), JmWeekType.hanman);
      expect(JmWeekType.tryFromValue('manga'), JmWeekType.manga);
      expect(JmWeekType.tryFromValue('another'), JmWeekType.another);
      expect(JmWeekType.tryFromValue('both'), isNull);
    });
  });

  group('JM promote 概览', () {
    test('保留 title/type/id/slug；category_id 块以 slug 为更多目标', () {
      final sections = parseJmPromoteSections(<dynamic>[
        <String, dynamic>{
          'title': '编辑推荐',
          'type': 'promote',
          'id': 77,
          'slug': '',
          'content': <dynamic>[_jmComic(1)],
        },
        <String, dynamic>{
          'title': '同人',
          'type': 'category_id',
          'id': 5,
          'slug': 'doujin',
          'content': <dynamic>[_jmComic(2)],
        },
        <String, dynamic>{
          'title': '未知块',
          'type': 'mystery',
          'id': 9,
          'slug': '',
          'content': <dynamic>[_jmComic(3)],
        },
      ]);
      expect(sections, hasLength(3));
      expect(sections[0].id, '77');
      expect(sections[0].hasMoreTarget, isTrue);
      expect(sections[1].id, 'doujin');
      expect(sections[1].hasMoreTarget, isTrue);
      // 未知 type 保留内容，但不给"更多"目标。
      expect(sections[2].comics, hasLength(1));
      expect(sections[2].hasMoreTarget, isFalse);
    });

    test('顶层不是数组时抛 parse', () {
      expect(() => parseJmPromoteSections(<String, dynamic>{}),
          throwsFormatException);
    });
  });

  group('JM promote_list 分页', () {
    test('loaded 按原始记录数推进，含坏项', () {
      final list = parseJmPromoteList(
        'p1',
        <String, dynamic>{
          'total': 10,
          'list': <dynamic>[_jmComic(1), _jmComic(null), _jmComic(2)],
        },
        page: 0,
      );
      expect(list.comics, hasLength(2));
      expect(list.loaded, 3);
      expect(list.hasMore, isTrue);
    });

    test('非空但全坏项抛 parse', () {
      expect(
        () => parseJmPromoteList(
          'p1',
          <String, dynamic>{
            'total': 5,
            'list': <dynamic>[_jmComic(null)],
          },
          page: 0,
        ),
        throwsFormatException,
      );
    });
  });

  group('JM 每周推荐', () {
    test('期号解析保留 id 与 time', () {
      final periods = parseJmWeekPeriods(<String, dynamic>{
        'categories': <dynamic>[
          <String, dynamic>{'id': 1001, 'time': '2026-08-01 ~ 2026-08-07'},
        ],
      });
      expect(periods.single.id, '1001');
      expect(periods.single.time, contains('2026-08-01'));
    });

    test('内容非空但全坏项抛 parse', () {
      expect(
        () => parseJmWeekComics(<String, dynamic>{
          'list': <dynamic>[_jmComic(null)],
        }),
        throwsFormatException,
      );
    });
  });

  group('Picacg 容器解析', () {
    Map<String, dynamic> comicDoc(String id) => <String, dynamic>{
          '_id': id,
          'title': 'T',
          'author': 'A',
          'likesCount': 1,
          'thumb': <String, dynamic>{
            'fileServer': 'https://s.example',
            'path': 'p.jpg',
          },
        };

    test('docs/pages 容器：pages 保留，docs 空数组是空成功', () {
      final docs = parsePicacgComicDocs(<dynamic>[]);
      expect(docs.parsed, isEmpty);
      expect(docs.invalid, 0);
      final parsed = parsePicacgComicDocs(<dynamic>[comicDoc('a')]);
      expect(parsed.parsed.single.id, 'a');
      expect(parsed.invalid, 0);
    });

    test('非空数组但条目全缺 ID：全部计入 invalid', () {
      final parsed = parsePicacgComicDocs(<dynamic>[
        <String, dynamic>{'title': 'x'},
        <String, dynamic>{'title': 'y'},
      ]);
      expect(parsed.parsed, isEmpty);
      expect(parsed.invalid, 2);
    });

    test('部分坏项：保留合法项并计数', () {
      final parsed = parsePicacgComicDocs(<dynamic>[
        comicDoc('a'),
        <String, dynamic>{'title': 'no-id'},
        comicDoc('b'),
      ]);
      expect(parsed.parsed.map((e) => e.id), <String>['a', 'b']);
      expect(parsed.invalid, 1);
    });

    test('分类目录过滤 isWeb 保留原始 title', () {
      final categories = parsePicacgCategories(<String, dynamic>{
        'categories': <dynamic>[
          <String, dynamic>{'title': '同人', 'isWeb': false},
          <String, dynamic>{'title': '外链', 'isWeb': true},
        ],
      });
      expect(categories.map((e) => e.title), <String>['同人', '外链']);
      expect(categories.first.isWeb, isFalse);
    });

    test('推荐集合支持 0 / 1 / 多组，保留标题', () {
      expect(
        parsePicacgCollections(<String, dynamic>{'collections': <dynamic>[]}),
        isEmpty,
      );
      final multi = parsePicacgCollections(<String, dynamic>{
        'collections': <dynamic>[
          <String, dynamic>{
            '_id': 'c1',
            'title': '本子母',
            'comics': <dynamic>[comicDoc('a')],
          },
          <String, dynamic>{
            '_id': 'c2',
            'title': '本子妹',
            'comics': <dynamic>[comicDoc('b'), comicDoc('c')],
          },
        ],
      });
      expect(multi.map((e) => e.title), <String>['本子母', '本子妹']);
      expect(multi[1].comics, hasLength(2));
    });

    test('榜期只有 H24/D7/D30，没有总榜', () {
      expect(picacgLeaderboardPeriods, <String>['H24', 'D7', 'D30']);
      expect(picacgLeaderboardPeriods.contains('all'), isFalse);
    });

    test('排序取值与搜索一致', () {
      expect(picacgSorts, <String>['dd', 'da', 'ld', 'vd']);
    });
  });

  group('EH 列表解析', () {
    /// 普通 compact 列表（无 rank 列）。
    ///
    /// 结构对齐真实站点：**5 个平铺 td**（类型 / 封面 / 时间+星级 / 标题+标签 /
    /// 上传者+页数），不是嵌套在同一 td 里。
    String compactHtml({required String nextHref}) => '''
<html><body>
<table class="itg gltc"><tbody>
<tr>
  <td><div class="cs">Doujinshi</div></td>
  <td><div><a href="/g/1/aaaa/"><div><img src="https://ehgt.org/1.jpg"></div></a></div></td>
  <td><div>2026-01-01 00:00</div><div class="ir" style="background-position:0px -1px;"></div></td>
  <td><a href="/g/1/aaaa/"><div><div class="glink">标题一</div><div><div title="artist:foo"></div></div></div></a></td>
  <td><div><a>uploader</a></div><div>12 pages</div></td>
</tr>
</tbody></table>
<a id="dnext" href="$nextHref">Next</a>
</body></html>
''';

    /// 榜单 compact 列表（首列是名次，列整体后移一位）。
    String toplistHtml({required String nextHref}) => '''
<html><body>
<table class="itg gltc"><tbody>
<tr>
  <td>1</td>
  <td><div class="cs">Manga</div></td>
  <td><div><a href="/g/9/bbbb/"><div><img src="https://ehgt.org/9.jpg"></div></a></div></td>
  <td><div>2026-02-02 00:00</div><div class="ir" style="background-position:0px -21px;"></div></td>
  <td><a href="/g/9/bbbb/"><div><div class="glink">榜单标题</div><div><div title="female:bar"></div></div></div></a></td>
  <td><div><a>uploader2</a></div><div>20 pages</div></td>
</tr>
</tbody></table>
<table class="ptt"><tbody><tr>
  <td><a href="$nextHref">&gt;</a></td>
</tr></tbody></table>
</body></html>
''';

    test('普通 compact：解析条目与 #dnext 游标', () {
      final parsed = parseEhGalleryList(
        compactHtml(nextHref: '/?p=1'),
        responseUri: 'https://e-hentai.org/?p=0',
      );
      expect(parsed.galleries, hasLength(1));
      expect(parsed.galleries.single.title, '标题一');
      expect(parsed.galleries.single.tags, <String>['artist:foo']);
      expect(parsed.failedRowCount, 0);
      expect(parsed.next, 'https://e-hentai.org/?p=1');
    });

    test('榜单 compact：名次列偏移正确，rank 列不被当分类', () {
      final parsed = parseEhGalleryList(
        toplistHtml(nextHref: 'toplist.php?tl=15&p=1'),
        responseUri: 'https://e-hentai.org/toplist.php?tl=15&p=0',
        leaderboard: true,
      );
      expect(parsed.galleries, hasLength(1));
      final brief = parsed.galleries.single;
      expect(brief.title, '榜单标题');
      // 名次"1"不得被当成分类；分类应为 Manga。
      expect(brief.type, 'Manga');
      expect(brief.pages, 20);
      expect(brief.tags, <String>['female:bar']);
      // 榜单分页走 table.ptt，而不是 #dnext。
      expect(parsed.next, 'https://e-hentai.org/toplist.php?tl=15&p=1');
    });

    test('榜单末页没有 > 链接时 next 为 null（正确停止）', () {
      final html = toplistHtml(nextHref: 'toplist.php?tl=15&p=1')
          .replaceAll('&gt;', '&lt;');
      final parsed = parseEhGalleryList(
        html,
        responseUri: 'https://e-hentai.org/toplist.php?tl=15&p=2',
        leaderboard: true,
      );
      expect(parsed.next, isNull);
      expect(parsed.galleries, hasLength(1));
    });

    test('相对 next 按最终响应地址解析（重定向后 origin 改变）', () {
      final parsed = parseEhGalleryList(
        compactHtml(nextHref: '/?p=2'),
        responseUri: 'https://exhentai.org/?p=1',
      );
      expect(parsed.next, 'https://exhentai.org/?p=2');
    });

    test('自环 next 被丢弃（不产生无限翻页）', () {
      final parsed = parseEhGalleryList(
        compactHtml(nextHref: 'https://e-hentai.org/?p=1'),
        responseUri: 'https://e-hentai.org/?p=1',
      );
      expect(parsed.next, isNull);
    });

    test('非允许站点的 next 被丢弃', () {
      final parsed = parseEhGalleryList(
        compactHtml(nextHref: 'https://evil.example/?p=2'),
        responseUri: 'https://e-hentai.org/?p=1',
      );
      expect(parsed.next, isNull);
    });

    test('识别到数据行却全部解析失败：allRowsFailed 为 true', () {
      final broken = compactHtml(nextHref: '/?p=1').replaceAll(
        '/g/1/aaaa/',
        'https://example.com/not-a-gallery',
      );
      final parsed = parseEhGalleryList(
        broken,
        responseUri: 'https://e-hentai.org/?p=0',
      );
      expect(parsed.galleries, isEmpty);
      expect(parsed.rawRowCount, greaterThan(0));
      expect(parsed.allRowsFailed, isTrue);
    });

    test('明确无数据页：没有数据行，也不是解析异常', () {
      final parsed = parseEhGalleryList(
        '<html><body><p>No hits found</p></body></html>',
        responseUri: 'https://e-hentai.org/?p=0',
      );
      expect(parsed.galleries, isEmpty);
      expect(parsed.rawRowCount, 0);
      expect(parsed.allRowsFailed, isFalse);
      expect(parsed.next, isNull);
      // 页面里没有列表容器 → 这是真的"无结果"，不是解析故障。
      expect(parsed.containerFound, isFalse);
      expect(parsed.isParseFailure, isFalse);
    });

    test('列表容器存在却一行都解析不出：必须判为解析失败（不是空结果）', () {
      // 这是用户真机报的"EH 加载不出任何内容"的**可诊断化**保障：
      // 结构变了时必须报错，而不是静默显示"没有内容"。
      final parsed = parseEhGalleryList(
        '<html><body><table class="itg"><tbody></tbody></table></body></html>',
        responseUri: 'https://e-hentai.org/?p=0',
      );
      expect(parsed.galleries, isEmpty);
      expect(parsed.rawRowCount, 0);
      expect(parsed.containerFound, isTrue);
      expect(parsed.isParseFailure, isTrue);
    });

    test('compact 列顺序被打乱仍能按特征解析（不依赖列下标）', () {
      // 关键回归：早先的实现写死"第 0 列是类型、第 2 列是时间"，
      // 站点增删列（榜单名次列、收藏夹页少上传者列）就会整行失败。
      // 这里把列**完全倒序**排布，模拟"结构变了但语义没变"。
      const shuffled = '''
<html><body>
<table class="itg gltc"><tbody>
<tr>
  <td><div><a>上传者X</a></div><div>37 pages</div></td>
  <td><a href="/g/42/deadbeef00/"><div><div class="glink">倒序标题</div><div><div title="artist:someone"></div></div></div></a></td>
  <td><div>2026-06-06 12:00</div><div class="ir" style="background-position:-16px -1px;"></div></td>
  <td><div><a href="/g/42/deadbeef00/"><div><img src="https://ehgt.org/42.jpg"></div></a></div></td>
  <td><div class="cs">Artist CG</div></td>
</tr>
</tbody></table>
<a id="dnext" href="/?p=1">Next</a>
</body></html>
''';
      final parsed = parseEhGalleryList(
        shuffled,
        responseUri: 'https://e-hentai.org/?p=0',
      );
      expect(parsed.galleries, hasLength(1));
      final brief = parsed.galleries.single;
      expect(brief.title, '倒序标题');
      expect(brief.type, 'Artist CG');
      expect(brief.link, 'https://e-hentai.org/g/42/deadbeef00/');
      expect(brief.tags, <String>['artist:someone']);
      expect(brief.pages, 37);
      expect(brief.uploader, '上传者X');
      expect(brief.time, '2026-06-06 12:00');
      // 4.0 星 = background-position:-16px -1px
      expect(brief.stars, 4);
      expect(parsed.failedRowCount, 0);
      // 封面/标题/上传者三类链接不会互相污染上传者字段。
      expect(brief.coverPath, 'https://ehgt.org/42.jpg');
    });

    test('懒加载封面：src 是占位时回退 data-src', () {
      const lazy = '''
<html><body>
<table class="itg gltc"><tbody>
<tr>
  <td><div class="cs">Doujinshi</div></td>
  <td><div><a href="/g/7/abcdef0123/"><div><img src="data:image/gif;base64,R0lGOD" data-src="https://ehgt.org/7.jpg"></div></a></div></td>
  <td><div>2026-07-07 00:00</div><div class="ir" style="background-position:0px -1px;"></div></td>
  <td><a href="/g/7/abcdef0123/"><div><div class="glink">懒加载</div></div></a></td>
  <td><div><a>up7</a></div><div>9 pages</div></td>
</tr>
</tbody></table>
</body></html>
''';
      final parsed = parseEhGalleryList(
        lazy,
        responseUri: 'https://e-hentai.org/?p=0',
      );
      expect(parsed.galleries.single.coverPath, 'https://ehgt.org/7.jpg');
    });

    test('四种布局的其它三种可按各自结构解析', () {
      const thumbnail = '''
<html><body>
<div class="gl1t">
  <a href="https://e-hentai.org/g/2/cccc/">缩略图布局</a>
  <img src="https://ehgt.org/2.jpg">
  <div class="gl5t"><div><div class="cs">Manga</div></div>
  <div><div>2026-03-03 00:00</div></div>
  <div><div class="ir" style="background-position:0px -1px;"></div></div>
  <div><div>8 pages</div></div></div>
</div>
</body></html>''';
      final thumbParsed = parseEhGalleryList(thumbnail,
          responseUri: 'https://e-hentai.org/?p=0');
      expect(thumbParsed.galleries, hasLength(1));
      expect(thumbParsed.galleries.single.type, 'Manga');

      const extended = '''
<html><body>
<table class="itg glte"><tbody><tr>
  <td class="gl1e"><div><a href="https://e-hentai.org/g/3/dddd/"><img src="https://ehgt.org/3.jpg"></a></div></td>
  <td class="gl2e"><div>
    <a href="https://e-hentai.org/g/3/dddd/"><div><div class="glink">扩展布局</div></div></a>
    <div class="gl3e">
      <div class="cn">Doujinshi</div>
      <div>2026-04-04 00:00</div>
      <div class="ir" style="background-position:0px -1px;"></div>
      <div><a>up</a></div>
      <div>5 pages</div>
    </div>
  </div></td>
</tr></tbody></table>
<div class="gt" title="artist:zzz"></div>
</body></html>''';
      final extParsed = parseEhGalleryList(extended,
          responseUri: 'https://e-hentai.org/?p=0');
      expect(extParsed.galleries, hasLength(1));
      expect(extParsed.galleries.single.type, 'Doujinshi');

      const minimal = '''
<html><body>
<table class="itg gltm"><tbody><tr>
  <td class="gl1m"><div class="cs">Manga</div></td>
  <td class="gl2m"><div>2026-05-05 00:00</div><div><div><img src="https://ehgt.org/4.jpg"></div></div></td>
  <td class="gl3m"><a href="https://e-hentai.org/g/4/eeee/"><div class="glink">最小布局</div></a></td>
  <td class="gl4m"><div class="ir" style="background-position:0px -1px;"></div></td>
  <td class="gl5m"><div><a>up4</a></div></td>
</tr></tbody></table>
</body></html>''';
      final minParsed =
          parseEhGalleryList(minimal, responseUri: 'https://e-hentai.org/?p=0');
      expect(minParsed.galleries, hasLength(1));
      expect(minParsed.galleries.single.title, '最小布局');
    });
  });

  group('EH 画廊类型与榜期', () {
    test('十项类型顺序与原项目一致', () {
      expect(EhGalleryCategory.values.map((e) => e.label), <String>[
        'Misc',
        'Doujinshi',
        'Manga',
        'Artist CG',
        'Game CG',
        'Image Set',
        'Cosplay',
        'Asian Porn',
        'Non-H',
        'Western',
      ]);
    });

    test('单类型 f_cats 为反码，全部为 0', () {
      expect(EhGalleryCategory.allFCats, 0);
      // index 0 (Misc) → 1023 ^ 1 = 1022
      expect(EhGalleryCategory.misc.singleFCats, 1022);
      // 原项目对 Doujinshi 用的是 1021
      expect(EhGalleryCategory.doujinshi.singleFCats, 1021);
      expect(EhGalleryCategory.manga.singleFCats, 1019);
    });

    test('榜期沿用站点口径（昨天不叫今日）', () {
      expect(EhToplistPeriod.yesterday.value, '15');
      expect(EhToplistPeriod.yesterday.label, '昨天');
      expect(EhToplistPeriod.month.value, '13');
      expect(EhToplistPeriod.year.value, '12');
      expect(EhToplistPeriod.all.value, '11');
      expect(EhToplistPeriod.tryFromId('yesterday'), EhToplistPeriod.yesterday);
      expect(EhToplistPeriod.tryFromId('today'), isNull);
    });
  });

  group('NH option 映射与查询组装', () {
    test('裸 option ID 映射到 v2 sort 参数', () {
      expect(nhentaiSortParamForOptionId('recent'), 'date');
      expect(nhentaiSortParamForOptionId('popular-today'), 'popular-today');
      expect(nhentaiSortParamForOptionId('popular-week'), 'popular-week');
      expect(nhentaiSortParamForOptionId('popular-month'), 'popular-month');
      expect(nhentaiSortParamForOptionId('popular'), 'popular');
    });

    test('未知裸 option ID 返回 null，不静默降级成最新', () {
      expect(nhentaiSortParamForOptionId('sort=popular'), isNull);
      expect(nhentaiSortParamForOptionId('nope'), isNull);
    });

    test('四档热门榜单不含"最新"', () {
      expect(isNhentaiRankingOptionId('popular-today'), isTrue);
      expect(isNhentaiRankingOptionId('popular'), isTrue);
      expect(isNhentaiRankingOptionId('recent'), isFalse);
      expect(isNhentaiRankingOptionId('nope'), isFalse);
    });

    test('三种语言分类各自生成单个 language: 查询', () {
      expect(
          NhentaiLanguageIds.all, <String>['chinese', 'japanese', 'english']);
      expect(NhentaiLanguageIds.all, hasLength(3));
    });

    test('多词 / 标点标签加引号，单标签原样', () {
      expect(buildNhentaiTagQuery('sole female'), '"sole female"');
      expect(buildNhentaiTagQuery('big breasts'), '"big breasts"');
      expect(buildNhentaiTagQuery('lolicon'), 'lolicon');
      expect(buildNhentaiTagQuery('  spaced  '), 'spaced');
      expect(buildNhentaiTagQuery(''), isNull);
    });

    test('内部引号被去掉（NH 不支持转义引号）', () {
      expect(buildNhentaiTagQuery('a "b" c'), '"a b c"');
    });
  });
}
