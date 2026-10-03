/// 插画卡片底部信息配置的**纯函数契约**：解析/生成往返、默认值、取值与样式。
///
/// ## 为什么必须测
///
/// 32 号计划「验收标准 2」第二条要求"勾选/排序/空选择的解析与生成往返一致"。
/// 这几条错了都不会报错，只会静默显示错内容或把设置写坏：
///
/// - `parse` 不按**出现顺序**返回 → 用户排好的顺序一存一读就丢（"配了没生效"）；
/// - 默认值不是"标题 + 作者、各占一行" → 升级后老用户卡片观感突变；
/// - 坏模板值不兜底 → 弹窗打开是空的，用户以为配置丢了；
/// - 空值字段不跳过 → 作者缺失时卡片上多一行空白。
///
/// 持久化格式与 27 号「Pixiv 下载目录名模板」一致（模板串），
/// 所以这里也照 `pixiv_download_naming_test.dart` 的写法锁往返。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/illust_card_info_config.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/local_library_illust_view.dart';
import 'package:picakeep/foundation/pixiv_download_naming.dart';
import 'package:picakeep/foundation/template_field_order.dart';

/// 造一条插画条目（json 列形态与 `CustomDownloadedItem.toJson()` 一致）。
IllustLibraryEntry _entry({
  String name = '作品标题',
  String author = '作者名',
  int? width,
  int? height,
  String id = 'pixiv1',
}) {
  final json = '{"id":"$id","name":"$name","subTitle":"$author",'
      '"tags":[],"sourceKey":"pixiv","sourceName":"Pixiv","cover":"",'
      '"comicId":"$id","width":${width ?? 'null'},"height":${height ?? 'null'}}';
  final item = LocalLibraryComicItem(
    itemId: 'local_download::current_download::$id',
    originalId: id,
    type: DownloadType.other,
    name: name,
    subTitle: author,
    tags: const <String>[],
    sourceDisplayName: 'Pixiv',
    fileSystemPath: '/tmp/$id',
    episodeFiles: const <int, List<String>>{},
    downloadedEps: const <int>[0],
    eps: const <String>['全部'],
    localCoverPath: null,
    localStorageExists: true,
    canDelete: false,
    aliases: <String>[id],
    sourceRowJson: json,
  );
  return buildIllustEntries(<LocalLibraryComicItem>[item]).single;
}

