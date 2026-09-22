/// 探索 Provider 的能力接口。纯 Dart：不导入 Flutter、`ComicSource`、`Res`。
library;

import 'package:picakeep/foundation/explore/explore_models.dart';

/// 单个源的探索能力。
///
/// 每个源适配器实现本接口，由 `ExploreRegistry` 统一分派。适配器内部负责：
/// 把 [ExploreRequest] 翻译成具体网络调用、解析响应、编解码续页句柄。
/// 页面不得绕过 Registry 直接调用网络单例。
abstract class ExploreProvider {
  /// 该源的探索能力描述（入口、选项、访问状态）。必须同步、不得发网络请求。
  ExploreSourceDescriptor get descriptor;

  /// 该源当前是否已登录。**每次读取都要反映实时状态**，不能在注册时拍快照。
  ///
  /// 这个值只用于"能不能发请求"的门槛判断；具体请求失败仍按真实响应归类。
  bool get isLoggedIn;

  /// 当前账号/站点的上下文指纹。
  ///
  /// 绑定层用它判定"身份或站点是否变了"：变了才失效列表与目录会话。
  /// 不得包含凭据本身（只用于内部比较，不写日志、不进公开 ID）。
  String get contextFingerprint;

  /// 分类目录。目录加载也走统一入口，禁止页面自带网络旁路。
  Future<ExploreResult<ExploreDirectory>> loadDirectory(
    ExploreRequest request,
  );

  /// 概览：返回若干可独立成功/失败的分区。
  Future<ExploreResult<ExploreOverview>> loadOverview(
    ExploreRequest request,
  );

  /// 普通列表 / 榜单 / 分类结果 / 分区更多，统一返回漫画页。
  Future<ExploreResult<ExploreComicPage>> loadComics(
    ExploreRequest request,
  );
}

/// 生成续页句柄 / 解析续页句柄的编解码接缝。
///
/// 实现方（Registry）负责把句柄绑定到 sessionId、源、入口、选项与分类，
/// 使旧 token 能明确返回 [ExploreErrorCode.expiredContinuation]，
/// 而不是静默跳回第一页。
abstract class ExploreContinuationCodec {
  /// 编码续页句柄。返回的字符串必须可序列化且不含凭据。
  String encode(ExploreContinuationToken token);

  /// 解码续页句柄；结构损坏返回 `null`。
  ExploreContinuationToken? decode(String raw);
}

/// 续页句柄的规范化内容。
class ExploreContinuationToken {
  const ExploreContinuationToken({
    required this.sessionId,
    required this.sourceKey,
    required this.entryId,
    required this.optionKey,
    required this.categoryKey,
    required this.cursor,
  });

  final String sessionId;
  final String sourceKey;
  final String entryId;

  /// 规范化后的选项签名（空选项为 `''`）。
  final String optionKey;

  /// 规范化后的分类签名（无分类为 `''`）。
  final String categoryKey;

  /// 源自己使用的游标（页码、站点 next 链接游标等）。
  final String cursor;

  @override
  String toString() => 'ExploreContinuationToken($sourceKey/$entryId)';
}
