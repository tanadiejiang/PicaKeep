/// 探索页面的公共零件：错误视图、登录提示、选项条、屏蔽解析器。
///
/// 抽出来的目的：首页 / 分类页 / 结果页三处需要同一套外观与同一份屏蔽语义，
/// 分散实现会出现"某个页面忘了更新屏蔽词"这类静默不一致。
library;

import 'package:flutter/material.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/explore/explore_models.dart';
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/pages/accounts/account_page_route.dart';
import 'package:picakeep/pages/favorites/local_favorites.dart';
import 'package:picakeep/pages/online_common/online_comic_list_item.dart';
import 'package:picakeep/tools/translations.dart';

/// 通用错误视图。
Widget exploreErrorView({
  required String error,
  required Future<void> Function() onRetry,
}) {
  return Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 40),
          const SizedBox(height: 12),
          Text(error, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => onRetry(),
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ],
      ),
    ),
  );
}

/// 未登录源：说明 + 账号管理入口。**不发送列表请求**。
Widget exploreLoginRequiredView({
  required String sourceName,
  required Future<void> Function() onManageAccounts,
}) {
  return Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.lock_outline, size: 40),
          const SizedBox(height: 12),
          Text('$sourceName 需要登录后才能浏览', textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => onManageAccounts(),
            child: Text('账号管理'.tl),
          ),
        ],
      ),
    ),
  );
}

/// 选项条（榜期 / 排序）。
Widget exploreOptionBar({
  required List<ExploreOption> options,
  required String? selectedId,
  required void Function(String optionId) onSelected,
}) {
  return SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    child: Row(
      children: [
        for (final option in options)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(option.label),
              selected: option.id == selectedId,
              onSelected: (_) => onSelected(option.id),
            ),
          ),
      ],
    ),
  );
}

/// 入口说明条（例如「榜单固定来自表站」）。
Widget exploreHintBar(BuildContext context, String text) {
  return Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodySmall,
    ),
  );
}

/// 打开账号管理容器（await 整个容器关闭）。
Future<void> showExploreAccountsPage(BuildContext context) {
  return showAccountsPage(context);
}

/// 构造探索列表的屏蔽判定器；没有屏蔽词时返回 null（不做过滤）。
///
/// 语义对照原项目 `comic_tile.dart: isBlocked`；翻译只在**启用翻译的源**上参与
/// 匹配，且走已带缓存的 [translateOnlineTag]（不在每次 build 重扫整表）。
ExploreBlockingResolverBuilder? buildExploreBlockingResolver() {
  final keywords = readBlockingKeywords();
  if (keywords.isEmpty) return null;
  return (BaseComic comic) => findBlockingKeyword(
        comic,
        keywords: keywords,
        translateTag: comic.enableTagsTranslation ? translateOnlineTag : null,
      );
}

typedef ExploreBlockingResolverBuilder = String? Function(BaseComic comic);

/// 入口描述：把结构化入口翻译成展示用标题（唯一入口 label 已足够，保留常量便于统一）。
String exploreEntryTitle(ExploreEntry entry) => entry.label;

/// 账号变更后重新读取"源是否可用"。
bool exploreSourceLoggedIn(String sourceKey) =>
    ComicSource.find(sourceKey)?.isLoggedIn ?? false;

/// 当前 App 上下文（探索页统一从 App 取，避免 await 后使用已失效的页面 context）。
BuildContext? exploreGlobalContext() => App.globalContext;
