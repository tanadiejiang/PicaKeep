/// 插画卡片**底部信息**的字段配置：选哪些字段、按什么顺序、用什么分隔。
///
/// ## 需求来源
///
/// 用户真机反馈原话：「下面的信息可以在设置里显示，也是和下载命名一样可以自由选择」。
/// 所以交互形态**照 27 号「Pixiv 下载目录名模板」**：勾选字段 + 拖拽排序 + 实时预览。
///
/// ## 持久化格式：与 27 号一致（模板串）
///
/// `settings[illustCardInfoSettingIndex]` 里存的是**模板串**，例如默认值
/// `'{title}\n{author}'`。选模板串而不是 JSON 数组的理由与 27 号相同：
///
/// - 设置数组是 `List<String>`，一个下标只能放一个字符串；模板串是它的自然形态；
/// - `build` → `store` → `parse` 往返幂等，可被直接单元测试；
/// - 与 27 号共用 [reorderTemplateFieldOrder] 与同构的 parse/build，
///   将来加字段时两处的改法一致，不会一处会、一处不会。
///
/// 唯一与 27 号不同的是**默认分隔符是换行**（27 号是 `-`）。原因见
/// [kDefaultIllustCardInfoSeparator]。
library;

import 'package:picakeep/foundation/local_library_illust_view.dart';
import 'package:picakeep/foundation/pixiv_download_naming.dart'
    show
        kPixivDirNamePreviewAuthor,
        kPixivDirNamePreviewPages,
        kPixivDirNamePreviewTitle,
        pixivPagesSuffix;
import 'package:picakeep/foundation/template_field_order.dart';

/// `settings[]` 下标：插画卡片底部信息模板。
///
/// 从 **158** 起：执行前实测 `lib/base.dart` 的 `settings` 数组长度为 158
/// （下标 0..157），155/156/157 已被 24 号的「图集页改版与插画视图」占用
/// （视图 / 瀑布流列数 / 切换按钮位置），154 是 23 号的 `pixivMultiPageZip`。
/// 在已有下标之前插入会让后面全部漂移，所以新项一律**追加**。
const int illustCardInfoSettingIndex = 158;

/// 可参与卡片底部信息的字段，**顺序即设置页弹窗里的初始排列**。
///
/// 与 27 号同样的组织方式：字段表与标签表都放在本文件，避免 UI 与解析各改一半。
const List<String> kIllustCardInfoFieldKeys = <String>[
  'title',
  'author',
  'pages',
  'size',
];

/// 字段 → 设置页展示名。
const Map<String, String> kIllustCardInfoFieldLabels = <String, String>{
  'title': '标题',
  'author': '作者',
  'pages': '页数',
  'size': '尺寸',
};

/// 模板里的变量占位符。**渲染与解析共用同一个正则** —— 两处各写一份的话，
/// 加字段时很容易只改一处，症状是"设置页勾得上、卡片上不显示"。
final RegExp _illustCardInfoVariablePattern =
    RegExp(r'\{(title|author|pages|size)\}');

/// 默认分隔符：**换行**。
///
/// 这是本配置与 27 号唯一的形态差异，理由很具体：改动前卡片底部就是
/// **标题 + 作者各占一行**（`local_library_illust_card.dart` 里两个独立的 `Text`）。
/// 「默认值要与现状一致」是 32 号计划的硬约束 —— 默认 `-` 会让升级后的卡片
/// 从两行变成一行中间多个横杠，观感突变。
///
/// 换行作为分隔符也正好让"每项一行"成为默认手感，而想紧凑的用户可以选空格 /
/// 横杠 / 下划线 / 无。
const String kDefaultIllustCardInfoSeparator = '\n';

/// 默认字段顺序：标题 + 作者（= 改动前写死的那两项）。
const List<String> kDefaultIllustCardInfoFields = <String>[
  'title',
  'author',
];

/// 默认模板串（与 [kDefaultIllustCardInfoFields] + 默认分隔符等价）。
const String kDefaultIllustCardInfoTemplate = '{title}\n{author}';

/// 分隔符候选（第一项为默认）。`''` = 字段之间不加任何字符。
///
/// 顺序即设置页里 chip 的排列顺序，默认项在前。
const List<String> kIllustCardInfoSeparators = <String>[
  '\n',
  ' ',
  '-',
  '_',
  ''
];

