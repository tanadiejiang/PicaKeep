import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/ai/ai_download_queue.dart';
import 'package:picakeep/foundation/ai/ai_result_item.dart';
import 'package:picakeep/foundation/app.dart';

AiResultItem _item(String source, String id) => AiResultItem(
      id: id,
      title: 'title-$id',
      author: 'author',
      coverUrl: '',
      source: source,
      tags: const [],
      availability: const {},
    );

void main() {
  late Directory tempDir;

  setUpAll(() {
    tempDir = Directory.systemTemp.createTempSync('ai_download_queue_test');
    App.dataPath = tempDir.path;
  });

  tearDownAll(() {
    tempDir.deleteSync(recursive: true);
  });

  setUp(() {
    AiDownloadQueue.instance.clear();
  });

  group('AiDownloadQueue.addItems 过滤非法 source', () {
    test('source 非法或为空的条目不会入队，且计入跳过数', () async {
      final skipped = await AiDownloadQueue.instance.addItems([
        _item('picacg', '1'),
        _item('', '2'),
        _item('not-a-source', '3'),
      ]);

      expect(skipped, 2);
      expect(AiDownloadQueue.instance.items.length, 1);
      expect(AiDownloadQueue.instance.items.single.source, 'picacg');
    });

    test('合法 source 全部正常入队，跳过数为 0', () async {
      final skipped = await AiDownloadQueue.instance.addItems([
        _item('picacg', '1'),
        _item('jm', '2'),
        _item('ehentai', '3'),
        _item('nhentai', '4'),
      ]);

      expect(skipped, 0);
      expect(AiDownloadQueue.instance.items.length, 4);
    });

    test('重复的 source:id 组合会被去重跳过', () async {
      await AiDownloadQueue.instance.addItems([_item('picacg', '1')]);
      final skipped = await AiDownloadQueue.instance.addItems([
        _item('picacg', '1'),
        _item('picacg', '2'),
      ]);

      expect(skipped, 1);
      expect(AiDownloadQueue.instance.items.length, 2);
    });
  });

  group('AiDownloadQueue.removeAll 批量移除', () {
    test('批量移除选中条目，未选中条目保留', () async {
      await AiDownloadQueue.instance.addItems([
        _item('picacg', '1'),
        _item('jm', '2'),
        _item('ehentai', '3'),
      ]);

      await AiDownloadQueue.instance.removeAll([
        _item('picacg', '1'),
        _item('ehentai', '3'),
      ]);

      expect(AiDownloadQueue.instance.items.length, 1);
      expect(AiDownloadQueue.instance.items.single.source, 'jm');
    });

    test('空列表调用不触发保存/通知，队列不变', () async {
      await AiDownloadQueue.instance.addItems([_item('picacg', '1')]);
      await AiDownloadQueue.instance.removeAll([]);
      expect(AiDownloadQueue.instance.items.length, 1);
    });

    test('传入队列中不存在的条目不影响现有条目', () async {
      await AiDownloadQueue.instance.addItems([_item('picacg', '1')]);
      await AiDownloadQueue.instance.removeAll([_item('jm', '999')]);
      expect(AiDownloadQueue.instance.items.length, 1);
    });
  });
}
