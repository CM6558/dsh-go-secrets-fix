import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener, AppLifecycleState, WidgetsBinding;

import '../l10n/l10n.dart';
import '../runtime/runtime_state.dart';
import '../usage/usage_stats.dart';
import 'connection_state.dart';
import 'read_list_cache.dart';
import 'read_list_identity.dart';
import 'engine_error_text.dart';
import 'hosts_state.dart';

/// Plugin management and the plugin market for the active host.
///
/// Writes go through `pluginManager/*` (the only write path DSH has, the same
/// on every host). The market is a format-1 index read by the app itself, so
/// it works on hosts without the experimental `pluginMarket` bundle and over
/// the relay.

/// Default market: dshfind's format-1 index (attribution "数据来自 dshfind").
const dshfindIndexUrl = 'https://api.dshfind.com/market/dsh-index.json';

/// Profile `dsh web` runs with; the app starts every host it drives that way.
const pluginProfile = 'web';

/// Install command for hosts the app cannot install on (relay).
String pluginInstallCommand(String spec) => 'dsh plugin --profile $pluginProfile add $spec';

// ── Market index ─────────────────────────────────────────────────────────────

typedef MarketIndexFetcher = Future<MarketIndex> Function(Uri url);

/// Thrown when the index could not be downloaded.
class MarketFetchException implements Exception {
  const MarketFetchException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// GETs [url] and reads it in a background isolate (≈3 MB for dshfind).
Future<MarketIndex> fetchMarketIndex(Uri url) async {
  final http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..userAgent = 'dsh-app';
  try {
    final request = await http.getUrl(url);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw MarketFetchException(appL10n.stateMarketHttpError(response.statusCode));
    }
    final text = await response
        .transform(utf8.decoder)
        .fold(StringBuffer(), (buffer, chunk) {
          if (buffer.length + chunk.length > 32 * 1024 * 1024) {
            throw MarketFetchException(appL10n.stateMarketTooLarge);
          }
          return buffer..write(chunk);
        })
        .timeout(const Duration(seconds: 60));
    final body = text.toString();
    return await Isolate.run(() => parseMarketIndexText(body, url));
  } on SocketException {
    throw MarketFetchException(appL10n.stateMarketUnreachable);
  } on TimeoutException {
    throw MarketFetchException(appL10n.stateMarketTimeout);
  } on HttpException {
    throw MarketFetchException(appL10n.stateMarketInterrupted);
  } on TlsException {
    // The handshake or the certificate (HandshakeException, CertificateException):
    // a captive portal, a proxy or a wrong clock, never the catalog's format.
    throw MarketFetchException(appL10n.stateMarketInsecure);
  } on IOException {
    throw MarketFetchException(appL10n.stateMarketUnreachable);
  } on OSError {
    throw MarketFetchException(appL10n.stateMarketUnreachable);
  } finally {
    http.close(force: true);
  }
}

final marketIndexFetcherProvider = Provider<MarketIndexFetcher>((ref) => fetchMarketIndex);

/// One market entry with what the list needs precomputed.
class MarketEntry {
  MarketEntry(this.plugin, {required this.webOnly, required this.categoryTitle})
    : haystack = _haystack(plugin),
      featured = plugin.labels.contains('featured');

  final MarketPlugin plugin;

  /// Likely only affects the DSH web UI ([isWebOnlyPlugin]).
  final bool webOnly;
  final bool featured;
  final String? categoryTitle;

  /// Lowercased name, titles, descriptions, keywords and author.
  final String haystack;

  String get name => plugin.name;

  static String _haystack(MarketPlugin p) =>
      [p.name, ...?p.title?.all, ...?p.description?.all, ...p.keywords, ?p.author].join('\n').toLowerCase();

  /// Every whitespace-separated term is a substring (works for Chinese
  /// without tokenizing: "小说 写作" matches "小说创作…写作").
  bool matches(List<String> terms) => terms.every(haystack.contains);
}

/// The fetched index plus derived entries.
class MarketCatalog {
  MarketCatalog(this.index)
    : entries = [
        for (final plugin in index.plugins)
          MarketEntry(
            plugin,
            webOnly: isWebOnlyPlugin(plugin, index),
            categoryTitle: index.categories[plugin.category]?.title.resolve('zh'),
          ),
      ];

  final MarketIndex index;
  final List<MarketEntry> entries;

  late final Map<String, MarketEntry> byName = {for (final e in entries) e.name: e};

  /// Declared categories that have at least one entry, in index order.
  late final List<MarketDeclaration> categories = [
    for (final declaration in index.categories.values)
      if (entries.any((e) => e.plugin.category == declaration.id)) declaration,
  ];
}

/// Fetched once per app session (kept in memory); `ref.invalidate` reloads.
final marketCatalogProvider = FutureProvider<MarketCatalog>((ref) async {
  final index = await ref.watch(marketIndexFetcherProvider)(Uri.parse(dshfindIndexUrl));
  return MarketCatalog(index);
}, retry: (_, _) => null);

const _webOnlyCategoryIds = {'ui', 'skin', 'skins', 'theme', 'themes', 'client', 'clients', 'web', 'webui', 'web-ui'};
final _webOnlyCategoryTitle = RegExp(r'\b(?:ui|themes?|skins?|panels?|clients?|appearance)\b', caseSensitive: false);
final _webOnlyName = RegExp(r'(?:client-ui|web-ui|webui|(?:^|[-/])(?:themes?|skins?)(?:-|$))');

/// Heuristic for "only changes the DSH web UI or is a separate client".
///
/// Format 1 has no surface field, so this reads what indexes do carry:
/// * the category id: dshfind `ui` (Panels & Views), `skin` (Skins & Themes),
///   `client` (Clients, e.g. dsh-TUI); awesome-dsh-plugin `ui`, `theme`;
/// * otherwise the category's English title (UI / theme / skin / panel /
///   client / appearance), for other indexes;
/// * for uncategorized entries, package names like `dsh-client-ui-*`,
///   `*-web-ui`, `*-theme`, `skin-*`.
/// Such plugins load into DSH's web profile but do nothing for this app's
/// native chat; they are hidden by default behind 「显示网页版插件」.
bool isWebOnlyPlugin(MarketPlugin plugin, MarketIndex index) {
  final category = plugin.category;
  if (category != null) {
    if (_webOnlyCategoryIds.contains(category.toLowerCase())) return true;
    final title = index.categories[category]?.title;
    if (title != null && _webOnlyCategoryTitle.hasMatch(title.values['en'] ?? title.resolve('en'))) {
      return true;
    }
  }
  return _webOnlyName.hasMatch(plugin.name);
}

