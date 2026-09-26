/// Pixiv 端点与响应键名契约测试（第十八轮补）。
///
/// ## 为什么需要这个文件
///
/// 2026-09 用**真实请求**复核 Pixiv Web Ajax 时，发现三处"站点侧变更 + 本端写法"
/// 叠在一起造成的**静默失效**——全都不报错、只是没内容，最难查：
///
/// 1. `illust/recommended-nologin` 已被 Pixiv 下线（404 + 日文 message），
///    探索页「推荐」分区只剩一句日文错误 → 改走 `illust/discovery?mode=all`；
/// 2. 搜索响应的列表键从 `illust` / `manga` 变成 **`illustManga`**，
///    且调用方原先把**整个响应**（而不是 `body`）喂给解析函数
///    → 搜索结果恒为空列表；
/// 3. `original` / `male` / `female` 三档榜单**只提供 `content=all`**，
///    带 `content=illust` 一律 404（其余四档相反）。
///
/// 这些事实**无法从代码本身看出来**（端点下线没有公告，键名变化只在响应里），
/// 所以把可断言的部分固定在这里：URL 拼装、键名兼容、页数解析的取值口径。
///
/// 全程**不出网**：只调静态 URL 构造函数与纯解析函数。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/explore/providers/pixiv_explore_provider.dart';
import 'package:picakeep/network/pixiv_network/pixiv_network.dart';
import 'package:picakeep/network/pixiv_network/pixiv_parsing.dart';

/// 一条贴近真实 `illust/discovery` 条目的样例（字段取自真实响应）。
Map<String, dynamic> _discoveryItem({
  required String id,
  String title = '無題',
  String user = 'K2N',
  int pageCount = 1,
  int illustType = pixivIllustTypeIllust,
  List<String> tags = const <String>['mdlstGL', 'ひかいの'],
}) =>
    <String, dynamic>{
      'id': id,
      'title': title,
      'illustType': illustType,
      'xRestrict': 0,
      'url': 'https://i.pximg.net/c/360x360_70/img-master/img/2026/09/16/'
          '22/48/20/${id}_p0_square1200.jpg',
      'description': '',
      'tags': tags,
      'userId': '129469954',
      'userName': user,
      'width': 2048,
      'height': 2048,
      'pageCount': pageCount,
      'isBookmarkable': true,
      'createDate': '2026-09-16T21:48:20+08:00',
    };

/// 一条贴近真实 `/ajax/search/artworks` 条目的样例。
Map<String, dynamic> _searchItem({required String id, String title = '朝'}) =>
    <String, dynamic>{
      'id': id,
      'title': title,
      'illustType': 0,
      'url': 'https://i.pximg.net/c/250x250_80_a2/img-master/img/2026/09/26/'
          '11/42/32/${id}_p0_square1200.jpg',
      'tags': <String>['初音ミク', 'VOCALOID'],
      'userId': '8721682',
      'userName': 'おーば',
      'width': 1086,
      'height': 1448,
      'pageCount': 1,
    };

