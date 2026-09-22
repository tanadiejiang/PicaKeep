/// EH 列表页的**纯 Dart 解析**。
///
/// 从 `eh_main_network.dart` 抽出来：那个文件依赖 Flutter 与 `base.dart`
/// （`appdata`），解析留在里面会让纯层测试无法用 `dart test` 运行。
/// 本文件只依赖 `dart:`、`package:html`（纯 Dart）与 EH 的纯模型。
library;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart';
import 'package:picakeep/network/eh_network/eh_brief_models.dart';
import 'package:picakeep/tools/extensions.dart';

/// 列表页解析结果。
class EhParsedGalleryList {
  const EhParsedGalleryList({
    required this.galleries,
    required this.next,
    required this.rawRowCount,
    required this.failedRowCount,
    this.containerFound = false,
  });

  final List<EhGalleryBrief> galleries;

  /// 下一页游标（已按响应地址解析成绝对 URL）；null 表示没有下一页。
  final String? next;

  /// 识别到的列表行数（含被屏蔽 / 解析失败的坏行）。
  final int rawRowCount;

  /// 识别到但解析失败的行数。
  final int failedRowCount;

  /// 页面里**存在**列表容器（`table.itg` / `div.gl1t` / 榜单的 `table.ptt`）。
  ///
  /// 用于区分两种"0 条"：真正的"无结果页"（页面里根本没有列表容器）与
  /// "容器在、我们却一行都没解析出来"（结构变了）。后者必须报解析失败，
  /// 否则界面会显示"没有内容"，把**解析故障伪装成空结果**。
  final bool containerFound;

  /// 识别到数据行却**全部**解析失败 —— 必须报 parse，不能伪装成空列表。
  bool get allRowsFailed => rawRowCount > 0 && galleries.isEmpty;

  /// 该页是"解析失败"而不是"真的没有内容"。
  bool get isParseFailure =>
      allRowsFailed || (rawRowCount == 0 && containerFound);
}

