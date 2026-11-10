// 界面: which home the app opens to (原生 / 网页), then everything about the
// web app — opening it once, its phone layout, and the display and sending
// preferences the official General settings keep on the host's engine (only
// the web app reads them; they were 通用设置).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/engine_settings_state.dart';
import '../../state/settings_state.dart';
import '../../state/ui_mode_state.dart';
import '../engine_settings/namespace_copy.dart';
import '../engine_settings/schema_form.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../web/local_web_screen.dart';
import 'settings_widgets.dart';

SchemaFieldSpec _field(String ns, String key) => SchemaFieldSpec(ns, [key], copy: copyOf(ns, [key]));

class InterfacePage extends ConsumerWidget {
  const InterfacePage({super.key});

  /// The web app's settings on the host's engine.
  static const namespaces = ['ui-settings', 'ui-chat', 'ui-conversation'];

  /// The new home takes over from the bottom of the stack (this page closes
  /// with the rest; the way back is the new home).
  static void choose(BuildContext context, WidgetRef ref, UiMode mode) {
    if (mode == ref.read(uiModeProvider).mode) return;
    Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst);
    unawaited(ref.read(uiModeProvider.notifier).set(mode));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final mode = ref.watch(uiModeProvider.select((s) => s.mode));
    final settings = ref.watch(settingsProvider);
    final engine = ref.watch(engineSettingsProvider).value;
    return AppPage.list(
      title: l10n.hubSettingsInterface,
      children: [
        SettingsSection(
          title: l10n.hubInterfaceHome,
          spot: Spots.uiMode,
          children: [
            for (final m in UiMode.values)
              Semantics(
                checked: m == mode,
                inMutuallyExclusiveGroup: true,
                child: SettingsTile(
                  key: ValueKey('ui-mode-${m.name}'),
                  title: m.label,
                  subtitle: m == UiMode.web ? l10n.hubInterfaceWebHint : null,
                  trailing: SizedBox.square(
                    dimension: 32,
                    child: Icon(m == mode ? AppIcons.radioOn : AppIcons.radioOff, size: 24),
                  ),
                  onTap: () => choose(context, ref, m),
                ),
              ),
          ],
        ),
        SettingsSection(
          title: l10n.commonWeb,
          spot: Spots.webApp,
          children: [
            SettingsTile(
              spot: Spots.openWeb,
              // In 网页模式 the web app is the home underneath.
              onTap: () => mode == UiMode.web
                  ? Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst)
                  : Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const LocalWebScreen())),
            ),
            SettingsSwitchTile(
              spot: Spots.webPhoneLayout,
              subtitle: l10n.hubSettingsWebPhoneLayoutHint,
              value: settings.webPhoneLayout,
              onChanged: (v) => unawaited(ref.read(settingsProvider.notifier).setWebPhoneLayout(v)),
            ),
          ],
        ),
        // The host's own: only once it has said what it keeps.
        if (engine != null && namespaces.any(engine.served))
          ...schemaFormGroups([
            SchemaFormSection(
              title: l10n.engineGeneralWebDisplay,
              fields: [
                _field('ui-settings', 'enabled'),
                _field('ui-chat', 'transcriptView'),
                _field('ui-chat', 'collapseTiming'),
                _field('ui-chat', 'performanceUsage'),
              ],
            ),
            SchemaFormSection(
              title: l10n.engineGeneralWebSending,
              fields: [_field('ui-conversation', 'busyEnter'), _field('ui-chat', 'linkOpening')],
            ),
          ], settings: engine),
      ],
    );
  }
}
