/// 从**图片文件头**读出像素宽高 —— 不解码像素、不分配 `width × height × 4` 的位图。
///
/// ## 为什么单独成文件、且必须是纯函数
///
/// 图集页的「插画」瀑布流需要每张图的真实宽高才能按真实比例排版。老下载记录里
/// 没有宽高（见 32 号计划的诊断 1，真机实测三条 Pixiv 记录全部缺 `width`/`height`），
/// 只能退到"读图片自己的尺寸"。
///
/// **读尺寸绝不能变成解码整图**：瀑布流一屏可能同时处理 10~20 张图，若每张都
/// `instantiateImageCodec` + `getNextFrame`，几百张就是几百次全图解码，
/// 老年代会当场炸掉。这里的做法是**只解析文件头里的尺寸字段**：
///
/// - PNG：`IHDR` 里的 width/height（固定偏移，零扫描）；
/// - JPEG：扫到第一个 `SOF0~SOF15`（**不是** `DHT`/`DAC`/`JPG`）段读宽高，
///   扫到 `SOS` 就停 —— 熵编码数据在 `SOS` 之后，永远不需要碰；
/// - WebP：`VP8 `（有损）/ `VP8L`（无损）/ `VP8X`（扩展容器）三种块头；
/// - GIF：逻辑屏幕描述符（顺手支持，成本三行）。
///
/// 纯函数（无 IO、无 Flutter 依赖）才能被直接单元测试 —— 尺寸解析的每个分支都是
/// 位运算与偏移，靠肉眼看代码是验不出来的。
///
/// ## 调用方约定
///
/// 调用方负责把文件**前若干字节**读进来（见 `illust_cover_size.dart` 的有界读），
/// 并在解析失败时按"尺寸未知"降级。本函数只在字节**足够且自洽**时返回结果，
/// 否则返回 `null` —— 不抛异常：瀑布流里一条坏图不该让整页崩掉。
library;

import 'dart:typed_data';

/// 图片像素尺寸。恒为正数（[parseImageHeaderSize] 已过滤非正数与明显异常值）。
class ImageHeaderSize {
  const ImageHeaderSize(this.width, this.height);

  final int width;
  final int height;

  double get aspectRatio => width / height;

  @override
  String toString() => 'ImageHeaderSize($width x $height)';

  @override
  bool operator ==(Object other) =>
      other is ImageHeaderSize &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(width, height);
}

/// 宽高的**合理上限**。
///
/// 用来把"偏移算错、读到了别的字节"和"真是一张巨图"区分开：Pixiv 原图最长边
/// 也就 1 万像素级别，0x3FFF（16383）是各格式自身的字段上限，这里再留一档余量。
/// 超过就认为这次解析不可信，返回 `null` 让调用方走占位比例 —— 宁可退化成占位，
/// 也不要拿一个错到离谱的比例把瀑布流撑坏。
const int _maxSaneDimension = 65535;

/// 解析图片头 → 尺寸。认不出来返回 `null`。
ImageHeaderSize? parseImageHeaderSize(Uint8List bytes) {
  if (bytes.length < 10) {
    return null;
  }
  return _parsePng(bytes) ??
      _parseGif(bytes) ??
      _parseWebp(bytes) ??
      _parseJpeg(bytes);
}

ImageHeaderSize? _checked(int? width, int? height) {
  if (width == null || height == null) {
    return null;
  }
  if (width <= 0 || height <= 0) {
    return null;
  }
  if (width > _maxSaneDimension || height > _maxSaneDimension) {
    return null;
  }
  return ImageHeaderSize(width, height);
}

bool _startsWith(Uint8List bytes, int offset, List<int> signature) {
  if (offset + signature.length > bytes.length) {
    return false;
  }
  for (var i = 0; i < signature.length; i++) {
    if (bytes[offset + i] != signature[i]) {
      return false;
    }
  }
  return true;
}

int _be16(Uint8List bytes, int offset) =>
    (bytes[offset] << 8) | bytes[offset + 1];

int _le16(Uint8List bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);

int _le24(Uint8List bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16);

int _be32(Uint8List bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

int _le32(Uint8List bytes, int offset) =>
    bytes[offset] |
    (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24);

const List<int> _pngSignature = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A,
  0x0A];

/// PNG：8 字节签名 + `IHDR` 块。
///
/// `IHDR` **必须**是第一个块（PNG 规范强制），所以宽高恒在固定偏移：
/// 16..20 = 宽（大端），20..24 = 高（大端）。不需要扫描块链表。
ImageHeaderSize? _parsePng(Uint8List bytes) {
  if (!_startsWith(bytes, 0, _pngSignature)) {
    return null;
  }
  if (bytes.length < 24) {
    return null;
  }
  // 块类型必须是 IHDR：否则这不是一张正常的 PNG（或字节被截断/错位）。
  if (!_startsWith(bytes, 12, const <int>[0x49, 0x48, 0x44, 0x52])) {
    return null;
  }
  return _checked(_be32(bytes, 16), _be32(bytes, 20));
}

/// GIF：`GIF87a` / `GIF89a` + 逻辑屏幕宽高（小端 16 位）。
ImageHeaderSize? _parseGif(Uint8List bytes) {
  final isGif = _startsWith(bytes, 0, const <int>[0x47, 0x49, 0x46, 0x38]) &&
      (bytes[4] == 0x37 || bytes[4] == 0x39) &&
      bytes[5] == 0x61;
  if (!isGif) {
    return null;
  }
  return _checked(_le16(bytes, 6), _le16(bytes, 8));
}

