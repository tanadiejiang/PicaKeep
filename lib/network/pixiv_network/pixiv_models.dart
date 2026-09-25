import 'package:picakeep/network/base_comic.dart';

// 说明：本文件刻意**不 import Flutter / meta**，只用 `final` 字段 + `const`
// 构造实现不可变语义。原因是 `pixiv_parsing.dart` 会 import 本文件，而解析层
// 必须能在纯 `dart test`（非 flutter_test）下直接跑——一旦这里引入
// `package:flutter/foundation.dart` 的 `@immutable`，整棵 Flutter 依赖树会被
// 拖进来，纯 Dart 运行直接报 `dart:ui` 缺失。`@immutable` 只是注解、无运行期
// 作用，`const` 构造 + `final` 字段已足够表达"不可变"。`package:meta` 虽在
// lock 里但只是传递依赖，直接 import 会触发 depend_on_referenced_packages，
// 且本任务禁止改 pubspec。

/// Pixiv 作品类型：插画（静态图）。
///
/// 该值来自 Web Ajax `/ajax/illust/{id}` 与搜索响应里的 `illustType` 字段，
/// 是 Pixiv 官方的原始枚举，不要在中间层做转换（上层据此区分"静态图/动图"）。
const pixivIllustTypeIllust = 0;

/// Pixiv 作品类型：动图（ugoira）。
///
/// 动图与静态图的取图链路完全不同：静态图走 `/ajax/illust/{id}/pages`，
/// 动图必须走 `/ajax/illust/{id}/ugoira_meta` 拿帧清单 + zip 源，因此该常量
/// 是网络层分流的唯一依据。
const pixivIllustTypeUgoira = 2;

/// Pixiv 列表项（搜索 / 排行榜 / 推荐通用）。
///
/// 字段口径来自 Web Ajax 响应，与 nhentai / picacg 的 brief 保持一致的命名习惯：
/// - [id] 用 `illustId`（兼容部分响应的 `id`）；
/// - [subTitle] 复用 `author`（作者名），与项目其它源的"副标题放作者/语言"惯例对齐；
/// - [cover] 优先用列表自带的 240x480 缩略图 URL，避免列表页二次请求。
/// 不可变：所有字段 `final`，构造为 `const`。
class PixivComicBrief extends BaseComic {
  const PixivComicBrief({
    required this.id,
    required this.title,
    required this.cover,
    required this.author,
    required this.tags,
    required this.illustType,
    required this.pageCount,
  });

  @override
  final String id;

  @override
  final String title;

  /// 作者名（`userName`）。Pixiv 列表项没有独立副标题概念，这里放作者。
  final String author;

  @override
  final String cover;

  @override
  final List<String> tags;

  /// 作品类型，取值见 [pixivIllustTypeIllust] / [pixivIllustTypeUgoira]。
  final int illustType;

  /// 页数；动图作品这里通常是 1，实际帧数以 ugoira_meta 为准。
  final int pageCount;

  @override
  String get subTitle => author;

  /// 列表项不含简介（简介只在详情 `illustComment` 里），因此恒返回空串。
  @override
  String get description => '';
}

/// Pixiv 作品详情（`/ajax/illust/{id}` 的 `body` 对象）。
///
/// 这是普通数据类（不继承 [BaseComic]）：详情页需要的字段远多于列表项，
/// 而且它不是"列表卡片"语义，强行复用 brief 会把展示层字段搅在一起。
/// 不可变：所有字段 `final`，构造为 `const`。
class PixivComicInfo {
  const PixivComicInfo({
    required this.id,
    required this.title,
    required this.author,
    required this.authorId,
    required this.coverUrl,
    required this.tags,
    required this.description,
    required this.pageCount,
    required this.illustType,
    required this.likeCount,
    required this.viewCount,
    required this.width,
    required this.height,
    required this.isOriginal,
    required this.createDate,
    required this.uploadDate,
    required this.userId,
  });

  /// 作品 id（`illustId`，兼容 `id`）。
  final String id;

