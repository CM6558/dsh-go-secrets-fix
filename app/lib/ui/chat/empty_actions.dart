// The controls of the new-chat empty state, in two tiers.
//
// - Primary: at most one, and only when the screen has a way forward of its
//   own (「重新连接」). A brand-filled pill.
// - Secondary: everything else — the workspace chip and the suggestions —
//   quiet chips of one size: a faint fill, no shadow, muted text.
//
// Both tiers share the height, the side insets and the type metrics, so a
// state change (connected ↔ failed) swaps the pill and the chip in place.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../common/fade_in.dart';
import '../common/pressable.dart';
import '../theme/theme.dart';
import 'empty_state.dart' show ChatSuggestion;

/// The sizes every empty-state control shares (measured in
/// `test/chat/empty_actions_test.dart`).
abstract final class EmptyActions {
  /// Height at 1× text; grows with the text, equally for both tiers.
  static const height = 36.0;

  /// Side padding of a pill, the same on both sides.
  static const inset = 14.0;

  /// Vertical padding (only matters once large text outgrows [height]).
  static const padV = 6.0;

  static const iconSize = 16.0;
  static const iconGap = 6.0;

  /// Room a Rounded glyph leaves inside its box at [iconSize] (~1.3 at 16):
  /// the leading icon's side gets that much less padding so both sides read
  /// the same.
  static const leadingAir = 1.0;

  /// A trailing chevron (`expand_more`, 18) carries ~4.5 of air on its side.
  static const chevronSize = 18.0;
  static const chevronAir = 4.0;

  /// Between suggestion chips, across and down.
  static const gap = 8.0;

  /// The one type style of both tiers (14 / 1.55): equal line heights keep
  /// the tiers equally tall at every text size.
  static TextStyle? labelStyle(BuildContext context) => Theme.of(context).textTheme.bodyMedium;
}

/// The quiet chip's fill: the filter capsules' unselected tone.
Color quietChipFill(ThemeData theme) => theme.brightness == Brightness.dark
    ? Colors.white.withValues(alpha: 0.07)
    : theme.colorScheme.onSurface.withValues(alpha: 0.05);

/// Shared shell of both tiers: a stadium [Material] with an ink ripple and
/// the 0.97 press, one row of content, [EmptyActions.height] tall.
class _Pill extends StatelessWidget {
  const _Pill({
    required this.color,
    required this.onTap,
    required this.padding,
    required this.child,
    required this.semanticsLabel,
    this.onTapHint,
    this.enabled = true,
    this.expand = false,
  });

  final Color color;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final Widget child;
  final String semanticsLabel;
  final String? onTapHint;
  final bool enabled;