/// WebP：`RIFF` 容器 + `VP8 `/`VP8L`/`VP8X` 三种块。
///
/// 三种块的尺寸编码完全不同，不能只看一种：
/// - `VP8 `（有损）：块内 3 字节帧标签 + `9D 01 2A` 起始码，之后才是 14 位宽高；
/// - `VP8L`（无损）：1 字节签名 `0x2F`，随后 28 位里塞 `宽-1` 与 `高-1`（各 14 位）；
/// - `VP8X`（扩展）：画布尺寸是 24 位小端、且是"减一"值，多用于动图/透明图。
ImageHeaderSize? _parseWebp(Uint8List bytes) {
  if (!_startsWith(bytes, 0, const <int>[0x52, 0x49, 0x46, 0x46])) {
    return null;
  }
  if (!_startsWith(bytes, 8, const <int>[0x57, 0x45, 0x42, 0x50])) {
    return null;
  }
  // 块链表：第一块就是图像数据（VP8X 也可能是第一块），逐个试着解。
  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final chunkSize = _le32(bytes, offset + 4);
    final payload = offset + 8;
    if (chunkSize < 0 || payload > bytes.length) {
      return null;
    }
    final available = bytes.length - payload;
    final size = chunkSize > available ? available : chunkSize;

    if (_startsWith(bytes, offset, const <int>[0x56, 0x50, 0x38, 0x20])) {
      // 'VP8 ' 有损
      if (size >= 10 &&
          bytes[payload + 3] == 0x9D &&
          bytes[payload + 4] == 0x01 &&
          bytes[payload + 5] == 0x2A) {
        final width = _le16(bytes, payload + 6) & 0x3FFF;
        final height = _le16(bytes, payload + 8) & 0x3FFF;
        final result = _checked(width, height);
        if (result != null) {
          return result;
        }
      }
    } else if (_startsWith(bytes, offset, const <int>[0x56, 0x50, 0x38, 0x4C])) {
      // 'VP8L' 无损：14 位宽-1 与 14 位高-1，紧跟在 0x2F 签名之后。
      if (size >= 5 && bytes[payload] == 0x2F) {
        final bits = _le32(bytes, payload + 1);
        final width = (bits & 0x3FFF) + 1;
        final height = ((bits >> 14) & 0x3FFF) + 1;
        final result = _checked(width, height);
        if (result != null) {
          return result;
        }
      }
    } else if (_startsWith(
        bytes, offset, const <int>[0x56, 0x50, 0x38, 0x58])) {
      // 'VP8X' 扩展容器：24 位小端画布尺寸（减一存储）。
      if (size >= 10) {
        final width = _le24(bytes, payload + 4) + 1;
        final height = _le24(bytes, payload + 7) + 1;
        final result = _checked(width, height);
        if (result != null) {
          return result;
        }
      }
    }
    // 块数据按偶数长度对齐（RIFF 规范），否则会错位并读出垃圾。
    final advance = 8 + chunkSize + (chunkSize.isOdd ? 1 : 0);
    if (advance <= 0) {
      return null;
    }
    offset += advance;
  }
  return null;
}

/// JPEG：`FFD8` 之后逐段跳，直到第一个 `SOFn` 段。
///
/// ## 两个必须做对的细节
///
/// 1. **`SOF` 的判定要排除三个"看着像"的段**：`0xC4`（DHT，霍夫曼表）、
///    `0xC8`（JPG 保留）、`0xCC`（DAC，算术编码表）不在 `SOF` 集合里。
///    把它们当成 `SOF` 会把霍夫曼表的字节读成宽高 —— 症状是"比例莫名其妙"，
///    而且只在特定图片上出现，最难排查。
/// 2. **遇到 `SOS`（`0xDA`）必须停**：熵编码数据跟在 `SOS` 后面，里面到处是
///    `0xFF`，继续按段解析会一路错位。到 `SOS` 还没见到 `SOF` 就说明这张图不
///    正常，返回 `null` 比猜一个尺寸安全。
///
/// 另外 `0x01` 与 `0xD0~0xD7`（RSTn）是**无长度字段**的独立标记，不跳长度。
ImageHeaderSize? _parseJpeg(Uint8List bytes) {
  if (bytes[0] != 0xFF || bytes[1] != 0xD8) {
    return null;
  }
  var offset = 2;
  while (offset + 1 < bytes.length) {
    if (bytes[offset] != 0xFF) {
      return null;
    }
    // 填充字节：允许连续多个 0xFF。
    var marker = bytes[offset + 1];
    while (marker == 0xFF && offset + 2 < bytes.length) {
      offset += 1;
      marker = bytes[offset + 1];
    }
    offset += 2;
    if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      continue;
    }
    if (marker == 0xD9 || marker == 0xDA) {
      return null;
    }
    if (offset + 1 >= bytes.length) {
      return null;
    }
    final length = _be16(bytes, offset);
    if (length < 2) {
      return null;
    }
    if (_isJpegStartOfFrame(marker)) {
      // 段负载：1 字节精度 + 2 字节高 + 2 字节宽（相对负载起点，即长度字段之后）。
      final payload = offset + 2;
      if (payload + 5 > bytes.length) {
        return null;
      }
      return _checked(_be16(bytes, payload + 3), _be16(bytes, payload + 1));
    }
    offset += length;
  }
  return null;
}

bool _isJpegStartOfFrame(int marker) {
  if (marker < 0xC0 || marker > 0xCF) {
    return false;
  }
  // DHT / JPG / DAC 不是 SOF，虽然落在 0xC0..0xCF 区间内。
  return marker != 0xC4 && marker != 0xC8 && marker != 0xCC;
}
