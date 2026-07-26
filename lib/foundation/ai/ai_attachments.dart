/// 15轮03号计划：AI 会话图片附件的目录管理、压缩落盘、mime 嗅探与删除清理。
///
/// 两条铁律（违反会产生崩溃/越界 bug）：
/// 1. `ui.instantiateImageCodec` / `ui.ImageDescriptor` 需要 Flutter engine
///    binding，**只能在主 isolate 调用**，不能进 compute isolate；
/// 2. **严禁用 package:image 解码 WebP**（VP8 lossy 解码器系统性越界，来源：
///    lib/foundation/image_loader/jm_image_recombine.dart:4-6，项目铁律），
///    image 包在本项目只准做编码；解码统一走 `ui.instantiateImageCodec`。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../app.dart';

/// 单张附件落盘体积上限（1.5MB）。4 张/条 × 1.5MB base64 后约 8MB 请求体。
const aiAttachmentMaxBytes = 1536 * 1024;

/// 附件长边上限（px），超过则等比缩到该值再重编码。
const aiAttachmentMaxEdge = 1600;

/// 附件根目录：{App.dataPath}/ai_conversations/attachments
String aiAttachmentsRoot() =>
    '${App.dataPath}${Platform.pathSeparator}ai_conversations'
    '${Platform.pathSeparator}attachments';

/// 相对路径（'{conversationId}/{fileName}'，统一 '/' 分隔）→ 绝对路径。
/// 存相对路径的原因：App.dataPath 可被用户改，绝对路径会失效。
String resolveAiAttachmentPath(String relativePath) =>
    '${aiAttachmentsRoot()}${Platform.pathSeparator}'
    '${relativePath.replaceAll('/', Platform.pathSeparator)}';

/// 魔数嗅探 mime（照抄 lib/tools/save_image.dart:23-45 的 _detectType，并补一条
/// GIF 分支：原函数不识别 GIF、会回退错标 image/jpeg，导致小 GIF 原样落盘时
/// 扩展名与 data URI 的 mime 全错）。
({String ext, String mime}) detectAiImageType(List<int> data) {
  if (data.length >= 3 &&
      data[0] == 0xff &&
      data[1] == 0xd8 &&
      data[2] == 0xff) {
    return (ext: '.jpg', mime: 'image/jpeg');
  }
  if (data.length >= 8 &&
      data[0] == 0x89 &&
      data[1] == 0x50 &&
      data[2] == 0x4e &&
      data[3] == 0x47) {
    return (ext: '.png', mime: 'image/png');
  }
  if (data.length >= 12 &&
      data[0] == 0x52 &&
      data[1] == 0x49 &&
      data[2] == 0x46 &&
      data[3] == 0x46) {
    return (ext: '.webp', mime: 'image/webp');
  }
  // GIF 魔数：前 4 字节 'G''I''F''8'。
  if (data.length >= 4 &&
      data[0] == 0x47 &&
      data[1] == 0x49 &&
      data[2] == 0x46 &&
      data[3] == 0x38) {
    return (ext: '.gif', mime: 'image/gif');
  }
  return (ext: '.jpg', mime: 'image/jpeg');
}

/// 把一批本地源文件压缩并落盘到 {root}/{conversationId}/ 下，
/// 返回相对路径列表（'{conversationId}/{时间戳}_{序号}{ext}'，'/' 分隔）。
///
/// 单个文件失败时先清理本次已写入的文件，再抛出带文件名的异常，
/// 由调用方决定提示；保证 attachments 目录只含完整成功批次的图。
Future<List<String>> persistAiAttachments(
    String conversationId, List<String> sourceAbsolutePaths) async {
  final targetDir = Directory(
      '${aiAttachmentsRoot()}${Platform.pathSeparator}$conversationId');
  await targetDir.create(recursive: true);
  final timestamp = DateTime.now().millisecondsSinceEpoch;
  final relativePaths = <String>[];
  final writtenAbsolutePaths = <String>[];
  for (var i = 0; i < sourceAbsolutePaths.length; i++) {
    final source = sourceAbsolutePaths[i];
    try {
      final bytes = await File(source).readAsBytes();
      final processed = await _compressAiAttachment(bytes);
      final fileName = '${timestamp}_$i${processed.ext}';
      final file =
          File('${targetDir.path}${Platform.pathSeparator}$fileName');
      await file.writeAsBytes(processed.bytes);
      writtenAbsolutePaths.add(file.path);
      relativePaths.add('$conversationId/$fileName');
    } catch (e) {
      // 回滚本次已写入的文件，保持目录只含已入列消息的图。
      for (final written in writtenAbsolutePaths) {
        try {
          await File(written).delete();
        } catch (_) {
          // 清理失败不掩盖原始异常。
        }
      }
      final name = source.replaceAll('\\', '/').split('/').last;
      throw Exception('处理图片「$name」失败：$e');
    }
  }
  return relativePaths;
}

