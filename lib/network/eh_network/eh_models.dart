import 'package:picakeep/foundation/history.dart';
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

/// ehentai 画廊详情领域对象。
///
/// 历史接入：照 PicaKeep 现有 picacg 范式，直接定义 [historyType] / [target] /
/// [cover] getter（PicaKeep 已移除上游的 HistoryMixin 抽象，不再 with mixin）。
class Gallery {
  String title;
  String? subTitle;
  String type;
  String time;
  String uploader;
  double stars;
  String? rating;
  String coverPath;

  /// namespace -> 标签列表。
  Map<String, List<String>> tags;
  List<Comment> comments = [];

  /// API 身份验证信息（运行期由网络层动态回写）。
  ///
  /// 承载 gid / token / apiuid / apikey / showKey / mpvKey / imgKey /
  /// thumbnailKey / archiveDownload 等运行期鉴权状态，
  /// 供图片直链解密（05）与归档下载（07）使用，必须可变。
  Map<String, String>? auth;
  bool favorite;
  String link;
  String maxPage;
  int pageSize;
  List<String> thumbnails;
  String ext;
  int width;

  Gallery(
    this.title,
    this.type,
    this.time,
    this.uploader,
    this.stars,
    this.rating,
    this.coverPath,
    this.tags,
    this.comments,
    this.auth,
    this.favorite,
    this.link,
    this.maxPage,
    this.pageSize,
    this.thumbnails, // 仅旧版 stand-alone 缩略图用，通常为空
    this.ext,
    this.width,
    this.subTitle,
  );

  /// 把 namespace 分桶的 tags 拍平成 `namespace:tag` 列表（供 brief / 翻译用）。
  List<String> _generateTags() {
    var res = <String>[];
    tags.forEach((key, value) {
      for (var element in value) {
        res.add('$key:$element');
      }
    });
    return res;
  }

  EhGalleryBrief toBrief() => EhGalleryBrief(
        title,
        type,
        time,
        uploader,
        coverPath,
        stars,
        link,
        _generateTags(),
      );

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'subTitle': subTitle,
      'type': type,
      'time': time,
      'uploader': uploader,
      'stars': stars,
      'rating': rating,
      'coverPath': coverPath,
      'tags': tags,
      'favorite': favorite,
      'link': link,
      'maxPage': maxPage,
      'pageSize': pageSize,
      'ext': ext,
      'width': width,
      'auth': auth,
    };
  }

  Gallery.fromJson(Map<String, dynamic> json)
      : title = json['title'],
        type = json['type'],
        time = json['time'],
        uploader = json['uploader'],
        subTitle = json['subTitle'],
        stars = (json['stars'] as num).toDouble(),
        rating = json['rating'],
        coverPath = json['coverPath'],
        tags = {},
        favorite = json['favorite'],
        link = json['link'],
        maxPage = json['maxPage'],
        pageSize = json['pageSize'] ?? 20,
        thumbnails = [],
        ext = json['ext'] ?? 'jpg',
        width = json['width'] ?? 100,
        auth =
            json['auth'] == null ? null : Map<String, String>.from(json['auth']),
        comments = [] {
    // 修复上游 bug：原项目此处误用字符串字面量 "key" 作为桶键，
    // 导致所有 namespace 的标签全部塌进单一名为 key 的桶。
    // 这里改用循环变量 key（真实 namespace）正确分桶。
    for (var key in (json['tags'] as Map<String, dynamic>).keys) {
      tags[key] = List<String>.from(json['tags'][key]);
    }
  }

  String get cover => coverPath;

  HistoryType get historyType => HistoryType.ehentai;

  /// 历史 / 收藏匹配用的唯一标识：画廊完整 URL（公共契约）。
  String get target => link;
}

/// 归档下载页信息（供 07 下载器调用，本计划只备好模型与网络方法）。
class ArchiveDownloadInfo {
  final String originSize;
  final String resampleSize;
  final String originCost;
  final String resampleCost;
  final String? cancelUnlockUrl;

  const ArchiveDownloadInfo(
    this.originSize,
    this.resampleSize,
    this.originCost,
    this.resampleCost,
    this.cancelUnlockUrl,
  );
}
