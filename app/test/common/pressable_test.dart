import 'package:dsh_app/ui/common/pressable.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/semantics_tap_check.dart';

void main() {
  for (final enabled in [true, false]) {
    testWidgets('owned tap reads its label once and stays a button (enabled: $enabled)', (tester) async {
      final semantics = tester.ensureSemantics();
      var tapped = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Pressable(enabled: enabled, onTap: () => tapped++, semanticLabel: '查看译文', child: const Text('查看译文')),
          ),
        ),
      );
      expect(
        tester.getSemantics(find.byType(Pressable)),
        isSemantics(label: '查看译文', isButton: true, hasEnabledState: true, isEnabled: enabled, hasTapAction: enabled),
      );
      expectAllButtonsTappable();
      if (enabled) {
        tester.semantics.tap(find.semantics.byLabel('查看译文'));
        await tester.pump();
        expect(tapped, 1);
      }
      semantics.dispose();
    });
  }

  testWidgets('without a custom label there is one tappable node', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Pressable(onTap: () {}, child: const Text('查看')),
        ),
      ),
    );
    final tappable = find.semantics.byPredicate((node) => node.getSemanticsData().hasAction(SemanticsAction.tap));
    expect(tappable, findsOneWidget);
    expect(tappable.evaluate().single.label, '查看');
    semantics.dispose();
  });

  for (final owned in [true, false]) {
    testWidgets('disabling keeps the child element (owns tap: $owned)', (tester) async {
      var enabled = true;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return Pressable(
                  enabled: enabled,
                  onTap: owned ? () {} : null,
                  child: InkWell(key: const ValueKey('inner'), onTap: () {}, child: const Text('行')),
                );
              },
            ),
          ),
        ),
      );
      final before = tester.element(find.byKey(const ValueKey('inner')));
      update(() => enabled = false);
      await tester.pump();
      expect(tester.element(find.byKey(const ValueKey('inner'))), same(before));
    });
  }
}
