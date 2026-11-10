// The medium-window detail sheet with a stand-in body: its width and
// centring, the two heights (half and full), the handle and drags that move
// between them, a drag that closes it, and folding into the panel when the
// window turns wide.
//
//   flutter test test/shell/adaptive/detail_sheet_test.dart

import 'package:dsh_app/ui/shell/adaptive/detail_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../chat/support/harness.dart';

const _top = 24.0;
const _bottom = 16.0;

void _window(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = size * 2;
  const pad = FakeViewPadding(top: _top * 2, bottom: _bottom * 2);
  tester.view.padding = pad;
  tester.view.viewPadding = pad;
  addTearDown(tester.view.reset);
}

final _sheet = find.byKey(const ValueKey('detail-sheet'));

Future<void> _open(WidgetTester tester, {VoidCallback? onWide}) async {
  await tester.pumpWidget(
    testApp(
      Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => showDetailSheet(
              context,
              onWide: onWide,
              builder: (context) => Column(
                children: [
                  // The content's own title row moves the sheet too.
                  DetailSheetScope.maybeOf(context)!.dragArea(
                    const SizedBox(
                      key: ValueKey('title-row'),
                      height: 52,
                      width: double.infinity,
                      child: ColoredBox(color: Color(0x00000000)),
                    ),
                  ),
                  const Expanded(child: SizedBox.expand()),
                ],
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('720 × 900: full width, half the window tall', (tester) async {
    _window(tester, const Size(720, 900));
    await _open(tester);
    expect(tester.getRect(_sheet), const Rect.fromLTWH(0, 450, 720, 450));
  });

  testWidgets('wider windows: the reading width, centred', (tester) async {
    _window(tester, const Size(820, 900));
    await _open(tester);
    final sheet = tester.getRect(_sheet);
    expect(sheet.width, 744);
    expect(sheet.left, 820 - sheet.right);
    expect(sheet.bottom, 900);
  });

  testWidgets('the handle: half ↔ full (status bar + 12 clear)', (tester) async {
    final semantics = tester.ensureSemantics();
    _window(tester, const Size(720, 900));
    await _open(tester);
    final handle = find.bySemanticsLabel('展开');
    expect(handle, findsOneWidget);
    await tester.tap(handle);
    await tester.pumpAndSettle();
    expect(tester.getRect(_sheet).top, _top + 12);
    expect(find.bySemanticsLabel('收起'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('收起'));
    await tester.pumpAndSettle();
    expect(tester.getRect(_sheet).top, 450);
    semantics.dispose();
  });

  testWidgets('resize handle exposes semantic dismiss at half and full height', (tester) async {
    final semantics = tester.ensureSemantics();
    _window(tester, const Size(720, 900));
    for (final full in [false, true]) {
      await _open(tester);
      if (full) {
        await tester.tap(find.bySemanticsLabel('展开'));
        await tester.pumpAndSettle();
      }
      tester.semantics.dismiss(find.semantics.byLabel(full ? '收起' : '展开'));
      await tester.pumpAndSettle();
      expect(_sheet, findsNothing);
    }
    semantics.dispose();
  });

  testWidgets('drags snap to the nearer height or fling past it', (tester) async {
    _window(tester, const Size(720, 900));
    await _open(tester);
    final title = find.byKey(const ValueKey('title-row'));
    // A short pull up from the title row falls back to half.
    await tester.drag(title, const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(tester.getRect(_sheet).top, 450);
    // Past the middle: full.
    await tester.drag(title, const Offset(0, -260));
    await tester.pumpAndSettle();
    expect(tester.getRect(_sheet).top, _top + 12);
    // A fling down: half again (not closed).
    await tester.fling(title, const Offset(0, 120), 1500);
    await tester.pumpAndSettle();
    expect(tester.getRect(_sheet).top, 450);
  });

  testWidgets('a pull down from half closes it; a nudge does not', (tester) async {
    _window(tester, const Size(720, 900));
    await _open(tester);
    final title = find.byKey(const ValueKey('title-row'));
    await tester.drag(title, const Offset(0, 60));
    await tester.pumpAndSettle();
    expect(tester.getRect(_sheet).top, 450);
    await tester.drag(title, const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(_sheet, findsNothing);
  });

  testWidgets('a tap on the scrim closes it', (tester) async {
    _window(tester, const Size(720, 900));
    await _open(tester);
    await tester.tapAt(const Offset(360, 120));
    await tester.pumpAndSettle();
    expect(_sheet, findsNothing);
  });

  testWidgets('turning wide hands over to the panel', (tester) async {
    _window(tester, const Size(720, 900));
    var wide = 0;
    await _open(tester, onWide: () => wide++);
    _window(tester, const Size(1280, 800));
    await tester.pumpAndSettle();
    expect(wide, 1);
    expect(_sheet, findsNothing);
  });
}
