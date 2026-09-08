import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/network/eh_network/eh_site.dart';

void main() {
  const eh = 'https://e-hentai.org';
  const ex = 'https://exhentai.org';
  test('ExHentai gallery keeps its API while the selected site is public', () {
    expect(ehSiteApi('$ex/g/123/abc/', fallback: eh), '$ex/api.php');
    expect(ehSiteOrigin('$ex/g/123/abc/', fallback: eh), ex);
  });
  test('public gallery keeps the public API while ExHentai is selected', () {
    expect(ehSiteApi('$eh/g/123/abc/', fallback: ex),
        'https://api.e-hentai.org/api.php');
    expect(ehSiteOrigin('$eh/g/123/abc/', fallback: ex), eh);
  });
  test('reader links retain the site for node retries', () {
    for (final site in [eh, ex]) {
      expect(ehSiteOrigin('$site/s/abc/123-2?nl=old', fallback: eh), site);
    }
  });
  test('www and uppercase hosts resolve to canonical HTTPS origins', () {
    expect(ehSiteOrigin('http://WWW.EXHENTAI.ORG/g/1/a/', fallback: eh), ex);
    expect(ehSiteOrigin('https://www.e-hentai.org/g/1/a/', fallback: ex), eh);
  });
  test('legacy operations without a gallery use the selected site', () {
    expect(ehSiteApi(null, fallback: ex), '$ex/api.php');
    expect(ehSiteApi(null, fallback: eh), 'https://api.e-hentai.org/api.php');
  });
  test('lookalike hosts cannot select an authenticated endpoint', () {
    for (final link in [
      'https://exhentai.org.example.com/g/1/a/',
      'https://fake-exhentai.org/g/1/a/',
      'https://exhentai.org@evil.example/g/1/a/',
      'invalid',
    ]) {
      expect(ehSiteOrigin(link, fallback: eh), eh);
    }
  });
}