/// 预览用的样例值。
///
/// 标题 / 作者 / 页数沿用 27 号的预览样例：两处设置页展示同一个作品，
/// 用户来回对照时不会以为"是不是配错了"。尺寸样例取一个竖构图原图的常见形态。
const String kIllustCardInfoPreviewSize = '1200×1600';

/// 用固定样例渲染卡片信息预览。
///
/// 与真实渲染走**同一条取值 → 拼接路径**（见 [buildIllustCardInfoText]），
/// 保证用户"看到什么就是卡片上显示什么"。
///
/// 空字段列表返回空串（调用方显示"未勾选任何字段"的占位）：**不能**让它落到
/// 默认模板兜底上 —— 那是"配置坏掉时的保险"，与"用户主动一个都没勾"是两回事。
String illustCardInfoPreview(List<String> fields, String separator) {
  if (fields.isEmpty) {
    return '';
  }
  final values = <String, String>{
    'title': kPixivDirNamePreviewTitle,
    'author': kPixivDirNamePreviewAuthor,
    'pages': illustCardInfoPageText(kPixivDirNamePreviewPages),
    'size': kIllustCardInfoPreviewSize,
  };
  return buildIllustCardInfoText(
    fields: fields,
    separator: separator,
    values: values,
  );
}

/// 按 [fields] 的顺序、用 [separator] 连接，生成模板串。
///
/// 空列表返回空串；空模板在 [renderIllustCardInfoFields] 里会退回默认字段，
/// 所以调用方若要表达"一个字段都没选"，应自己拦在保存之前（设置页就是这么做的）。
String buildIllustCardInfoTemplate(List<String> fields, String separator) {
  return fields.map((key) => '{$key}').join(separator);
}

/// 解析模板串 →（勾选的字段按出现顺序、字段间的分隔符）。
///
/// 这是"勾选 + 拖拽排序"能落回**模板串**的桥：`settings[158]` 里存的仍然是
/// 模板字符串，设置页只是它的另一个编辑入口 —— 因此**不需要数据迁移**，
/// 老值（含用户手写过的模板）也能被还原成勾选与顺序。
///
/// 规则（与 `parsePixivDirNameTemplate` 逐条对齐）：
/// - 字段按模板里的**出现顺序**返回 —— 这正是"排序"能被保存并还原的关键；
/// - 重复出现的字段**保序去重**（`{title}_{title}` 只算一个 `title`）；
/// - 分隔符取「第一个字段结束 → 第二个字段开始」之间的**原文**；
///   不足两个字段时分隔符无意义，返回默认分隔符；
/// - **一个字段都解析不出**（例如历史值是 `{foo}`）→ 退回只含标题 + 作者的默认规格。
///   **不抛错、不返回空** —— 用户不该因为一个坏值看到弹窗变空、或把设置写坏。
({List<String> fields, String separator}) parseIllustCardInfoTemplate(
  String template,
) {
  final matches = _illustCardInfoVariablePattern
      .allMatches(template)
      .toList(growable: false);
  final seen = <String>{};
  final fields = <String>[];
  for (final match in matches) {
    final key = match.group(1)!;
    if (seen.add(key)) {
      fields.add(key);
    }
  }
  if (fields.isEmpty) {
    return (
      fields: <String>[...kDefaultIllustCardInfoFields],
      separator: kDefaultIllustCardInfoSeparator,
    );
  }
  // 用 matches（而非去重后的 fields）取间隙：`{title}\n{title}` 这种重复写法，
  // 间隙仍是 `\n`，取它比取"去重后两字段之间的整段"更贴近用户写下的意图。
  final separator = matches.length >= 2
      ? template.substring(matches[0].end, matches[1].start)
      : kDefaultIllustCardInfoSeparator;
  return (fields: fields, separator: separator);
}

/// 归一化模板值：空白（含未设置）一律回落到默认模板。
///
/// 这一层与 [renderIllustCardInfoFields] 内部对空模板的兜底**两道都要有**：
/// 前者保证设置数组里不留空白串，后者保证任何调用方直接传空也拿到合理结果。
String normalizeIllustCardInfoTemplate(String? value) {
  final trimmed = (value ?? '').trim();
  return trimmed.isEmpty ? kDefaultIllustCardInfoTemplate : trimmed;
}

String encodeIllustCardInfoTemplate({
  required List<String> fields,
  required String separator,
}) {
  return buildIllustCardInfoTemplate(fields, separator);
}