/// Search box, category chip and the web-only switch.
class MarketFilter {
  const MarketFilter({this.query = '', this.category, this.showWebOnly = false});

  final String query;

  /// Category id; null = all.
  final String? category;
  final bool showWebOnly;

  List<String> get terms =>
      query.trim().toLowerCase().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList(growable: false);

  MarketFilter copyWith({String? query, String? Function()? category, bool? showWebOnly}) => MarketFilter(
    query: query ?? this.query,
    category: category == null ? this.category : category(),
    showWebOnly: showWebOnly ?? this.showWebOnly,
  );
}

class MarketFilterController extends Notifier<MarketFilter> {
  @override
  MarketFilter build() => const MarketFilter();

  void setQuery(String query) => state = state.copyWith(query: query);

  void setCategory(String? category) => state = state.copyWith(category: () => category);

  void setShowWebOnly(bool show) => state = state.copyWith(showWebOnly: show);
}

final marketFilterProvider = NotifierProvider<MarketFilterController, MarketFilter>(MarketFilterController.new);

/// Entries passing [filter], in index order. Pure for testing.
List<MarketEntry> filterMarket(MarketCatalog catalog, MarketFilter filter) {
  final terms = filter.terms;
  final category = filter.category;
  return [
    for (final entry in catalog.entries)
      if ((filter.showWebOnly || !entry.webOnly || category != null && entry.plugin.category == category) &&
          (category == null || entry.plugin.category == category) &&
          (terms.isEmpty || entry.matches(terms)))
        entry,
  ];
}

/// How many entries the web-only switch hides for the current filter.
int hiddenWebOnlyCount(MarketCatalog catalog, MarketFilter filter) {
  if (filter.showWebOnly) return 0;
  return filterMarket(catalog, filter.copyWith(showWebOnly: true)).length - filterMarket(catalog, filter).length;
}

final marketResultsProvider = Provider<AsyncValue<List<MarketEntry>>>((ref) {
  final filter = ref.watch(marketFilterProvider);
  return ref.watch(marketCatalogProvider).whenData((catalog) => filterMarket(catalog, filter));
});

// ── Active host ──────────────────────────────────────────────────────────────

/// What plugins can be managed on: the active host's client and what its
/// carrier allows.
class PluginHost {
  const PluginHost({required this.client, required this.label, required this.kind, this.safeMode = false});

  factory PluginHost.of(HostConnection connection, {bool safeMode = false}) =>
      PluginHost(client: connection.client, label: connection.label, kind: connection.kind, safeMode: safeMode);

  final DshClient client;
  final String label;
  final HostKind kind;

  bool get isLocal => kind == HostKind.local;

  /// The local engine runs a clean repair profile with the plugin manager off:
  /// no installs or removals until it's back to normal.
  final bool safeMode;

  /// The relay's allow-list has no install/remove; there the app shows the
  /// command to run on that computer instead.
  bool get canInstall => !safeMode && client.canInstallPlugins;
}

/// The on-device engine runs in safe mode. A seam of its own so plugin state
/// doesn't need the native runtime (tests override it).
final localSafeModeProvider = Provider<bool>(
  (ref) => ref.watch(localRuntimeProvider.select((s) => s.status.inSafeMode)),
);

final pluginHostProvider = Provider<PluginHost?>((ref) {
  final connection = ref.watch(readListLiveConnectionProvider);
  if (connection == null) return null;
  final safeMode = connection.isLocal && ref.watch(localSafeModeProvider);
  return PluginHost.of(connection, safeMode: safeMode);
});

// ── Installed bundles ────────────────────────────────────────────────────────

/// How a bundle shows up on 「已安装」.
enum BundleGroup {
  /// Third-party bundles the profile depends on (and selected names with a
  /// problem).
  installed,

  /// Official optional bundles shipped with DSH: switch only.
  official,

  /// Official on-demand entries not installed yet.
  onDemand,

  /// Installation-provided infrastructure (dsh-base, web-app, ...): hidden.
  hidden,
}

BundleGroup bundleGroup(PluginBundle bundle) {
  if (bundle.installed) {
    return bundle.official ? BundleGroup.official : BundleGroup.installed;
  }
  if (bundle.optional) return BundleGroup.official;
  if (bundle.isOnDemand) return BundleGroup.onDemand;
  // Selected but broken names (`not-bundle`, unreadable files) stay visible.
  if (bundle.error != null && bundle.enabled && !bundle.official) {
    return BundleGroup.installed;
  }
  return BundleGroup.hidden;
}

/// A confirmed uninstall waiting out its undo window: nothing reaches the
/// Host before the window ends. [undo] drops it; [commitNow] ends the window
/// early.
class PendingPluginRemoval {
  PendingPluginRemoval(this.bundle, this.cancel);
  final PluginBundle bundle;

  /// Drops the plan if nothing has been sent yet.
  final bool Function() cancel;
  final _done = Completer<PluginOperationResult?>();
  final _windowClosed = Completer<void>();
  Timer? _timer;
  bool _started = false;
  bool _committing = false;
  bool _undone = false;
  late bool Function() _commitNow;
  bool get canUndo => !_windowClosed.isCompleted;
  Future<void> get windowClosed => _windowClosed.future;

  /// The Host's answer; null when the plan was dropped before sending.
  Future<PluginOperationResult?> get done => _done.future;

  /// 撤销: [cancel], remembered as the user's choice.
  bool undo() {
    if (!canUndo || _committing) return false;
    _undone = true;
    if (cancel()) return true;
    _undone = false;
    return false;
  }

  /// Uninstalls now instead of when the window ends: the app is leaving the
  /// screen, or a newer undo notice takes this one's place.
  bool commitNow() => _commitNow();

  /// Dropped with 撤销.
  bool get undone => _undone;

