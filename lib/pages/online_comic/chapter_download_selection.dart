import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/online_download_manager.dart';
import 'package:picakeep/network/res.dart';

final _openChapterPanels = <String>{};

Future<bool> showOnlineChapterDownloadSelection(
  BuildContext context, {
  required String title,
  required List<String> chapterNames,
  required String sourceKey,
  required List<String> candidateIds,
  required Future<Res<bool>> Function(List<int>) onSubmit,
}) =>
    showChapterDownloadSelection(
      context,
      title: title,
      chapterNames: chapterNames,
      identity: '$sourceKey/${candidateIds.join("|")}',
      loadStatuses: () => OnlineDownloadManager.instance.chapterStatuses(
          sourceKey: sourceKey,
          candidateIds: candidateIds,
          chapterCount: chapterNames.length),
      statusChanges: Listenable.merge(
          [OnlineDownloadManager.instance.version, App.localDataVersion]),
      onSubmit: onSubmit,
    );

Future<bool> showChapterDownloadSelection(
  BuildContext context, {
  required String title,
  required List<String> chapterNames,
  required Future<Map<int, ChapterDownloadStatus>> Function() loadStatuses,
  required Future<Res<bool>> Function(List<int>) onSubmit,
  Listenable? statusChanges,
  String? identity,
}) async {
  if (identity != null && !_openChapterPanels.add(identity)) return false;
  try {
    return await showModalBottomSheet<bool>(
          context: context,
          isScrollControlled: true,
          isDismissible: false,
          enableDrag: false,
          useSafeArea: true,
          builder: (sheetContext) => SizedBox(
            height: MediaQuery.sizeOf(sheetContext).height * .85,
            child: ChapterDownloadSelection(
              title: title,
              chapterNames: chapterNames,
              loadStatuses: loadStatuses,
              statusChanges: statusChanges,
              onSubmit: onSubmit,
              onSuccess: () => Navigator.of(sheetContext).pop(true),
              onCancel: () => Navigator.of(sheetContext).pop(false),
            ),
          ),
        ) ??
        false;
  } finally {
    if (identity != null) _openChapterPanels.remove(identity);
  }
}

String chapterDownloadStatusLabel(ChapterDownloadStatus status) =>
    switch (status) {
      ChapterDownloadStatus.available => '可下载',
      ChapterDownloadStatus.downloaded => '已下载',
      ChapterDownloadStatus.queued => '已排队',
      ChapterDownloadStatus.downloading => '下载中',
      ChapterDownloadStatus.paused => '已暂停',
      ChapterDownloadStatus.failed => '失败待重试',
    };

/// 原始章节索引始终为 0-based；下载和状态读取由宿主注入。
class ChapterDownloadSelection extends StatefulWidget {
  const ChapterDownloadSelection({
    super.key,
    required this.title,
    required this.chapterNames,
    required this.loadStatuses,
    required this.onSubmit,
    required this.onSuccess,
    required this.onCancel,
    this.statusChanges,
  });
  final String title;
  final List<String> chapterNames;
  final Future<Map<int, ChapterDownloadStatus>> Function() loadStatuses;
  final Future<Res<bool>> Function(List<int>) onSubmit;
  final VoidCallback onSuccess;
  final VoidCallback onCancel;
  final Listenable? statusChanges;

  @override
  State<ChapterDownloadSelection> createState() =>
      _ChapterDownloadSelectionState();
}

