import 'package:flutter/material.dart';

/// How long a one-line confirmation (「已复制」「已保存」) stays up, enter and
/// exit animation not counted. Longer text gets a little more, up to
/// [kBriefNoticeMaxDuration], so a saved-to path can still be read.
///
/// Errors and notices with an action keep the SnackBar defaults: an action
/// stays until it is used (Flutter's `persist`), the rest four seconds. An
/// undo notice ([BriefNotice.showUndoNotice]) lasts exactly its window.
const kBriefNoticeDuration = Duration(milliseconds: 1500);

/// The ceiling for [briefNoticeDuration].
const kBriefNoticeMaxDuration = Duration(milliseconds: 3000);

/// [kBriefNoticeDuration] for [text], stretched by its length: a Chinese
/// character counts double a Latin letter.
Duration briefNoticeDuration(String text) {
  var units = 0;
  for (final rune in text.runes) {
    units += rune >= 0x2E80 ? 2 : 1;
  }
  final ms = (1000 + units * 40).clamp(kBriefNoticeDuration.inMilliseconds, kBriefNoticeMaxDuration.inMilliseconds);
  return Duration(milliseconds: ms);
}

/// A brief confirmation: no action, [briefNoticeDuration].
SnackBar briefNoticeBar(String text) => SnackBar(content: Text(text), duration: briefNoticeDuration(text));

extension BriefNotice on ScaffoldMessengerState {
  /// Shows [text] as a brief confirmation, taking the place of whatever is
  /// up: tapping 复制 twice doesn't queue two.
  void showBriefNotice(String text) {
    hideCurrentSnackBar();
    showSnackBar(briefNoticeBar(text));
  }

  /// [text] with 撤销 for exactly [window], put up at once in place of
  /// anything shown or queued, so the notice and the undo window end
  /// together.
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showUndoNotice(
    String text, {
    required String undoLabel,
    required VoidCallback onUndo,
    required Duration window,
  }) {
    clearSnackBars();
    removeCurrentSnackBar();
    return showSnackBar(
      SnackBar(
        content: Text(text),
        duration: window,
        persist: false,
        action: SnackBarAction(label: undoLabel, onPressed: onUndo),
      ),
    );
  }
}

/// [BriefNotice.showBriefNotice] on [context]'s messenger, if there is one.
void showBriefNotice(BuildContext context, String text) => ScaffoldMessenger.maybeOf(context)?.showBriefNotice(text);
