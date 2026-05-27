import 'package:flutter/material.dart';
import 'package:picakeep/foundation/archive/archive_password_store.dart';
import 'package:picakeep/tools/translations.dart';

class ArchiveSettingsPage extends StatefulWidget {
  const ArchiveSettingsPage({super.key});

  @override
  State<ArchiveSettingsPage> createState() => _ArchiveSettingsPageState();
}

class _ArchiveSettingsPageState extends State<ArchiveSettingsPage> {
  final _store = ArchivePasswordStore.instance;

  @override
  void initState() {
    super.initState();
    _store.addListener(_onStoreChanged);
  }

  @override
  void dispose() {
    _store.removeListener(_onStoreChanged);
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final passwordCount = _store.defaultPasswords.length;
    return Scaffold(
      appBar: AppBar(title: Text('压缩包设置'.tl)),
      body: ListView(
        children: [
          SwitchListTile(
            title: Text('自动解密'.tl),
            subtitle: Text('刷新时自动尝试默认密码列表解锁加密压缩包'.tl),
            value: _store.autoUnlockEnabled,
            onChanged: (v) => _store.setAutoUnlockEnabled(v),
          ),
          ListTile(
            title: Text('自动解密密码'.tl),
            subtitle: Text('已保存 $passwordCount 个密码'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const ArchivePasswordListPage(),
              ),
            ),
          ),
          ListTile(
            title: Text('清空全部自动解密密码'.tl),
            textColor: Theme.of(context).colorScheme.error,
            onTap: () => _confirmClearAll(context),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClearAll(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('清空密码'.tl),
        content: Text('确定要清空全部自动解密密码吗？'.tl),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消'.tl),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('清空'.tl),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _store.clearDefaultPasswords();
    }
  }
}

class ArchivePasswordListPage extends StatefulWidget {
  const ArchivePasswordListPage({super.key});

  @override
  State<ArchivePasswordListPage> createState() =>
      _ArchivePasswordListPageState();
}

class _ArchivePasswordListPageState extends State<ArchivePasswordListPage> {
  final _store = ArchivePasswordStore.instance;

  @override
  void initState() {
    super.initState();
    _store.addListener(_onStoreChanged);
  }

  @override
  void dispose() {
    _store.removeListener(_onStoreChanged);
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final passwords = _store.defaultPasswords;
    return Scaffold(
      appBar: AppBar(
        title: Text('自动解密密码'.tl),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _addPassword(context),
          ),
        ],
      ),
      body: passwords.isEmpty
          ? Center(child: Text('暂无密码'.tl))
          : ListView.builder(
              itemCount: passwords.length,
              itemBuilder: (ctx, i) => ListTile(
                title: Text('密码 #${i + 1}'),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _store.removeDefaultPassword(passwords[i]),
                ),
              ),
            ),
    );
  }

  Future<void> _addPassword(BuildContext context) async {
    final controller = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('添加密码'.tl),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: '输入密码'.tl),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('取消'.tl),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: Text('添加'.tl),
          ),
        ],
      ),
    );
    if (password != null && password.isNotEmpty) {
      await _store.addDefaultPassword(password);
    }
  }
}
