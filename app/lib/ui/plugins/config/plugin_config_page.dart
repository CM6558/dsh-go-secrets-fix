// A plugin's configuration as a native page (docs/design/plugin-config.md):
// every field its Config declares, drawn by the schema form engine. Live
// fields take effect as they change; the others wait for 保存, which reloads
// the plugin with progress, and a failed reload can be retried, put back or
// dropped. Long forms fold their groups and their plumbing (「高级」) and get
// a search; a plugin that ships its own web page keeps a way there.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart' show PluginBundle;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../plugins/seams/seams.dart' show Slots, seatInventoryProvider;
import '../../../state/engine_settings_state.dart';
import '../../../state/plugin_config/plugin_config_state.dart';
import '../../../state/plugins_state.dart';
import '../../common/discard_guard.dart';
import '../../common/search_capsule.dart';
import '../../engine_settings/field_row.dart';
import '../../engine_settings/namespace_copy.dart';
import '../../engine_settings/schema_collapsed_groups.dart';
import '../../engine_settings/schema_documentation.dart';
import '../../engine_settings/schema_fields.dart' show humanizeKey;
import '../../engine_settings/schema_form.dart';
import '../../features/feature_widgets.dart';
import '../../settings/index/spot_anchor.dart' show anchorSpot;
import '../../settings/index/spots.dart' show SettingsIndex;
import '../../settings/settings_widgets.dart' show SettingsSection;
import '../../shell/page_frame.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../../web/web_target.dart';
import '../seats/seat_links.dart' show seatWebOpenerProvider;
import 'plugin_config_entries.dart' show pluginConfigNamedByBundle, pluginConfigTitle, retryPluginList;
import 'plugin_config_layout.dart';
import 'plugin_config_save_bar.dart';

/// A plugin form's fields read and write [PluginConfigController].
class PluginConfigSource extends SchemaFormSource {
  const PluginConfigSource(this.ns);

  final String ns;

  @override
  EngineSettings? watch(WidgetRef ref) => ref.watch(pluginConfigProvider).value?.settingsFor(ns);

  @override
  SettingsEditor editor(WidgetRef ref, EngineSettings snapshot) =>
      PluginConfigEditor(ref.read(pluginConfigProvider.notifier));

  @override
  String secretSetLabel(L10n l10n) => l10n.pluginConfigSecretSet;

  @override
  String secretUnsetLabel(L10n l10n) => l10n.commonNotSet;

  @override
  bool operator ==(Object other) => other is PluginConfigSource && other.ns == ns;

  @override
  int get hashCode => ns.hashCode;
}

/// A search shows once a form has this many fields.
const pluginConfigSearchFrom = 8;

/// Titled groups fold once a form has this many fields.
const pluginConfigFoldFrom = 12;

/// The bundle that brings entry [ns], if listed.
PluginBundle? pluginConfigBundleOf(List<PluginBundle>? bundles, String ns) =>
    bundles?.where((b) => b.rows.any((r) => r.rowId == ns)).firstOrNull;

/// Where [ns]'s own page is in DSH Web: its bundle's card on the Plugins
/// page (titles in every language, then the package name).
DshWebTarget pluginConfigWebTarget(String ns, {required String title, List<PluginBundle>? bundles}) {
  final bundle = pluginConfigBundleOf(bundles, ns);
  if (bundle == null) return DshWebTarget(pluginItem: [title, ns]);
  return DshWebTarget(pluginItem: [...?bundle.meta?.title?.all, bundle.name]);
}

class PluginConfigPage extends ConsumerStatefulWidget {
  const PluginConfigPage({super.key, required this.ns, this.title});

  /// The plugin entry's profile id (its settings namespace).
  final String ns;
  final String? title;

  @override
  ConsumerState<PluginConfigPage> createState() => _PluginConfigPageState();
}

class _PluginConfigPageState extends ConsumerState<PluginConfigPage> {
  final _search = TextEditingController();
  late final PluginConfigController _controller;
  String _query = '';

