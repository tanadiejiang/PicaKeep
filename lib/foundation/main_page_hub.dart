import 'package:flutter/material.dart';

import 'state_controller.dart';

/// Bridges the desktop title-bar quick menu to the tab [Navigator] in [MainPage].
class MainPageHub extends StateController {
  void Function(Widget Function() page)? pushPage;

  void openPage(Widget Function() page) => pushPage?.call(page);
}