/// EH 列表页解析（四种布局 + 榜单名次列）。
///
/// [responseUri] 用于把相对 `next` 解析成绝对地址（重定向后 origin 会变）；
/// [leaderboard] 为 true 时 compact 表格首列是**名次**，后续列整体后移一位
/// （这是普通 compact 解析在榜单页会吞异常、返回假空列表的根因）。
EhParsedGalleryList parseEhGalleryList(
  String html, {
  required String responseUri,
  bool leaderboard = false,
}) {
  final document = parse(html);
  final galleries = <EhGalleryBrief>[];
  var rawRows = 0;
  var failedRows = 0;

  // ── compact mode（gltc）─────────────────────────────────────────────────
  //
  // **按特征识别，不按列下标。** 早先的实现照抄"第 0 列是类型、第 2 列是时间"
  // 这类下标假设，一旦站点增删列（榜单页多个名次列、收藏夹页没有上传者列、
  // 站点改版）就会整行解析失败；`try/catch` 把失败吞掉后表现为"假空列表"，
  // 也就是用户看到的"EH 加载不出任何内容"。
  //
  // 现在改为在**每一行内部**按语义选择器取字段：类型找 `div.cs`、封面找
  // `img`、星级找 `div.ir` 的 style、标题找 `div.glink` / `a[href*="/g/"]`、
  // 标签找 `div[title]`、页数找含 "pages" 的 div、时间找能被 `DateTime.parse`
  // 识别的 div、上传者取"非标题、非封面"的链接文本。列序与列数因此都不再重要，
  // 榜单的名次列也就天然不需要 [leaderboard] 做偏移（该参数仍保留用于分页导航）。
  for (var item in document.querySelectorAll('table.itg.gltc > tbody > tr')) {
    rawRows++;
    try {
      final brief = parseEhCompactRow(item, responseUri);
      if (brief == null) {
        failedRows++;
        continue;
      }
      galleries.add(brief);
    } catch (e) {
      // 空行 / 被屏蔽行 / 结构异常
      failedRows++;
    }
  }

  // ── Thumbnail mode（gl1t）──────────────────────────────────────────────
  for (var item in document.querySelectorAll('div.gl1t')) {
    rawRows++;
    try {
      final title = item.querySelector('a')?.text ?? 'Unknown';
      final type =
          item.querySelector('div.gl5t > div > div.cs')?.text ?? 'Unknown';
      final time = item
              .querySelectorAll('div.gl5t > div > div')
              .firstWhereOrNull(
                  (element) => DateTime.tryParse(element.text) != null)
              ?.text ??
          'Unknown';
      final coverPath = item.querySelector('img')?.attributes['src'] ?? '';
      final stars = _starsFromPosition(
          item.querySelector('div.gl5t > div > div.ir')?.attributes['style'] ??
              '');
      final link = item.querySelector('a')?.attributes['href'] ?? '';
      final pages = int.tryParse(item
              .querySelectorAll('div.gl5t > div > div')
              .firstWhereOrNull((element) => element.text.contains('pages'))
              ?.text
              .nums ??
          '');
      final brief = EhGalleryBrief(
          title, type, time, '', coverPath, stars, link, [],
          pages: pages);
      final normalized = normalizeEhGalleryBrief(brief, responseUri);
      if (normalized == null) {
        failedRows++;
        continue;
      }
      galleries.add(normalized);
    } catch (e) {
      failedRows++;
    }
  }

  // ── Extended mode（glte）───────────────────────────────────────────────
  for (var item in document.querySelectorAll('table.itg.glte > tbody > tr')) {
    rawRows++;
    try {
      final title =
          item.querySelector('td.gl2e > div > a > div > div.glink')?.text ??
              'Unknown';
      final type =
          item.querySelector('td.gl2e > div > div.gl3e > div.cn')?.text ??
              'Unknown';
      final time = item
              .querySelectorAll('td.gl2e > div > div.gl3e > div')
              .firstWhereOrNull(
                  (element) => DateTime.tryParse(element.text) != null)
              ?.text ??
          'Unknown';
      final uploader =
          item.querySelector('td.gl2e > div > div.gl3e > div > a')?.text ??
              'Unknown';
      final coverPath =
          item.querySelector('td.gl1e > div > a > img')?.attributes['src'] ??
              '';
      final stars = _starsFromPosition(item
              .querySelector('td.gl2e > div > div.gl3e > div.ir')
              ?.attributes['style'] ??
          '');
      final link =
          item.querySelector('td.gl1e > div > a')?.attributes['href'] ?? '';
      final tags = item
          .querySelectorAll('div.gt, div.gtl')
          .map((e) => e.attributes['title'] ?? '')
          .where((e) => e.isNotEmpty)
          .toList();
      final pages = int.tryParse(item
              .querySelectorAll('td.gl2e > div > div.gl3e > div')
              .firstWhereOrNull((element) => element.text.contains('pages'))
              ?.text
              .nums ??
          '');
      final brief = EhGalleryBrief(
          title, type, time, uploader, coverPath, stars, link, tags,
          pages: pages);
      final normalized = normalizeEhGalleryBrief(brief, responseUri);
      if (normalized == null) {
        failedRows++;
        continue;
      }
      galleries.add(normalized);
    } catch (e) {
      failedRows++;
    }
  }

  // ── minimal mode（gltm）────────────────────────────────────────────────
  for (var item in document.querySelectorAll('table.itg.gltm > tbody > tr')) {
    rawRows++;
    try {
      final title =
          item.querySelector('td.gl3m > a > div.glink')?.text ?? 'Unknown';
      final type = item.querySelector('td.gl1m > div.cs')?.text ?? 'Unknown';
      final time = item
              .querySelectorAll('td.gl2m > div')
              .firstWhereOrNull(
                  (element) => DateTime.tryParse(element.text) != null)
              ?.text ??
          'Unknown';
      final uploader =
          item.querySelector('td.gl5m > div > a')?.text ?? 'Unknown';
      var coverPath =
          item.querySelector('td.gl2m > div > div > img')?.attributes['src'];
      final link = item.querySelector('td.gl3m > a')?.attributes['href'] ?? '';
      final stars = _starsFromPosition(
          item.querySelector('td.gl4m > div.ir')?.attributes['style'] ?? '');
      final brief = EhGalleryBrief(
          title, type, time, uploader, coverPath ?? '', stars, link, []);
      final normalized = normalizeEhGalleryBrief(brief, responseUri);
      if (normalized == null) {
        failedRows++;
        continue;
      }
      galleries.add(normalized);
    } catch (e) {
      failedRows++;
    }
  }

  // ── 下一页游标 ─────────────────────────────────────────────────────────
  String? next;
  if (leaderboard) {
    next = _parseToplistNext(document, responseUri);
  } else {
    next = resolveEhListCursor(
        document.getElementById('dnext')?.attributes['href'], responseUri);
  }

  // 页面里是否存在列表容器：用于把"结构变了导致一行都没解析出"与真正的
  // "无结果页"区分开（后者不该被报成解析失败）。
  final containerFound = document.querySelector('table.itg') != null ||
      document.querySelector('div.gl1t') != null ||
      document.querySelector('table.ptt') != null ||
      document.querySelector('div#gdt') != null;

  return EhParsedGalleryList(
    galleries: galleries,
    next: next,
    rawRowCount: rawRows,
    failedRowCount: failedRows,
    containerFound: containerFound,
  );
}

