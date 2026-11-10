import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/motion.dart';

/// Press feedback for anything tappable: shrinks to [AppMotion.pressScale]
/// (0.97) while held and eases back to 1 on release, never past it.
///
/// Two ways to use it:
///
/// - **Owns the tap**: pass [onTap] / [onLongPress]. Adds a light selection
///   haptic on tap and button semantics.
///   ```dart
///   Pressable(onTap: openCard, child: SuggestionCard(...))
///   ```
/// - **Feedback only**: leave both null and wrap a child that already handles
///   its own taps (an `InkWell`, a `GlassSurface(onTap:)`). It only listens to
///   raw pointers, so it never competes in the gesture arena; a pointer that
///   moves past the touch slop (a scroll) releases the press.
///
/// Reduced motion keeps the scale at 1.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = AppMotion.pressScale,
    this.haptic = true,
    this.enabled = true,
    this.semanticLabel,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Scale while pressed.
  final double scale;

  /// Light selection click on tap (only when [onTap] is set).
  final bool haptic;

  /// False: no scale, no callbacks (the child still draws).
  final bool enabled;

  /// Read instead of the child's own text, when [Pressable] owns the tap.
  final String? semanticLabel;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> with SingleTickerProviderStateMixin {
  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: AppMotion.press,
    reverseDuration: AppMotion.release,
  );
  late final Animation<double> _scale = CurvedAnimation(
    parent: _press,
    curve: Curves.easeOut,
    reverseCurve: Curves.easeOutCubic.flipped,
  );

  Offset? _downAt;

  bool get _ownsTap => widget.onTap != null || widget.onLongPress != null;

  @override
  void didUpdateWidget(Pressable oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Disabled mid-press: the release no longer reaches the gesture callbacks.
    if (oldWidget.enabled && !widget.enabled) _up();
  }

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  void _down([Offset? at]) {
    if (!widget.enabled || AppMotion.reduced(context)) return;
    _downAt = at;
    _press.forward();
  }

  void _up() {
    _downAt = null;
    if (_press.isDismissed) return;
    // A quick tap: let the press land before springing back.
    if (_press.isAnimating && _press.status == AnimationStatus.forward) {
      _press.forward().whenCompleteOrCancel(() {
        if (mounted) _press.reverse();
      });
    } else {
      _press.reverse();
    }
  }

  void _move(PointerMoveEvent event) {
    final at = _downAt;
    if (at != null && (event.position - at).distance > kTouchSlop) _up();
  }

  void _tap() {
    if (widget.haptic) HapticFeedback.selectionClick();
    widget.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    // The same tree whether enabled or not, so the child keeps its state.
    final child = ScaleTransition(
      scale: Tween(begin: 1.0, end: widget.scale).animate(_scale),
      child: widget.child,
    );
    if (!_ownsTap) {
      return Listener(
        onPointerDown: (e) => _down(e.position),
        onPointerMove: _move,
        onPointerUp: (_) => _up(),
        onPointerCancel: (_) => _up(),
        child: child,
      );
    }
    final enabled = widget.enabled;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.semanticLabel,
      // The label stands in for the visible text instead of repeating it.
      excludeSemantics: widget.semanticLabel != null,
      onTap: enabled && widget.onTap != null ? _tap : null,
      onLongPress: enabled ? widget.onLongPress : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTapDown: enabled ? (d) => _down() : null,
        onTapUp: enabled ? (_) => _up() : null,
        onTapCancel: enabled ? _up : null,
        onTap: enabled && widget.onTap != null ? _tap : null,
        onLongPress: enabled && widget.onLongPress != null
            ? () {
                _up();
                widget.onLongPress!();
              }
            : null,
        child: child,
      ),
    );
  }
}
