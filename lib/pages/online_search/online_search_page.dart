import 'package:flutter/material.dart';

import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/pages/accounts/account_page_route.dart';
import 'package:picakeep/tools/tags_translation.dart'
    show
        tagTranslations,
        tagTranslateCategory,
        tagNamespacesForChineseCategory,
        loadTagTranslations;

import 'online_search_logic.dart';
import 'online_search_result_page.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  辅助类型 & 纯函数
// ─────────────────────────────────────────────────────────────────────────────

/// 标签建议条目。
typedef _TagSug = ({String namespace, String key, String cn});

/// 从已加载的 [tagTranslations] 中按输入词段 [word] 匹配最多 200 条建议。
///
/// 支持三类输入：
/// - 英文 key 前缀/末词匹配：`wi` → `witch`
/// - 中文译名包含匹配：`女巫` → `witch`
/// - 中文分类名展开：`作者/画师/女性/标签` → 对应 namespace 下的英文 key
List<_TagSug> _findTagSuggestions(String word) {
  if (word.isEmpty) return const [];
  final lower = word.toLowerCase();
  final result = <_TagSug>[];

  void addNamespace(String namespace) {
    final map = tagTranslations[namespace];
    if (map == null) return;
    for (final tag in map.entries) {
      if (result.length >= 200) break;
      result.add((namespace: namespace, key: tag.key, cn: tag.value));
    }
  }

  // 输入“作者/画师/女性/标签”等中文分类名时，直接展开相关 namespace。
  final namespaces = tagNamespacesForChineseCategory(word);
  for (final namespace in namespaces) {
    addNamespace(namespace);
    if (result.length >= 200) break;
  }
  if (result.isNotEmpty) return result;

  for (final ns in tagTranslations.entries) {
    for (final tag in ns.value.entries) {
      if (result.length >= 200) break;
      final key = tag.key;
      final cn = tag.value;
      final keyLower = key.toLowerCase();
      final lastWord =
          keyLower.contains(' ') ? keyLower.split(' ').last : keyLower;
      if (keyLower.startsWith(lower) ||
          lastWord.startsWith(lower) ||
          cn.toLowerCase().contains(lower)) {
        result.add((namespace: ns.key, key: key, cn: cn));
      }
    }
    if (result.length >= 200) break;
  }
  return result;
}

/// 剥离已知字母前缀（jm / nh / nhentai 等）→ 纯数字 id。
String _stripIdPrefix(String text) {
  final m = RegExp(r'^[a-zA-Z]*(\d+)$').firstMatch(text);
  return m?.group(1) ?? text;
}

// ─────────────────────────────────────────────────────────────────────────────
//  OnlineSearchPage
// ─────────────────────────────────────────────────────────────────────────────

class OnlineSearchPage extends StatefulWidget {
  const OnlineSearchPage({super.key});

  @override
  State<OnlineSearchPage> createState() => _OnlineSearchPageState();
}

class _OnlineSearchPageState extends State<OnlineSearchPage> {
  final _logic = OnlineSearchLogic();
  final _keywordController = TextEditingController();

  ComicSource? _source;
  String _option = '';
  List<_TagSug> _suggestions = [];
  bool _tagsReady = false; // tags 是否已加载完毕

  @override
  void initState() {
    super.initState();
    final sources = _logic.loggedInSearchableSources;
    if (sources.isNotEmpty) {
      _source = sources.first;
      _option = _source!.searchPageData!.defaultOption;
    }
    _keywordController.addListener(_onKeywordChanged);
    // tags 懒加载；加载完毕后触发一次 setState，确保后续输入能命中数据
    loadTagTranslations().then((_) {
      if (mounted) setState(() => _tagsReady = true);
    });
  }

  @override
  void dispose() {
    _keywordController.removeListener(_onKeywordChanged);
    _keywordController.dispose();
    super.dispose();
  }

  void _onKeywordChanged() {
    final text = _keywordController.text;
    final enableSugg = _source?.searchPageData?.enableTagsSuggestions == true;
    if (!enableSugg || !_tagsReady || text.isEmpty || text.endsWith(' ')) {
      if (_suggestions.isNotEmpty) setState(() => _suggestions = []);
      return;
    }
    final last = text.split(' ').last;
    if (last.isEmpty) {
      if (_suggestions.isNotEmpty) setState(() => _suggestions = []);
      return;
    }
    setState(() => _suggestions = _findTagSuggestions(last));
  }

