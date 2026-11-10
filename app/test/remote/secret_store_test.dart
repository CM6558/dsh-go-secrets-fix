// FileSecretStore: the app-private secret file that replaced the Android
// Keystore. Values must survive a fresh instance (the reboot case), stay
// namespaced apart, and a corrupt file must report unreadable instead of
// silently reading as "never saved".

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/remote/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('dshgo-secrets');
    file = File('${dir.path}/secrets.json');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  FileSecretStore store() => FileSecretStore(file: Future.value(file));

  test('a value written by one instance is read back by the next', () async {
    await store().write('remote.ssh.h.password', 'hunter2');
    // A new instance is what the next launch does: nothing is cached in memory.
    expect(await store().read('remote.ssh.h.password'), 'hunter2');
    expect(await file.exists(), isTrue);
  });

  test('a missing key is null, not an error', () async {
    expect(await store().read('never.saved'), isNull);
  });

  test('an empty file reads as no secrets', () async {
    await file.writeAsString('');
    expect(await store().read('x'), isNull);
  });

  test('namespaced stores do not collide in the one file', () async {
    final remote = NamespacedSecretStore(store(), 'remote.');
    final forum = NamespacedSecretStore(store(), 'forum.');
    await remote.write('token', 'r1');
    await forum.write('token', 'f1');
    expect(await remote.read('token'), 'r1');
    expect(await forum.read('token'), 'f1');
    expect((await remote.readAll()).keys, ['token']);
    expect((await forum.readAll()).keys, ['token']);
  });

  test('rapid writes all land', () async {
    final vault = store();
    await Future.wait([for (var i = 0; i < 20; i++) vault.write('k$i', 'v$i')]);
    final all = await store().readAll(prefix: 'k');
    expect(all, hasLength(20));
    expect(all['k7'], 'v7');
  });

  test('delete removes only that key', () async {
    final vault = store();
    await vault.write('a', '1');
    await vault.write('b', '2');
    await vault.delete('a');
    expect(await store().read('a'), isNull);
    expect(await store().read('b'), '2');
  });

  test('a corrupt file reports unreadable and keeps the bytes aside', () async {
    await file.writeAsString('{not json');
    await expectLater(store().read('x'), throwsA(isA<SecretUnreadableException>()));
    expect(await File('${file.path}.corrupt').exists(), isTrue, reason: 'the bytes must not be destroyed');
  });

  test('values are written as plain JSON in the app-private file', () async {
    await store().write('remote.ssh.h.privateKey', '-----BEGIN KEY-----');
    final raw = jsonDecode(await file.readAsString()) as Map;
    expect(raw['remote.ssh.h.privateKey'], '-----BEGIN KEY-----');
  });

  test('readAll without a prefix returns everything', () async {
    final vault = store();
    await vault.write('a', '1');
    await vault.write('b', '2');
    expect(await store().readAll(), {'a': '1', 'b': '2'});
  });
}
