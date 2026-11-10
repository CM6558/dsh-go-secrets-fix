// The permission pill above the composer (docs/design/settings-ia.md §4.4):
// the conversation is looser than 工作区内修改 — 「⚠ 完全权限 ›」 — and a tap
// opens its permissions. Grown out of [AutoApprovePill], which still says
// 「自动允许中 ×」 while this client allows everything itself.

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../features/feature_format.dart' show permissionName;
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';

export 'auto_approve_pill.dart' show AutoApprovePill;

/// The pills' shared geometry; `test/chat/permission_pill_test.dart` measures it.
abstract final class PermissionPillMetrics {
  static const height = 32.0;

  /// Pill edge → the end icons, the same on both sides.
  static const inset = 10.0;
  static const icon = 16.0;
}

/// 「⚠ 完全权限 ›」: 32 high, an icon at each end, equal insets. [compact]
/// (beside the generation mode capsule) is the 32 round ⚠ alone.
class PermissionPill extends StatelessWidget {
  const PermissionPill({super.key, required this.preset, required this.onTap, this.compact = false});

  /// `danger-full-access` or `auto`.
  final String preset;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final fg = dsh.onWarningContainer;
    final name = permissionName(preset);
    const side = PermissionPillMetrics.inset;
    final glyph = Icon(AppIcons.permissionRisky, size: PermissionPillMetrics.icon, color: fg);
    return Semantics(
      button: true,
      label: l10n.nearbyPermissionPill(name),
      excludeSemantics: true,
      child: Material(
        color: Color.alphaBlend(dsh.warningContainer.withValues(alpha: 0.94), theme.colorScheme.surface),
        shape: compact
            ? CircleBorder(side: BorderSide(color: dsh.warning.withValues(alpha: 0.35), width: 0.5))
            : StadiumBorder(side: BorderSide(color: dsh.warning.withValues(alpha: 0.35), width: 0.5)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: compact
              ? SizedBox.square(
                  dimension: PermissionPillMetrics.height,
                  child: Center(child: glyph),
                )
              : SizedBox(
                  height: PermissionPillMetrics.height,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: side),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        glyph,
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelMedium?.copyWith(color: fg),
                          ),
                        ),
                        const SizedBox(width: 4),
                        SizedBox.square(
                          dimension: PermissionPillMetrics.icon,
                          child: Icon(AppIcons.disclosure, size: 14, color: fg),
                        ),
                      ],
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}
