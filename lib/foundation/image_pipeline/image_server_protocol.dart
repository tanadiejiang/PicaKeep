import 'dart:convert';
import 'dart:typed_data';

const imageProtocolVersion = 1;
const imageDerivativeAlgorithmVersion = 2;
const imageCoverVariant = 'cover-v1';
const imageCoverWidths = [192, 384, 768, 1536];
const imageTileSize = 512;

class ImageServerCapabilities {
  const ImageServerCapabilities({
    this.version = imageProtocolVersion,
    this.coverWidths = const [],
    this.coverFormats = const [],
    this.manifests = false,
    this.levels = false,
    this.tiles = false,
    this.largeRegions = false,
  });
  final int version;
  final List<int> coverWidths;
  final List<String> coverFormats;
  final bool manifests;
  final bool levels;
  final bool tiles;
  final bool largeRegions;
  bool get supportsCovers =>
      version == imageProtocolVersion &&
      coverWidths.isNotEmpty &&
      coverFormats.isNotEmpty;

  factory ImageServerCapabilities.fromJson(Object? value) {
    if (value is! Map || value['version'] != imageProtocolVersion) {
      return const ImageServerCapabilities();
    }
    return ImageServerCapabilities(
      version: value['version'] as int,
      coverWidths: value['coverWidths'] is List
          ? (value['coverWidths'] as List)
              .whereType<int>()
              .where(imageCoverWidths.contains)
              .toList()
          : const [],
      coverFormats: value['coverFormats'] is List
          ? (value['coverFormats'] as List)
              .whereType<String>()
              .where(['png', 'jpeg', 'webp'].contains)
              .toList()
          : const [],
      manifests: value['manifests'] == true,
      levels: value['levels'] == true,
      tiles: value['tiles'] == true,
      largeRegions: value['largeRegions'] == true,
    );
  }

  Map<String, Object> toJson() => {
        'version': version,
        'coverVariant': imageCoverVariant,
        'coverWidths': coverWidths,
        'coverFormats': coverFormats,
        'manifests': manifests,
        'levels': levels,
        'tiles': tiles,
        'largeRegions': largeRegions,
        'tileSize': imageTileSize,
      };
}

class ImagePageManifest {
  const ImagePageManifest({
    required this.pageIdentity,
    required this.sourceVersion,
    required this.width,
    required this.height,
    required this.originalUrl,
    required this.levels,
    this.tileSize = imageTileSize,
    this.orientationApplied = true,
    this.sourceQuality = 'authoritativeOriginal',
    this.colorSpace = 'sRGB',
    this.pixelFormat = 'rgba8888',
    this.preparation = 'ready',
    this.tilesAvailable = false,
    this.algorithmVersion = imageDerivativeAlgorithmVersion,
  });
  final String pageIdentity;
  final String sourceVersion;
  final int width;
  final int height;
  final String originalUrl;
  final List<ImageManifestLevel> levels;
  final int tileSize;
  final bool orientationApplied;
  final String sourceQuality;
  final String colorSpace;
  final String pixelFormat;
  final String preparation;
  final bool tilesAvailable;
  final int algorithmVersion;

  factory ImagePageManifest.fromJson(Map<String, dynamic> json) {
    final width = json['width'];
    final height = json['height'];
    if (json['version'] != imageProtocolVersion ||
        width is! int ||
        width <= 0 ||
        height is! int ||
        height <= 0 ||
        json['sourceVersion'] is! String ||
        (json['sourceVersion'] as String).isEmpty) {
      throw const FormatException('Invalid image manifest');
    }
    final levels = json['levels'];
    return ImagePageManifest(
      pageIdentity: json['pageIdentity'] as String,
      sourceVersion: json['sourceVersion'] as String,
      width: width,
      height: height,
      originalUrl: json['originalUrl'] as String,
      levels: levels is List
          ? levels
              .whereType<Map>()
              .map((entry) =>
                  ImageManifestLevel.fromJson(Map<String, dynamic>.from(entry)))
              .toList()
          : const [],
      tileSize:
          json['tileSize'] is int ? json['tileSize'] as int : imageTileSize,
      orientationApplied: json['orientationApplied'] == true,
      sourceQuality: json['sourceQuality'] is String
          ? json['sourceQuality'] as String
          : 'bestAvailableSource',
      colorSpace: json['colorSpace'] is String
          ? json['colorSpace'] as String
          : 'unknown',
      pixelFormat: json['pixelFormat'] is String
          ? json['pixelFormat'] as String
          : 'unknown',
      preparation: json['preparation'] is String
          ? json['preparation'] as String
          : 'ready',
      tilesAvailable: json['tilesAvailable'] == true,
      algorithmVersion:
          json['algorithmVersion'] is int ? json['algorithmVersion'] as int : 1,
    );
  }