  /// Fill the width given (a grid cell) and centre the content.
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final tap = enabled ? onTap : null;
    return Semantics(
      button: true,
      enabled: tap != null,
      label: semanticsLabel,
      onTapHint: tap == null ? null : onTapHint,
      onTap: tap,
      excludeSemantics: true,
      child: Pressable(
        enabled: tap != null,
        child: Material(
          color: color,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: tap,
            customBorder: const StadiumBorder(),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: EmptyActions.height),
              // Shrinks to the content, or (expand) fills the cell and
              // centres it: equal room on both sides either way.
              child: Align(
                widthFactor: expand ? null : 1,
                heightFactor: 1,
                child: Padding(padding: padding, child: child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Tier 1: the empty state's one primary action, a brand-filled pill.
class EmptyPrimaryPill extends StatelessWidget {
  const EmptyPrimaryPill({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _Pill(
      color: scheme.primary,
      onTap: onTap,
      semanticsLabel: label,
      padding: const EdgeInsets.symmetric(horizontal: EmptyActions.inset + 4, vertical: EmptyActions.padV),
      child: Text(
        label,
        maxLines: 1,
        style: EmptyActions.labelStyle(context)?.copyWith(color: scheme.onPrimary, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Tier 2: a quiet chip — [icon], one line of [label], an optional
/// [trailing] chevron. Shrinks to its content unless [expand].
class QuietChip extends StatelessWidget {
  const QuietChip({
    super.key,
    required this.label,
    this.icon,
    this.trailing,
    this.onTap,
    this.enabled = true,
    this.expand = false,
    this.semanticsLabel,
    this.onTapHint,
  });

  final String label;
  final IconData? icon;

  /// A chevron that says "this opens a choice".
  final IconData? trailing;
  final VoidCallback? onTap;
  final bool enabled;
  final bool expand;

  /// Read instead of [label].
  final String? semanticsLabel;
  final String? onTapHint;

  /// The padding that makes both sides read the same (see [EmptyActions]).
  static EdgeInsetsDirectional paddingFor({bool icon = false, bool trailing = false}) => EdgeInsetsDirectional.fromSTEB(
    EmptyActions.inset - (icon ? EmptyActions.leadingAir : 0),
    EmptyActions.padV,
    EmptyActions.inset - (trailing ? EmptyActions.chevronAir : 0),
    EmptyActions.padV,
  );

  /// The width a chip needs to show [label] whole.
  static double widthFor(BuildContext context, String label, {bool icon = false, bool trailing = false}) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: EmptyActions.labelStyle(context)),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return paddingFor(icon: icon, trailing: trailing).horizontal +
        width +
        (icon ? EmptyActions.iconSize + EmptyActions.iconGap : 0) +
        (trailing ? EmptyActions.chevronSize + 2 : 0);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return _Pill(
      color: quietChipFill(theme),
      onTap: onTap,
      enabled: enabled,
      expand: expand,
      semanticsLabel: semanticsLabel ?? label,
      onTapHint: onTapHint,
      padding: paddingFor(icon: icon != null, trailing: trailing != null),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: EmptyActions.iconSize, color: muted),
            const SizedBox(width: EmptyActions.iconGap),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: EmptyActions.labelStyle(context)?.copyWith(color: muted),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 2),
            Icon(trailing, size: EmptyActions.chevronSize, color: muted),
          ],
        ],
      ),
    );
  }
}

/// The suggestions as quiet chips: a 2×2 grid of equal cells, edge to edge
/// with the composer, [EmptyActions.gap] apart both ways. When one label
/// would not fit its cell (a narrow phone with large text) every chip takes
/// the full width instead, one per row — still equal, never cut.
class SuggestionChips extends StatelessWidget {
  const SuggestionChips({
    super.key,
    required this.suggestions,
    required this.enabled,
    required this.onSuggestion,
    this.firstIndex = 0,
  });

  final List<ChatSuggestion> suggestions;
  final bool enabled;
  final ValueChanged<ChatSuggestion> onSuggestion;

  /// Entrance stagger of the first chip (after what is above them).
  final int firstIndex;

  @override
  Widget build(BuildContext context) {
    if (suggestions.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final cell = (constraints.maxWidth - EmptyActions.gap) / 2;
        final widest = suggestions.map((s) => QuietChip.widthFor(context, s.label, icon: true)).reduce(math.max);
        final columns = widest <= cell ? 2 : 1;

        Widget chip(int i) {
          final s = suggestions[i];
          return FadeSlideIn(
            index: firstIndex + i,
            child: AnimatedOpacity(
              opacity: enabled ? 1 : 0.5,
              duration: AppMotion.of(context, AppMotion.quick),
              child: QuietChip(
                icon: s.icon,
                label: s.label,
                expand: true,
                enabled: enabled,
                onTap: () => onSuggestion(s),
              ),
            ),
          );
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < suggestions.length; i += columns) ...[
              if (i > 0) const SizedBox(height: EmptyActions.gap),
              if (columns == 1)
                chip(i)
              else
                Row(
                  children: [
                    Expanded(child: chip(i)),
                    const SizedBox(width: EmptyActions.gap),
                    Expanded(child: i + 1 < suggestions.length ? chip(i + 1) : const SizedBox.shrink()),
                  ],
                ),
            ],
          ],
        );
      },
    );
  }
}
