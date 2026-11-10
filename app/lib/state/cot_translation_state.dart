// Machine translation of expanded reasoning (DSH's optional
// `dsh-experimental-cot-translation-bundle`). The thinking view asks
// [cotTranslationProvider] whether the bundle is on, then drives one
// [ReasoningTranslation] per reasoning block.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection_state.dart';

/// The app's interface language, the target of `auto`.
const reasoningUiLanguage = 'zh';

/// `cotTranslation/limits` of the active host; null while the bundle is off,
/// its provider can't take requests, or nothing is connected. Read only while
/// a thinking block is open (auto-dispose), so a bundle switched on later
/// shows up on the next open.
final cotTranslationProvider = FutureProvider.autoDispose<CotTranslationLimits?>((ref) async {
  final client = ref.watch(activeConnectionProvider).value?.client;
  if (client == null) return null;
  try {
    final limits = await client.cotTranslationLimits();
    return limits.usable ? limits : null;
  } catch (_) {
    return null;
  }
});

/// Translates one fragment with [limits]' accepted provider and language.
typedef ReasoningTranslator = Future<String> Function(
  String text, {
  required CotTranslationLimits limits,
  String? sessionId,
});

/// The Host call behind [ReasoningTranslator] (a seam for tests).
final reasoningTranslatorProvider = Provider<ReasoningTranslator?>((ref) {
  final client = ref.watch(activeConnectionProvider).value?.client;
  if (client == null) return null;
  return (text, {required limits, sessionId}) => client.translateReasoning(
    text,
    targetLanguage: limits.targetFor(reasoningUiLanguage),
    provider: limits.provider,
    sessionId: sessionId,
  );
});

/// Whether [text] is worth translating into [target]: reasoning already in
/// the target script (Chinese into `zh`) is not.
bool reasoningNeedsTranslation(String text, String target) {
  if (!target.toLowerCase().startsWith('zh')) return true;
  var cjk = 0;
  for (final rune in text.runes) {
    if (rune >= 0x4E00 && rune <= 0x9FFF || rune >= 0x3400 && rune <= 0x4DBF) {
      cjk++;
    }
  }
  // A Chinese character carries about as much as a Latin word; identifiers in
  // Chinese reasoning don't make it foreign.
  final words = RegExp('[A-Za-z]+').allMatches(text).length;
  return words > cjk;
}

/// Sequential paragraph translation for one reasoning block, as the official
/// client does it: complete paragraphs (and request-sized pieces of long ones)
/// go out one at a time, the still-growing tail stays original, results are
/// cached by fragment text, and a failure keeps the original until [retry].
class ReasoningTranslation extends ChangeNotifier {
  ReasoningTranslation({required this.maxTextChars, required this.translate});

  final int maxTextChars;
  final Future<String> Function(String text) translate;

  final Map<String, String> _cache = {};
  List<ReasoningFragment> _fragments = const [];
  bool _pending = false;
  bool _failed = false;
  bool _disposed = false;

  /// The display text: translated where available, original elsewhere.
  String get text =>
      [for (final f in _fragments) '${f.complete ? _cache[f.text] ?? f.text : f.text}${f.suffix}'].join();

  bool get pending => _pending;
  bool get failed => _failed;

  /// Something has been translated already.
  bool get hasTranslation => _cache.isNotEmpty;

  /// Adopts the current reasoning and queues newly completed fragments.
  void update(String source, {required bool running}) {
    if (_disposed) return;
    _fragments = reasoningFragments(source, running: running, maxTextChars: maxTextChars);
    notifyListeners();
    unawaited(_run());
  }

  void retry() {
    if (_disposed) return;
    _failed = false;
    unawaited(_run());
  }

  ReasoningFragment? _next() {
    for (final f in _fragments) {
      if (f.complete && f.text.trim().isNotEmpty && !_cache.containsKey(f.text)) {
        return f;
      }
    }
    return null;
  }

  Future<void> _run() async {
    if (_pending || _failed || _disposed) return;
    var next = _next();
    if (next == null) return;
    _pending = true;
    notifyListeners();
    try {
      while (next != null) {
        final translated = await translate(next.text);
        if (_disposed) return;
        _cache[next.text] = translated;
        notifyListeners();
        next = _next();
      }
    } catch (_) {
      if (!_disposed) _failed = true;
    } finally {
      _pending = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
