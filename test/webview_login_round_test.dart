import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/pages/online_comic/webview_login_round.dart';

/// A16：WebView 登录收尾的轮次语义。
///
/// 这些判定过去以散落的局部 bool 存在于两个登录页里（桌面标题是 2 秒轮询、
/// 会重复触发；用户可能在采集过程中取消并立刻重开一轮），无法直接验证。
/// 抽成 [WebviewLoginRound] 后在这里锁定语义。

void main() {
  test('A16 同轮最多提交一次（标题重复触发不再写 Cookie）', () {
    final round = WebviewLoginRound();
    final id = round.begin();

    expect(round.beginCommit(id), isTrue);
    expect(
      round.beginCommit(id),
      isFalse,
      reason: '桌面标题重复回调不得导致第二次提交',
    );
    expect(round.committed, isTrue);
  });

  test('A16 采集期间被取消：迟到结果必须丢弃', () {
    final round = WebviewLoginRound();
    final id = round.begin();

    expect(round.beginHarvest(id), isTrue);
    // 采集（await 抓 Cookie）期间用户取消
    round.requestClose();

    expect(
      round.isCurrent(id) && !round.closeRequested,
      isFalse,
      reason: '关闭后必须判定为不可写入，避免迟到的采集污染源状态',
    );
    round.endHarvest();
  });

  test('A16 取消后立即新一轮：旧轮次回调全部失效', () {
    final round = WebviewLoginRound();
    final first = round.begin();
    round.beginHarvest(first);
    round.requestClose();

    final second = round.begin();

    expect(round.isCurrent(first), isFalse);
    expect(round.beginHarvest(first), isFalse, reason: '旧轮次不得再采集');
    expect(round.beginCommit(first), isFalse, reason: '旧轮次不得提交');
    expect(round.isCurrent(second), isTrue);
    expect(
      round.closeRequested,
      isFalse,
      reason: '新一轮的关闭状态必须是干净的，否则会立刻被误判为已取消',
    );
    expect(round.beginHarvest(second), isTrue, reason: '新一轮应能正常开始采集');
  });

  test('A16 关窗请求幂等：只发起一次', () {
    final round = WebviewLoginRound();
    round.begin();

    expect(round.requestClose(), isTrue);
    expect(
      round.requestClose(),
      isFalse,
      reason: '重复请求不得再次调用 controller.close()',
    );
  });

  test('A16 重叠采集被拒绝（上一次还没结束）', () {
    final round = WebviewLoginRound();
    final id = round.begin();

    expect(round.beginHarvest(id), isTrue);
    expect(
      round.beginHarvest(id),
      isFalse,
      reason: '相邻两次标题回调重叠时，第二次不得进入采集',
    );

    round.endHarvest();
    expect(round.beginHarvest(id), isTrue, reason: '结束后应能再次采集');
  });

  test('A16 已提交后既不再采集也不再关窗', () {
    final round = WebviewLoginRound();
    final id = round.begin();
    round.beginCommit(id);

    expect(round.beginHarvest(id), isFalse);
    expect(round.requestClose(), isFalse);
    expect(
      describeWebviewLoginRound(round),
      contains('committed=true'),
      reason: '状态可打印，便于排查时序问题',
    );
  });
}
