import 'dart:async';
import 'dart:ui' as ui;
import 'dart:typed_data' show Uint8List;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

abstract class BaseImageProvider<T extends BaseImageProvider<T>>
    extends ImageProvider<T> {
  const BaseImageProvider();

  @override
  ImageStreamCompleter loadImage(T key, ImageDecoderCallback decode) {
    final chunkEvents = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: _loadBufferAsync(key, chunkEvents, decode),
      chunkEvents: chunkEvents.stream,
      scale: 1.0,
    );
  }

  Future<ui.Codec> _loadBufferAsync(
    T key,
    StreamController<ImageChunkEvent> chunkEvents,
    ImageDecoderCallback decode,
  ) async {
    try {
      Uint8List? data;
      final cacheKey = key.key;
      // cacheRawBytes=false 的子类（如已有磁盘缓存的远程封面）不进这个静态堆
      // 字节缓存：原始压缩字节在堆上驻留是滚动时老年代 GC 的主要压力源，
      // 而它们本就有磁盘缓存兜底，无需再在堆里缓一份。
      if (cacheRawBytes) {
        final cachedData = _cache[cacheKey];
        if (cachedData != null && cachedData.isNotEmpty) {
          data = cachedData;
        } else {
          if (cachedData != null) {
            _cache.remove(cacheKey);
          }
          data = await load(chunkEvents);
          if (data.isEmpty) {
            throw Exception('Empty image data');
          }
          _checkCacheSize();
          _cache[cacheKey] = data;
          _cacheSize += data.length;
        }
      } else {
        data = await load(chunkEvents);
        if (data.isEmpty) {
          throw Exception('Empty image data');
        }
      }
      if (data.isEmpty) {
        if (cacheRawBytes) {
          _cache.remove(cacheKey);
        }
        throw Exception('Empty image data');
      }
      final buffer = await ui.ImmutableBuffer.fromUint8List(data);
      // 子类可通过 targetDecodeWidth 指定按宽缩放解码（如封面缩略图），
      // 避免把原图全尺寸解码——既省解码耗时（滚动时 UI isolate 上的解码
      // 回调是卡顿主因），也省内存。默认 null 时行为不变。
      final targetWidth = targetDecodeWidth;
      if (targetWidth != null && targetWidth > 0) {
        return await decode(
          buffer,
          getTargetSize: (intrinsicWidth, intrinsicHeight) {
            if (intrinsicWidth <= targetWidth) {
              return ui.TargetImageSize(
                width: intrinsicWidth,
                height: intrinsicHeight,
              );
            }
            final scaledHeight =
                (intrinsicHeight * targetWidth / intrinsicWidth).round();
            return ui.TargetImageSize(
              width: targetWidth,
              height: scaledHeight < 1 ? 1 : scaledHeight,
            );
          },
        );
      }
      return await decode(buffer);
    } catch (e) {
      scheduleMicrotask(() {
        PaintingBinding.instance.imageCache.evict(key);
      });
      rethrow;
    } finally {
      chunkEvents.close();
    }
  }

  static final _cache = <String, Uint8List>{};

  static var _cacheSize = 0;

  static var _cacheSizeLimit = 50 * 1024 * 1024;

  static void _checkCacheSize() {
    while (_cacheSize > _cacheSizeLimit && _cache.isNotEmpty) {
      final firstKey = _cache.keys.first;
      _cacheSize -= _cache[firstKey]!.length;
      _cache.remove(firstKey);
    }
  }

  static void evictKey(String key) {
    final data = _cache.remove(key);
    if (data == null) {
      return;
    }
    _cacheSize -= data.length;
    if (_cacheSize < 0) {
      _cacheSize = 0;
    }
  }

  static void clearCache() {
    _cache.clear();
    _cacheSize = 0;
  }

  static void setCacheSizeLimit(int size) {
    _cacheSizeLimit = size;
    _checkCacheSize();
  }

  Future<Uint8List> load(StreamController<ImageChunkEvent> chunkEvents);

  String get key;

  /// 子类可重写以指定按此宽度（像素）缩放解码，用于缩略图/封面降低解码与内存开销。
  /// 返回 null（默认）则按原图尺寸解码，保持既有行为。
  int? get targetDecodeWidth => null;

  /// 是否把原始压缩字节缓存进静态堆缓存（默认 true，保持既有行为）。
  /// 已有磁盘缓存的子类（如远程封面）应返回 false，避免字节在堆上驻留
  /// 造成老年代 GC 压力。
  bool get cacheRawBytes => true;

  @override
  bool operator ==(Object other) {
    return other is BaseImageProvider<T> && key == other.key;
  }

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => '$runtimeType($key)';
}