/// 压缩单张图（决策E）：
/// - `ui.ImageDescriptor.encoded` 只读宽高（不整图解码）；
/// - 长边 ≤ 1600px 且 bytes ≤ 1.5MB → 原样落盘，保留嗅探扩展名
///   （避免重复编码损失画质，截图文字更清晰利于 OCR/视觉识别）；
/// - 否则：主 isolate 用 `ui.instantiateImageCodec` 解码（宽是长边传
///   targetWidth，高是长边传 targetHeight，只传其一保持宽高比）→ RGBA 交给
///   compute isolate 做 encodeJpg（quality 85→70→55→40 递降压到 ≤1.5MB，
///   仍超限抛异常拒绝该图）。重编码产物一律 .jpg。
/// - GIF 会被 instantiateImageCodec 解出首帧，重编码后动画丢失——可接受，
///   视觉模型也只看首帧。
Future<({Uint8List bytes, String ext})> _compressAiAttachment(
    Uint8List bytes) async {
  final type = detectAiImageType(bytes);
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  final width = descriptor.width;
  final height = descriptor.height;
  descriptor.dispose();
  buffer.dispose();
  final longEdge = math.max(width, height);
  if (longEdge <= aiAttachmentMaxEdge && bytes.length <= aiAttachmentMaxBytes) {
    return (bytes: bytes, ext: type.ext);
  }
  // 解码必须留在主 isolate（铁律 1），只把 CPU 密集的 encodeJpg 挪进 isolate
  // （compute 先例：lib/foundation/remote_library_data_source.dart:2688-2689）。
  final ui.Codec codec;
  if (longEdge <= aiAttachmentMaxEdge) {
    codec = await ui.instantiateImageCodec(bytes);
  } else if (width >= height) {
    codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: aiAttachmentMaxEdge,
    );
  } else {
    codec = await ui.instantiateImageCodec(
      bytes,
      targetHeight: aiAttachmentMaxEdge,
    );
  }
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final decodedWidth = image.width;
  final decodedHeight = image.height;
  image.dispose();
  codec.dispose();
  if (byteData == null) {
    throw Exception('图片解码失败（无法读取像素数据）');
  }
  final encoded = await compute(
    _encodeJpgUnderLimit,
    _AiJpgEncodeRequest(
      rgba: byteData.buffer.asUint8List(),
      width: decodedWidth,
      height: decodedHeight,
    ),
  );
  if (encoded == null) {
    throw Exception('压缩到最低质量后仍超过 1.5MB，已拒绝该图片');
  }
  return (bytes: encoded, ext: '.jpg');
}

class _AiJpgEncodeRequest {
  const _AiJpgEncodeRequest({
    required this.rgba,
    required this.width,
    required this.height,
  });

  final Uint8List rgba;
  final int width;
  final int height;
}

/// compute isolate 内执行：RGBA → JPEG，quality 递降压到 ≤1.5MB；压不到返回 null。
Uint8List? _encodeJpgUnderLimit(_AiJpgEncodeRequest request) {
  final image = img.Image.fromBytes(
    width: request.width,
    height: request.height,
    bytes: request.rgba.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  for (final quality in const [85, 70, 55, 40]) {
    final encoded = Uint8List.fromList(img.encodeJpg(image, quality: quality));
    if (encoded.length <= aiAttachmentMaxBytes) return encoded;
  }
  return null;
}

/// 删除单次发送尝试落盘的文件（发送失败回滚用）。不存在时静默跳过。
Future<void> deleteAiAttachmentFiles(List<String> relativePaths) async {
  for (final relative in relativePaths) {
    try {
      final file = File(resolveAiAttachmentPath(relative));
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // 静默跳过：回滚清理失败不阻断调用方流程。
    }
  }
}

/// 删除整个会话的附件子目录（会话删除/清理时用）。不存在时静默跳过。
Future<void> deleteAiConversationAttachments(String conversationId) async {
  if (conversationId.isEmpty) return;
  try {
    final dir = Directory(
        '${aiAttachmentsRoot()}${Platform.pathSeparator}$conversationId');
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  } catch (_) {
    // 静默跳过：附件目录清理失败不阻断会话删除主流程。
  }
}
