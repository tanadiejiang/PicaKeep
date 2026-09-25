/// Pixiv 下载的**产物形态**（目录 / 压缩包 / 单图文件）与打包实现。
///
/// ## 为什么单独成文件
///
/// 打包是**纯 IO**、与下载器无关，但它踩错顺序就是"用户下载全白费"：
/// 必须先确认 zip 真的能被归档服务打开，**才**允许删掉原图片目录。
/// 抽出来才有单测盯着这条顺序（见 `test/pixiv_artifact_test.dart`），
/// 而不是只能靠肉眼看下载器里的几十行。
library;

import 'dart:io';

import 'package:archive/archive_io.dart';

import 'archive/archive_reading_service.dart';
import 'archive/archive_registry.dart';
import 'pixiv_download_naming.dart';

/// 一个作品下载完成后的产物形态。
enum PixivArtifactForm {
  /// 一个作品一个目录（**改动前的形态，也是开关关闭时的唯一形态**）。
  directory,

  /// 多图作品打成一个 zip 文件。
  archive,

  /// 单图作品直接放一个图片文件。
  singleImage,
}

/// 由"开关 + 作品页数"决定产物形态。
///
/// 判定用**作品页数**（`PixivComicInfo.pageCount`），不用"下载到的文件数"：
/// 某一页下载失败会让多图被误判成单图，那等于**把内容截掉**。
///
/// 页数未知（`<= 0`）时保持 [PixivArtifactForm.directory]：不确定就不动形态 ——
/// 猜"是单图"会丢图，猜"是多图"会打出一个页数不全的包，都不如维持现状。
PixivArtifactForm resolvePixivArtifactForm({
  required bool zipEnabled,
  required int pageCount,
}) {
  if (!zipEnabled) {
    return PixivArtifactForm.directory;
  }
  if (pageCount > 1) {
    return PixivArtifactForm.archive;
  }
  if (pageCount == 1) {
    return PixivArtifactForm.singleImage;
  }
  return PixivArtifactForm.directory;
}

/// 产物**文件名**（不含路径）。
///
/// 目录形态返回 `null`：那种形态直接用渲染出的名字当目录名，**不加任何后缀** ——
/// 这是开关关闭时的行为，必须与改动前逐字节一致。
String? pixivArtifactFileName({
  required PixivArtifactForm form,
  required String baseName,
  String imageExtension = '',
}) {
  switch (form) {
    case PixivArtifactForm.directory:
      return null;
    case PixivArtifactForm.archive:
      return buildPixivArtifactFileName(
        baseName: baseName,
        extension: kPixivArchiveExtension,
      );
    case PixivArtifactForm.singleImage:
      final ext = imageExtension.trim();
      // 扩展名缺失时给 `.jpg`：Pixiv 正文只有 jpg/png/webp，回退不能是空串，
      // 否则会产出一个没有扩展名的文件（阅读器与图库都认不出来）。
      return buildPixivArtifactFileName(
        baseName: baseName,
        extension: ext.isEmpty ? '.jpg' : ext,
      );
  }
}

/// 目录里的**正文页**文件（不含封面、不含隐藏文件），按页序。
///
/// 正文页文件名就是下载时写的 `1.jpg`、`2.jpg`…，所以按"数字前缀 + 自然序"排。
Future<List<File>> listPixivPageFiles(Directory sourceDir) async {
  if (!await sourceDir.exists()) {
    return const <File>[];
  }
  final pages = <File>[];
  await for (final entity in sourceDir.list(followLinks: false)) {
    if (entity is! File) {
      continue;
    }
    final name = _basename(entity.path);
    if (name.startsWith('.')) {
      continue;
    }
    if (!_isImageName(name.toLowerCase()) || _isCoverName(name)) {
      continue;
    }
    pages.add(entity);
  }
  pages.sort((a, b) => _pageFileOrder(a.path, b.path));
  return pages;
}

/// 目录里"正文第一页"的文件（**封面不算**）。
///
/// 单图作品正常情况下只会有一张，排序是为了兜住"目录里还留着上一次下载的残页"
/// 这种脏情况 —— 那种时候取错一张就是**给用户看错图**。
///
/// 没有任何正文图片时返回 null，调用方据此保持目录形态（不猜）。
Future<File?> firstPixivPageFile(Directory sourceDir) async {
  final pages = await listPixivPageFiles(sourceDir);
  return pages.isEmpty ? null : pages.first;
}

/// 页码排序：先比"文件名里的数字前缀"，相同再走自然序。
int _pageFileOrder(String left, String right) {
  final a = _leadingNumber(_basename(left));
  final b = _leadingNumber(_basename(right));
  if (a != b) {
    return a.compareTo(b);
  }
  return _naturalCompare(_basename(left), _basename(right));
}

/// `1.jpg` → `1`；解析不出来的排到最后（`null` 比任何数字都大）。
int _leadingNumber(String name) {
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  return int.tryParse(stem) ?? 0x7fffffff;
}

/// 取路径的扩展名（含点、小写）；没有扩展名时返回空串。
String pixivExtensionOf(String path) {
  final name = _basename(path);
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) {
    return '';
  }
  return name.substring(dot).toLowerCase();
}

