import 'dart:ffi';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/local_data_source.dart';

void main() {
  setUpAll(() {
    if (Platform.isWindows) {
      open.overrideFor(
          OperatingSystem.windows,
          () => DynamicLibrary.open(
              '${Directory.current.path}/windows/sqlite3.dll'));
    }
  });
  tearDown(() => setManagedDataSourceMode(managedDataSourceModeCurrentOnly));
  for (final count in [0, 1000, 10000]) {
    test('single history query uses primary key at $count rows', () {
      final db = sqlite3.openInMemory();
      final manager = HistoryManager.withDatabasesForTesting(db);
      db.execute('BEGIN');
      for (var i = 0; i < count; i++) {
        db.execute('INSERT INTO history VALUES(?,?,?,?,?,?,?,?,?,?)',
            ['target$i', 'title', 'author', 'cover', i, 0, 1, 5, '', 10]);
      }
      db.execute('COMMIT');
      final calls = <String>[];
      manager.onLookupForTesting = (sql, parameters) {
        calls.add(sql);
        expect(sql, contains('where target == ?'));
        expect(parameters, ['target${count - 1}']);
      };
      final found = manager.findSync('target${count - 1}');
      expect(found != null, count > 0);
      expect(calls.length, 1);
      expect(
          db
              .select(
                  'EXPLAIN QUERY PLAN select * from history where target == ?',
                  ['target0'])
              .single['detail']
              .toString(),
          contains('INDEX'));
      manager.dispose();
    });
  }
  test(
      'primary precedence and secondary fallback preserve progress, hidden source stays hidden',
      () {
    final primary = sqlite3.openInMemory(), secondary = sqlite3.openInMemory();
    final manager =
        HistoryManager.withDatabasesForTesting(primary, secondary: secondary);
    for (final pair in [(primary, 5), (secondary, 9)]) {
      pair.$1.execute('INSERT INTO history VALUES(?,?,?,?,?,?,?,?,?,?)',
          ['same', 'title', '', '', pair.$2, 0, 1, pair.$2, '', 10]);
    }
    secondary.execute('INSERT INTO history VALUES(?,?,?,?,?,?,?,?,?,?)',
        ['secondary', 'title', '', '', 1, 0, 1, 7, '', 10]);
    var calls = 0;
    manager.onLookupForTesting = (_, __) {
      calls++;
    };
    expect(manager.find('same')!.page, 5);
    expect(calls, 1);
    calls = 0;
    expect(manager.find('secondary')!.page, 7);
    expect(calls, 2);
    calls = 0;
    expect(manager.find('local_download::original_download::hidden'), isNull);
    expect(calls, 0);
    manager.dispose();
  });
  test('uninitialized lookup remains null', () {
    expect(HistoryManager.create().findSync('anything'), isNull);
  });
}
