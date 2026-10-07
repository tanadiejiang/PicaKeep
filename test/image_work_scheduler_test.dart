import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/reader_viewport.dart';
import 'package:flutter/painting.dart';

void main() {
  test('shared consumers cancel independently and reserve once', () async {
    final queue = ImageWorkScheduler(memoryBudgetBytes: 100);
    final gate = Completer<int>();
    var starts = 0;
    Future<int> work(ImageWorkCancellation _) {
      starts++;
      return gate.future;
    }

    final a = queue.submit(
        key: 'page',
        priority: ImageWorkPriority.visible,
        estimatedBytes: 60,
        run: work);
    final b = queue.submit(
        key: 'page',
        priority: ImageWorkPriority.visible,
        estimatedBytes: 60,
        run: work);
    final cancelled = expectLater(a.future, throwsA(isA<ImageWorkCancelled>()));
    await Future<void>.delayed(Duration.zero);
    expect(queue.reservedBytes, 60);
    a.cancel();
    gate.complete(3);
    await cancelled;
    expect(await b.future, 3);
    await Future<void>.delayed(Duration.zero);
    expect(starts, 1);
    expect(queue.reservedBytes, 0);
  });

  test('queued visible work precedes background and failures release budget',
      () async {
    final queue = ImageWorkScheduler(maxConcurrent: 1, memoryBudgetBytes: 100);
    final order = <String>[];
    queue.pauseBackground(true);
    final background = queue.submit(
        key: 'background',
        priority: ImageWorkPriority.background,
        estimatedBytes: 70,
        run: (_) async {
          order.add('background');
          return 2;
        });
    final visible = queue.submit<int>(
        key: 'visible',
        priority: ImageWorkPriority.visible,
        estimatedBytes: 80,
        run: (_) async {
          order.add('visible');
          throw StateError('bad stream');
        });
    await expectLater(visible.future, throwsStateError);
    expect(queue.reservedBytes, 0);
    queue.pauseBackground(false);
    expect(await background.future, 2);
    expect(order, ['visible', 'background']);
  });

  test('oversized tasks fail before starting rather than waiting forever',
      () async {
    final queue = ImageWorkScheduler(memoryBudgetBytes: 100);
    var started = false;
    final ticket = queue.submit<int>(
        key: 'giant',
        priority: ImageWorkPriority.visible,
        estimatedBytes: 101,
        run: (_) async {
          started = true;
          return 1;
        });
    await expectLater(ticket.future, throwsA(isA<ImageWorkBudgetExceeded>()));
    expect(started, isFalse);
  });

  test('viewport density increases to native pixels and clips edge tiles', () {
    const fit = ReaderViewportDemand(
        visibleSourceRect: Rect.fromLTWH(0, 0, 8000, 12000),
        physicalPixelsPerSourcePixel: 0.2);
    expect(fit.density, 0.25);
    const zoom = ReaderViewportDemand(
        visibleSourceRect: Rect.fromLTWH(7500, 11500, 1000, 1000),
        physicalPixelsPerSourcePixel: 2);
    final tiles = zoom.tiles(const Size(8000, 12000));
    expect(zoom.density, 1);
    expect(tiles, isNotEmpty);
    expect(
        tiles.every(
            (t) => t.sourceRect.right <= 8000 && t.sourceRect.bottom <= 12000),
        isTrue);
    expect(tiles.every((t) => t.outputWidth <= 512 && t.outputHeight <= 512),
        isTrue);
  });
  test('network readers can await server execution without consuming its slots',
      () async {
    final queue = ImageWorkScheduler(
        maxConcurrent: 1, maxNetworkConcurrent: 2, memoryBudgetBytes: 100);
    var maximumReserved = 0;
    final readers = List.generate(
        2,
        (index) => queue.submit<int>(
            key: 'http-$index',
            lane: ImageWorkLane.network,
            priority: ImageWorkPriority.visible,
            estimatedBytes: 20,
            run: (_) async {
              final server = queue.submit<int>(
                  key: 'server-$index',
                  servesNetwork: true,
                  priority: ImageWorkPriority.visible,
                  estimatedBytes: 50,
                  run: (_) async {
                    maximumReserved = queue.reservedBytes;
                    expect(queue.activeExecutionCount, 1);
                    expect(queue.activeNetworkCount, 2);
                    await Future<void>.delayed(Duration.zero);
                    return index;
                  });
              return server.future;
            }));
    expect(await Future.wait(readers.map((ticket) => ticket.future)), [0, 1]);
    await Future<void>.delayed(Duration.zero);
    expect(maximumReserved, 90);
    expect(queue.reservedBytes, 0);
    expect(queue.activeCount, 0);
    expect(queue.pendingCount, 0);
  });

  test(
      'a server dependency exceeding remaining aggregate memory fails instead of deadlocking',
      () async {
    final queue = ImageWorkScheduler(memoryBudgetBytes: 100);
    final reader = queue.submit<int>(
        key: 'reader',
        lane: ImageWorkLane.network,
        priority: ImageWorkPriority.visible,
        estimatedBytes: 60,
        run: (_) => queue
            .submit<int>(
                key: 'server',
                servesNetwork: true,
                priority: ImageWorkPriority.visible,
                estimatedBytes: 50,
                run: (_) async => 1)
            .future);
    await expectLater(
        reader.future,
        throwsA(isA<ImageWorkBudgetExceeded>().having(
            (error) => error.budgetBytes, 'remaining aggregate budget', 40)));
    await Future<void>.delayed(Duration.zero);
    expect(queue.pendingCount, 0);
    expect(queue.reservedBytes, 0);
  });

  test('fitting server dependency bypasses a blocked ordinary foreground head',
      () async {
    final queue = ImageWorkScheduler(
        maxConcurrent: 1, maxNetworkConcurrent: 1, memoryBudgetBytes: 100);
    final ready = Completer<void>();
    final response = Completer<int>();
    final reader = queue.submit<int>(
        key: 'reader',
        lane: ImageWorkLane.network,
        priority: ImageWorkPriority.visible,
        estimatedBytes: 60,
        run: (_) async {
          ready.complete();
          return response.future;
        });
    await ready.future;
    final ordinary = queue.submit<int>(
        key: 'ordinary-head',
        priority: ImageWorkPriority.visible,
        estimatedBytes: 50,
        run: (_) async => 2);
    final server = queue.submit<int>(
        key: 'server-dependency',
        servesNetwork: true,
        priority: ImageWorkPriority.visible,
        estimatedBytes: 20,
        run: (_) async => 3);
    response.complete(await server.future.timeout(const Duration(seconds: 1)));
    expect(await reader.future, 3);
    expect(await ordinary.future, 2);
    expect(queue.reservedBytes, 0);
  });

  test('network cancellation and independent queues remain bounded and recover',
      () async {
    final queue = ImageWorkScheduler(
        maxConcurrent: 1,
        maxNetworkConcurrent: 1,
        maxNetworkPending: 2,
        maxExecutionPending: 2,
        memoryBudgetBytes: 100);
    final release = Completer<void>();
    final running = queue.submit<int>(
        key: 'network-running',
        lane: ImageWorkLane.network,
        priority: ImageWorkPriority.visible,
        estimatedBytes: 10,
        run: (cancel) async {
          await cancel.cancelled;
          await release.future;
          return 1;
        });
    final cancelled =
        expectLater(running.future, throwsA(isA<ImageWorkCancelled>()));
    final queued = queue.submit<int>(
        key: 'network-queued',
        lane: ImageWorkLane.network,
        priority: ImageWorkPriority.visible,
        estimatedBytes: 10,
        run: (_) async => 2);
    final excess = queue.submit<int>(
        key: 'network-excess',
        lane: ImageWorkLane.network,
        priority: ImageWorkPriority.visible,
        estimatedBytes: 10,
        run: (_) async => 3);
    await expectLater(excess.future, throwsA(isA<ImageWorkQueueExceeded>()));
    await Future<void>.delayed(Duration.zero);
    running.cancel();
    await cancelled;
    // Cancellation does not free memory while underlying response cleanup runs.
    expect(queue.reservedBytes, 10);
    expect(queue.activeNetworkCount, 1);
    final execution = queue.submit<int>(
        key: 'execution',
        priority: ImageWorkPriority.visible,
        estimatedBytes: 20,
        run: (_) async => 4);
    expect(await execution.future, 4);
    release.complete();
    expect(await queued.future, 2);
    await Future<void>.delayed(Duration.zero);
    expect(queue.reservedBytes, 0);
    expect(queue.pendingCount, 0);
  });

  test(
      'foreground priority and background pause apply independently within network lane',
      () async {
    final queue =
        ImageWorkScheduler(maxNetworkConcurrent: 1, memoryBudgetBytes: 100);
    final order = <String>[];
    queue.pauseBackground(true);
    final background = queue.submit<int>(
        key: 'network-bg',
        lane: ImageWorkLane.network,
        priority: ImageWorkPriority.background,
        estimatedBytes: 20,
        run: (_) async {
          order.add('background');
          return 1;
        });
    final visible = queue.submit<int>(
        key: 'network-visible',
        lane: ImageWorkLane.network,
        priority: ImageWorkPriority.visible,
        estimatedBytes: 20,
        run: (_) async {
          order.add('visible');
          return 2;
        });
    expect(await visible.future, 2);
    expect(order, ['visible']);
    queue.pauseBackground(false);
    expect(await background.future, 1);
    expect(order, ['visible', 'background']);
    expect(queue.reservedBytes, 0);
  });
}
