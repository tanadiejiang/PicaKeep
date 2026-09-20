import 'package:picakeep/comic_source/comic_source.dart';

import 'log.dart';
import 'local_favorites.dart';

/// 单条本地收藏条目的"更新卡片信息"结果。
enum LocalFavoriteUpdateStatus {
  /// 成功写回本地库。
  updated,

  /// 该来源没有按 id 取详情的能力（无网络层 / 未实现），或条目缺少可用 id。
  unsupported,

  /// 网络请求或写回失败。
  failed,
}

/// 一条条目的更新结果，保留 [errorMessage] 以便结果摘要里说清"为什么没更新"。
class LocalFavoriteUpdateResult {
  const LocalFavoriteUpdateResult({
    required this.status,
    this.errorMessage,
  });

  final LocalFavoriteUpdateStatus status;
  final String? errorMessage;
}

/// 整批更新的统计摘要。
class LocalFavoriteUpdateReport {
  const LocalFavoriteUpdateReport({
    required this.total,
    required this.updated,
    required this.unsupported,
    required this.failed,
    required this.cancelled,
    this.firstErrorMessage,
  });

  final int total;
  final int updated;
  final int unsupported;
  final int failed;

  /// 用户中途取消时为 true（已更新的条目保留，剩余条目标记为未处理）。
  final bool cancelled;

  /// 第一条失败原因，供结果提示展示（不逐条罗列，避免提示过长）。
  final String? firstErrorMessage;

  bool get isEmpty => total == 0;
}

/// 四源「来源类型 key → 源 key」映射。
///
/// 只映射有网络层、且实现了 `FavoriteData.loadComicInfo` 的四个源；其余来源
/// （hitomi / htmanga / copymanga / komiic / 自定义源）没有详情能力，归入
/// `unsupported`，不发起任何请求。
String? favoriteSourceKeyForType(int typeKey) {
  switch (typeKey) {
    case 0:
      return 'picacg';
    case 1:
      return 'ehentai';
    case 2:
      return 'jm';
    case 6:
      return 'nhentai';
    default:
      return null;
  }
}

/// 该来源是否支持"更新卡片信息"。
bool supportsFavoriteInfoUpdate(int typeKey) =>
    favoriteSourceKeyForType(typeKey) != null;

/// 清洗要写回本地的标签：去空白、去空项、**过滤纯数字项**、去重（保持原顺序）。
///
/// 纯数字项来自各源接口里的分类 id（JM 列表接口的 `tags` 字段就混着 id），
/// 写进卡片只会显示成一串无意义数字。去重是因为 JM 的 category 与 category_sub
/// 可能是同一个标题（`parseJmListTags` 内部已经去过一次，这里再兜一层，
/// 防止其它源或后续改动引入重复）。
List<String> sanitizeFavoriteTags(Iterable<String> tags) {
  final result = <String>[];
  for (final raw in tags) {
    final tag = raw.trim();
    if (tag.isEmpty) continue;
    if (int.tryParse(tag) != null) continue;
    if (result.contains(tag)) continue;
    result.add(tag);
  }
  return result;
}

/// 逐条更新收藏条目信息（名称 / 作者 / 标签 / 封面）。
///
/// [explicitComics] 为空时更新 [folder] 内的全部条目（操作区入口）；
/// 传入条目列表时只更新这几条（长按多选后的入口）。两种入口共用同一套逻辑。
///
/// 语义与边界：
/// - **串行执行**，每条之间让出事件循环，避免批量请求把界面卡住；
/// - 单条失败只跳过该条，不打断整批；
/// - 标签只在源能给出**列表口径**时写入，否则保留原值（`FavoriteInfoPatch.tags`
///   为 null 即表示"本次没拿到"）；
/// - 取消后已更新的条目保留，剩余条目不再处理；
/// - 全部结束后经 `LocalFavoritesManager` 的文件夹流通知列表重载。
Future<LocalFavoriteUpdateReport> updateLocalFavoritesCardInfo(
  String folder, {
  Iterable<FavoriteItem>? explicitComics,
  void Function(int completed, int total)? onProgress,
  bool Function()? isCancelled,
}) async {
  final manager = LocalFavoritesManager();
  // 取副本：更新过程中会写库，不要让遍历依赖于正在变化的列表。
  final comics = List<FavoriteItem>.of(
    explicitComics ?? manager.getAllComics(folder),
  );
  final total = comics.length;
  var updated = 0;
  var unsupported = 0;
  var failed = 0;
  var cancelled = false;
  String? firstError;
  var completed = 0;

  onProgress?.call(0, total);

  for (final comic in comics) {
    if (isCancelled?.call() ?? false) {
      cancelled = true;
      break;
    }
    final sourceKey = favoriteSourceKeyForType(comic.type.key);
    final loader = sourceKey == null
        ? null
        : ComicSource.find(sourceKey)?.favoriteData?.loadComicInfo;
    if (loader == null) {
      unsupported++;
    } else {
      try {
        final res = await loader(comic.target);
        if (res.error) {
          failed++;
          firstError ??= res.errorMessageWithoutNull;
        } else {
          final patch = res.data;
          if (patch.isEmpty) {
            // 网络成功但没有任何可写字段：不算失败，也不写库（避免空更新）。
            unsupported++;
          } else {
            // 标签清洗为空时传 null（= 保留原值），其余字段照常写入。
            final cleanedTags = patch.tags == null
                ? null
                : sanitizeFavoriteTags(patch.tags!);
            final ok = manager.updateComicInfo(
              folder,
              comic.target,
              comic.type.key,
              name: patch.name,
              author: patch.author,
              tags: (cleanedTags?.isEmpty ?? true) ? null : cleanedTags,
              coverPath: patch.coverPath,
            );
            if (ok) {
              updated++;
            } else {
              failed++;
              firstError ??= '本地记录未找到';
            }
          }
        }
      } catch (e, s) {
        failed++;
        firstError ??= e.toString();
        LogManager.addLog(
          LogLevel.error,
          'LocalFavoriteUpdate',
          'update ${comic.type.key}/${comic.target} failed: $e\n$s',
        );
      }
    }
    completed++;
    onProgress?.call(completed, total);
    // 让出事件循环：批量网络请求期间界面仍能响应取消与重绘。
    await Future<void>.delayed(Duration.zero);
  }

  if (updated > 0) {
    manager.notifyFoldersChanged();
  }

  return LocalFavoriteUpdateReport(
    total: total,
    updated: updated,
    unsupported: unsupported,
    failed: failed,
    cancelled: cancelled,
    firstErrorMessage: firstError,
  );
}

/// 结果摘要文案（供对话框与 SnackBar 共用，保证两处口径一致）。
String buildLocalFavoriteUpdateSummary(LocalFavoriteUpdateReport report) {
  if (report.isEmpty) return '没有需要更新的条目';
  if (report.unsupported == report.total && report.updated == 0) {
    return '这 ${report.total} 条都不支持更新（仅支持 Picacg / 禁漫 / E-Hentai / NHentai）';
  }
  final parts = <String>['已更新 ${report.updated} 条'];
  if (report.unsupported > 0) parts.add('${report.unsupported} 条来源不支持');
  if (report.failed > 0) parts.add('${report.failed} 条更新失败');
  if (report.cancelled) parts.add('已取消，剩余未处理');
  final summary = parts.join('，');
  final firstError = report.firstErrorMessage;
  return firstError == null ? summary : '$summary。原因示例：$firstError';
}
