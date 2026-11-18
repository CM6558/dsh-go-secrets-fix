import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Saved secrets that can't be parsed, so nothing in the file can be trusted.
///
/// The bad file is renamed next to itself (`secrets.json.corrupt-<ms>`) before
/// this is thrown, so the next call starts from an empty store and writes work
/// again. Callers that can tell the person to re-enter the credential (SSH
/// hosts) treat it as "saved but unreadable", not as "never saved".
class SecretStoreCorruptException implements Exception {
  const SecretStoreCorruptException(this.message);

  final String message;

  @override
  String toString() => 'SecretStoreCorruptException: $message';
}

/// Credentials in a file under the app's private support directory.
///
/// Android keeps a Keystore wrapping key per boot on some ROMs, so a
/// flutter_secure_storage item written before a reboot can't be decrypted
/// afterwards. This store never touches the Keystore: the values are as private
/// as the app's own files (no other app can read them), which is the same
/// protection the app already gives its sessions and settings.
///
/// Writes are atomic (temp file, flush, rename) and serialized, and the
/// in-memory cache only changes after the file does.
class FileSecretStore {
  FileSecretStore({Directory? root, this.fileName = 'secrets.json'}) : _root = root;

  /// Defaults to `<application support>/secrets`; tests inject a temp dir.
  final Directory? _root;
  final String fileName;

  /// Set once the app has dealt with the values the Keystore held.
  static const migratedMarker = '.migrated';

  /// Null until the file has been read once. [_cachePath] is the file it came
  /// from, so the cache never serves values read from another file.
  Map<String, String>? _values;
  String? _cachePath;
  int _dropped = 0;

  /// Every operation, including reads, runs behind this chain so a concurrent
  /// write can't lose another one's keys.
  Future<void> _queue = Future<void>.value();

  /// Entries skipped by the last load because their value wasn't a string.
  int get droppedEntries => _dropped;

  Future<Directory> _directory() async =>
      _root ?? Directory('${(await getApplicationSupportDirectory()).path}/secrets');

  Future<File> _file() async => File('${(await _directory()).path}/$fileName');

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    // A failed operation must not stall the ones queued behind it.
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<String?> read(String key) => _serial(() async => (await _load())[key]);

  Future<Map<String, String>> readAll() => _serial(() async => Map.of(await _load()));

  Future<void> write(String key, String value) => _serial(() async {
    final next = {...await _load(), key: value};
    await _persist(next);
    _values = next;
  });

  Future<void> delete(String key) => _serial(() async {
    final current = await _load();
    if (!current.containsKey(key)) return;
    final next = {...current}..remove(key);
    await _persist(next);
    _values = next;
  });

  /// Drops every saved value. The file goes first: a failed delete must not
  /// leave the cache claiming an empty store. The migration marker stays, so
  /// clearing credentials never makes the app copy the old Keystore values back.
  Future<void> clear() => _serial(() async {
    final file = await _file();
    if (await file.exists()) await file.delete();
    final temp = File('${file.path}.tmp');
    if (await temp.exists()) await temp.delete();
    _cachePath = file.path;
    _values = <String, String>{};
  });

  Future<Map<String, String>> _load() async {
    final file = await _file();
    final cached = _values;
    if (cached != null && _cachePath == file.path) return cached;
    // No file is an empty store, not an error.
    if (!await file.exists()) {
      _cachePath = file.path;
      return _values = <String, String>{};
    }
    final text = await file.readAsString();
    final Map<String, String> values;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) throw const FormatException('top level is not an object');
      values = <String, String>{};
      var dropped = 0;
      for (final entry in decoded.entries) {
        if (entry.key is String && entry.value is String) {
          values[entry.key as String] = entry.value as String;
        } else {
          dropped++;
        }
      }
      _dropped = dropped;
    } on FormatException catch (error) {
      await _quarantine(file);
      throw SecretStoreCorruptException('${file.path} is not a secret map: ${error.message}');
    }
    _cachePath = file.path;
    return _values = values;
  }

  /// Whether the legacy Keystore values were already offered to this store.
  /// Lives next to the secret file so [clear] can't undo it.
  Future<bool> isMigrated() => _serial(() async => (await _marker()).exists());

  /// Records that the legacy Keystore values were copied in, or that there were
  /// none to copy.
  Future<void> markMigrated() => _serial(() async {
    final marker = await _marker();
    await marker.parent.create(recursive: true);
    await marker.writeAsString('migrated\n', flush: true);
  });

  Future<File> _marker() async => File('${(await _directory()).path}/$migratedMarker');

  /// Keeps the bad file for inspection under a name the store never reads.
  Future<void> _quarantine(File file) async {
    try {
      await file.rename('${file.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}');
    } on FileSystemException {
      // The caller still has to hear about the corruption, not about this.
    }
  }

  Future<void> _persist(Map<String, String> values) async {
    final dir = await _directory();
    await dir.create(recursive: true);
    final file = File('${dir.path}/$fileName');
    final temp = File('${file.path}.tmp');
    final handle = await temp.open(mode: FileMode.write);
    try {
      await handle.writeString(jsonEncode(values));
      await handle.flush();
    } finally {
      await handle.close();
    }
    await temp.rename(file.path);
    _cachePath = file.path;
  }
}
