part of 'settings_page.dart';

/// 浏览设置与 Pixiv 作者页共用入口；编辑期间只持有副本，确定才保存。
Future<void> showWaterfallTagSettings(BuildContext context) async {
  final initial = readComicTileDisplaySettings();
  var local = initial.localIllustTags;
  var author = initial.pixivAuthorTags;
  var recommend = initial.recommendTags;
  var favoriteStyle = initial.favoriteStyle;
  var saving = false;
  String? error;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) => AlertDialog(
        title: const Text('瀑布流卡片标签'),
        content: SizedBox(
          width: 380,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                WaterfallTagSettingsEditor(
                  initialLocal: initial.localIllustTags,
                  initialPixivAuthor: initial.pixivAuthorTags,
                  initialRecommend: initial.recommendTags,
                  initialFavoriteStyle: initial.favoriteStyle,
                  onChanged: (nextLocal, nextAuthor) {
                    local = nextLocal;
                    author = nextAuthor;
                  },
                  onRecommendChanged: (tags, style) {
                    recommend = tags;
                    favoriteStyle = style;
                  },
                ),
                if (error != null) Text(error!),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: saving ? null : () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: saving
                ? null
                : () async {
                    setDialogState(() {
                      saving = true;
                      error = null;
                    });
                    try {
                      await saveWaterfallTagDisplaySettings(
                        local: local,
                        pixivAuthor: author,
                        recommend: recommend,
                        favoriteStyle: favoriteStyle,
                      );
                      App.notifyDisplaySettingsChanged();
                      if (dialogContext.mounted) {
                        Navigator.of(dialogContext).pop();
                      }
                    } catch (failure) {
                      if (dialogContext.mounted) {
                        setDialogState(() {
                          saving = false;
                          error = '保存失败：$failure';
                        });
                      }
                    }
                  },
            child: Text(saving ? '正在保存' : '确定'),
          ),
        ],
      ),
    ),
  );
}

/// 受控的初始配置和变化回调，不依赖全局设置或持久化。
class WaterfallTagSettingsEditor extends StatefulWidget {
  const WaterfallTagSettingsEditor({
    super.key,
    required this.initialLocal,
    required this.initialPixivAuthor,
    required this.onChanged,
    this.initialRecommend = WaterfallTagDisplayConfig.recommendDefaults,
    this.initialFavoriteStyle = WaterfallFavoriteStyle.defaults,
    this.onRecommendChanged,
  });

  final WaterfallTagDisplayConfig initialLocal;
  final WaterfallTagDisplayConfig initialPixivAuthor;
  final void Function(WaterfallTagDisplayConfig local,
      WaterfallTagDisplayConfig pixivAuthor) onChanged;
  final WaterfallTagDisplayConfig initialRecommend;
  final WaterfallFavoriteStyle initialFavoriteStyle;
  final void Function(WaterfallTagDisplayConfig recommend,
      WaterfallFavoriteStyle favoriteStyle)? onRecommendChanged;

  @override
  State<WaterfallTagSettingsEditor> createState() =>
      _WaterfallTagSettingsEditorState();
}

class _WaterfallTagSettingsEditorState
    extends State<WaterfallTagSettingsEditor> {
  late WaterfallTagDisplayConfig _local = widget.initialLocal;
  late WaterfallTagDisplayConfig _author = widget.initialPixivAuthor;
  late WaterfallTagDisplayConfig _recommend = widget.initialRecommend;
  late WaterfallFavoriteStyle _favoriteStyle = widget.initialFavoriteStyle;

  void _change(String scope, WaterfallTagDisplayConfig value) {
    setState(() {
      if (scope == waterfallTagLocalKey) {
        _local = value;
      } else if (scope == waterfallTagPixivAuthorKey) {
        _author = value;
      } else {
        _recommend = value;
      }
    });
    widget.onChanged(_local, _author);
    widget.onRecommendChanged?.call(_recommend, _favoriteStyle);
  }

  void _changeFavorite(WaterfallFavoriteStyle style) {
    setState(() => _favoriteStyle = style);
    widget.onRecommendChanged?.call(_recommend, _favoriteStyle);
  }

  Widget _section(
          String title, String scope, WaterfallTagDisplayConfig value) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            key: ValueKey('waterfall-$scope-switch'),
            contentPadding: EdgeInsets.zero,
            title: Text(title),
            subtitle: const Text('显示标签'),
            value: value.showTags,
            onChanged: (enabled) =>
                _change(scope, value.copyWith(showTags: enabled)),
          ),
          const Text('标签显示行数'),
          Wrap(
            spacing: 8,
            children: [
              for (final rows in WaterfallTagDisplayConfig.rowOptions)
                ChoiceChip(
                  key: ValueKey('waterfall-$scope-row-$rows'),
                  label: Text(rows == 0 ? '不限' : '$rows 行'),
                  selected: value.normalizedTagRows == rows,
                  onSelected: (_) =>
                      _change(scope, value.copyWith(tagRows: rows)),
                ),
            ],
          ),
        ],
      );

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _section('本地插画卡片', waterfallTagLocalKey, _local),
          const Divider(),
          _section('Pixiv 作者作品卡片', waterfallTagPixivAuthorKey, _author),
          const Divider(),
          _section('推荐页卡片', waterfallTagRecommendKey, _recommend),
          const Divider(),
          const Text('推荐页平台收藏图标'),
          Wrap(
            spacing: 8,
            children: [
              for (final color in WaterfallFavoriteStyle.colorOptions)
                ChoiceChip(
                  key: ValueKey('waterfall-favorite-color-$color'),
                  avatar: Icon(Icons.favorite,
                      size: 18,
                      color: _favoriteStyle
                          .copyWith(color: color)
                          .favoriteColor(context)),
                  label: Text(color == 'rose' ? '玫红' : '跟随主题'),
                  selected: _favoriteStyle.normalizedColor == color,
                  onSelected: (_) =>
                      _changeFavorite(_favoriteStyle.copyWith(color: color)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          const Text('图标不透明度'),
          Wrap(
            spacing: 8,
            children: [
              for (final opacity in WaterfallFavoriteStyle.opacityOptions)
                ChoiceChip(
                  key: ValueKey('waterfall-favorite-opacity-$opacity'),
                  label: Text('$opacity%'),
                  selected: _favoriteStyle.normalizedOpacity == opacity,
                  onSelected: (_) => _changeFavorite(
                      _favoriteStyle.copyWith(opacity: opacity)),
                ),
            ],
          ),
          const SizedBox(height: 12),
          const Text('有限行数会省略超出的标签，空标签也保留所选行数的空间；'
              '不限时显示全部标签，卡片高度随内容变化。平台收藏按钮仅在支持的来源显示。'),
        ],
      );
}
