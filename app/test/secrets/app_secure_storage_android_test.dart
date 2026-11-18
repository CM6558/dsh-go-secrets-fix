import 'dart:io';

import 'package:dsh_app/secrets/file_secret_store.dart';
import 'package:dsh_app/secrets/secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

// AppSecureStorage's platform split without a device: Android resolves its
// private file store (after the one-time copy of whatever the Keystore still
// holds), OHOS keeps the dsh/secrets channel, and an explicit
// FlutterSecureStorage injection keeps the original behaviour everywhere. The
// app shares one FileSecretStore, so each test points it at a temporary
// directory instead of the real support directory.
const _channel = MethodChannel('dsh/secrets');
const _paths = MethodChannel('plugins.flutter.io/path_provider');

/// Records every call so a test can prove which backend served it.
class _FakeStorage implements FlutterSecureStorage {
  _FakeStorage([Map<String, String>? values]) : values = values ?? {};

  final Map<String, String> values;
  final List<String> calls = [];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final arguments = invocation.namedArguments;
    final member = invocation.memberName;
    if (member == #read) {
      calls.add('read');
      return Future<String?>.value(values[arguments[#key] as String]);
    }
    if (member == #write) {
      calls.add('write');
      final key = arguments[#key] as String;
      final value = arguments[#value] as String?;
      if (value == null) {
        values.remove(key);
      } else {
        values[key] = value;
      }
      return Future<void>.value();
    }
    if (member == #delete) {
      calls.add('delete');
      values.remove(arguments[#key] as String);
      return Future<void>.value();
    }
    if (member == #readAll) {
      calls.add('readAll');
      return Future<Map<String, String>>.value(Map<String, String>.of(values));
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late Directory support;
  late List<MethodCall> channelCalls;
  late Map<String, String> channelValues;

  File secretFile() => File('${root.path}/secrets.json');
  // A new store over the same directory: it reads the file, not the old cache.
  void reopen() => AppSecureStorage.fileStore = FileSecretStore(root: root);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('app-secure-storage-');
    support = await Directory.systemTemp.createTemp('app-support-');
    reopen();
    channelCalls = [];
    channelValues = {};
    FlutterSecureStorage.setMockInitialValues({});
    messenger.setMockMethodCallHandler(_paths, (_) async => support.path);
    messenger.setMockMethodCallHandler(_channel, (call) async {
      channelCalls.add(call);
      final arguments = call.arguments as Map?;
      switch (call.method) {
        case 'read':
          return channelValues[arguments!['key']];
        case 'readAll':
          return Map<String, String>.of(channelValues);
        case 'write':
          channelValues[arguments!['key'] as String] = arguments['value'] as String;
          return null;
        case 'delete':
          channelValues.remove(arguments!['key']);
          return null;
        case 'recover':
          expect(arguments, {'confirmed': true});
          channelValues.clear();
          return null;
        default:
          throw MissingPluginException();
      }
    });
  });
  tearDown(() async {
    AppSecureStorage.fileStore = FileSecretStore();
    messenger.setMockMethodCallHandler(_paths, null);
    messenger.setMockMethodCallHandler(_channel, null);
    for (final directory in [root, support]) {
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  });

  test('Android reads and writes through the private file store, not the keystore', () async {
    final store = AppSecureStorage.forPlatform('android');
    expect(await store.read(key: 'absent'), isNull);
    await store.write(key: 'remote.中文', value: 'SSH 私钥🔐\nline two');
    await store.write(key: 'second', value: 'two');
    expect(await store.read(key: 'remote.中文'), 'SSH 私钥🔐\nline two');
    expect(await store.readAll(), {'remote.中文': 'SSH 私钥🔐\nline two', 'second': 'two'});
    // The values are in the private file, so the next process sees them: a new
    // store over the same directory reads the file instead of a cache.
    expect(secretFile().existsSync(), isTrue);
    expect(await secretFile().readAsString(), contains('remote.中文'));
    reopen();
    expect(await AppSecureStorage.forPlatform('android').readAll(), {
      'remote.中文': 'SSH 私钥🔐\nline two',
      'second': 'two',
    });
    await store.delete(key: 'second');
    expect(await store.readAll(), {'remote.中文': 'SSH 私钥🔐\nline two'});
    expect(await const FlutterSecureStorage().readAll(), isEmpty);
    expect(channelCalls, isEmpty);
  });

  test('Android write with a null value clears the key like the OHOS branch', () async {
    final store = AppSecureStorage.forPlatform('android');
    await store.write(key: 'token', value: 'secret');
    await store.write(key: 'token', value: null);
    expect(await store.read(key: 'token'), isNull);
    expect(await store.readAll(), isEmpty);
    reopen();
    expect(await store.readAll(), isEmpty);
    expect(channelCalls, isEmpty);
  });

  test('Android recovery needs explicit confirmation and then clears the saved file', () async {
    final store = AppSecureStorage.forPlatform('android');
    await store.write(key: 'deepseek_api_key', value: 'sk-fixture');
    await store.write(key: 'hosted_links', value: '[]');
    await expectLater(() => store.recover(confirmed: false), throwsArgumentError);
    expect(await store.readAll(), {'deepseek_api_key': 'sk-fixture', 'hosted_links': '[]'});
    expect(secretFile().existsSync(), isTrue);
    await store.recover(confirmed: true);
    expect(await store.readAll(), isEmpty);
    expect(await store.read(key: 'deepseek_api_key'), isNull);
    reopen();
    expect(await AppSecureStorage.forPlatform('android').readAll(), isEmpty);
    expect(channelCalls, isEmpty);
  });

  test('the first Android operation copies the Keystore values into the private file once', () async {
    FlutterSecureStorage.setMockInitialValues({'remote.k': 'v', 'deepseek_api_key': 'sk-old'});
    final store = AppSecureStorage.forPlatform('android');
    expect(await store.read(key: 'remote.k'), 'v');
    expect(await secretFile().readAsString(), contains('sk-old'));
    expect(await AppSecureStorage.fileStore.isMigrated(), isTrue);
    final migrated = await secretFile().readAsString();
    // A later process (a new store over the same directory) sees the marker and
    // does not copy again.
    reopen();
    expect(await AppSecureStorage.forPlatform('android').readAll(), {'remote.k': 'v', 'deepseek_api_key': 'sk-old'});
    expect(await secretFile().readAsString(), migrated);
  });

  test('Android recovery marks the migration done so the old Keystore values never come back', () async {
    FlutterSecureStorage.setMockInitialValues({'remote.k': 'v'});
    final store = AppSecureStorage.forPlatform('android');
    expect(await store.read(key: 'remote.k'), 'v');
    await store.recover(confirmed: true);
    expect(await store.readAll(), isEmpty);
    expect(await AppSecureStorage.fileStore.isMigrated(), isTrue);
    // Whatever the vault still holds, the next process reads an empty store.
    FlutterSecureStorage.setMockInitialValues({'remote.k': 'v'});
    reopen();
    expect(await AppSecureStorage.forPlatform('android').readAll(), isEmpty);
    expect(secretFile().existsSync(), isFalse);
  });

  test('an injected FlutterSecureStorage still wins on Android', () async {
    final fake = _FakeStorage();
    final store = AppSecureStorage.forPlatform('android', fake);
    await store.write(key: 'k', value: 'v');
    expect(await store.read(key: 'k'), 'v');
    expect(await store.readAll(), {'k': 'v'});
    await store.delete(key: 'k');
    expect(fake.calls, ['write', 'read', 'readAll', 'delete']);
    expect(fake.values, isEmpty);
    expect(secretFile().existsSync(), isFalse);
    expect(channelCalls, isEmpty);
  });

  test('iOS keeps the injected storage and never touches the file store', () async {
    final fake = _FakeStorage({'keystore': 'value'});
    final store = AppSecureStorage.forPlatform('ios', fake);
    expect(await store.readAll(), {'keystore': 'value'});
    await store.write(key: 'keystore', value: null);
    expect(await store.read(key: 'keystore'), isNull);
    expect(fake.calls, ['readAll', 'write', 'read']);
    expect(secretFile().existsSync(), isFalse);
    expect(channelCalls, isEmpty);
  });

  test('OHOS still goes through the dsh/secrets channel and writes no local file', () async {
    final store = AppSecureStorage.forPlatform('ohos');
    await store.write(key: 'saved', value: 'credential');
    expect(await store.read(key: 'saved'), 'credential');
    expect(await store.readAll(), {'saved': 'credential'});
    await store.delete(key: 'saved');
    expect(await store.readAll(), isEmpty);
    expect(channelCalls.map((call) => call.method), ['write', 'read', 'readAll', 'delete', 'readAll']);
    expect(channelCalls.first.arguments, {'key': 'saved', 'value': 'credential'});
    expect(secretFile().existsSync(), isFalse);
  });

  test('the Android default store lives under <app support>/secrets', () async {
    AppSecureStorage.fileStore = FileSecretStore();
    final store = AppSecureStorage.forPlatform('android');
    await store.write(key: 'k', value: 'v');
    final written = File('${support.path}/secrets/secrets.json');
    expect(written.existsSync(), isTrue);
    expect(await written.readAsString(), contains('k'));
    expect(await store.read(key: 'k'), 'v');
  });
}
