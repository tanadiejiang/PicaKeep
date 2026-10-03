/// 阅读清晰度两套开关的判据（39 号）。
///
/// ## 为什么必须单测
///
/// 这条判据把**两件容易写反的事**揉在一起，而写反的症状都只是"某类内容糊/卡"、
/// 不会报错：
///
/// 1. **两个开关的默认方向相反** —— 漫画缺省即关（只认 `'1'`）、
///    插画/图集缺省即开（只认 `'0'`）。若两处都写成 `== '1'`，
///    插画那侧"默认打开"就静默失效；
/// 2. **哪些来源算漫画** —— 不能用 `ComicType` 判：`ComicType.other` 是个兜底桶，
///    本地图集、拷贝漫画、Komiic 全在里面（见 `comicTypeForDownloadType`），
///    用它会把 Komiic（条漫）划进"插画/图集"。
///
/// 用户的原始要求：「漫画高清模式默认（初始）关闭，但有记忆如果打开后就保持打开，
/// 而插画-图集那边默认打开」。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/reader_image_quality.dart';

/// 两套开关都用默认值（= 数组里的字面量）时的表现。
bool usingDefaults(String sourceKey) => readerHighQualityEnabled(
      sourceKey: sourceKey,
      comicSetting: '0', // settings[159] 默认：漫画关
      illustSetting: '1', // settings[160] 默认：插画/图集开
    );

void main() {
  group('默认值方向相反（用户明确要求）', () {
    test('漫画来源 + 默认设置 → 低清（关）', () {
      for (final key in <String>[
        'ehentai',
        'nhentai',
        'jm',
        'picacg',
        'hitomi',
        'htmanga',
        'copy_manga',
      ]) {
        expect(usingDefaults(key), isFalse, reason: '$key 默认应是低清');
      }
    });

    test('插画 / 图集来源 + 默认设置 → 高清（开）', () {
      for (final key in <String>['pixiv', 'local_album', 'other']) {
        expect(usingDefaults(key), isTrue, reason: '$key 默认应是高清');
      }
    });

    test('归一化：漫画只认 1，插画只认 0（写反会让默认值失效）', () {
      expect(normalizeReaderHighQualityComic(null), '0');
      expect(normalizeReaderHighQualityComic(''), '0');
      expect(normalizeReaderHighQualityComic('1'), '1');
      expect(normalizeReaderHighQualityComic('脏值'), '0');

      expect(normalizeReaderHighQualityIllust(null), '1', reason: '缺省即开');
      expect(normalizeReaderHighQualityIllust(''), '1');
      expect(normalizeReaderHighQualityIllust('0'), '0');
      expect(normalizeReaderHighQualityIllust('脏值'), '1');
    });
  });

  group('来源归类', () {
    test('Komiic 大小写两种写法都算漫画（写入侧是 `Komiic`）', () {
      expect(readerReadingIsComic('Komiic'), isTrue);
      expect(readerReadingIsComic('komiic'), isTrue);
      expect(readerReadingIsComic('  KoMiIc  '), isTrue);
    });

    test('本地图集 / 兜底来源不算漫画', () {
      expect(readerReadingIsComic('local_album'), isFalse);
      expect(readerReadingIsComic('other'), isFalse);
      expect(readerReadingIsComic('pixiv'), isFalse);
    });

    test('不认识的来源按"非漫画"处理（反着判的好处：新源默认走插画侧）', () {
      expect(readerReadingIsComic('some_future_source'), isFalse);
      expect(usingDefaults('some_future_source'), isTrue);
    });

    test('空来源不抛，按非漫画处理', () {
      expect(readerReadingIsComic(''), isFalse);
      expect(usingDefaults('   '), isTrue);
    });
  });

  group('开关真的分别生效', () {
    test('漫画开关打开 → 漫画高清；插画那侧不受影响', () {
      const s = <String, String>{'comic': '1', 'illust': '0'};
      expect(usingDefaultsWith('jm', s), isTrue);
      expect(usingDefaultsWith('pixiv', s), isFalse);
    });

    test('插画开关关掉 → 插画低清；漫画那侧不受影响', () {
      const s = <String, String>{'comic': '0', 'illust': '0'};
      expect(usingDefaultsWith('pixiv', s), isFalse);
      expect(usingDefaultsWith('jm', s), isFalse);
    });

    test('两个都开 → 都高清', () {
      const s = <String, String>{'comic': '1', 'illust': '1'};
      expect(usingDefaultsWith('jm', s), isTrue);
      expect(usingDefaultsWith('pixiv', s), isTrue);
    });
  });
}

/// 用给定的两个设置值判一次。
bool usingDefaultsWith(String sourceKey, Map<String, String> settings) =>
    readerHighQualityEnabled(
      sourceKey: sourceKey,
      comicSetting: settings['comic']!,
      illustSetting: settings['illust']!,
    );
