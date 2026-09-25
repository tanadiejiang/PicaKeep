/// Komiic GraphQL 请求体构造函数（**纯 Dart，零 Flutter 依赖**）。
///
/// Komiic 只有**单一 POST 端点** `https://komiic.com/api/query`：所有查询与
/// mutation 都是同一个端点、同一套 `{operationName, variables, query}` 信封，
/// 只是 `operationName` / `query` / `variables` 不同。因此这里把每个 operation
/// 各收敛成一个返回请求体的顶层函数，网络层负责发送与鉴权，互不掺杂。
///
/// 本文件不 import Flutter，任何 `dart test` 都能直接调用断言请求体形状。
library;

/// 漫画实体字段串（**与站点 schema 逐字一致，勿改字段名或顺序性内容**）。
///
/// 抽成常量拼接进各 query：列表类、搜索类、按 id 取详情都必须请求同一组字段，
/// 否则会出现"首页有分类、搜索页没分类"这类难以追的口径漂移。
const String komiicComicFields = ' id title status year imageUrl'
    ' authors { id name __typename }'
    ' categories { id name __typename }'
    ' dateUpdated monthViews views favoriteCount'
    ' lastBookUpdate lastChapterUpdate __typename ';

/// 分页变量构造：Komiic 的 pagination 是**偏移量**而非页码。
///
/// `offset = (page - 1) * limit`；`page` 从 1 开始。`orderBy` / `status` / `asc`
/// 直接下发枚举字符串，站点自行校验，这里不做本地合法性判断（避免把新枚举挡住）。
Map<String, dynamic> komiicPagination({
  required int page,
  int limit = 20,
  String orderBy = 'DATE_UPDATED',
  String status = '',
  bool asc = true,
}) =>
    <String, dynamic>{
      'limit': limit,
      'offset': (page - 1) * limit,
      'orderBy': orderBy,
      'status': status,
      'asc': asc,
    };

/// 通用漫画列表 query 构造（`recentUpdate` / `hotComics` 结构完全相同）。
///
/// 两个 operation 的 query 文本结构一致，只有名称不同，故共用一份模板。
Map<String, dynamic> _comicListQuery(
  String operationName, {
  required int page,
  int limit = 20,
  String orderBy = 'DATE_UPDATED',
  String status = '',
  bool asc = true,
}) =>
    <String, dynamic>{
      'operationName': operationName,
      'variables': <String, dynamic>{
        'pagination': komiicPagination(
          page: page,
          limit: limit,
          orderBy: orderBy,
          status: status,
          asc: asc,
        ),
      },
      'query': 'query $operationName(\$pagination: Pagination!) {'
          ' $operationName(pagination: \$pagination) {$komiicComicFields}'
          ' }',
    };

/// 最新更新列表。
Map<String, dynamic> recentUpdateQuery({required int page, int limit = 20}) =>
    _comicListQuery('recentUpdate', page: page, limit: limit);

/// 热门列表。
Map<String, dynamic> hotComicsQuery({required int page, int limit = 20}) =>
    _comicListQuery('hotComics', page: page, limit: limit);

/// 按分类取漫画；`categoryId` 传空数组表示"全部分类"。
Map<String, dynamic> comicByCategoriesQuery({
  required List<String> categoryId,
  required int page,
  int limit = 20,
  String orderBy = 'DATE_UPDATED',
  String status = '',
  bool asc = true,
}) =>
    <String, dynamic>{
      'operationName': 'comicByCategories',
      'variables': <String, dynamic>{
        'categoryId': categoryId,
        'pagination': komiicPagination(
          page: page,
          limit: limit,
          orderBy: orderBy,
          status: status,
          asc: asc,
        ),
      },
      'query': 'query comicByCategories(\$categoryId: [ID!]!, '
          '\$pagination: Pagination!) {'
          ' comicByCategories(categoryId: \$categoryId, '
          'pagination: \$pagination) {$komiicComicFields}'
          ' }',
    };

/// 关键词搜索漫画 + 作者。
///
/// **关键：本站 searchComicsAndAuthors 不接受分页参数**，只传 `keyword`；
/// 分页只能靠"返回条数 == limit"在外层判停（见网络层 subData 协议）。
Map<String, dynamic> searchComicAndAuthorQuery({required String keyword}) =>
    <String, dynamic>{
      'operationName': 'searchComicAndAuthorQuery',
      'variables': <String, dynamic>{'keyword': keyword},
      'query': 'query searchComicAndAuthorQuery(\$keyword: String!) {'
          ' searchComicsAndAuthors(keyword: \$keyword) {'
          ' comics {$komiicComicFields}'
          ' authors {'
          ' id'
          ' name'
          ' chName'
          ' enName'
          ' wikiLink'
          ' comicCount'
          ' views'
          ' __typename'
          ' }'
          ' __typename'
          ' }'
          ' }',
    };

