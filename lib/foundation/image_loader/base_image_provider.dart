import 'dart:async';
import 'dart:collection';
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
      if (_cache.containsKey(cacheKey)) {
        data = _cache[cacheKey];
      } else {
        data = await load(chunkEvents);
        _checkCacheSize();
        _cache[cacheKey] = data;
        _cacheSize += data.length;
      }
      if (data == null || data.isEmpty) {
        throw Exception('Empty image data');
      }
      final buffer = await ui.ImmutableBuffer.fromUint8List(data!);
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

  static final _cache = LinkedHashMap<String, Uint8List>();

  static var _cacheSize = 0;

  static var _cacheSizeLimit = 50 * 1024 * 1024;

  static void _checkCacheSize() {
    while (_cacheSize > _cacheSizeLimit && _cache.isNotEmpty) {
      final firstKey = _cache.keys.first;
      _cacheSize -= _cache[firstKey]!.length;
      _cache.remove(firstKey);
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

  @override
  bool operator ==(Object other) {
    return other is BaseImageProvider<T> && key == other.key;
  }

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => '$runtimeType($key)';
}