/// 15轮03号计划（决策F/G）：OCR 客户端——图片转文字兜底。
///
/// 独立于 [LlmClient]（决策G）：`LlmClient.chat` 签名吃 `List<LlmMessage>`，
/// 而 LlmMessage 按决策A不承载 parts，视觉 OCR 需手拼 raw messages Map。
/// 网络样板（logDio/鉴权头/60s receiveTimeout/非 200 与空响应判定/DioException
/// 兜底）照抄 llm_client.dart；不需要 tools、tool_choice、usage 统计、参数白名单。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/ai/ai_attachments.dart';
import 'package:picakeep/foundation/ai/ai_settings.dart';
import 'package:picakeep/network/app_dio.dart';

/// OCR 识别结果：`text` 为识别出的文字（空字符串=图中无文字，非错误）；
/// `error` 非空表示识别失败。二者互斥。
class OcrResponse {
  final String? text;
  final String? error;
  const OcrResponse({this.text, this.error});
}

/// 从 appdata.settings[aiOcrConfigSettingIndex] 解析，全字段防御式读取
/// （jsonDecode 失败 / 非 Map / 键缺失 / 类型不符一律回退默认值，不抛异常）。
class AiOcrConfig {
  final bool enabled;
  final String type; // 'vision' | 'generic'，默认 'vision'
  final String template; // '' | 'umi' | 'paddle_hub' | 'paddlex'
  final String baseUrl; // vision: 拼 /chat/completions；generic: 完整端点不拼接
  final String apiKey; // vision: Bearer
  final String modelId; // vision
  final String authHeader; // generic，'Header名:值'，可空
  final String imageField; // generic，默认 'base64'
  final String imageEncoding; // 'b64' | 'b64_array' | 'data_uri'，默认 'b64'
  final Map<String, dynamic> extraBody; // generic，merge 到 body 根
  final String resultPath; // generic，简化 JSONPath

  const AiOcrConfig({
    required this.enabled,
    required this.type,
    required this.template,
    required this.baseUrl,
    required this.apiKey,
    required this.modelId,
    required this.authHeader,
    required this.imageField,
    required this.imageEncoding,
    required this.extraBody,
    required this.resultPath,
  });

  factory AiOcrConfig.fromSettings() {
    Object? decoded;
    try {
      decoded = jsonDecode(appdata.settings[aiOcrConfigSettingIndex]);
    } catch (_) {
      decoded = null;
    }
    final map = decoded is Map<String, dynamic>
        ? decoded
        : const <String, dynamic>{};
    final imageField = _readString(map, 'imageField');
    final imageEncoding = map['imageEncoding'];
    final extraBodyRaw = map['extraBody'];
    return AiOcrConfig(
      enabled: map['enabled'] == true,
      type: map['type'] == 'generic' ? 'generic' : 'vision',
      template: _readString(map, 'template'),
      baseUrl: _readString(map, 'baseUrl'),
      apiKey: _readString(map, 'apiKey'),
      modelId: _readString(map, 'modelId'),
      authHeader: _readString(map, 'authHeader'),
      imageField: imageField.isEmpty ? 'base64' : imageField,
      imageEncoding:
          const {'b64', 'b64_array', 'data_uri'}.contains(imageEncoding)
              ? imageEncoding as String
              : 'b64',
      extraBody: extraBodyRaw is Map
          ? extraBodyRaw.map((k, v) => MapEntry(k.toString(), v))
          : const <String, dynamic>{},
      resultPath: _readString(map, 'resultPath'),
    );
  }

  static String _readString(Map<String, dynamic> map, String key) {
    final value = map[key];
    return value is String ? value.trim() : '';
  }

  /// 配置是否可用：enabled 且（vision: baseUrl+apiKey+modelId 全非空 /
  /// generic: baseUrl+imageField+resultPath 全非空）。
  bool get usable {
    if (!enabled) return false;
    if (type == 'vision') {
      return baseUrl.isNotEmpty && apiKey.isNotEmpty && modelId.isNotEmpty;
    }
    return baseUrl.isNotEmpty && imageField.isNotEmpty && resultPath.isNotEmpty;
  }
}