  /// The removal has been sent to the Host; it can no longer be taken back.
  bool get sent => _committing;
  void _closeWindow() {
    _timer?.cancel();
    if (!_windowClosed.isCompleted) _windowClosed.complete();
  }
}

/// `pluginManager/listBundles` of the active host; refreshed on
/// `plugin-manager/changed`. Null while disconnected.
class InstalledPluginsController extends AsyncNotifier<List<PluginBundle>?> {
  DshClient? _client;
  int _loadSeq = 0;
  Future<List<PluginBundle>>? _buildRead;
  List<PluginBundle> _latest = const [];
  final _removals = <String, PendingPluginRemoval>{};
  static const removalUndoWindow = Duration(seconds: 4);

  List<PluginBundle> _visible(List<PluginBundle> bundles) {
    final cache = ref.read(readListCacheProvider);
    return cache.derive([
      for (final b in bundles)
        if (!_removals.containsKey(b.name)) b,
    ], cache.origin(bundles));
  }

  void _showLatest() {
    if (ref.mounted && state.hasValue) state = AsyncData(_visible(_latest));
  }

  bool cancelRemoval(String name) {
    final pending = _removals[name];
    if (pending == null || pending._committing) return false;
    _removals.remove(name);
    pending._closeWindow();
    pending._done.complete(null);
    _showLatest();
    return true;
  }

  static Object _bundleIdentity(PluginBundle b) => (
    b.name,
    b.version,
    b.source,
    b.installTargetSpec,
    b.installTargetVersion,
    b.installed,
    b.enabled,
    b.removable,
    b.official,
    b.availability,
  );

