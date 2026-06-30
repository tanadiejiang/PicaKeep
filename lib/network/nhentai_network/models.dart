import 'package:flutter/cupertino.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/network/base_comic.dart';

/// nhentai 列表项（搜索/收藏/推荐通用）。
///
/// 适配点：照搬上游字段签名；[description] 复用 [lang]（语言）、[subTitle] 复用
/// [id]（与 picacg/eh brief 同惯例），[enableTagsTranslation] 恒 true。
@immutable
class NhentaiComicBrief extends BaseComic {
  @override
  final String title;
  @override
  final String cover;
  @override
  final String id;
  final String lang;
  @override
  final List<String> tags;

  const NhentaiComicBrief(this.title, this.cover, this.id, this.lang, this.tags);

  @override
  String get description => lang;

  @override
  String get subTitle => id;

  @override
  bool get enableTagsTranslation => true;
}

class NhentaiHomePageData {
  final List<NhentaiComicBrief> popular;
  List<NhentaiComicBrief> latest;
  int page = 1;

  NhentaiHomePageData(this.popular, this.latest);
}

/// nhentai 画廊详情领域对象。
///
/// 历史接入：照 PicaKeep 现有 eh/picacg 范式直接定义 [historyType] / [target]
/// getter（PicaKeep 已移除上游的 HistoryMixin 抽象，不再 with mixin）。
/// [token] 为 CSRF token，详情页 HTML 现抓，收藏/取消收藏时传给平台接口。
class NhentaiComic {
  String id;
  String title;
  String subTitle;
  String cover;
  Map<String, List<String>> tags;
  bool favorite;
  List<String> thumbnails;
  List<NhentaiComicBrief> recommendations;
  String token;

  NhentaiComic(this.id, this.title, this.subTitle, this.cover, this.tags,
      this.favorite, this.thumbnails, this.recommendations, this.token);

  Map<String, dynamic> toMap() => {
        "id": id,
        "title": title,
        "subTitle": subTitle,
        "cover": cover,
      };

  NhentaiComic.fromMap(Map<String, dynamic> map)
      : id = map["id"],
        title = map["title"],
        subTitle = map["subTitle"],
        cover = map["cover"],
        tags = {},
        favorite = false,
        thumbnails = [],
        recommendations = [],
        token = "";

  HistoryType get historyType => HistoryType.nhentai;

  String get target => id;
}

class NhentaiComment {
  String userName;
  String avatar;
  String content;
  int date;

  NhentaiComment(this.userName, this.avatar, this.content, this.date);
}
