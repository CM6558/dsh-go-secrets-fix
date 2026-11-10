import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../runtime/runtime_bridge.dart';
import '../runtime/runtime_state.dart';

/// Multi-step engine actions built on [localRuntimeProvider].
///
/// They take the [ProviderContainer] (not a WidgetRef) so they keep working after
/// the screen that started them is popped.
abstract final class EngineControl {
  /// Stops the local DSH, waits until the process has actually exited, then starts it again.
  /// [mode] null keeps the current mode (a restart in safe mode stays in safe mode).
  static Future<void> restart(ProviderContainer container, {EngineMode? mode}) async {
    final runtime = container.read(localRuntimeProvider.notifier);
    final phase = container.read(localRuntimeProvider).status.phase;
    if (phase == RuntimePhase.running || phase == RuntimePhase.starting || phase == RuntimePhase.stopping) {
      await _stopAndWait(container);
    }
    if (mode == null) {
      await runtime.start();
    } else {
      await runtime.startIn(mode);
    }
  }

  /// Starts the engine unless it is already starting or running.
  static Future<void> ensureStarted(ProviderContainer container) async {
    final phase = container.read(localRuntimeProvider).status.phase;
    if (phase == RuntimePhase.installed || phase == RuntimePhase.error) {
      await container.read(localRuntimeProvider.notifier).start();
    }
  }

  /// Whether the launch-time auto start should run. After two failures in a row with
  /// automatic safe mode turned off, the failure card waits for the user instead.
  /// In every other case `start()` itself picks the right mode, so callers need
  /// nothing else.
  static bool shouldAutoStart(RuntimeStatus status) =>
      !(status.safeState == SafeModeState.off && !status.autoSafe && status.strikes >= 2);

  /// Restarts in safe mode, first renaming the given home-level files out of the way.
  static Future<void> enterSafeMode(ProviderContainer container, {List<String> moveAside = const []}) async {
    if (moveAside.isNotEmpty) {
      await container.read(runtimeBridgeProvider).moveAside(moveAside);
    }
    await restart(container, mode: EngineMode.safe);
  }

  /// Back to the user's own profile; failing again within two minutes returns to safe mode.
  static Future<void> leaveSafeMode(ProviderContainer container) => restart(container, mode: EngineMode.normal);

  /// Puts the main profile back to its last good plugin set, then starts in normal mode
  /// (from safe mode that is the two-minute trial). Needs no model, key or network.
  static Future<LastKnownGood> restoreLastKnownGood(ProviderContainer container) async {
    final status = container.read(localRuntimeProvider).status;
    final busy =
        status.phase == RuntimePhase.running ||
        status.phase == RuntimePhase.starting ||
        status.phase == RuntimePhase.stopping;
    // A normal-mode DSH must not be running on the profile being rewritten; a safe one may.
    if (busy && !status.inSafeMode) await _stopAndWait(container);
    final changed = await container.read(runtimeBridgeProvider).restoreLastKnownGood();
    await restart(container, mode: EngineMode.normal);
    return changed;
  }

  static Future<void> _stopAndWait(ProviderContainer container) async {
    final stopped = Completer<void>();
    final sub = container.listen<RuntimePhase>(localRuntimeProvider.select((s) => s.status.phase), (_, next) {
      if (!next.isBusy && next != RuntimePhase.running && !stopped.isCompleted) {
        stopped.complete();
      }
    });
    try {
      if (container.read(localRuntimeProvider).status.phase != RuntimePhase.stopping) {
        await container.read(localRuntimeProvider.notifier).stop();
      }
      // DshProcess sends SIGTERM and escalates on its own; don't wait forever.
      await stopped.future.timeout(const Duration(seconds: 20), onTimeout: () {});
    } finally {
      sub.close();
    }
  }
}
