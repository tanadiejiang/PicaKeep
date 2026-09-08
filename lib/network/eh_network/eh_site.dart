/// Resolve gallery operations independently of the selected search site.
String ehSiteOrigin(String? link, {required String fallback}) {
  final host = Uri.tryParse(link ?? '')?.host.toLowerCase();
  if (host == 'exhentai.org' || host == 'www.exhentai.org') {
    return 'https://exhentai.org';
  }
  if (host == 'e-hentai.org' || host == 'www.e-hentai.org') {
    return 'https://e-hentai.org';
  }
  return fallback;
}

String ehSiteApi(String? link, {required String fallback}) =>
    ehSiteOrigin(link, fallback: fallback) == 'https://exhentai.org'
        ? 'https://exhentai.org/api.php'
        : 'https://api.e-hentai.org/api.php';
