import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/network/eh_network/eh_brief_models.dart';

// 列表条目 / 分页结果 / HTML 响应 / 分类榜期枚举已拆到纯 Dart 的
// `eh_brief_models.dart`；这里再导出一次，既有 import 点无需改动。
export 'package:picakeep/network/eh_network/eh_brief_models.dart';

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
        auth = json['auth'] == null
            ? null
            : Map<String, String>.from(json['auth']),
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