  Map<String, Object> toJson() => {
        'version': imageProtocolVersion,
        'algorithmVersion': algorithmVersion,
        'pageIdentity': pageIdentity,
        'sourceVersion': sourceVersion,
        'width': width,
        'height': height,
        'originalUrl': originalUrl,
        'orientationApplied': orientationApplied,
        'sourceQuality': sourceQuality,
        'colorSpace': colorSpace,
        'pixelFormat': pixelFormat,
        'preparation': preparation,
        'tileSize': tileSize,
        'edgeRule': 'exactSourceRect',
        'tilesAvailable': tilesAvailable,
        'levels': levels.map((level) => level.toJson()).toList(),
      };
}

class ImageManifestLevel {
  const ImageManifestLevel({
    required this.index,
    required this.width,
    required this.height,
    required this.density,
    required this.url,
    required this.tileUrlTemplate,
    this.lossless = true,
    this.mimeType = 'image/png',
  });
  final int index;
  final int width;
  final int height;
  final double density;
  final String url;
  final String tileUrlTemplate;
  final bool lossless;
  final String mimeType;
  factory ImageManifestLevel.fromJson(Map<String, dynamic> json) {
    if (json['index'] is! int ||
        json['width'] is! int ||
        json['height'] is! int ||
        json['density'] is! num ||
        (json['density'] as num) <= 0 ||
        (json['density'] as num) > 1) {
      throw const FormatException('Invalid image level');
    }
    return ImageManifestLevel(
      index: json['index'] as int,
      width: json['width'] as int,
      height: json['height'] as int,
      density: (json['density'] as num).toDouble(),
      url: json['url'] as String,
      tileUrlTemplate: json['tileUrlTemplate'] as String,
      lossless: json['lossless'] == true,
      mimeType: json['mimeType'] as String,
    );
  }
  Map<String, Object> toJson() => {
        'index': index,
        'width': width,
        'height': height,
        'density': density,
        'url': url,
        'tileUrlTemplate': tileUrlTemplate,
        'lossless': lossless,
        'mimeType': mimeType,
      };
}

enum ImageDerivativeResponseKind {
  ready,
  preparing,
  notModified,
  versionChanged,
  unsupported,
  failed
}

class ImageDerivativeResponse {
  const ImageDerivativeResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
  });
  final int statusCode;
  final Map<String, String> headers;
  final Uint8List body;
  ImageDerivativeResponseKind get kind => switch (statusCode) {
        200 => ImageDerivativeResponseKind.ready,
        202 => ImageDerivativeResponseKind.preparing,
        304 => ImageDerivativeResponseKind.notModified,
        409 => ImageDerivativeResponseKind.versionChanged,
        404 => ImageDerivativeResponseKind.unsupported,
        _ => ImageDerivativeResponseKind.failed,
      };
  Map<String, dynamic>? get state {
    if (kind == ImageDerivativeResponseKind.ready || body.isEmpty) return null;
    try {
      final value = jsonDecode(utf8.decode(body));
      return value is Map ? Map<String, dynamic>.from(value) : null;
    } on Object {
      return null;
    }
  }

  bool get isImage =>
      statusCode == 200 &&
      (headers['content-type'] ?? '').split(';').first.startsWith('image/') &&
      body.isNotEmpty;
}

String imagePagePath(String itemId, int episode, int page) =>
    '/api/library/items/${Uri.encodeComponent(itemId)}/images/$episode/$page';

String imageManifestPath(String itemId, int episode, int page) =>
    '${imagePagePath(itemId, episode, page)}/manifest';

String imageVariantUrl(
  String originalUrl, {
  required int width,
  required String format,
  required String sourceVersion,
}) {
  final uri = Uri.parse(originalUrl);
  return uri.replace(queryParameters: {
    ...uri.queryParameters,
    'variant': imageCoverVariant,
    'w': '$width',
    'format': format,
    'v': sourceVersion,
    'a': '$imageDerivativeAlgorithmVersion',
  }).toString();
}
