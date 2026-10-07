import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/image_pipeline/cover_thumbnail_size.dart';

void main() {
  test('cover buckets round up monotonically through the 4096 limit', () {
    const boundaries = <int, int>{
      1: 384,
      383: 384,
      384: 384,
      385: 768,
      767: 768,
      768: 768,
      769: 1024,
      935: 1024,
      1023: 1024,
      1024: 1024,
      1025: 1536,
      1535: 1536,
      1536: 1536,
      1537: 3072,
      3072: 3072,
      3073: 4096,
      4096: 4096,
      4097: 4096,
    };
    for (final entry in boundaries.entries) {
      expect(coverThumbnailWidthBucket(entry.key), entry.value,
          reason: 'requested width ${entry.key}');
    }
    var previousBucket = 0;
    for (var requestedWidth = 1; requestedWidth <= 4096; requestedWidth++) {
      final bucket = coverThumbnailWidthBucket(requestedWidth);
      expect(bucket, greaterThanOrEqualTo(requestedWidth),
          reason: 'the bucket must cover physical demand $requestedWidth');
      expect(bucket, greaterThanOrEqualTo(previousBucket),
          reason: 'increasing demand must not choose a smaller bucket');
      previousBucket = bucket;
    }
  });
}
