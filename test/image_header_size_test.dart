/// 图片头尺寸解析器的**逐格式**测试。
///
/// ## 为什么值得这么细
///
/// 这个解析器是"瀑布流按真实比例排版"的唯一数据来源（老下载记录里没有宽高，
/// 见 32 号计划）。它全是位运算与偏移，**看代码验不出来**，而错法的症状又特别隐蔽：
/// 比例看着"差不多"，只是每条高度都不对 —— 正是用户最初报的那个问题。
///
/// 覆盖三类：
/// 1. **真实编码器产出的字节**（`package:image` 生成 PNG / JPEG）——
///    证明对真实文件有效，而不只是对手写的理想字节有效；
/// 2. **手写的最小段结构** —— 覆盖真实编码器不一定产生、但现实中存在的分支
///    （JPEG 的 `DHT` 段、`SOS` 截断、WebP 的三种块、GIF）；
/// 3. **退化输入** —— 空 / 截断 / 垃圾 / 尺寸为 0，必须返回 `null` 而不是抛异常
///    或返回一个荒谬的比例。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:picakeep/foundation/image_header_size.dart';

/// 大端 16 位。
List<int> _be16(int v) => <int>[(v >> 8) & 0xFF, v & 0xFF];

/// 小端 16 位。
List<int> _le16(int v) => <int>[v & 0xFF, (v >> 8) & 0xFF];

/// 小端 24 位。
List<int> _le24(int v) =>
    <int>[v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF];

