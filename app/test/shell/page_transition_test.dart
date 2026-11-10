// The app-wide push transition: the new page slides in from the right while
// the one underneath drifts left; the back gesture (in-app edge swipe or
// Android's predictive back) moves the page with the finger and either pops it
// or settles it back.
//
//   flutter test test/shell/page_transition_test.dart

import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app() => MaterialApp(
  theme: buildLightTheme(),
  home: Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Center(child: Text('page b'))),
            ),
          ),
          child: const Text('push'),
        ),
      ),
    ),
  ),
);

Future<void> _push(WidgetTester tester) async {
  await tester.pumpWidget(_app());
  await tester.tap(find.text('push'));
  await tester.pumpAndSettle();
  expect(find.text('page b'), findsOneWidget);
}

Future<void> _backGesture(WidgetTester tester, String method, [Map<String, dynamic>? args]) async {
  final message = const StandardMethodCodec().encodeMethodCall(MethodCall(method, args));
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage('flutter/backgesture', message, (_) {});
}

void main() {
  testWidgets('push: the new page comes from the right, the old one drifts left', (tester) async {
    await tester.pumpWidget(_app());
    final width = tester.getSize(find.byType(MaterialApp)).width;
    final pushStart = tester.getCenter(find.text('push')).dx;
    await tester.tap(find.text('push'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final incoming = tester.getCenter(find.text('page b')).dx;
    final outgoing = tester.getCenter(find.text('push')).dx;
    expect(incoming, greaterThan(width / 2), reason: 'still on its way in from the right');
    expect(outgoing, lessThan(pushStart), reason: 'the page underneath moves left');
    await tester.pumpAndSettle();
    expect(tester.getCenter(find.text('page b')).dx, closeTo(width / 2, 0.01));
  });

  testWidgets('an edge swipe past the middle pops the page', (tester) async {
    await _push(tester);
    final width = tester.getSize(find.byType(MaterialApp)).width;
    final gesture = await tester.startGesture(const Offset(6, 300));
    for (var x = 0; x < 24; x++) {
      await gesture.moveBy(Offset(width * 0.7 / 24, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    // Mid-gesture the page follows the finger.
    expect(tester.getTopLeft(find.byType(Scaffold).last).dx, greaterThan(width * 0.5));
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('page b'), findsNothing);
    expect(find.text('push'), findsOneWidget);
  });

  testWidgets('a short, slow edge swipe settles the page back', (tester) async {
    await _push(tester);
    final gesture = await tester.startGesture(const Offset(6, 300));
    for (var x = 0; x < 10; x++) {
      await gesture.moveBy(const Offset(8, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('page b'), findsOneWidget);
    expect(tester.getTopLeft(find.byType(Scaffold).last).dx, closeTo(0, 0.01));
  });

  testWidgets('Android predictive back drives the same transition', (tester) async {
    await _push(tester);
    final width = tester.getSize(find.byType(MaterialApp)).width;
    await _backGesture(tester, 'startBackGesture', {
      'touchOffset': <double>[5.0, 300.0],
      'progress': 0.0,
      'swipeEdge': 0,
    });
    await tester.pump();
    await _backGesture(tester, 'updateBackGestureProgress', {'x': 200.0, 'y': 300.0, 'progress': 0.5, 'swipeEdge': 0});
    await tester.pump();
    // Linear while the finger is down: half way along, half way across.
    expect(tester.getTopLeft(find.byType(Scaffold).last).dx, closeTo(width / 2, 1));
    await _backGesture(tester, 'commitBackGesture');
    await tester.pumpAndSettle();
    expect(find.text('page b'), findsNothing);
  });
}
