import 'dart:async';
import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/settings_state.dart';
import '../state/read_list_epoch.dart';
import 'runtime_bridge.dart';

final runtimeBridgeProvider = Provider<RuntimeBridge>((ref) => RuntimeBridge());

/// [RuntimeBridge.batteryExempt]; invalidate to read it again.
final batteryExemptProvider = FutureProvider<bool?>((ref) => ref.watch(runtimeBridgeProvider).batteryExempt());

/// A one-off message from the runtime (e.g. "已用安全模式启动"); [seq] tells repeats apart.
class RuntimeNotice {
  const RuntimeNotice(this.seq, this.text);
  final int seq;
  final String text;
}

/// What the UI needs to know about the local runtime.
class LocalRuntimeState {
  const LocalRuntimeState({
    this.status = const RuntimeStatus.unknown(),
    this.progress,
    this.logs = const [],
    this.loaded = false,
    this.notice,
  });

  final RuntimeStatus status;
  final RuntimeProgressEvent? progress;
  final List<String> logs;

  /// False until the first status arrives from the native side.
  final bool loaded;

  /// The latest notice; shown once by `SafeModeNoticeListener`.
  final RuntimeNotice? notice;

  LocalRuntimeState copyWith({
    RuntimeStatus? status,
    RuntimeProgressEvent? progress,
    bool clearProgress = false,
    List<String>? logs,
    bool? loaded,
    RuntimeNotice? notice,
  }) => LocalRuntimeState(
    status: status ?? this.status,
    progress: clearProgress ? null : (progress ?? this.progress),
    logs: logs ?? this.logs,
    loaded: loaded ?? this.loaded,
    notice: notice ?? this.notice,
  );
}

class LocalRuntimeController extends Notifier<LocalRuntimeState> {
  static const _maxLogs = 1000;
  final _logs = ListQueue<String>();
  StreamSubscription<RuntimeEvent>? _sub;

  RuntimeBridge get _bridge => ref.read(runtimeBridgeProvider);

  @override
  LocalRuntimeState build() {
    _sub = _bridge.events.listen(_onEvent, onError: (_) {});
    ref.onDispose(() => _sub?.cancel());
    unawaited(_refresh());
    return const LocalRuntimeState();
  }

  Future<void> _refresh() async {
    final r = ref;
    try {
      final status = await _bridge.status();
      if (!r.mounted) return;
      // Apply it before the slower log read: a status event meanwhile is newer than this.
      state = state.copyWith(status: status, loaded: true, clearProgress: status.phase != RuntimePhase.installing);
      final logs = await _bridge.logs(lines: 300);
      if (!r.mounted) return;
      _logs
        ..clear()
        ..addAll(logs);
      state = state.copyWith(logs: List.unmodifiable(_logs));
    } catch (_) {
      if (r.mounted) state = state.copyWith(loaded: true);
    }
  }

  void _onEvent(RuntimeEvent event) {
    switch (event) {
      case RuntimeStatusEvent(:final status):
        state = state.copyWith(status: status, loaded: true, clearProgress: status.phase != RuntimePhase.installing);
      case RuntimeProgressEvent():
        state = state.copyWith(progress: event);
      case RuntimeLogEvent(:final line):
        _logs.addLast(line);
        while (_logs.length > _maxLogs) {
          _logs.removeFirst();
        }
        state = state.copyWith(logs: List.unmodifiable(_logs));
      case RuntimeNoticeEvent(:final text):
        state = state.copyWith(notice: RuntimeNotice((state.notice?.seq ?? 0) + 1, text));
    }
  }

  Future<void> install() {
    ref.read(readListCredentialEpochProvider.notifier).advance();
    return _bridge.install();
  }

  /// Installs without what a reset kept but could not put back.
  Future<void> installDroppingKept() {
    ref.read(readListCredentialEpochProvider.notifier).advance();
    return _bridge.install(dropKept: true);
  }

  /// The API key is not passed here: it is written to DSH's own credential store
  /// after connecting (see connection_state.dart), so it can change without a restart.
  /// Keeps the current mode: in safe mode this starts safe mode again.
  Future<void> start() {
    final settings = ref.read(settingsProvider);
    return _bridge.start(phoneStorage: settings.phoneStorage, visualReplies: settings.visualReplies);
  }

  /// Starts in [mode]; [EngineMode.normal] from safe mode begins the two-minute trial.
  Future<void> startIn(EngineMode mode) {
    final settings = ref.read(settingsProvider);
    return _bridge.start(phoneStorage: settings.phoneStorage, visualReplies: settings.visualReplies, mode: mode);
  }

  Future<void> stop() => _bridge.stop();

  Future<void> reset() => resetKeeping(const ResetKeep());

  /// Resets the runtime; [keep] comes back with the next install.
  Future<void> resetKeeping(ResetKeep keep) async {
    final r = ref;
    ref.read(readListCredentialEpochProvider.notifier).advance();
    await _bridge.reset(keep: keep);
    if (r.mounted) await _refresh();
  }
}

final localRuntimeProvider = NotifierProvider<LocalRuntimeController, LocalRuntimeState>(LocalRuntimeController.new);