/// 解析 compact 表格的一行（按特征，不按列下标）。
///
/// 返回 `null` 表示该行不是一条可用的画廊（空行、被屏蔽行、缺关键字段）。
/// 公开是为了让纯层测试能直接对单行夹具回归（本文件不依赖 Flutter）。
EhGalleryBrief? parseEhCompactRow(dom.Element row, String responseUri) {
  // 封面：行内第一个 img；懒加载时 src 可能是占位 data:，回退 data-src。
  final img = row.querySelector('img');
  var cover = img?.attributes['src'] ?? '';
  if (cover.isEmpty || cover.startsWith('data:')) {
    final lazy = img?.attributes['data-src'];
    if (lazy != null && lazy.isNotEmpty) cover = lazy;
  }

  // 标题 + 链接：优先 glink（compact/extended 共用），退到行内首个画廊链接。
  final galleryAnchors = row
      .querySelectorAll('a')
      .where((a) => (a.attributes['href'] ?? '').contains('/g/'))
      .toList();
  final titleAnchor = galleryAnchors.isEmpty ? null : galleryAnchors.first;
  final title =
      (row.querySelector('div.glink')?.text ?? titleAnchor?.text ?? '').trim();
  final link = titleAnchor?.attributes['href'] ?? '';

  // 类型：compact 用 div.cs。
  final type = row.querySelector('div.cs')?.text.trim() ?? '';

  // 星级：div.ir 的 background-position。
  final stars = _starsFromPosition(
      row.querySelector('div.ir')?.attributes['style'] ?? '');

  // 标签：带 title 属性的标签格（namespace:tag）。
  final tags = row
      .querySelectorAll('div[title]')
      .map((e) => e.attributes['title'] ?? '')
      .where((e) => e.isNotEmpty)
      .toList();

  // 时间：能被 DateTime.parse 识别的 div（EH 的格式是 yyyy-MM-dd HH:mm）。
  var time = '';
  for (final div in row.querySelectorAll('div')) {
    final text = div.text.trim();
    if (text.isEmpty || text.length > 24) continue;
    if (DateTime.tryParse(text) != null) {
      time = text;
      break;
    }
  }

  // 页数：含 "pages" 的 div。
  int? pages;
  for (final div in row.querySelectorAll('div')) {
    final text = div.text;
    if (!text.contains('pages')) continue;
    final parsed = int.tryParse(text.nums);
    if (parsed != null && parsed > 0) {
      pages = parsed;
      break;
    }
  }

  // 上传者：行内**不是**标题链接、且不含 img 的链接文本。
  var uploader = '';
  for (final anchor in row.querySelectorAll('a')) {
    if (identical(anchor, titleAnchor)) continue;
    if (anchor.querySelector('img') != null) continue;
    final text = anchor.text.trim();
    if (text.isEmpty) continue;
    uploader = text;
    break;
  }

  final brief = EhGalleryBrief(
      title, type, time, uploader, cover, stars, link, tags,
      pages: pages);
  return normalizeEhGalleryBrief(brief, responseUri);
}

