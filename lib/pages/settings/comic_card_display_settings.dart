// ignore_for_file: avoid_unused_constructor_params, unused_element, no_leading_underscores_for_local_identifiers

part of 'settings_page.dart';

/// 搜索页可配置的源。恒为内置四源：来源是内置源注册表，而不是"当前已加载的
/// 在线源" —— 后者在源未初始化时为空，会让用户进不了配置。
List<ComicSource> get _cardDisplaySearchSources =>
    ComicSource.builtIn.toList(growable: false);

/// 颜色键的中文名。
///
/// 不走 `.tl` 翻译表：这些是**新增键**，翻译表里没有对应条目，`tl` 会原样返回
/// 英文键；颜色名短且固定，直接给出中文更清楚。
String _cardDisplayIdColorTitle(String colorKey) {
  return switch (colorKey) {
    'orange' => '橙色',
    'red' => '红色',
    'pink' => '粉色',
    'purple' => '紫色',
    'blue' => '蓝色',
    'teal' => '青色',
    'green' => '绿色',
    'black' => '黑 / 白',
    'theme' => '跟随主题',
    _ => colorKey,
  };
}

/// 分组之间与分组内部的分隔线。
///
/// 用户反馈：本地收藏与在线收藏两组**没有分隔线，看起来像重复了一遍**。
/// 分组之间用更明显的间距 + 粗一点的线，分组内部用细线，保证"这是两组"一眼可见。
class _CardDisplayDivider extends StatelessWidget {
  const _CardDisplayDivider({this.section = false});

  /// 分组之间的分隔线（比组内的略重）。
  final bool section;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.outlineVariant;
    return Padding(
      padding: EdgeInsets.only(top: section ? 12 : 0),
      child: Divider(
        height: 1,
        thickness: section ? 1.2 : 0.6,
        color: color,
      ),
    );
  }
}

/// 一行「来源标识号颜色」选择：左侧颜色圆点 + 下拉，样式对齐「外观 → 主题色」。
class _CardDisplayIdColorRow extends StatelessWidget {
  const _CardDisplayIdColorRow({
    required this.colorKey,
    required this.onChanged,
  });

  final String colorKey;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return buildResponsiveSettingTile(
      title: Text('来源 id 颜色'.tl),
      trailingWidth: 140,
      trailing: Select(
        // key 绑定当前值：值一变就重建，色点/文字必定跟着更新，不依赖
        // `Select` 内部 `_currentValue` 的同步时机。
        key: ValueKey<String>(colorKey),
        width: 140,
        centerTextWhenPlain: true,
        initialValue: colorKey,
        values: comicTileDisplayIdColorOptions,
        titles: [
          for (final key in comicTileDisplayIdColorOptions)
            _cardDisplayIdColorTitle(key).tl,
        ],
        leadingBuilder: (key) => cardDisplayIdColorDot(context, key),
        tailing: const Icon(Icons.arrow_drop_down),
        onChanged: (value) => onChanged(normalizeComicTileIdColor(value)),
      ),
    );
  }
}

/// 一行「标签行数」选择。
///
/// 保留下拉（2 / 3 / 不限 是三选一，用开关表达不了）；`centerTextWhenPlain`
/// 让框内文字居中，与同页 Switch 的右对齐观感一致。
class _CardDisplayTagRowsRow extends StatelessWidget {
  const _CardDisplayTagRowsRow({
    required this.tagRows,
    required this.onChanged,
  });

  final int tagRows;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return buildResponsiveSettingTile(
      title: Text('标签显示行数'.tl),
      trailingWidth: 140,
      trailing: Select(
        key: ValueKey<String>('rows-$tagRows'),
        width: 140,
        centerTextWhenPlain: true,
        initialValue: '$tagRows',
        values: [
          for (final rows in comicTileDisplayTagRowOptions) '$rows',
        ],
        titles: [
          for (final rows in comicTileDisplayTagRowOptions)
            comicTileDisplayTagRowOptionTitle(rows).tl,
        ],
        onChanged: (value) {
          onChanged(normalizeComicTileTagRows(int.tryParse(value)));
        },
      ),
    );
  }
}

/// 一个布尔开关行。
///
/// 用 [Switch] 而不是"是/否"下拉：只有两个取值，开关更贴合语义，也与「浏览」页
/// 既有开关（显示收藏状态 / 显示阅读位置等 `SwitchSetting`）观感统一。
/// 宽度沿用 `SwitchSetting` 的 60，保证与那些开关左右对齐。
class _CardDisplaySwitchRow extends StatelessWidget {
  const _CardDisplaySwitchRow({
    required this.title,
    required this.subTitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String? subTitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return buildResponsiveSettingTile(
      title: Text(title),
      subtitle: subTitle == null ? null : Text(subTitle!),
      trailingWidth: 60,
      trailing: Switch(
        value: value,
        onChanged: onChanged,
      ),
    );
  }
}

/// 一套卡片的显示项：标签行数 + 显示标签 + 显示来源 id（行间带分隔线）。
class _CardDisplayConfigRows extends StatelessWidget {
  const _CardDisplayConfigRows({
    required this.config,
    required this.onChanged,
  });

