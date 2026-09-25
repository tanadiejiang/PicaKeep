/// Pixiv 解析纯函数与 ID 提取的夹具测试（第十八轮）。
///
/// 全程不出网：只调 `pixiv_parsing.dart` 的顶层纯函数与
/// `favorite_source_id.dart` 的 `extractPixivNumericId`。
///
/// 覆盖计划 03 号点名的风险：
/// - 详情字段名与调研文档不一致（Ajax API 非官方、文档已停维护）
/// - 标签翻译优先 / HTML 简介清洗
/// - 搜索响应 illust + manga 两段合并去重
/// - Ugoira 帧解析
/// - ID 提取不误命中非 Pixiv 链接
library;

import 'package:picakeep/foundation/favorite_source_id.dart';
import 'package:picakeep/network/pixiv_network/pixiv_parsing.dart';
import 'package:test/test.dart';

/// 一份贴近真实 `/ajax/illust/{id}` 响应的 `body`。
Map<String, dynamic> _detailBody() => <String, dynamic>{
      'illustId': '100412238',
      'illustTitle': '测试作品',
      'illustComment': '第一行<br />第二行 &amp; 转义',
      'illustType': 0,
      'userId': '12345',
      'userName': '画师名',
      'userAccount': 'painter',
      'urls': <String, dynamic>{
        'mini': 'https://i.pximg.net/mini.jpg',
        'thumb': 'https://i.pximg.net/thumb.jpg',
        'small': 'https://i.pximg.net/small.jpg',
        'regular': 'https://i.pximg.net/regular.jpg',
        'original': 'https://i.pximg.net/original.jpg',
      },
      'width': 1200,
      'height': 1700,
      'pageCount': 3,
      'likeCount': 42,
      'viewCount': 999,
      'createDate': '2026-01-02T03:04:05+09:00',
      'uploadDate': '2026-01-02T03:04:05+09:00',
      'isOriginal': true,
      'tags': <String, dynamic>{
        'tags': <dynamic>[
          <String, dynamic>{
            'tag': 'オリジナル',
            'translation': <String, dynamic>{'en': 'original'},
          },
          <String, dynamic>{
            'tag': '女の子',
            'translation': <String, dynamic>{'zh': '女孩'},
          },
          // 无 translation 的项必须保留原 tag。
          <String, dynamic>{'tag': 'R-18'},
          // 空 tag 必须被过滤。
          <String, dynamic>{'tag': ''},
        ],
      },
    };

