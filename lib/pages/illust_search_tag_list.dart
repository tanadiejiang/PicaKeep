import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:picakeep/foundation/local_library_illust_view.dart';

/// A naturally wrapping tag list that only mounts rows in the viewport.
///
/// [tags] already contains the desired order. The chips themselves retain
/// Flutter's normal appearance, interactions, checkmark, and semantics.
/// Custom borders whose dimensions change on focus, hover, or press retain
/// the original scrolling Wrap so those interactions can change the layout.
class IllustSearchTagList extends StatefulWidget {
  const IllustSearchTagList({
    super.key,
    required this.tags,
    required this.selectedTags,
    required this.onToggleTag,
    this.visibleTagLimit,
    this.metricsCache,
    this.maxHeight = 288,
    this.bottomPadding = 30,
  })  : assert(visibleTagLimit == null || visibleTagLimit >= 0),
        assert(maxHeight >= 0),
        assert(bottomPadding >= 0);

  final List<IllustTagSummary> tags;
  final Set<String> selectedTags;
  final ValueChanged<String> onToggleTag;

  /// All candidates remain available for idle measurement. Only this prefix
  /// is displayed; null displays the complete list.
  final int? visibleTagLimit;
  final IllustSearchTagMetricsCache? metricsCache;
  final double maxHeight;
  final double bottomPadding;

  @override
  State<IllustSearchTagList> createState() => _IllustSearchTagListState();
}

const double _tagSpacing = 6;
const double _tagRunSpacing = 2;

typedef _LabelCacheKey = ({
  String label,
  TextStyle style,
  TextScaler scaler,
  Locale? locale,
  TextDirection direction,
  TextHeightBehavior? heightBehavior,
});

/// Bounded, value-only measurements shared across collapsing/reopening panels.
/// No render object, context, or TextPainter is retained in this cache.
class IllustSearchTagMetricsCache {
  IllustSearchTagMetricsCache({this.capacity = 2048}) : assert(capacity > 0);
  final int capacity;
  final LinkedHashMap<_LabelCacheKey, Size> _sizes = LinkedHashMap();
  int _measurementCount = 0;

  @visibleForTesting
  int get measurementCount => _measurementCount;
  @visibleForTesting
  int get entryCount => _sizes.length;

  Size? _read(_LabelCacheKey key) {
    final result = _sizes.remove(key);
    if (result != null) _sizes[key] = result;
    return result;
  }

  void _store(_LabelCacheKey key, Size size) {
    _measurementCount++;
    _sizes.remove(key);
    _sizes[key] = size;
    while (_sizes.length > capacity) {
      _sizes.remove(_sizes.keys.first);
    }
  }
}

final _sharedMetricsCache = IllustSearchTagMetricsCache();

typedef _ChipGeometry = ({
  TextStyle labelStyle,
  TextScaler textScaler,
  Locale? locale,
  TextDirection textDirection,
  TextHeightBehavior? textHeightBehavior,
  EdgeInsets padding,
  EdgeInsets labelPadding,
  EdgeInsets shapeInsets,
  EdgeInsets selectedShapeInsets,
  Offset densityAdjustment,
  MaterialTapTargetSize tapTargetSize,
  bool showCheckmark,
  bool canVirtualize,
});

class _IllustSearchTagListState extends State<IllustSearchTagList> {
  final TextPainter _textPainter = TextPainter(
    textDirection: TextDirection.ltr,
    textAlign: TextAlign.start,
    maxLines: 1,
  );
  List<IllustTagSummary> _candidates = const [];
  List<IllustTagSummary> _tags = const [];
  Set<String> _selectedTags = const {};
  _ChipGeometry? _geometry;
  double? _width;
  List<_TagRow>? _rows;
  Map<Key, int> _rowIndices = const {};
  double _contentHeight = 0;
  final Map<int, _TagRowPlan> _plans = {};
  int _warmupEpoch = 0;
  int _warmupIndex = 0;
  bool _warmupScheduled = false;
  Timer? _warmupTimer;
  IllustSearchTagMetricsCache get _metrics =>
      widget.metricsCache ?? _sharedMetricsCache;