void main() {
  group('布局预留独立于可见文本', () {
    test('只选已未知的动态字段；已知单图无需页数占位', () {
      final entry = _entry();
      expect(
          illustCardInfoPendingFieldsFor(
              entry: entry, fields: const ['title', 'author']),
          isEmpty);
      expect(
          illustCardInfoPendingFieldsFor(
              entry: entry, fields: const ['pages', 'size']),
          {'pages', 'size'});
      expect(
          illustCardInfoPendingFieldsFor(
              entry: entry.withResolvedInfo(pageCount: 1),
              fields: const ['pages', 'size']),
          {'size'});
    });

    test('布局片段尊重顺序与分隔符，预留值不进入可见文本', () {
      final entry = _entry();
      const fields = ['pages', 'title', 'size'];
      final reserved =
          illustCardInfoPendingFieldsFor(entry: entry, fields: fields);
      final before = illustCardInfoLayoutSpansFor(
          entry: entry,
          fields: fields,
          separator: ' / ',
          reservedFields: reserved);
      final single =
          entry.withResolvedInfo(pageCount: 1, width: 600, height: 800);
      final after = illustCardInfoLayoutSpansFor(
          entry: single,
          fields: fields,
          separator: ' / ',
          reservedFields: reserved);
      expect(before.map((s) => s.text), after.map((s) => s.text));
      expect(before.map((s) => s.text).join(), 'p88 / 作品标题 / 88888×88888');
      expect(
          illustrateCardInfoTextFor(
              entry: entry, fields: fields, separator: ' / '),
          '作品标题');
      expect(
          illustrateCardInfoTextFor(
              entry: single, fields: fields, separator: ' / '),
          '作品标题 / 600×800');
    });
  });
  group('默认值：与改动前的卡片观感逐字一致', () {
    test('settings 下标与 24 号占用区不冲突（≥158）', () {
      expect(illustCardInfoSettingIndex, 158);
      // 24 号（图集页视图 / 瀑布流列数 / 按钮位置）与 23 号（多图打包）的占用
      expect(illustCardInfoSettingIndex, greaterThan(157));
      expect(illustCardInfoSettingIndex,
          greaterThan(pixivMultiPageZipSettingIndex));
      expect(
        illustCardInfoSettingIndex,
        greaterThan(illustViewSwitcherPositionSettingIndex),
      );
    });

    test('下标真的落在 settings 数组里（漏加数组项会在这里炸）', () {
      // 这条比"等于 158"更有用：它保证 `lib/base.dart` 的默认值数组**真的**有这一项。
      // 只加常量、忘了往数组里补一项的话，`settings[158]` 会越界 ——
      // 而症状是启动时 `readSettings` 抛异常，离"加了个设置项"很远，很难联想起因。
      expect(
        appdata.settings.length,
        greaterThan(illustCardInfoSettingIndex),
        reason: 'illustCardInfoSettingIndex 必须小于 settings 的长度',
      );
      expect(
        appdata.settings[illustCardInfoSettingIndex],
        kDefaultIllustCardInfoTemplate,
        reason: '数组里这一项的默认值就是默认模板',
      );
    });

    test('默认字段是标题 + 作者（改动前写死的那两项）', () {
      expect(kDefaultIllustCardInfoFields, <String>['title', 'author']);
    });

    test('默认分隔符是换行 —— 默认渲染出来是两行，与改动前一致', () {
      expect(kDefaultIllustCardInfoSeparator, '\n');
      expect(
        buildIllustCardInfoTemplate(
          kDefaultIllustCardInfoFields,
          kDefaultIllustCardInfoSeparator,
        ),
        kDefaultIllustCardInfoTemplate,
      );
      expect(kDefaultIllustCardInfoTemplate, '{title}\n{author}');
    });

    test('未设置 / 空白 / 只有空格 → 一律落到默认模板', () {
      for (final raw in <String?>[null, '', '   ', '\n', '\t']) {
        expect(normalizeIllustCardInfoTemplate(raw),
            kDefaultIllustCardInfoTemplate);
        final spec = illustCardInfoSpecFromSetting(raw);
        expect(spec.fields, kDefaultIllustCardInfoFields);
        expect(spec.separator, kDefaultIllustCardInfoSeparator);
      }
    });

    test('一个字段都解析不出的坏值 → 兜底成默认，不抛错也不返回空', () {
      for (final raw in <String>['{foo}', 'none', '{title', 'title}', '{}']) {
        final spec = parseIllustCardInfoTemplate(raw);
        expect(spec.fields, kDefaultIllustCardInfoFields, reason: 'raw=$raw');
        expect(spec.separator, kDefaultIllustCardInfoSeparator);
      }
    });
  });

  group('parse / build 往返：勾选与顺序都能存下来并还原', () {
    test('全部候选分隔符与字段组合都往返一致', () {
      final allFields = <List<String>>[
        <String>['title'],
        <String>['author'],
        <String>['title', 'author'],
        <String>['author', 'title'],
        <String>['size', 'title', 'pages'],
        <String>['pages', 'size', 'author', 'title'],
        kIllustCardInfoFieldKeys,
      ];
      for (final fields in allFields) {
        for (final separator in kIllustCardInfoSeparators) {
          final template = buildIllustCardInfoTemplate(fields, separator);
          final parsed = parseIllustCardInfoTemplate(template);
          expect(parsed.fields, fields,
              reason: 'fields=$fields sep=${separator.codeUnits}');
          if (fields.length >= 2) {
            expect(parsed.separator, separator,
                reason: 'fields=$fields sep=${separator.codeUnits}');
          } else {
            // **只有一个字段时分隔符无意义**，parse 会回落到默认分隔符。
            // 这是与 27 号 `parsePixivDirNameTemplate` **刻意相同**的行为：
            // 单个字段的模板里根本不存在"两字段之间的那段"，无从还原；
            // 而落回默认值不会影响渲染（一个字段时分隔符不参与拼接）。
            // 下面的用例把这条契约单独钉住。
            expect(parsed.separator, kDefaultIllustCardInfoSeparator);
          }
          // 二次往返必须稳定（存 → 读 → 再存 不能漂移）
          expect(
            buildIllustCardInfoTemplate(parsed.fields, parsed.separator),
            parseIllustCardInfoTemplate(template).fields.length >= 2
                ? template
                : buildIllustCardInfoTemplate(
                    fields,
                    kDefaultIllustCardInfoSeparator,
                  ),
          );
        }
      }
    });

    test('单字段模板：分隔符回落到默认值（与 27 号同规则，但默认值不同）', () {
      // 规则一致：单字段时分隔符无从还原，各自回落到**自己的**默认分隔符。
      // 两处默认值刻意不同（卡片=换行、目录名=`-`），所以这里比的是"各自回落"，
      // 而不是"回落成同一个值"。
      expect(parseIllustCardInfoTemplate('{title}').separator,
          kDefaultIllustCardInfoSeparator);
      expect(parsePixivDirNameTemplate('{title}').separator,
          kDefaultPixivDirNameSeparator);
      // 双字段时两处都按"第一段间隙"取值 —— 这才是真正共用的规则。
      expect(
        parseIllustCardInfoTemplate('{title} - {author}').separator,
        parsePixivDirNameTemplate('{title} - {author}').separator,
      );
      // 单字段时分隔符不参与拼接，所以"丢了"不影响任何可见结果
      final entry = _entry();
      for (final separator in kIllustCardInfoSeparators) {
        expect(
          illustrateCardInfoTextFor(
            entry: entry,
            fields: <String>['title'],
            separator: separator,
          ),
          '作品标题',
        );
      }
    });

    test('顺序是"出现顺序"而不是固定顺序 —— 排序能被保存的关键', () {
      final template = buildIllustCardInfoTemplate(
        <String>['size', 'author', 'title'],
        '-',
      );
      expect(template, '{size}-{author}-{title}');
      expect(parseIllustCardInfoTemplate(template).fields,
          <String>['size', 'author', 'title']);
    });

    test('重复字段保序去重', () {
      final parsed = parseIllustCardInfoTemplate('{title}_{author}_{title}');
      expect(parsed.fields, <String>['title', 'author']);
      expect(parsed.separator, '_');
    });

    test('只有一个字段时分隔符无意义 → 返回默认分隔符', () {
      expect(
        parseIllustCardInfoTemplate('{size}').separator,
        kDefaultIllustCardInfoSeparator,
      );
    });

    test('历史值里手写的分隔符（不在候选内）原样保留，不被改掉', () {
      final parsed = parseIllustCardInfoTemplate('{title} · {author}');
      expect(parsed.fields, <String>['title', 'author']);
      expect(parsed.separator, ' · ');
      expect(
        buildIllustCardInfoTemplate(parsed.fields, parsed.separator),
        '{title} · {author}',
      );
    });

    test('字段表与标签表一一对应（加字段时不会漏改一处）', () {
      expect(kIllustCardInfoFieldLabels.keys.toSet(),
          kIllustCardInfoFieldKeys.toSet());
      for (final key in kIllustCardInfoFieldKeys) {
        expect(kIllustCardInfoFieldLabels[key], isNotEmpty);
      }
      // 至少要提供计划点名的四类字段
      expect(
        kIllustCardInfoFieldKeys.toSet().containsAll(
          <String>{'title', 'author', 'pages', 'size'},
        ),
        isTrue,
      );
    });

    test('分隔符候选第一项就是默认值', () {
      expect(kIllustCardInfoSeparators.first, kDefaultIllustCardInfoSeparator);
    });
  });

  group('排序：与 27 号共用同一份实现', () {
    test('向下拖：newIndex 需减一，否则差一位', () {
      expect(
        reorderIllustCardInfoFieldOrder(<String>['a', 'b', 'c'], 0, 2),
        <String>['b', 'a', 'c'],
      );
    });

    test('向上拖：直接用 newIndex', () {
      expect(
        reorderIllustCardInfoFieldOrder(<String>['a', 'b', 'c'], 2, 0),
        <String>['c', 'a', 'b'],
      );
    });

    test('拖到末尾', () {
      expect(
        reorderIllustCardInfoFieldOrder(<String>['a', 'b', 'c'], 0, 3),
        <String>['b', 'c', 'a'],
      );
    });

    test('越界索引按"不动"处理（拖动取消时不崩）', () {
      final order = <String>['a', 'b', 'c'];
      expect(reorderIllustCardInfoFieldOrder(order, -1, 1), order);
      expect(reorderIllustCardInfoFieldOrder(order, 9, 0), order);
      expect(reorderIllustCardInfoFieldOrder(order, 0, -5),
          <String>['a', 'b', 'c']);
      // 原列表不被原地修改
      expect(order, <String>['a', 'b', 'c']);
    });

    test('与 27 号的 Pixiv 版本行为一致（同一份算法）', () {
      const cases = <List<int>>[
        <int>[0, 2],
        <int>[2, 0],
        <int>[1, 1],
        <int>[0, 3],
        <int>[3, 0],
      ];
      for (final c in cases) {
        expect(
          reorderIllustCardInfoFieldOrder(
              <String>['a', 'b', 'c', 'd'], c[0], c[1]),
          reorderPixivDirNameFieldOrder(
              <String>['a', 'b', 'c', 'd'], c[0], c[1]),
        );
        expect(
          reorderIllustCardInfoFieldOrder(
              <String>['a', 'b', 'c', 'd'], c[0], c[1]),
          reorderTemplateFieldOrder(<String>['a', 'b', 'c', 'd'], c[0], c[1]),
        );
      }
    });
  });

  group('取值与渲染：字段值、跳过空值、样式', () {
    test('标题 + 作者 + 尺寸都取到', () {
      final entry = _entry(width: 638, height: 1200);
      final text = illustrateCardInfoTextFor(
        entry: entry,
        fields: <String>['title', 'author', 'size'],
        separator: '\n',
      );
      expect(text, '作品标题\n作者名\n638×1200');
    });

    test('值为空的字段整项跳过，不留分隔符尾巴', () {
      final entry = _entry(author: '   ');
      final text = illustrateCardInfoTextFor(
        entry: entry,
        fields: <String>['title', 'author'],
        separator: '\n',
      );
      expect(text, '作品标题');
      expect(text.endsWith('\n'), isFalse);
    });

    test('全部为空 → 空串（卡片不渲染信息块）', () {
      final entry = _entry(name: '', author: '');
      expect(
        illustrateCardInfoTextFor(
          entry: entry,
          fields: <String>['title', 'author'],
          separator: '\n',
        ),
        '',
      );
    });

    test('未勾选任何字段 → 空串（而不是回落默认内容）', () {
      final entry = _entry();
      expect(
        illustrateCardInfoTextFor(
          entry: entry,
          fields: const <String>[],
          separator: '\n',
        ),
        '',
      );
    });

    test('尺寸：缺任一维就不渲染（不显示 638× 这种半截值）', () {
      expect(illustCardInfoSizeText(null, 1200), '');
      expect(illustCardInfoSizeText(638, null), '');
      expect(illustCardInfoSizeText(0, 1200), '');
      expect(illustCardInfoSizeText(-1, 1200), '');
      expect(illustCardInfoSizeText(638, 1200), '638×1200');
    });

    test('尺寸随运行时补齐变化（真实比例那条链路的落点）', () {
      final entry = _entry();
      expect(
        illustrateCardInfoTextFor(
          entry: entry,
          fields: <String>['size'],
          separator: '\n',
        ),
        '',
      );
      final resolved = entry.withResolvedInfo(width: 638, height: 1200);
      expect(
        illustrateCardInfoTextFor(
          entry: resolved,
          fields: <String>['size'],
          separator: '\n',
        ),
        '638×1200',
      );
    });

    test('页数：未补到就不渲染；补到后是 `p{N}`（33 号：与下载命名同口径）', () {
      final entry = _entry();
      expect(
        illustrateCardInfoTextFor(
          entry: entry,
          fields: <String>['pages'],
          separator: '\n',
        ),
        '',
      );
      final withPages = entry.withResolvedInfo(pageCount: 3);
      expect(withPages.pageCount, 3);
      expect(
        illustrateCardInfoTextFor(
          entry: withPages,
          fields: <String>['pages'],
          separator: '\n',
        ),
        'p3',
      );
      // 单图**不显示页数**（36 号真机反馈：「p0 单图的就不用显示页数了」）。
      //
      // ⚠️ 注意这与**下载目录名**的约定不同：目录名里单图仍是 `p0`
      // （28 号拍板、已写进 db 的身份），卡片这一侧才省略。两处刻意不同口径，
      // 所以这里断的是空串，而不是"和 pixivPagesSuffix 一致"。
      expect(
        illustrateCardInfoTextFor(
          entry: entry.withResolvedInfo(pageCount: 1),
          fields: <String>['pages'],
          separator: '\n',
        ),
        '',
      );
      // 未知（0 / 负数 / null）同样不渲染这一项。
      expect(
        illustrateCardInfoTextFor(
          entry: entry.withResolvedInfo(pageCount: 0),
          fields: <String>['pages'],
          separator: '\n',
        ),
        '',
      );
    });

    test('页数文案：多图 p{N}，单图与未知空串（与目录名的单图约定刻意不同）', () {
      expect(illustCardInfoPageText(2), 'p2');
      expect(illustCardInfoPageText(18), 'p18');
      expect(illustCardInfoPageText(1), '', reason: '单图不显示页数');
      expect(illustCardInfoPageText(0), '');
      expect(illustCardInfoPageText(-1), '');
      // 目录名那一侧不受影响：单图仍是 `p0`（回归守卫）。
      expect(pixivPagesSuffix(1), 'p0');
      expect(pixivPagesSuffix(18), 'p18');
    });

    test('标题是唯一"强调"字段（顺序变了也不变），分隔符是次要样式', () {
      final entry = _entry(width: 638, height: 1200);
      final spans = illustrateCardInfoSpansFor(
        entry: entry,
        fields: <String>['size', 'title', 'author'],
        separator: ' - ',
      );
      expect(spans.map((s) => s.text).toList(),
          <String>['638×1200', ' - ', '作品标题', ' - ', '作者名']);
      expect(spans.map((s) => s.emphasized).toList(),
          <bool>[false, false, true, false, false]);
    });

    test('默认配置的片段 = 标题（强调）+ 换行 + 作者（次要）', () {
      final entry = _entry();
      final spans = illustrateCardInfoSpansFor(
        entry: entry,
        fields: kDefaultIllustCardInfoFields,
        separator: kDefaultIllustCardInfoSeparator,
      );
      expect(spans.length, 3);
      expect(spans[0].text, '作品标题');
      expect(spans[0].emphasized, isTrue);
      expect(spans[1].text, '\n');
      expect(spans[1].emphasized, isFalse);
      expect(spans[2].text, '作者名');
      expect(spans[2].emphasized, isFalse);
    });

    test('分隔符为"无"时字段直接相连', () {
      final entry = _entry();
      expect(
        illustrateCardInfoTextFor(
          entry: entry,
          fields: <String>['title', 'author'],
          separator: '',
        ),
        '作品标题作者名',
      );
    });

    test('buildIllustCardInfoText 与 spans 是同一份拼接结果', () {
      final spans = buildIllustCardInfoSpans(
        fields: <String>['title', 'author', 'size'],
        separator: ' / ',
        values: const <String, String>{
          'title': 'T',
          'author': '',
          'size': '10×20',
        },
      );
      expect(
        buildIllustCardInfoText(
          fields: <String>['title', 'author', 'size'],
          separator: ' / ',
          values: const <String, String>{
            'title': 'T',
            'author': '',
            'size': '10×20',
          },
        ),
        spans.map((s) => s.text).join(),
      );
      expect(spans.map((s) => s.text).toList(), <String>['T', ' / ', '10×20']);
    });
  });

  group('预览：与真实渲染走同一条路径', () {
    test('默认配置的预览 = 标题 + 换行 + 作者（样例取自真实形态）', () {
      final preview = illustCardInfoPreview(
        kDefaultIllustCardInfoFields,
        kDefaultIllustCardInfoSeparator,
      );
      expect(
          preview, '$kPixivDirNamePreviewTitle\n$kPixivDirNamePreviewAuthor');
    });

    test('勾了尺寸时预览里能看到尺寸样例', () {
      final preview = illustCardInfoPreview(
        <String>['size'],
        kDefaultIllustCardInfoSeparator,
      );
      expect(preview, kIllustCardInfoPreviewSize);
      expect(preview, '1200×1600');
    });

    test('勾了页数时预览里能看到页数样例（p3，与下载命名同口径）', () {
      final preview = illustCardInfoPreview(
        <String>['pages'],
        kDefaultIllustCardInfoSeparator,
      );
      expect(preview, 'p$kPixivDirNamePreviewPages');
      expect(preview, 'p3');
      // 预览与真实渲染必须是**同一个函数**算出来的，不能各写一份三分支。
      expect(preview, illustCardInfoPageText(kPixivDirNamePreviewPages));
    });

    test('一个字段都没勾 → 空串（调用方显示占位，不回落默认内容）', () {
      expect(illustCardInfoPreview(const <String>[], '\n'), '');
    });

    test('预览与真实渲染用同一套取值：结构一致（字段数与非空项数相同）', () {
      final fields = <String>['title', 'author', 'size'];
      final previewLines = illustCardInfoPreview(fields, '\n').split('\n');
      final realLines = illustrateCardInfoTextFor(
        entry: _entry(width: 638, height: 1200),
        fields: fields,
        separator: '\n',
      ).split('\n');
      expect(previewLines.length, realLines.length);
    });
  });
}
