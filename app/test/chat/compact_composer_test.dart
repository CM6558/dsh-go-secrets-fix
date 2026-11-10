import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_list.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

void _view(WidgetTester tester, Size size, double keyboard) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 16);
  tester.view.padding = FakeViewPadding(top: 24, bottom: keyboard > 0 ? 0 : 16);
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
}

Future<TextEditingController> _open(
  WidgetTester tester, {
  required Size size,
  double keyboard = 0,
  double scale = 1,
}) async {
  _view(tester, size, keyboard);
  addTearDown(tester.view.reset);
  final harness = ChatHarness(
    session: 's1',
    states: {
      's1': ChatState(
        loading: false,
        items: [
          UserChatItem(seq: 1, time: DateTime(2026), text: 'Existing history', images: const [], files: const []),
        ],
      ),
    },
  );
  await tester.pumpWidget(
    testApp(
      MediaQuery.withClampedTextScaling(minScaleFactor: scale, maxScaleFactor: scale, child: const ChatScreen()),
      overrides: harness.overrides,
    ),
  );
  await pumpFrames(tester);
  return tester.widget<TextField>(find.byType(TextField)).controller!;
}

const _draft = 'first\nsecond\nthird\nfourth\nfifth\nsixth';

void main() {
  for (final (size, keyboard, scale) in [(const Size(844, 390), 180.0, 2.0), (const Size(390, 320), 180.0, 1.0)]) {
    testWidgets('a six-line draft stays reachable at $size with keyboard $keyboard and text $scale', (tester) async {
      final input = await _open(tester, size: size, keyboard: keyboard, scale: scale);
      await tester.enterText(find.byType(TextField), _draft);
      await pumpFrames(tester);
      final field = tester.getRect(find.byType(TextField));
      expect(field.top, greaterThanOrEqualTo(24));
      expect(field.bottom, lessThanOrEqualTo(size.height - keyboard));
      expect(tester.getSize(find.byType(ChatList)).height, greaterThan(32));
      expect(input.text, _draft);
      final editable = tester.state<EditableTextState>(find.byType(EditableText));
      expect(editable.renderEditable.offset.pixels, greaterThan(0), reason: 'The last line scrolls into the editor');
      input.selection = const TextSelection.collapsed(offset: 0);
      editable.bringIntoView(input.selection.extent);
      await pumpFrames(tester);
      final caret = editable.renderEditable.getLocalRectForCaret(input.selection.extent);
      // The test font's caret extends fractionally past the glyph box.
      expect(caret.top, greaterThanOrEqualTo(-1));
      expect(caret.bottom, lessThanOrEqualTo(editable.renderEditable.size.height + 1));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('restoring height restores six-line growth without losing the draft', (tester) async {
    final input = await _open(tester, size: const Size(844, 390), keyboard: 180);
    await tester.enterText(find.byType(TextField), _draft);
    await pumpFrames(tester);
    final compact = tester.getSize(find.byType(Composer)).height;
    _view(tester, const Size(390, 844), 0);
    await pumpFrames(tester);
    expect(input.text, _draft);
    expect(tester.getSize(find.byType(Composer)).height, greaterThan(compact + 50));
    expect(tester.widget<TextField>(find.byType(TextField)).maxLines, 6);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty single-line composer keeps the same compact and tall geometry', (tester) async {
    await _open(tester, size: const Size(390, 844));
    final tall = tester.getSize(find.byType(Composer)).height;
    _view(tester, const Size(844, 390), 180);
    await pumpFrames(tester);
    expect(tester.getSize(find.byType(Composer)).height, tall);
    expect(tester.takeException(), isNull);
  });

  for (final scale in [1.0, 1.15]) {
    testWidgets('an upright phone with a tall keyboard keeps six-line growth at text $scale', (tester) async {
      // Chinese keyboards with a candidate bar often take 400 dp or more.
      final input = await _open(tester, size: const Size(393, 852), keyboard: 420, scale: scale);
      await tester.enterText(find.byType(TextField), _draft);
      await pumpFrames(tester);
      expect(tester.widget<TextField>(find.byType(TextField)).maxLines, 6);
      expect(input.text, _draft);
      expect(tester.getSize(find.byType(ChatList)).height, greaterThan(100));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a smaller phone with a tall keyboard keeps six-line growth', (tester) async {
    final input = await _open(tester, size: const Size(360, 780), keyboard: 400);
    await tester.enterText(find.byType(TextField), _draft);
    await pumpFrames(tester);
    expect(tester.widget<TextField>(find.byType(TextField)).maxLines, 6);
    expect(input.text, _draft);
    expect(tester.getSize(find.byType(ChatList)).height, greaterThan(100));
    expect(tester.takeException(), isNull);
  });

  testWidgets('very large text under a tall keyboard trades lines for a strip of chat', (tester) async {
    await _open(tester, size: const Size(393, 852), keyboard: 420, scale: 2);
    await tester.enterText(find.byType(TextField), _draft);
    await pumpFrames(tester);
    final lines = tester.widget<TextField>(find.byType(TextField)).maxLines!;
    expect(lines, inInclusiveRange(2, 5));
    expect(tester.getSize(find.byType(ChatList)).height, greaterThan(32));
    expect(tester.takeException(), isNull);
  });
}
