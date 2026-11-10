// The dsh-go-guide skill (docs/guide, built by tool/guide_sync.py): it ships in
// the app's assets, the engine-start auto-install puts it in
// `$DSH_HOME/skills/dsh-go-guide/` next to the other two, keeps it current
// while SKILL.md carries the managed line, and leaves it alone once the person
// removes that line.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/ui_config/ui_config.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';
import 'skill_native_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late UiSkillBundle guide;
  late Directory root;

  setUpAll(() async => guide = await loadUiSkillBundle(readAssetFromDisk, guideSkillName));
  setUp(() => root = tempRootfs());
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Directory installed() => Directory('${root.path}/root/.dsh/skills/$guideSkillName');

  test('the bundle: every asset mapped, both languages page for page, links resolve, SKILL.md managed and last', () {
    final assets = Directory('$appDir/assets/skills/$guideSkillName');
    final manifest = jsonDecode(File('${assets.path}/manifest.json').readAsStringSync()) as Map;
    expect(manifest['name'], guideSkillName);
    final files = (manifest['files'] as Map).cast<String, String>();
    expect(files.keys.toSet(), {for (final f in assets.listSync()) f.uri.pathSegments.last}..remove('manifest.json'));

    expect(guide.name, guideSkillName);
    expect(guide.files.keys.toSet(), files.values.toSet());
    expect(
      guide.files.keys,
      containsAll(['SKILL.md', 'README.md', 'zh/04-phone-control.md', 'en/04-phone-control.md']),
    );
    expect(guide.writeOrder.last.key, 'SKILL.md');
    expect(guide.skillMd.split('\n').first, '---');
    expect(isManagedUiSkill(guide.skillMd), isTrue);
    expect(guide.skillMd, contains('name: $guideSkillName\n'));

    Set<String> pages(String locale) => {
      for (final path in guide.files.keys)
        if (path.startsWith('$locale/')) path.substring(locale.length + 1),
    };
    expect(pages('zh'), isNotEmpty);
    expect(pages('en'), pages('zh'));

    // Relative links land on a file of the bundle, wherever it is installed.
    final link = RegExp(r'\]\(([^)\s]+)\)');
    for (final MapEntry(key: path, value: text) in guide.files.entries) {
      for (final match in link.allMatches(text)) {
        final target = match[1]!;
        if (RegExp(r'^(https?|mailto|dshgo):').hasMatch(target)) continue;
        final resolved = Uri.parse(path).resolve(target.split('#').first).path;
        expect(guide.files.keys, contains(resolved), reason: '$path → $target');
      }
    }
  });

  test('installs the nested folder, repairs a managed copy, leaves a taken-over one alone', () async {
    expect(await installUiSkill(root, guide), UiSkillInstallResult.installed);
    for (final MapEntry(key: path, value: text) in guide.files.entries) {
      expect(File('${installed().path}/$path').readAsStringSync(), text, reason: path);
    }
    expect(File('${installed().path}/SKILL.md').readAsStringSync(), contains(uiSkillManagedMarker));
    expect(await installUiSkill(root, guide), UiSkillInstallResult.unchanged);

    final page = File('${installed().path}/zh/04-phone-control.md');
    page.writeAsStringSync('outdated');
    expect(await installUiSkill(root, guide), UiSkillInstallResult.updated);
    expect(page.readAsStringSync(), guide.files['zh/04-phone-control.md']);

    // The person deletes the managed line: the folder is theirs from now on.
    final skill = File('${installed().path}/SKILL.md');
    skill.writeAsStringSync(
      skill.readAsStringSync().replaceFirst(RegExp(r'^# dsh-go:managed.*\n', multiLine: true), ''),
    );
    page.writeAsStringSync('my notes');
    expect(await installUiSkill(root, guide), UiSkillInstallResult.userOwned);
    expect(page.readAsStringSync(), 'my notes');
    expect(skill.readAsStringSync(), isNot(contains(uiSkillManagedMarker)));
    expect(installed().listSync(recursive: true).where((f) => f.path.endsWith('.dsh-go-tmp')), isEmpty);
  });

  test('no DSH home yet: nothing is created', () async {
    root.deleteSync(recursive: true);
    root = tempRootfs(withHome: false);
    expect(await installUiSkill(root, guide), UiSkillInstallResult.noHome);
    expect(installed().existsSync(), isFalse);
  });

  test('the default loaders bring the guide in from the app bundle on engine start', () async {
    late SkillRuntime runtime;
    final c = ProviderContainer(
      overrides: [
        localRuntimeProvider.overrideWith(() => runtime = SkillRuntime(RuntimePhase.installed)),
        runtimeBridgeProvider.overrideWithValue(SkillFileBridge()),
        uiRootfsResolverProvider.overrideWithValue(() async => root),
      ],
    );
    addTearDown(c.dispose);
    c.listen(uiSkillAutoInstallProvider, (_, _) {});
    expect(installed().existsSync(), isFalse);

    runtime.setPhase(RuntimePhase.running);
    await until(() => c.read(uiSkillAutoInstallProvider) != null);
    await c.read(uiSkillAutoInstallProvider.notifier).running;
    for (final name in [uiSkillName, pluginSkillName, guideSkillName]) {
      expect(File('${root.path}/root/.dsh/skills/$name/SKILL.md').existsSync(), isTrue, reason: name);
    }
    for (final MapEntry(key: path, value: text) in guide.files.entries) {
      expect(File('${installed().path}/$path').readAsStringSync(), text, reason: path);
    }
  });
}