  final ComicTileDisplayConfig config;
  final ValueChanged<ComicTileDisplayConfig> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CardDisplayTagRowsRow(
          tagRows: config.tagRows,
          onChanged: (rows) => onChanged(config.copyWith(tagRows: rows)),
        ),
        const _CardDisplayDivider(),
        _CardDisplaySwitchRow(
          title: '显示标签'.tl,
          subTitle: null,
          value: config.showTags,
          onChanged: (value) => onChanged(config.copyWith(showTags: value)),
        ),
        const _CardDisplayDivider(),
        _CardDisplaySwitchRow(
          title: '显示来源 id'.tl,
          subTitle: null,
          value: config.showId,
          onChanged: (value) => onChanged(config.copyWith(showId: value)),
        ),
      ],
    );
  }
}

/// 「设置 → 浏览 → 卡片信息显示」。
///
/// 粒度：本地收藏一套、在线收藏一套（都不区分源），搜索页与探索页**按源切换页签**
/// 各一套（不另开子页 —— 用户明确要求做成"选哪个源就配哪个源"的形态；探索页复用
/// 同一套源配置，因此两处的在线列表卡片观感一致）。改动立即写回
/// settings 索引 150，对应页面下次构建即生效。
class ComicCardDisplaySetting extends StatefulWidget {
  const ComicCardDisplaySetting({super.key});

  @override
  State<ComicCardDisplaySetting> createState() =>
      _ComicCardDisplaySettingState();
}

class _ComicCardDisplaySettingState extends State<ComicCardDisplaySetting>
    with SingleTickerProviderStateMixin {
  late ComicTileDisplaySettings _settings = readComicTileDisplaySettings();
  late final TabController _tabController = TabController(
    length: _cardDisplaySearchSources.length,
    vsync: this,
  );

  @override
  void initState() {
    super.initState();
    // 必须监听：去掉 TabBarView 之后，TabBar 的索引变化**不会**自动重建本页，
    // 不监听就会出现"切了页签但下面还是上一个源的配置"（用户实测）。
    _tabController.addListener(_handleTabChanged);
  }

  void _handleTabChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _tabController.removeListener(_handleTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  void _apply(ComicTileDisplaySettings next) {
    setState(() => _settings = next);
    saveComicTileDisplaySettings(next);
  }

  @override
  Widget build(BuildContext context) {
    final sources = _cardDisplaySearchSources;
    return PopUpWidgetScaffold(
      title: '卡片信息显示'.tl,
      // 整页**一个**滚动视图：源页签的内容直接铺在下面，不再用 TabBarView。
      // TabBarView 会吃掉剩余高度并在内部滚动，导致上面的配置区滚不到底
      // （用户实测：底部设置调不了）。
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                '以下配置只影响卡片的"显示哪些信息"，不改卡片样式；改动即时生效，'
                        '返回对应页面即可看到。标签行数选「不限」时不截断。'
                    .tl,
                style: const TextStyle(fontSize: 12),
              ),
            ),
            const _CardDisplayDivider(section: true),
            _CardDisplayIdColorRow(
              colorKey: _settings.idColor,
              onChanged: (key) => _apply(_settings.withIdColor(key)),
            ),
            const _CardDisplayDivider(section: true),
            SettingsTitle('本地收藏'.tl),
            _CardDisplayConfigRows(
              config: _settings.local,
              onChanged: (config) => _apply(_settings.withLocal(config)),
            ),
            const _CardDisplayDivider(section: true),
            SettingsTitle('在线收藏'.tl),
            _CardDisplayConfigRows(
              config: _settings.online,
              onChanged: (config) => _apply(_settings.withOnline(config)),
            ),
            const _CardDisplayDivider(section: true),
            SettingsTitle('搜索与探索（按源）'.tl),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                '这组配置按源分别保存，共同控制搜索页与探索页的在线列表卡片：'
                        '两个页面都支持切换源，因此每个源单独一套，改一次两处同时生效；'
                        '本地收藏 / 在线收藏等其它页面不受影响。'
                        '「显示来源 id」只对禁漫 / NHentai 有可见效果'
                        '（它们的描述位在无简介时回退为 jm<id> / nhentai<id>）；'
                        '注意搜索结果卡片的标签通常很少（禁漫多为 1~2 个），'
                        '因此下面的「标签显示行数」大多时候不会触发，'
                        '真正需要限行的是收藏条目。'
                    .tl,
                style: const TextStyle(fontSize: 12),
              ),
            ),
            // 源做成页签：选哪个源就是配哪个源，不再进二级子页。
            TabBar(
              controller: _tabController,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                for (final source in sources)
                  Tab(
                    text: source.name,
                    height: 42,
                  ),
              ],
            ),
            // 当前源的配置直接铺在页签下方（随整页滚动）。
            for (var i = 0; i < sources.length; i++)
              if (_tabController.index == i)
                _CardDisplayConfigRows(
                  config: _settings.search(sources[i].key),
                  onChanged: (config) =>
                      _apply(_settings.withSearch(sources[i].key, config)),
                ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
