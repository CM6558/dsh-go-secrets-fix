// The reasoning translation controller: one fragment at a time, cached by
// text, the streaming tail left alone, failures keep the original.

import 'dart:async';

import 'package:dsh_app/state/cot_translation_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('translates complete paragraphs in order, reuses the cache', () async {
    final asked = <String>[];
    final translation = ReasoningTranslation(
      maxTextChars: 4000,
      translate: (text) async {
        asked.add(text);
        return '【$text】';
      },
    );
    addTearDown(translation.dispose);
    translation.update('One.\n\nTwo.\n\nThr', running: true);
    await pumpEventQueue();
    expect(asked, ['One.', 'Two.']);
    expect(translation.text, '【One.】\n\n【Two.】\n\nThr');
    expect(translation.pending, isFalse);
    // The tail completes: only it goes out.
    translation.update('One.\n\nTwo.\n\nThree.', running: false);
    await pumpEventQueue();
    expect(asked, ['One.', 'Two.', 'Three.']);
    expect(translation.text, '【One.】\n\n【Two.】\n\n【Three.】');
    expect(translation.hasTranslation, isTrue);
  });

  test('a failure keeps the original until retry', () async {
    var fail = true;
    final translation = ReasoningTranslation(
      maxTextChars: 4000,
      translate: (text) async {
        if (fail) throw StateError('offline');
        return 'ok:$text';
      },
    );
    addTearDown(translation.dispose);
    translation.update('Alpha.\n\nBeta.', running: false);
    await pumpEventQueue();
    expect(translation.failed, isTrue);
    expect(translation.text, 'Alpha.\n\nBeta.');
    // Updates don't hammer a failing service.
    translation.update('Alpha.\n\nBeta.', running: false);
    await pumpEventQueue();
    expect(translation.failed, isTrue);
    fail = false;
    translation.retry();
    await pumpEventQueue();
    expect(translation.failed, isFalse);
    expect(translation.text, 'ok:Alpha.\n\nok:Beta.');
  });

  test('dispose stops publishing', () async {
    final gate = Completer<String>();
    final translation = ReasoningTranslation(maxTextChars: 4000, translate: (_) => gate.future);
    var notified = 0;
    translation.addListener(() => notified++);
    translation.update('Gamma.', running: false);
    final before = notified;
    translation.dispose();
    gate.complete('done');
    await pumpEventQueue();
    expect(notified, before);
  });

  test('only reasoning outside the target script is worth translating', () {
    expect(reasoningNeedsTranslation('Let me check the pubspec first.', 'zh'), isTrue);
    expect(reasoningNeedsTranslation('先看一下 pubspec 里锁的版本，再决定怎么改。', 'zh'), isFalse);
    expect(reasoningNeedsTranslation('看 `flutter_riverpod` 的 `ProviderScope.containerOf` 实现', 'zh-CN'), isFalse);
    expect(reasoningNeedsTranslation('先看一下版本。', 'en'), isTrue);
  });
}