/// 从当前设置值取"要显示哪些字段、怎么分隔"。
({List<String> fields, String separator}) illustCardInfoSpecFromSetting(
  String? raw,
) {
  return parseIllustCardInfoTemplate(normalizeIllustCardInfoTemplate(raw));
}

/// 「页数」的展示文案：**多图 `p{N}`、单图与未知一律空串（不显示）**。
///
/// ## 为什么从 `'@pages 页'` 改成 `p{N}`
///
/// 33 号真机反馈原话：「把那个页改成 p 几就行了」。改动前卡片显示
/// `Vodyanitsa🎨 \n 1 页`，而同一个作品下载到盘上的名字是 `..._p0.jpg` ——
/// 两处对不上，用户要求统一到**产物名的那套记号**。
///
/// ## 为什么单图不显示（36 号追加反馈）
///
/// 用户原话：「p0 单图的就不用显示页数了」—— 一张图的作品标 `p0` 只是噪音。
///
/// ⚠️ **只改卡片这一侧**。下载目录名仍走 [pixivPagesSuffix]（单图 = `p0`），
/// 那是 28 号拍板、且**已经写进 `download.db` 的命名约定**：目录名是记录的
/// 一部分，跟着卡片观感一起改会让新旧下载变成两套命名。所以这里不再整体转调
/// 那个函数，而是"单图先拦掉，其余仍交给它"——保证多图与未知两档的口径
/// 与目录名**逐字一致**，只有单图这一档是卡片特有的省略。
///
/// 顺带不再需要翻译：`p3` 是**语言无关的记号**，所以 `'@pages 页'` 那个 tlParams
/// 占位符（以及它在 `assets/translation.json` 里的两条译文）在卡片侧不再被用到。
/// "未知页数不显示"仍沿用卡片侧的空值跳过（见 [buildIllustCardInfoSpans]）。
String illustCardInfoPageText(int pages) {
  if (pages <= 1) {
    return '';
  }
  return pixivPagesSuffix(pages);
}

/// 「尺寸」的展示文案：`宽×高`。任一维缺失返回空串（该项不渲染）。
String illustCardInfoSizeText(int? width, int? height) {
  if (width == null || height == null || width <= 0 || height <= 0) {
    return '';
  }
  return '$width×$height';
}

/// 把"选中的字段 + 分隔符"渲染成最终要显示的一段文本（可能含换行）。
///
/// **不在这里兜底到默认字段**：调用方先用 [parseIllustCardInfoTemplate]
/// （它已经兜过底）拿到 `fields`，再进来时若 `fields` 为空只可能是"确实没选"，
/// 返回空串让卡片不渲染这一块，比强行显示默认内容更诚实。
String buildIllustCardInfoText({
  required List<String> fields,
  required String separator,
  required Map<String, String> values,
}) {
  return buildIllustCardInfoSpans(
    fields: fields,
    separator: separator,
    values: values,
  ).map((span) => span.text).join();
}

/// 卡片底部信息的一个**渲染片段**：一段文本 + 是否用强调样式。
///
/// 为什么要拆成片段而不是一个整串：卡片要按字段给不同字重（标题醒目、其余次要），
/// 而分隔符（可能是换行、也可能是 `-`）夹在字段之间。整串渲染就只能整块一个样式，
/// 那会让默认观感（标题加粗、作者次要）丢失。
///
/// 预览（[buildIllustCardInfoText]）与卡片渲染共用本函数，两者的取值与拼接顺序
/// **由构造保证一致** —— 这正是"预览里看到什么，卡片上就显示什么"的实现方式。
class IllustCardInfoSpan {
  const IllustCardInfoSpan(
    this.text, {
    required this.emphasized,
    this.isSeparator = false,
  });

  final String text;

  /// 用强调样式（加粗）。只有 `title` 为真，见 [buildIllustCardInfoSpans]。
  final bool emphasized;

  /// 这一段是不是"字段之间的分隔符"。
  ///
  /// 卡片据此算 `maxLines`：分隔符不该占行数额度。不能用"文本是否为空"代替这个
  /// 判据 —— `' - '` 这种可见分隔符去掉空白后非空，会被数成一个字段值，
  /// 于是 3 个字段被算成 5，`maxLines` 虚高。
  final bool isSeparator;

  @override
  String toString() => 'IllustCardInfoSpan($text, sep: $isSeparator)';
}

