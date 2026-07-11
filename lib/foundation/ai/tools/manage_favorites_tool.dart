import 'package:picakeep/foundation/local_favorites.dart';

import '../ai_tool.dart';

class ManageFavoritesTool extends AiTool {
  const ManageFavoritesTool();

  @override
  String get name => 'manage_favorites';

  @override
  String get description =>
      '管理本地收藏夹：查询/创建/删除/重命名收藏夹，向收藏夹添加或移除漫画条目，检查某漫画是否已收藏。';

  @override
  Map<String, Object?> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'action': {
            'type': 'string',
            'enum': [
              'list_folders',
              'create_folder',
              'delete_folder',
              'rename_folder',
              'list_comics',
              'add_comic',
              'remove_comic',
              'check_comic',
            ],
            'description': '操作类型',
          },
          'folder': {
            'type': 'string',
            'description': '收藏夹名称（create/delete/rename/list_comics/add/remove 时使用）',
          },
          'new_folder': {
            'type': 'string',
            'description': '新收藏夹名称（rename_folder 时使用）',
          },
          'comic_id': {
            'type': 'string',
            'description': '漫画 ID（add_comic/remove_comic/check_comic 时使用）',
          },
          'source': {
            'type': 'string',
            'enum': ['picacg', 'jm', 'ehentai', 'nhentai'],
            'description': '漫画来源（add_comic/remove_comic/check_comic 时使用）',
          },
          'title': {
            'type': 'string',
            'description': '漫画标题（add_comic 时使用）',
          },
          'author': {
            'type': 'string',
            'description': '漫画作者（add_comic 时可选）',
          },
          'tags': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': '漫画标签（add_comic 时可选）',
          },
          'cover_url': {
            'type': 'string',
            'description': '封面图 URL（add_comic 时可选）',
          },
        },
        'required': ['action'],
      };

  @override
  Future<AiToolResult> execute(Map<String, dynamic> args) async {
    final action = args['action']?.toString() ?? '';
    final mgr = LocalFavoritesManager();

    switch (action) {
      case 'list_folders':
        final names = mgr.folderNames;
        return AiToolResult.success({
          'folders': names,
          'count': names.length,
        });

      case 'create_folder':
        final folder = _require(args, 'folder');
        if (folder == null) return const AiToolResult.failure('folder is required');
        try {
          mgr.createFolder(folder);
          return AiToolResult.success({'created': folder}, '收藏夹"$folder"已创建');
        } catch (e) {
          return AiToolResult.failure('创建失败: $e');
        }

      case 'delete_folder':
        final folder = _require(args, 'folder');
        if (folder == null) return const AiToolResult.failure('folder is required');
        try {
          mgr.deleteFolder(folder);
          return AiToolResult.success({'deleted': folder}, '收藏夹"$folder"已删除');
        } catch (e) {
          return AiToolResult.failure('删除失败: $e');
        }

      case 'rename_folder':
        final folder = _require(args, 'folder');
        final newFolder = _require(args, 'new_folder');
        if (folder == null || newFolder == null) {
          return const AiToolResult.failure('folder and new_folder are required');
        }
        try {
          mgr.rename(folder, newFolder);
          return AiToolResult.success(
              {'old': folder, 'new': newFolder}, '已重命名为"$newFolder"');
        } catch (e) {
          return AiToolResult.failure('重命名失败: $e');
        }

      case 'list_comics':
        final folder = _require(args, 'folder');
        if (folder == null) return const AiToolResult.failure('folder is required');
        final comics = mgr.getAllComics(folder);
        return AiToolResult.success({
          'folder': folder,
          'count': comics.length,
          'comics': comics
              .map((c) => {
                    'id': c.target,
                    'title': c.name,
                    'author': c.author,
                    'source': _sourceNameOf(c.type),
                    'tags': c.tags,
                    'time': c.time,
                  })
              .toList(),
        });

      case 'add_comic':
        final folder = _require(args, 'folder');
        final comicId = _require(args, 'comic_id');
        final source = _require(args, 'source');
        final title = args['title']?.toString() ?? '';
        if (folder == null || comicId == null || source == null) {
          return const AiToolResult.failure('folder, comic_id, source are required');
        }
        final favType = _toFavoriteType(source);
        if (favType == null) {
          return AiToolResult.failure('unsupported source: $source');
        }
        final tags = (args['tags'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const <String>[];
        final item = FavoriteItem(
          target: comicId,
          name: title,
          author: args['author']?.toString() ?? '',
          type: favType,
          tags: tags,
          coverPath: args['cover_url']?.toString() ?? '',
        );
        try {
          mgr.addComic(folder, item);
          return AiToolResult.success(
              {'folder': folder, 'added': comicId}, '"$title"已收藏到"$folder"');
        } catch (e) {
          return AiToolResult.failure('添加失败: $e');
        }

      case 'remove_comic':
        final folder = _require(args, 'folder');
        final comicId = _require(args, 'comic_id');
        final source = _require(args, 'source');
        if (folder == null || comicId == null || source == null) {
          return const AiToolResult.failure('folder, comic_id, source are required');
        }
        final favType = _toFavoriteType(source);
        if (favType == null) {
          return AiToolResult.failure('unsupported source: $source');
        }
        try {
          mgr.deleteComicWithTarget(folder, comicId, favType);
          return AiToolResult.success(
              {'folder': folder, 'removed': comicId}, '已从"$folder"移除');
        } catch (e) {
          return AiToolResult.failure('移除失败: $e');
        }

      case 'check_comic':
        final comicId = _require(args, 'comic_id');
        if (comicId == null) return const AiToolResult.failure('comic_id is required');
        final favorited = mgr.isExist(comicId);
        return AiToolResult.success({
          'comic_id': comicId,
          'favorited': favorited,
        });

      default:
        return AiToolResult.failure('unknown action: $action');
    }
  }

  String? _require(Map<String, dynamic> args, String key) {
    final val = args[key]?.toString().trim();
    return (val == null || val.isEmpty) ? null : val;
  }

  String _sourceNameOf(FavoriteType type) {
    switch (type.key) {
      case 0:
        return 'picacg';
      case 1:
        return 'ehentai';
      case 2:
        return 'jm';
      case 3:
        return 'hitomi';
      case 4:
        return 'htManga';
      case 6:
        return 'nhentai';
      case 7:
        return 'copyManga';
      case 8:
        return 'komiic';
      default:
        return 'unknown(${type.key})';
    }
  }

  FavoriteType? _toFavoriteType(String source) {
    switch (source) {
      case 'picacg':
        return FavoriteType.picacg;
      case 'jm':
        return FavoriteType.jm;
      case 'ehentai':
        return FavoriteType.ehentai;
      case 'nhentai':
        return FavoriteType.nhentai;
      default:
        return null;
    }
  }
}
