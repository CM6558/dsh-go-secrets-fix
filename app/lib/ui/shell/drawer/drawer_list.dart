// The drawer's conversation list once it has loaded:
// DS Bot's row, 置顶, the folders (opening and closing in place), then the
// rest by day; or, under a status filter, just the matches. Loading, error
// and empty-host states stay with the drawer (sessions_drawer.dart).

import 'package:dsh_client/dsh_client.dart' show SessionSummary;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/drawer_view_state.dart';
import '../../../state/session_attention_state.dart';
import '../../../state/session_created_state.dart';
import '../../../state/sessions_state.dart';
import '../../../state/workspaces_state.dart';
import '../../common/empty_view.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../sessions_drawer.dart' show sessionTitle;
import 'drawer_actions.dart';
import 'folder_header.dart';
import 'session_tile.dart';

class DrawerConversationList extends ConsumerWidget {
  const DrawerConversationList({
    super.key,
    required this.onOpen,
    required this.onLongPress,
    this.leading,
    this.now,
    this.readOnly = false,
  });

  /// Opens a conversation (and closes the drawer).
  final ValueChanged<String> onOpen;

  /// A conversation's actions.
  final void Function(SessionSummary session) onLongPress;

  /// Above everything when nothing is filtered or chosen (DS Bot's row).
  final Widget? leading;

  /// Clock override for the day groups (tests).
  final DateTime? now;
  final bool readOnly;

  /// The list's padding: rows' edges on the drawer's 10 line.
  static const padding = EdgeInsets.fromLTRB(10, 4, 10, 16);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final blocks = watchDrawerBlocks(ref, now: now);
    if (blocks == null) return const SizedBox.shrink();
    final selection = ref.watch(drawerSelectionProvider);
    final selecting = !readOnly && selection != null;
    final filter = ref.watch(drawerFilterProvider);
    final current = ref.watch(currentSessionProvider);
    final pending = ref.watch(pendingInteractionsProvider);
    final unread = ref.watch(unreadSessionIdsProvider);
    final pinned = ref.watch(workspacesProvider.select((s) => s.pinnedSessionIds)).toSet();
    final sort = ref.watch(drawerViewProvider.select((v) => v.sort));
    if (!readOnly && sort == DrawerSort.created) {
      final ids = [
        for (final block in blocks)
          for (final s in block.items) s.sessionId,
      ];
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) ref.read(sessionCreatedProvider.notifier).ensure(ids);
      });
    }
    final selectionNotifier = ref.read(drawerSelectionProvider.notifier);

    Widget tile(SessionSummary s, {bool inFolder = false}) {
      final id = s.sessionId;
      return SessionTile(
        key: ValueKey('session-$id'),
        title: sessionTitle(s),
        running: s.running,
        current: id == current,
        pending: readOnly ? null : pending[id],
        unread: !readOnly && unread.contains(id),
        pinned: inFolder && pinned.contains(id),
        indent: inFolder ? SessionTile.folderIndent : 0,
        selecting: selecting,
        selected: selection?.contains(id) ?? false,
        onTap: selecting ? () => selectionNotifier.toggle(id) : () => onOpen(id),
        onLongPress: readOnly
            ? null
            : selecting
            ? () => selectionNotifier.toggle(id)
            : () => onLongPress(s),
      );
    }

    final children = <Widget>[];
    var foldersLabelled = false;
    for (final block in blocks) {
      switch (block) {
        case FilteredBlock(filter: final matching, :final items) when items.isEmpty:
          children.add(_FilterEmpty(matching));
        case FilteredBlock(:final items):
          children.addAll(items.map(tile));
        case PinnedBlock(:final items):
          children
            ..add(DrawerEyebrow(l10n.commonPin))
            ..addAll(items.map(tile));
        case FolderBlock(:final folder, :final items):
          if (!foldersLabelled) {
            foldersLabelled = true;
            children.add(DrawerEyebrow(l10n.shellFolders));
          }
          children
            ..add(
              DrawerFolderHeader(
                key: ValueKey('folder-${folder.id}'),
                folder: folder,
                count: items.length,
                onTap: () => ref.read(drawerViewProvider.notifier).toggleCollapsed(folder.id),
                onLongPress: () {
                  if (!readOnly) folderActionsFlow(context, ref, folder);
                },
              ),
            )
            ..add(
              DrawerFolderBody(
                key: ValueKey('folder-body-${folder.id}'),
                open: !folder.collapsed,
                children: [for (final s in items) tile(s, inFolder: true)],
              ),
            );
        case DayBlock(:final day, :final items):
          children
            ..add(DrawerEyebrow(sessionDayLabels[day]!))
            ..addAll(items.map(tile));
      }
    }
    final showLeading = leading != null && filter == DrawerFilter.all && !selecting;
    return AnimatedSwitcher(
      duration: AppMotion.of(context, AppMotion.quick),
      layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
      child: ListView(
        key: ValueKey(filter),
        padding: padding,
        children: [?(showLeading ? leading : null), ...children],
      ),
    );
  }
}

/// A status filter with no matches.
class _FilterEmpty extends StatelessWidget {
  const _FilterEmpty(this.filter);

  final DrawerFilter filter;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final (icon, title) = switch (filter) {
      DrawerFilter.running => (AppIcons.running, l10n.shellNoRunningChats),
      DrawerFilter.pending => (AppIcons.toConfirm, l10n.shellNoPendingChats),
      DrawerFilter.unread => (AppIcons.allRead, l10n.shellNoUnreadChats),
      DrawerFilter.all => (AppIcons.chat, l10n.shellNoChatsYet),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 56),
      child: EmptyView(compact: true, icon: icon, title: title),
    );
  }
}