void main() {
  group('推荐端点契约', () {
    test('走 illust/discovery，不再指向已下线的 recommended-nologin', () {
      final url = PixivNetwork.recommendedUrl();
      expect(url, contains('/ajax/illust/discovery'));
      // 回归守卫：这两个端点都已 404（实测），改回去会让推荐分区只能显示
      // 一句「无法找到您所请求的页面」。
      expect(url, isNot(contains('recommended-nologin')));
      expect(url, isNot(contains('recommended')));
    });

    test('带 mode=all：该端点的唯一合法取值', () {
      expect(PixivNetwork.pixivDiscoveryMode, 'all');
      expect(PixivNetwork.recommendedUrl(), contains('mode=all'));
    });

    test('带 lang=zh：Pixiv 的错误消息跟着这个参数走', () {
      // 不带时失败信息是日文（404 →「リクエストされたページが見つかりませんでした」，
      // 400 →「不正なリクエストです。」），会被原样显示给用户。
      expect(PixivNetwork.recommendedUrl(), contains('lang=zh'));
    });
  });

  group('榜单 content 推导', () {
    test('原创 / 男性向 / 女性向只有综合榜，必须用 content=all', () {
      for (final mode in const <String>['original', 'male', 'female']) {
        expect(
          PixivNetwork.rankingContentForMode(mode),
          'all',
          reason: '$mode 带 content=illust 会 404（实测）',
        );
      }
    });

    test('其余四档用 content=illust（用 all 会混进漫画）', () {
      for (final mode in const <String>['daily', 'weekly', 'monthly', 'rookie']) {
        expect(PixivNetwork.rankingContentForMode(mode), 'illust');
      }
    });

    test('未知榜期退回 illust（保守，不放大结果集）', () {
      expect(PixivNetwork.rankingContentForMode('something_new'), 'illust');
      expect(PixivNetwork.rankingContentForMode(''), 'illust');
    });

    test('探索页声明的每个榜期都能被网络层正确推导', () {
      // 守住"选项 ↔ 网络层"的联动：新增榜期时忘了同步推导规则，
      // 表现就是"选了那一档必然报错"。
      expect(pixivRankingOptions, isNotEmpty);
      for (final option in pixivRankingOptions) {
        final content = PixivNetwork.rankingContentForMode(option.id);
        expect(
          content,
          PixivNetwork.pixivRankingAllContentModes.contains(option.id)
              ? 'all'
              : 'illust',
        );
      }
    });
  });

  group('推荐（discovery）列表解析', () {
    test('body.illusts 的条目被逐字段取到', () {
      final items = parsePixivDiscoveryItems(<String, dynamic>{
        'illusts': <dynamic>[
          _discoveryItem(
            id: '149746200',
            title: '無題',
            user: 'K2N',
            pageCount: 4,
          ),
        ],
      });
      expect(items, hasLength(1));
      expect(items.first.id, '149746200');
      expect(items.first.title, '無題');
      expect(items.first.author, 'K2N');
      expect(items.first.pageCount, 4);
      expect(items.first.illustType, pixivIllustTypeIllust);
      expect(items.first.cover, contains('149746200_p0_square1200.jpg'));
      expect(items.first.tags, <String>['mdlstGL', 'ひかいの']);
      // 列表项没有简介，恒为空串（与搜索项一致）。
      expect(items.first.description, isEmpty);
    });

    test('tags 是纯字符串数组（不是 [{tag: ...}] 对象数组）', () {
      final items = parsePixivDiscoveryItems(<String, dynamic>{
        'illusts': <dynamic>[
          _discoveryItem(id: '1', tags: const <String>['a', 'b', 'a']),
        ],
      });
      // 同一条目内的重复标签按首次出现去重。
      expect(items.single.tags, <String>['a', 'b']);
    });

    test('坏条目跳过：缺 id / id 非数字 / 不是对象', () {
      final items = parsePixivDiscoveryItems(<String, dynamic>{
        'illusts': <dynamic>[
          _discoveryItem(id: '100'),
          <String, dynamic>{'title': '没有 id'},
          _discoveryItem(id: 'abc'),
          'not-a-map',
          _discoveryItem(id: '200'),
        ],
      });
      expect(items.map((item) => item.id), <String>['100', '200']);
    });

    test('重复 id 只保留第一条', () {
      final items = parsePixivDiscoveryItems(<String, dynamic>{
        'illusts': <dynamic>[
          _discoveryItem(id: '100', title: '第一次'),
          _discoveryItem(id: '100', title: '第二次'),
        ],
      });
      expect(items, hasLength(1));
      expect(items.single.title, '第一次');
    });

    test('illusts 不是数组（结构再变）时返回空列表且不抛', () {
      expect(
        parsePixivDiscoveryItems(<String, dynamic>{
          'illusts': <String, dynamic>{'100': null},
        }),
        isEmpty,
      );
      expect(parsePixivDiscoveryItems(const <String, dynamic>{}), isEmpty);
    });

    test('空列表是正常结果，不是异常', () {
      expect(
        parsePixivDiscoveryItems(<String, dynamic>{'illusts': <dynamic>[]}),
        isEmpty,
      );
    });

    test('不能拿「假搜索结构」套解析：这正是旧实现恒空的原因', () {
      // 旧实现把 body.illusts 包成 {'illust': {'data': [...]}} 再交给
      // parsePixivSearchItems；现在两者各自有对应的解析函数，
      // 这条断言用来钉住"discovery 的 body 直接就是数组"这一事实。
      final body = <String, dynamic>{
        'illusts': <dynamic>[_discoveryItem(id: '100')],
      };
      expect(parsePixivDiscoveryItems(body), hasLength(1));
      // 同一份 body 交给搜索解析函数取不到东西（它要的是 illustManga.data）。
      expect(parsePixivSearchItems(body), isEmpty);
    });
  });

  group('搜索键名兼容（illustManga）', () {
    test('新形状 body.illustManga.data 能被解析出来', () {
      final items = parsePixivSearchItems(<String, dynamic>{
        'illustManga': <String, dynamic>{
          'data': <dynamic>[_searchItem(id: '150120670')],
          'total': 619617,
          'lastPage': 10,
        },
      });
      expect(items, hasLength(1));
      expect(items.single.id, '150120670');
      expect(items.single.author, 'おーば');
      expect(items.single.tags, <String>['初音ミク', 'VOCALOID']);
    });

    test('旧形状 illust + manga 仍然可用（两类合并、illust 在前）', () {
      final items = parsePixivSearchItems(<String, dynamic>{
        'illust': <String, dynamic>{
          'data': <dynamic>[_searchItem(id: '1', title: '插画')],
        },
        'manga': <String, dynamic>{
          'data': <dynamic>[_searchItem(id: '2', title: '漫画')],
        },
      });
      expect(items.map((item) => item.id), <String>['1', '2']);
    });

    test('新旧键同时出现时以 illustManga 优先，并按 id 去重', () {
      final items = parsePixivSearchItems(<String, dynamic>{
        'illustManga': <String, dynamic>{
          'data': <dynamic>[_searchItem(id: '1', title: '新形状')],
        },
        'illust': <String, dynamic>{
          'data': <dynamic>[
            _searchItem(id: '1', title: '旧形状里的同一条'),
            _searchItem(id: '3', title: '只在旧形状里'),
          ],
        },
      });
      expect(items.map((item) => item.id), <String>['1', '3']);
      expect(items.first.title, '新形状');
    });

    test('完全陌生的结构返回空列表（不抛）', () {
      expect(parsePixivSearchItems(const <String, dynamic>{}), isEmpty);
      expect(
        parsePixivSearchItems(<String, dynamic>{'whatever': <dynamic>[]}),
        isEmpty,
      );
    });
  });

  group('搜索末页页码解析', () {
    test('取 lastPage，绝不把 total（总条数）当页数', () {
      // 真实响应：total = 619617（总条数）、lastPage = 10（末页页码）。
      // 把 total 当页数会让搜索页以为能翻 61 万页。
      expect(
        parsePixivSearchMaxPage(<String, dynamic>{
          'illustManga': <String, dynamic>{
            'lastPage': 10,
            'total': 619617,
          },
        }),
        10,
      );
    });

    test('只有 total 时返回 null（宁可退回保守判停）', () {
      expect(
        parsePixivSearchMaxPage(<String, dynamic>{
          'illustManga': <String, dynamic>{'total': 619617},
        }),
        isNull,
      );
    });

    test('旧形状的 lastPage 位置仍能取到', () {
      expect(
        parsePixivSearchMaxPage(<String, dynamic>{
          'illust': <String, dynamic>{'lastPage': 5},
        }),
        5,
      );
    });

    test('嵌套的 pagination.lastPage 也能取到', () {
      expect(
        parsePixivSearchMaxPage(<String, dynamic>{
          'illustManga': <String, dynamic>{
            'pagination': <String, dynamic>{'lastPage': 7},
          },
        }),
        7,
      );
    });

    test('结构完全变化时返回 null 且不抛', () {
      expect(parsePixivSearchMaxPage(const <String, dynamic>{}), isNull);
      expect(
        parsePixivSearchMaxPage(<String, dynamic>{
          'illustManga': <String, dynamic>{'lastPage': '十'},
        }),
        isNull,
      );
      expect(
        parsePixivSearchMaxPage(<String, dynamic>{
          'illustManga': <String, dynamic>{'lastPage': 0},
        }),
        isNull,
      );
    });
  });

  group('作者页 URL 契约', () {
    test('作者资料带 full=1 与 lang=zh', () {
      final url = PixivNetwork.authorInfoUrl('8721682');
      expect(url, endsWith('/ajax/user/8721682?full=1&lang=zh'));
    });

    test('作者作品 id 列表带 lang=zh', () {
      final url = PixivNetwork.authorWorkIdsUrl('8721682');
      expect(url, endsWith('/ajax/user/8721682/profile/all?lang=zh'));
    });

    test('批量取详情：ids[] 重复出现，不能拼成逗号串', () {
      final url = PixivNetwork.authorWorksUrl(
        '8721682',
        const <String>['150095039', '150098866'],
      );
      expect(url, contains('work_category=illustManga'));
      expect(url, contains('is_first_page=0'));
      expect(url, contains('lang=zh'));
      expect(url, contains('&ids[]=150095039'));
      expect(url, contains('&ids[]=150098866'));
      expect(url, isNot(contains('ids[]=150095039,')));
      expect(url, isNot(contains('ids=150095039')));
    });
  });
}
