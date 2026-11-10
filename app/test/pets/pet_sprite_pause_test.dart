// Frozen playback tests. Fake time exercises Timer cancellation, not the
// Stopwatch-derived exact remaining milliseconds (which need a real clock).
import 'package:dsh_app/pets/pet_pack.dart';
import 'package:dsh_app/pets/pet_sheets.dart';
import 'package:dsh_app/pets/pet_state.dart';
import 'package:dsh_app/ui/pets/pet_sprite.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

// Long nominal frames keep real Stopwatch elapsed time immaterial to the
// assertions. No assertion below treats pump's fake time as Stopwatch time.
const frameTime = Duration(minutes: 1);

PetAnimation animation(String name, {bool loop = true}) {
  final source = deepy.animFor(PetStateName.idle);
  return PetAnimation(
    name: name,
    sheet: source.sheet,
    frameWidth: source.frameWidth,
    frameHeight: source.frameHeight,
    cols: source.cols,
    box: source.box,
    frames: [for (final frame in source.frames.take(3)) PetFrame(frame.i, frameTime.inMilliseconds)],
    loop: loop,
  );
}

Future<void> showSprite(WidgetTester tester, PetAnimation anim, {bool paused = false, VoidCallback? onEnd}) =>
    tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: PetSprite(
              key: const ValueKey('paused-sprite'),
              pack: deepy,
              anim: anim,
              scale: 0.1,
              paused: paused,
              onEnd: onEnd,
            ),
          ),
        ),
      ),
    );

PetSpriteState sprite(WidgetTester tester) => tester.state<PetSpriteState>(find.byType(PetSprite));

void main() {
  tearDown(PetSheets.instance.clear);

  testWidgets('a long pause holds a nonzero frame and resumes without resetting', (tester) async {
    final anim = animation('pause-loop');
    await warmSheets(tester, deepy, [anim]);
    await showSprite(tester, anim);
    await tester.pump(frameTime);
    expect(sprite(tester).frame, 1);
    final state = sprite(tester);

    await showSprite(tester, anim, paused: true);
    expect(sprite(tester), same(state));
    // Deliberately not a whole number of animation cycles.
    await tester.pump(const Duration(hours: 4, minutes: 1));
    expect(sprite(tester).frame, 1);
    await tester.pump(const Duration(minutes: 2));
    expect(sprite(tester).frame, 1);
    expect(tester.binding.hasScheduledFrame, isFalse);

    await showSprite(tester, anim);
    expect(sprite(tester), same(state));
    expect(sprite(tester).frame, 1, reason: 'resume must not call _start');
    await tester.pump(frameTime);
    expect(sprite(tester).frame, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('changing animation while paused discards the old frame and deadline', (tester) async {
    final first = animation('first');
    final second = animation('second');
    await warmSheets(tester, deepy, [first, second]);
    await showSprite(tester, first);
    await tester.pump(frameTime);
    expect(sprite(tester).frame, 1);
    await showSprite(tester, first, paused: true);

    await showSprite(tester, second, paused: true);
    expect(sprite(tester).shown, same(second));
    expect(sprite(tester).frame, 0);
    await tester.pump(const Duration(hours: 3));
    expect(sprite(tester).frame, 0);
    await showSprite(tester, second);
    expect(sprite(tester).frame, 0);
    await tester.pump(frameTime);
    expect(sprite(tester).frame, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a finite animation completes once after resuming its final frame', (tester) async {
    final anim = animation('finite', loop: false);
    var ended = 0;
    void onEnd() => ended++;
    await warmSheets(tester, deepy, [anim]);
    await showSprite(tester, anim, onEnd: onEnd);
    await tester.pump(frameTime);
    await tester.pump(frameTime);
    expect(sprite(tester).frame, 2);
    expect(ended, 0);

    await showSprite(tester, anim, paused: true, onEnd: onEnd);
    await tester.pump(const Duration(hours: 3));
    expect(sprite(tester).frame, 2);
    expect(ended, 0);
    await showSprite(tester, anim, onEnd: onEnd);
    expect(sprite(tester).frame, 2);
    await tester.pump(frameTime);
    expect(ended, 1);
    await tester.pump(const Duration(hours: 1));
    expect(ended, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
