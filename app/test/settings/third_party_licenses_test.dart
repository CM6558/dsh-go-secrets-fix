// The open-source licences page: every bundled third-party notice is registered once,
// with the copyright line and licence THIRD_PARTY_NOTICES.md gives it.

import 'dart:io';

import 'package:dsh_app/ui/common/third_party_licenses.dart';
import 'package:dsh_app/ui/settings/font_licenses.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Package name → a line its entry must carry, also found in THIRD_PARTY_NOTICES.md.
const _expected = <String, String>{
  'PiPilot': 'Copyright (c) 2026 CikeSeven',
  'DeepSeek Harness': 'Copyright (c) 2026 DeepSeek',
  'Phase': 'Copyright (c) 2026 CikeSeven',
  'DS Bot': 'Copyright 2026 Fei2411 and the DS Bot contributors',
  'ds-harness-remote': 'Copyright (c) 2026 DSH Remote contributors',
  'DSHA': 'Copyright (c) 2026 qiannianhuanxiang',
  'Shizuku-API': 'Copyright (c) 2021 RikkaW',
  'libadb-android': 'Copyright 2021 Muntashir Al-Islam',
  'spake2-android': 'Copyright 2021 Muntashir Al-Islam',
  'Conscrypt': 'Copyright 2016 The Android Open Source Project',
  'Bouncy Castle': 'Copyright (c) 2000-2023 The Legion of the Bouncy Castle Inc.',
  'XZ for Java': 'Copyright (C) The XZ for Java authors and contributors',
  'AndroidX WebKit': 'The Android Open Source Project',
  'Phosphor Icons': 'Copyright (c) 2023 Phosphor Icons',
  'Material Icons': 'Google',
  'discourse-emojis': 'Joffrey Jaffeux',
  'JetBrains Mono': 'Copyright 2020 The JetBrains Mono Project Authors',
};

const _mit = 'Permission is hereby granted, free of charge';
const _apache = 'Apache License\n                           Version 2.0, January 2004';
const _lgpl = 'GNU LESSER GENERAL PUBLIC LICENSE\n                       Version 3, 29 June 2007';
const _gpl = 'GNU GENERAL PUBLIC LICENSE\n                       Version 3, 29 June 2007';

void main() {
  late List<LicenseEntryWithLineBreaks> entries;

  setUpAll(() async {
    LicenseRegistry.reset();
    registerThirdPartyLicenses();
    registerFontLicenses();
    entries = (await LicenseRegistry.licenses.toList()).cast<LicenseEntryWithLineBreaks>();
  });
  tearDownAll(LicenseRegistry.reset);

  String textOf(String package) => entries.singleWhere((e) => e.packages.contains(package)).text;

  test('each package is registered exactly once', () {
    final names = [for (final entry in entries) ...entry.packages];
    final repeated = {
      for (final name in names)
        if (names.where((n) => n == name).length > 1) name,
    };
    expect(repeated, isEmpty);
  });

  test('every bundled third-party notice is listed', () {
    final names = {for (final entry in entries) ...entry.packages};
    expect(names, _expected.keys.toSet());
  });

  test('copyright lines agree with THIRD_PARTY_NOTICES.md', () {
    final notices = File('../THIRD_PARTY_NOTICES.md').readAsStringSync();
    for (final MapEntry(key: package, value: line) in _expected.entries) {
      expect(textOf(package), contains(line), reason: package);
      expect(notices, contains(line), reason: package);
    }
  });

  test('each entry carries its own licence text', () {
    for (final package in [
      'PiPilot',
      'DeepSeek Harness',
      'ds-harness-remote',
      'DSHA',
      'Shizuku-API',
      'Phosphor Icons',
      'discourse-emojis',
    ]) {
      expect(textOf(package), contains(_mit), reason: package);
      expect(textOf(package), isNot(contains('Apache License')), reason: package);
    }
    for (final package in ['DS Bot', 'libadb-android', 'Conscrypt', 'AndroidX WebKit', 'Material Icons']) {
      expect(textOf(package), contains(_apache), reason: package);
    }
    expect(textOf('spake2-android'), allOf(contains(_lgpl), contains(_gpl)));
    expect(textOf('Phase'), contains("used with the author's permission"));
    expect(textOf('Bouncy Castle'), contains(_mit));
    expect(textOf('XZ for Java'), contains('Permission to use, copy, modify, and/or distribute'));
    expect(textOf('JetBrains Mono'), contains('SIL OPEN FONT LICENSE Version 1.1'));
  });
}
