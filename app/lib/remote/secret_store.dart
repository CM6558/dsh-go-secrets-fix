import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

/// The entry is there but could not be read: the value still exists, it just
/// can't be handed over right now.
///
/// Distinct from `null` ("never saved") because the fix differs: this one must
/// not be reported as "enter it again", and the caller must not overwrite the
/// stored copy with an empty value.
class SecretUnreadableException implements Exception {
  const SecretUnreadableException(this.key, this.cause);

  /// The caller-facing key (no store namespace).
  final String key;

  /// What the storage reported.
  final Object cause;

  @override
  String toString() => 'SecretUnreadableException($key): $cause';
}

/// Where secrets live: SSH passwords and private keys, relay device
/// credentials, API keys, forum keys. Never SharedPreferences (that file is
/// read by a lot of unrelated code).
///
/// Injectable so state and tests can swap in [MemorySecretStore], and so the
/// relay package (`dsh_remote`) can be handed the same store.
abstract class SecretStore {
  /// The stored value, or null when nothing was ever saved.
  ///
  /// Throws [SecretUnreadableException] when a value exists but cannot be
  /// handed over — callers must keep that apart from null.
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);

  /// Every stored value whose key starts with [prefix], keyed without it.
  Future<Map<String, String>> readAll({String prefix = ''});
}

/// Secrets in one app-private file: `<app support>/secrets/secrets.json`.
///
/// **Why not the Android Keystore.** The Keystore path
/// (`flutter_secure_storage`) wraps an AES key with an RSA key held in the
/// device keystore. When that wrapping key is replaced — the TEE is reset, a
/// hardware-key simulator is installed or reconfigured, or the entry is
/// restored onto another device — every value it wrapped becomes unreadable,
/// permanently. On top of that, the plugin's `resetOnError` default is **true**:
/// a read that fails to decrypt *deletes the entry*. A person who saved a key
/// then finds an empty field after the next reboot and has to type it in again,
/// every time; a phone whose TEE reports broken never recovers.
///
/// A file in the app's private storage has neither failure mode: Android keeps
/// `/data/data/<app>` unreadable to other apps and encrypted at rest while the
/// phone is locked, and nothing re-wraps it on boot. The trade-off is stated
/// plainly rather than hidden: this is **not** hardware-backed, so root or full
/// device compromise can read the file. That is the exposure `~/.ssh` and the
/// SSH agent already have on such a device, and it is the right trade for
/// credentials that must survive a reboot.
class FileSecretStore implements SecretStore {
  FileSecretStore({Future<File>? file}) : _file = file ?? defaultFile();

  static const fileName = 'secrets.json';

