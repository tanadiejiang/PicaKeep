/// Pixiv 下载根的**默认位置**与**生效值**解析（36 号）。
///
/// ## 背景
///
/// 用户反馈：Pixiv 下载的内容"裸露"在「本应用下载目录」（`files/download`）里，
/// 与其它来源的作品混在一层。要求**在 `download` 同级放一个 `download_pixiv`**。
///
/// 机制本来就有 —— `settings[152]`（`pixivDownloadDir`）是一个**独立的下载根**，
/// 只是它默认是空串（= 跟随 `download`）。本文件把"空"的语义从
/// **"跟随 `download`"改成"用同级的 `download_pixiv`"**，于是新下载自动分开，
/// 不需要用户手动配置。
///
/// ## 一处定义、两边必须同时用
///
/// 下载根在项目里有**两个消费者**，少接任何一个的症状都是
/// 「下载成功、但列表里一条都看不到」（不报错，最难排查）：
/// - **写入侧**：`online_download_manager._runPixivTask` 决定落盘到哪；
/// - **读取侧**：`_effectiveDownloadRoots()`（已下载列表）与
///   `configuredPixivDownloadPath`（本地扫描的 `pixiv_download` 源）。
///
/// 所以两条路径都必须走 [effectivePixivDownloadRoot]，**不要各自读 `settings[152]`**。
library;

import 'dart:io' show Platform;
import 'pixiv_library_locations.dart';

import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/pixiv_download_naming.dart';

/// Pixiv 专属下载目录的**默认目录名**（与 `download` 同级）。
const String kDefaultPixivDownloadDirName = 'download_pixiv';

/// Pixiv 下载的默认根：`<应用数据目录>/download_pixiv`。
///
/// 与「本应用下载目录」`<应用数据目录>/download` **同级**（用户明确要求）。
String defaultPixivDownloadPath() =>
    '${App.dataPath}${Platform.pathSeparator}$kDefaultPixivDownloadDirName';

/// 当前**生效**的 Pixiv 下载根。
///
/// `settings[152]` 非空时以它为准（用户显式指定过位置，必须尊重）；
/// 为空时回落到 [defaultPixivDownloadPath]。
String effectivePixivDownloadRoot() {
  final configured = appdata.settings[pixivDownloadDirSettingIndex].trim();
  return resolvePixivLibraryRoot(configured.isEmpty ? defaultPixivDownloadPath() : configured);
}

/// `settings[152]` 是否仍是空值（即"用默认位置"）。
///
/// UI 用它决定显示"默认位置"还是"用户指定的位置"，也用于判断要不要提供迁移入口。
bool pixivDownloadRootIsDefault() =>
    appdata.settings[pixivDownloadDirSettingIndex].trim().isEmpty;

/// Pixiv 内容**过去**可能落盘的位置：`<应用数据目录>/download`。
///
/// 36 号之前 Pixiv 跟随默认下载根，所以老内容都在这里。迁移功能需要它作为源。
/// 注意它**不等于** `settings[22]`（那是用户自定义的"本应用下载目录"）——
/// 老 Pixiv 内容只会落在默认根，不会落在用户后来改的自定义根里。
///
/// ⚠️ **下面这条"只会落在默认根"的假设已被真机推翻** ——
/// 归位时必须用 [pixivRelocationSourceRoots] 而不是只用本函数，原因见它的注释。
String legacyPixivDownloadPath() =>
    '${App.dataPath}${Platform.pathSeparator}download';

/// 「归位 Pixiv 内容」要检查的**源根**清单。
///
/// ## 为什么不能只盯着 [legacyPixivDownloadPath]
///
/// 上面那条注释里的假设 —— "老 Pixiv 内容只会落在默认根，不会落在用户后来改的
/// 自定义根里" —— **在真机上不成立**（43 号续，用户反馈"pixiv 怎么还是丢在这里"）：
///
/// 1. 用户在下载目录**还是默认根**时下载了 Pixiv；
/// 2. **之后**把下载目录改到自定义位置（`settings[22]`）；
/// 3. 而"换下载目录"的内容迁移会**把 Pixiv 内容一起搬过去** ——
///    它按"顶层条目"搬、**不区分来源**，于是 Pixiv 躺进了 `settings[22]`；
/// 4. 迁移入口只看默认根 ⇒ **永远数不到、也搬不走**。
///
/// 所以候选源根 = 默认根 ∪ `settings[22]` ∪ **Pixiv 的默认位置**
/// ∪ `settings[22]`，再**去掉当前生效的 Pixiv 根**
///（不把自己当归位源，否则会自己搬自己）。
///
/// 为什么要带上 [defaultPixivDownloadPath]：它是 `settings[152]` **为空时**的生效根。
/// 用户一旦把它设成别处，**之前落在默认位置的那些就扫描不到了** ——
/// 它们既不属于当前下载目录、也不属于新的 Pixiv 根，表现为"文件还在、
/// 但哪个页面都看不见"（真机实证：`files/download_pixiv` 里躺着 3 张）。
List<String> pixivRelocationSourceRoots() {
  final target = effectivePixivDownloadRoot();
  final roots = <String>{
    legacyPixivDownloadPath(),
    defaultPixivDownloadPath(),
  };
  final current = appdata.settings[22].trim();
  if (current.isNotEmpty) {
    roots.add(current);
  }
  roots.removeWhere((root) => root.trim().isEmpty || root == target);
  return roots.toList();
}
