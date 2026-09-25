const aiSourcePicacg = 'picacg';
const aiSourceJm = 'jm';
const aiSourceEhentai = 'ehentai';
const aiSourceNhentai = 'nhentai';
// 第十八轮新增在线源。
const aiSourcePixiv = 'pixiv';
const aiSourceKomiic = 'komiic';

const aiSources = <String>{
  aiSourcePicacg,
  aiSourceJm,
  aiSourceEhentai,
  aiSourceNhentai,
  aiSourcePixiv,
  aiSourceKomiic,
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
  if (source == 'pix' || source == 'p站') {
    return aiSourcePixiv;
  }
  // Komiic 的下载/历史/收藏侧历史遗留 sourceKey 写作大写 `'Komiic'`，
  // 但源注册与 AI 工具统一用小写 `komiic`；这里显式归一化，
  // 避免模型传 'Komiic' 时被判为不支持源。
  if (source == 'komiic') {
    return aiSourceKomiic;
  }
  return isSupportedAiSource(source) ? source : null;
}
