// The live view and data of one surface instance (a status line, a panel):
// docs/design/native-plugins-protocol.md §4.2–§4.5.
// A panel reads its view and initial data (`GET views`), then follows the
// stream from that data's revision; a status line only follows the stream.
// The stream hands over whole snapshots (it applies the merge patches), so
// this only swaps data in.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/hosts_state.dart';
import 'native_model.dart';
import 'native_state.dart';

/// One surface instance: a plugin's strip or panel in a conversation.
@immutable
class NativeSurfaceKey {
  const NativeSurfaceKey({
    required this.package,
    required this.surface,
    required this.id,
    this.scope = DshGoScope.none,
    this.live = true,
  });

  final String package;

  /// [NativeSurface.composerStrip] or [NativeSurface.panel].
  final NativeSurface surface;
  final String id;
  final DshGoScope scope;

  /// The plugin pushes data: follow the stream.
  final bool live;

  /// Prefix of this surface's runtime issues (`/runtime/usage`).
  String get pointer => '/runtime/$id';

  @override
  bool operator ==(Object other) =>
      other is NativeSurfaceKey &&
      other.package == package &&
      other.surface == surface &&
      other.id == id &&
      other.scope == scope &&
      other.live == live;

  @override
  int get hashCode => Object.hash(package, surface, id, scope, live);

  @override
  String toString() => 'NativeSurfaceKey($package/$id, $scope)';
}

/// What a surface shows right now.
@immutable
class NativeSurfaceState {
  const NativeSurfaceState({this.view, this.data, this.title, this.loading = true, this.offline = false, this.failure});

  /// The plugin's view tree (panels; null until read).
  final Object? view;

  /// The data model (null: nothing yet).
  final Object? data;

  /// The panel's title as the bridge gave it.
  final String? title;

  /// Waiting for the first view (panel) or data (strip).
  final bool loading;

  /// The bridge can't be reached (no route on this host, the socket is down).
  final bool offline;

  /// Why the plugin can't show this now: a protocol code (`not-found`,
  /// `degraded`, `timeout`, `plugin-error` …).
  final String? failure;

  bool get hasView => view != null;

  NativeSurfaceState copyWith({
    Object? view,
    Object? data,
    bool clearData = false,
    String? title,
    bool? loading,
    bool? offline,
    String? failure,
    bool clearFailure = false,
  }) => NativeSurfaceState(
    view: view ?? this.view,
    data: clearData ? null : (data ?? this.data),
    title: title ?? this.title,
    loading: loading ?? this.loading,
    offline: offline ?? this.offline,
    failure: clearFailure ? null : (failure ?? this.failure),
  );
}

class NativeSurfaceController extends Notifier<NativeSurfaceState> {
  NativeSurfaceController(this.key);

  final NativeSurfaceKey key;

  StreamSubscription<DshGoEvent>? _sub;
  StreamSubscription<DshGoLink>? _links;
  String? _rev;
  int _reads = 0;

  /// Changes whenever a view read starts or this subscription is replaced.
  /// An invoke may use it to reject effects belonging to an older surface.
  int get generation => _reads;
  HostRef? _host;
  NativeSurfaceState? _retained;

  bool get _panel => key.surface == NativeSurface.panel;

  @override
  NativeSurfaceState build() {
    final host = ref.watch(activeHostProvider);
    if (host != _host) {
      _host = host;
      _retained = null;
      _rev = null;
    }
    final client = ref.watch(nativeBridgeProvider);
    ref.onDispose(_stop);
    if (client == null) {
      return _retained?.copyWith(loading: false, offline: true) ??
          const NativeSurfaceState(loading: false, offline: true);
    }
    final known = ref.watch(nativeRawContributionsProvider.select((raw) => raw.value != null));
    final available = ref.watch(
      nativeContributionsProvider.select((contributions) {
        final plugin = contributions.plugin(key.package);
        if (plugin == null || !plugin.native) return false;
        return _panel
            ? plugin.panels.any((panel) => panel.id == key.id)
            : plugin.strips.any((strip) => strip.id == key.id);
      }),
    );
    if (known && !available) {
      _retained = null;
      _rev = null;
      return const NativeSurfaceState(loading: false, failure: 'not-found');
    }
    final stream = ref.watch(nativeStreamProvider);
    if (_panel) {
      unawaited(Future.microtask(_read));
    } else if (key.live && stream != null) {
      _follow(stream);
    } else {
      return const NativeSurfaceState(loading: false);
    }
    // A v2 form keeps its local widget and drafts during reconnect. Editing
    // resumes only after the new bridge has returned a current view.
    return _retained?.copyWith(loading: false, offline: true) ?? const NativeSurfaceState();
  }

