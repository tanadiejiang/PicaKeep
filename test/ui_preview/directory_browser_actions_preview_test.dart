/// 文件夹浏览页按钮行的布局契约 + PNG 预览生成器。
///
/// ## 为什么有这个文件
///
/// 真机反馈：这一行的三个按钮在手机上**挤到了换行**（「选择当前文件夹」
/// 掉到第二行）。凭肉眼看代码估宽度不可靠，所以这里做两件事：
///
/// 1. **自动断言**（默认运行）：在几种常见手机逻辑宽度下，按钮行的高度必须
///    等于单行高度。一旦折行，高度会变成两行，断言立刻失败 —— 这比截图可靠。
/// 2. **PNG 预览**（需要开关）：把真实组件渲染成图片，用眼睛确认排版与美观。
///
/// ## 生成预览图
///
/// ```text
/// flutter test test/ui_preview/directory_browser_actions_preview_test.dart \
///   --dart-define=DIRECTORY_ACTIONS_PREVIEW=true \
///   --plain-name 'renders directory browser action row preview'
/// ```
///
/// 输出到 `build/directory-browser-actions-preview.png`。不带
/// `DIRECTORY_ACTIONS_PREVIEW` 时该测试直接返回，不会产生副作用。
///
/// 中文字体默认读本机 `C:/Windows/Fonts/msyh.ttc`；换机器时用
/// `--dart-define=DIRECTORY_PREVIEW_FONT=<字体路径>` 指定。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/pages/settings/settings_page.dart';

/// 预览里要对照的手机逻辑宽度（dp）。
///
/// 360 是主流下限，393/412 覆盖 Pixel 与多数国产机。320 属于老小屏，
/// 单独作为"放不下时的兜底行为"来验证（见 `_narrowestWidth`）。
const List<double> _previewWidths = <double>[320, 360, 393, 412];

/// 保证单行的最小屏幕宽度：三个按钮实测合计 319.1 dp，需要内容区 ≥ 319.1，
/// 即屏幕 ≥ 343.1 dp。360 dp 是主流下限，留出约 17 dp 余量。
const double _singleRowMinScreenWidth = 360;

/// 老小屏宽度：这里只要求「折行且不溢出」，不要求单行。
const double _narrowestWidth = 320;

/// 页面内容区左右各 12 dp 的内边距。
const double _pageHorizontalPadding = 12;

/// 按钮行可用宽度 = 屏幕宽度 - 两侧内边距。
///
/// 预览时必须按这个宽度渲染：直接拿屏幕宽度当容器宽度会**看起来更宽松**，
/// 从而掩盖真机上的折行（先前那版预览就犯过这个错）。
double _contentWidth(double screenWidth) =>
    screenWidth - _pageHorizontalPadding * 2;

const bool _previewEnabled = bool.fromEnvironment(
  'DIRECTORY_ACTIONS_PREVIEW',
);

const String _fontPath = String.fromEnvironment(
  'DIRECTORY_PREVIEW_FONT',
  defaultValue: 'C:/Windows/Fonts/msyh.ttc',
);

/// 加载图标字体。
///
/// `flutter test` 不会自动备好 Material 图标字体，不加载的话所有图标都会渲染成
/// 空心方框 —— 断言仍然通过（图标宽度固定），但预览图会失去参考价值。
Future<void> _loadIconFont() async {
  const candidates = <String>[
    'build/unit_test_assets/fonts/MaterialIcons-Regular.otf',
    r'E:\SDK\flutter_windows_3.38.5-stable\flutter\bin\cache\artifacts'
        r'\material_fonts\materialicons-regular.otf',
  ];
  for (final path in candidates) {
    try {
      final file = File(path);
      if (!file.existsSync()) continue;
      final bytes = await file.readAsBytes();
      final loader = FontLoader('MaterialIcons')
        ..addFont(Future<ByteData>.value(ByteData.view(bytes.buffer)));
      await loader.load();
      return;
    } catch (_) {
      continue;
    }
  }
  // ignore: avoid_print
  print('[preview] 未能加载 Material 图标字体，预览里图标会显示为方框');
}

/// 加载中文字体。测试环境自带字体不含中文字形，不加载的话中文会变成方框，
/// 量出来的宽度也不可信。字体缺失时只警告、不失败 —— 断言仍用默认字体跑。
Future<bool> _loadCjkFont() async {
  try {
    final file = File(_fontPath);
    if (!file.existsSync()) {
      // ignore: avoid_print
      print('[preview] 中文字体不存在，改用默认字体：$_fontPath');
      return false;
    }
    final bytes = await file.readAsBytes();
    final loader = FontLoader('PreviewCjk')
      ..addFont(Future<ByteData>.value(ByteData.view(bytes.buffer)));
    await loader.load();
    return true;
  } catch (e) {
    // ignore: avoid_print
    print('[preview] 中文字体加载失败，改用默认字体：$e');
    return false;
  }
}

