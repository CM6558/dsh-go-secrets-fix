// Feeds the out-of-app overlay (`dsh/pet_overlay`) every new [PetState].

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'overlay_channel.dart';
import 'pet_signals.dart';
import 'pet_state.dart';

/// Where states go: the overlay's channel (`dsh/pet_overlay`).
final petOverlayPushProvider = Provider<Future<void> Function(PetState state)>(
  (ref) => ref.watch(petOverlayChannelProvider).push,
);

/// Watch it to keep the overlay fed: pushes the state on start and on every
/// change (equal states are not pushed twice). Failures are dropped: no
/// native side in tests, or the overlay is off.
final petOverlayBridgeProvider = Provider<void>((ref) {
  ref.listen<PetState>(petStateProvider, (previous, next) {
    if (previous == next) return;
    final push = ref.read(petOverlayPushProvider);
    unawaited(() async {
      try {
        await push(next);
      } catch (_) {}
    }());
  }, fireImmediately: true);
});

/// Keeps [petOverlayBridgeProvider] alive where it is mounted (the home
/// shell, so the overlay is fed in both 原生 and 网页 modes). Draws nothing.
class PetOverlayBridge extends ConsumerWidget {
  const PetOverlayBridge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(petOverlayBridgeProvider);
    return const SizedBox.shrink();
  }
}