  void _set(NativeSurfaceState next) {
    state = next;
    _retained = next.view is Map && (next.view as Map)['v'] == 2 ? next : null;
  }

  NativeDiagnosticsController get _diagnostics => ref.read(nativeDiagnosticsProvider.notifier);

  void _issue(String code) =>
      _diagnostics.report(key.package, key.pointer, [NativeIssue('', nativeIssueText(code), code: code)]);

  /// Reads the panel's view (and initial data); then follows the stream.
  Future<void> _read() async {
    if (!ref.mounted) return;
    final client = ref.read(nativeBridgeProvider);
    if (client == null) return;
    final read = ++_reads;
    try {
      final view = await client.view(key.package, key.id, scope: key.scope, caps: ref.read(nativeCapsProvider));
      if (!ref.mounted || read != _reads) return;
      _diagnostics.view(key.package, view.bytes);
      _diagnostics.report(key.package, '', [for (final i in view.issues) NativeIssue.fromBridge(i)]);
      _rev = view.rev;
      _set(NativeSurfaceState(view: view.view, data: view.data, title: view.title, loading: false));
      final stream = ref.read(nativeStreamProvider);
      if ((view.live || key.live) && stream != null && _sub == null) _follow(stream, data: view.data);
    } on DshException catch (e) {
      if (!ref.mounted || read != _reads) return;
      final code = e is DshRemoteException && e.code.startsWith('dsh-go/') && !e.code.startsWith('dsh-go/http-')
          ? e.code.substring('dsh-go/'.length)
          : null;
      if (code != null) _issue(code);
      _set(state.copyWith(loading: false, offline: code == null, failure: code));
    }
  }

  void _follow(DshGoStream stream, {Object? data}) {
    _sub = stream.subscribe(pkg: key.package, id: key.id, scope: key.scope, rev: _rev, data: data).listen(_onEvent);
    _links = stream.links.listen((link) {
      if (!ref.mounted) return;
      final offline = link == DshGoLink.backoff;
      if (offline != state.offline) _set(state.copyWith(offline: offline));
    });
  }

  void _stop() {
    _reads++;
    unawaited(_sub?.cancel());
    unawaited(_links?.cancel());
    _sub = null;
    _links = null;
  }

  void _onEvent(DshGoEvent event) {
    if (!ref.mounted) return;
    switch (event) {
      case DshGoData(:final data, :final rev):
        _rev = rev;
        _set(
          data == null
              ? state.copyWith(clearData: true, loading: false, clearFailure: true)
              : state.copyWith(data: data, loading: false, clearFailure: true),
        );
      case DshGoStale():
        unawaited(_read());
      case DshGoEnded(:final reason):
        _stop();
        _issue(reason);
        _set(state.copyWith(loading: false, failure: reason));
    }
  }

  /// A `patch` effect: merged in now (the bridge merges it into the source
  /// too, so the next snapshot agrees).
  void patch(Object? data) {
    _set(state.copyWith(data: mergePatch(state.data, data), loading: false));
  }

  /// A `refresh` effect, or 重试: read the view again (a panel), or follow
  /// the stream again (a strip).
  void refresh() {
    if (!ref.mounted) return;
    if (ref.read(nativeBridgeProvider) == null) {
      _set(state.copyWith(loading: false, offline: true));
      return;
    }
    _set(state.copyWith(loading: !state.hasView, offline: false, clearFailure: true));
    if (_panel) {
      unawaited(_read());
      return;
    }
    final stream = ref.read(nativeStreamProvider);
    if (stream == null) return;
    _stop();
    _follow(stream);
    stream.foreground();
  }
}

final nativeSurfaceProvider = NotifierProvider.autoDispose
    .family<NativeSurfaceController, NativeSurfaceState, NativeSurfaceKey>(NativeSurfaceController.new);
