import 'dart:async';

import 'package:flutter/material.dart';

import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/local_favorites_update.dart';
import 'package:picakeep/tools/translations.dart';

/// 「更新卡片信息」的进度对话框。
///
/// 自己驱动批量流程（而不是由调用方驱动、对话框只显示）：进度分母 `total` 只有
/// 流程内部知道，把它放在同一个 State 里最省事，且与项目既有批量进度对话框的
/// `_completed` / `_total` + setState 写法一致。
///
/// 放在 components 而不是某个页面里：操作区（收藏夹级）与长按多选栏（条目级）
/// 两个入口都要用它，而它们分属不同页面文件。
class LocalFavoriteUpdateDialog extends StatefulWidget {
  const LocalFavoriteUpdateDialog({
    super.key,
    required this.folder,
    this.comics,
  });

  final String folder;

  /// 为空表示更新 [folder] 内全部条目；传入则只更新这几条（长按多选入口）。
  final List<FavoriteItem>? comics;

  @override
  State<LocalFavoriteUpdateDialog> createState() =>
      _LocalFavoriteUpdateDialogState();
}

class _LocalFavoriteUpdateDialogState
    extends State<LocalFavoriteUpdateDialog> {
  var _completed = 0;
  var _total = 0;
  var _cancelRequested = false;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    final report = await updateLocalFavoritesCardInfo(
      widget.folder,
      explicitComics: widget.comics,
      onProgress: (completed, total) {
        if (mounted) {
          setState(() {
            _completed = completed;
            _total = total;
          });
        }
      },
      isCancelled: () => _cancelRequested,
    );
    if (mounted) Navigator.pop(context, report);
  }

  @override
  Widget build(BuildContext context) {
    final ratio = _total <= 0 ? null : _completed / _total;
    return AlertDialog(
      title: Text('更新卡片信息'.tl),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(value: ratio),
          const SizedBox(height: 12),
          Text('正在处理 $_completed / $_total 条…'.tl),
          const SizedBox(height: 8),
          Text(
            '仅支持 Picacg / 禁漫 / E-Hentai / NHentai；其余来源会跳过，'
                    '单条失败不影响整批。'
                .tl,
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _cancelRequested
              ? null
              : () => setState(() => _cancelRequested = true),
          child: Text('取消'.tl),
        ),
      ],
    );
  }
}

