import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/secrets/file_secret_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// The Android private-file secret store, exercised as plain file I/O: every
// store gets an injected temporary root, so nothing here reads the app's real
// support directory and no binding-dependent plugin state is involved.
const _paths = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;

  File file([String name = 'secrets.json']) => File('${root.path}/$name');
  FileSecretStore store([String name = 'secrets.json']) => FileSecretStore(root: root, fileName: name);
  List<File> backups([String name = 'secrets.json']) => root
      .listSync()
      .whereType<File>()
      .where((entry) => entry.uri.pathSegments.last.startsWith('$name.corrupt-'))
      .toList();

  setUp(() async {
    root = await Directory.systemTemp.createTemp('file-secret-store-');
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(_paths, null);
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('a missing file is an empty store and is not created by reading', () async {
    final secrets = store();
    expect(await secrets.read('absent'), isNull);
    expect(await secrets.readAll(), isEmpty);
    expect(file().existsSync(), isFalse);
  });

  test('write then read keeps unicode, newlines and empty values on disk', () async {
    final secrets = store();
    await secrets.write('remote.中文', 'SSH 私钥🔐\nline two');
    await secrets.write('empty', '');
    expect(await secrets.read('remote.中文'), 'SSH 私钥🔐\nline two');
    expect(await secrets.read('empty'), '');
    expect(await secrets.readAll(), {'remote.中文': 'SSH 私钥🔐\nline two', 'empty': ''});
    final onDisk = jsonDecode(await file().readAsString()) as Map<String, dynamic>;
    expect(onDisk['remote.中文'], 'SSH 私钥🔐\nline two');
    expect(onDisk['empty'], '');
  });

  test('delete removes one key and keeps the rest', () async {
    final secrets = store();
    await secrets.write('keep', 'one');
    await secrets.write('drop', 'two');
    await secrets.delete('drop');
    expect(await secrets.read('drop'), isNull);
    expect(await secrets.readAll(), {'keep': 'one'});
    await secrets.delete('never-written');
    expect(await secrets.readAll(), {'keep': 'one'});
  });

  test('a second instance reads what an earlier instance wrote', () async {
    await store().write('a', '1');
    await store().write('b', '2');
    expect(await store().readAll(), {'a': '1', 'b': '2'});
    expect(await store().read('a'), '1');
  });

  test('20 concurrent writes keep every key', () async {
    final secrets = store();
    await Future.wait([for (var i = 0; i < 20; i++) secrets.write('key$i', 'value$i')]);
    final expected = {for (var i = 0; i < 20; i++) 'key$i': 'value$i'};
    expect(await secrets.readAll(), expected);
    expect(jsonDecode(await file().readAsString()) as Map<String, dynamic>, hasLength(20));
  });

  test('a concurrent reader never observes a half-written file', () async {
    final expected = {for (var i = 0; i < 20; i++) 'key$i': 'value$i'};
    final writer = store();
    final snapshots = <Map<String, dynamic>>[];
    final failures = <Object>[];
    var writing = true;
    final reader = () async {
      // The canonical path is read directly: the rename either published the
      // whole new map or left the previous one, so a decode failure here means
      // a torn file was visible.
      while (writing) {
        try {
          if (file().existsSync()) snapshots.add(jsonDecode(await file().readAsString()) as Map<String, dynamic>);
        } on FileSystemException {
          // The first write has not published the file yet.
        } catch (error) {
          failures.add(error);
        }
        await Future<void>.delayed(Duration.zero);
      }
    }();
    for (var i = 0; i < 20; i++) {
      await writer.write('key$i', 'value$i');
    }
    writing = false;
    await reader;
    expect(failures, isEmpty, reason: 'every published file decodes as a complete map');
    expect(snapshots, isNotEmpty);
    for (final snapshot in snapshots) {
      for (final entry in snapshot.entries) {
        expect(expected[entry.key], entry.value, reason: 'snapshot $snapshot');
      }
    }
    expect(await writer.readAll(), expected);
  });

  test('a write that cannot publish keeps the previous file and the cache unchanged', () async {
    final secrets = store();
    await secrets.write('kept', 'original');
    final before = await file().readAsString();
    await Process.run('chmod', ['0500', root.path]);
    addTearDown(() => Process.run('chmod', ['0700', root.path]));
    // The directory must really refuse new files: as root the mode would not
    // hold and this test would prove nothing.
    var blocked = false;
    try {
      await File('${root.path}/probe').writeAsString('x');
    } on FileSystemException {
      blocked = true;
    }
    expect(blocked, isTrue, reason: 'needs a non-root POSIX user for a read-only directory');
    await expectLater(secrets.write('added', 'value'), throwsA(anything));
    expect(await file().readAsString(), before);
    expect(await secrets.read('added'), isNull);
    expect(await secrets.read('kept'), 'original');
    await Process.run('chmod', ['0700', root.path]);
    await secrets.write('added', 'value');
    expect(await secrets.readAll(), {'kept': 'original', 'added': 'value'});
  });

  test('invalid JSON throws SecretStoreCorruptException and keeps a timestamped copy', () async {
    const broken = '{"kept": "value", "cut":';
    await file().writeAsString(broken);
    final secrets = store();
    await expectLater(
      secrets.readAll(),
      throwsA(isA<SecretStoreCorruptException>().having((error) => error.message, 'message', isNotEmpty)),
    );
    expect(file().existsSync(), isFalse, reason: 'the bad file is moved aside, not left in place');
    expect(backups(), hasLength(1));
    expect(await backups().single.readAsString(), broken);
    // The backup keeps the bad bytes, so the store is usable again right away.
    await secrets.write('fresh', 'value');
    expect(await secrets.readAll(), {'fresh': 'value'});
    expect(await store().read('fresh'), 'value');
    expect(backups(), hasLength(1), reason: 'a healthy file is never moved aside');
  });

  test('read on a corrupt file fails the same way and backs it up once', () async {
    await file().writeAsString('not json at all');
    await expectLater(store().read('k'), throwsA(isA<SecretStoreCorruptException>()));
    expect(backups(), hasLength(1));
    expect(await backups().single.readAsString(), 'not json at all');
    expect(await store().read('k'), isNull);
  });

  test('non-String entries are dropped instead of failing the whole file', () async {
    await file().writeAsString(
      jsonEncode({
        'good': 'value',
        'number': 7,
        'flag': true,
        'nothing': null,
        'list': [1, 2],
        'object': {'nested': 'x'},
      }),
    );
    final secrets = store();
    expect(await secrets.readAll(), {'good': 'value'});
    expect(await secrets.read('number'), isNull);
    expect(await secrets.read('object'), isNull);
    await secrets.write('after', 'ok');
    expect(await secrets.readAll(), {'good': 'value', 'after': 'ok'});
  });

  test('fileName selects the file and the corrupt copy next to it', () async {
    final secrets = store('alt.json');
    await secrets.write('k', 'v');
    expect(file('alt.json').existsSync(), isTrue);
    expect(file().existsSync(), isFalse);
    await file('alt.json').writeAsString('{');
    await expectLater(store('alt.json').readAll(), throwsA(isA<SecretStoreCorruptException>()));
    expect(backups('alt.json'), hasLength(1));
    expect(backups(), isEmpty);
  });

  test('clear empties the store for this and later instances', () async {
    final secrets = store();
    await secrets.write('a', '1');
    await secrets.write('b', '2');
    await secrets.clear();
    expect(await secrets.readAll(), isEmpty);
    expect(await secrets.read('a'), isNull);
    expect(await store().readAll(), isEmpty);
    await secrets.write('c', '3');
    expect(await store().readAll(), {'c': '3'});
  });

  test('the migration marker is off until marked and survives clear', () async {
    final marker = File('${root.path}/${FileSecretStore.migratedMarker}');
    final secrets = store();
    expect(await secrets.isMigrated(), isFalse);
    expect(marker.existsSync(), isFalse);
    await secrets.markMigrated();
    expect(await secrets.isMigrated(), isTrue);
    expect(marker.existsSync(), isTrue);
    await secrets.write('k', 'v');
    expect(await secrets.readAll(), {'k': 'v'}, reason: 'the marker is not a saved secret');
    await secrets.clear();
    expect(await secrets.readAll(), isEmpty);
    // Clearing credentials must not re-enable the copy of the old Keystore values.
    expect(await secrets.isMigrated(), isTrue);
    expect(await store().isMigrated(), isTrue);
    await secrets.markMigrated();
    expect(await secrets.isMigrated(), isTrue, reason: 'marking twice is harmless');
  });

  test('the default root is <app support>/secrets', () async {
    final methods = <String>[];
    messenger.setMockMethodCallHandler(_paths, (call) async {
      methods.add(call.method);
      return root.path;
    });
    final secrets = FileSecretStore();
    await secrets.write('k', 'v');
    expect(methods, isNotEmpty);
    expect(methods, everyElement('getApplicationSupportDirectory'));
    final written = File('${root.path}/secrets/secrets.json');
    expect(written.existsSync(), isTrue);
    expect(await secrets.read('k'), 'v');
    expect(jsonDecode(await written.readAsString()) as Map<String, dynamic>, containsPair('k', 'v'));
  });
}
