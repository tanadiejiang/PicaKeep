/// Nhentai 探索首页 `div.gallery` 条目的 HTML 解析测试。
///
/// 背景（真机验收发现的缺陷）：探索首页曾把 `data-tags` 整段丢弃，硬编码
/// `lang: 'Unknown'` 与 `tags: []`，表现为"卡片不显示标签、描述位显示 Unknown"。
/// 本文件锁住修复后的**字段口径**（与 `parseComic` / v2 `_parseV2GalleryItem`
/// 一致）与**容错边界**（缺字段不崩、只有 id 非法才返回 null）。
///
/// 被测对象是顶层函数 [parseNhentaiHomeComic]（`_tryParseComic` 只是它的一行
/// 转发），因此这里可以用纯 HTML 夹具驱动，不需要起网络单例。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart';
import 'package:picakeep/network/nhentai_network/nhentai_main_network.dart';

/// 构造一个 `div.container.index-container > div.gallery` 结构并取出该元素。
///
/// [dataTags] 为 null 表示**整个属性不存在**（区别于空串）。
Element galleryDom({
  String? dataTags,
  String href = '/g/123456/',
  String? caption,
  String? src,
  String? dataSrc,
}) {
  final dataTagsAttr = dataTags == null ? '' : ' data-tags="$dataTags"';
  final captionHtml =
      caption == null ? '' : '<div class="caption">$caption</div>';
  final srcAttr = src == null ? '' : ' src="$src"';
  final dataSrcAttr = dataSrc == null ? '' : ' data-src="$dataSrc"';
  final html = '<div class="container index-container">'
      '<div class="gallery"$dataTagsAttr>'
      '<a href="$href">'
      '<img$srcAttr$dataSrcAttr />'
      '</a>'
      '$captionHtml'
      '</div>'
      '</div>';
  final dom = parse(html).querySelector('div.gallery');
  if (dom == null) {
    throw StateError('夹具 HTML 未生成 div.gallery');
  }
  return dom;
}

