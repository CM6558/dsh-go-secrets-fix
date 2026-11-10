// 启动画面 at the app root: RootGate says "ready" the frame its first page is up (no waiting
// for the engine), and the layer over the app comes and goes without the page under it losing
// its state.

import 'package:dsh_app/app.dart';
import 'package:dsh_app/launch/launch_state.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/launch/launch_overlay.dart';
import 'package:dsh_app/ui/shell/root_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../safe_mode/support.dart';
import '../shell/golden_harness.dart';
import 'support.dart';

class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int taps = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(onPressed: () => setState(() => taps++), child: Text('taps $taps')),
    ),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => LaunchController.active.value = null);

  testWidgets('RootGate: ready as soon as home is up, with the engine still starting', (tester) async {
    final channel = FakeLaunchChannel();
    final c = LaunchController(snapshot: snapshotFor(), channel: channel);
    LaunchController.active.value = c;
    final runtime = RecordingRuntime(
      const LocalRuntimeState(
        loaded: true,
        status: RuntimeStatus(phase: RuntimePhase.installed, bundledVersion: 'r1', installedVersion: 'r1'),
      ),
    );
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: const RootGate(home: Scaffold(body: Text('home'))),
        brightness: Brightness.light,
        overrides: [
          localRuntimeProvider.overrideWith(() => runtime),
          settingsProvider.overrideWith(
            () => FakeSettings(const AppSettings(loaded: true, apiKey: 'key', autoStartLocal: true)),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(channel.marks, contains('ready'));
    // The engine was asked to start, and nobody waited for it.
    expect(runtime.starts, ['start']);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the app root tells a held cold start when this phone\'s engine is running', (tester) async {
    usePhone(tester);
    final c = LaunchController(
      snapshot: snapshotFor(sdk: 30, systemSplash: false, coldEngine: true),
      channel: FakeLaunchChannel(),
    );
    LaunchController.active.value = c;
    final runtime = RecordingRuntime(
      const LocalRuntimeState(
        loaded: true,
        status: RuntimeStatus(phase: RuntimePhase.starting, bundledVersion: 'r1', installedVersion: 'r1'),
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
          localRuntimeProvider.overrideWith(() => runtime),
        ],
        child: const DshApp(home: _Counter()),
      ),
    );
    await tester.pump();
    c.ready();
    await tester.pump(const Duration(milliseconds: 300));
    expect(c.phase, LaunchPhase.playing);
    runtime.emit(
      const LocalRuntimeState(
        loaded: true,
        status: RuntimeStatus(phase: RuntimePhase.running, bundledVersion: 'r1', installedVersion: 'r1'),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(c.phase, LaunchPhase.leaving);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(LaunchController.active.value, isNull);
  });

  testWidgets('the app root: the layer over everything, then gone; the page keeps its state', (tester) async {
    usePhone(tester);
    final c = LaunchController(snapshot: snapshotFor(sdk: 30, systemSplash: false), channel: FakeLaunchChannel());
    LaunchController.active.value = c;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true)))],
        child: const DshApp(home: _Counter()),
      ),
    );
    await tester.pump();
    expect(find.byType(LaunchOverlay), findsOneWidget);
    expect(c.phase, LaunchPhase.playing);
    // A tap skips the launch screen, and doesn't reach the page under it.
    await tester.tap(find.text('taps 0'), warnIfMissed: false);
    await tester.pump();
    expect(find.text('taps 0'), findsOneWidget);
    expect(c.phase, LaunchPhase.leaving);
    c.ready();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(c.phase, LaunchPhase.gone);
    expect(find.byType(LaunchOverlay), findsNothing);
    expect(LaunchController.active.value, isNull);
    await tester.tap(find.text('taps 0'));
    await tester.pump();
    expect(find.text('taps 1'), findsOneWidget);
  });
}
