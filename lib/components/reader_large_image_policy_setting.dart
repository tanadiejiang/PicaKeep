import 'package:flutter/material.dart';
import 'package:picakeep/foundation/reader_image_quality.dart';
import 'package:picakeep/tools/translations.dart';

/// Shared presentation only. The hosts own persistence and reader refresh.
class ReaderLargeImagePolicySetting extends StatelessWidget {
  const ReaderLargeImagePolicySetting({
    super.key,
    required this.value,
    required this.onChanged,
    this.leading,
  });

  final ReaderLargeImagePolicy value;
  final ValueChanged<ReaderLargeImagePolicy> onChanged;
  final Widget? leading;

  static const title = '清晰优先·超大图处理';
  static const scope = '仅对清晰优先生效；预览优先时也可预先设置。原文件不变。';

  static String label(ReaderLargeImagePolicy policy) => switch (policy) {
        ReaderLargeImagePolicy.safeWhole => '安全整图显示',
        ReaderLargeImagePolicy.strictOriginal => '严格原尺寸',
      };

  static String description(ReaderLargeImagePolicy policy) => switch (policy) {
        ReaderLargeImagePolicy.safeWhole => '优先显示完整图片；超出设备能力时降低显示分辨率，不修改原文件。',
        ReaderLargeImagePolicy.strictOriginal =>
          '保持原始显示分辨率；超限时提示无法显示，不自动降低清晰度。',
      };

  Future<void> _choose(BuildContext context) async {
    final selected = await showDialog<ReaderLargeImagePolicy>(
      context: context,
      useSafeArea: true,
      builder: (context) => AlertDialog(
        title: Text(title.tl),
        scrollable: true,
        contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(scope.tl),
            ),
            const SizedBox(height: 8),
            RadioGroup<ReaderLargeImagePolicy>(
              groupValue: value,
              onChanged: (policy) {
                if (policy != null) Navigator.of(context).pop(policy);
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final policy in ReaderLargeImagePolicy.values)
                    ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: RadioListTile<ReaderLargeImagePolicy>(
                        value: policy,
                        title: Text(label(policy).tl),
                        subtitle: Text(description(policy).tl),
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 8),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('取消'.tl),
          ),
        ],
      ),
    );
    if (context.mounted && selected != null && selected != value) {
      onChanged(selected);
    }
  }

  @override
  Widget build(BuildContext context) => ListTile(
        leading: leading,
        title: Text(title.tl),
        subtitle: Text('${label(value).tl}\n${scope.tl}'),
        trailing: const Icon(Icons.chevron_right),
        minTileHeight: 48,
        onTap: () => _choose(context),
      );
}
