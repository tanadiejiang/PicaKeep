import 'package:flutter/foundation.dart';

/// WebView 登录收尾的轮次状态机（EH / NH 登录页共用）。
///
/// 抽成独立小类的原因：这几条语义都是"只在特定时序下才出错"的，
/// 例如桌面标题是 2 秒轮询会重复触发、用户可能在采集过程中取消并立刻重开一轮。
/// 它们此前以散落的局部 bool 实现，无法直接验证。
///
/// 规则：
/// - 每次登录是一个**轮次**，带自增编号；旧轮次的任何回调一律丢弃；
/// - 一轮最多**提交一次**（标题重复触发不得重复写 Cookie/UA）；
/// - "已请求关闭"与"已提交"是**两个独立状态**，不能互相兼任；
/// - 网页关闭后迟到的采集**不得**再写 Cookie/UA/源文件。
class WebviewLoginRound {
  int _round = 0;
  bool _harvesting = false;
  bool _closeRequested = false;
  bool _committed = false;
  bool _closed = false;

  int get round => _round;
  bool get harvesting => _harvesting;
  bool get closeRequested => _closeRequested;
  bool get committed => _committed;
  bool get closed => _closed;

  /// 开始新一轮（打开网页前调用），返回本轮编号。
  int begin() {
    _harvesting = false;
    _closeRequested = false;
    _committed = false;
    _closed = false;
    return ++_round;
  }

  /// 该编号是否仍是当前轮次（迟到的 Future/onClose 据此丢弃）。
  bool isCurrent(int round) => round == _round;

  /// 是否接受本轮的一次采集。
  ///
  /// 必须是当前轮、未请求关闭、未提交，且没有正在进行的采集（避免并发重叠）。
  bool beginHarvest(int round) {
    if (!canAccept(round) || _harvesting) {
      return false;
    }
    _harvesting = true;
    return true;
  }

  /// 采集结束。写入前必须再判一次 [isCurrent] 与 [closeRequested]。
  void endHarvest() => _harvesting = false;

  bool canAccept(int round) =>
      isCurrent(round) && !_closed && !_closeRequested && !_committed;

  void markClosed() {
    _closed = true;
    _closeRequested = true;
  }

  /// 请求关闭本轮网页（幂等）。返回 true 表示这次真正发起了关闭，
  /// 调用方据此决定是否真的调用 `controller.close()`。
  bool requestClose() {
    if (_closeRequested || _committed) return false;
    _closeRequested = true;
    return true;
  }

  /// 收尾提交：同一轮只允许一次。
  bool beginCommit(int round) {
    if (!isCurrent(round) || _committed) return false;
    _committed = true;
    return true;
  }
}

/// 便于测试与调试：把状态机当前状态打成一行。
@visibleForTesting
String describeWebviewLoginRound(WebviewLoginRound round) =>
    'round=${round.round} harvesting=${round.harvesting} '
    'closeRequested=${round.closeRequested} committed=${round.committed}';
