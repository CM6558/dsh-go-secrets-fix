// The composer's round keys sit in its capsule like a pill's end caps: on one
// line, the gap above, below and beside each key is the same, and the + on
// the left mirrors the send key on the right. Taller (multi-line) input keeps
// the keys at the bottom with the same bottom and side gaps. With voice, the
// mic takes the send key's place on an empty draft, and while dictating the
// ✕ takes the +'s: all four are the same 40 circle in the same two seats.

import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/mention/mention_text_controller.dart';
import 'package:dsh_app/ui/chat/voice/voice_controller.dart';
import 'package:dsh_app/ui/chat/voice/voice_widgets.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/composer_fakes.dart';
import 'support/harness.dart';

Future<TextEditingController> _pump(
  WidgetTester tester, {
  String text = '',
  double textScale = 1,
  VoiceInputController? voice,
  bool running = false,
  bool stopping = false,
  bool waiting = false,
  String? waitHint,
  VoidCallback? onStop,
  TextEditingController? input,
}) async {
  usePhoneView(tester);
  final controller = input ?? TextEditingController(text: text);
  await tester.pumpWidget(
    testApp(
      MediaQuery.withClampedTextScaling(
        minScaleFactor: textScale,
        maxScaleFactor: textScale,
        // As in the chat screen: a bottom column of intrinsic height.
        child: Scaffold(
          body: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Composer(
                  controller: controller,
                  connected: true,
                  running: running,
                  stopping: stopping,
                  waiting: waiting,
                  waitHint: waitHint,
                  onSend: () {},
                  onStop: onStop ?? () {},
                  leading: AttachButton(onPressed: () {}),
                  voice: voice,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return controller;
}

Rect _capsule(WidgetTester tester) => tester.getRect(find.byType(Composer));
Rect _plus(WidgetTester tester) =>
    tester.getRect(find.ancestor(of: find.byIcon(AppIcons.add), matching: find.byType(Container)).first);
Rect _send(WidgetTester tester) => _round(tester, AppIcons.send);

Rect _round(WidgetTester tester, IconData icon) =>
    tester.getRect(find.ancestor(of: find.byIcon(icon), matching: find.byType(AnimatedContainer)).first);

Rect _cancel(WidgetTester tester) =>
    tester.getRect(find.ancestor(of: find.byIcon(AppIcons.close), matching: find.byType(Container)).first);

/// The two keys sit like end caps: same size, same gap to every edge.
void _expectEndCaps(WidgetTester tester, Rect left, Rect right) {
  final capsule = _capsule(tester);
  final side = left.left - capsule.left;
  expect(left.size, const Size(40, 40));
  expect(right.size, left.size);
  expect(capsule.right - right.right, moreOrLessEquals(side, epsilon: 0.5));
  for (final key in [left, right]) {
    expect(capsule.bottom - key.bottom, moreOrLessEquals(side, epsilon: 0.5));
  }
}

VoiceInputController _voice(TextEditingController input) {
  final voice = VoiceInputController(
    input: input,
    bridge: FakeVoiceBridge(),
    client: () => null,
    observeLifecycle: false,
  );
  addTearDown(voice.dispose);
  return voice;
}

void main() {
  testWidgets('stopping keeps a symmetric 40dp key', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, running: true, stopping: true);
    final busy = find
        .ancestor(of: find.byType(CircularProgressIndicator), matching: find.byType(AnimatedContainer))
        .first;
    _expectEndCaps(tester, _plus(tester), tester.getRect(busy));
    expect(find.bySemanticsLabel('正在停止'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a waiting stop key is quiet and still stops', (tester) async {
    var stops = 0;
    await _pump(tester, running: true, waiting: true, onStop: () => stops++);
    // The approval card and the header say what waits; the hint is the plain
    // one, not 「生成中」.
    expect(tester.widget<TextField>(find.byType(TextField)).decoration!.hintText, '给 DSH 发消息…');
    final key = find.ancestor(of: find.byIcon(AppIcons.stopGenerating), matching: find.byType(AnimatedContainer)).first;
    final decoration = tester.widget<AnimatedContainer>(key).decoration! as BoxDecoration;
    final colors = Theme.of(tester.element(find.byType(Composer))).colorScheme;
    expect(decoration.color, colors.onSurface.withValues(alpha: 0.06));
    await tester.tap(find.byIcon(AppIcons.stopGenerating));
    expect(stops, 1);
  });

  for (final scale in [1.0, 1.3]) {
    testWidgets('one line: equal gaps all round, + mirrors send (text ×$scale)', (tester) async {
      await _pump(tester, textScale: scale);
      final capsule = _capsule(tester);
      final plus = _plus(tester);
      final send = _send(tester);
      final side = plus.left - capsule.left;
      expect(capsule.right - send.right, moreOrLessEquals(side, epsilon: 0.5));
      for (final key in [plus, send]) {
        expect(key.top - capsule.top, moreOrLessEquals(side, epsilon: 0.5));
        expect(capsule.bottom - key.bottom, moreOrLessEquals(side, epsilon: 0.5));
      }
    });
  }

  testWidgets('several lines: keys stay at the bottom with the same gaps', (tester) async {
    await _pump(tester, text: '第一行\n第二行\n第三行');
    final capsule = _capsule(tester);
    final plus = _plus(tester);
    final send = _send(tester);
    final side = plus.left - capsule.left;
    expect(capsule.height, greaterThan(plus.height + 2 * side + 20));
    expect(capsule.right - send.right, moreOrLessEquals(side, epsilon: 0.5));
    expect(capsule.bottom - plus.bottom, moreOrLessEquals(side, epsilon: 0.5));
    expect(capsule.bottom - send.bottom, moreOrLessEquals(side, epsilon: 0.5));
  });

  for (final scale in [1.0, 1.3]) {
    testWidgets('the mic mirrors the + on an empty draft (text ×$scale)', (tester) async {
      final input = MentionTextController();
      await _pump(tester, input: input, voice: _voice(input), textScale: scale);
      await tester.pump();
      final mic = _round(tester, AppIcons.voice);
      final plus = _plus(tester);
      _expectEndCaps(tester, plus, mic);
      expect(mic.top - _capsule(tester).top, plus.top - _capsule(tester).top);
    });
  }

  testWidgets('dictating: ✕ and ■ in the same seats, the level bars lower '
      'than the keys and centred on them', (tester) async {
    final input = MentionTextController();
    final voice = _voice(input);
    await _pump(tester, input: input, voice: voice);
    await tester.pump();
    final empty = _capsule(tester);
    final plus = _plus(tester);
    await voice.start();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(voice.phase, VoicePhase.listening);

    final cancel = _cancel(tester);
    final stop = _round(tester, AppIcons.stopGenerating);
    expect(cancel, plus);
    _expectEndCaps(tester, cancel, stop);
    expect(_capsule(tester), empty);

    final bars = tester.getRect(find.byType(VoiceWaveform));
    expect(bars.height, 40);
    expect(bars.center.dy, moreOrLessEquals(stop.center.dy, epsilon: 0.5));
    expect(VoiceWaveform.maxHeight, lessThan(stop.height));
    // The bars sit next to the stop key like the context ring does.
    expect(stop.left - bars.right, moreOrLessEquals(2, epsilon: 0.5));
  });
}