  /// Keep the real inventory separate: refreshes must not resurrect waiting rows.
  PendingPluginRemoval scheduleRemoval(PluginBundle bundle) {
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    if (lifecycleState == AppLifecycleState.hidden ||
        lifecycleState == AppLifecycleState.paused ||
        lifecycleState == AppLifecycleState.detached) {
      throw const DshClosedException('app is not visible');
    }
    final existing = _removals[bundle.name];
    if (existing != null) {
      if (!existing.canUndo) throw StateError('uninstall in progress');
      return existing;
    }
    final host = ref.read(pluginHostProvider);
    final client = _client;
    final installing =
        ref.exists(pluginInstallsProvider) && (ref.read(pluginInstallsProvider)[bundle.name]?.isActive ?? false);
    final current = _latest.where((b) => b.name == bundle.name).firstOrNull;
    if (host == null ||
        client == null ||
        !host.canInstall ||
        !bundle.removable ||
        installing ||
        current == null ||
        _bundleIdentity(current) != _bundleIdentity(bundle)) {
      throw const DshClosedException('plugin owner or bundle changed');
    }
    final generation = client.mux.generation;
    final ready = client.mux.lastReadyGenerationNumber;
    late final PendingPluginRemoval pending;
    pending = PendingPluginRemoval(
      bundle,
      () => identical(_removals[bundle.name], pending) && cancelRemoval(bundle.name),
    );
    bool currentOwner() =>
        ref.mounted &&
        identical(_removals[bundle.name], pending) &&
        identical(ref.read(pluginHostProvider), host) &&
        identical(_client, client) &&
        identical(client.mux.generation, generation) &&
        client.mux.lastReadyGenerationNumber == ready;
    Future<void> commit() async {
      if (pending._started) return;
      pending._started = true;
      if (!currentOwner()) {
        pending.cancel();
        return;
      }
      try {
        // The remove API has no expectedRevision. Re-read immediately before
        // dispatch; a race with an external process after this read is a Host limit.
        final inventory = await client.listBundles();
        if (!currentOwner() || !pending.canUndo) {
          pending.cancel();
          return;
        }
        final fresh = inventory.where((b) => b.name == bundle.name).firstOrNull;
        if (fresh == null || _bundleIdentity(fresh) != _bundleIdentity(bundle)) {
          _latest = inventory;
          pending.cancel();
          return;
        }
        pending._committing = true;
        pending._closeWindow();
        final result = await client.removeBundle(bundle.name);
        if (result.succeeded && currentOwner()) {
          final cache = ref.read(readListCacheProvider);
          _latest = cache.derive([
            for (final b in _latest)
              if (b.name != bundle.name) b,
          ], cache.origin(_latest));
        }
        if (!pending._done.isCompleted) pending._done.complete(result);
      } on Object catch (error, stack) {
        if (!pending._done.isCompleted) pending._done.completeError(error, stack);
      } finally {
        pending._closeWindow();
        if (identical(_removals[bundle.name], pending)) {
          _removals.remove(bundle.name);
          _showLatest();
          if (ref.mounted && identical(_client, client)) {
            unawaited(refresh().catchError((Object _) {}));
          }
        }
      }
    }

    pending._commitNow = () {
      if (!identical(_removals[bundle.name], pending) || !pending.canUndo || pending._started) return false;
      pending._timer?.cancel();
      unawaited(commit());
      return true;
    };
    _removals[bundle.name] = pending;
    // Leaving the screen (Home, recents, another app on top; the process may be
    // killed from there) uninstalls at once: the notice said 已卸载, and the
    // undo it offered is gone with the screen.
    final lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (state != AppLifecycleState.resumed) pending.commitNow();
      },
    );
    unawaited(pending.windowClosed.then((_) => lifecycle.dispose()));
    pending._timer = Timer(removalUndoWindow, () => unawaited(commit()));
    _showLatest();
    return pending;
  }

  @override
  Future<List<PluginBundle>?> build() async {
    final r = ref;
    // Provider rebuild means the previous owner lease ended. No deferred work
    // is persisted across app exit or a new Host connection.
    for (final pending in _removals.values.toList()) {
      pending._closeWindow();
      if (!pending._done.isCompleted) pending._done.complete(null);
    }
    _removals.clear();
    final seq = ++_loadSeq;
    final host = r.watch(pluginHostProvider);
    final identity = r.watch(readListIdentityProvider);
    ref.listen(activeHostProvider, (previous, next) {
      if (previous != next) {
        for (final name in _removals.keys.toList()) {
          cancelRemoval(name);
        }
      }
    });
    _client = host?.client;
    if (host == null) {
      _buildRead = null;
      return null;
    }
    final ownerChanges = host.client.mux.states.listen((_) {
      if (seq != _loadSeq) return;
      for (final name in _removals.keys.toList()) {
        cancelRemoval(name);
      }
    });
    Timer? debounce;
    void scheduleRefresh() {
      debounce?.cancel();
      debounce = Timer(const Duration(milliseconds: 300), () => unawaited(refresh().catchError((Object _) {})));
    }

    final sub = host.client.pluginManagerEvents.listen((event) {
      if (event is PluginManagerChangedEvent) scheduleRefresh();
    });
    final ready = host.client.hostEvents.listen((event) {
      if (event is HostReadyEvent) scheduleRefresh();
    });
    ref.onDispose(() {
      unawaited(ownerChanges.cancel());
      for (final pending in _removals.values.toList()) {
        pending._closeWindow();
        if (!pending._done.isCompleted) pending._done.complete(null);
      }
      _removals.clear();
      debounce?.cancel();
      unawaited(sub.cancel());
      unawaited(ready.cancel());
    });
    final bundles = await (_buildRead = host.client.listBundles());
    if (!r.mounted) return null;
    if (seq != _loadSeq) return state.value;
    final cache = r.read(readListCacheProvider);
    cache.stamp(bundles, identity, host.client);
    cache.put(readListKey(identity, ReadListKind.plugins), bundles, () => CachedPlugins(bundles));
    _latest = bundles;
    _counted(bundles);
    return _visible(bundles);
  }

  /// How many plugins 「已安装」 lists, for the usage statistics.
  void _counted(List<PluginBundle> bundles) => ref
      .read(usageStatsProvider.notifier)
      .plugins(bundles.where((b) => bundleGroup(b) == BundleGroup.installed && b.installed).length);

  /// Re-reads the list; keeps the old one (and rethrows) on failure.
  Future<void> refresh() async {
    final r = ref;
    final client = _client;
    if (client == null) return;
    // A build is already a refresh. Coalesce entry/HostReady kicks until
    // that build settles, so its Future cannot later overwrite a manual read.
    if (state.isLoading && _buildRead != null) {
      await _buildRead;
      return;
    }
    final identity = r.read(readListIdentityProvider);
    final seq = ++_loadSeq;
    final cache = r.read(readListCacheProvider);
    final activity = cache.beginRefresh(ReadListKind.plugins, identity);
    try {
      final bundles = await client.listBundles();
      if (r.mounted && seq == _loadSeq && identical(client, _client)) {
        final cache = r.read(readListCacheProvider);
        cache.stamp(bundles, identity, client);
        cache.put(readListKey(identity, ReadListKind.plugins), bundles, () => CachedPlugins(bundles));
        _latest = bundles;
        for (final pending in _removals.values.toList()) {
          final fresh = bundles.where((b) => b.name == pending.bundle.name).firstOrNull;
          if (fresh == null || _bundleIdentity(fresh) != _bundleIdentity(pending.bundle)) {
            cancelRemoval(pending.bundle.name);
          }
        }
        state = AsyncData(_visible(bundles));
        cache.finishRefresh(ReadListKind.plugins, activity);
        _counted(bundles);
      }
    } on Object catch (error, stack) {
      if (r.mounted && seq == _loadSeq && identical(client, _client)) {
        cache.finishRefresh(ReadListKind.plugins, activity, failed: true);
        if (!state.hasValue) state = AsyncError(error, stack);
      }
      rethrow;
    }
  }

  /// Switches a bundle layer (optimistic; reverts and rethrows on failure).
  Future<PluginOperationResult> setEnabled(PluginBundle bundle, bool enabled) async {
    if (_removals[bundle.name]?._committing == true) throw StateError('uninstall in progress');
    cancelRemoval(bundle.name);
    final r = ref;
    final client = _client;
    if (client == null) throw const DshClosedException('not connected');
    _patch(bundle.name, enabled);
    try {
      final result = await client.setBundleEnabled(bundle.name, enabled);
      if (!r.mounted || !identical(client, _client)) return result;
      if (!result.succeeded) _patch(bundle.name, bundle.enabled);
      unawaited(refresh().catchError((Object _) {}));
      return result;
    } on Object {
      if (r.mounted && identical(client, _client)) _patch(bundle.name, bundle.enabled);
      rethrow;
    }
  }

  /// Removes a profile bundle (files and selection; settings stay).
  Future<PluginOperationResult> remove(PluginBundle bundle) async {
    if (_removals[bundle.name]?._committing == true) throw StateError('uninstall in progress');
    cancelRemoval(bundle.name);
    final r = ref;
    final client = _client;
    if (client == null) throw const DshClosedException('not connected');
    final result = await client.removeBundle(bundle.name);
    if (r.mounted && identical(client, _client)) await refresh().catchError((Object _) {});
    return result;
  }

  void _patch(String name, bool enabled) {
    if (!ref.mounted || !state.hasValue) return;
    final cache = ref.read(readListCacheProvider);
    _latest = cache.derive(
      [for (final b in _latest) b.name == name ? _withEnabled(b, enabled) : b],
      cache.origin(_latest),
      confirmed: false,
    );
    _showLatest();
  }

  static PluginBundle _withEnabled(PluginBundle b, bool enabled) => PluginBundle(
    name: b.name,
    official: b.official,
    availability: b.availability,
    installTargetSpec: b.installTargetSpec,
    installTargetVersion: b.installTargetVersion,
    version: b.version,
    meta: b.meta,
    description: b.description,
    enabled: enabled,
    installed: b.installed,
    source: b.source,
    optional: b.optional,
    removable: b.removable,
    readOnlyReason: b.readOnlyReason,
    error: b.error,
    rows: b.rows,
    overrides: b.overrides,
  );
}

final installedPluginsProvider = AsyncNotifierProvider<InstalledPluginsController, List<PluginBundle>?>(
  InstalledPluginsController.new,
  retry: (_, _) => null,
);