  void _search() {
    final source = _source;
    final keyword = _keywordController.text.trim();
    if (source == null || keyword.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请选择目标源并输入关键词')),
      );
      return;
    }
    _logic.addSearchHistory(keyword);
    setState(() => _suggestions = []);
    Navigator.of(context).push(
      AppPageRoute(
        builder: (_) => OnlineSearchResultPage(
          source: source,
          keyword: keyword,
          option: _option,
        ),
      ),
    );
  }

  void _changeSource(ComicSource source) {
    setState(() {
      _source = source;
      _option = source.searchPageData!.defaultOption;
      _suggestions = [];
    });
  }

  /// 点击建议条目：把搜索框最后一个词段替换为 `namespace:key `（末尾加空格）。
  void _onSuggestionTap(_TagSug sug) {
    final parts = _keywordController.text.split(' ');
    // EH 源：写 namespace:key 格式；NH/其他：只写 key（不带 namespace 前缀）。
    final isEh = _source?.key == 'ehentai';
    final replacement = isEh
        ? '${sug.namespace}:${sug.key.replaceAll(' ', '_')} '
        : '${sug.key} ';
    parts[parts.length - 1] = replacement;
    final newText = parts.join(' ');
    _keywordController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newText.length),
    );
    // 末尾是空格，_onKeywordChanged 会自动清空建议列表。
  }

  Future<void> _openAccounts() async {
    await showAccountsPage(context);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final sources = _logic.searchableSources;
    final loggedInSources = _logic.loggedInSearchableSources;

    // 源失效兜底
    if (_source == null && loggedInSources.isNotEmpty) {
      _source = loggedInSources.first;
      _option = _source!.searchPageData!.defaultOption;
    } else if (_source != null &&
        !loggedInSources.any((s) => s.key == _source!.key)) {
      _source = loggedInSources.isEmpty ? null : loggedInSources.first;
      _option = _source?.searchPageData?.defaultOption ?? '';
    }

    final showSuggestions = _suggestions.isNotEmpty &&
        _keywordController.text.isNotEmpty &&
        !_keywordController.text.endsWith(' ');

    return Scaffold(
      appBar: AppBar(title: const Text('在线搜索')),
      body: sources.isEmpty
          ? const Center(child: Text('暂无可搜索的在线源'))
          : loggedInSources.isEmpty
              ? _NoLoggedInSourceView(onOpenAccounts: _openAccounts)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // ── 搜索框区（始终可见）──
                    _SearchBarSection(
                      keywordController: _keywordController,
                      onSearch: _search,
                    ),
                    // ── 内容区（建议列表 OR 配置内容）──
                    Expanded(
                      child: showSuggestions
                          ? _SuggestionListView(
                              suggestions: _suggestions,
                              onTap: _onSuggestionTap,
                              onClose: () => setState(() => _suggestions = []),
                            )
                          : _SearchConfigContent(
                              source: _source,
                              option: _option,
                              loggedInSources: loggedInSources,
                              history: _logic.searchHistory,
                              keywordController: _keywordController,
                              onChangeSource: _changeSource,
                              onChangeOption: (v) =>
                                  setState(() => _option = v),
                              onClearHistory: () =>
                                  setState(_logic.clearSearchHistory),
                              onOpenAccounts: _openAccounts,
                              onSelectHistory: (kw) {
                                _keywordController.text = kw;
                                _search();
                              },
                            ),
                    ),
                  ],
                ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  _SearchBarSection — 始终可见的搜索框 + ID 直跳提示
// ─────────────────────────────────────────────────────────────────────────────

class _SearchBarSection extends StatelessWidget {
  const _SearchBarSection({
    required this.keywordController,
    required this.onSearch,
  });

  final TextEditingController keywordController;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 胶囊搜索框
          Container(
            height: 52,
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(26),
            ),
            child: TextField(
              controller: keywordController,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => onSearch(),
              decoration: InputDecoration(
                hintText: '关键词',
                prefixIcon: const Icon(Icons.search),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.travel_explore),
                  onPressed: onSearch,
                  tooltip: '搜索',
                ),
              ),
            ),
          ),
          // ID 直跳提示（ComicSource.idMatcher 统一检测）
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: keywordController,
            builder: (context, value, _) {
              final text = value.text.trim();
              if (text.isEmpty) return const SizedBox.shrink();
              final matches = <({ComicSource source, String cleanId})>[];
              for (final s in ComicSource.sources) {
                if (s.idMatcher?.hasMatch(text) == true &&
                    s.comicPageBuilder != null) {
                  matches.add((source: s, cleanId: _stripIdPrefix(text)));
                }
              }
              if (matches.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final m in matches)
                      ActionChip(
                        avatar: const Icon(Icons.open_in_new, size: 16),
                        label: Text('打开漫画: ${m.source.name}  ${m.cleanId}'),
                        onPressed: () {
                          final page = m.source.comicPageBuilder!(
                            _IdBaseComic(m.cleanId),
                          );
                          Navigator.of(context)
                              .push(AppPageRoute(builder: (_) => page));
                        },
                      ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  _SearchConfigContent — 配置内容区（源/排序/历史）
// ─────────────────────────────────────────────────────────────────────────────

class _SearchConfigContent extends StatelessWidget {
  const _SearchConfigContent({
    required this.source,
    required this.option,
    required this.loggedInSources,
    required this.history,
    required this.keywordController,
    required this.onChangeSource,
    required this.onChangeOption,
    required this.onClearHistory,
    required this.onOpenAccounts,
    required this.onSelectHistory,
  });

  final ComicSource? source;
  final String option;
  final List<ComicSource> loggedInSources;
  final List<String> history;
  final TextEditingController keywordController;
  final ValueChanged<ComicSource> onChangeSource;
  final ValueChanged<String> onChangeOption;
  final VoidCallback onClearHistory;
  final VoidCallback onOpenAccounts;
  final ValueChanged<String> onSelectHistory;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        // ── 目标源 ──
        Row(
          children: [
            Expanded(child: Text('目标', style: textTheme.titleSmall)),
            TextButton.icon(
              onPressed: onOpenAccounts,
              icon: const Icon(Icons.account_circle_outlined, size: 18),
              label: const Text('账号'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final s in loggedInSources) ...[
                ChoiceChip(
                  label: Text(s.name),
                  selected: source?.key == s.key,
                  onSelected: (_) => onChangeSource(s),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),
        const SizedBox(height: 24),

        // ── 排序 ──
        if (source != null &&
            (source!.searchPageData?.searchOptions.isNotEmpty ?? false)) ...[
          Text('排序', style: textTheme.titleSmall),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final opt in source!.searchPageData!.searchOptions) ...[
                  ChoiceChip(
                    label: Text(opt.label),
                    selected: option == opt.value,
                    onSelected: (_) => onChangeOption(opt.value),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],

        // ── 历史搜索 ──
        if (history.isNotEmpty) ...[
          Row(
            children: [
              Expanded(child: Text('历史搜索', style: textTheme.titleSmall)),
              TextButton.icon(
                onPressed: onClearHistory,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('清除'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final kw in history)
                ActionChip(
                  label: Text(kw),
                  onPressed: () => onSelectHistory(kw),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  _SuggestionListView — 建议列表（占内容区，搜索框仍可见）
// ─────────────────────────────────────────────────────────────────────────────

class _SuggestionListView extends StatelessWidget {
  const _SuggestionListView({
    required this.suggestions,
    required this.onTap,
    required this.onClose,
  });

  final List<_TagSug> suggestions;
  final void Function(_TagSug) onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        SizedBox(
          height: 36,
          child: Row(
            children: [
              const SizedBox(width: 20),
              Text('建议',
                  style: Theme.of(context)
                      .textTheme
                      .labelLarge
                      ?.copyWith(color: colorScheme.onSurfaceVariant)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: onClose,
                tooltip: '关闭建议',
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: suggestions.length,
            itemBuilder: (context, index) {
              final sug = suggestions[index];
              return ListTile(
                dense: true,
                title: Text(sug.key),
                subtitle: sug.cn.isNotEmpty && sug.cn != sug.key
                    ? Text(sug.cn,
                        style: TextStyle(
                            fontSize: 12, color: colorScheme.onSurfaceVariant))
                    : null,
                trailing: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(sug.namespace,
                        style: TextStyle(
                            fontSize: 12, color: colorScheme.outline)),
                    Text(tagTranslateCategory(sug.namespace),
                        style: TextStyle(
                            fontSize: 11,
                            color: colorScheme.outline.withValues(alpha: 0.7))),
                  ],
                ),
                onTap: () => onTap(sug),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  _NoLoggedInSourceView
// ─────────────────────────────────────────────────────────────────────────────

class _NoLoggedInSourceView extends StatelessWidget {
  const _NoLoggedInSourceView({required this.onOpenAccounts});

  final VoidCallback onOpenAccounts;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.login, size: 56),
            const SizedBox(height: 12),
            Text('请先登录在线源', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onOpenAccounts,
              icon: const Icon(Icons.account_circle_outlined),
              label: const Text('去登录'),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  _IdBaseComic — idMatcher 直跳用的轻量 BaseComic 适配器
// ─────────────────────────────────────────────────────────────────────────────

/// 仅用于 idMatcher 命中后通过 [ComicSource.comicPageBuilder] 跳转详情页，
/// comicPageBuilder 只读 [id]，其余字段填空即可。
class _IdBaseComic extends BaseComic {
  const _IdBaseComic(this.id);

  @override
  final String id;
  @override
  String get title => '';
  @override
  String get subTitle => '';
  @override
  String get cover => '';
  @override
  List<String> get tags => const [];
  @override
  String get description => '';
}