/// 按 id 批量取漫画（详情、推荐补全、收藏夹补全都走这里）。
Map<String, dynamic> comicByIdsQuery({required List<String> comicIds}) =>
    <String, dynamic>{
      'operationName': 'comicByIds',
      'variables': <String, dynamic>{'comicIds': comicIds},
      'query': 'query comicByIds(\$comicIds: [ID]!) {'
          ' comicByIds(comicIds: \$comicIds) {$komiicComicFields}'
          ' }',
    };

/// 单本漫画的推荐 id 列表（**返回的是 ID 字符串数组，不含漫画字段**）。
Map<String, dynamic> recommendComicByIdQuery({required String comicId}) =>
    <String, dynamic>{
      'operationName': 'recommendComicById',
      'variables': <String, dynamic>{'comicId': comicId},
      'query': 'query recommendComicById(\$comicId: ID!) {'
          ' recommendComicById(comicId: \$comicId)'
          ' }',
    };

/// 某本漫画的章节列表。
Map<String, dynamic> chapterByComicIdQuery({required String comicId}) =>
    <String, dynamic>{
      'operationName': 'chapterByComicId',
      'variables': <String, dynamic>{'comicId': comicId},
      'query': 'query chapterByComicId(\$comicId: ID!) {'
          ' chaptersByComicId(comicId: \$comicId) {'
          ' id'
          ' serial'
          ' type'
          ' dateCreated'
          ' dateUpdated'
          ' size'
          ' __typename'
          ' }'
          ' }',
    };

/// 某章节的图片列表（只取 kid/高宽，URL 由解析层拼）。
Map<String, dynamic> imagesByChapterIdQuery({required String chapterId}) =>
    <String, dynamic>{
      'operationName': 'imagesByChapterId',
      'variables': <String, dynamic>{'chapterId': chapterId},
      'query': 'query imagesByChapterId(\$chapterId: ID!) {'
          ' imagesByChapterId(chapterId: \$chapterId) {'
          ' id'
          ' kid'
          ' height'
          ' width'
          ' __typename'
          ' }'
          ' }',
    };

/// 当前账号的收藏夹列表（无变量）。
Map<String, dynamic> myFolderQuery() => <String, dynamic>{
      'operationName': 'myFolder',
      'variables': <String, dynamic>{},
      'query': 'query myFolder {'
          ' folders {'
          ' id'
          ' key'
          ' name'
          ' views'
          ' comicCount'
          ' dateCreated'
          ' dateUpdated'
          ' __typename'
          ' }'
          ' }',
    };

/// 某本漫画落在哪些收藏夹里（返回 folder id 字符串数组）。
Map<String, dynamic> comicInAccountFoldersQuery({required String comicId}) =>
    <String, dynamic>{
      'operationName': 'comicInAccountFolders',
      'variables': <String, dynamic>{'comicId': comicId},
      'query': 'query comicInAccountFolders(\$comicId: ID!) {'
          ' comicInAccountFolders(comicId: \$comicId)'
          ' }',
    };

/// 收藏夹内的漫画 id 分页（**返回 id 列表，漫画本体另走 comicByIds**）。
Map<String, dynamic> folderComicIdsQuery({
  required String folderId,
  required int page,
  int limit = 20,
  String orderBy = 'DATE_UPDATED',
  String status = '',
  bool asc = true,
}) =>
    <String, dynamic>{
      'operationName': 'folderComicIds',
      'variables': <String, dynamic>{
        'folderId': folderId,
        'pagination': komiicPagination(
          page: page,
          limit: limit,
          orderBy: orderBy,
          status: status,
          asc: asc,
        ),
      },
      'query':
          'query folderComicIds(\$folderId: ID!, \$pagination: Pagination!) {'
              ' folderComicIds(folderId: \$folderId, pagination: \$pagination) {'
              ' folderId'
              ' key'
              ' comicIds'
              ' __typename'
              ' }'
              ' }',
    };

/// 把漫画加入收藏夹。
Map<String, dynamic> addComicToFolderMutation({
  required String comicId,
  required String folderId,
}) =>
    <String, dynamic>{
      'operationName': 'addComicToFolder',
      'variables': <String, dynamic>{
        'comicId': comicId,
        'folderId': folderId,
      },
      'query': 'mutation addComicToFolder(\$comicId: ID!, \$folderId: ID!) {'
          ' addComicToFolder(comicId: \$comicId, folderId: \$folderId)'
          ' }',
    };

/// 把漫画移出收藏夹。
Map<String, dynamic> removeComicToFolderMutation({
  required String comicId,
  required String folderId,
}) =>
    <String, dynamic>{
      'operationName': 'removeComicToFolder',
      'variables': <String, dynamic>{
        'comicId': comicId,
        'folderId': folderId,
      },
      'query': 'mutation removeComicToFolder(\$comicId: ID!, \$folderId: ID!) {'
          ' removeComicToFolder(comicId: \$comicId, folderId: \$folderId)'
          ' }',
    };