final pluginListViewProvider = Provider.autoDispose<ReadListView<CachedPlugins>>((ref) {
  final source = ref.watch(installedPluginsProvider);
  final identity = ref.watch(readListIdentityProvider);
  final host = ref.watch(pluginHostProvider);
  final cache = ref.watch(readListCacheProvider);
  ref.watch(readListCacheChangesProvider);
  final raw = source.value;
  final activity = cache.refresh(ReadListKind.plugins, identity, raw);
  final current = raw != null && cache.current(raw, identity, host?.client);
  final ready =
      current && !source.isLoading && !source.hasError && activity?.pending != true && activity?.failed != true;
  final status = source.hasError || activity?.failed == true
      ? ReadListStatus.failed
      : host == null
      ? ReadListStatus.offline
      : ReadListStatus.updating;
  if (current) {
    return ReadListView(authoritative: true, readOnly: !ready, status: ready ? ReadListStatus.current : status);
  }
  return ReadListView(
    value: cache.get<CachedPlugins>(readListKey(identity, ReadListKind.plugins)),
    readOnly: true,
    status: status,
  );
});

/// Install state of a market entry against the installed list.
enum MarketInstallStatus { notInstalled, installed, updateAvailable }

MarketInstallStatus marketInstallStatus(MarketPlugin plugin, List<PluginBundle>? bundles) {
  if (bundles == null) return MarketInstallStatus.notInstalled;
  for (final bundle in bundles) {
    if (bundle.name != plugin.name || !(bundle.installed || bundle.availability == 'profile')) {
      continue;
    }
    final installed = bundle.version;
    if (installed != null && isExactSemver(installed) && compareSemver(plugin.latest.version, installed) > 0) {
      return MarketInstallStatus.updateAvailable;
    }
    return MarketInstallStatus.installed;
  }
  return MarketInstallStatus.notInstalled;
}

// ── Failures ─────────────────────────────────────────────────────────────────

enum PluginFailureKind {
  network,
  timeout,
  pnpmMissing,
  notFound,
  noMatchingVersion,
  tooNew,
  incompatible,
  diskFull,
  permission,
  integrity,
  buildBlocked,
  alreadyInstalled,
  notBundle,
  inUse,
  readOnly,
  cancelled,
  unsupported,
  connection,
  resultUnknown,
  unknown,
}

/// A failed plugin operation in plain Chinese.
class PluginFailure {
  const PluginFailure(this.kind, this.title, this.message, {this.detail, this.pendingBuilds = const []});

  final PluginFailureKind kind;
  final String title;
  final String message;

  /// pnpm / Host diagnostic for the expandable detail.
  final String? detail;

  /// Packages whose build scripts pnpm blocked (offer an explicit approval).
  final List<String> pendingBuilds;

  bool get canApproveBuilds => kind == PluginFailureKind.buildBlocked && pendingBuilds.isNotEmpty;

  bool get retryable => switch (kind) {
    PluginFailureKind.network ||
    PluginFailureKind.timeout ||
    PluginFailureKind.integrity ||
    PluginFailureKind.connection ||
    PluginFailureKind.unknown ||
    PluginFailureKind.noMatchingVersion => true,
    _ => false,
  };
}

String _registryName(String? registry) {
  if (registry == null) return appL10n.stateRegistryDefault;
  final host = Uri.tryParse(registry)?.host ?? registry;
  return switch (host) {
    'registry.npmjs.org' => appL10n.stateRegistryNpm,
    'registry.npmmirror.com' => appL10n.stateRegistryMirror,
    _ => host,
  };
}

String _requirementText(List<PluginIncompatibility> incompatible) {
  if (incompatible.isEmpty) return appL10n.statePluginIncompatible;
  final first = incompatible.first;
  final wanted = first.requirements['engines.dsh'] ?? first.requirements.values.firstOrNull;
  if (wanted == null) return appL10n.statePluginRuntimeIncompatible(first.runtimeVersion);
  return appL10n.statePluginRequiredVersion(wanted, first.runtimeVersion);
}

