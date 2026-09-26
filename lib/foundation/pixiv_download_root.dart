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
  return configured.isEmpty ? defaultPixivDownloadPath() : configured;
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
String legacyPixivDownloadPath() =>
    '${App.dataPath}${Platform.pathSeparator}download';
