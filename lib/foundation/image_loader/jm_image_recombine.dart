/// 转换自 https://github.com/tonquer/JMComic-qt/blob/main/src/tools/tool.py
/// 照搬原项目 image_recombine.dart 核心算法，去掉原项目框架依赖。
///
/// 2026-06-28 修复：package:image 的 VP8 lossy WebP 解码器对 jm 图片系统性越界，
/// 改用 Flutter 引擎 ui.instantiateImageCodec 解码（主 isolate），
/// 重排+编码仍在后台 isolate（不卡 UI）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:picakeep/foundation/log.dart';

import 'reader_image_limits.dart';

const String kJmScrambleId = '220980';

/// A terminal source-restoration refusal, not a display quality choice. Neither
/// safeWhole nor resizing the eventual display can repair this condition.
class JmRecombineLimit extends ReaderImageLimit {
  const JmRecombineLimit(
    super.reason, {
    required this.encodedBytes,
    this.width,
    this.height,
    this.estimatedWorkingBytes,
  });

  final int encodedBytes;
  final int? width, height;

  /// A conservative estimate (minimum one pixel before metadata is available).
  /// Null means the arithmetic result exceeds the exact JSON integer range;
  /// never publish a wrapped, truncated or falsely saturated estimate.
  final int? estimatedWorkingBytes;
  int get maximumWorkingBytes => JmRecombineLimits.maximumWorkingBytes;

  @override
  String get message => reason == 'jm-recombine-animation'
      ? '暂不支持对 JM 动态图片重组，无法保持完整动画；原文件未修改。'
      : 'JM 图片重组超出安全内存预算，暂时无法处理此图片；原文件未修改。';
}

/// Pure admission arithmetic; tests need not allocate a budget-sized buffer.
/// Keep both existing limits. The extra encoded copy must fit inside the same
/// 128 MiB work budget, rather than increasing it to admit the previous mistake.
class JmRecombineLimits {
  static const maximumEncodedBytes = 64 << 20;
  static const maximumWorkingBytes = 128 << 20;
  static const _workingBytesPerPixel = 4 * 6;
  static final _maximumExactJsonInteger = BigInt.from(0x1fffffffffffff);

  /// ImmutableBuffer.fromUint8List copies the input. Reject a definitely
  /// impossible job before making that copy, allowing at least one source pixel.
  static int admitEncodedBytes(int encodedBytes) =>
      _admit(encodedBytes, 1, 1, includeDimensions: false);

  /// Called after metadata, but before instantiating/decoding the full codec.
  static int admit(
          {required int encodedBytes,
          required int width,
          required int height}) =>
      _admit(encodedBytes, width, height);

  static int _admit(int encodedBytes, int width, int height,
      {bool includeDimensions = true}) {
    if (encodedBytes < 0 || width <= 0 || height <= 0) {
      throw ArgumentError('JM image byte length and dimensions are invalid');
    }
    // Header dimensions are untrusted. Compute before narrowing so very large
    // products cannot wrap into a small, apparently admissible working set.
    final working = BigInt.from(encodedBytes) * BigInt.two +
        BigInt.from(width) *
            BigInt.from(height) *
            BigInt.from(_workingBytesPerPixel);
    if (encodedBytes > maximumEncodedBytes ||
        working > BigInt.from(maximumWorkingBytes)) {
      throw JmRecombineLimit('jm-recombine-budget',
          encodedBytes: encodedBytes,
          width: includeDimensions ? width : null,
          height: includeDimensions ? height : null,
          estimatedWorkingBytes:
              working <= _maximumExactJsonInteger ? working.toInt() : null);
    }
    // Admission guarantees this conversion is <= 128 MiB on every platform.
    return working.toInt();
  }
}

// ── 分块数算法（零容错，照搬原项目）──────────────────────────────────────

int _getSegmentationNum(String epsId, String scrambleID, String pictureName) {
  final scrambleId = int.parse(scrambleID);
  final epsID = int.parse(epsId);

  if (epsID < scrambleId) return 0;
  if (epsID < 268850) return 10;

  final string = epsID.toString() + pictureName;
  final hash = md5.convert(utf8.encode(string)).toString();
  final charCode = hash.codeUnitAt(hash.length - 1);

  if (epsID > 421926) {
    return (charCode % 8) * 2 + 2;
  } else {
    return (charCode % 10) * 2 + 2;
  }
}

