// 设置 › 能力 › 图像与视频 (docs/design/media-generation.md §5.8, first
// version): the media plugin's own settings, drawn from its schema by the
// native form — services, write-only keys, defaults, limits. The namespace is
// the one whose schema carries the catalogue (the host may rename the
// instance), else the plugin's own name. Without the plugin on this host:
// 「在此主机上安装」, to the plugin market. The curated page of §5.8
// (services, usage, works) comes later (M6 proper).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/engine_settings_state.dart';
import '../../state/media_generation.dart';
import '../common/app_sheet.dart';
import '../common/empty_view.dart';
import '../engine_settings/engine_settings_page.dart' show EngineSettingsPage;
import '../plugins/plugins_screen.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';

class MediaSettingsPage extends ConsumerWidget {
  const MediaSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final namespaces = ref.watch(engineSettingsProvider.select((s) => s.value?.namespaces));
    final ns =
        (namespaces == null ? null : mediaNamespacesOf(namespaces).firstOrNull) ??
        mediaSettingsNamespaces.where((n) => namespaces?.containsKey(n) ?? false).firstOrNull;
    final plugin = ref.watch(mediaPluginProvider);
    if (ns != null) return EngineSettingsPage(ns: ns, title: l10n.mediaSettingsTitle);
    // Still reading what the host has: the form's own loading state.
    if (namespaces == null && plugin != MediaPluginState.absent) {
      return EngineSettingsPage(ns: mediaSettingsNamespaces.first, title: l10n.mediaSettingsTitle);
    }
    return AppPage.list(
      title: l10n.mediaSettingsTitle,
      children: [
        const SizedBox(height: 48),
        MediaInstallPrompt(onInstall: () => openMediaPluginMarket(context)),
      ],
    );
  }
}

/// 「图像与视频」 · 「这台主机还没有图像与视频插件」 · 「在此主机上安装」.
class MediaInstallPrompt extends StatelessWidget {
  const MediaInstallPrompt({super.key, required this.onInstall, this.compact = false});

  final VoidCallback onInstall;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return EmptyView(
      icon: AppIcons.generateMedia,
      compact: compact,
      title: l10n.mediaInstallTitle,
      message: l10n.mediaInstallBody,
      actionLabel: l10n.mediaInstallAction,
      onAction: onInstall,
    );
  }
}

/// The plugin market, where the media plugin is installed on this host (or
/// [tab]: the installed list, where it is updated).
Future<void> openMediaPluginMarket(BuildContext context, {PluginsTab tab = PluginsTab.market}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PluginsScreen(initialTab: tab)));

/// 生成 where the plugin runs but its catalogue is missing, damaged or of a
/// version this app doesn't know (§4.3): no generation mode, and a word that
/// chat works as usual. The installed plugins (to update it) are one tap away.
Future<void> showMediaUnavailableSheet(BuildContext context) => showAppSheet<void>(
  context,
  builder: (sheet) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: EmptyView(
        icon: AppIcons.generateMedia,
        compact: true,
        title: context.l10n.mediaUnavailableTitle,
        message: context.l10n.mediaUnavailableBody,
        actionLabel: context.l10n.mediaUnavailableAction,
        onAction: () {
          Navigator.of(sheet).pop();
          openMediaPluginMarket(context, tab: PluginsTab.installed);
        },
      ),
    ),
  ),
);

/// 生成 on a host without the plugin (§2.2, M7): the same prompt as a sheet.
Future<void> showMediaInstallSheet(BuildContext context) => showAppSheet<void>(
  context,
  builder: (sheet) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: MediaInstallPrompt(
        compact: true,
        onInstall: () {
          Navigator.of(sheet).pop();
          openMediaPluginMarket(context);
        },
      ),
    ),
  ),
);