/// Maps a failed (or cancelled) [result] to user copy. [published] is the
/// version's index publish time, used to explain pnpm's 24-hour cooldown.
PluginFailure describeOperationFailure(
  PluginOperationResult result, {
  required bool isLocal,
  DateTime? published,
  DateTime? now,
}) {
  final run = result.packageResult;
  final detail = [?result.error?.diagnostic, if (run != null && run.output.trim().isNotEmpty) run.output].join('\n\n');
  final d = detail.isEmpty ? null : detail;
  if (result.application == PluginApplication.cancelled) {
    return PluginFailure(
      PluginFailureKind.cancelled,
      appL10n.statePluginInstallCancelled,
      appL10n.statePluginNoChanges,
    );
  }
  final incompatible = [...?result.error?.incompatible, ...?run?.incompatible];
  if (result.error?.code == 'incompatible-version' || incompatible.isNotEmpty) {
    return PluginFailure(
      PluginFailureKind.incompatible,
      appL10n.statePluginIncompatibleTitle,
      _requirementText(incompatible),
      detail: d,
    );
  }
  switch (run?.kind) {
    case 'network':
      final spec = result.failedAt == 'spec-host';
      final asked = result.registries.map(_registryName).toSet().join(appL10n.stateListSeparator);
      return PluginFailure(
        PluginFailureKind.network,
        appL10n.statePluginNetworkFailed,
        spec
            ? appL10n.statePluginSourceUnreachable
            : (asked.isEmpty
                  ? appL10n.statePluginRegistryUnreachable
                  : appL10n.statePluginNamedRegistryUnreachable(asked)),
        detail: d,
      );
    case 'timeout':
      return PluginFailure(
        PluginFailureKind.timeout,
        appL10n.statePluginDownloadTimeout,
        appL10n.statePluginRegistryUnavailable,
        detail: d,
      );
    case 'pnpm-missing':
      return PluginFailure(
        PluginFailureKind.pnpmMissing,
        appL10n.statePluginPnpmMissing,
        isLocal ? appL10n.statePluginPhonePnpmMissing : appL10n.statePluginHostPnpmMissing,
        detail: [?d, if (!isLocal) 'npm install -g pnpm'].join('\n\n'),
      );
    case 'not-found':
      return PluginFailure(
        PluginFailureKind.notFound,
        appL10n.statePluginNotFound,
        appL10n.statePluginPackageMissing,
        detail: d,
      );
    case 'no-matching-version':
      final reference = now ?? DateTime.now();
      if (published != null && reference.difference(published) < const Duration(hours: 24)) {
        return PluginFailure(
          PluginFailureKind.tooNew,
          appL10n.statePluginTooNew,
          appL10n.statePluginWaitForRelease,
          detail: d,
        );
      }
      return PluginFailure(
        PluginFailureKind.noMatchingVersion,
        appL10n.statePluginVersionMissing,
        appL10n.statePluginRegistryVersionMissing,
        detail: d,
      );
    case 'disk-full':
      return PluginFailure(
        PluginFailureKind.diskFull,
        appL10n.commonStorageFull,
        appL10n.stateDeviceStorageFull,
        detail: d,
      );
    case 'permission':
      return PluginFailure(
        PluginFailureKind.permission,
        appL10n.statePluginNoWritePermission,
        appL10n.statePluginConfigReadOnly,
        detail: d,
      );
    case 'integrity':
      return PluginFailure(
        PluginFailureKind.integrity,
        appL10n.statePluginIntegrityFailed,
        appL10n.statePluginDownloadIncomplete,
        detail: d,
      );
    case 'build-blocked':
      final builds = result.pendingBuilds;
      return PluginFailure(
        PluginFailureKind.buildBlocked,
        appL10n.statePluginBuildScripts,
        builds.isEmpty
            ? appL10n.statePluginBuildApproval
            : appL10n.statePluginBuildsPending(builds.join(appL10n.stateListSeparator)),
        detail: d,
        pendingBuilds: builds,
      );
  }
  switch (result.error?.code) {
    case 'already-installed':
      return PluginFailure(
        PluginFailureKind.alreadyInstalled,
        appL10n.statePluginAlreadyInstalled,
        appL10n.statePluginUninstallFirst,
      );
    case 'not-bundle':
    case 'ambiguous-install':
      return PluginFailure(
        PluginFailureKind.notBundle,
        appL10n.statePluginInvalid,
        appL10n.statePluginNoEntry,
        detail: d,
      );
    case 'bundle-in-use':
      return PluginFailure(
        PluginFailureKind.inUse,
        appL10n.statePluginInUse,
        appL10n.statePluginHasDependents,
        detail: d,
      );
    case 'not-removable':
    case 'management-required':
    case 'unaddressable':
    case 'stop-profile':
      return PluginFailure(
        PluginFailureKind.readOnly,
        appL10n.statePluginManagedElsewhere,
        appL10n.statePluginEngineManaged,
        detail: d,
      );
    case 'stale-approval':
      return PluginFailure(
        PluginFailureKind.buildBlocked,
        appL10n.statePluginAuthorizationExpired,
        appL10n.statePluginBuildChanged,
        detail: d,
      );
    case 'invalid-spec':
      return PluginFailure(
        PluginFailureKind.notFound,
        appL10n.statePluginInvalidAddress,
        appL10n.statePluginCatalogInvalidAddress,
        detail: d,
      );
  }
  if (result.pendingBuilds.isNotEmpty) {
    return PluginFailure(
      PluginFailureKind.buildBlocked,
      appL10n.statePluginBuildScripts,
      appL10n.statePluginBuildsPending(result.pendingBuilds.join(appL10n.stateListSeparator)),
      detail: d,
      pendingBuilds: result.pendingBuilds,
    );
  }
  return PluginFailure(
    PluginFailureKind.unknown,
    appL10n.statePluginOperationIncomplete,
    appL10n.commonFailedTryAgain,
    detail: d,
  );
}

/// Maps an exception from a plugin call to user copy.
PluginFailure describePluginError(Object error) {
  switch (error) {
    case DshRemoteException(code: 'METHOD_NOT_ALLOWED'):
      return PluginFailure(
        PluginFailureKind.unsupported,
        appL10n.statePluginRemoteForbidden,
        appL10n.statePluginRelayToggleOnly,
      );
    case DshRemoteException(:final code, :final message) when code.startsWith('gateway/'):
      return PluginFailure(
        PluginFailureKind.unsupported,
        appL10n.statePluginManagementUnsupported,
        appL10n.statePluginEngineUnsupported,
        detail: '$code: $message',
      );
    case DshRemoteException(:final code, :final message):
      return PluginFailure(
        PluginFailureKind.unknown,
        appL10n.statePluginOperationIncomplete,
        appL10n.commonFailedTryAgain,
        detail: '$code: $message',
      );
    case DshHttpException(statusCode: 404):
      return PluginFailure(
        PluginFailureKind.unsupported,
        appL10n.statePluginManagementUnsupported,
        appL10n.statePluginEngineUnsupported,
      );
    case _InstallResultUnknown():
      return PluginFailure(
        PluginFailureKind.resultUnknown,
        appL10n.statePluginResultMissing,
        appL10n.statePluginResultPending,
      );
    case _ when engineUnreachable(error):
      return PluginFailure(
        PluginFailureKind.connection,
        appL10n.statePluginDisconnected,
        appL10n.commonEngineUnreachable,
        detail: '$error',
      );
    default:
      return PluginFailure(
        PluginFailureKind.unknown,
        appL10n.statePluginOperationIncomplete,
        appL10n.commonFailedTryAgain,
        detail: '$error',
      );
  }
}

class _InstallResultUnknown implements Exception {
  const _InstallResultUnknown();
}

// ── Install queue ────────────────────────────────────────────────────────────

/// What to install. [replaceInstalled] removes the installed copy first
/// (DSH has no in-place upgrade).
class PluginInstallRequest {
  const PluginInstallRequest({
    required this.name,
    required this.spec,
    this.title,
    this.registry,
    this.replaceInstalled = false,
    this.finishesUpdate = false,
    this.approvedBuilds = const [],
    this.published,
  });

  final String name;
  final String spec;
  final String? title;
  final String? registry;
  final bool replaceInstalled;

  /// A retry of an update whose first attempt already removed the old copy.
  final bool finishesUpdate;
  final List<String> approvedBuilds;
  final DateTime? published;

  /// An update needs an engine restart even when the Host answers `applied`:
  /// the running engine keeps executing the old module (Node's module cache)
  /// until it restarts.
  bool needsRestartAfter(PluginOperationResult result) =>
      result.needsRestart ||
      ((replaceInstalled || finishesUpdate) && result.application == PluginApplication.applied);