// ── 像素重排（后台 isolate）────────────────────────────────────────────────
// 入参已是解码后的 RGBA 字节（主 isolate 用 ui 引擎解的）。
// 直接在 RGBA 字节层面按行拷贝重排，最后 PNG 无损编码——
// 完全不经过任何有损压缩，像素级精确，彻底消除块拼接横纹。

Future<Uint8List> _segmentationPicture(_RecombineTask data) async {
  final num = _getSegmentationNum(data.epsId, data.scrambleId, data.bookId);

  final width = data.width;
  final height = data.height;
  final src = data.rgbaBytes;
  const channels = 4; // RGBA
  final rowBytes = width * channels;

  // 校验字节数
  if (src.length < height * rowBytes) {
    throw Exception(
        'RGBA byte length ${src.length} < expected ${height * rowBytes} '
        '(${width}x$height)');
  }

  try {
    // 按原算法计算分块：高度切 num 块，余数全部加到最后一块
    // （原项目就是这样分的，不要"优化"成均匀分配——会导致块边界错位）
    final blockSize = (height / num).floor();
    final remainder = height % num;
    final blocks = <({int start, int h})>[];
    var y = 0;
    for (var i = 0; i < num; i++) {
      final h = blockSize + (i == num - 1 ? remainder : 0);
      blocks.add((start: y, h: h));
      y += h;
    }

    // 倒序重排：直接整行字节块拷贝（RGBA 原始数据，无损）
    final dst = Uint8List(height * rowBytes);
    var destY = 0;
    for (var i = blocks.length - 1; i >= 0; i--) {
      final block = blocks[i];
      final srcOffset = block.start * rowBytes;
      final destOffset = destY * rowBytes;
      final lengthBytes = block.h * rowBytes;
      // 一次性整段拷贝（含整数行，像素精确对齐）
      dst.setRange(destOffset, destOffset + lengthBytes,
          src.sublist(srcOffset, srcOffset + lengthBytes));
      destY += block.h;
    }

    // 用重排后的 RGBA 构造图像 → PNG 无损编码
    final desImg = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: dst.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
    return Uint8List.fromList(img.encodePng(desImg));
  } catch (e, stack) {
    throw Exception('Image recombine failed:\n'
        '  epsId: ${data.epsId}\n'
        '  scrambleId: ${data.scrambleId}\n'
        '  pictureName: ${data.bookId}\n'
        '  size: ${width}x$height\n'
        '  num: $num\n'
        '  error: $e\n'
        '  stack: $stack');
  }
}

// ── Isolate 任务数据 ───────────────────────────────────────────────────────

class _RecombineTask {
  _RecombineTask(this.rgbaBytes, this.width, this.height, this.epsId,
      this.scrambleId, this.bookId, this.completer);

  final Uint8List rgbaBytes; // RGBA 字节（主 isolate 用 ui 解码得到）
  final int width;
  final int height;
  final String epsId;
  final String scrambleId;
  final String bookId;
  final Completer<Uint8List>? completer;

  _RecombineTask withoutCompleter() =>
      _RecombineTask(rgbaBytes, width, height, epsId, scrambleId, bookId, null);
}

// ── Isolate 管理 ─────────────────────────────────────────────────────────

class JmRecombine {
  static Isolate? _isolate;
  static ReceivePort? _receivePort;
  static ReceivePort? _errorPort;
  static SendPort? _sendPort;
  static final List<_RecombineTask> _queue = [];
  static _RecombineTask? _current;