  /// 作品标题（`illustTitle`，兼容 `title`）。
  final String title;

  /// 作者展示名（`userName`）。
  final String author;

  /// 作者账号/uid（`userId`）。Pixiv 的 `userAccount` 是登录账号名，与 uid
  /// 不是一回事，这里统一取 `userId` 作为稳定标识。
  final String authorId;

  /// 封面原图 URL（`urls.original`，缺失时向后回退到 regular/small/thumb/mini）。
  final String coverUrl;

  /// 作品标签（已做翻译优先 + 去重）。
  final List<String> tags;

  /// 作品简介（已由 `stripPixivHtml` 清洗过 HTML）。
  final String description;

  /// 页数。
  final int pageCount;

  /// 作品类型，取值见 [pixivIllustTypeIllust] / [pixivIllustTypeUgoira]。
  final int illustType;

  /// 收藏数（`likeCount`）。
  final int likeCount;

  /// 浏览数（`viewCount`）。
  final int viewCount;

  /// 原图宽度。
  final int width;

  /// 原图高度。
  final int height;

  /// 是否为原创作品（`isOriginal`）。
  final bool isOriginal;

  /// 创建时间（`createDate`，Pixiv 原样返回的字符串，如 `2024-01-01T00:00:00+09:00`）。
  final String createDate;

  /// 上传时间（`uploadDate`，同上，保持原样字符串不做时区转换）。
  final String uploadDate;

  /// 当前请求用户 id（Pixiv 详情响应里的 `userId`，登录态下为账号 uid）。
  final String userId;
}

/// Pixiv 单页图片的多档 URL（`/ajax/illust/{id}/pages` 的数组元素）。
///
/// Pixiv 为每页同时下发多档尺寸，阅读器按网络质量/缩放档位选择：
/// [thumbMini] 用于列表占位，[small]/[regular] 用于阅读，[original] 用于下载。
/// 不可变：所有字段 `final`，构造为 `const`。
class PixivPage {
  const PixivPage({
    required this.thumbMini,
    required this.small,
    required this.regular,
    required this.original,
    required this.width,
    required this.height,
  });

  /// 最小缩略图（`urls.thumb_mini`）。
  final String thumbMini;

  /// 小图（`urls.small`）。
  final String small;

  /// 常规尺寸图（`urls.regular`）。
  final String regular;

  /// 原图（`urls.original`）。
  final String original;

  /// 该页宽度。
  final int width;

  /// 该页高度。
  final int height;
}

/// Pixiv 动图（ugoira）的**单帧**信息。
///
/// [file] 是帧文件名，需与 [PixivUgoiraMeta.originalSrc]（zip 包）配合使用；
/// [delay] 是该帧的停留时长（毫秒），由 `/ajax/illust/{id}/ugoira_meta` 下发。
/// 不可变：所有字段 `final`，构造为 `const`。
class PixivUgoiraFrame {
  const PixivUgoiraFrame({required this.file, required this.delay});

  /// 帧文件名（zip 包内路径，如 `000000.jpg`）。
  final String file;

  /// 该帧显示时长，单位毫秒。
  final int delay;
}

/// Pixiv 动图（ugoira）元数据（`/ajax/illust/{id}/ugoira_meta` 的 `body`）。
///
/// 动图不能按静态图逐页下载：必须拿 [originalSrc] 的 zip 解包后再按 [frames]
/// 的时序合成，因此该结构单独建模，不与 [PixivPage] 混用。
/// 不可变：所有字段 `final`，构造为 `const`。
class PixivUgoiraMeta {
  const PixivUgoiraMeta({
    required this.frames,
    required this.mimeType,
    required this.originalSrc,
    required this.src,
  });

  /// 帧清单（顺序即播放顺序）。
  final List<PixivUgoiraFrame> frames;

  /// 帧图 MIME 类型（响应字段名是下划线风格的 `mime_type`）。
  final String mimeType;

  /// 原始 zip 包地址（下载动图取这个）。
  final String originalSrc;

  /// 预览用压缩包地址（体积更小，用于快速预览）。
  final String src;
}