  PluginInstallRequest withApprovedBuilds(List<String> builds) => PluginInstallRequest(
    name: name,
    spec: spec,
    title: title,
    registry: registry,
    finishesUpdate: replaceInstalled || finishesUpdate,
    approvedBuilds: builds,
    published: published,
  );
}

enum PluginInstallPhase { queued, removing, installing, applying, cancelling, succeeded, failed, cancelled }

class PluginInstallJob {
  const PluginInstallJob({
    required this.request,
    required this.requestId,
    this.phase = PluginInstallPhase.queued,
    this.registry,
    this.attempt,
    this.attempts,
    this.log = '',
    this.result,
    this.failure,
  });

  final PluginInstallRequest request;
  final String requestId;
  final PluginInstallPhase phase;

  /// Registry of the current attempt (`null` = the host's default).
  final String? registry;
  final int? attempt;
  final int? attempts;

  /// Tail of the pnpm output streamed so far.
  final String log;
  final PluginOperationResult? result;
  final PluginFailure? failure;

  bool get isActive => switch (phase) {
    PluginInstallPhase.queued ||
    PluginInstallPhase.removing ||
    PluginInstallPhase.installing ||
    PluginInstallPhase.applying ||
    PluginInstallPhase.cancelling => true,
    _ => false,
  };

  bool get needsRestart {
    final result = this.result;
    return result != null && request.needsRestartAfter(result);
  }

  /// Cancellable until the bundle is being applied.
  bool get cancellable =>
      phase == PluginInstallPhase.queued ||
      phase == PluginInstallPhase.installing ||
      phase == PluginInstallPhase.removing;

  String get phaseLabel => switch (phase) {
    PluginInstallPhase.queued => appL10n.statePluginQueued,
    PluginInstallPhase.removing => appL10n.statePluginRemoving,
    PluginInstallPhase.installing =>
      (attempt ?? 1) > 1
          ? (attempts == null
                ? appL10n.statePluginRegistryProgressUnknown(_registryName(registry), attempt!)
                : appL10n.statePluginRegistryProgress(_registryName(registry), attempt!, attempts!))
          : appL10n.statePluginInstalling,
    PluginInstallPhase.applying => appL10n.statePluginApplying,
    PluginInstallPhase.cancelling => appL10n.statePluginCancelling,
    PluginInstallPhase.succeeded => needsRestart ? appL10n.statePluginInstalledRestart : appL10n.commonInstalled,
    PluginInstallPhase.failed => failure?.title ?? appL10n.statePluginInstallFailed,
    PluginInstallPhase.cancelled => appL10n.commonCancelled,
  };

  PluginInstallJob copyWith({
    PluginInstallPhase? phase,
    String? Function()? registry,
    int? attempt,
    int? attempts,
    String? log,
    PluginOperationResult? result,
    PluginFailure? failure,
  }) => PluginInstallJob(
    request: request,
    requestId: requestId,
    phase: phase ?? this.phase,
    registry: registry == null ? this.registry : registry(),
    attempt: attempt ?? this.attempt,
    attempts: attempts ?? this.attempts,
    log: log ?? this.log,
    result: result ?? this.result,
    failure: failure ?? this.failure,
  );
}

/// Per-plugin installs on the active host, run one at a time (DSH holds a
/// profile lock anyway). Keyed by package name.
class PluginInstallsController extends Notifier<Map<String, PluginInstallJob>> {
  static const _logLimit = 16 * 1024;
  static final _random = Random();

  PluginHost? _host;
  int _generation = 0;
  Future<void> _tail = Future.value();
  final Set<String> _cancelledQueued = {};
  final Map<String, List<Completer<PluginInstallJob>>> _waiters = {};

  @override
  Map<String, PluginInstallJob> build() {
    _host = ref.watch(pluginHostProvider);
    _generation++;
    _tail = Future.value();
    _cancelledQueued.clear();
    return const {};
  }

  /// Queues [request]; resolves with the finished job. A plugin that is
  /// already being installed returns its running job.
  Future<PluginInstallJob> install(PluginInstallRequest request) {
    if (ref.exists(installedPluginsProvider)) {
      final removals = ref.read(installedPluginsProvider.notifier);
      if (removals._removals[request.name]?._committing == true) throw StateError('uninstall in progress');
      removals.cancelRemoval(request.name);
    }
    final host = _host;
    final running = state[request.name];
    if (running != null && running.isActive) return _waitFor(running.requestId);
    final job = PluginInstallJob(
      request: request,
      requestId: 'dsh-app-${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(1 << 32)}',
    );
    if (host == null || !host.canInstall) {
      final failed = job.copyWith(
        phase: PluginInstallPhase.failed,
        failure: host == null
            ? PluginFailure(
                PluginFailureKind.connection,
                appL10n.commonEngineUnreachable,
                appL10n.statePluginConnectFirst,
              )
            : describePluginError(const DshRemoteException('METHOD_NOT_ALLOWED', 'install not allowed')),
      );
      _put(failed);
      return Future.value(failed);
    }
    _put(job);
    final generation = _generation;
    final done = Completer<PluginInstallJob>();
    _tail = _tail.then((_) async {
      final finished = await _run(host, generation, job);
      done.complete(finished);
    });
    return done.future;
  }

  /// Stops a queued or running install (no effect once it is being applied).
  Future<void> cancel(String name) async {
    final job = state[name];
    final host = _host;
    if (job == null || !job.cancellable || host == null) return;
    if (job.phase == PluginInstallPhase.queued) {
      _cancelledQueued.add(job.requestId);
      _put(job.copyWith(phase: PluginInstallPhase.cancelled, failure: describeCancelled));
      return;
    }
    _put(job.copyWith(phase: PluginInstallPhase.cancelling));
    try {
      final status = await host.client.cancelInstall(job.requestId);
      if (status == PluginCancelStatus.tooLate) {
        _update(name, job.requestId, (j) => j.copyWith(phase: PluginInstallPhase.applying));
      }
    } on Object {
      _update(name, job.requestId, (j) => j.phase == PluginInstallPhase.cancelling ? j.copyWith(phase: job.phase) : j);
    }
  }

