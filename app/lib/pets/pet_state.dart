// What the pet shows, as reduced from the app's signals by the mood reducer
// (pet_mood.dart). The chat page's pet layer and the out-of-app overlay
// (Kotlin, `dsh/pet_overlay`) both draw from this one value; the overlay
// never reduces anything itself. Product rules: `docs/design/pets.md`.
//
// State names are Clawd on Desk's (the keys of `states` in pack.json).

import 'package:flutter/foundation.dart';

import '../l10n/l10n.dart';
import '../state/hosts_state.dart';

/// The pet's states, in Clawd on Desk's names.
enum PetStateName {
  idle,
  thinking,
  working,
  juggling,
  sweeping,
  notification,
  attention,
  error,
  carrying,
  sleeping,
  waking;

  /// Unknown names read as [idle].
  static PetStateName fromName(String? name) => values.asNameMap()[name] ?? idle;
}

/// The three sizes in 宠物设置, by body height (docs/design/pets.md §2.10).
/// The name is the persisted value.
enum PetSize {
  small,
  medium,
  large;

  String get label => switch (this) {
    small => appL10n.stateSizeSmall,
    medium => appL10n.stateSizeStandard,
    large => appL10n.stateSizeLarge,
  };

  /// Target height of the pet's body (its pack's `contentBox`), dp. The
  /// drawn size snaps to a whole number of device pixels per art pixel.
  double get bodyHeight => switch (this) {
    small => 22,
    medium => 30,
    large => 40,
  };

  static PetSize fromName(String? name) => values.asNameMap()[name] ?? medium;
}

/// What a bubble is about.
enum PetBubbleKind {
  done,
  failed,
  approval,
  question;

  /// The bubble's words.
  String get verb => switch (this) {
    done => appL10n.statePetDone,
    failed => appL10n.statePetFailed,
    approval => appL10n.commonWaitingApproval,
    question => appL10n.commonWaitingAnswer,
  };

  /// Waits on the person: stays up longer, outranks the rest.
  bool get waits => this == approval || this == question;

  /// How long it stays up.
  Duration get shownFor => switch (this) {
    done => const Duration(seconds: 4),
    failed => const Duration(seconds: 6),
    approval || question => const Duration(seconds: 8),
  };

  /// Which one wins when two meet: waiting requests, then failures, then done.
  int get rank => switch (this) {
    done => 0,
    failed => 1,
    approval || question => 2,
  };
}

/// A conversation on a host.
@immutable
class PetTarget {
  const PetTarget(this.host, this.sessionId);

  final HostRef host;
  final String sessionId;

  Map<String, Object?> toMap() => {'host': host.encode(), 'sessionId': sessionId};

  @override
  bool operator ==(Object other) => other is PetTarget && other.host == host && other.sessionId == sessionId;

  @override
  int get hashCode => Object.hash(host, sessionId);

  @override
  String toString() => 'PetTarget(${host.kind.name}:${host.id}/$sessionId)';
}

/// Titles longer than this are cut (docs/design/pets.md §2.6).
const petTitleMax = 12;

/// A short line over the pet's head: 「做完了」「标题 · 等你确认」
/// 「3 个对话做完了」. Never the conversation's text, never buttons.
@immutable
class PetBubble {
  const PetBubble({
    required this.id,
    required this.kind,
    required this.target,
    required this.until,
    this.title,
    this.count = 1,
  });

  /// Unique per bubble: the same id pushed again is the same bubble.
  final String id;
  final PetBubbleKind kind;

  /// The conversation's title, already masked (`alertTitle`); null for none.
  final String? title;

  /// The conversation a tap opens (a merged bubble: the first one).
  final PetTarget target;

  /// Conversations merged into this bubble.
  final int count;

  /// Device clock: the bubble folds away then.
  final DateTime until;