/// 小端 32 位。
List<int> _le32(int v) =>
    <int>[v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

/// 一个大端 32 位整数（PNG 的块长度与 IHDR 用）。
List<int> _be32(int v) =>
    <int>[(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);

/// 手写 PNG：签名 + `IHDR`（宽高在固定偏移 16/20）。
Uint8List _pngBytes(int width, int height) {
  return _bytes(<int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // 签名
    ..._be32(13), // IHDR 数据长度（固定 13）
    0x49, 0x48, 0x44, 0x52, // 'IHDR'
    ..._be32(width),
    ..._be32(height),
    0x08, 0x06, 0x00, 0x00, 0x00, // 位深/颜色类型/压缩/滤波/隔行
    0x00, 0x00, 0x00, 0x00, // CRC 占位（解析器不校验）
  ]);
}

/// 手写 GIF：`GIF89a` + 逻辑屏幕宽高（小端）。
Uint8List _gifBytes(int width, int height) {
  return _bytes(<int>[
    0x47, 0x49, 0x46, 0x38, 0x39, 0x61, // 'GIF89a'
    ..._le16(width),
    ..._le16(height),
    0x00, 0x00, 0x00, // 其余字段（解析器不读）
  ]);
}

/// 手写 JPEG：`FFD8` + 若干段 + 一个 `SOF0`。
///
/// [leadingSegments] 用来插入 `APP0` / `DHT` 这类**必须先被跳过**的段；
/// [trailingEntropy] 为真时在 `SOF0` 之后补一个 `SOS`（证明解析在遇到 SOF 时
/// 就已经有结果，不需要读熵编码数据）。
Uint8List _jpegBytes({
  required int width,
  required int height,
  List<List<int>> leadingSegments = const <List<int>>[],
  bool trailingEntropy = false,
}) {
  final out = <int>[0xFF, 0xD8];
  for (final segment in leadingSegments) {
    out.addAll(segment);
  }
  // SOF0：FFC0 + 长度(2) + 精度(1) + 高(2) + 宽(2) + 分量数(1) + ...
  final sof = <int>[
    0xFF, 0xC0,
    ..._be16(11), // 段长（含长度字段自身）
    0x08, // 精度
    ..._be16(height),
    ..._be16(width),
    0x01, 0x01, 0x11, 0x00, // 1 个分量
  ];
  out.addAll(sof);
  if (trailingEntropy) {
    // SOS：FFDA + 长度(2) + ... 之后是熵编码数据（里面到处是 0xFF）。
    out.addAll(<int>[0xFF, 0xDA, ..._be16(8), 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00]);
    out.addAll(<int>[0xFF, 0x00, 0xFF, 0xD9]);
  }
  return _bytes(out);
}

/// 一个 `APP0`（JFIF）段：真实 JPEG 的第一个段，解析器必须按长度跳过它。
List<int> _app0Segment(int payloadBytes) {
  return <int>[
    0xFF, 0xE0,
    ..._be16(payloadBytes + 2),
    ...List<int>.filled(payloadBytes, 0x00),
  ];
}

/// 一个 `DHT`（霍夫曼表）段：**必须不被当成 `SOF`**。
///
/// 段内字节刻意排成"如果被误读为 SOF 就会得到一个像模像样的宽高"的形态：
/// 精度字节后面的四个字节是 `40 00 30 00`（= 高 16384、宽 12288），
/// 一旦误判就会得到一个离谱却不像垃圾的比例。
List<int> _dhtSegment() {
  return <int>[
    0xFF, 0xC4,
    ..._be16(9),
    0x08, 0x40, 0x00, 0x30, 0x00, 0x11, 0x22,
  ];
}

void main() {
  group('PNG', () {
    test('真实编码器产出的 PNG：宽高与编码时一致', () {
      final image = img.Image(width: 638, height: 1200);
      final size = parseImageHeaderSize(_bytes(img.encodePng(image)));
      expect(size, const ImageHeaderSize(638, 1200));
    });

    test('手写 IHDR：走固定偏移，不需要扫描块链表', () {
      expect(parseImageHeaderSize(_pngBytes(1, 2)),
          const ImageHeaderSize(1, 2));
      expect(parseImageHeaderSize(_pngBytes(2000, 3500)),
          const ImageHeaderSize(2000, 3500));
    });

    test('签名对但 IHDR 之前有别的块 → 不认（正常 PNG 不允许）', () {
      final bytes = _pngBytes(10, 20);
      final tampered = Uint8List.fromList(bytes);
      // 把块类型从 'IHDR' 改成 'XHDR'
      tampered[12] = 0x58;
      expect(parseImageHeaderSize(tampered), isNull);
    });
  });

  group('JPEG', () {
    test('真实编码器产出的 JPEG：宽高与编码时一致', () {
      final image = img.Image(width: 856, height: 1200);
      final size = parseImageHeaderSize(_bytes(img.encodeJpg(image)));
      expect(size, const ImageHeaderSize(856, 1200));
    });

    test('跳过 APP0 后再读 SOF0', () {
      final bytes = _jpegBytes(
        width: 686,
        height: 1200,
        leadingSegments: <List<int>>[_app0Segment(64)],
      );
      expect(parseImageHeaderSize(bytes),
          const ImageHeaderSize(686, 1200));
    });

    test('DHT 段不会被误当成 SOF（0xC4 必须排除）', () {
      // 只有 DHT、没有 SOF → 必须返回 null，而不是把霍夫曼表的字节读成宽高。
      final onlyDht = _bytes(<int>[0xFF, 0xD8, ..._dhtSegment(), 0xFF, 0xD9]);
      expect(parseImageHeaderSize(onlyDht), isNull);

      // DHT 在 SOF 之前时，仍然读到 SOF 的真实宽高。
      final withSof = _jpegBytes(
        width: 120,
        height: 240,
        leadingSegments: <List<int>>[_dhtSegment(), _app0Segment(8)],
      );
      expect(parseImageHeaderSize(withSof),
          const ImageHeaderSize(120, 240));
    });

    test('遇到 SOS 就停：SOF 在 SOS 之后（异常图）→ null', () {
      final bytes = _bytes(<int>[
        0xFF, 0xD8,
        0xFF, 0xDA, ..._be16(8), 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00,
        // SOS 之后即便有"看着像 SOF"的字节也不能被当成尺寸
        0xFF, 0xC0, ..._be16(11), 0x08, ..._be16(100), ..._be16(200), 0x01, 0x01, 0x11, 0x00,
      ]);
      expect(parseImageHeaderSize(bytes), isNull);
    });

    test('SOF 之后跟 SOS + 熵编码数据：结果不受影响', () {
      final bytes = _jpegBytes(
        width: 300,
        height: 600,
        leadingSegments: <List<int>>[_app0Segment(32)],
        trailingEntropy: true,
      );
      expect(parseImageHeaderSize(bytes),
          const ImageHeaderSize(300, 600));
    });

    test('SOF2（渐进式）与 SOF9（算术编码）都认', () {
      for (final marker in <int>[0xC2, 0xC9]) {
        final bytes = _bytes(<int>[
          0xFF, 0xD8,
          0xFF, marker, ..._be16(11), 0x08, ..._be16(480), ..._be16(640),
          0x01, 0x01, 0x11, 0x00,
        ]);
        expect(parseImageHeaderSize(bytes),
            const ImageHeaderSize(640, 480),
            reason: 'marker 0x${marker.toRadixString(16)} 应被识别为 SOF');
      }
    });
  });

  group('WebP', () {
    test('VP8X（扩展容器）：24 位画布尺寸是"减一"存储', () {
      final payload = <int>[
        0x00, // 标志
        0x00, 0x00, 0x00, // 保留
        ..._le24(1070 - 1),
        ..._le24(2014 - 1),
      ];
      final bytes = _bytes(<int>[
        0x52, 0x49, 0x46, 0x46, ..._le32(4 + 8 + payload.length),
        0x57, 0x45, 0x42, 0x50,
        0x56, 0x50, 0x38, 0x58, // 'VP8X'
        ..._le32(payload.length),
        ...payload,
      ]);
      expect(parseImageHeaderSize(bytes),
          const ImageHeaderSize(1070, 2014));
    });

    test('VP8（有损）：起始码 9D 01 2A 之后的 14 位宽高', () {
      final payload = <int>[
        0x00, 0x00, 0x00, // 帧标签
        0x9D, 0x01, 0x2A, // 起始码（识别用）
        ..._le16(638),
        ..._le16(1200),
      ];
      final bytes = _bytes(<int>[
        0x52, 0x49, 0x46, 0x46, ..._le32(4 + 8 + payload.length),
        0x57, 0x45, 0x42, 0x50,
        0x56, 0x50, 0x38, 0x20, // 'VP8 '
        ..._le32(payload.length),
        ...payload,
      ]);
      expect(parseImageHeaderSize(bytes),
          const ImageHeaderSize(638, 1200));
    });

    test('VP8L（无损）：签名 0x2F 后 14+14 位「减一」值', () {
      const width = 686;
      const height = 1200;
      const bits = ((height - 1) << 14) | (width - 1);
      final payload = <int>[0x2F, ..._le32(bits)];
      final bytes = _bytes(<int>[
        0x52, 0x49, 0x46, 0x46, ..._le32(4 + 8 + payload.length),
        0x57, 0x45, 0x42, 0x50,
        0x56, 0x50, 0x38, 0x4C, // 'VP8L'
        ..._le32(payload.length),
        ...payload,
      ]);
      expect(parseImageHeaderSize(bytes),
          const ImageHeaderSize(686, 1200));
    });

    test('RIFF 容器但不是 WebP → null', () {
      final bytes = _bytes(<int>[
        0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0,
        0x57, 0x41, 0x56, 0x45, // 'WAVE'
        0, 0, 0, 0, 0, 0, 0, 0,
      ]);
      expect(parseImageHeaderSize(bytes), isNull);
    });
  });

  group('GIF', () {
    test('GIF89a：逻辑屏幕宽高', () {
      expect(parseImageHeaderSize(_gifBytes(320, 480)),
          const ImageHeaderSize(320, 480));
    });

    test('GIF87a 也认', () {
      final bytes = _bytes(<int>[
        0x47, 0x49, 0x46, 0x38, 0x37, 0x61, ..._le16(64), ..._le16(32),
        0, 0, 0,
      ]);
      expect(parseImageHeaderSize(bytes), const ImageHeaderSize(64, 32));
    });
  });

  group('退化输入：一律 null，绝不抛异常也不给荒谬比例', () {
    test('空 / 过短', () {
      expect(parseImageHeaderSize(Uint8List(0)), isNull);
      expect(parseImageHeaderSize(_bytes(<int>[0xFF, 0xD8])), isNull);
      expect(parseImageHeaderSize(_bytes(List<int>.filled(9, 0))), isNull);
    });

    test('纯垃圾字节', () {
      expect(
        parseImageHeaderSize(_bytes(List<int>.generate(64, (i) => i * 7 % 256))),
        isNull,
      );
    });

    test('PNG 宽高为 0 → null（0 会让瀑布流算出错误高度甚至除零）', () {
      expect(parseImageHeaderSize(_pngBytes(0, 100)), isNull);
      expect(parseImageHeaderSize(_pngBytes(100, 0)), isNull);
    });

    test('PNG 尺寸超出合理上限 → null（偏移读错时的保护）', () {
      expect(parseImageHeaderSize(_pngBytes(70000, 70000)), isNull);
      // 上限之内仍然正常
      expect(parseImageHeaderSize(_pngBytes(65535, 1)),
          const ImageHeaderSize(65535, 1));
    });

    test('截断的 PNG：IHDR 不完整 → null', () {
      final bytes = _pngBytes(100, 200);
      expect(parseImageHeaderSize(Uint8List.sublistView(bytes, 0, 18)), isNull);
    });

    test('JPEG 段长度非法（< 2）→ null，不会死循环', () {
      final bytes = _bytes(<int>[
        0xFF, 0xD8,
        0xFF, 0xE0, 0x00, 0x00, // 长度为 0
        0x00, 0x00,
      ]);
      expect(parseImageHeaderSize(bytes), isNull);
    });

    test('JPEG 段长度越过文件末尾 → null', () {
      final bytes = _bytes(<int>[
        0xFF, 0xD8,
        0xFF, 0xE0, 0xFF, 0xFF, // 声称 65535 字节
        0x00, 0x00,
      ]);
      expect(parseImageHeaderSize(bytes), isNull);
    });
  });

  group('ImageHeaderSize', () {
    test('aspectRatio 即宽/高', () {
      expect(const ImageHeaderSize(638, 1200).aspectRatio,
          closeTo(0.53167, 0.00001));
    });

    test('相等性按宽高比较（缓存去重依赖它）', () {
      expect(const ImageHeaderSize(1, 2), const ImageHeaderSize(1, 2));
      expect(const ImageHeaderSize(1, 2), isNot(const ImageHeaderSize(2, 1)));
      expect(const ImageHeaderSize(1, 2).hashCode,
          const ImageHeaderSize(1, 2).hashCode);
    });
  });
}