  /// Forgets a finished job (the card goes back to its plain state).
  void dismiss(String name) {
    final job = state[name];
    if (job == null || job.isActive) return;
    state = {...state}..remove(name);
  }

  static PluginFailure get describeCancelled =>
      PluginFailure(PluginFailureKind.cancelled, appL10n.statePluginInstallCancelled, appL10n.statePluginNoChanges);

  Future<PluginInstallJob> _waitFor(String requestId) {
    final completer = Completer<PluginInstallJob>();
    (_waiters[requestId] ??= []).add(completer);
    return completer.future;
  }

  Future<PluginInstallJob> _run(PluginHost host, int generation, PluginInstallJob job) async {
    final name = job.request.name;
    final requestId = job.requestId;
    if (_cancelledQueued.remove(requestId) || generation != _generation || !ref.mounted) {
      final current = ref.mounted ? state[name] : null;
      final cancelled = current?.requestId == requestId
          ? current!
          : job.copyWith(phase: PluginInstallPhase.cancelled);
      _settle(cancelled);
      return cancelled;
    }
    final client = host.client;
    final events = client.pluginManagerEvents.listen((event) {
      if (generation != _generation) return;
      switch (event) {
        case PluginInstallStateEvent(requestId: final id) when id == requestId:
          _update(name, requestId, (j) {
            if (j.phase == PluginInstallPhase.cancelling && event.phase != 'applying') {
              return j;
            }
            return switch (event.phase) {
              'installing' => j.copyWith(
                phase: PluginInstallPhase.installing,
                registry: () => event.registry,
                attempt: event.attemptIndex,
                attempts: event.attemptTotal,
              ),
              'applying' => j.copyWith(phase: PluginInstallPhase.applying),
              'cancelling' => j.copyWith(phase: PluginInstallPhase.cancelling),
              _ => j,
            };
          });
        case PluginInstallLogEvent(requestId: final id) when id == requestId && event.text.isNotEmpty:
          _update(name, requestId, (j) {
            final log = j.log + event.text;
            return j.copyWith(log: log.length > _logLimit ? log.substring(log.length - _logLimit) : log);
          });
        default:
          break;
      }
    });
    PluginInstallJob finish(PluginInstallJob Function(PluginInstallJob) change) {
      _update(name, requestId, change);
      final current = ref.mounted ? state[name] : null;
      // A newer host may be installing the same package. Its visible job is
      // never the result of this request, including duplicate callers.
      final finished = current?.requestId == requestId ? current! : change(job);
      _settle(finished);
      return finished;
    }

    try {
      if (job.request.replaceInstalled) {
        _update(name, requestId, (j) => j.copyWith(phase: PluginInstallPhase.removing));
        final removed = await client.removeBundle(name);
        if (!removed.succeeded) {
          return finish(
            (j) => j.copyWith(
              phase: PluginInstallPhase.failed,
              result: removed,
              failure: describeOperationFailure(removed, isLocal: host.isLocal),
            ),
          );
        }
        if (_cancelledQueued.remove(requestId)) {
          return finish((j) => j.copyWith(phase: PluginInstallPhase.cancelled, failure: describeCancelled));
        }
      }
      _update(
        name,
        requestId,
        (j) => j.phase == PluginInstallPhase.cancelling ? j : j.copyWith(phase: PluginInstallPhase.installing),
      );
      PluginOperationResult result;
      try {
        result = await client.installBundle(
          job.request.spec,
          requestId: requestId,
          enabled: true,
          saveExact: true,
          registry: job.request.registry,
          approvedBuilds: job.request.approvedBuilds.isEmpty ? null : job.request.approvedBuilds,
        );
      } on DshException catch (error) {
        if (error is DshRemoteException) rethrow;
        result = await _recover(client, requestId, name);
      }
      if (result.succeeded) {
        return finish((j) => j.copyWith(phase: PluginInstallPhase.succeeded, result: result));
      }
      final failure = describeOperationFailure(result, isLocal: host.isLocal, published: job.request.published);
      return finish(
        (j) => j.copyWith(
          phase: failure.kind == PluginFailureKind.cancelled ? PluginInstallPhase.cancelled : PluginInstallPhase.failed,
          result: result,
          failure: failure,
        ),
      );
    } on Object catch (error) {
      return finish((j) => j.copyWith(phase: PluginInstallPhase.failed, failure: describePluginError(error)));
    } finally {
      unawaited(events.cancel());
      if (generation == _generation && ref.mounted) {
        unawaited(ref.read(installedPluginsProvider.notifier).refresh().catchError((Object _) {}));
      }
    }
  }

  /// The install response was lost (timeout, dropped tunnel): ask the Host
  /// for the running install's result, then fall back to the bundle list.
  Future<PluginOperationResult> _recover(DshClient client, String requestId, String name) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final result = await client.waitForInstall(requestId);
        if (result != null) return result;
        break;
      } on DshRemoteException {
        break;
      } on DshException {
        await Future<void>.delayed(Duration(seconds: 2 * (attempt + 1)));
      }
    }
    try {
      final bundles = await client.listBundles();
      if (bundles.any((b) => b.name == name && b.installed)) {
        return PluginOperationResult(application: PluginApplication.applied, target: name, bundle: name);
      }
    } on DshException {
      // fall through
    }
    throw const _InstallResultUnknown();
  }

  void _put(PluginInstallJob job) {
    if (!ref.mounted) return;
    state = {...state, job.request.name: job};
    _settle(job);
  }

  void _settle(PluginInstallJob job) {
    if (job.isActive) return;
    for (final waiter in _waiters.remove(job.requestId) ?? const <Completer<PluginInstallJob>>[]) {
      if (!waiter.isCompleted) waiter.complete(job);
    }
  }

  void _update(String name, String requestId, PluginInstallJob Function(PluginInstallJob) change) {
    if (!ref.mounted) return;
    final current = state[name];
    if (current == null || current.requestId != requestId) return;
    final next = change(current);
    state = {...state, name: next};
    _settle(next);
  }
}

final pluginInstallsProvider = NotifierProvider<PluginInstallsController, Map<String, PluginInstallJob>>(
  PluginInstallsController.new,
);