/// 通用 OCR 业务码前置校验。返回 null 表示放行，非 null 表示应判定为失败/空结果。
/// 设计取舍：不为任何单一服务硬编码分支，只识别「顶层 code 是整数」这一广泛约定
/// （Umi-OCR: 100 成功 / 101 无文字 / 其他失败；多数自建 FastAPI 包装同构）。
/// 顶层无 code 键或 code 非整数 → 一律放行，退回纯取值路径判定，
/// 保持对 PaddleOCR hub（顶层 status 是字符串）等服务的兼容。
OcrResponse? checkGenericOcrBizCode(Map<String, dynamic> json) {
  final code = json['code'];
  if (code is! int) return null; // 无 code 约定 → 放行
  if (code == 100) return null; // 明确成功 → 放行
  if (code == 101) {
    // 图中无文字 → 空结果，非错误（不能把服务端的描述串当成识别出的文字）。
    return const OcrResponse(text: '');
  }
  final msg = json['message']?.toString().trim();
  return OcrResponse(
    error: 'OCR 服务返回错误码 $code'
        '${msg == null || msg.isEmpty ? '' : '：$msg'}',
  );
}

/// 简化 JSONPath 解析纯函数（可单测、不发网络）。
/// 语法：段用 '.' 分隔，每段为 `name`，可带零或多个 `[数字]` / `[*]` 后缀，
/// 例：`data`、`results[0][*].text`、`result.ocrResults[0].prunedResult.rec_texts[*]`。
/// `[*]` 对 List 逐元素展开并收集；叶子取 String（非 String 用 toString）。
/// 全部叶子 join('\n') 返回；路径取不到、中途类型不符或结果为空返回 null。
String? extractByOcrPath(Object? json, String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return null;
  final steps = _parseOcrPathSteps(trimmed);
  if (steps == null) return null;
  var nodes = <Object?>[json];
  for (final step in steps) {
    final next = <Object?>[];
    for (final node in nodes) {
      if (step.isWildcard) {
        if (node is! List) return null;
        next.addAll(node);
      } else if (step.index != null) {
        if (node is! List || step.index! < 0 || step.index! >= node.length) {
          return null;
        }
        next.add(node[step.index!]);
      } else {
        if (node is! Map || !node.containsKey(step.key)) return null;
        next.add(node[step.key]);
      }
    }
    nodes = next;
  }
  final leaves = <String>[];
  for (final node in nodes) {
    if (node == null) continue;
    leaves.add(node is String ? node : node.toString());
  }
  if (leaves.isEmpty) return null;
  final joined = leaves.join('\n');
  return joined.trim().isEmpty ? null : joined;
}

class _OcrPathStep {
  const _OcrPathStep.key(this.key)
      : index = null,
        isWildcard = false;
  const _OcrPathStep.index(this.index)
      : key = null,
        isWildcard = false;
  const _OcrPathStep.wildcard()
      : key = null,
        index = null,
        isWildcard = true;

  final String? key;
  final int? index;
  final bool isWildcard;
}

/// 把路径拆成线性步骤；语法非法返回 null。
List<_OcrPathStep>? _parseOcrPathSteps(String path) {
  final segmentPattern = RegExp(r'^([^\[\]]+)((?:\[(?:\d+|\*)\])*)$');
  final bracketPattern = RegExp(r'\[(\d+|\*)\]');
  final steps = <_OcrPathStep>[];
  for (final segment in path.split('.')) {
    final match = segmentPattern.firstMatch(segment);
    if (match == null) return null;
    steps.add(_OcrPathStep.key(match.group(1)!));
    for (final bracket in bracketPattern.allMatches(match.group(2)!)) {
      final token = bracket.group(1)!;
      if (token == '*') {
        steps.add(const _OcrPathStep.wildcard());
      } else {
        final index = int.tryParse(token);
        if (index == null) return null;
        steps.add(_OcrPathStep.index(index));
      }
    }
  }
  return steps.isEmpty ? null : steps;
}

/// OCR HTTP 客户端（纯静态方法）。
class OcrClient {
  OcrClient._();

  static const visionSystemPrompt =
      '你是一个 OCR 文字转写引擎。你唯一的任务是把图片中所有可见文字原样转写出来。'
      '规则：1. 只输出图中文字本身，禁止任何解释、前言、总结、markdown 标记或翻译；'
      '2. 按人眼阅读顺序输出（横排从上到下、从左到右；日文竖排从右到左），每行文字独占一行；'
      '3. 保留原文语言和标点，日文、英文不要翻译成中文；'
      '4. 无法辨认的字符用〓占位；'
      '5. 如果图片中没有任何文字，只输出 <NO_TEXT>。';

  /// 识别单张图（绝对路径）。按 [AiOcrConfig.type] 分发两分支。
  static Future<OcrResponse> recognize(String absoluteImagePath) async {
    final config = AiOcrConfig.fromSettings();
    if (!config.usable) {
      return const OcrResponse(error: 'OCR 接口未启用或未配置完整');
    }
    final file = File(absoluteImagePath);
    if (!await file.exists()) {
      return const OcrResponse(error: '图片文件不存在或已被清理');
    }
    final bytes = await file.readAsBytes();
    if (config.type == 'generic') {
      return _recognizeGeneric(config, bytes);
    }
    return _recognizeVision(config, bytes);
  }

