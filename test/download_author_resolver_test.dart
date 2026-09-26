import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/download_author_resolver.dart';
import 'package:picakeep/foundation/download_model.dart';

/// 真机（`lingxue.picakeep`，33 号执行时用 `adb` 从
/// `/data/data/lingxue.picakeep/files/download/download.db` 拉出来的 `json` 列）
/// 里的三条 **Pixiv** 记录。
///
/// 为什么把真数据原样抄进测试：33 号的核心假设是
/// 「[resolveDownloadedAuthors] 对 `CustomDownloadedItem` 返回空」——
/// 这条假设如果哪天被"顺手修好"，下面「假设确认」那组用例会立刻失败，
/// 提示后来者"这条链的语义变了，卡片侧那个直取分支的前提要重新想"。
/// 同时它们也是新的 [resolveDownloadedRowAuthor] 契约最真实的输入。
const String _realPixivLightRiaJson = '{"comicSize":3.8157119750976562,'
    '"downloadedEps":[0],"chapters":null,"id":"pixiv150034783",'
    '"name":"Vodyanitsa🎨","subTitle":"LightRia",'
    '"tags":["Genshin Impact","ヴォジャニーツァ","魅惑的大腿"],'
    '"sourceKey":"pixiv","sourceName":"Pixiv","cover":"","comicId":"150034783",'
    '"width":null,"height":null}';

const String _realPixivKyuusoukyuuJson = '{"comicSize":7.268954277038574,'
    '"downloadedEps":[0],"chapters":null,"id":"pixiv150033282",'
    '"name":"完全で瀟洒な従者","subTitle":"久蒼穹",'
    '"tags":["东方","东方Project"],"sourceKey":"pixiv","sourceName":"Pixiv",'
    '"cover":"","comicId":"150033282"}';

const String _realPixivDensenshaJson = '{"comicSize":3.4361371994018555,'
    '"downloadedEps":[0],"chapters":null,"id":"pixiv79837313",'
    '"name":"是色兔子peko","subTitle":"電瘋扇","tags":["Usada Pekora"],'
    '"sourceKey":"pixiv","sourceName":"Pixiv","cover":"","comicId":"79837313"}';

/// 造一条**与真实调用点同形**的自定义源记录：先按 id+json 解析出 fallback
/// （`local_library_scan.dart` 就是这么做的：`_parseDownloadedItem(id, json)`），
/// 再喂给作者解析。
CustomDownloadedItem _customFallback(String id, String json) {
  final parsed = parseDownloadedItemRecordJson(id, json);
  expect(parsed, isA<CustomDownloadedItem>(),
      reason: '前置条件：带 sourceKey 的 json 必须解析成 CustomDownloadedItem');
  return parsed! as CustomDownloadedItem;
}