  String get ns => widget.ns;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(pluginConfigProvider.notifier);
    // A Host that serves forms one entry at a time: read this one now, and
    // again once the entry list arrives.
    ref.listenManual(pluginConfigProvider, (_, next) {
      final state = next.value;
      if (state != null && state.lazy && state[ns] == null && !state.loadErrors.containsKey(ns)) {
        unawaited(_controller.load(ns));
      }
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    // Left with 放弃: the held edits go too (a save in flight carries on).
    final controller = _controller;
    final ns = this.ns;
    scheduleMicrotask(() => controller.discardIfIdle(ns));
    _search.dispose();
    super.dispose();
  }

  String _title(List<PluginBundle>? bundles, PluginConfigState? state) {
    if (widget.title case final title?) return title;
    // A bridge R7 Host: the name it is listed by (plugin_config_entries.dart).
    if (pluginConfigNamedByBundle(state, ns)) return pluginConfigTitle(ns, bundles, state: state, l10n: context.l10n);
    final locale = AppLocale.current.languageCode;
    if (pluginConfigBundleOf(bundles, ns) case final bundle?) {
      final row = bundle.rows.firstWhere((r) => r.rowId == ns);
      return row.meta?.title?.resolve(locale) ?? bundle.title(locale);
    }
    if (state?.entries[ns]?.label case final label?) return label.resolve(locale);
    return namespaceTitles[ns] ?? humanizeKey(ns);
  }

  /// Why there is no form: the Host's reason for an entry it lists, else the
  /// plugin is not running.
  Widget _unavailable(BuildContext context, PluginConfigEntry? entry) {
    final l10n = context.l10n;
    return switch ((entry?.state, entry?.reason)) {
      (null, _) || ('inactive', _) || (_, 'not-active') => FeatureMessage(
        icon: AppIcons.unsupported,
        title: l10n.engineSettingsPluginStopped,
        body: l10n.engineSettingsEnablePlugin,
      ),
      ('failed', _) => FeatureMessage(icon: AppIcons.error, title: l10n.pluginConfigNotStarted),
      _ => FeatureMessage(icon: AppIcons.unsupported, title: l10n.pluginConfigUnsupported),
    };
  }

  /// The plugin ships a settings page of its own in DSH Web (it said so, or
  /// the web client reported it in a config slot).
  bool _hasWebPage(PluginConfigForm form, List<PluginBundle>? bundles) {
    if (form.prefersOwnPage) return true;
    final owner = pluginConfigBundleOf(bundles, ns);
    if (owner == null) return false;
    final occupancy = ref.watch(seatInventoryProvider)?.occupancy;
    if (occupancy == null) return false;
    return [
      ...?occupancy[Slots.bundleConfig],
      ...?occupancy[Slots.rowConfig],
      ...?occupancy[Slots.settingsSection],
    ].any((o) => o.package == owner.name && (o.slot != Slots.rowConfig || o.cell.endsWith('#$ns')));
  }

  void _openWeb(String title, List<PluginBundle>? bundles) =>
      ref.read(seatWebOpenerProvider)(context, ref, pluginConfigWebTarget(ns, title: title, bundles: bundles));

  Future<void> _resetAll() async {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.pluginConfigResetAllTitle),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: colors.danger, foregroundColor: colors.onDanger),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(l10n.pluginConfigReset),
          ),
        ],
      ),
    );
    if (ok == true) await _controller.resetAll(ns);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final async = ref.watch(pluginConfigProvider);
    final state = async.value;
    final bundles = ref.watch(installedPluginsProvider.select((s) => s.value));
    final title = _title(bundles, state);
    final form = state?[ns];

    if (state == null || form == null) {
      return AppPage.list(
        title: title,
        children: [
          if (state == null && async.hasError)
            FeatureMessage(
              icon: AppIcons.error,
              title: l10n.engineSettingsReadFailed,
              body: describeSettingsError(async.error!),
              action: (
                l10n.commonRetry,
                () {
                  ref.invalidate(engineSettingsProvider);
                  ref.invalidate(pluginConfigProvider);
                },
              ),
            )
          else if (state == null && async.isLoading)
            const FeatureLoading()
          else if (state == null)
            const FeatureOffline()
          // DSH's core, the App's own rows, anything not a chosen bundle's:
          // never drawn or written here; nor anything while the plugin list
          // is not the Host's confirmed answer (PluginConfigScope).
          else if (!state.isPlugin(ns))
            switch (state.scope.status) {
              PluginScopeStatus.pending => const FeatureLoading(),
              PluginScopeStatus.failed => FeatureMessage(
                icon: AppIcons.error,
                title: l10n.pluginConfigListFailed,
                action: (l10n.commonRetry, () => retryPluginList(ref)),
              ),
              PluginScopeStatus.offline => const FeatureOffline(),
              PluginScopeStatus.confirmed => FeatureMessage(
                icon: AppIcons.unsupported,
                title: l10n.pluginConfigUnsupported,
              ),
            }
          else if (state.loadErrors[ns] case final error?)
            FeatureMessage(
              icon: AppIcons.error,
              title: l10n.engineSettingsReadFailed,
              body: error,
              action: (l10n.commonRetry, () => unawaited(_controller.load(ns))),
            )
          else if (state.lazy && (state.entries[ns]?.configurable ?? false))
            const FeatureLoading()
          else
            _unavailable(context, state.entries[ns]),
        ],
      );
    }

    final settings = state.settingsFor(ns);
    final job = state.jobOf(ns);
    final changes = state.draftOf(ns).length;
    final copy = namespaceCopy[ns] ?? const <String, FieldCopy>{};
    final layout = pluginConfigLayout(form, copy: copy, query: _query);
    final searching = _query.trim().isNotEmpty;
    final web = _hasWebPage(form, bundles);
    final bar = PluginConfigSaveBar.shows(changes, job);
    // What the Host keeps as the person's own (held edits are 放弃's).
    final userSet = form.view.user?.isNotEmpty ?? false;

    Widget webCard() => SettingsSection(
      children: [
        EngineFieldRow(
          key: const ValueKey('plugin-config-web'),
          title: l10n.pluginConfigOpenWeb,
          subtitle: l10n.pluginConfigOpenWebHint,
          opensExternally: true,
          onTap: () => _openWeb(title, bundles),
        ),
      ],
    );

    List<Widget> rows(SchemaFormSection section) => [
      for (final f in section.fields)
        anchorSpot(SettingsIndex.forField(f.ns, f.path), SchemaFieldTile(f, key: ValueKey(f.ref.key))),
    ];

    // A long form folds its titled groups (the untitled top stays open),
    // unless its schema folds groups of its own.
    final titled = layout.sections.where((s) => s.title != null).length;
    final foldGroups = !searching && !layout.authored && layout.fieldCount >= pluginConfigFoldFrom && titled >= 2;
    final groups = <Widget>[
      if (foldGroups)
        for (final section in layout.sections)
          if (section.title == null)
            ...schemaFormGroups([section], settings: settings)
          else
            SchemaCollapsedGroup(
              key: PageStorageKey('plugin-config:$ns:${section.title}'),
              title: section.title!,
              count: section.fields.length,
              children: rows(section),
            )
      else
        ...schemaFormGroups(layout.sections, settings: settings),
      if (layout.advanced.isNotEmpty)
        SchemaCollapsedGroup(
          key: PageStorageKey('plugin-config:$ns:advanced'),
          title: advancedGroupTitle,
          count: layout.advancedCount,
          children: [
            for (final section in layout.advanced) ...[
              if (section.title case final heading?) SchemaGroupLabel(heading),
              ...rows(section),
            ],
          ],
        ),
    ];

    final page = AppPage.list(
      title: title,
      subtitle: state.local || state.hostLabel == null ? null : Text(state.hostLabel!),
      actions: [SchemaDocumentationButton(schema: form.view.schema, title: title)],
      children: [
        if (!state.writable)
          Padding(padding: const EdgeInsets.only(bottom: 16), child: FeatureNote(l10n.engineSettingsReadOnly))
        // What its row in the list said (bridge R7): an overlay fixes it.
        else if (state.entries[ns] case final entry? when entry.readOnly)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: FeatureNote(entry.fixedByFile ? l10n.pluginConfigFixedNote : l10n.engineSettingsReadOnly),
          ),
        if (form.failed)
          SettingsSection(
            children: [
              EngineFieldRow(
                title: l10n.pluginConfigNotStarted,
                subtitle: form.error,
                subtitleColor: DshColors.of(context).danger,
              ),
            ],
          ),
        if (layout.fieldCount >= pluginConfigSearchFrom)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: SearchCapsule(
              key: const ValueKey('plugin-config-search'),
              controller: _search,
              hint: l10n.pluginConfigSearchHint,
              onChanged: (text) => setState(() => _query = text),
              onClear: () => setState(() {
                _search.clear();
                _query = '';
              }),
            ),
          ),
        if (web && form.prefersOwnPage && !searching) webCard(),
        if (searching && layout.sections.isEmpty)
          FeatureMessage(icon: AppIcons.search, title: l10n.pluginConfigNoMatch)
        else
          ...groups,
        if (layout.isEmpty && !searching && !web)
          FeatureMessage(icon: AppIcons.configure, title: l10n.pluginConfigNone),
        if (web && !form.prefersOwnPage && !searching) webCard(),
        if (userSet && !searching && settings.canWrite(ns))
          SettingsSection(
            children: [
              EngineFieldRow(
                key: const ValueKey('plugin-config-reset-all'),
                title: l10n.pluginConfigResetAll,
                chevron: false,
                onTap: () => unawaited(_resetAll()),
              ),
            ],
          ),
        if (bar) const SizedBox(height: PluginConfigSaveBar.reserve),
      ],
    );

    return SchemaFormScope(
      source: PluginConfigSource(ns),
      child: DiscardGuard(
        listenable: _search,
        isDirty: () => changes > 0 && !(job?.running ?? false),
        child: Stack(
          children: [
            page,
            Positioned(
              left: 0,
              right: 0,
              bottom: MediaQuery.viewInsetsOf(context).bottom,
              child: AnimatedSwitcher(
                duration: AppMotion.of(context, AppMotion.standard),
                switchInCurve: AppMotion.enter,
                switchOutCurve: AppMotion.exit,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween(begin: const Offset(0, 0.25), end: Offset.zero).animate(animation),
                    child: child,
                  ),
                ),
                child: bar
                    ? PluginConfigSaveBar(
                        key: const ValueKey('plugin-config-bar'),
                        changes: changes,
                        job: job,
                        onSave: () => unawaited(_controller.save(ns)),
                        onDiscard: () => _controller.discard(ns),
                        onRetry: () => unawaited(_controller.retry(ns)),
                        onRestore: () => unawaited(_controller.rollback(ns)),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
