import 'package:picakeep/network/pixiv_network/pixiv_parsing.dart';
import 'package:test/test.dart';

void main() {
  group('detail commentOff', () {
    test('only explicit bool and 0/1 values establish the disabled state', () {
      for (final pair in <(Object, bool)>[
        (1, true),
        (true, true),
        ('1', true),
        ('true', true),
        (0, false),
        (false, false),
        ('0', false),
        ('false', false),
      ]) {
        final info = parsePixivComicInfo({
          'id': '150343763',
          'commentOff': pair.$1,
          'commentCount': 0,
        });
        expect(info.commentsDisabled, pair.$2, reason: '${pair.$1}');
      }
    });

    test('missing or unknown state stays unknown regardless of comment count',
        () {
      for (final count in [0, 48]) {
        expect(
          parsePixivComicInfo({
            'id': '150343763',
            'commentCount': count,
            'commentsDisabled': true,
          }).commentsDisabled,
          isNull,
        );
        for (final value in <Object?>[
          null,
          2,
          -1,
          0.5,
          '',
          'yes',
          'unknown',
          <String, dynamic>{},
          <Object>[],
        ]) {
          final info = parsePixivComicInfo({
            'id': '150343763',
            'commentOff': value,
            'commentCount': count,
          });
          expect(info.commentsDisabled, isNull, reason: '$value / $count');
        }
      }
    });

    test('bookmark copies preserve disabled, enabled and unknown states', () {
      for (final state in <bool?>[true, false, null]) {
        final original = parsePixivComicInfo({
          'id': '150343763',
          'illustTitle': '\u2800',
          'userName': '\u2800',
          'commentOff': state,
          'commentCount': 0,
          'bookmarkData': {'id': '300', 'private': true},
        });
        for (final copy in [
          original.copyWith(),
          original.copyWith(
            isBookmarked: false,
            bookmarkId: null,
            bookmarkPrivate: null,
          ),
        ]) {
          expect(copy.commentsDisabled, state);
          expect(copy.title, original.title);
          expect(copy.author, original.author);
          expect(copy.commentCount, original.commentCount);
        }
      }
    });

    test('visually blank titles and names retain their original U+2800 text',
        () {
      for (final title in ['\u2800', '\u2800\u2800', '\u2800原题\u2800']) {
        final info = parsePixivComicInfo({
          'id': '150343763',
          'illustTitle': title,
          'title': 'Must not replace the original title',
          'userName': '\u2800',
          'userAccount': 'Must not replace the original name',
          'commentOff': 1,
        });
        expect(info.title, title);
        expect(info.author, '\u2800');
      }
    });
  });
}
