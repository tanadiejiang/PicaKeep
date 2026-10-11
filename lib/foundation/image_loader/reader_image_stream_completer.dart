import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';

import 'reader_image_limits.dart';

/// Non-reader users keep Flutter's existing completer. Readers use the same
/// provider codec/scale, but explicitly own in-flight and paused animation work.
ImageStreamCompleter readerAwareImageCompleter({
  required Future<ui.Codec> codec,
  required double scale,
  Stream<ImageChunkEvent>? chunkEvents,
}) =>
    ReaderImageReadLimits.current == null
        ? MultiFrameImageStreamCompleter(
            codec: codec, scale: scale, chunkEvents: chunkEvents)
        : ReaderImageStreamCompleter(
            codec: codec, scale: scale, chunkEvents: chunkEvents);

/// A single-flight full-image codec owner. Unlike re-attaching a listener to a
/// paused SDK MultiFrameImageStreamCompleter, retirement never requests another
/// frame. A late frame is disposed and late errors are consumed, not published.
/// No source resolution, resize, raster policy or native probe happens here.
class ReaderImageStreamCompleter extends ImageStreamCompleter {
  ReaderImageStreamCompleter(
      {required Future<ui.Codec> codec,
      required this.scale,
      Stream<ImageChunkEvent>? chunkEvents}) {
    _chunks = chunkEvents?.listen((event) {
      if (!_retired) reportImageChunkEvent(event);
    }, onError: (Object error, StackTrace stack) => _error(error, stack));
    unawaited(codec.then((value) {
      _codec = value;
      _codecSettled = true;
      if (_retired) {
        _finishRetirement();
      } else {
        _decode();
      }
    }, onError: (Object error, StackTrace stack) {
      _codecSettled = true;
      _error(error, stack);
      _finishRetirement();
    }));
  }

  final double scale;
  final _retirement = Completer<void>();
  Future<void> get retired => _retirement.future;
  ui.Codec? _codec;
  ui.FrameInfo? _next;
  StreamSubscription<ImageChunkEvent>? _chunks;
  Timer? _timer;
  int? _frameCallback;
  Duration? _shown, _duration;
  int _emitted = 0;
  bool _codecSettled = false,
      _decoding = false,
      _retired = false,
      _chunksClosed = false;

  @override
  void addListener(ImageStreamListener listener) {
    super.addListener(listener);
    if (_retired) return;
    if (_next != null) {
      _schedule();
    } else {
      _decode();
    }
  }

  @override
  void removeListener(ImageStreamListener listener) {
    super.removeListener(listener);
    if (!hasListeners) _stopScheduling();
  }

  void _decode() {
    final codec = _codec;
    if (_retired ||
        _decoding ||
        !hasListeners ||
        codec == null ||
        _next != null) {
      return;
    }
    _decoding = true;
    unawaited((() async {
      try {
        final frame = await codec.getNextFrame();
        if (_retired) {
          frame.image.dispose();
          return;
        }
        _next = frame;
        if (codec.frameCount == 1) {
          _emit();
          _disposeCodec();
        } else {
          _schedule();
        }
      } catch (error, stack) {
        _error(error, stack);
      } finally {
        _decoding = false;
        _finishRetirement();
      }
    })());
  }

  void _emit() {
    final frame = _next!;
    _next = null;
    try {
      setImage(ImageInfo(image: frame.image.clone(), scale: scale));
      _emitted++;
    } finally {
      frame.image.dispose();
    }
  }

  void _schedule() {
    if (_retired || !hasListeners || _next == null || _frameCallback != null) {
      return;
    }
    _frameCallback = SchedulerBinding.instance.scheduleFrameCallback(_onFrame);
  }

  void _onFrame(Duration timestamp) {
    _frameCallback = null;
    if (_retired || !hasListeners || _next == null) return;
    if (_shown == null || timestamp - _shown! >= _duration!) {
      _shown = timestamp;
      _duration = _next!.duration;
      _emit();
      final codec = _codec;
      if (_retired || codec == null) return;
      final cycles = _emitted ~/ codec.frameCount;
      if (codec.repetitionCount == -1 || cycles <= codec.repetitionCount) {
        _decode();
      } else {
        _disposeCodec();
      }
    } else {
      final remaining = _duration! - (timestamp - _shown!);
      _timer = Timer(remaining * timeDilation, () {
        _timer = null;
        _schedule();
      });
    }
  }

  void _error(Object error, StackTrace stack) {
    if (_retired) return;
    reportError(
        exception: error,
        stack: stack,
        context: ErrorDescription('while decoding an original reader image'),
        silent: true);
  }

  void _stopScheduling() {
    _timer?.cancel();
    _timer = null;
    final callback = _frameCallback;
    _frameCallback = null;
    if (callback != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(callback);
    }
  }

  void _disposeCodec() {
    final codec = _codec;
    _codec = null;
    codec?.dispose();
  }

  void retire() {
    if (_retired) return;
    _retired = true;
    _stopScheduling();
    _next?.image.dispose();
    _next = null;
    final chunks = _chunks;
    _chunks = null;
    if (chunks == null) {
      _chunksClosed = true;
    } else {
      unawaited(chunks.cancel().then((_) {
        _chunksClosed = true;
        _finishRetirement();
      }, onError: (Object _, StackTrace __) {
        _chunksClosed = true;
        _finishRetirement();
      }));
    }
    _finishRetirement();
  }

  void _finishRetirement() {
    if (!_retired || !_codecSettled || _decoding) return;
    _disposeCodec();
    if (_chunksClosed && !_retirement.isCompleted) _retirement.complete();
  }

  @override
  void onDisposed() {
    retire();
    super.onDisposed();
  }
}