/// 产出渲染片段：字段值 + **夹在非空字段之间**的分隔符。
///
/// 值是空串的字段**整项跳过，连它前后的分隔符一起不产出** ——
/// 否则作者缺失时会留下 `标题\n` 这种尾巴（卡片上多一行空白）。
///
/// 强调规则：只有 `title` 加粗，其余字段（作者 / 页数 / 尺寸）次要。
/// 这是**改动前的观感**（标题 `bodySmall` 加粗、作者 `labelSmall` 次要色），
/// 也是与顺序无关的稳定规则 —— 用户把作者拖到第一位时，加粗的仍是标题，
/// 不会因为排序而"哪个字段最醒目"变来变去。
List<IllustCardInfoSpan> buildIllustCardInfoSpans({
  required List<String> fields,
  required String separator,
  required Map<String, String> values,
}) {
  final spans = <IllustCardInfoSpan>[];
  for (final key in fields) {
    final value = values[key]?.trim() ?? '';
    if (value.isEmpty) {
      continue;
    }
    if (spans.isNotEmpty && separator.isNotEmpty) {
      // 分隔符跟随"次要"样式：换行时它不含字形（无影响），
      // 而 `-` / `_` 这类可见分隔符与作者/页数同色才不会突兀。
      spans.add(
        IllustCardInfoSpan(separator, emphasized: false, isSeparator: true),
      );
    }
    spans.add(IllustCardInfoSpan(value, emphasized: key == 'title'));
  }
  return spans;
}

/// 供 UI 直接调用的"一条条目 → 卡片底部文本"。
///
/// [fields]/[separator] 由调用方从设置里解析好传进来（见
/// [illustCardInfoSpecFromSetting]），而不是在这里读 `appdata` ——
/// 纯函数才能被直接单元测试，也才能被设置页的预览复用同一套取值。
String illustrateCardInfoTextFor({
  required IllustLibraryEntry entry,
  required List<String> fields,
  required String separator,
}) {
  return illustrateCardInfoSpansFor(
    entry: entry,
    fields: fields,
    separator: separator,
  ).map((span) => span.text).join();
}

/// 同 [illustrateCardInfoTextFor]，但返回带样式的片段（卡片渲染用这个）。
List<IllustCardInfoSpan> illustrateCardInfoSpansFor({
  required IllustLibraryEntry entry,
  required List<String> fields,
  required String separator,
}) {
  return buildIllustCardInfoSpans(
    fields: fields,
    separator: separator,
    values: _illustCardInfoValues(entry),
  );
}

Map<String, String> _illustCardInfoValues(IllustLibraryEntry entry) => {
      'title': entry.item.name.trim(),
      'author': entry.item.subTitle.trim(),
      'pages': entry.pageCount == null
          ? ''
          : illustCardInfoPageText(entry.pageCount!),
      'size': illustCardInfoSizeText(entry.width, entry.height),
    };

/// 只为已勾选、仍未知的异步字段预留布局空间。已知单图不需要页数行。
Set<String> illustCardInfoPendingFieldsFor({
  required IllustLibraryEntry entry,
  required List<String> fields,
}) =>
    {
      if (fields.contains('pages') && entry.pageCount == null) 'pages',
      if (fields.contains('size') && !entry.hasRealSize) 'size',
    };

/// 仅供 TextPainter 测量的片段，不能绘制或放进语义树。
///
/// [reservedFields] 来自卡片初次显示时的未知字段；解析为单图时调用方立即
/// 释放页数预留，避免留白一直持续到离屏重建。
/// 非换行模板仍按原分隔符拼接；示例宽度只提供最小高度，极端长数值可以折行。
List<IllustCardInfoSpan> illustCardInfoLayoutSpansFor({
  required IllustLibraryEntry entry,
  required List<String> fields,
  required String separator,
  required Set<String> reservedFields,
}) {
  final values = _illustCardInfoValues(entry);
  if (reservedFields.contains('pages')) values['pages'] = 'p88';
  if (reservedFields.contains('size')) values['size'] = '88888×88888';
  return buildIllustCardInfoSpans(
      fields: fields, separator: separator, values: values);
}

/// 卡片底部信息的字段顺序调整（设置页 `onReorder` 调它）。
///
/// 转调共用的 [reorderTemplateFieldOrder]。
List<String> reorderIllustCardInfoFieldOrder(
  List<String> order,
  int oldIndex,
  int newIndex,
) {
  return reorderTemplateFieldOrder(order, oldIndex, newIndex);
}