  @override
  void didUpdateWidget(covariant IllustSearchTagList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.metricsCache != widget.metricsCache) _invalidateWarmup();
  }

  @override
  void dispose() {
    _warmupEpoch++;
    _warmupTimer?.cancel();
    _textPainter.dispose();
    super.dispose();
  }

  void _snapshotInputs() {
    final tagsChanged = _candidates.length != widget.tags.length ||
        !Iterable<int>.generate(widget.tags.length).every((index) =>
            _candidates[index].tag == widget.tags[index].tag &&
            _candidates[index].count == widget.tags[index].count);
    final selectedChanged = !setEquals(_selectedTags, widget.selectedTags);
    final count = math.min(
        widget.visibleTagLimit ?? widget.tags.length, widget.tags.length);
    if (!tagsChanged && !selectedChanged && _tags.length == count) {
      return;
    }
    // Both collections can be changed in place by callers.
    if (tagsChanged) _candidates = List.of(widget.tags);
    _tags = _candidates.take(count).toList(growable: false);
    _selectedTags = Set.of(widget.selectedTags);
    if (tagsChanged || selectedChanged) {
      _plans.clear();
      _invalidateWarmup();
    }
    _rows = null;
  }

  _ChipGeometry _resolveGeometry(BuildContext context) {
    final theme = Theme.of(context);
    final chipTheme = ChipTheme.of(context);
    final mediaQuery = MediaQuery.of(context);
    final textScaler = mediaQuery.textScaler;
    final textDirection = Directionality.of(context);
    final defaultLabelStyle = theme.useMaterial3
        ? theme.textTheme.labelLarge!
        : theme.textTheme.bodyLarge!;
    var labelStyle = chipTheme.labelStyle ?? defaultLabelStyle;

    // RawChip supplies a fresh DefaultTextStyle to its Text label. Match the
    // accessibility adjustments that Text applies after that style resolves.
    if (mediaQuery.boldText) {
      labelStyle =
          labelStyle.merge(const TextStyle(fontWeight: FontWeight.bold));
    }
    labelStyle = labelStyle.merge(TextStyle(
      height: mediaQuery.lineHeightScaleFactorOverride,
      letterSpacing: mediaQuery.letterSpacingOverride,
      wordSpacing: mediaQuery.wordSpacingOverride,
    ));

    // FilterChip's M3 default label padding uses the default label font, even
    // when ChipTheme overrides labelStyle. M2 uses the effective label font.
    final paddingFontSize = (theme.useMaterial3
            ? defaultLabelStyle.fontSize
            : (chipTheme.labelStyle ?? defaultLabelStyle).fontSize) ??
        14;
    final labelPadding = chipTheme.labelPadding ??
        EdgeInsets.lerp(
          const EdgeInsets.symmetric(horizontal: 8),
          const EdgeInsets.symmetric(horizontal: 4),
          (textScaler.scale(paddingFontSize) / 14 - 1).clamp(0.0, 1.0),
        )!;

    EdgeInsets shapeInsets(bool selected,
        [Set<WidgetState> interactions = const {}]) {
      final states = <WidgetState>{
        if (selected) WidgetState.selected,
        ...interactions,
      };
      final side =
          WidgetStateProperty.resolveAs<BorderSide?>(chipTheme.side, states);
      final shape = WidgetStateProperty.resolveAs<OutlinedBorder?>(
              chipTheme.shape, states) ??
          (theme.useMaterial3
              ? const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(8)))
              : const StadiumBorder());
      // RawChip._getShape uses a supplied side, otherwise a nonempty shape
      // side, otherwise the chip default. M3's transparent selected side still
      // has width 1. Ink includes ShapeDecoration.padding = shape.dimensions.
      final resolvedShape = side != null
          ? shape.copyWith(side: side)
          : shape.side != BorderSide.none
              ? shape
              : shape.copyWith(
                  side: theme.useMaterial3 ? const BorderSide() : null);
      return resolvedShape.dimensions.resolve(textDirection);
    }

    final normalInsets = shapeInsets(false);
    final selectedInsets = shapeInsets(true);
    var canVirtualize = true;
    if (chipTheme.side is WidgetStateProperty<BorderSide?> ||
        chipTheme.shape is WidgetStateProperty<OutlinedBorder?>) {
      // A hover/focus/press can occur entirely inside RawChip, without
      // rebuilding this planner. Preserve natural wrapping for custom themes
      // that change layout dimensions during those interactions.
      const interactiveStates = [
        WidgetState.hovered,
        WidgetState.focused,
        WidgetState.pressed,
      ];
      for (var mask = 1; mask < 8 && canVirtualize; mask++) {
        final states = <WidgetState>{
          for (var index = 0; index < interactiveStates.length; index++)
            if (mask & (1 << index) != 0) interactiveStates[index],
        };
        canVirtualize = shapeInsets(false, states) == normalInsets &&
            shapeInsets(true, states) == selectedInsets;
      }
    }

    return (
      labelStyle: labelStyle,
      textScaler: textScaler,
      locale: Localizations.maybeLocaleOf(context),
      textDirection: textDirection,
      textHeightBehavior: DefaultTextHeightBehavior.maybeOf(context),
      padding: (chipTheme.padding ?? EdgeInsets.all(theme.useMaterial3 ? 8 : 4))
          .resolve(textDirection),
      labelPadding: labelPadding.resolve(textDirection),
      shapeInsets: normalInsets,
      selectedShapeInsets: selectedInsets,
      densityAdjustment: theme.visualDensity.baseSizeAdjustment,
      tapTargetSize: theme.materialTapTargetSize,
      showCheckmark: chipTheme.showCheckmark ?? true,
      canVirtualize: canVirtualize,
    );
  }

  _LabelCacheKey _labelKey(String label) => (
        label: label,
        style: _geometry!.labelStyle,
        scaler: _geometry!.textScaler,
        locale: _geometry!.locale,
        direction: _geometry!.textDirection,
        heightBehavior: _geometry!.textHeightBehavior,
      );

  Size _measureLabel(String label) {
    final key = _labelKey(label);
    final cached = _metrics._read(key);
    if (cached != null) return cached;
    _textPainter.text = TextSpan(text: label, style: key.style);
    _textPainter.layout();
    final size = _textPainter.size;
    _metrics._store(key, size);
    return size;
  }

  void _invalidateWarmup() {
    _warmupEpoch++;
    _warmupIndex = 0;
  }

  void _scheduleWarmup() {
    if (_warmupScheduled ||
        _geometry == null ||
        !_geometry!.canVirtualize ||
        _warmupIndex >= math.min(_candidates.length, _metrics.capacity)) {
      return;
    }
    _warmupScheduled = true;
    // Show the requested prefix first. Measuring hidden candidates is optional
    // idle work and never mounts widgets or schedules a new paint frame.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scheduleIdleBatch();
    });
  }

  void _scheduleIdleBatch() {
    final epoch = _warmupEpoch;
    _warmupTimer = Timer(const Duration(milliseconds: 8), () {
      if (!mounted) return;
      if (!_geometry!.canVirtualize) {
        _warmupScheduled = false;
        return;
      }
      final scheduler = SchedulerBinding.instance;
      if (scheduler.transientCallbackCount > 0 ||
          scheduler.hasScheduledFrame ||
          scheduler.schedulerPhase != SchedulerPhase.idle) {
        // Do not put low-priority tasks in the scheduler's retrying task queue
        // while a fling/animation is active. Wait without requesting a frame.
        _warmupTimer =
            Timer(const Duration(milliseconds: 80), _scheduleIdleBatch);
        return;
      }
      _warmupScheduled = false;
      if (epoch != _warmupEpoch) {
        if (_geometry!.canVirtualize &&
            _warmupIndex < math.min(_candidates.length, _metrics.capacity)) {
          _warmupScheduled = true;
          _scheduleIdleBatch();
        }
        return;
      }
      final clock = Stopwatch()..start();
      var measured = 0;
      final limit = math.min(_candidates.length, _metrics.capacity);
      while (_warmupIndex < limit &&
          measured < 4 &&
          clock.elapsedMicroseconds < 800) {
        final tag = _candidates[_warmupIndex++];
        final label = '${tag.tag} · ${tag.count}';
        if (_metrics._read(_labelKey(label)) != null) continue;
        _measureLabel(label);
        measured++;
      }
      if (_warmupIndex < limit) {
        _warmupScheduled = true;
        _scheduleIdleBatch();
      }
    });
  }

  Widget _buildChip(IllustTagSummary tag) => FilterChip(
        key: ValueKey('illust-search-tag-${tag.tag}'),
        label: Text('${tag.tag} · ${tag.count}'),
        selected: _selectedTags.contains(tag.tag),
        onSelected: (_) => widget.onToggleTag(tag.tag),
      );

  Size _chipSize(IllustTagSummary tag, double availableWidth) {
    final geometry = _geometry!;
    final selected = _selectedTags.contains(tag.tag);
    final shapeInsets =
        selected ? geometry.selectedShapeInsets : geometry.shapeInsets;
    final contentWidth = math.max(0.0, availableWidth - shapeInsets.horizontal);
    final labelSize = _measureLabel('${tag.tag} · ${tag.count}');

    // These are RawChip._computeSizes and _layoutAvatar's dimensions for a
    // text-only FilterChip, including the selected checkmark drawer. There is
    // no avatar/delete widget; their theme constraints cannot change its size.
    final contentSize = math.max(
      32 - geometry.padding.vertical + geometry.labelPadding.vertical,
      labelSize.height + geometry.labelPadding.vertical,
    );
    final checkmarkWidth =
        geometry.showCheckmark && selected ? contentSize : 0.0;
    final horizontalInsets =
        geometry.padding.horizontal + geometry.labelPadding.horizontal;
    final labelWidth = math.min(labelSize.width,
        math.max(0.0, contentWidth - checkmarkWidth - horizontalInsets));
    final paddedWidth =
        math.min(contentWidth, checkmarkWidth + labelWidth + horizontalInsets) +
            shapeInsets.horizontal;
    final paddedHeight = contentSize +
        geometry.densityAdjustment.dy / 2 +
        geometry.padding.vertical +
        shapeInsets.vertical;
    final paddedTapTarget =
        geometry.tapTargetSize == MaterialTapTargetSize.padded;
    return Size(
      math.min(
          availableWidth,
          math.max(paddedWidth,
              paddedTapTarget ? 48 + geometry.densityAdjustment.dx : 0)),
      math.max(paddedHeight,
          paddedTapTarget ? 48 + geometry.densityAdjustment.dy : 0),
    );
  }

  void _planRows(double width) {
    if (_width != width) _plans.clear();
    final cached = _plans[_tags.length];
    if (cached != null) {
      _rows = cached.rows;
      _rowIndices = cached.indices;
      _contentHeight = cached.height;
      _width = width;
      return;
    }
    final rows = <_TagRow>[];
    var chips = <_PlannedTag>[];
    var rowWidth = 0.0;
    var rowHeight = 0.0;

    void finishRow() {
      if (chips.isEmpty) {
        return;
      }
      rows.add(_TagRow(chips: chips, height: rowHeight));
      chips = [];
      rowWidth = 0;
      rowHeight = 0;
    }

    for (var index = 0; index < _tags.length; index++) {
      final tag = _tags[index];
      final size = _chipSize(tag, width);
      final nextWidth =
          rowWidth + (chips.isEmpty ? 0 : _tagSpacing) + size.width;
      if (chips.isNotEmpty && nextWidth - width > precisionErrorTolerance) {
        finishRow();
      }
      rowWidth += (chips.isEmpty ? 0 : _tagSpacing) + size.width;
      rowHeight = math.max(rowHeight, size.height);
      chips.add(_PlannedTag(tag: tag, index: index, width: size.width));
    }
    finishRow();

    _rows = rows;
    _width = width;
    _rowIndices = {
      for (var index = 0; index < rows.length; index++) rows[index].key: index,
    };
    _contentHeight = rows.fold<double>(0, (sum, row) => sum + row.height) +
        math.max(0, rows.length - 1) * _tagRunSpacing;
    if (_plans.length >= 2) _plans.remove(_plans.keys.first);
    _plans[_tags.length] = _TagRowPlan(rows, _rowIndices, _contentHeight);
  }

  @override
  Widget build(BuildContext context) {
    _snapshotInputs();
    final geometry = _resolveGeometry(context);
    if (_geometry != geometry) {
      _geometry = geometry;
      _plans.clear();
      _invalidateWarmup();
      _rows = null;
      _textPainter
        ..textScaler = geometry.textScaler
        ..locale = geometry.locale
        ..textDirection = geometry.textDirection
        ..textHeightBehavior = geometry.textHeightBehavior;
    }

    if (!geometry.canVirtualize) {
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: widget.maxHeight),
        child: SingleChildScrollView(
          key: const Key('illust-search-tag-scroll'),
          primary: false,
          padding: EdgeInsets.only(bottom: widget.bottomPadding),
          child: RepaintBoundary(
            child: Wrap(
              spacing: _tagSpacing,
              runSpacing: _tagRunSpacing,
              children: [
                for (var index = 0; index < _tags.length; index++)
                  IndexedSemantics(
                    key: ValueKey('illust-search-tag-slot-${_tags[index].tag}'),
                    index: index,
                    child: _buildChip(_tags[index]),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    return LayoutBuilder(builder: (context, constraints) {
      // A horizontal Wrap previously also required a bounded width. Preserve
      // that contract instead of guessing a device-specific wrapping width.
      assert(constraints.hasBoundedWidth);
      final width = constraints.maxWidth;
      if (_rows == null || _width != width) {
        _planRows(width);
      }
      _scheduleWarmup();
      final rows = _rows!;
      if (rows.isEmpty) {
        return const SizedBox(height: 0, width: double.infinity);
      }
      final height =
          math.min(widget.maxHeight, _contentHeight + widget.bottomPadding);
      return SizedBox(
        height: height,
        child: ListView.custom(
          key: const Key('illust-search-tag-scroll'),
          primary: false,
          cacheExtent: 0,
          padding: EdgeInsets.only(bottom: widget.bottomPadding),
          semanticChildCount: _tags.length,
          itemExtentBuilder: (index, dimensions) => index < rows.length
              ? rows[index].height +
                  (index < rows.length - 1 ? _tagRunSpacing : 0)
              : null,
          // ListView.builder restricts semanticChildCount to the row count.
          // The custom delegate allows one semantic index per actual tag.
          childrenDelegate: SliverChildBuilderDelegate(
            (context, index) {
              final row = rows[index];
              return Padding(
                key: row.key,
                padding: EdgeInsets.only(
                    bottom: index < rows.length - 1 ? _tagRunSpacing : 0),
                child: Wrap(
                  spacing: _tagSpacing,
                  children: [
                    for (final chip in row.chips)
                      IndexedSemantics(
                        key: ValueKey('illust-search-tag-slot-${chip.tag.tag}'),
                        index: chip.index,
                        child: SizedBox(
                          // Reserve the final natural width during the
                          // checkmark animation, keeping this planned row
                          // bounded while the real chip animates inside it.
                          width: chip.width,
                          child: _buildChip(chip.tag),
                        ),
                      ),
                  ],
                ),
              );
            },
            childCount: rows.length,
            findChildIndexCallback: (key) => _rowIndices[key],
            // Keep an active keyboard focus or ink response alive using the
            // chip's own request; ordinary offscreen rows are still recycled.
            addSemanticIndexes: false,
          ),
        ),
      );
    });
  }
}

class _TagRowPlan {
  const _TagRowPlan(this.rows, this.indices, this.height);
  final List<_TagRow> rows;
  final Map<Key, int> indices;
  final double height;
}

class _PlannedTag {
  const _PlannedTag({
    required this.tag,
    required this.index,
    required this.width,
  });

  final IllustTagSummary tag;
  final int index;
  final double width;
}

class _TagRow {
  const _TagRow({required this.chips, required this.height});

  final List<_PlannedTag> chips;
  final double height;

  Key get key => ValueKey('illust-search-tag-row-${chips.first.tag.tag}');
}
