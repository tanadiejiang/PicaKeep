import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/components/components.dart';
import 'package:picakeep/pages/explore/explore_route_scope.dart';

class _Probe extends StatefulWidget {
  const _Probe({required this.onBuild, required this.onRestore});
  final VoidCallback onBuild;
  final VoidCallback onRestore;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> with ExploreRouteRestoreMixin<_Probe> {
  @override
  void onExploreRouteRestored() => widget.onRestore();

  @override
  Widget build(BuildContext context) {
    widget.onBuild();
    return const Center(child: Text('explore'));
  }
}

void main() {
  testWidgets('popup route changes never rebuild the subscribed explore page',
      (tester) async {
    final observer = NaviObserver();
    final navigator = GlobalKey<NavigatorState>();
    var builds = 0;
    var restores = 0;
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      navigatorObservers: [observer],
      home: ExploreRouteScope(
        observer: observer,
        child: _Probe(onBuild: () => builds++, onRestore: () => restores++),
      ),
    ));
    await tester.pumpAndSettle();
    final before = builds;
    showMenu<int>(
      context: tester.element(find.byType(_Probe)),
      position: const RelativeRect.fromLTRB(20, 30, 20, 30),
      items: const [PopupMenuItem(value: 0, child: Text('latest'))],
    );
    await tester.pumpAndSettle();
    expect(builds, before);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(builds, before);
    expect(restores, 0);

    // Both unnamed routes use identical const RouteSettings, so the route's
    // actual subtree identity must distinguish this from a popup dismissal.
    navigator.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('settings')),
    ));
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(restores, 1);
    expect(tester.takeException(), isNull);
  });
}
