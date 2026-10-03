/// 阅读器的**图片清晰度模式**（39 号）：两套开关，按内容类型分。
///
/// ## 需求来源
///
/// 用户真机反馈：「当前阅读浏览插画时图有点糊，放大更糊……糊图的问题在漫画那边
/// 也存在，但漫画的需要单独做一个开关来打开高清模式，默认依旧是[低清]，
/// 插画、图集这边也增加这个模式」，随后明确默认值：
/// 「漫画高清模式默认（初始）关闭，但有记忆如果打开后就保持打开，
/// 而插画-图集那边默认打开」。
///
/// ## 「糊」的机制
///
/// 阅读器对所有图都按**屏幕宽度降采样**（`pages/reader/image_view.dart` 的
/// `_createReaderImageRequest`）：单页档 `宽度 × DPR × 1.6`、双页档
/// `(宽度/2) × DPR × 1.35`、连续滚动档 `宽度 × DPR`。于是"放大看细节"这个
/// 最普通的用法必然糊 —— 放大的部分压根没被解码出来。
///
/// 高清模式 = **跳过这次降采样**，让 `Image` 按图片自身的分辨率解码
/// （与 `_shouldUseOriginalLocalImageStrategy` 那条既有分支同一个做法）。
///
/// ## 为什么是两套开关（而不是一套）
///
/// 用户要求分开：漫画默认低清（一部单行本几十页大图，全分辨率解码会明显吃内存），
/// 插画/图集默认高清（一话往往就一两张图，值得看细节）。
library;

/// `settings[]` 下标：**漫画**阅读高清模式（默认关）。
const int readerHighQualityComicSettingIndex = 159;

/// `settings[]` 下标：**插画 / 图集**阅读高清模式（默认开）。
const int readerHighQualityIllustSettingIndex = 160;

/// 归一化：漫画开关只认 `'1'`，其余（含未设置 / 脏值）一律关。
///
/// 默认关是用户明确要求「默认依旧是[低清]」；而它是**持久化在 settings 里**的，
/// 所以用户打开一次之后就一直是开 —— 这就是用户说的"有记忆"，
/// 不需要额外的状态。
String normalizeReaderHighQualityComic(String? value) =>
    value == '1' ? '1' : '0';

/// 归一化：插画 / 图集开关只认 `'0'`（关），其余（含未设置）一律开。
///
/// 与漫画那侧**方向相反**是有意的：默认值要"缺省即开"，
/// 所以判据不能写成 `== '1'` —— 那样未设置会落到关，与默认值矛盾。
String normalizeReaderHighQualityIllust(String? value) =>
    value == '0' ? '0' : '1';

/// 这些来源算「漫画」：各在线源的连载 / 单行本。
///
/// ## 为什么用 `sourceKey` 而不是 `ComicType`
///
/// `ComicType.other` 是个**兜底桶**：本地图集（`DownloadType.favorite` →
/// `local_album`）、拷贝漫画（`copyManga`）与 Komiic 全都映射到它
/// （见 `foundation/download_model.dart` 的 `comicTypeForDownloadType`）。
/// 用类型判会把 Komiic 划进"插画/图集"，而它是条漫，属于漫画那一侧。
///
/// ## 为什么反着判
///
/// 这里列的是**漫画**来源，其余一律算"插画/图集"。反过来列"插画来源"的话，
/// 以后每加一个新源都要回来补一次 —— 漏补的症状是"新源的图突然变糊"，
/// 而且只在放大时才看得出来。
const Set<String> kReaderComicSourceKeys = <String>{
  'picacg',
  'ehentai',
  'jm',
  'hitomi',
  'htmanga',
  'nhentai',
  'copy_manga',
  // 下载侧写入的是 `'Komiic'`（首字母大写），这里按小写比较。
  'komiic',
};

/// 这次阅读算不算「漫画」（决定用哪个开关）。
///
/// 比较前统一小写去空白：来源标识不是枚举，写入侧大小写不一致
/// （Komiic 写 `'Komiic'`、注册表用 `'komiic'`）。
bool readerReadingIsComic(String sourceKey) =>
    kReaderComicSourceKeys.contains(sourceKey.trim().toLowerCase());

/// 本次阅读是否该走高清（跳过我方降采样）。
///
/// 纯函数：设置值由调用方传入，便于直接单测 —— 这条判据一旦写反
/// （比如把两个开关的默认方向搞混），症状只是"某类内容糊/卡"，
/// 不会报错。
bool readerHighQualityEnabled({
  required String sourceKey,
  required String comicSetting,
  required String illustSetting,
}) {
  if (readerReadingIsComic(sourceKey)) {
    return normalizeReaderHighQualityComic(comicSetting) == '1';
  }
  return normalizeReaderHighQualityIllust(illustSetting) == '1';
}