  /// `<app support>/secrets/secrets.json`, directory created on first use.
  static Future<File> defaultFile() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/secrets');
    await dir.create(recursive: true);
    return File('${dir.path}/$fileName');
  }

  final Future<File> _file;

  /// Loaded once; every mutation rewrites the file atomically.
  Map<String, String>? _values;
  Future<Map<String, String>>? _loading;

  /// Serializes mutations so two rapid saves can't lose one another.
  Future<void> _queue = Future.value();

  Future<Map<String, String>> _load() {
    final cached = _values;
    if (cached != null) return Future.value(cached);
    return _loading ??= _readFile().then(
      (values) {
        _values = values;
        _loading = null;
        return values;
      },
      onError: (Object error) {
        _loading = null;
        throw error;
      },
    );
  }

  Future<Map<String, String>> _readFile() async {
    final file = await _file;
    if (!await file.exists()) return <String, String>{};
    final String text;
    try {
      text = await file.readAsString();
    } on FileSystemException catch (e) {
      throw SecretUnreadableException(fileName, e);
    }
    if (text.trim().isEmpty) return <String, String>{};
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (e) {
      await _quarantine(file);
      throw SecretUnreadableException(fileName, e);
    }
    if (decoded is! Map) {
      await _quarantine(file);
      throw SecretUnreadableException(fileName, const FormatException('secrets file is not an object'));
    }
    return {
      for (final entry in decoded.entries)
        if (entry.key is String && entry.value is String) entry.key as String: entry.value as String,
    };
  }

  /// Moves a corrupt file aside once, so the next launch starts clean but the
  /// bytes are not silently destroyed.
  Future<void> _quarantine(File file) async {
    try {
      if (await file.exists()) await file.rename('${file.path}.corrupt');
    } catch (_) {
      // Best effort: a failure here must not mask the read error.
    }
  }

  Future<T> _mutate<T>(T Function(Map<String, String> values) change) {
    final result = _queue.then((_) async {
      final values = Map<String, String>.of(await _load());
      final out = change(values);
      _values = values;
      await _writeFile(values);
      return out;
    });
    // Keep the chain alive even when a caller ignores the returned future.
    _queue = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> _writeFile(Map<String, String> values) async {
    final file = await _file;
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(values), flush: true);
    await tmp.rename(file.path);
  }

  @override
  Future<String?> read(String key) async => (await _load())[key];

  @override
  Future<void> write(String key, String value) => _mutate((values) => values[key] = value);

  @override
  Future<void> delete(String key) => _mutate((values) => values.remove(key));

  @override
  Future<Map<String, String>> readAll({String prefix = ''}) async {
    final values = await _load();
    return {
      for (final entry in values.entries)
        if (entry.key.startsWith(prefix)) entry.key.substring(prefix.length): entry.value,
    };
  }

  /// Copies anything still readable out of the old Keystore-backed storage,
  /// once, then records that it ran.
  ///
  /// Values the Keystore can no longer decrypt are simply absent — the old
  /// plugin deleted them on its failed read — so this only rescues devices
  /// where the Keystore still works. Those are exactly the devices where a
  /// silent switch would otherwise make every saved password look lost.
  Future<void> migrateFromKeystore({FlutterSecureStorage? from}) async {
    const marker = 'secrets.migrated_from_keystore';
    final Map<String, String> old;
    try {
      old = await (from ?? const FlutterSecureStorage()).readAll();
    } catch (_) {
      return; // Old storage unavailable: leave the marker for a later launch.
    }
    await _mutate((values) {
      for (final entry in old.entries) {
        values.putIfAbsent(entry.key, () => entry.value);
      }
      values[marker] = DateTime.now().toUtc().toIso8601String();
    });
  }
}

/// [SecretStore] over a shared [FileSecretStore], under a key prefix.
///
/// The prefix keeps stores apart in the one file: `remote.` for SSH and relay,
/// `forum.` for the forum's key pair, no prefix for the DeepSeek key.
class NamespacedSecretStore implements SecretStore {
  const NamespacedSecretStore(this._vault, [this._prefix = '']);

  final FileSecretStore _vault;
  final String _prefix;

  String _k(String key) => '$_prefix$key';

  @override
  Future<String?> read(String key) async {
    try {
      return await _vault.read(_k(key));
    } catch (e) {
      throw SecretUnreadableException(key, e);
    }
  }

  @override
  Future<void> write(String key, String value) => _vault.write(_k(key), value);

  @override
  Future<void> delete(String key) => _vault.delete(_k(key));

  @override
  Future<Map<String, String>> readAll({String prefix = ''}) => _vault.readAll(prefix: _k(prefix));
}

/// The one vault the app uses. Construction is cheap (the file is resolved on
/// first read), so stores can hold it directly.
final FileSecretStore appSecretVault = FileSecretStore();

/// In-memory store for tests and previews.
class MemorySecretStore implements SecretStore {
  MemorySecretStore([Map<String, String>? initial]) : values = {...?initial};

  final Map<String, String> values;

  /// Keys whose read should fail, to exercise the unreadable path.
  final Set<String> unreadable = {};

  @override
  Future<String?> read(String key) async {
    if (unreadable.contains(key)) throw SecretUnreadableException(key, 'test: storage unavailable');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<Map<String, String>> readAll({String prefix = ''}) async => {
    for (final entry in values.entries)
      if (entry.key.startsWith(prefix)) entry.key.substring(prefix.length): entry.value,
  };
}