  /// 视觉分支：OpenAI 兼容视觉模型当 OCR。endpoint 拼接与鉴权头同 LlmClient
  /// （llm_client.dart:264-266）；取 `choices[0].message.content`；
  /// `trim() == '<NO_TEXT>'` 视为空结果。
  static Future<OcrResponse> _recognizeVision(
      AiOcrConfig config, List<int> bytes) async {
    final mime = detectAiImageType(bytes).mime;
    final endpoint = config.baseUrl.endsWith('/chat/completions')
        ? config.baseUrl
        : '${config.baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions';
    final body = <String, dynamic>{
      'model': config.modelId,
      'temperature': 0,
      'messages': [
        {'role': 'system', 'content': visionSystemPrompt},
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': '转写这张图片中的全部文字。'},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:$mime;base64,${base64Encode(bytes)}'},
            },
          ],
        },
      ],
    };
    try {
      final dio = logDio();
      final response = await dio.post<Map<String, dynamic>>(
        endpoint,
        data: body,
        options: Options(
          headers: {
            'Authorization': 'Bearer ${config.apiKey}',
            'Content-Type': 'application/json',
          },
          receiveTimeout: const Duration(seconds: 60),
        ),
      );
      if (response.statusCode != 200) {
        return OcrResponse(
            error: 'HTTP ${response.statusCode}: ${response.statusMessage}');
      }
      final data = response.data;
      if (data == null) {
        return const OcrResponse(error: '响应为空');
      }
      final choices = data['choices'] as List<dynamic>?;
      if (choices == null || choices.isEmpty) {
        return const OcrResponse(error: '响应格式错误：缺少 choices');
      }
      final message = choices[0]['message'] as Map<String, dynamic>?;
      if (message == null) {
        return const OcrResponse(error: '响应格式错误：缺少 message');
      }
      final content = message['content']?.toString() ?? '';
      if (content.trim() == '<NO_TEXT>') {
        return const OcrResponse(text: '');
      }
      return OcrResponse(text: content);
    } on DioException catch (e) {
      return OcrResponse(error: e.message ?? 'Network error: $e');
    } catch (e) {
      return OcrResponse(error: '未知错误: $e');
    }
  }

  /// 通用分支：POST 到 `baseUrl` 原样（不做任何拼接）。
  /// 成功判定 = HTTP 200 + 业务码前置校验通过 + `extractByOcrPath` 非空。
  static Future<OcrResponse> _recognizeGeneric(
      AiOcrConfig config, List<int> bytes) async {
    final b64 = base64Encode(bytes);
    final Object imageValue = switch (config.imageEncoding) {
      'b64_array' => <String>[b64],
      'data_uri' => 'data:${detectAiImageType(bytes).mime};base64,$b64',
      _ => b64,
    };
    // 先浅拷贝 extraBody 再写图片字段（同名键以图片字段为准）。
    final body = <String, dynamic>{...config.extraBody};
    body[config.imageField] = imageValue;
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (config.authHeader.isNotEmpty) {
      final separator = config.authHeader.indexOf(':');
      if (separator > 0) {
        final headerName = config.authHeader.substring(0, separator).trim();
        final headerValue = config.authHeader.substring(separator + 1).trim();
        if (headerName.isNotEmpty) {
          headers[headerName] = headerValue;
        }
      }
    }
    try {
      final dio = logDio();
      final response = await dio.post<Map<String, dynamic>>(
        config.baseUrl,
        data: body,
        options: Options(
          headers: headers,
          receiveTimeout: const Duration(seconds: 60),
        ),
      );
      if (response.statusCode != 200) {
        return OcrResponse(
            error: 'HTTP ${response.statusCode}: ${response.statusMessage}');
      }
      final data = response.data;
      if (data == null) {
        return const OcrResponse(error: '响应为空');
      }
      // 决策F修订：先做业务码前置校验，避免把服务端错误描述当成识别文字。
      final bizCodeResult = checkGenericOcrBizCode(data);
      if (bizCodeResult != null) return bizCodeResult;
      final text = extractByOcrPath(data, config.resultPath);
      if (text == null) {
        return const OcrResponse(error: 'OCR 响应中按取值路径未取到文字');
      }
      return OcrResponse(text: text);
    } on DioException catch (e) {
      return OcrResponse(error: e.message ?? 'Network error: $e');
    } catch (e) {
      return OcrResponse(error: '未知错误: $e');
    }
  }
}