void main() {
  // ---------------------------------------------------------------------------
  // 33 号「关键假设确认」：自定义源的作者**不能**走 EH/NH 那条解析链。
  //
  // 计划里把这条列为"动手前先确认的假设"。实测（真机三条 Pixiv 记录）结论：
  // 假设**成立** —— 这条链两步都返回空，作者就是这么被静默丢掉的。
  // 下面四条把"两处都为空"钉成契约：它们是"为什么必须直取 subTitle"的证据。
  // ---------------------------------------------------------------------------
  group('33 号假设确认：EH/NH 那条链对自定义源返回空', () {
    test('resolveDownloadedAuthors(CustomDownloadedItem) 恒为空（不是"暂时没读到"）',
        () {
      for (final json in <String>[
        _realPixivLightRiaJson,
        _realPixivKyuusoukyuuJson,
        _realPixivDensenshaJson,
      ]) {
        final id = jsonDecode(json)['id'].toString();
        final item = _customFallback(id, json);
        // 数据里明明有作者（`subTitle`），这个 resolver 却**刻意**不给 ——
        // 它的注释写的是"自定义记录没有源安全的作者契约"。
        expect(item.subTitle, isNotEmpty);
        expect(resolveDownloadedAuthors(item), isEmpty);
      }
    });

    test('resolveDownloadedAuthorsFromRecord 对同一条记录也为空（链的第一步）',
        () {
      // 第二步（`fallback.type` 是 `DownloadType.other`，躲过了那句 `return ''`）
      // 落到第三步 `resolveDownloadedAuthors`，还是空 —— 两步都空 = 作者丢失。
      for (final json in <String>[
        _realPixivLightRiaJson,
        _realPixivKyuusoukyuuJson,
        _realPixivDensenshaJson,
      ]) {
        final id = jsonDecode(json)['id'].toString();
        expect(
          resolveDownloadedAuthorsFromRecord(
            id,
            json,
            fallback: _customFallback(id, json),
          ),
          isEmpty,
        );
      }
    });

    test('自定义源的 type 是 other（所以躲过了 EH/NH 那句 return \'\'）', () {
      final item = _customFallback('pixiv79837313', _realPixivDensenshaJson);
      expect(item.type, DownloadType.other);
      expect(item.type, isNot(DownloadType.ehentai));
      expect(item.type, isNot(DownloadType.nhentai));
    });
  });

  // ---------------------------------------------------------------------------
  // 新契约：托管下载行的作者文本（33 号修的 bug）。
  // ---------------------------------------------------------------------------
  group('resolveDownloadedRowAuthor：自定义源直取 subTitle', () {
    test('真机三条 Pixiv 记录都取到作者（复现 33 号真机症状的输入）', () {
      final cases = <String, String>{
        'pixiv150034783': 'LightRia',
        'pixiv150033282': '久蒼穹',
        'pixiv79837313': '電瘋扇',
      };
      final jsons = <String>[
        _realPixivLightRiaJson,
        _realPixivKyuusoukyuuJson,
        _realPixivDensenshaJson,
      ];
      for (final json in jsons) {
        final id = jsonDecode(json)['id'].toString();
        expect(
          resolveDownloadedRowAuthor(
            rawJson: json,
            fallback: _customFallback(id, json),
          ),
          cases[id],
          reason: '$id 的作者就是它 json 里的 subTitle',
        );
      }
    });

    test('Komiic 形态：多作者原样返回（`authors.join(\', \')`，不在这里拆分）',
        () {
      final json = jsonEncode(<String, dynamic>{
        'id': 'komiic123',
        'name': '标题',
        'subTitle': '作者A, 作者B',
        'tags': <String>[],
        'sourceKey': 'Komiic',
        'sourceName': 'Komiic',
        'cover': '',
        'comicId': '123',
        'downloadedEps': <int>[0],
      });
      expect(
        resolveDownloadedRowAuthor(
          rawJson: json,
          fallback: _customFallback('komiic123', json),
        ),
        '作者A, 作者B',
      );
    });

    test('subTitle 为空 / 纯空白 → 返回空串（不崩、也不编造占位文案）', () {
      for (final raw in <String>['', '   ', '\n']) {
        final json = jsonEncode(<String, dynamic>{
          'id': 'pixiv1',
          'name': '标题',
          'subTitle': raw,
          'tags': <String>[],
          'sourceKey': 'pixiv',
          'sourceName': 'Pixiv',
          'cover': '',
          'comicId': '1',
          'downloadedEps': <int>[0],
        });
        // 卡片侧对空值"整项跳过"是**有意**的，所以这里必须是空串，
        // 不能是"未知"之类的占位符。
        expect(
          resolveDownloadedRowAuthor(
            rawJson: json,
            fallback: _customFallback('pixiv1', json),
          ),
          isEmpty,
          reason: 'raw=${raw.codeUnits}',
        );
      }
    });

    test('json 是空串 / 坏 JSON 时也只看 fallback 的类型（不会抛异常）', () {
      final item = CustomDownloadedItem(
        id: 'pixiv79837313',
        name: '是色兔子peko',
        subTitle: '電瘋扇',
        tags: const <String>[],
        sourceKey: 'pixiv',
        sourceName: 'Pixiv',
        cover: '',
        comicId: '79837313',
        downloadedEps: const <int>[0],
      );
      for (final raw in <String>['', '   ', '{}', 'not json']) {
        expect(
          resolveDownloadedRowAuthor(rawJson: raw, fallback: item),
          '電瘋扇',
          reason: 'raw=$raw',
        );
      }
    });

    test('作者两端的空白被裁掉（DB 里可能带空白，卡片不该显示成缩进）', () {
      expect(
        resolveDownloadedRowAuthor(
          rawJson: '{}',
          fallback: CustomDownloadedItem(
            id: 'pixiv2',
            name: 'n',
            subTitle: '  作者B  ',
            tags: const <String>[],
            sourceKey: 'pixiv',
            sourceName: 'Pixiv',
            cover: '',
            comicId: '2',
            downloadedEps: const <int>[0],
          ),
        ),
        '作者B',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // EH / NH 回归：铁律 —— 这两条的解析结果**必须与改动前逐字一致**，
  // 尤其"拿不到就返回空、绝不用 uploader 冒充作者"。
  // ---------------------------------------------------------------------------
  group('EH / NH 回归：既有行为一字不改', () {
    String ehJson({
      String? artist,
      String uploader = '8476411',
      bool broken = false,
    }) {
      return jsonEncode(<String, dynamic>{
        'galleryTitle': 'title',
        'uploader': uploader,
        'link': 'https://e-hentai.org/g/123/abc/',
        'tagList': <String>[
          if (artist != null) 'artist:$artist',
          'group:きのこのみ',
          'language:chinese',
        ],
        if (broken) 'garbage': true,
      });
    }

    test('EH：有 artist 标签 → 取 artist（不是 uploader、不是 group）', () {
      final json = ehJson(artist: 'konomi');
      final item = parseDownloadedItemRecordJson('123-abc', json)!;
      expect(item, isA<DownloadedGallery>());
      expect(item.type, DownloadType.ehentai);
      expect(
        resolveDownloadedRowAuthor(rawJson: json, fallback: item),
        'konomi',
      );
    });

    test('EH：只有 uploader / group，没有 artist → **空串**（不拿 uploader 冒充）',
        () {
      final json = ehJson();
      final item = parseDownloadedItemRecordJson('123-abc', json)!;
      expect(
        resolveDownloadedRowAuthor(rawJson: json, fallback: item),
        isEmpty,
        reason: 'EH 的 uploader 是上传者，不是作者；宁可不显示',
      );
    });

    test('EH：json 破损（`{}`）→ 空串（隐藏文件/坏记录不该长出作者）', () {
      // ⚠️ 这一条正是新分支**必须只认类型**的原因：id 含 '-' 且 json 里没有
      // `galleryTitle` 时，`parseDownloadedItemRecordJson` 会把它解析成
      // `CustomDownloadedItem`。改动前这里返回空串，改动后也必须还是空串。
      final item = parseDownloadedItemRecordJson('123-abc', '{}');
      expect(item, isA<CustomDownloadedItem>(),
          reason: '前置条件：破损的 EH 行确实会被解析成自定义源形态');
      expect(
        resolveDownloadedRowAuthor(rawJson: '{}', fallback: item!),
        isEmpty,
        reason: '坏 json 里没有驼峰 subTitle，所以新分支同样给空串',
      );
    });

    test('NH：有 Artists 分类 → 取它；没有 → 空串', () {
      final withArtists = jsonEncode(<String, dynamic>{
        'comicID': '605366',
        'title': 'title',
        'categorizedTags': <String, List<String>>{
          'Artists': <String>['konomi'],
          'Groups': <String>['きのこのみ'],
        },
      });
      final nh = parseDownloadedItemRecordJson('nhentai605366', withArtists)!;
      expect(nh, isA<NhentaiDownloadedComic>());
      expect(nh.type, DownloadType.nhentai);
      expect(
        resolveDownloadedRowAuthor(rawJson: withArtists, fallback: nh),
        'konomi',
      );

      final withoutArtists = jsonEncode(<String, dynamic>{
        'comicID': '605366',
        'title': 'title',
        'categorizedTags': <String, List<String>>{
          'Groups': <String>['きのこのみ'],
        },
      });
      final nh2 = parseDownloadedItemRecordJson('nhentai605366', withoutArtists)!;
      expect(
        resolveDownloadedRowAuthor(rawJson: withoutArtists, fallback: nh2),
        isEmpty,
        reason: 'NH 列表行不带 Artists 分类 → 未知就是未知',
      );
    });

    test('NH：json 破损（`{}`）→ 空串（既有契约，`download_author_resolver_test` 已锁）',
        () {
      final item = parseDownloadedItemRecordJson('nhentai605366', '{}');
      expect(item, isA<NhentaiDownloadedComic>());
      expect(
        resolveDownloadedRowAuthor(rawJson: '{}', fallback: item!),
        isEmpty,
      );
    });

    test('EH 的 subTitle 是 uploader —— 新分支若误伤 EH，这里会立刻变红', () {
      // 把"危险"显式写出来：`DownloadedGallery.subTitle` **就是** uploader。
      // 新分支只要对 EH 生效一点点，作者就会变成上传者，与铁律直接冲突。
      final json = ehJson(artist: 'konomi');
      final item = parseDownloadedItemRecordJson('123-abc', json)!;
      expect(item.subTitle, '8476411', reason: 'EH 的 subTitle = uploader');
      expect(
        resolveDownloadedRowAuthor(rawJson: json, fallback: item),
        isNot('8476411'),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // 其他来源未受影响（新分支只截自定义源）。
  // ---------------------------------------------------------------------------
  group('其他来源：仍走原来的链', () {
    test('JM：按 json 的用户名列取作者', () {
      final json = jsonEncode(<String, dynamic>{
        'comicId': '1466163',
        'title': '标题',
        'author': 'OMGqmq',
        'chapters': <String>['第1章'],
        'downloadedChapters': <int>[0],
        'tagList': <String>['中文'],
        'downloadType': 2,
      });
      final item = parseDownloadedItemRecordJson('jm1466163', json)!;
      expect(item, isA<DownloadedJmComic>());
      expect(
        resolveDownloadedRowAuthor(rawJson: json, fallback: item),
        'OMGqmq',
      );
    });

    test('老式行（无可解析 json）→ 走 DB 列构造的 ScannedDownloadedComic，作者仍取得到',
        () {
      // 这类行走的是 `_downloadedItemFromDbRow`，它的 author 来自 db 的
      // `subtitle` 列（写入时就是 `item.subTitle`），所以"没有 json 的 Pixiv 记录"
      // 其实一直是好的 —— bug 只出现在 **json 能解析** 的那条路径上。
      final item = ScannedDownloadedComic(
        comicId: 'pixiv79837313',
        title: '是色兔子peko',
        author: '電瘋扇',
        chapters: const <String>['全部'],
        downloadedChapters: const <int>[0],
        size: 1,
        tagList: const <String>[],
      );
      expect(item, isNot(isA<CustomDownloadedItem>()));
      expect(
        resolveDownloadedRowAuthor(rawJson: '', fallback: item),
        '電瘋扇',
      );
    });
  });

  test('EH author uses artist tag and never uploader/group', () {
    final item = DownloadedGallery(
      galleryTitle: 'title',
      uploader: '8476411',
      link: 'https://e-hentai.org/g/123/abc/',
      tagList: const [
        'artist:konomi',
        'group:きのこのみ',
        'cosplayer:someone',
      ],
    );
    expect(resolveDownloadedAuthors(item), ['konomi']);
  });

  test('NH author uses only Artists category', () {
    final item = NhentaiDownloadedComic(
      comicID: '605366',
      title: 'title',
      categorizedTags: const {
        'Artists': ['konomi', 'konomi'],
        'Groups': ['きのこのみ'],
        'Tags': ['ordinary'],
      },
    );
    expect(resolveDownloadedAuthors(item), ['konomi']);
  });

  test('managed wrapper resolves canonical author from raw record', () {
    final json = jsonEncode({
      'galleryTitle': 'title',
      'uploader': '8476411',
      'link': 'https://e-hentai.org/g/123/abc/',
      'tagList': ['artist:konomi', 'group:きのこのみ'],
    });
    expect(
      resolveDownloadedAuthorsFromRecord('123-abc', json),
      ['konomi'],
    );
  });

  test('EH/NH rows without reliable metadata stay empty', () {
    expect(resolveDownloadedAuthorsFromRecord('123-abc', '{}'), isEmpty);
    expect(resolveDownloadedAuthorsFromRecord('nhentai605366', '{}'), isEmpty);
  });

  test('source-neutral online resolver keeps EH artist and unknown NH brief',
      () {
    expect(
      resolveSourceAuthors(
        source: 'ehentai',
        flatTags: const ['artist:konomi', 'group:きのこのみ'],
        fallbackAuthor: '8476411',
      ),
      ['konomi'],
    );
    expect(
      resolveSourceAuthors(
        source: 'nhentai',
        flatTags: const ['artist:konomi'],
        fallbackAuthor: '605366',
      ),
      isEmpty,
    );
  });

  test('source-neutral resolver uses explicit author for other sources', () {
    expect(
      resolveSourceAuthors(source: 'picacg', fallbackAuthor: 'A, B'),
      ['A', 'B'],
    );
  });

  // 04 计划追加：列表卡片描述位在源无简介时回退到源标识号。
  group('displaySourceInfoLine', () {
    test('JM 无简介时回退为 jm<id>', () {
      expect(
        displaySourceInfoLine(source: 'jm', comicId: '1466163', description: ''),
        'jm1466163',
      );
    });

    test('NH 无简介时回退为 nhentai<id>', () {
      expect(
        displaySourceInfoLine(
            source: 'nhentai', comicId: '605366', description: ''),
        'nhentai605366',
      );
    });

    test('有简介时一律显示简介，不回退标识号', () {
      for (final source in const ['jm', 'nhentai', 'picacg', 'ehentai']) {
        expect(
          displaySourceInfoLine(
              source: source, comicId: '1466163', description: '作品简介'),
          '作品简介',
          reason: '$source 不应覆盖既有简介',
        );
      }
    });

    test('无简介且源不在回退名单内时保持为空', () {
      for (final source in const ['picacg', 'ehentai', 'unknown']) {
        expect(
          displaySourceInfoLine(source: source, comicId: '1', description: ''),
          isEmpty,
        );
      }
    });

    test('id 为空时不产生残缺前缀', () {
      expect(
        displaySourceInfoLine(source: 'jm', comicId: '', description: ''),
        isEmpty,
      );
      expect(
        displaySourceInfoLine(source: 'jm', comicId: '   ', description: ''),
        isEmpty,
      );
    });

    test('纯空白简介视为无简介', () {
      expect(
        displaySourceInfoLine(source: 'jm', comicId: '9', description: '   '),
        'jm9',
      );
    });
  });
}