/// 榜单分页：`table.ptt` 里的 `>` / `Next` 链接。
///
/// 不查普通 `#dnext` —— toplist 的翻页导航是另一套 DOM。
String? _parseToplistNext(dom.Document document, String responseUri) {
  for (final anchor in document.querySelectorAll('table.ptt a')) {
    final text = anchor.text.trim();
    if (text == '>' || text == 'Next' || text == '下一頁') {
      return resolveEhListCursor(anchor.attributes['href'], responseUri);
    }
  }
  return null;
}

/// 把列表游标候选值解析成绝对地址。
///
/// 丢弃空值与自环（解析结果等于当前页地址）；相对地址按 [responseUri] 解析；
/// 非允许站点的地址直接丢弃。
String? resolveEhListCursor(String? raw, String responseUri) {
  final value = raw?.trim() ?? '';
  if (value.isEmpty) return null;
  final resolved =
      Uri.tryParse(responseUri)?.resolve(value).toString() ?? value;
  if (resolved == responseUri) return null;
  final host = Uri.tryParse(resolved)?.host.toLowerCase() ?? '';
  if (!isAllowedEhHost(host)) return null;
  return resolved;
}

/// 允许的 EH 站点 host（表站 / 里站）。
bool isAllowedEhHost(String host) {
  if (host.isEmpty) return false;
  return host == 'e-hentai.org' ||
      host == 'www.e-hentai.org' ||
      host == 'exhentai.org' ||
      host == 'www.exhentai.org' ||
      host.endsWith('.e-hentai.org') ||
      host.endsWith('.exhentai.org');
}

/// 探索列表条目的最小合法性校验。
///
/// 必须有**可识别的画廊链接**（`/g/<gid>/<token>`）与非空标题，排除空串和字面量
/// `"null"`；否则坏响应会被伪装成"空列表成功"。
///
/// 相对链接（`/g/1/abc/`）先按 [responseUri] 补成绝对地址再判断：站点偶尔返回
/// 相对 href，而条目 id 的公共契约是"完整画廊 URL"，直接放行会让详情/图片请求
/// 拿到不可用地址。
EhGalleryBrief? normalizeEhGalleryBrief(
  EhGalleryBrief brief,
  String responseUri,
) {
  final title = brief.title.trim();
  if (title.isEmpty || title == 'null') return null;
  final raw = brief.link.trim();
  if (raw.isEmpty || raw == 'null') return null;

  final uri = Uri.tryParse(raw);
  if (uri == null) return null;
  final resolved =
      uri.hasScheme ? uri : Uri.tryParse(responseUri)?.resolve(raw) ?? uri;
  final host = resolved.host.toLowerCase();
  if (!isAllowedEhHost(host)) return null;
  if (!RegExp(r'^/g/\d+/[0-9a-fA-F]+/?$').hasMatch(resolved.path)) return null;

  if (!uri.hasScheme) {
    brief.link = resolved.toString();
  }
  brief.title = title;
  return brief;
}

/// 兼容包装：只判断不做补全（供纯校验使用）。
bool isValidEhGalleryBrief(EhGalleryBrief brief) =>
    _hasEhGalleryShape(brief.link) && _hasEhTitle(brief.title);

bool _hasEhTitle(String title) {
  final value = title.trim();
  return value.isNotEmpty && value != 'null';
}

bool _hasEhGalleryShape(String link) {
  final value = link.trim();
  if (value.isEmpty || value == 'null') return false;
  final uri = Uri.tryParse(value);
  if (uri == null || !isAllowedEhHost(uri.host.toLowerCase())) return false;
  return RegExp(r'^/g/\d+/[0-9a-fA-F]+/?$').hasMatch(uri.path);
}

double _starsFromPosition(String position) {
  int i = 0;
  while (i < position.length && position[i] != ';') {
    i++;
  }
  switch (position.substring(0, i)) {
    case 'background-position:0px -1px':
      return 5;
    case 'background-position:0px -21px':
      return 4.5;
    case 'background-position:-16px -1px':
      return 4;
    case 'background-position:-16px -21px':
      return 3.5;
    case 'background-position:-32px -1px':
      return 3;
    case 'background-position:-32px -21px':
      return 2.5;
    case 'background-position:-48px -1px':
      return 2;
    case 'background-position:-48px -21px':
      return 1.5;
    case 'background-position:-64px -1px':
      return 1;
    case 'background-position:-64px -21px':
      return 0.5;
  }
  return 0.5;
}
