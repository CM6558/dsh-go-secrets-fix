import 'package:dsh_app/ui/chat/render/code_block.dart';
import 'package:dsh_app/ui/chat/widgets/stream_row.dart';
import 'package:dsh_app/ui/chat/widgets/thinking_pill.dart';
import 'package:dsh_app/ui/chat/widgets/tool_row.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/sample_chat.dart';

void main() {
  setUpAll(loadTestFonts);
  testWidgets('thinking and tool previews share a centered 15px separator', (tester) async {
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Column(
            children: [
              const ThinkingPill(reasoning: '预览'),
              ToolRow(item: tool('a', 'bash', {'command': 'echo'}), onRespond: (_, _) async {}),
            ],
          ),
        ),
      ),
    );
    final thought = tester.getRect(find.text('思考'));
    final verb = tester.getRect(find.text('运行'));
    expect(tester.getTopLeft(find.text('预览')).dx - thought.right, closeTo(15, 0.5));
    expect(tester.getTopLeft(find.text('echo')).dx - verb.right, closeTo(15, 0.5));
    final dots = find.byType(StreamDot);
    expect(tester.getCenter(dots.at(0)).dy, closeTo(thought.center.dy, 0.5));
    expect(tester.getCenter(dots.at(1)).dy, closeTo(verb.center.dy, 0.5));
  });
  testWidgets('streaming to running keeps one spinner and the same State', (tester) async {
    Widget row(ToolStatus status) => testApp(
      Scaffold(
        body: ToolRow(
          item: tool('a', 'bash', {'command': 'echo'}, status: status),
          onRespond: (_, _) async {},
        ),
      ),
    );
    await tester.pumpWidget(row(ToolStatus.streaming));
    final state = tester.state(find.byType(CircularProgressIndicator));
    await tester.pumpWidget(row(ToolStatus.running));
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.state(find.byType(CircularProgressIndicator)), same(state));
  });
  testWidgets('finished thinking moves the preview left without overshooting right', (tester) async {
    Widget pill(bool active) => testApp(
      Scaffold(
        body: ThinkingPill(reasoning: '预览\n细节', active: active),
      ),
    );
    await tester.pumpWidget(pill(true));
    var x = tester.getTopLeft(find.text('预览')).dx;
    await tester.pumpWidget(pill(false));
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final next = tester.getTopLeft(find.text('预览')).dx;
      expect(next, lessThanOrEqualTo(x + 0.5));
      x = next;
    }
  });
  testWidgets('dense code and ANSI output align with section titles and use 18px lines', (tester) async {
    usePhoneView(tester);
    final cases = [
      tool('bash', 'bash', {'command': 'echo hi'}, result: '\u001b[31mred\u001b[0m\nsecond'),
      tool(
        'read',
        'read',
        {'file_path': 'a.dart'},
        meta: {
          'lines': [
            for (var i = 40; i <= 44; i++) {'number': i, 'text': 'final value = $i;'},
          ],
        },
      ),
      tool('write', 'write', {'file_path': 'b.dart', 'content': 'final x = 1;\nfinal y = 2;'}),
      tool('edit', 'edit', {'file_path': 'c.dart', 'old_string': 'old', 'new_string': 'new'}),
    ];
    for (final item in cases) {
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: ToolRow(key: ValueKey(item.callId), item: item, onRespond: (_, _) async {}),
            ),
          ),
        ),
      );
      await tester.tap(
        find.text(switch (item.name) {
          'bash' => '运行',
          'read' => '读取',
          'write' => '写入',
          _ => '编辑',
        }),
      );
      await pumpFrames(tester, 5);
      final detail = find.byType(ToolDetail);
      final left = tester.getTopLeft(detail).dx + 12;
      for (final editable in find.descendant(of: detail, matching: find.byType(EditableText)).evaluate()) {
        final state = (editable as StatefulElement).state as EditableTextState;
        final render = state.renderEditable;
        final plain = state.widget.controller.text;
        if (plain.startsWith(r'$') || plain.startsWith('red') || (item.name != 'read' && plain.startsWith('final'))) {
          final point = render.localToGlobal(render.getLocalRectForCaret(const TextPosition(offset: 0)).topLeft);
          expect(point.dx, closeTo(left, 0.5));
          expect(render.preferredLineHeight, closeTo(18, 0.5));
        }
      }
      if (item.name == 'read') {
        expect(tester.getTopLeft(find.text('40\n41\n42\n43\n44')).dx, closeTo(left, 0.5));
        final path = tester.widget<SelectableText>(
          find.byWidgetPredicate(
            (w) =>
                w is SelectableText && (w.textSpan?.toPlainText().contains('第\u00a040\u2060–\u206044\u00a0行') ?? false),
          ),
        );
        expect(path.textSpan!.toPlainText(), contains('\u00a0·\u00a0第\u00a040\u2060–\u206044\u00a0行'));
        // A long path wraps; the line never starts with the 「·」 (or
        // inside 「第 40–44 行」): the range goes with the path's last
        // part.
        final range = path.textSpan!.children!.last;
        const tail = 'login_controller_test.dart';
        final span = TextSpan(
          style: path.textSpan!.style,
          children: [
            const TextSpan(text: 'lib/features/auth/$tail'),
            range,
          ],
        );
        final plain = span.toPlainText();
        final from = plain.indexOf('\u00a0·');
        final chunk = TextPainter(
          text: TextSpan(
            style: path.textSpan!.style,
            children: [
              const TextSpan(text: tail),
              range,
            ],
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        for (var width = chunk.width.ceilToDouble(); width <= 400; width += 4) {
          final painter = TextPainter(text: span, textDirection: TextDirection.ltr)..layout(maxWidth: width);
          for (final line in painter.computeLineMetrics().skip(1)) {
            final start = painter.getPositionForOffset(Offset(0, line.baseline - line.ascent + 1)).offset;
            expect(
              start <= from - tail.length || start >= plain.length,
              isTrue,
              reason: 'line ${line.lineNumber} at $width starts at $start',
            );
          }
          painter.dispose();
        }
        chunk.dispose();
      }
      if (item.name == 'edit') {
        expect(tester.getTopLeft(find.text('-old')).dx, closeTo(left, 0.5));
      }
    }
  });
  testWidgets('code header grows symmetrically with a 2x text scaler', (tester) async {
    await tester.pumpWidget(
      testApp(
        const MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: SizedBox(width: 390, child: CodeBlock(code: 'hello')),
          ),
        ),
      ),
    );
    final label = tester.getRect(find.text('复制'));
    final tap = tester.getRect(find.ancestor(of: find.text('复制'), matching: find.byType(InkWell)));
    expect(label.top - tap.top, closeTo(tap.bottom - label.bottom, 0.5));
    expect(tester.takeException(), isNull);
  });
}
