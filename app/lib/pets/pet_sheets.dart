// Decoded pet sheets, shared by every sprite on screen. Deepy's 5× sheets are
// ~139 MB decoded in all (docs/design/pets.md §3.3), so nothing is decoded
// ahead: a sheet is decoded when it first plays, idle's main sheet stays, and
// the rest live in a small LRU.

import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'pet_pack.dart';

/// Process-wide cache of decoded sheets. Callers get their own handle
/// ([ui.Image.clone]) and dispose it when done, so evicting a sheet never
/// pulls it from under a sprite that still draws it.
class PetSheets {
  PetSheets._();

  static final instance = PetSheets._();

  /// Sheets kept besides the pinned ones.
  static const capacity = 3;

  final LinkedHashMap<String, ui.Image> _images = LinkedHashMap();
  final Map<String, Future<ui.Image>> _loading = {};
  final Set<String> _pinned = {};

  static String keyOf(PetPack pack, PetAnimation anim) => '${pack.id}/${anim.sheet}';

  /// Off: nothing decodes, so no pet is drawn (widget tests other than the
  /// pet's own switch it off in `flutter_test_config.dart`).
  @visibleForTesting
  static bool enabled = true;

  /// A handle to [anim]'s sheet when it is already decoded; null otherwise.
  ui.Image? peek(PetPack pack, PetAnimation anim) {
    if (!enabled) return null;
    final key = keyOf(pack, anim);
    final image = _images.remove(key);
    if (image == null) return null;
    _images[key] = image;
    return image.clone();
  }

  /// A handle to [anim]'s sheet, decoding it first if needed.
  Future<ui.Image> load(PetPack pack, PetAnimation anim, AssetBundle bundle) async {
    if (!enabled) throw StateError('pet sheets are off');
    final ready = peek(pack, anim);
    if (ready != null) return ready;
    final key = keyOf(pack, anim);
    await (_loading[key] ??= _decode(key, '${PetPack.folder(pack.id)}/${anim.sheet}', bundle));
    // Evicted by another decode in between: decode it again.
    final kept = _images[key];
    if (kept == null) return load(pack, anim, bundle);
    return kept.clone();
  }

  /// Keeps [anim]'s sheet decoded for good (idle's main animation).
  void pin(PetPack pack, PetAnimation anim) => _pinned.add(keyOf(pack, anim));

  Future<ui.Image> _decode(String key, String path, AssetBundle bundle) async {
    try {
      final data = await bundle.load(path);
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      final frame = await codec.getNextFrame();
      codec.dispose();
      _images.remove(key)?.dispose();
      _images[key] = frame.image;
      _evict();
      return frame.image;
    } finally {
      unawaited(Future<void>.microtask(() => _loading.remove(key)));
    }
  }

  void _evict() {
    var unpinned = _images.keys.where((k) => !_pinned.contains(k)).length;
    for (final key in [..._images.keys]) {
      if (unpinned <= capacity) break;
      if (_pinned.contains(key)) continue;
      _images.remove(key)?.dispose();
      unpinned--;
    }
  }

  /// Drops everything (tests).
  void clear() {
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
    _pinned.clear();
    _loading.clear();
  }
}