  /// The title as the bubble shows it (cut at [petTitleMax]); null when
  /// merged or untitled.
  String? get shortTitle {
    final t = title?.trim();
    if (count > 1 || t == null || t.isEmpty) return null;
    final chars = t.runes.toList();
    return chars.length <= petTitleMax ? t : '${String.fromCharCodes(chars.take(petTitleMax))}…';
  }

  /// What the bubble says after the title: 「做完了」, or 「3 个对话做完了」.
  String get verb => count > 1
      ? switch (kind) {
          PetBubbleKind.done => appL10n.statePetChatsDone(count),
          PetBubbleKind.failed => appL10n.statePetChatsFailed(count),
          PetBubbleKind.approval => appL10n.statePetChatsApproval(count),
          PetBubbleKind.question => appL10n.statePetChatsQuestion(count),
        }
      : kind.verb;

  /// The line on screen.
  String get text => switch (shortTitle) {
    final t? => '$t · $verb',
    null => verb,
  };

  PetBubble copyWith({int? count, DateTime? until}) => PetBubble(
    id: id,
    kind: kind,
    title: title,
    target: target,
    count: count ?? this.count,
    until: until ?? this.until,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'kind': kind.name,
    'text': text,
    'title': ?title,
    'count': count,
    'host': target.host.encode(),
    'sessionId': target.sessionId,
    'untilMs': until.millisecondsSinceEpoch,
  };

  @override
  bool operator ==(Object other) =>
      other is PetBubble &&
      other.id == id &&
      other.kind == kind &&
      other.title == title &&
      other.target == target &&
      other.count == count &&
      other.until == until;

  @override
  int get hashCode => Object.hash(id, kind, title, target, count, until);

  @override
  String toString() => 'PetBubble(${kind.name} "$text" → $target)';
}

/// Id of the 「不显示」 choice.
const noPetId = 'none';

/// What the pet shows right now. Equal values need no redraw and no push.
@immutable
class PetState {
  const PetState({
    this.state = PetStateName.idle,
    this.tier = 0,
    this.bubble,
    this.target,
    this.active = false,
    this.foreground = true,
    this.packId = noPetId,
    this.size = PetSize.medium,
    this.quiet = false,
    this.reduceMotion = false,
  });

  final PetStateName state;

  /// 0: not tiered. working 1–3 (running top-level conversations on every
  /// host, capped at 3); juggling 1–2 (running subagents).
  final int tier;

  /// Null in quiet mode, or when there is nothing to say.
  final PetBubble? bubble;

  /// The most relevant conversation (docs/design/pets.md §2.7): one waiting
  /// on the person (the longest), else one that failed unseen, else one that
  /// finished unseen, else the most recently active running one, else the
  /// one last looked at.
  final PetTarget? target;

  /// Something runs, waits on the person, or a bubble is up.
  final bool active;

  /// The app is on screen (the overlay steps aside).
  final bool foreground;

  /// The chosen pack, or [noPetId].
  final String packId;
  final PetSize size;

  /// 安静模式: moves only, no bubbles.
  final bool quiet;
  final bool reduceMotion;

  Map<String, Object?> toMap() => {
    'state': state.name,
    'tier': tier,
    if (bubble case final bubble?) 'bubble': bubble.toMap(),
    if (target case final target?) 'target': target.toMap(),
    'active': active,
    'foreground': foreground,
    'packId': packId,
    'size': size.name,
    'quiet': quiet,
    'reduceMotion': reduceMotion,
  };

  @override
  bool operator ==(Object other) =>
      other is PetState &&
      other.state == state &&
      other.tier == tier &&
      other.bubble == bubble &&
      other.target == target &&
      other.active == active &&
      other.foreground == foreground &&
      other.packId == packId &&
      other.size == size &&
      other.quiet == quiet &&
      other.reduceMotion == reduceMotion;

  @override
  int get hashCode => Object.hash(state, tier, bubble, target, active, foreground, packId, size, quiet, reduceMotion);

  @override
  String toString() => 'PetState(${state.name}${tier > 0 ? '/$tier' : ''}${bubble == null ? '' : ' $bubble'})';
}
