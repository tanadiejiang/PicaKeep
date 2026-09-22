/// EH 的**纯 Dart** 模型：列表条目、分页结果、HTML 响应与分类 / 榜期枚举。
///
/// 与 `eh_models.dart` 分开的理由：后者还定义了 `Gallery`（详情对象），它引用
/// `foundation/history.dart` → `state_controller.dart`（Flutter）。列表解析测试
/// 只需要这些轻量模型，混在一起会让 `dart test` 牵连整棵 Flutter 依赖树。
library;

import 'package:picakeep/network/base_comic.dart';

/// ehentai 搜索结果 / 收藏列表用的轻量条目。
///
/// 接入 PicaKeep 的 [BaseComic] 抽象，使其能直接被在线列表通用组件渲染。
/// 字段映射（公共契约）：id => link、cover => coverPath、subTitle => uploader。
class EhGalleryBrief extends BaseComic {
  @override
  String title;
  String type;
  String time;
  String uploader;
  double stars; // 0-5
  String coverPath;
  String link;
  @override
  List<String> tags;
  int? pages;

  EhGalleryBrief(
    this.title,
    this.type,
    this.time,
    this.uploader,
    this.coverPath,
    this.stars,
    this.link,
    this.tags, {
    this.pages,
  });

  @override
  String get cover => coverPath;

  @override
  String get description => time;

  /// 画廊完整 URL，即公共契约的唯一标识。
  @override
  String get id => link;

  @override
  String get subTitle => uploader;

  @override
  bool get enableTagsTranslation => true;
}

/// 一页搜索 / 收藏列表的结果集，附带下一页游标。
///
/// ehentai 用 [next] 游标翻页，而非纯页码。
class Galleries {
  List<EhGalleryBrief> galleries = [];

  /// 下一页的链接（游标）；为 null 表示没有下一页。
  String? next;

  EhGalleryBrief operator [](int index) => galleries[index];

  int get length => galleries.length;
}

/// 带最终响应地址的 HTML 响应。
///
/// 列表页的相对 `next` 游标必须按**本次最终响应地址**解析（重定向后 origin 可能
/// 不同）。独立成类型而不是借用 `Res.subData`：后者在既有链路里是"收藏夹名 /
/// 分页"语义，改语义会静默破坏老调用方。
class EhHtmlResponse {
  const EhHtmlResponse({required this.body, required this.finalUri});

  final String body;
  final String finalUri;

  @override
  String toString() => 'EhHtmlResponse(${body.length} bytes, $finalUri)';
}

/// EH 画廊类型（f_cats 位序，与原项目一致）。
///
/// 单类型筛选值为 `1023 ^ (1 << index)`（反码），全部为 0。
enum EhGalleryCategory {
  misc('Misc'),
  doujinshi('Doujinshi'),
  manga('Manga'),
  artistCg('Artist CG'),
  gameCg('Game CG'),
  imageSet('Image Set'),
  cosplay('Cosplay'),
  asianPorn('Asian Porn'),
  nonH('Non-H'),
  western('Western');

  const EhGalleryCategory(this.label);

  final String label;

  /// 该类型在 f_cats 里的位序号（与枚举声明顺序一致）。
  int get bit => index;

  /// 只保留该类型时的 `f_cats` 取值。
  int get singleFCats => 1023 ^ (1 << index);

  /// 全部类型的 `f_cats` 取值。
  static const int allFCats = 0;

  static EhGalleryCategory? tryFromId(String id) {
    for (final category in EhGalleryCategory.values) {
      if (category.name == id) return category;
    }
    return null;
  }
}

/// toplist 榜期（tl 参数）。标签沿用站点口径，**不改写**（「昨天」不叫今日）。
enum EhToplistPeriod {
  yesterday('15', '昨天'),
  month('13', '本月'),
  year('12', '今年'),
  all('11', '全部');

  const EhToplistPeriod(this.value, this.label);

  final String value;
  final String label;

  static EhToplistPeriod? tryFromId(String id) {
    for (final period in EhToplistPeriod.values) {
      if (period.name == id) return period;
    }
    return null;
  }
}

/// 单条评论。
class Comment {
  String id;
  String name;
  String content;
  String time;
  int score;

  /// true: up, false: down, null: 未投票
  bool? voteUP;

  Comment(this.id, this.name, this.content, this.time, this.score, this.voteUP);
}
