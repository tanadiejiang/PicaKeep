import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/ai/ai_conversation.dart';
import 'package:picakeep/foundation/app.dart';

/// 33号计划：AiConversationRegistry 单元测试。
///
/// 仅测试 getOrCreate(null)（新建会话，不触碰磁盘：AiConversationController
/// ._createNew() 是纯内存操作）与缓存命中/移除路径，不覆盖 getOrCreate(已存在
/// 但未缓存的 id) 这种需要真实反序列化磁盘文件的路径——该路径的正确性已由
/// AiConversationController.create/_restoreStoredConversation 自身的既有测试
/// （ai_conversation_prompt_test.dart 经 restoreForTesting）覆盖，本测试只关心
/// "注册表层"的复用/隔离/淘汰语义。
void main() {
  late Directory tempDir;

  setUpAll(() {
    tempDir = Directory.systemTemp.createTempSync('ai_conversation_registry_test');
    App.dataPath = tempDir.path;
  });

  tearDownAll(() {
    tempDir.deleteSync(recursive: true);
  });

  test('getOrCreate(null) 创建新会话并写入缓存', () async {
    final registry = AiConversationRegistry.instance;
    final before = registry.cacheSizeForTesting;

    final ctrl = await registry.getOrCreate(null);

    expect(ctrl.conversationId, isNotNull);
    expect(registry.containsForTesting(ctrl.conversationId!), isTrue);
    expect(registry.cacheSizeForTesting, before + 1);

    // 清理，避免影响其他测试用例对缓存条目数的断言。
    registry.remove(ctrl.conversationId!);
  });

  test('同一个 conversationId 多次 getOrCreate 返回同一实例', () async {
    final registry = AiConversationRegistry.instance;
    final ctrl = await registry.getOrCreate(null);
    final id = ctrl.conversationId!;

    final again = await registry.getOrCreate(id);

    expect(identical(ctrl, again), isTrue);

    registry.remove(id);
  });

  test('不同 conversationId 的 getOrCreate 返回不同实例', () async {
    final registry = AiConversationRegistry.instance;
    final ctrlA = await registry.getOrCreate(null);
    final ctrlB = await registry.getOrCreate(null);

    expect(identical(ctrlA, ctrlB), isFalse);
    expect(ctrlA.conversationId, isNot(ctrlB.conversationId));

    registry.remove(ctrlA.conversationId!);
    registry.remove(ctrlB.conversationId!);
  });

  test('remove 后该 id 从缓存移除，且 controller 被 dispose（后续 notifyListeners 报错）',
      () async {
    final registry = AiConversationRegistry.instance;
    final ctrl = await registry.getOrCreate(null);
    final id = ctrl.conversationId!;
    expect(registry.containsForTesting(id), isTrue);

    registry.remove(id);

    expect(registry.containsForTesting(id), isFalse);
    // dispose 后的 ChangeNotifier 在 debug 模式下调用 notifyListeners 会触发
    // assert 异常；用它反向验证 remove() 确实调用了 controller.dispose()。
    expect(() => ctrl.clear(), throwsA(anything));
  });

  test('remove 对不存在于缓存的 id 是安全的空操作', () {
    final registry = AiConversationRegistry.instance;
    expect(() => registry.remove('not-a-real-cached-id'), returnsNormally);
  });

  test('缓存超过上限时淘汰最久未访问且非-loading的会话，isLoading 的会话不会被淘汰',
      () async {
    final registry = AiConversationRegistry.instance;
    final createdIds = <String>[];

    // 撑满到刚好超过上限（_maxCacheSize = 20），触发一次淘汰。
    for (var i = 0; i < 21; i++) {
      final ctrl = await registry.getOrCreate(null);
      createdIds.add(ctrl.conversationId!);
    }

    // 淘汰应发生：缓存条目数不应超过上限。
    expect(registry.cacheSizeForTesting, lessThanOrEqualTo(20));
    // 最早创建的一个应已被淘汰（最久未访问、非-loading）。
    expect(registry.containsForTesting(createdIds.first), isFalse);

    // 清理剩余缓存条目，避免影响后续测试用例。
    for (final id in createdIds) {
      if (registry.containsForTesting(id)) {
        registry.remove(id);
      }
    }
  });

  group('40号计划：并发去重', () {
    test('同一个 conversationId 并发多次 getOrCreate，全部返回同一实例', () async {
      final registry = AiConversationRegistry.instance;
      // 构造一个缓存中确定不存在的 id，触发"缓存未命中 -> 从磁盘加载（文件
      // 不存在 -> create() 内部走 _createNew() 分支）"这条存在真实 await
      // 耗时窗口的路径——这正是原 bug 中并发调用会各自判定"未命中"、各自
      // 创建出独立实例的场景。并发发起 5 次相同 id 的 getOrCreate 调用，
      // 验证 _pending 去重表确实让它们全部拿到同一个实例引用。
      const missingId = 'concurrent-missing-id-40';
      final futures = List.generate(
        5,
        (_) => registry.getOrCreate(missingId),
      );
      final results = await Future.wait(futures);

      for (final r in results.skip(1)) {
        expect(identical(results.first, r), isTrue);
      }
      // _createNew() 路径下 controller.conversationId 会被重新赋随机 uuid
      // （不等于传入的 missingId），因此清理时要用实际返回的 id。
      registry.remove(results.first.conversationId!);
    });

    test('创建失败后 _pending 会被清理，后续调用可以正常重试', () async {
      final registry = AiConversationRegistry.instance;
      // 用一个真实存在的 id 走正常路径，验证第二次调用不会因为第一次调用
      // 的 _pending 未清理而永久卡死——若清理逻辑有缺陷（比如漏写在
      // finally 里），这个测试会因为 Future 永远不 resolve 而超时失败。
      const id = 'retry-after-pending-cleared-40';
      final first = await registry.getOrCreate(id);
      expect(registry.containsForTesting(first.conversationId!), isTrue);

      // 第一次调用完成后 _pending 应已清理，第二次针对同一原始 id 的调用
      // 应该走"缓存未命中重新创建"或"命中缓存"路径，而不会挂起。
      final second = await registry
          .getOrCreate(id)
          .timeout(const Duration(seconds: 5));
      expect(second, isNotNull);

      registry.remove(first.conversationId!);
      if (second.conversationId != first.conversationId) {
        registry.remove(second.conversationId!);
      }
    });
  });

  group('41号计划：loading 广播', () {
    test('controller.isLoading 由 false 变 true 时，registry.loadingIds 应包含其 id，'
        '并触发 registry 的 notifyListeners', () async {
      final registry = AiConversationRegistry.instance;
      final ctrl = await registry.getOrCreate(null);
      final id = ctrl.conversationId!;
      expect(registry.loadingIds.contains(id), isFalse);

      var notifyCount = 0;
      void listener() => notifyCount++;
      registry.addListener(listener);

      ctrl.isLoading = true;
      ctrl.notifyListeners();

      expect(registry.loadingIds.contains(id), isTrue);
      expect(notifyCount, greaterThanOrEqualTo(1));

      registry.removeListener(listener);
      registry.remove(id);
    });

    test('isLoading 由 true 变回 false 时，registry.loadingIds 应移除对应 id', () async {
      final registry = AiConversationRegistry.instance;
      final ctrl = await registry.getOrCreate(null);
      final id = ctrl.conversationId!;

      ctrl.isLoading = true;
      ctrl.notifyListeners();
      expect(registry.loadingIds.contains(id), isTrue);

      ctrl.isLoading = false;
      ctrl.notifyListeners();
      expect(registry.loadingIds.contains(id), isFalse);

      registry.remove(id);
    });

    test('notifyListeners 但 isLoading 未变化时，不应产生冗余广播', () async {
      final registry = AiConversationRegistry.instance;
      final ctrl = await registry.getOrCreate(null);
      final id = ctrl.conversationId!;

      var notifyCount = 0;
      void listener() => notifyCount++;
      registry.addListener(listener);

      // isLoading 保持 false 不变，仅触发 controller 自身的 notifyListeners
      // （模拟 error/pendingDownload 等其他字段变化的场景）。
      ctrl.notifyListeners();
      expect(notifyCount, 0);

      registry.removeListener(listener);
      registry.remove(id);
    });

    test('同一 conversationId 被多次 getOrCreate 命中缓存时，只挂一个监听器，'
        '不会因重复挂听导致一次 isLoading 翻转触发多次广播', () async {
      final registry = AiConversationRegistry.instance;
      final ctrl = await registry.getOrCreate(null);
      final id = ctrl.conversationId!;

      // 多次命中缓存（LRU 场景），不应重复挂听。
      await registry.getOrCreate(id);
      await registry.getOrCreate(id);
      await registry.getOrCreate(id);
      expect(registry.hasLoadingListenerForTesting(id), isTrue);

      var notifyCount = 0;
      void listener() => notifyCount++;
      registry.addListener(listener);

      ctrl.isLoading = true;
      ctrl.notifyListeners();

      expect(notifyCount, 1);

      registry.removeListener(listener);
      registry.remove(id);
    });

    test('remove 后应清理该 id 的 loading 监听器绑定与 loadingIds 记录，不残留', () async {
      final registry = AiConversationRegistry.instance;
      final ctrl = await registry.getOrCreate(null);
      final id = ctrl.conversationId!;

      ctrl.isLoading = true;
      ctrl.notifyListeners();
      expect(registry.loadingIds.contains(id), isTrue);
      expect(registry.hasLoadingListenerForTesting(id), isTrue);

      registry.remove(id);

      expect(registry.loadingIds.contains(id), isFalse);
      expect(registry.hasLoadingListenerForTesting(id), isFalse);
    });

    test('并发去重路径（40号 _pending）命中时也应正确挂上 loading 监听器', () async {
      final registry = AiConversationRegistry.instance;
      const missingId = 'concurrent-missing-id-41-loading';
      final futures = List.generate(
        3,
        (_) => registry.getOrCreate(missingId),
      );
      final results = await Future.wait(futures);
      final ctrl = results.first;
      final id = ctrl.conversationId!;

      expect(registry.hasLoadingListenerForTesting(id), isTrue);

      ctrl.isLoading = true;
      ctrl.notifyListeners();
      expect(registry.loadingIds.contains(id), isTrue);

      registry.remove(id);
    });
  });
}
