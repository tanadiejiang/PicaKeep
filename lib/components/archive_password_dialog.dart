import 'package:flutter/material.dart';
import 'package:picakeep/foundation/archive/archive_errors.dart';
import 'package:picakeep/foundation/archive/archive_models.dart';
import 'package:picakeep/foundation/archive/archive_reading_service.dart';
import 'package:picakeep/tools/translations.dart';

Future<({String password, bool addToDefaults})?> showArchivePasswordDialog({
  required BuildContext context,
  required String archivePath,
  required String archiveFileName,
  required ArchiveFormat format,
  Future<bool> Function(String password)? onVerify,
  bool allowAddToDefaults = true,
}) {
  return showDialog<({String password, bool addToDefaults})>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ArchivePasswordDialog(
      archivePath: archivePath,
      archiveFileName: archiveFileName,
      format: format,
      onVerify: onVerify,
      allowAddToDefaults: allowAddToDefaults,
    ),
  );
}

class _ArchivePasswordDialog extends StatefulWidget {
  const _ArchivePasswordDialog({
    required this.archivePath,
    required this.archiveFileName,
    required this.format,
    this.onVerify,
    required this.allowAddToDefaults,
  });

  final String archivePath;
  final String archiveFileName;
  final ArchiveFormat format;
  final Future<bool> Function(String password)? onVerify;
  final bool allowAddToDefaults;

  @override
  State<_ArchivePasswordDialog> createState() => _ArchivePasswordDialogState();
}

class _ArchivePasswordDialogState extends State<_ArchivePasswordDialog> {
  final _controller = TextEditingController();
  bool _loading = false;
  String? _errorMessage;
  // After successful unlock: ask whether to add to defaults
  bool _showAddToDefaults = false;
  String? _unlockedPassword;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _tryUnlock() async {
    final password = _controller.text;
    if (password.isEmpty) return;
    setState(() {
      _loading = true;
      _errorMessage = null;
    });
    try {
      final verifier = widget.onVerify ??
          (String value) => ArchiveReadingService.instance
              .tryUnlock(widget.archivePath, value);
      final ok = await verifier(password);
      if (!mounted) return;
      if (ok) {
        _unlockedPassword = password;
        if (!widget.allowAddToDefaults) {
          Navigator.of(context).pop(
            (password: _unlockedPassword!, addToDefaults: false),
          );
          return;
        }
        setState(() {
          _loading = false;
          _showAddToDefaults = true;
        });
      } else {
        setState(() {
          _loading = false;
          _errorMessage = '密码错误或压缩包无法解密';
        });
      }
    } on ArchiveFailure catch (f) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorMessage = f.code == ArchiveErrorCode.unsupportedEncryption
            ? '当前压缩包加密方式暂不支持'
            : f.userMessage();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorMessage = '解锁失败，请重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_showAddToDefaults) {
      return AlertDialog(
        title: Text('解锁成功'.tl),
        content: Text('是否将该密码加入自动解密列表？'.tl),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(
              (password: _unlockedPassword!, addToDefaults: false),
            ),
            child: Text('不加入'.tl),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(
              (password: _unlockedPassword!, addToDefaults: true),
            ),
            child: Text('加入'.tl),
          ),
        ],
      );
    }

    final formatLabel = widget.format == ArchiveFormat.cbz ? 'CBZ' : 'ZIP';
    return AlertDialog(
      title: Text('输入密码'.tl),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${widget.archiveFileName} ($formatLabel)',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            obscureText: true,
            decoration: InputDecoration(
              hintText: '密码'.tl,
              errorText: _errorMessage,
            ),
            onSubmitted: (_) => _tryUnlock(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.of(context).pop(),
          child: Text('取消'.tl),
        ),
        FilledButton(
          onPressed: _loading ? null : _tryUnlock,
          child: _loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text('解锁'.tl),
        ),
      ],
    );
  }
}
