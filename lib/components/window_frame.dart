import 'package:flutter/material.dart';
import 'package:picakeep/foundation/state_controller.dart';

void showSideBar(BuildContext context, Widget child, {String? title, bool useSurfaceTintColor = false, bool addTopPadding = false, double? width}) {
  if (title != null) {
    child = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        const Divider(height: 1),
        Expanded(child: child),
      ],
    );
  }
  showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: "Dismiss",
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (context, animation, secondaryAnimation) {
      return Align(
        alignment: Alignment.centerRight,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(CurvedAnimation(
            parent: animation,
            curve: Curves.easeOut,
          )),
          child: Material(
            elevation: 8,
            color: Theme.of(context).colorScheme.surface,
            surfaceTintColor: useSurfaceTintColor ? Theme.of(context).colorScheme.surfaceTint : null,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(12),
              bottomLeft: Radius.circular(12),
            ),
            child: SizedBox(
              width: width ?? 400,
              height: MediaQuery.of(context).size.height * 0.8,
              child: child,
            ),
          ),
        ),
      );
    },
  );
}

class WindowFrameController extends StateController {
  void setDarkTheme() {}
  void resetTheme() {}
  void hideWindowFrame() {}
  void showWindowFrame() {}
}