  /// 主 isolate 入口：用 Flutter 引擎解码 WebP → 传 RGBA 给后台 isolate 重排
  ///
  /// 返回 (bytes, extension)：
  /// - num<=1（不重组）：直接返回原始字节，扩展名沿用原始（零损失、零重编码）
  /// - num>1（重组）：引擎解码 → 重排 → PNG 无损编码，扩展名 .png
  static Future<({Uint8List bytes, String extension})> recombine(
    Uint8List imgData, {
    required String epsId,
    required String scrambleId,
    required String pictureName,
    String originalExtension = '.webp',
  }) async {
    final num = _getSegmentationNum(epsId, scrambleId, pictureName);
    if (num <= 1) {
      // 不需要重排：直接保存原始字节，零损失、零重编码、零 CPU
      return (bytes: imgData, extension: originalExtension);
    }

    // 需要重排：主 isolate 解码 → 后台 isolate 重排 → PNG 无损
    final decoded = await _decodeToRgba(imgData);
    final completer = Completer<Uint8List>();
    final task = _RecombineTask(decoded.rgba, decoded.width, decoded.height,
        epsId, scrambleId, pictureName, completer);
    _queue.add(task);
    if (_isolate == null && _receivePort == null) {
      _receivePort = ReceivePort();
      await _start();
    }
    _push();
    final bytes = await completer.future;
    return (bytes: bytes, extension: '.png');
  }

  /// 主 isolate：用 ui 引擎解码 WebP → RGBA 字节 + 尺寸
  static Future<({Uint8List rgba, int width, int height})> _decodeToRgba(
      Uint8List webpBytes) async {
    // Recombination has the source raster, readback, destination, isolate copy
    // and encoder workspace alive together. The engine also copies encoded
    // bytes while callers may still retain the input. Admit that copy first.
    JmRecombineLimits.admitEncodedBytes(webpBytes.length);
    final buffer = await ui.ImmutableBuffer.fromUint8List(webpBytes);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final estimatedWorking = JmRecombineLimits.admit(
          encodedBytes: webpBytes.length,
          width: descriptor.width,
          height: descriptor.height);
      codec = await descriptor.instantiateCodec();
      // A single reordered PNG cannot preserve later frames, timing or loops.
      // No-reorder pages return their original bytes before entering this path.
      if (codec.frameCount > 1) {
        throw JmRecombineLimit('jm-recombine-animation',
            encodedBytes: webpBytes.length,
            width: descriptor.width,
            height: descriptor.height,
            estimatedWorkingBytes: estimatedWorking);
      }
      final frame = await codec.getNextFrame();
      image = frame.image;
      // package:image/PNG stores straight RGBA. Passing Flutter's premultiplied
      // rawRgba here would encode already-darkened RGB and multiply alpha again
      // when the resulting PNG is displayed. Keep the row algorithm unchanged.
      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      if (byteData == null) throw StateError('JM pixel readback failed');
      return (
        rgba: byteData.buffer.asUint8List(),
        width: image.width,
        height: image.height
      );
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  static void _push() {
    if (_sendPort != null && _current == null && _queue.isNotEmpty) {
      _current = _queue.removeAt(0);
      _sendPort!.send(_current!.withoutCompleter());
    }
  }

  static Future<void> _start() async {
    _errorPort = ReceivePort();
    _isolate = await Isolate.spawn(
      _run,
      _receivePort!.sendPort,
      onError: _errorPort!.sendPort,
      debugName: 'JmRecombine',
    );
    _listen();
  }

  static void _listen() {
    _receivePort!.listen((message) {
      if (message is SendPort) {
        _sendPort = message;
        _push();
      } else if (message is Uint8List) {
        _current!.completer!.complete(message);
        _current = null;
        _push();
      } else if (message is Exception) {
        _current!.completer!.completeError(message);
        _current = null;
        _push();
      }
    });

    _errorPort!.listen((message) {
      LogManager.addLog(
          LogLevel.error, 'JmRecombine', 'isolate error: $message');
      _handleError();
    });
  }

  static Future<void> _handleError() async {
    _receivePort?.close();
    _errorPort?.close();
    _isolate = null;
    _sendPort = null;
    if (_current != null) {
      _queue.insert(0, _current!);
      _current = null;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (_isolate == null && _receivePort == null) {
      _receivePort = ReceivePort();
      await _start();
    } else {
      _push();
    }
  }

  static void _run(SendPort port) {
    final rp = ReceivePort();
    rp.listen((message) async {
      if (message is _RecombineTask) {
        try {
          final bytes = await _segmentationPicture(message);
          port.send(bytes);
        } catch (e) {
          port.send(Exception(e.toString()));
        }
      }
    });
    port.send(rp.sendPort);
  }
}
