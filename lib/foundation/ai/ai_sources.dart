const aiSourcePicacg = 'picacg';
const aiSourceJm = 'jm';
const aiSourceEhentai = 'ehentai';
const aiSourceNhentai = 'nhentai';

const aiSources = <String>{
  aiSourcePicacg,
  aiSourceJm,
  aiSourceEhentai,
  aiSourceNhentai,
};

bool isSupportedAiSource(String source) => aiSources.contains(source);

String? normalizeAiSource(Object? value) {
  final source = value?.toString().trim().toLowerCase();
  if (source == null || source.isEmpty) return null;
  if (source == 'eh' || source == 'e-hentai' || source == 'exhentai') {
    return aiSourceEhentai;
  }
  if (source == 'nh' || source == 'n-hentai') {
    return aiSourceNhentai;
  }
  return isSupportedAiSource(source) ? source : null;
}
