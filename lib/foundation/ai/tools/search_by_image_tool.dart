import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:picakeep/network/cloudflare.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/network/soutubot_network/soutubot_network.dart';

import '../ai_tool.dart';

/// 以图搜源工具（15轮05号计划步骤 8）。
///
/// 模型只传图片引用 `image_ref`（turn_context.attachments 里的 ref，即 03 计划
/// 的附件相对路径）；ref → 绝对路径的白名单解析经
/// [AiToolExecutionContext.resolveAttachmentPath] 由 controller 注入，模型编造
/// 的任意路径一律解析失败——杜绝借工具读任意本地文件。
///
/// Cloudflare 过盾触发链：`passCloudflare` 此前全库零调用点（05 计划核实的
/// 事实），本工具是它的首次投产接线——命中 [CloudflareException] 时弹 webview
/// 让用户人工过盾，成功后整流程重试一次（`searchByImage` 每次现抓 m，重新调用
/// 即为「重新 GET 主页抠 m 起」的整流程重试）。桌面 DesktopWebview 分支用户
/// 手动关窗时 `onFinished` 永不回调，180 秒超时兜底防止工具轮挂死。
class SearchByImageTool extends AiTool {
  const SearchByImageTool();

  /// 图片体积上限：10MB（体积治理属 03 计划职责，此处只做兜底）。
  static const _maxImageBytes = 10 * 1024 * 1024;

  /// 默认展示阈值：≥15% 的条目纳入结果；<15% 进「隐藏池」。
  ///
  /// soutubot 站点前端 <30 隐藏、<15 基本无参考价值；本工具取 15 作为实际有
  /// 意义的最低线，让 15-29% 的弱匹配也能展示给用户自行判断（15轮08号计划）。
  static const _hideBelowSimilarity = 15;

  /// 最高分 <45 时提示结果可能不正确（阈值不随展示阈值变化）。
  static const _lowConfidenceBelow = 45;

  static const _cfFailureMessage =
      '以图搜源需要通过 Cloudflare 人机验证，本次未完成。请告知用户：稍后重试时会再次弹出验证窗口，'
      '完成验证即可；不要连续自动重试';

  @override
  String get name => 'search_by_image';

  @override
  String get description =>
      '以图搜源：对用户在对话中发送的图片（用 image_ref 引用）在 soutubot.moe 反向搜索，'
      '返回 nhentai/e-hentai 等来源的相似本子及相似度百分比。仅在用户发送了图片且要求搜图时调用。';