void main() {
  group('Pixiv 详情解析', () {
    test('核心字段逐个对上', () {
      final info = parsePixivComicInfo(_detailBody());
      expect(info.id, '100412238');
      expect(info.title, '测试作品');
      expect(info.author, '画师名');
      expect(info.authorId, '12345');
      // 详情封面取 original 档（详情页信息区用原图，与 Pixiv 网页一致）。
      expect(info.coverUrl, 'https://i.pximg.net/original.jpg');
      expect(info.pageCount, 3);
      expect(info.likeCount, 42);
      expect(info.viewCount, 999);
      expect(info.illustType, pixivIllustTypeIllust);
      expect(info.isOriginal, isTrue);
    });

    test('标签优先取翻译名，无翻译保留原名，空 tag 被过滤', () {
      final info = parsePixivComicInfo(_detailBody());
      expect(info.tags, contains('original'));
      expect(info.tags, contains('女孩'));
      expect(info.tags, contains('R-18'));
      expect(info.tags, isNot(contains('')));
    });

    test('HTML 简介被清洗（<br> 转换行、实体解码、其余标签剥离）', () {
      final info = parsePixivComicInfo(_detailBody());
      expect(info.description, isNot(contains('<br')));
      expect(info.description, contains('第一行'));
      expect(info.description, contains('第二行'));
      expect(info.description, contains('&'));
      expect(info.description, isNot(contains('&amp;')));
    });

    test('缺字段不崩：空 body 抛 FormatException 而不是 TypeError', () {
      expect(
        () => parsePixivComicInfo(<String, dynamic>{}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('Pixiv 标签剥离与实体解码', () {
    test('stripPixivHtml 处理常见实体与标签', () {
      expect(stripPixivHtml('a<br>b'), contains('a'));
      expect(stripPixivHtml('a<br>b'), contains('b'));
      expect(stripPixivHtml('<a href="x">link</a>'), 'link');
      expect(stripPixivHtml('&lt;x&gt;'), '<x>');
      expect(stripPixivHtml('&quot;q&quot;'), '"q"');
      expect(stripPixivHtml("&#39;"), "'");
    });
  });

  group('Pixiv 分页解析', () {
    test('pages 数组按顺序解析且字段完整', () {
      final pages = parsePixivPages(<dynamic>[
        <String, dynamic>{
          'urls': <String, dynamic>{
            'thumb_mini': 't1',
            'small': 's1',
            'regular': 'r1',
            'original': 'o1',
          },
          'width': 100,
          'height': 200,
        },
        <String, dynamic>{
          'urls': <String, dynamic>{
            'thumb_mini': 't2',
            'small': 's2',
            'regular': 'r2',
            'original': 'o2',
          },
          'width': 300,
          'height': 400,
        },
      ]);
      expect(pages, hasLength(2));
      expect(pages[0].regular, 'r1');
      expect(pages[0].original, 'o1');
      expect(pages[0].width, 100);
      expect(pages[1].regular, 'r2');
      expect(pages[1].height, 400);
    });
  });

  group('Pixiv Ugoira 帧解析', () {
    test('frames/delay 与 zip 地址解析', () {
      final meta = parsePixivUgoiraMeta(<String, dynamic>{
        'frames': <dynamic>[
          <String, dynamic>{'file': '000000.jpg', 'delay': 60},
          <String, dynamic>{'file': '000001.jpg', 'delay': 80},
        ],
        'mime_type': 'image/jpeg',
        'originalSrc': 'https://i.pximg.net/orig.zip',
        'src': 'https://i.pximg.net/zip.zip',
      });
      expect(meta.frames, hasLength(2));
      expect(meta.frames[0].file, '000000.jpg');
      expect(meta.frames[0].delay, 60);
      expect(meta.frames[1].delay, 80);
      expect(meta.mimeType, 'image/jpeg');
      expect(meta.src, 'https://i.pximg.net/zip.zip');
    });
  });

  group('Pixiv 搜索解析', () {
    test('illust 与 manga 两段合并，且按 id 去重', () {
      final items = parsePixivSearchItems(<String, dynamic>{
        'illust': <String, dynamic>{
          'data': <dynamic>[
            <String, dynamic>{
              'id': '1',
              'title': '插画一',
              'url': 'https://i.pximg.net/1.jpg',
              'tags': <dynamic>['a'],
              'illustType': 0,
              'pageCount': 1,
              'userId': 'u1',
              'userName': 'A',
            },
            <String, dynamic>{
              'id': '2',
              'title': '插画二',
              'url': 'https://i.pximg.net/2.jpg',
              'tags': <dynamic>['b'],
              'illustType': 2,
              'pageCount': 5,
              'userId': 'u2',
              'userName': 'B',
            },
          ],
        },
        'manga': <String, dynamic>{
          'data': <dynamic>[
            // 与 illust 段重复的 id：必须只保留一个。
            <String, dynamic>{
              'id': '1',
              'title': '重复项',
              'url': 'https://i.pximg.net/dup.jpg',
              'tags': <dynamic>[],
              'illustType': 1,
              'pageCount': 1,
              'userId': 'u1',
              'userName': 'A',
            },
            <String, dynamic>{
              'id': '3',
              'title': '漫画一',
              'url': 'https://i.pximg.net/3.jpg',
              'tags': <dynamic>['c'],
              'illustType': 1,
              'pageCount': 9,
              'userId': 'u3',
              'userName': 'C',
            },
          ],
        },
      });
      expect(items, hasLength(3));
      expect(items.map((item) => item.id).toList(), <String>['1', '2', '3']);
      expect(items[1].illustType, 2);
      expect(items[1].pageCount, 5);
      expect(items[0].cover, 'https://i.pximg.net/1.jpg');
    });

    test('maxPage 解析不到时返回 null（调用方退回保守判停）', () {
      expect(parsePixivSearchMaxPage(<String, dynamic>{}), isNull);
    });
  });

  group('Pixiv ID 提取', () {
    test('支持裸 ID / pixiv 前缀 / 作品链接 / 语言段链接', () {
      expect(extractPixivNumericId('12345678'), '12345678');
      expect(extractPixivNumericId('pixiv12345678'), '12345678');
      expect(extractPixivNumericId('PIXIV12345678'), '12345678');
      expect(
        extractPixivNumericId('https://www.pixiv.net/artworks/12345678'),
        '12345678',
      );
      expect(
        extractPixivNumericId('https://www.pixiv.net/en/artworks/12345678'),
        '12345678',
      );
    });

    test('带页锚点的链接取到作品 ID 而不是页号', () {
      expect(
        extractPixivNumericId('https://www.pixiv.net/artworks/12345678#1'),
        '12345678',
      );
    });

    test('非 Pixiv 形态与非数字不误命中', () {
      expect(extractPixivNumericId(null), isNull);
      expect(extractPixivNumericId(''), isNull);
      expect(extractPixivNumericId('   '), isNull);
      expect(extractPixivNumericId('pixiv'), isNull);
      expect(extractPixivNumericId('abc'), isNull);
      expect(extractPixivNumericId('https://example.com/123'), isNull);
    });

    test('前后空白被 trim（详情页 target 常见脏值）', () {
      expect(extractPixivNumericId('  12345678  '), '12345678');
    });
  });

  // ── 当前登录用户 uid 解析 ────────────────────────────────────────────────
  // 背景：首版从 cookie 键名猜 uid（pixiv_uid/p_uid/uid…），真机证实 cookie 里
  // **没有** uid，导致 data['userId'] 恒空 → 收藏接口每次都报"需要登录"，
  // 且重新登录无效（换的只是 PHPSESSID）。改为从页面 HTML 解析。

  group('Pixiv 页面 uid 解析', () {
    test('global-data meta 形态（首选）', () {
      const html = '<html><head><meta name="global-data" content=\'{"userData":'
          '{"id":"1234567","name":"someone","account":"acc"},'
          '"other":"x"}\'></head></html>';
      expect(parsePixivUserIdFromHtml(html), '1234567');
    });

    test('dataLayer 形态', () {
      const html = '<script>var dataLayer = [{"user_id": "7654321", '
          '"login": "yes"}];</script>';
      expect(parsePixivUserIdFromHtml(html), '7654321');
    });

    test('GA custom var 形态', () {
      const html = "<script>_gaq.push(['_setCustomVar', 6, 'user_id', "
          '"2468101", 1]);</script>';
      expect(parsePixivUserIdFromHtml(html), '2468101');
    });

    test('qualtrics 隐藏 span 形态', () {
      const html = '<span id="qualtrics_user-id" hidden="">1357913</span>';
      expect(parsePixivUserIdFromHtml(html), '1357913');
    });

    test('多种形态同时存在时取 global-data（当前用户语义最强）', () {
      const html = '<meta name="global-data" content=\'{"userData":'
          '{"id":"111"}}\'>'
          '<script>var dataLayer = [{"user_id": "999"}];</script>';
      expect(parsePixivUserIdFromHtml(html), '111',
          reason: '页面里可能混有他人的 user_id，必须优先取当前用户那一处');
    });

    test('uid 必须是纯数字，非数字形态一律不返回', () {
      expect(parsePixivUserIdFromHtml('{"userData":{"id":"abc"}}'), isNull);
      expect(parsePixivUserIdFromHtml('{"userData":{"id":""}}'), isNull);
      expect(parsePixivUserIdFromHtml('{"userData":{"id":"12a45"}}'), isNull);
    });

    test('无匹配 / 空 / null 都返回 null（不抛异常）', () {
      expect(parsePixivUserIdFromHtml(null), isNull);
      expect(parsePixivUserIdFromHtml(''), isNull);
      expect(
        parsePixivUserIdFromHtml('<html><body>nothing</body></html>'),
        isNull,
      );
      // 风控页（HTML 但不是 Pixiv 正常页面）也不该误取。
      expect(
        parsePixivUserIdFromHtml(
          '<html><title>Just a moment...</title></html>',
        ),
        isNull,
      );
    });

    test('未登录页面的 userData 为 null / 缺字段时不误取', () {
      expect(
        parsePixivUserIdFromHtml('{"userData":{"id":null,"name":null}}'),
        isNull,
      );
      expect(parsePixivUserIdFromHtml('{"userData":{"name":"x"}}'), isNull);
    });
  });

  // ── CSRF token 解析 ──────────────────────────────────────────────────────
  // 背景：真机上"读接口全正常、收藏（写）被拒并提示重新登录"。
  // 读通过写被拒是 CSRF 校验失败的典型特征，故新增 token 提取。

  group('Pixiv CSRF token 解析', () {
    test('meta 标签形态（双引号 / 单引号都要认）', () {
      expect(
        parsePixivCsrfTokenFromHtml(
          '<meta name="csrf-token" content="abc123">',
        ),
        'abc123',
      );
      expect(
        parsePixivCsrfTokenFromHtml(
          "<meta name='csrf-token' content='xyz789'>",
        ),
        'xyz789',
      );
    });

    test('meta 的属性顺序颠倒也要认（HTML 属性顺序是任意的）', () {
      expect(
        parsePixivCsrfTokenFromHtml('<meta content="tok1" name="csrf-token">'),
        'tok1',
        reason: '真实页面里 content 在前同样常见，只认一种顺序会静默失配',
      );
    });

    test('内联 JSON 形态', () {
      expect(
        parsePixivCsrfTokenFromHtml('{"csrfToken":"json-token"}'),
        'json-token',
      );
      expect(
        parsePixivCsrfTokenFromHtml('{"csrf_token":"snake-token"}'),
        'snake-token',
      );
    });

    test('页面上有多个候选时取第一个命中的形态', () {
      const html = '<meta name="csrf-token" content="first">'
          '<script>window.csrfToken = "second"</script>';
      expect(parsePixivCsrfTokenFromHtml(html), 'first');
    });

    // 下面这组是 2026-09 用真机 Cookie 打真实请求后确认的**当前生效形态**：
    // 令牌在首页那段被转义过的 serverSerializedPreloadedState JSON 里，
    // 路径是 api.token。先前的实现只找 meta 与非转义 JSON，所以永远取不到，
    // 收藏一直被服务端以 400 + "请重新登录"拒绝（该文案有误导性）。
    test('解析转义 JSON 里的 api.token（当前生效形态）', () {
      const html = '<script>window.__NEXT_DATA__ = {"props":{"pageProps":{'
          '"serverSerializedPreloadedState":"{\\"ads\\":{\\"config\\":{},'
          '\\"flags\\":{}},\\"api\\":{\\"token\\":\\"241c8e050ea2d7d5b9d6bebde6d81164\\",'
          '\\"services\\":{}},\\"user\\":{}}},"page":"/"}}</script>';
      expect(
        parsePixivCsrfTokenFromHtml(html),
        '241c8e050ea2d7d5b9d6bebde6d81164',
      );
    });

    test('解析未转义 JSON 里的 api.token', () {
      const html = '{"api":{"token":"abcdef0123456789"}}';
      expect(parsePixivCsrfTokenFromHtml(html), 'abcdef0123456789');
    });

    test('api 对象里 token 不是第一个字段时也能取到', () {
      const html = r'"api":{"a":"1","token":"deadbeefcafe1234"}';
      expect(parsePixivCsrfTokenFromHtml(html), 'deadbeefcafe1234');
    });

    test('刻意限制：api 里嵌了子对象时不再往后找 token（防跨对象误取）', () {
      // 正则刻意排除花括号，避免把 api 之后**其它对象**里的 token 张冠李戴。
      // 实测首页里 token 就在 api 的第一位，所以这条限制不影响真实页面；
      // 保留这个断言是为了防止后人"顺手优化"掉这层保护。
      const html = r'"api":{"services":{"boot":"x"},"token":"deadbeefcafe1234"}';
      expect(parsePixivCsrfTokenFromHtml(html), isNull);
    });

    test('不跨对象误取：api 之外的 token 不算', () {
      // 同页还有别的 token 字段时，不能张冠李戴。
      const html = r'"other":{"token":"wrongwrongwrong"}';
      expect(parsePixivCsrfTokenFromHtml(html), isNull);
    });

    test('meta 形态仍然优先（历史部署的兼容路径）', () {
      const html = '<meta name="csrf-token" content="meta-wins">'
          r'{"api":{"token":"json-loses"}}';
      expect(parsePixivCsrfTokenFromHtml(html), 'meta-wins');
    });

    test('无匹配 / 空 / null 返回 null（不抛异常）', () {
      expect(parsePixivCsrfTokenFromHtml(null), isNull);
      expect(parsePixivCsrfTokenFromHtml(''), isNull);
      expect(
        parsePixivCsrfTokenFromHtml('<html><body>no token here</body></html>'),
        isNull,
      );
      // 空值不算命中：否则会往请求头塞一个空 token，比不塞更糟。
      expect(
        parsePixivCsrfTokenFromHtml('<meta name="csrf-token" content="">'),
        isNull,
      );
      // 真实首页里没有 meta；确认这条路径不会假装成功。
      expect(
        parsePixivCsrfTokenFromHtml(
          r'"api":{"token":""}',
        ),
        isNull,
      );
    });

    test('候选 cookie 名清单非空且含主流命名', () {
      // 这份清单是"从哪里找 CSRF token"的唯一依据，被清空会导致永远取不到。
      expect(pixivCsrfCookieNames, isNotEmpty);
      expect(
        pixivCsrfCookieNames.map((name) => name.toLowerCase()),
        contains('xsrf-token'),
      );
    });
  });
}
