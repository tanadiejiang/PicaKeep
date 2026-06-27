import 'package:flutter/material.dart';

import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/pages/accounts/accounts_page.dart';

import 'online_search_logic.dart';
import 'online_search_result_page.dart';

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

  @override
  void initState() {
    super.initState();
    final sources = _logic.loggedInSearchableSources;
    if (sources.isNotEmpty) {
      _source = sources.first;
      _option = _source!.searchPageData!.defaultOption;
    }
  }

  @override
  void dispose() {
    _keywordController.dispose();
    super.dispose();
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
    });
  }

  Future<void> _openAccounts() async {
    await Navigator.of(context).push(
      AppPageRoute(builder: (_) => const AccountsPage()),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final sources = _logic.searchableSources;
    final loggedInSources = _logic.loggedInSearchableSources;
    if (_source == null && loggedInSources.isNotEmpty) {
      _source = loggedInSources.first;
      _option = _source!.searchPageData!.defaultOption;
    } else if (_source != null &&
        !loggedInSources.any((s) => s.key == _source!.key)) {
      _source = loggedInSources.isEmpty ? null : loggedInSources.first;
      _option = _source?.searchPageData?.defaultOption ?? '';
    }
    return Scaffold(
      appBar: AppBar(title: const Text('在线搜索')),
      body: sources.isEmpty
          ? const Center(child: Text('暂无可搜索的在线源'))
          : loggedInSources.isEmpty
              ? _NoLoggedInSourceView(onOpenAccounts: _openAccounts)
              : _SearchConfigBody(
                  source: _source,
                  option: _option,
                  loggedInSources: loggedInSources,
                  keywordController: _keywordController,
                  history: _logic.searchHistory,
                  onSearch: _search,
                  onChangeSource: _changeSource,
                  onChangeOption: (v) => setState(() => _option = v),
                  onClearHistory: () => setState(_logic.clearSearchHistory),
                  onOpenAccounts: _openAccounts,
                  onSelectHistory: (kw) {
                    _keywordController.text = kw;
                    _search();
                  },
                ),
    );
  }
}

class _SearchConfigBody extends StatelessWidget {
  const _SearchConfigBody({
    required this.source,
    required this.option,
    required this.loggedInSources,
    required this.keywordController,
    required this.history,
    required this.onSearch,
    required this.onChangeSource,
    required this.onChangeOption,
    required this.onClearHistory,
    required this.onOpenAccounts,
    required this.onSelectHistory,
  });

  final ComicSource? source;
  final String option;
  final List<ComicSource> loggedInSources;
  final TextEditingController keywordController;
  final List<String> history;
  final VoidCallback onSearch;
  final ValueChanged<ComicSource> onChangeSource;
  final ValueChanged<String> onChangeOption;
  final VoidCallback onClearHistory;
  final VoidCallback onOpenAccounts;
  final ValueChanged<String> onSelectHistory;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
      children: [
        // ── 胶囊搜索框 ──
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

        const SizedBox(height: 28),

        // ── 目标源 ──
        Row(
          children: [
            Expanded(
              child: Text('目标', style: textTheme.titleSmall),
            ),
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
            Text('请先登录在线源',
                style: Theme.of(context).textTheme.titleMedium),
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
