import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/network/eh_network/eh_models.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_comic/eh_content_warning.dart';

Gallery _gallery(String link) {
  return Gallery(
    'title',
    'type',
    'time',
    'uploader',
    0,
    null,
    'cover',
    const {},
    const [],
    null,
    false,
    link,
    '1',
    20,
    const [],
    'jpg',
    100,
    null,
  );
}

void main() {
  test('Content Warning confirmation retries with setNW disabled', () async {
    final calls = <bool>[];
    final result = await requestEhGalleryInfoWithContentWarning(
      link: 'https://e-hentai.org/g/1/token/',
      request: (link, setNW) async {
        calls.add(setNW);
        return setNW
            ? const Res<Gallery>.error('Content Warning')
            : Res<Gallery>(_gallery(link));
      },
      confirmContentWarning: () async => true,
    );

    expect(calls, [true, false]);
    expect(result.success, isTrue);
  });

  test('Content Warning cancellation leaves the initial failure unchanged',
      () async {
    final calls = <bool>[];
    final result = await requestEhGalleryInfoWithContentWarning(
      link: 'https://e-hentai.org/g/1/token/',
      request: (_, setNW) async {
        calls.add(setNW);
        return const Res<Gallery>.error('Content Warning');
      },
      confirmContentWarning: () async => false,
    );

    expect(calls, [true]);
    expect(isEhContentWarning(result), isTrue);
  });

  test('ordinary request failures do not show a Content Warning confirmation',
      () async {
    var confirmationRequested = false;
    final result = await requestEhGalleryInfoWithContentWarning(
      link: 'https://e-hentai.org/g/1/token/',
      request: (_, __) async => const Res<Gallery>.error('Gallery not found'),
      confirmContentWarning: () async {
        confirmationRequested = true;
        return true;
      },
    );

    expect(result.errorMessage, 'Gallery not found');
    expect(confirmationRequested, isFalse);
  });
}