Widget _buildRow({
  required bool showPresetRoots,
  required bool cjkLoaded,
  bool enabled = true,
  VoidCallback? onToggle,
  VoidCallback? onCreate,
  VoidCallback? onSelect,
}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorSchemeSeed: const Color(0xFF6750A4),
      fontFamily: cjkLoaded ? 'PreviewCjk' : null,
    ),
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: DirectoryBrowserActionRow(
          showPresetRoots: showPresetRoots,
          actionsEnabled: enabled,
          onTogglePresetRoots: onToggle ?? () {},
          onCreateFolder: onCreate ?? () {},
          onSelectCurrentFolder: onSelect ?? () {},
        ),
      ),
    ),
  );
}

/// 量出按钮行当前占用的总宽度（三个按钮 + 两个间隔）。
double _measureButtonsWidth(WidgetTester tester) {
  var used = 0.0;
  final chips = find.byType(ActionChip);
  for (var i = 0; i < chips.evaluate().length; i++) {
    used += tester.getSize(chips.at(i)).width;
  }
  used += tester.getSize(find.byType(FilledButton)).width;
  used += DirectoryBrowserActionRow.buttonSpacing * 2;
  return used;
}

void main() {
  late bool cjkLoaded;

  setUpAll(() async {
    // 字体是真实文件 IO，必须放在 runAsync 里，否则 fakeAsync 会挂住。
    await TestWidgetsFlutterBinding.ensureInitialized()
        .runAsync(() async {
      await _loadIconFont();
      cjkLoaded = await _loadCjkFont();
    });
  });

  // ── 1. 布局契约：三个按钮必须在同一行 ──────────────────────────────────
  //
  // 这是量出来的硬要求，不是审美偏好：先前三个按钮合计 369.5 dp，
  // 于是 393 dp 的屏幕（内容区 369 dp）差 0.5 dp 放不下、360 dp 差 33 dp，
  // 真机上就折行。文案收短后总宽降到约 294 dp，320 dp 起都能单行。
  //
  // 断言的是**布局结果**而不是像素值：三个按钮的垂直中心必须一致，
  // 且整行高度等于单行高度（折行会立刻变成两倍高）。
  group('按钮行始终单行', () {
    double centerY(WidgetTester tester, String label) =>
        tester.getCenter(find.text(label)).dy;

    for (final width in _previewWidths.where(
      (w) => w >= _singleRowMinScreenWidth,
    )) {
      testWidgets('${width.toInt()} dp 屏幕三个按钮同一行', (tester) async {
        tester.view.physicalSize = Size(width * 3, 400 * 3);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          _buildRow(showPresetRoots: false, cjkLoaded: cjkLoaded),
        );
        await tester.pumpAndSettle();

        final toggleY = centerY(tester, '预设路径');
        expect(
          centerY(tester, '新建'),
          closeTo(toggleY, 1),
          reason: '${width.toInt()} dp 下「新建」掉到了第二行',
        );
        expect(
          centerY(tester, '选择文件夹'),
          closeTo(toggleY, 1),
          reason: '${width.toInt()} dp 下「选择文件夹」掉到了第二行',
        );
        expect(
          tester.getSize(find.byType(DirectoryBrowserActionRow)).height,
          closeTo(DirectoryBrowserActionRow.buttonHeight, 1),
          reason: '${width.toInt()} dp 下按钮行折行了',
        );
      });
    }

    testWidgets('展开态（收起预设路径）也是单行', (tester) async {
      // 展开态与收起态文案长度相同（都由「预设路径」承担），
      // 图标不同而已；锁一次避免以后给展开态单独加字。
      tester.view.physicalSize = const Size(360 * 3, 400 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _buildRow(showPresetRoots: true, cjkLoaded: cjkLoaded),
      );
      await tester.pumpAndSettle();

      expect(
        tester.getSize(find.byType(DirectoryBrowserActionRow)).height,
        closeTo(DirectoryBrowserActionRow.buttonHeight, 1),
      );
    });

    testWidgets('主流下限 ${_singleRowMinScreenWidth.toInt()} dp 有余量，不是刚好卡住', (tester) async {
      tester.view.physicalSize = const Size(360 * 3, 400 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _buildRow(showPresetRoots: false, cjkLoaded: cjkLoaded),
      );
      await tester.pumpAndSettle();

      final used = _measureButtonsWidth(tester);
      expect(
        used,
        lessThan(_contentWidth(_singleRowMinScreenWidth)),
        reason: '360 dp 内容区 ${_contentWidth(_singleRowMinScreenWidth)} dp，'
            '按钮已占 $used dp —— 没有余量，字体度量一变就会折行',
      );
    });
  });

  // ── 1b. 老小屏的兜底：放不下时要折得干净，不能横向溢出 ──────────────────
  group('${_narrowestWidth.toInt()} dp 老小屏的兜底行为', () {
    testWidgets('折行但不溢出，且主按钮完整可见', (tester) async {
      tester.view.physicalSize = const Size(_narrowestWidth * 3, 400 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _buildRow(showPresetRoots: false, cjkLoaded: cjkLoaded),
      );
      await tester.pumpAndSettle();

      final rowSize = tester.getSize(find.byType(DirectoryBrowserActionRow));
      // Wrap 折行：高度变成两行。
      expect(
        rowSize.height,
        closeTo(
          DirectoryBrowserActionRow.buttonHeight * 2 +
              DirectoryBrowserActionRow.buttonSpacing,
          1,
        ),
      );
      // 关键：任何按钮都不能超出内容区宽度（溢出会直接报 RenderFlex overflow）。
      expect(
        rowSize.width,
        lessThanOrEqualTo(_contentWidth(_narrowestWidth) + 1),
      );
      // 三个按钮都还在，没有因为放不下而消失。
      expect(find.text('预设路径'), findsOneWidget);
      expect(find.text('新建'), findsOneWidget);
      expect(find.text('选择文件夹'), findsOneWidget);
    });
  });

  // ── 2. 三个按钮都能点 ─────────────────────────────────────────────────
  group('按钮回调接线', () {
    testWidgets('点击三个按钮分别触发对应回调', (tester) async {
      var toggled = 0;
      var created = 0;
      var selected = 0;

      tester.view.physicalSize = const Size(393 * 3, 400 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _buildRow(
          showPresetRoots: false,
          cjkLoaded: cjkLoaded,
          onToggle: () => toggled++,
          onCreate: () => created++,
          onSelect: () => selected++,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('预设路径'));
      await tester.tap(find.text('新建'));
      await tester.tap(find.text('选择文件夹'));
      await tester.pumpAndSettle();

      expect(toggled, 1);
      expect(created, 1);
      expect(selected, 1);
    });

    testWidgets('目录加载中时「新建」被禁用', (tester) async {
      var created = 0;

      tester.view.physicalSize = const Size(393 * 3, 400 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _buildRow(
          showPresetRoots: false,
          cjkLoaded: cjkLoaded,
          enabled: false,
          onCreate: () => created++,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('新建'));
      await tester.pumpAndSettle();

      expect(created, 0, reason: '加载中不应该能新建');
    });
  });

  // ── 3. PNG 预览 ───────────────────────────────────────────────────────
  testWidgets('renders directory browser action row preview', (tester) async {
    if (!_previewEnabled) {
      return;
    }

    const canvasWidth = 460.0;
    final boundaryKey = GlobalKey();

    tester.view.physicalSize = const Size(canvasWidth * 2, 900 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: const Color(0xFF6750A4),
          fontFamily: cjkLoaded ? 'PreviewCjk' : null,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: RepaintBoundary(
              key: boundaryKey,
              child: Container(
                width: canvasWidth,
                color: const Color(0xFFFEF7FF),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '文件夹浏览页 · 按钮行（按手机逻辑宽度对照）',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      '每行按"屏幕宽度 − 24 dp 内边距"渲染，与真实页面一致；'
                      '三个按钮必须始终在同一行。',
                      style: TextStyle(fontSize: 11, color: Colors.black54),
                    ),
                    const SizedBox(height: 16),
                    for (final width in _previewWidths) ...[
                      Text(
                        '屏幕 ${width.toInt()} dp'
                        '（内容区 ${_contentWidth(width).toInt()} dp）',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.black54,
                        ),
                      ),
                      const SizedBox(height: 4),
                      SizedBox(
                        width: _contentWidth(width),
                        child: DirectoryBrowserActionRow(
                          showPresetRoots: false,
                          actionsEnabled: true,
                          onTogglePresetRoots: () {},
                          onCreateFolder: () {},
                          onSelectCurrentFolder: () {},
                        ),
                      ),
                      const SizedBox(height: 18),
                    ],
                    const Text(
                      '展开态（图标变为收起）',
                      style: TextStyle(fontSize: 11, color: Colors.black54),
                    ),
                    const SizedBox(height: 4),
                    const SizedBox(
                      width: 296,
                      child: _ExpandedStateRow(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      final boundary = boundaryKey.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (byteData == null) {
        throw StateError('PNG 导出失败：toByteData 返回 null');
      }
      final output = File('build/directory-browser-actions-preview.png');
      output.parent.createSync(recursive: true);
      output.writeAsBytesSync(byteData.buffer.asUint8List());
      // ignore: avoid_print
      print('[preview] 已写出 ${output.absolute.path}');
    });
  });
}

/// 预览里单独展示一次"展开态"的按钮行（`showPresetRoots: true`）。
class _ExpandedStateRow extends StatelessWidget {
  const _ExpandedStateRow();

  @override
  Widget build(BuildContext context) {
    return DirectoryBrowserActionRow(
      showPresetRoots: true,
      actionsEnabled: true,
      onTogglePresetRoots: () {},
      onCreateFolder: () {},
      onSelectCurrentFolder: () {},
    );
  }
}
