import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:picakeep/network/cookie_jar.dart';
import 'package:picakeep/network/eh_network/eh_main_network.dart';
import 'package:picakeep/tools/translations.dart';

import 'account_operation_scope.dart';

/// EH 账号页的 cookies 管理区。
///
/// 默认折叠；展开依次显示 `ipb_member_id` / `ipb_pass_hash` / `igneous`。
/// 三项只读展示 + 点按复制完整值，仅 `igneous` 可编辑，且编辑必须两站同时生效。
class EhCookieManagementView extends StatefulWidget {
  const EhCookieManagementView({super.key, this.onSaved, this.cookieJar});

  /// 保存成功后通知外层刷新资料行。
  final VoidCallback? onSaved;

  @visibleForTesting
  final CookieJarSql? cookieJar;

  @override
  State<EhCookieManagementView> createState() => _EhCookieManagementViewState();
}

/// EH 双域根地址：改写 igneous 时两站都要写一份。
const List<String> kEhCookieSites = <String>[
  'https://e-hentai.org/',
  'https://exhentai.org/',
];

/// 账号页只允许编辑这一项；其余身份 Cookie 只能查看/复制。
const String kEhIgneousCookieName = 'igneous';

/// 展示顺序与原项目账号页一致。
const List<String> kEhCookieRowNames = <String>[
  'ipb_member_id',
  'ipb_pass_hash',
  'igneous',
];

/// 与账号页其它 EH 操作共用的门禁键（等于源 key）。
const String _ehOperationKey = 'ehentai';

/// 值能否安全构造成 Cookie：空白、分号、逗号都会破坏 Cookie 语法或后半段内容。
@visibleForTesting
bool isValidEhCookieValue(String value) {
  if (value.isEmpty || RegExp(r'[\s;,]').hasMatch(value)) return false;
  try {
    Cookie(kEhIgneousCookieName, value);
    return true;
  } catch (_) {
    return false;
  }
}

/// 双域改写 `igneous`。
///
/// - [rawValue] 先 trim 外侧空白；空串表示**移除** igneous（两个域都删）；
/// - 只影响根路径下名为 igneous 的项：`ipb_member_id`、`ipb_pass_hash`、`star`、
///   `nw`、`sp`、其它域与其它源的 Cookie 一律保留；
/// - 任意一步失败时按编辑前快照整批恢复（逐条恢复会被既存 domain 优先规则改写，
///   所以每个域一次 `saveFromResponse`）；恢复也失败时抛出明确错误，不谎报成功。
@visibleForTesting
Future<void> applyEhIgneousValue(
  CookieJarSql jar,
  String rawValue, {
  List<String> sites = kEhCookieSites,
}) async {
  final value = rawValue.trim();
  if (value.isNotEmpty && !isValidEhCookieValue(value)) {
    throw FormatException('igneous 包含无效字符'.tl);
  }

  final parsedSites = <Uri>[
    for (final site in sites) Uri.parse(site).replace(path: '/'),
  ];
  final replacements = <Uri, List<Cookie>>{
    for (final uri in parsedSites)
      uri: value.isEmpty
          ? <Cookie>[]
          : <Cookie>[
              Cookie(kEhIgneousCookieName, value)
                ..domain = uri.host
                ..path = '/',
            ],
  };
  // 编辑前快照：含 domain/path/expires/secure/httpOnly。
  final snapshots = <Uri, List<Cookie>>{
    for (final uri in parsedSites)
      uri: jar
          .loadForRequest(uri)
          .where((cookie) =>
              cookie.name == kEhIgneousCookieName && cookie.path == '/')
          .toList(),
  };

  try {
    for (final uri in parsedSites) {
      // 只删根路径（uri.path == '/'）下名为 igneous 的 host/点域旧项。
      jar.delete(uri, kEhIgneousCookieName);
      if (value.isEmpty) continue;
      jar.saveFromResponse(uri, replacements[uri]!);
    }
  } catch (error) {
    try {
      for (final uri in parsedSites) {
        jar.delete(uri, kEhIgneousCookieName);
        jar.saveFromResponse(uri, snapshots[uri] ?? const <Cookie>[]);
      }
    } catch (_) {
      throw StateError('igneous 保存失败，且本地恢复未完成，请重新读取账号信息'.tl);
    }
    rethrow;
  }
}

class _EhCookieManagementViewState extends State<EhCookieManagementView> {
  bool _expanded = false;
  bool _dialogOpen = false;
  late Map<String, String> _values = _readValues();

  CookieJarSql get _jar => widget.cookieJar ?? EhNetwork().cookieJar;

