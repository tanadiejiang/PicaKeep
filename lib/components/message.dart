part of 'components.dart';

void hideAllMessages() {}

void showToast({required String message, Widget? icon, Widget? trailing}) {}

class ContentDialog extends StatelessWidget {
  const ContentDialog({
    super.key,
    required this.title,
    required this.content,
    this.actions = const [],
  });

  final String title;

  final Widget content;

  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: IntrinsicWidth(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 16),
            Text(title,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            content,
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: actions,
            ).paddingRight(12),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
