import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/network/base_comic.dart';

const String defaultPicacgAvatarUrl = 'DEFAULT AVATAR URL';

String picacgImageUrl(Map? media) {
  if (media == null) {
    return '';
  }
  final server = media['fileServer']?.toString() ?? '';
  final path = media['path']?.toString() ?? '';
  if (server.isEmpty || path.isEmpty) {
    return '';
  }
  final base = server.endsWith('/') ? '${server}static/' : '$server/static/';
  return '$base$path';
}

int _intValue(Object? value) {
  if (value is int) {
    return value;
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

List<String> _stringList(Object? value) {
  if (value is List) {
    return value.map((e) => e.toString()).toList(growable: false);
  }
  return const <String>[];
}

class PicacgProfile {
  const PicacgProfile({
    required this.id,
    required this.avatarUrl,
    required this.email,
    required this.exp,
    required this.level,
    required this.name,
    required this.title,
    this.isPunched,
    this.slogan,
    this.frameUrl,
  });

  factory PicacgProfile.fromApi(Map json) {
    return PicacgProfile(
      id: json['_id']?.toString() ?? json['id']?.toString() ?? '',
      avatarUrl: picacgImageUrl(json['avatar'] as Map?),
      email: json['email']?.toString() ?? '',
      exp: _intValue(json['exp']),
      level: _intValue(json['level']),
      name: json['name']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      isPunched: json['isPunched'] as bool?,
      slogan: json['slogan']?.toString(),
      frameUrl: json['character']?.toString(),
    );
  }

  factory PicacgProfile.fromJson(Map json) {
    return PicacgProfile(
      id: json['id']?.toString() ?? '',
      avatarUrl: json['avatarUrl']?.toString() ?? '',
      email: json['email']?.toString() ?? '',
      exp: _intValue(json['exp']),
      level: _intValue(json['level']),
      name: json['name']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      isPunched: json['isPunched'] as bool?,
      slogan: json['slogan']?.toString(),
      frameUrl: json['frameUrl']?.toString(),
    );
  }

  final String id;
  final String avatarUrl;
  final String email;
  final int exp;
  final int level;
  final String name;
  final String title;
  final bool? isPunched;
  final String? slogan;
  final String? frameUrl;

  Map<String, dynamic> toJson() => {
        'id': id,
        'avatarUrl': avatarUrl,
        'email': email,
        'exp': exp,
        'level': level,
        'name': name,
        'title': title,
        'isPunched': isPunched,
        'slogan': slogan,
        'frameUrl': frameUrl,
      };
}

class PicacgComicItemBrief extends BaseComic {
  const PicacgComicItemBrief({
    required this.id,
    required this.title,
    required this.author,
    required this.likes,
    required this.path,
    required this.tags,
    this.pages,
  });

  factory PicacgComicItemBrief.fromApi(Map json) {
    final tags = <String>[
      ..._stringList(json['tags']),
      ..._stringList(json['categories']),
    ];
    return PicacgComicItemBrief(
      id: json['_id']?.toString() ?? '',
      title: json['title']?.toString() ?? 'Unknown',
      author: json['author']?.toString() ?? 'Unknown',
      likes: _intValue(json['likesCount'] ?? json['totalLikes']),
      path: picacgImageUrl(json['thumb'] as Map?),
      tags: tags,
      pages: _intValue(json['pagesCount']),
    );
  }

  @override
  final String id;

  @override
  final String title;

  final String author;
  final int likes;
  final String path;

  @override
  final List<String> tags;

  final int? pages;

  @override
  String get cover => path;

  @override
  String get description {
    final pageText = pages == null || pages == 0 ? '' : ' · $pages 页';
    return '$likes 喜欢$pageText';
  }

  @override
  String get subTitle => author;
}

class PicacgComicItem extends PicacgComicItemBrief {
  const PicacgComicItem({
    required super.id,
    required super.title,
    required super.author,
    required super.likes,
    required super.path,
    required super.tags,
    required this.creator,
    required this.detailDescription,
    required this.chineseTeam,
    required this.categories,
    required this.comments,
    required this.isLiked,
    required this.isFavourite,
    required this.epsCount,
    required this.pagesCount,
    required this.updatedAt,
    required this.eps,
    required this.recommendation,
  }) : super(pages: pagesCount);

  factory PicacgComicItem.fromApi({
    required Map json,
    required List<String> eps,
    required List<PicacgComicItemBrief> recommendation,
  }) {
    final creatorJson = (json['_creator'] as Map?) ?? const <String, dynamic>{};
    return PicacgComicItem(
      id: json['_id']?.toString() ?? '',
      title: json['title']?.toString() ?? 'Unknown',
      detailDescription: json['description']?.toString() ?? '',
      path: picacgImageUrl(json['thumb'] as Map?),
      author: json['author']?.toString() ?? 'Unknown',
      chineseTeam: json['chineseTeam']?.toString() ?? '',
      categories: _stringList(json['categories']),
      tags: _stringList(json['tags']),
      likes: _intValue(json['likesCount']),
      comments: _intValue(json['commentsCount']),
      isFavourite: json['isFavourite'] == true,
      isLiked: json['isLiked'] == true,
      epsCount: _intValue(json['epsCount']),
      pagesCount: _intValue(json['pagesCount']),
      updatedAt: json['updated_at']?.toString() ?? '',
      eps: eps,
      recommendation: recommendation,
      creator: PicacgProfile.fromApi(creatorJson),
    );
  }

  final PicacgProfile creator;
  final String detailDescription;
  final String chineseTeam;
  final List<String> categories;
  final int comments;
  final bool isLiked;
  final bool isFavourite;
  final int epsCount;
  final int pagesCount;
  final String updatedAt;
  final List<String> eps;
  final List<PicacgComicItemBrief> recommendation;

  @override
  String get description => detailDescription;

  HistoryType get historyType => HistoryType.picacg;

  String get target => id;

  PicacgComicItemBrief toBrief() {
    return PicacgComicItemBrief(
      id: id,
      title: title,
      author: author,
      likes: likes,
      path: path,
      tags: tags,
      pages: pagesCount,
    );
  }

  Map<String, dynamic> toQueueJson() => {
        'id': id,
        'title': title,
        'author': author,
        'likes': likes,
        'path': path,
        'tags': tags,
        'description': detailDescription,
        'categories': categories,
        'epsCount': epsCount,
        'pagesCount': pagesCount,
        'eps': eps,
        'updatedAt': updatedAt,
      };

  factory PicacgComicItem.fromQueueJson(Map json) {
    final tags = (json['tags'] as List?)?.map((e) => e.toString()).toList() ??
        const <String>[];
    final categories =
        (json['categories'] as List?)?.map((e) => e.toString()).toList() ??
            const <String>[];
    final eps = (json['eps'] as List?)?.map((e) => e.toString()).toList() ??
        const <String>[];
    return PicacgComicItem(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      author: json['author']?.toString() ?? '',
      likes: _intValue(json['likes']),
      path: json['path']?.toString() ?? '',
      tags: tags,
      creator: const PicacgProfile(
        id: '', avatarUrl: '', email: '', exp: 0, level: 0, name: '', title: '',
      ),
      detailDescription: json['description']?.toString() ?? '',
      chineseTeam: '',
      categories: categories,
      comments: 0,
      isLiked: false,
      isFavourite: false,
      epsCount: _intValue(json['epsCount']),
      pagesCount: _intValue(json['pagesCount']),
      updatedAt: json['updatedAt']?.toString() ?? '',
      eps: eps,
      recommendation: const [],
    );
  }
}

/// Picacg 评论模型。字段照搬原项目 loadMoreCommends 实现。
class PicacgComment {
  PicacgComment({
    required this.commentId,
    required this.name,
    required this.avatarUrl,
    required this.level,
    required this.content,
    required this.replyCount,
    required this.createdAt,
    required this.isLiked,
    required this.likes,
    this.slogan,
  });

  factory PicacgComment.fromApi(Map json) {
    final user = json['_user'] as Map?;
    String avatarUrl = '';
    if (user != null) {
      try {
        final avatar = user['avatar'] as Map?;
        if (avatar != null) {
          avatarUrl = '${avatar['fileServer']}/static/${avatar['path']}';
        }
      } catch (_) {}
    }
    return PicacgComment(
      commentId: json['_id']?.toString() ?? '',
      name: user?['name']?.toString() ?? 'Unknown',
      avatarUrl: avatarUrl,
      level: (user?['level'] as num?)?.toInt() ?? 1,
      content: json['content']?.toString() ?? '',
      replyCount: (json['commentsCount'] as num?)?.toInt() ?? 0,
      createdAt: json['created_at']?.toString() ?? '',
      isLiked: json['isLiked'] == true,
      likes: (json['likesCount'] as num?)?.toInt() ?? 0,
      slogan: user?['slogan']?.toString(),
    );
  }

  final String commentId;
  final String name;
  final String avatarUrl;
  final int level;
  final String content;
  final int replyCount;
  final String createdAt;
  // Non-final: local like-toggle mutates these in UI layer.
  bool isLiked;
  int likes;
  final String? slogan;
}