/// 把 [sourceDir] 里的图片打成 **store（仅存储、不加密）** 的 zip 写到 [target]。
///
/// ## 两个必须说清楚的点
///
/// 1. **store 不能靠 `level: 0` 实现**。`archive` 4.x 的 `ZipEncoder.add()` 先看
///    `ArchiveFile.compression`，为 null 时一律走 deflate 分支；`level: 0` 只是让
///    deflate 输出"存储型块"，压缩方法号仍是 8（deflate），体积反而比真 store 略大。
///    要拿到真正的方法号 0，必须显式给 `compression = CompressionType.none`。
///    用户的诉求是"仅存储不加密"，所以这里按键写死 store。
/// 2. **失败绝不留半成品**。任何异常（含磁盘写满）都会把已落地的 zip 删掉再抛出，
///    免得留下一个"看着像压缩包、其实是半截"的文件被阅读侧当成真产物。
///    删掉的只是 zip，[sourceDir] 一根毫毛都不动 —— 调用方据此降级回目录形态。
///
/// 条目名用文件自己的名字（`1.jpg`、`2.jpg`…，封面 `cover.jpg` 排最前），
/// 与目录形态的产物**同名同序**，这样阅读侧列页结果与目录形态完全一致。
Future<File> packagePixivDirectoryToStoreZip({
  required Directory sourceDir,
  required File target,
}) async {
  final encoder = ZipFileEncoder();
  var opened = false;
  try {
    final entries = await _collectPixivZipEntries(sourceDir);
    if (entries.isEmpty) {
      throw StateError('没有可打包的图片: ${sourceDir.path}');
    }

    encoder.create(target.path);
    opened = true;
    for (final file in entries) {
      // 逐个文件流式写入：一本几十 MB 的作品不会整个进内存。
      final stream = InputFileStream(file.path);
      final entry = ArchiveFile.stream(_basename(file.path), stream)
        ..lastModTime =
            (await file.lastModified()).millisecondsSinceEpoch ~/ 1000
        // 见上文：只有这一行能让压缩方法号落到 0（store）。
        ..compression = CompressionType.none;
      // `addArchiveFile` 内部 `autoClose: true`，会关掉上面那个 InputFileStream；
      // 用 `addFile` 拿不到设置 compression 的机会。
      encoder.addArchiveFile(entry);
    }
    await encoder.close();
    opened = false;

    // ── 校验：**删原目录之前**唯一的一次"写成功"证据 ──────────────────
    //
    // 用阅读侧同一个入口打开它。条目数对不上说明有文件没写进去（或写坏了），
    // 一样按失败处理 —— 宁可退回目录形态，也不能让用户拿到一个缺页的包。
    ArchiveRegistry.initDefaults();
    final index = await ArchiveReadingService.instance
        .getIndex(target.path, forceRefresh: true);
    if (index.imageEntries.length != entries.length) {
      throw StateError(
        '打包结果校验不过：zip 内图片条目 ${index.imageEntries.length} 个，'
        '源目录 ${entries.length} 个',
      );
    }
  } catch (_) {
    if (opened) {
      try {
        await encoder.close();
      } catch (_) {}
    }
    try {
      if (await target.exists()) {
        await target.delete();
      }
    } catch (_) {}
    rethrow;
  }
  return target;
}

/// 目录内的图片条目，**封面在前、其余按自然序**（与目录形态的阅读顺序一致）。
Future<List<File>> _collectPixivZipEntries(Directory sourceDir) async {
  if (!await sourceDir.exists()) {
    return const <File>[];
  }
  final files = <File>[];
  await for (final entity in sourceDir.list(followLinks: false)) {
    if (entity is! File) {
      continue;
    }
    final name = _basename(entity.path);
    final lower = name.toLowerCase();
    if (!_isImageName(lower)) {
      continue;
    }
    // 与阅读侧同口径：**隐藏条目（`.` 开头）不进包**。归档索引会把它们过滤掉，
    // 打进包只会让"包内条目数 == 源文件数"这条校验凭空失败（于是打包永远降级）。
    if (name.startsWith('.')) {
      continue;
    }
    files.add(entity);
  }
  files.sort((a, b) {
    final aCover = _isCoverName(_basename(a.path));
    final bCover = _isCoverName(_basename(b.path));
    if (aCover != bCover) {
      return aCover ? -1 : 1;
    }
    return _naturalCompare(_basename(a.path), _basename(b.path));
  });
  return files;
}

bool _isImageName(String lowerName) {
  return lowerName.endsWith('.jpg') ||
      lowerName.endsWith('.jpeg') ||
      lowerName.endsWith('.png') ||
      lowerName.endsWith('.webp');
}

bool _isCoverName(String name) {
  final lower = name.toLowerCase();
  return lower == 'cover.jpg' ||
      lower == 'cover.jpeg' ||
      lower == 'cover.png' ||
      lower == 'cover.webp';
}

int _naturalCompare(String left, String right) {
  final a = _splitNatural(left.toLowerCase());
  final b = _splitNatural(right.toLowerCase());
  final length = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < length; i++) {
    final leftToken = a[i];
    final rightToken = b[i];
    final leftNumber = int.tryParse(leftToken);
    final rightNumber = int.tryParse(rightToken);
    if (leftNumber != null && rightNumber != null) {
      final diff = leftNumber.compareTo(rightNumber);
      if (diff != 0) return diff;
      continue;
    }
    final diff = leftToken.compareTo(rightToken);
    if (diff != 0) return diff;
  }
  return a.length.compareTo(b.length);
}

List<String> _splitNatural(String value) {
  return RegExp(r'\d+|\D+')
      .allMatches(value)
      .map((match) => match.group(0)!)
      .toList(growable: false);
}

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final segments = normalized.split('/').where((e) => e.isNotEmpty).toList();
  return segments.isEmpty ? path : segments.last;
}