class _ChapterDownloadSelectionState extends State<ChapterDownloadSelection>
    with SingleTickerProviderStateMixin {
  final _scroll = ScrollController();
  final _gridKey = GlobalKey();
  late final Ticker _ticker;
  Set<int> _selected = {};
  late List<String> _names = List.of(widget.chapterNames);
  Map<int, ChapterDownloadStatus>? _statuses;
  String? _statusError, _submitError;
  bool _loading = true,
      _refreshing = false,
      _refreshAgain = false,
      _submitting = false,
      _completed = false;
  Timer? _refreshTimer;
  int _generation = 0;
  int? _dragAnchor;
  Set<int> _beforeDrag = {};
  bool _dragSelect = true;
  Offset? _pointer;
  Duration _lastTick = Duration.zero;
  int _columns = 1;
  double _cellHeight = 80, _cellWidth = 100;
  static const _padding = 8.0, _gap = 8.0, _edge = 48.0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_autoScroll);
    widget.statusChanges?.addListener(_scheduleRefresh);
    _refresh();
  }

  @override
  void didUpdateWidget(covariant ChapterDownloadSelection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.statusChanges != widget.statusChanges) {
      oldWidget.statusChanges?.removeListener(_scheduleRefresh);
      widget.statusChanges?.addListener(_scheduleRefresh);
    }
    if (!listEquals(_names, widget.chapterNames)) {
      _names = List.of(widget.chapterNames);
      _stopDrag();
      _selected.clear();
      _statuses = null;
      _loading = true;
      _generation++;
      _submitting = false;
      _completed = false;
      _submitError = null;
      _refresh();
    }
  }

  void _scheduleRefresh() {
    // 下载每页都会发版本信号，合并短时间内的更新并串行读取状态。
    _refreshTimer ??= Timer(const Duration(milliseconds: 120), () {
      _refreshTimer = null;
      if (mounted) _refresh();
    });
  }

  Future<void> _refresh() async {
    if (_refreshing) {
      _refreshAgain = true;
      return;
    }
    _refreshing = true;
    final generation = _generation;
    try {
      final states = await widget.loadStatuses();
      if (!mounted || generation != _generation) return;
      setState(() {
        _statuses = Map.of(states);
        _statusError = null;
        _loading = false;
        _selected.removeWhere((i) => !_available(i));
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _statusError = '读取章节状态失败：$error';
          _loading = false;
        });
      }
    } finally {
      _refreshing = false;
      if (_refreshAgain && mounted) {
        _refreshAgain = false;
        _refresh();
      }
    }
  }

  ChapterDownloadStatus _status(int index) =>
      _statuses?[index] ?? ChapterDownloadStatus.available;
  bool _available(int index) =>
      index >= 0 &&
      index < _names.length &&
      _status(index) == ChapterDownloadStatus.available;
  bool get _editable =>
      !_loading &&
      _statusError == null &&
      _statuses != null &&
      !_submitting &&
      !_completed;

  void _toggle(int index) {
    if (!_editable || !_available(index)) return;
    setState(() {
      if (!_selected.add(index)) _selected.remove(index);
      _submitError = null;
    });
  }

  RenderBox? get _gridBox =>
      _gridKey.currentContext?.findRenderObject() as RenderBox?;

  int? _indexAt(Offset global) {
    final box = _gridBox;
    if (box == null || !_scroll.hasClients || box.size.height <= _padding * 2) {
      return null;
    }
    final local = box.globalToLocal(global);
    final x =
        local.dx.clamp(_padding, box.size.width - _padding - .001) - _padding;
    final y = local.dy.clamp(_padding, box.size.height - _padding - .001) -
        _padding +
        _scroll.offset;
    var column =
        (x / (_cellWidth + _gap)).floor().clamp(0, _columns - 1).toInt();
    if (Directionality.of(context) == TextDirection.rtl) {
      column = _columns - 1 - column;
    }
    final row = math.max(0, (y / (_cellHeight + _gap)).floor());
    final index = row * _columns + column;
    return index < _names.length ? index : _names.length - 1;
  }

  void _beginDrag(LongPressStartDetails details) {
    if (!_editable) return;
    final anchor = _indexAt(details.globalPosition);
    if (anchor == null || !_available(anchor)) return;
    _beforeDrag = Set.of(_selected);
    _dragSelect = !_selected.contains(anchor);
    _pointer = details.globalPosition;
    setState(() {
      _dragAnchor = anchor;
    });
    _updateRange(anchor);
    _lastTick = Duration.zero;
    _ticker.start();
  }

  void _moveDrag(LongPressMoveUpdateDetails details) {
    if (_dragAnchor == null) return;
    _pointer = details.globalPosition;
    final index = _indexAt(details.globalPosition);
    if (index != null) _updateRange(index);
  }

  void _updateRange(int endpoint) {
    final anchor = _dragAnchor;
    if (anchor == null || !_editable) return;
    final next = _beforeDrag.where(_available).toSet();
    for (var i = math.min(anchor, endpoint);
        i <= math.max(anchor, endpoint);
        i++) {
      if (!_available(i)) continue;
      if (_dragSelect) {
        next.add(i);
      } else {
        next.remove(i);
      }
    }
    if (!setEquals(next, _selected)) {
      setState(() {
        _selected = next;
        _submitError = null;
      });
    }
  }

  void _autoScroll(Duration elapsed) {
    final delta =
        (elapsed - _lastTick).inMicroseconds / Duration.microsecondsPerSecond;
    _lastTick = elapsed;
    final box = _gridBox, pointer = _pointer;
    if (box == null || pointer == null || !_scroll.hasClients || !_editable) {
      return;
    }
    final y = box.globalToLocal(pointer).dy;
    final edge = math.min(_edge, box.size.height / 3);
    final fraction = y < edge
        ? -((edge - y) / edge).clamp(0.0, 1.0)
        : y > box.size.height - edge
            ? ((y - box.size.height + edge) / edge).clamp(0.0, 1.0)
            : 0.0;
    if (fraction == 0) return;
    final target = (_scroll.offset + fraction * 600 * delta)
        .clamp(
            _scroll.position.minScrollExtent, _scroll.position.maxScrollExtent)
        .toDouble();
    if (target != _scroll.offset) {
      _scroll.jumpTo(target);
      final index = _indexAt(pointer);
      if (index != null) _updateRange(index);
    }
  }

  void _stopDrag() {
    _ticker.stop();
    _pointer = null;
    if (_dragAnchor != null) {
      if (mounted) {
        setState(() {
          _dragAnchor = null;
        });
      } else {
        _dragAnchor = null;
      }
    }
  }

  Future<void> _submit() async {
    if (!_editable || _selected.isEmpty) return;
    _stopDrag();
    final indexes = _selected.where(_available).toList()..sort();
    if (indexes.isEmpty) return;
    final generation = _generation;
    setState(() {
      _submitting = true;
      _submitError = null;
    });
    try {
      final result = await widget.onSubmit(indexes);
      if (!mounted || generation != _generation) return;
      if (result.error || result.data != true) {
        setState(() {
          _submitError =
              result.error ? result.errorMessageWithoutNull : '未加入下载队列';
        });
      } else {
        setState(() {
          _submitting = false;
          _completed = true;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && generation == _generation) widget.onSuccess();
        });
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _submitError = '加入下载队列失败：$error';
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _submitting = false;
        });
      }
    }
  }

  Widget _chapter(int index) {
    final enabled = _editable && _available(index);
    final selected = _selected.contains(index);
    final status = _status(index);
    final colors = Theme.of(context).colorScheme;
    final name = _names[index];
    return Semantics(
      key: ValueKey('chapter-download-$index'),
      container: true,
      button: true,
      enabled: enabled,
      selected: selected,
      label:
          '第${index + 1}章，$name，${chapterDownloadStatusLabel(status)}${selected ? "，已选择" : ""}',
      onTap: enabled ? () => _toggle(index) : null,
      child: ExcludeSemantics(
          child: Material(
        color:
            selected ? colors.primaryContainer : colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          excludeFromSemantics: true,
          borderRadius: BorderRadius.circular(12),
          onTap: enabled ? () => _toggle(index) : null,
          child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                      child: Text(name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14, height: 1.2))),
                  Row(children: [
                    Icon(
                        selected
                            ? Icons.check_circle
                            : status == ChapterDownloadStatus.downloaded
                                ? Icons.download_done
                                : enabled
                                    ? Icons.radio_button_unchecked
                                    : Icons.schedule,
                        size: 16),
                    const SizedBox(width: 4),
                    Expanded(
                        child: Text(chapterDownloadStatusLabel(status),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11, height: 1.2))),
                  ]),
                ],
              )),
        ),
      )),
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !_submitting,
      child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('选择下载章节 · ${widget.title}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium),
                  Text('共 ${_names.length} 章，已选 ${_selected.length} 章',
                      key: const Key('chapter-download-count')),
                  const Text('点选章节；长按后滑动连续选择或取消。暂停、失败请到下载任务页恢复。',
                      style: TextStyle(fontSize: 11)),
                  Wrap(spacing: 4, children: [
                    TextButton(
                        onPressed: _editable
                            ? () => setState(() {
                                  _selected = {
                                    for (var i = 0; i < _names.length; i++)
                                      if (_available(i)) i
                                  };
                                })
                            : null,
                        child: const Text('全选可下载')),
                    TextButton(
                        onPressed: _editable
                            ? () => setState(() {
                                  _selected = {
                                    for (var i = 0; i < _names.length; i++)
                                      if (_available(i) &&
                                          !_selected.contains(i))
                                        i
                                  };
                                })
                            : null,
                        child: const Text('反选')),
                    TextButton(
                        onPressed:
                            _editable ? () => setState(_selected.clear) : null,
                        child: const Text('清空')),
                  ]),
                  if (_statusError != null) ...[
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 96),
                      child: SingleChildScrollView(
                          child: Text(_statusError!,
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.error))),
                    ),
                    TextButton(
                        onPressed: _refreshing ? null : _refresh,
                        child: const Text('重试读取状态')),
                  ],
                  if (_submitError != null)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 64),
                      child: SingleChildScrollView(
                          child: Text(_submitError!,
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.error))),
                    ),
                  Expanded(
                      child: _loading
                          ? const Center(child: CircularProgressIndicator())
                          : _statusError != null
                              ? const Center(child: Text('读取成功后才能选择章节'))
                              : LayoutBuilder(
                                  builder: (context, constraints) {
                                    _columns = math.max(
                                        1,
                                        ((constraints.maxWidth - _padding * 2) /
                                                300)
                                            .ceil());
                                    _cellWidth = (constraints.maxWidth -
                                            _padding * 2 -
                                            (_columns - 1) * _gap) /
                                        _columns;
                                    final scaler =
                                        MediaQuery.textScalerOf(context);
                                    _cellHeight = scaler.scale(14) * 1.2 * 2 +
                                        math.max(16, scaler.scale(11) * 1.2) +
                                        20;
                                    return GestureDetector(
                                      key: _gridKey,
                                      behavior: HitTestBehavior.opaque,
                                      excludeFromSemantics: true,
                                      onLongPressStart: _beginDrag,
                                      onLongPressMoveUpdate: _moveDrag,
                                      onLongPressEnd: (_) => _stopDrag(),
                                      onLongPressCancel: _stopDrag,
                                      child: GridView.builder(
                                        key: const Key('chapter-download-grid'),
                                        controller: _scroll,
                                        physics: _dragAnchor == null
                                            ? null
                                            : const NeverScrollableScrollPhysics(),
                                        padding: const EdgeInsets.all(_padding),
                                        gridDelegate:
                                            SliverGridDelegateWithFixedCrossAxisCount(
                                                crossAxisCount: _columns,
                                                mainAxisExtent: _cellHeight,
                                                mainAxisSpacing: _gap,
                                                crossAxisSpacing: _gap),
                                        itemCount: _names.length,
                                        itemBuilder: (_, index) =>
                                            _chapter(index),
                                      ),
                                    );
                                  },
                                )),
                  Row(children: [
                    Expanded(
                        child: OutlinedButton(
                            onPressed: _submitting ? null : widget.onCancel,
                            child: Text(_completed ? '关闭' : '取消'))),
                    const SizedBox(width: 8),
                    Expanded(
                        child: FilledButton(
                            onPressed: _editable && _selected.isNotEmpty
                                ? _submit
                                : null,
                            child: Text(_completed
                                ? '已加入队列'
                                : _submitting
                                    ? '正在加入队列'
                                    : '下载所选（${_selected.length}）'))),
                  ]),
                ]),
          )));

  @override
  void dispose() {
    _generation++;
    widget.statusChanges?.removeListener(_scheduleRefresh);
    _refreshTimer?.cancel();
    _ticker.dispose();
    _scroll.dispose();
    super.dispose();
  }
}
