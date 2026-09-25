import 'package:flutter/material.dart';

typedef ActionFunc = void Function();

enum ComicType {
  picacg,
  ehentai,
  jm,
  hitomi,
  htManga,
  htFavorite,
  nhentai,

  // 第十八轮新增：Pixiv（插画/漫画/Ugoira）与 Komiic（中文条漫，有章节）。
  // 二者都追加在 `other` 之前，保持 `other` 作为兜底项仍在末尾。
  pixiv,
  komiic,
  other;

  @override
  toString() => name;
}

const String webUA =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36";

//Define breakpoints for wide screen devices
const changePoint = 600;
const changePoint2 = 1300;

List<MaterialAccentColor> get colors => [
      Colors.redAccent,
      Colors.pinkAccent,
      Colors.purpleAccent,
      Colors.indigoAccent,
      Colors.blueAccent,
      Colors.cyanAccent,
      Colors.tealAccent,
      Colors.greenAccent,
      Colors.limeAccent,
      Colors.yellowAccent,
      Colors.amberAccent,
      Colors.orangeAccent,
    ];

const builtInSources = [
  "picacg",
  "ehentai",
  "jm",
  "hitomi",
  "htmanga",
  "nhentai",
  // 第十八轮新增在线源。注意 komiic 的历史遗留 sourceKey 在下载/历史/收藏
  // 侧写作大写 `'Komiic'`，这里登记的 `ComicSource.key` 用小写 `komiic`，
  // 两者之间的映射由下载/历史/收藏各自的分支负责（详见 04 号计划 §诊断结论）。
  "pixiv",
  "komiic"
];