void main() {
  group('parseNhentaiHomeComic 字段口径（与 parseComic 一致）', () {
    test('1. data-tags 完整：标签按表映射、语言判定为 English', () {
      final comic = parseNhentaiHomeComic(galleryDom(
        dataTags: '12227 2937 35762 8010',
        caption: 'Sample Title',
        src: 'https://t.nhentai.net/galleries/1/1t.jpg',
      ));

      expect(comic, isNotNull);
      expect(comic!.id, '123456');
      expect(comic.title, 'Sample Title');
      expect(comic.cover, 'https://t.nhentai.net/galleries/1/1t.jpg');
      expect(comic.lang, 'English');
      expect(comic.description, 'English', reason: '描述位复用 lang，不得再是 Unknown');
      expect(comic.tags, <String>['big breasts', 'sole female', 'group']);
    });

    test('2. 语言 6346 → 日本語', () {
      final comic = parseNhentaiHomeComic(
          galleryDom(dataTags: '6346 14283', caption: 't'));

      expect(comic!.lang, '日本語');
      expect(comic.tags, <String>['anal']);
    });

    test('3. 语言 29963 → 中文', () {
      final comic = parseNhentaiHomeComic(
          galleryDom(dataTags: '29963 14283', caption: 't'));

      expect(comic!.lang, '中文');
      expect(comic.tags, <String>['anal']);
    });

    test('语言 id 以整词判定：122270 不算 English', () {
      final comic = parseNhentaiHomeComic(
          galleryDom(dataTags: '122270 2937', caption: 't'));

      expect(comic!.lang, 'Unknown');
      expect(comic.tags, <String>['big breasts']);
    });
  });

  group('parseNhentaiHomeComic 容错边界', () {
    test('4. data-tags 属性缺失 → 空标签 + Unknown，且不抛异常', () {
      NhentaiComicBrief? parsed;
      expect(() => parsed = parseNhentaiHomeComic(galleryDom(caption: 't')),
          returnsNormally);
      final comic = parsed;
      expect(comic, isNotNull, reason: '缺 data-tags 仍应产出条目，不能整条丢弃');
      expect(comic!.tags, isEmpty);
      expect(comic.lang, 'Unknown');
    });

    test('5. data-tags 为空串 → 空标签 + Unknown', () {
      final comic =
          parseNhentaiHomeComic(galleryDom(dataTags: '', caption: 't'));

      expect(comic!.tags, isEmpty);
      expect(comic.lang, 'Unknown');
    });

    test('6. data-tags 全是表外数字 → 标签为空（不把数字当标签名）', () {
      final comic = parseNhentaiHomeComic(
          galleryDom(dataTags: '999999 888888 777777', caption: 't'));

      expect(comic!.tags, isEmpty);
      expect(comic.lang, 'Unknown');
    });

    test('7. 表外数字与表内 id 混合 → 只保留表内映射结果', () {
      final comic = parseNhentaiHomeComic(
          galleryDom(dataTags: '999999 2937 888888', caption: 't'));

      expect(comic!.tags, <String>['big breasts']);
    });

    test('8. 缺 div.caption → 标题回退为 id', () {
      final comic = parseNhentaiHomeComic(galleryDom(
        dataTags: '12227 2937',
        caption: null,
        src: 'https://t.nhentai.net/galleries/1/1t.jpg',
      ));

      expect(comic!.title, '123456');
      expect(comic.id, '123456');
      expect(comic.lang, 'English', reason: '标题回退不影响标签/语言解析');
    });

    test('9. div.caption 只有空白 → 标题回退为 id', () {
      final comic = parseNhentaiHomeComic(galleryDom(caption: '   '));

      expect(comic!.title, '123456');
    });

    test('10. href 为 # → 返回 null（调用方跳过坏条目）', () {
      expect(
          parseNhentaiHomeComic(galleryDom(href: '#', caption: 't')), isNull);
    });

    test('11. href 为空串 → 返回 null', () {
      expect(parseNhentaiHomeComic(galleryDom(href: '', caption: 't')), isNull);
    });

    test('12. href 无任何数字 → 返回 null', () {
      expect(
          parseNhentaiHomeComic(
              galleryDom(href: '/gallery/abc/', caption: 't')),
          isNull);
    });

    test('13. img 无 src / data-src → 封面为空串但仍产出条目', () {
      final comic = parseNhentaiHomeComic(galleryDom(caption: 't'));

      expect(comic, isNotNull);
      expect(comic!.cover, '');
    });
  });

  group('parseNhentaiHomeComic 封面懒加载', () {
    test('14. src 为空且 data-src 有效 → 用 data-src', () {
      final comic = parseNhentaiHomeComic(galleryDom(
        caption: 't',
        src: '',
        dataSrc: 'https://t.nhentai.net/galleries/2/2t.jpg',
      ));

      expect(comic!.cover, 'https://t.nhentai.net/galleries/2/2t.jpg');
    });

    test('15. src 是 data: 内联占位且 data-src 有效 → 用 data-src', () {
      final comic = parseNhentaiHomeComic(galleryDom(
        caption: 't',
        src: 'data:image/gif;base64,R0lGODlhAQABAAAAACw=',
        dataSrc: 'https://t.nhentai.net/galleries/3/3t.jpg',
      ));

      expect(comic!.cover, 'https://t.nhentai.net/galleries/3/3t.jpg');
    });

    test('16. src 缺失（无 src 属性）且 data-src 有效 → 用 data-src', () {
      final comic = parseNhentaiHomeComic(galleryDom(
        caption: 't',
        dataSrc: 'https://t.nhentai.net/galleries/4/4t.jpg',
      ));

      expect(comic!.cover, 'https://t.nhentai.net/galleries/4/4t.jpg');
    });

    test('17. src 有效时不被 data-src 覆盖', () {
      final comic = parseNhentaiHomeComic(galleryDom(
        caption: 't',
        src: 'https://t.nhentai.net/galleries/5/5t.jpg',
        dataSrc: 'https://t.nhentai.net/galleries/placeholder.jpg',
      ));

      expect(comic!.cover, 'https://t.nhentai.net/galleries/5/5t.jpg');
    });

    test('18. src 为 data: 且没有 data-src → 保留原 src（不崩、不置空硬造）', () {
      const placeholder = 'data:image/gif;base64,R0lGODlhAQABAAAAACw=';
      final comic =
          parseNhentaiHomeComic(galleryDom(caption: 't', src: placeholder));

      expect(comic!.cover, placeholder);
    });
  });

  group('首页真实形态回归', () {
    test('19. 一页多个 gallery：坏条目跳过、好条目保留标签与语言', () {
      final document = parse('''
<div class="container index-container index-popular">
  <div class="gallery" data-tags="12227 2937 35762">
    <a href="/g/480041/">
      <img src="https://t.nhentai.net/galleries/1/1t.jpg" />
    </a>
    <div class="caption">Popular One</div>
  </div>
  <div class="gallery">
    <a href="#">
      <img src="https://t.nhentai.net/galleries/2/2t.jpg" />
    </a>
    <div class="caption">Bad Row</div>
  </div>
  <div class="gallery" data-tags="29963 14283">
    <a href="/g/480042/">
      <img data-src="https://t.nhentai.net/galleries/3/3t.jpg" />
    </a>
    <div class="caption">Latest One</div>
  </div>
</div>''');

      final parsed = document
          .querySelectorAll('div.container.index-container > div.gallery')
          .map(parseNhentaiHomeComic)
          .whereType<NhentaiComicBrief>()
          .toList();

      expect(parsed.length, 2, reason: 'href=# 的坏条目必须被跳过');
      expect(parsed.first.id, '480041');
      expect(parsed.first.lang, 'English');
      expect(parsed.first.tags, <String>['big breasts', 'sole female']);
      expect(parsed.last.id, '480042');
      expect(parsed.last.lang, '中文');
      expect(parsed.last.cover, 'https://t.nhentai.net/galleries/3/3t.jpg');
    });
  });
}