  /// 直接从当前选中站点的 CookieJar 读取，不依赖 source.data 或上一次的 net 快照。
  /// 同名多项（host 与点域）时取最后一项，与 [EhNetwork.getCookies] 的遍历语义一致。
  Map<String, String> _readValues() {
    final cookies = _jar
        .loadForRequest(Uri.parse(EhNetwork().ehBaseUrl).replace(path: '/'));
    final values = <String, String>{};
    for (final cookie in cookies) {
      values[cookie.name] = cookie.value;
    }
    return values;
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _copy(String name, String value) async {
    if (value.isEmpty) return;
    try {
      await Clipboard.setData(ClipboardData(text: value));
      if (!mounted) return;
      _showMessage('已复制'.tl);
    } catch (error) {
      if (!mounted) return;
      _showMessage('复制失败：@error'.tlParams({'error': error.toString()}));
    }
  }

  Future<void> _editIgneous() async {
    final operations = AccountOperationScope.maybeOf(context);
    if (_dialogOpen || (operations?.isBusy(_ehOperationKey) ?? false)) return;
    final current = _values[kEhIgneousCookieName] ?? '';
    setState(() => _dialogOpen = true);
    bool? saved;
    try {
      saved = await showDialog<bool>(
        context: context,
        useRootNavigator: false,
        builder: (_) => _EhIgneousDialog(
          initialValue: current,
          operations: operations,
          onSave: (value) async {
            await applyEhIgneousValue(_jar, value);
            if (widget.cookieJar == null) await EhNetwork().getCookies(true);
          },
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _dialogOpen = false;
          _values = _readValues();
        });
      }
    }
    if (!mounted || saved != true) return;
    widget.onSaved?.call();
    _showMessage('已保存'.tl);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          dense: true,
          leading: const Icon(Icons.cookie_outlined),
          title: const Text('cookies'),
          trailing: Icon(
            _expanded ? Icons.expand_less : Icons.expand_more,
            size: 20,
          ),
          onTap: () => setState(() => _expanded = !_expanded),
        ),
        if (_expanded)
          for (final name in kEhCookieRowNames)
            _buildCookieRow(context, colorScheme, name),
      ],
    );
  }

  Widget _buildCookieRow(
    BuildContext context,
    ColorScheme colorScheme,
    String name,
  ) {
    final value = _values[name] ?? '';
    final hasValue = value.isNotEmpty;
    final editable = name == kEhIgneousCookieName;
    final busy = _dialogOpen ||
        (AccountOperationScope.maybeOf(context)?.isBusy(_ehOperationKey) ??
            false);
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 32, right: 8),
      title: Text(name, style: const TextStyle(fontSize: 12)),
      subtitle: Text(
        hasValue ? value : '未设置'.tl,
        style: TextStyle(
          color: hasValue ? null : colorScheme.outline,
        ),
      ),
      trailing: editable
          ? IconButton(
              icon: const Icon(Icons.edit_outlined, size: 20),
              tooltip: '编辑 igneous'.tl,
              onPressed: busy ? null : _editIgneous,
            )
          : Icon(
              Icons.copy_outlined,
              size: 18,
              color: hasValue ? null : colorScheme.outline,
            ),
      onTap: hasValue && !busy ? () => _copy(name, value) : null,
    );
  }
}

class _EhIgneousDialog extends StatefulWidget {
  const _EhIgneousDialog({
    required this.initialValue,
    required this.operations,
    required this.onSave,
  });

  final String initialValue;
  final AccountOperationController? operations;
  final Future<void> Function(String value) onSave;

  @override
  State<_EhIgneousDialog> createState() => _EhIgneousDialogState();
}

class _EhIgneousDialogState extends State<_EhIgneousDialog> {
  late final _controller = TextEditingController(text: widget.initialValue);
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final operations = widget.operations;
    if (operations?.isBusy(_ehOperationKey) ?? false) {
      setState(() => _error = '账号操作正在进行，请稍候'.tl);
      return;
    }
    final value = _controller.text.trim();
    if (value.isNotEmpty && !isValidEhCookieValue(value)) {
      setState(() => _error = 'igneous 包含无效字符'.tl);
      return;
    }
    if (value == widget.initialValue) {
      Navigator.of(context).pop(false);
      return;
    }
    final route = ModalRoute.of(context);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (operations != null) {
        await operations.execute<void>(
          _ehOperationKey,
          () => widget.onSave(value),
          operation: 'editCookies',
        );
      } else {
        await widget.onSave(value);
      }
      if (mounted && route?.isCurrent == true) {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '保存失败：@error'.tlParams({'error': error.toString()});
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !_saving,
        child: AlertDialog(
          title: Text('编辑 igneous'.tl),
          content: TextField(
            controller: _controller,
            autofocus: true,
            enabled: !_saving,
            onSubmitted: (_) => _save(),
            decoration: InputDecoration(
              hintText: '留空表示移除 igneous'.tl,
              errorText: _error,
              errorMaxLines: 4,
            ),
          ),
          actions: [
            TextButton(
              onPressed: _saving ? null : () => Navigator.of(context).pop(),
              child: Text('取消'.tl),
            ),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Text('保存'.tl),
            ),
          ],
        ),
      );
}