  @override
  Map<String, Object?> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'image_ref': {
            'type': 'string',
            'description': '要搜索的图片引用ID，取当前 turn_context.attachments[].ref',
          },
          'include_all_results': {
            'type': 'boolean',
            'description': '是否包含相似度 <15% 的超低置信结果。默认 false；'
                '用户明确要求"显示全部结果"时传 true。',
          },
        },
        'required': ['image_ref'],
      };

  @override
  Future<AiToolResult> execute(Map<String, dynamic> args) async {
    return executeWithContext(
      args,
      AiToolExecutionContext(
          operationId: 'ai-direct-${DateTime.now().microsecondsSinceEpoch}'),
    );
  }

  @override
  Future<AiToolResult> executeWithContext(
    Map<String, dynamic> args,
    AiToolExecutionContext context,
  ) async {
    final ref = args['image_ref']?.toString().trim() ?? '';
    if (ref.isEmpty) {
      return const AiToolResult.failure(
          'image_ref is required：请从 turn_context.attachments 中取 ref');
    }
    final resolver = context.resolveAttachmentPath;
    if (resolver == null) {
      return const AiToolResult.failure(
          '当前执行环境没有图片附件语境，无法搜图；请让用户在对话中发送图片后重试');
    }
    final path = resolver(ref);
    if (path == null) {
      return AiToolResult.failure(
          '图片引用 "$ref" 不存在或已过期，请让用户重新发送图片后再试');
    }
    final file = File(path);
    if (!await file.exists()) {
      return const AiToolResult.failure('该图片文件已被清理，请让用户重新发送图片');
    }
    if (await file.length() > _maxImageBytes) {
      return const AiToolResult.failure(
          '图片超过 10MB 上限，请让用户换一张更小的图片（如单页截图）再试');
    }
    final bytes = await file.readAsBytes();

    Res<SoutubotSearchResult> res;
    try {
      res = await SoutubotNetwork().searchByImage(bytes);
    } catch (e) {
      final cf = _asCloudflareException(e);
      if (cf == null) {
        return AiToolResult.failure('网络错误：$e。可提示用户检查网络后重试');
      }
      final passed = await _tryPassCloudflare(cf);
      if (!passed) {
        return const AiToolResult.failure(_cfFailureMessage);
      }
      // 过盾成功后整流程重试一次（UA/cookie 已更新）；重试仍 CF → 失败收口。
      try {
        res = await SoutubotNetwork().searchByImage(bytes);
      } catch (retryError) {
        if (_asCloudflareException(retryError) != null) {
          return const AiToolResult.failure(_cfFailureMessage);
        }
        return AiToolResult.failure('网络错误：$retryError。可提示用户检查网络后重试');
      }
    }

    if (res.error) {
      return _mapNetworkFailure(res.errorMessageWithoutNull);
    }

    return buildResult(
      res.data,
      includeAll: args['include_all_results'] == true,
    );
  }

  /// 条目过滤 → 工具结果的纯函数段（网络分支之外的全部业务语义）。
  ///
  /// 展示策略（15轮08号计划）：
  /// - `kept`：similarity ≥ 15 的条目，默认展示；
  /// - `hiddenItems`：similarity < 15 的隐藏池，两种情况下加入结果——
  ///   ① [includeAll]（用户主动要全部）；② `kept` 为空的 fallback（宁可给出
  ///   超低置信结果，也比「未找到」更有用）。
  ///
  /// `hidden_count` 只在「确实还有条目没给模型」时才 > 0：includeAll 与
  /// fallback 下全部条目都已展示，一律置 0，避免「另有 0 条」的错误提示。
  @visibleForTesting
  AiToolResult buildResult(
    SoutubotSearchResult result, {
    bool includeAll = false,
  }) {
    final allItems = result.items;
    final kept = allItems
        .where((item) => item.similarity >= _hideBelowSimilarity)
        .toList(growable: false);
    final hiddenItems = allItems
        .where((item) => item.similarity < _hideBelowSimilarity)
        .toList(growable: false);

    // fallback：阈值内为空且隐藏池非空 → 自动展示全部。
    final useFallback = kept.isEmpty && hiddenItems.isNotEmpty;
    final displayItems = (includeAll || useFallback) ? allItems : kept;
    final hiddenCount = (includeAll || useFallback) ? 0 : hiddenItems.length;

    if (displayItems.isEmpty) {
      // 搜索成功但无结果是正常业务态：success 空列表（failure 会诱导模型
      // 当作故障重试或道歉）；空 items 不会触发结果卡。
      return AiToolResult.success(
        {
          'items': const <Object?>[],
          'search_id': result.id,
          'hidden_count': 0,
        },
        '未找到任何相似结果。可建议用户换一张更清晰的漫画内页原图'
            '（避免截图边框、水印、封面裁切）再试',
      );
    }

    // displayItems 已确认非空，first 安全。
    var topSimilarity = displayItems.first.similarity;
    for (final item in displayItems) {
      if (item.similarity > topSimilarity) topSimilarity = item.similarity;
    }
    final lowConfidence = topSimilarity < _lowConfidenceBelow;

    String? message;
    if (useFallback) {
      message = '过滤阈值内无结果，已自动展示全部 ${displayItems.length} 条超低置信结果'
          '（最高相似度 ${_formatSimilarity(topSimilarity)}%，仅供参考，'
          '请告知用户结果可靠性极低）';
    } else if (lowConfidence) {
      message = '最高相似度仅 ${_formatSimilarity(topSimilarity)}%，结果可能不正确；'
          '向用户总结时必须说明这一点，不要断言就是该本子';
    }
    if (hiddenCount > 0) {
      final hint = '（另有 $hiddenCount 条相似度 <$_hideBelowSimilarity% 的'
          '超低置信结果已隐藏；若用户需要可传 include_all_results=true 重新调用）';
      message = message != null ? '$message $hint' : hint;
    }

    return AiToolResult.success(
      {
        'items': [for (final item in displayItems) item.toAiResultItemJson()],
        'top_similarity': topSimilarity,
        'low_confidence': lowConfidence,
        'search_id': result.id,
        'hidden_count': hiddenCount,
      },
      message,
    );
  }

  /// 网络层 Res.errorMessage → 引导模型正确应对的 failure（禁止裸异常字符串）。
  AiToolResult _mapNetworkFailure(String message) {
    if (message.contains('拒绝了请求')) {
      // 401/403 非质询：签名算法可能已变更。
      return const AiToolResult.failure(
          'soutubot 拒绝了请求，可能其接口签名已变更，该功能暂时不可用。请如实告知用户，不要重试');
    }
    if (message.startsWith('网络错误')) {
      return AiToolResult.failure('$message。可提示用户检查网络后重试');
    }
    // 'soutubot 返回错误：xxx'、m 解析失败、响应无法解析等——网络层措辞已是
    // 面向模型的引导性描述，原样透传。
    return AiToolResult.failure(message);
  }

  /// CF 质询三重判定（与网络层同一套写法：直接异常 / DioException 包裹 /
  /// 被字符串化的异常）。
  static CloudflareException? _asCloudflareException(Object e) {
    if (e is CloudflareException) return e;
    if (e is DioException && e.error is CloudflareException) {
      return e.error as CloudflareException;
    }
    return CloudflareException.fromString(e.toString());
  }

  /// 弹 webview 让用户人工过盾；180 秒超时兜底（桌面 DesktopWebview 分支
  /// 用户手动关窗时 onFinished 永不回调，无超时会把工具轮挂死；移动端
  /// App.globalTo 返回即回调；两端都不可用时 passCloudflare 只 showToast，
  /// 也靠超时路径兜住）。
  Future<bool> _tryPassCloudflare(CloudflareException e) async {
    final completer = Completer<void>();
    passCloudflare(e, () {
      if (!completer.isCompleted) completer.complete();
    });
    try {
      await completer.future.timeout(const Duration(seconds: 180));
      return true;
    } on TimeoutException {
      return false;
    }
  }

  static String _formatSimilarity(double value) {
    final formatted = value.toStringAsFixed(1);
    return formatted.endsWith('.0')
        ? formatted.substring(0, formatted.length - 2)
        : formatted;
  }
}
