import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/pixiv_detail_session.dart';
import 'package:picakeep/pages/online_comic/pixiv_detail_pager.dart';

// Lifecycle/scroll fakes deliberately have no preview, network or App state.
// Actual PageView controller navigation, rather than directly calling its
// onPageChanged callback, exercises the sliver keep-alive bucket.
class _ProbeLog {
  final created = <String, int>{};
  final closed = <String, int>{};
  final live = <String, _ProbeState>{};
  var nextSerial = 0;
}

class _Probe extends StatefulWidget {
  const _Probe({super.key, required this.id, required this.log});

  final String id;
  final _ProbeLog log;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  final vertical = ScrollController();
  late final _ProbeLog _log;
  late final String id;
  late final int serial;
  var entryActive = false;
  var tickersEnabled = false;
  var memo = 0;

  @override
  void initState() {
    super.initState();
    // Capture the originating registry, so swapping a same-key session cannot
    // accidentally make an old instance count as a new session's instance.
    _log = widget.log;
    id = widget.id;
    serial = ++_log.nextSerial;
    _log.created.update(id, (count) => count + 1, ifAbsent: () => 1);
    _log.live[id] = this;
  }

  @override
  Widget build(BuildContext context) {
    entryActive = PixivDetailEntryScope.isActiveOf(context);
    tickersEnabled = TickerMode.valuesOf(context).enabled;
    return Scaffold(
      body: SingleChildScrollView(
        controller: vertical,
        child: SizedBox(
          height: 1800,
          width: double.infinity,
          child: Align(
            alignment: Alignment.topCenter,
            child: Text('$id#$serial:$entryActive:$tickersEnabled:$memo'),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _log.closed.update(id, (count) => count + 1, ifAbsent: () => 1);
    if (identical(_log.live[id], this)) _log.live.remove(id);
    vertical.dispose();
    super.dispose();
  }
}

PixivDetailSession _session(_ProbeLog log, {int count = 6}) =>
    PixivDetailSession(
      scope: PixivDetailScope.search,
      entries: [
        for (var index = 0; index < count; index++)
          PixivDetailEntry(
            key: 'work:$index',
            comicId: '$index',
            builder: (_) => _Probe(
              // Identical IDs/keys across sessions intentionally expose stale
              // reuse if the pager omits the session identity from its subtree.
              key: ValueKey('probe:$index'),
              id: '$index',
              log: log,
            ),
          ),
      ],
    );

Widget _app(PixivDetailSession session, {String initialKey = 'work:0'}) =>
    MaterialApp(
      home: PixivDetailPager(session: session, initialKey: initialKey),
    );

void _configureView(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

PageController _controller(WidgetTester tester) => tester
    .widget<PageView>(find.byKey(const Key('pixiv-work-pager')))
    .controller!;

Future<void> _jump(WidgetTester tester, int page) async {
  _controller(tester).jumpToPage(page);
  await tester.pumpAndSettle();
  expect(_controller(tester).page, closeTo(page.toDouble(), .001));
  expect(tester.takeException(), isNull);
}

void _expectActivity(_ProbeLog log, int current) {
  expect(
    log.live.values
        .where((state) => state.entryActive)
        .map((state) => state.id),
    ['$current'],
  );
  expect(
    log.live.values
        .where((state) => state.tickersEnabled)
        .map((state) => state.id),
    ['$current'],
  );
  expect(log.live.length, lessThanOrEqualTo(3));
  for (final id in log.live.keys) {
    expect((int.parse(id) - current).abs(), lessThanOrEqualTo(1));
  }
}

void main() {
  testWidgets('0 to 1 to 0 retains loaded state and the vertical position',
      (tester) async {
    _configureView(tester);
    final log = _ProbeLog();
    final session = _session(log);
    await tester.pumpWidget(_app(session));
    await tester.pumpAndSettle();
    final first = log.live['0']!;
    final position = first.vertical.position;
    first.memo = 47;
    first.vertical.jumpTo(312);
    await tester.pump();

    await _jump(tester, 1);
    expect(log.created, {'0': 1, '1': 1});
    expect(log.closed['0'] ?? 0, 0);
    expect(identical(log.live['0'], first), isTrue);
    _expectActivity(log, 1);

    await _jump(tester, 0);
    expect(log.created, {'0': 1, '1': 1});
    expect(log.closed, isEmpty);
    expect(identical(log.live['0'], first), isTrue);
    expect(first.memo, 47);
    expect(identical(first.vertical.position, position), isTrue);
    expect(first.vertical.offset, 312);
    _expectActivity(log, 0);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(log.live, isEmpty);
    expect(log.closed, log.created);
    session.dispose();
  });

  testWidgets('jump 0 to 3 evicts far state; return creates only one new state',
      (tester) async {
    _configureView(tester);
    final log = _ProbeLog();
    final session = _session(log);
    await tester.pumpWidget(_app(session));
    await tester.pumpAndSettle();
    final first = log.live['0']!;

    await _jump(tester, 3);
    expect(log.closed['0'], 1);
    expect(first.mounted, isFalse);
    expect(log.live.containsKey('0'), isFalse);
    _expectActivity(log, 3);

    await _jump(tester, 0);
    expect(log.created['0'], 2);
    expect(log.closed['0'], 1);
    expect(identical(log.live['0'], first), isFalse);
    expect(log.created['3'], 1);
    expect(log.closed['3'], 1);
    _expectActivity(log, 0);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(log.live, isEmpty);
    expect(log.closed, log.created);
    session.dispose();
  });

  testWidgets('walking many works retains at most the current plus neighbours',
      (tester) async {
    _configureView(tester);
    final log = _ProbeLog();
    final session = _session(log, count: 12);
    await tester.pumpWidget(_app(session));
    await tester.pumpAndSettle();

    for (var page = 1; page < 8; page++) {
      await _jump(tester, page);
      _expectActivity(log, page);
      if (page >= 2) {
        expect(log.live.containsKey('${page - 2}'), isFalse);
        expect(log.closed['${page - 2}'], 1);
      }
    }
    final seventh = log.live['7']!;
    await _jump(tester, 6);
    expect(log.created['6'], 1);
    _expectActivity(log, 6);
    await _jump(tester, 7);
    expect(identical(log.live['7'], seventh), isTrue);
    expect(log.created['7'], 1);
    _expectActivity(log, 7);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(log.live, isEmpty);
    expect(log.closed, log.created);
    session.dispose();
  });

  testWidgets('same-key replacement session clears old bucket and initial page',
      (tester) async {
    _configureView(tester);
    final oldLog = _ProbeLog();
    final oldSession = _session(oldLog);
    await tester.pumpWidget(_app(oldSession));
    await tester.pumpAndSettle();
    await _jump(tester, 1);
    expect(oldLog.live.keys, containsAll(['0', '1']));
    final previousController = _controller(tester);

    final newLog = _ProbeLog();
    final newSession = _session(newLog);
    await tester.pumpWidget(_app(newSession, initialKey: 'work:3'));
    await tester.pumpAndSettle();
    expect(identical(_controller(tester), previousController), isFalse);
    expect(_controller(tester).page, closeTo(3, .001));
    expect(oldLog.live, isEmpty);
    expect(oldLog.closed, oldLog.created);
    expect(newLog.created['3'], 1);
    _expectActivity(newLog, 3);
    expect(tester.takeException(), isNull);

    await _jump(tester, 4);
    await _jump(tester, 3);
    expect(newLog.created['3'], 1);
    _expectActivity(newLog, 3);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(newLog.live, isEmpty);
    expect(newLog.closed, newLog.created);
    oldSession.dispose();
    newSession.dispose();
  });
}
