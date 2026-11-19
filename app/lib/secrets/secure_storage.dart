import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'file_secret_store.dart';

/// True for the failures trying again can't fix: the saved credentials don't
/// decrypt, the system key they need is gone, no credentials are left and the
/// key that remains doesn't work, or the Android file store found a file it
/// can't parse. Only the OH channel and the Android file store report them.
/// Everything else (`secrets_unavailable`, `secrets_io`) may pass.
bool credentialsUnreadable(Object? error) =>
    error is SecretStoreCorruptException ||
    (error is PlatformException &&
        const {'secrets_unreadable', 'secrets_key_missing', 'secrets_key_unusable'}.contains(error.code));

/// Secret-storage operations and explicit credential recovery.
///
/// OH uses the app's HUKS channel. Android uses [FileSecretStore] instead of the
/// Keystore: some ROMs rebuild the wrapping key on every boot, which leaves
/// saved SSH keys undecryptable. Other platforms and explicit test injections
/// keep the original flutter_secure_storage implementation and options, except
/// that on iOS an item stays on this device instead of following a backup to the
/// next one.
class AppSecureStorage {
  const AppSecureStorage([this._injected]) : _platform = null;

  const AppSecureStorage.forPlatform(String operatingSystem, [this._injected]) : _platform = operatingSystem;

  final FlutterSecureStorage? _injected;
  final String? _platform;
  static const _channel = MethodChannel('dsh/secrets');

  /// Replaced by tests that need their own directory.
  @visibleForTesting
  static FileSecretStore fileStore = FileSecretStore();

  /// How long the first Android operation waits for the old Keystore vault.
  static const _migrationTimeout = Duration(seconds: 5);

  /// The store [_migration] belongs to, so a replaced [fileStore] migrates again.
  static FileSecretStore? _migrationStore;
  static Future<void>? _migration;

  bool get _ohos => _injected == null && (_platform ?? Platform.operatingSystem) == 'ohos';
  bool get _android => _injected == null && (_platform ?? Platform.operatingSystem) == 'android';
  FlutterSecureStorage get _fallback =>
      _injected ??
      const FlutterSecureStorage(iOptions: IOSOptions(accessibility: KeychainAccessibility.unlocked_this_device));

  /// Copies what the Keystore still holds into [fileStore] once, so switching
  /// Android to the private file doesn't cost the person every saved login.
  /// Awaited by the first Android operation; every failure is a reason to keep
  /// serving the file store, never a reason to fail the call.
  Future<void> _ensureMigrated() {
    if (!identical(_migrationStore, fileStore)) {
      _migrationStore = fileStore;
      _migration = _migrateKeystore();
    }
    return _migration!;
  }

  /// Never throws: the first Android operation waits on this, so a vault or a
  /// file that fails here must not take the store down with it.
  Future<void> _migrateKeystore() async {
    try {
      if (await fileStore.isMigrated()) return;
      final List<MapEntry<String, String>> legacy;
      try {
        legacy = (await _fallback.readAll().timeout(_migrationTimeout)).entries.toList();
      } on TimeoutException {
        // A vault that can't answer in time leaves the marker unwritten, so a
        // later launch can still try; this one goes on with the file store.
        return;
      } catch (_) {
        // Nothing left to read (unreadable keys, a missing key, or no plugin in
        // tests). Remembering it stops a pointless retry on every launch.
        await fileStore.markMigrated();
        return;
      }
      for (final entry in legacy) {
        try {
          await fileStore.write(entry.key, entry.value);
        } catch (_) {
          // One key that won't write must not stop the others.
        }
      }
      await fileStore.markMigrated();
    } catch (_) {
      // A store that can't be reached is served as it is; the marker stays off,
      // so the next launch tries again.
    }
  }

  Future<String?> read({required String key}) async {
    if (_android) {
      // ignore: avoid_print
      print('[DSHDBG] read($key) android, awaiting migration');
      await _ensureMigrated();
      // ignore: avoid_print
      print('[DSHDBG] read($key) migration done');
      final value = await fileStore.read(key);
      // ignore: avoid_print
      print('[DSHDBG] read($key) -> ${value == null ? "null" : "${value.length}B"}');
      return value;
    }
    if (!_ohos) return _fallback.read(key: key);
    final value = await _channel.invokeMethod<Object?>('read', {'key': key});
    if (value == null || value is String) return value as String?;
    throw const FormatException('Invalid secret-storage response');
  }

  Future<void> write({required String key, required String? value}) async {
    if (_android) {
      await _ensureMigrated();
      if (value == null) return delete(key: key);
      return fileStore.write(key, value);
    }
    if (!_ohos) return _fallback.write(key: key, value: value);
    if (value == null) return delete(key: key);
    await _channel.invokeMethod<void>('write', {'key': key, 'value': value});
  }

  Future<void> delete({required String key}) async {
    if (_android) {
      await _ensureMigrated();
      return fileStore.delete(key);
    }
    if (!_ohos) return _fallback.delete(key: key);
    await _channel.invokeMethod<void>('delete', {'key': key});
  }

  /// Call only after the user confirms clearing all locally saved credentials.
  /// On OH native recovery keeps host configuration and shares the read/write
  /// queue; on Android it deletes the secret file and marks the migration done,
  /// so the next launch can't copy the old Keystore values back in.
  Future<void> recover({required bool confirmed}) async {
    if (!confirmed) throw ArgumentError.value(confirmed, 'confirmed', 'Explicit confirmation required');
    if (_android) {
      await fileStore.clear();
      await fileStore.markMigrated();
      try {
        await _fallback.deleteAll().timeout(_migrationTimeout);
      } catch (_) {
        // The vault that can't be read can't be emptied either; the file store
        // is what the app reads from now on.
      }
      return;
    }
    if (!_ohos) throw UnsupportedError('Credential recovery is only available on OHOS and Android');
    await _channel.invokeMethod<void>('recover', {'confirmed': true});
  }

  Future<Map<String, String>> readAll() async {
    if (_android) {
      await _ensureMigrated();
      return fileStore.readAll();
    }
    if (!_ohos) return _fallback.readAll();
    final value = await _channel.invokeMethod<Object?>('readAll');
    if (value is! Map) throw const FormatException('Invalid secret-storage response');
    final result = <String, String>{};
    for (final entry in value.entries) {
      if (entry.key is! String || entry.value is! String) {
        throw const FormatException('Invalid secret-storage response');
      }
      result[entry.key as String] = entry.value as String;
    }
    return result;
  }
}
