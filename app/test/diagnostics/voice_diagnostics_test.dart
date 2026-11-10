import 'dart:convert';

import 'package:dsh_app/diagnostics/diagnostics_bundle.dart';
import 'package:dsh_app/diagnostics/diagnostics_channel.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/voice_settings.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/zip_reader.dart';

void main() {
  test('diagnostics retain bounded error facts and reject audio and transcript fields', () {
    final hostile = {
      'sdk': 35,
      'defaultService': 'vendor.voice/.Recognizer',
      'recognizerAvailable': true,
      'onDeviceFactoryApiAvailable': true,
      'onDeviceAvailable': false,
      'systemUnreliable': true,
      'text': 'PRIVATE_SPOKEN_WORDS',
      'audioBase64': 'PRIVATE_AUDIO_BYTES',
      'visibleServices': [for (var i = 0; i < 30; i++) 'vendor.voice/$i'],
      'recentFailures': [
        for (var i = 0; i < 30; i++)
          {
            'at': i,
            'code': 5,
            'name': 'CLIENT',
            'stage': 'listen',
            'partial': 'PRIVATE_SPOKEN_WORDS',
            'wav': 'PRIVATE_AUDIO_BYTES',
            'exceptionMessage': 'PRIVATE_SPOKEN_WORDS',
          },
      ],
    };
    final decoded = NativeDiagnostics.fromMap({'voice': hostile});
    expect(decoded.voice['recentFailures'], hasLength(20));
    expect((decoded.voice['recentFailures'] as List).first['at'], 10);
    expect(decoded.voice['visibleServices'], hasLength(16));
    final snapshot = DiagnosticsSnapshot(
      at: DateTime.utc(2026, 10, 27),
      status: const RuntimeStatus(phase: RuntimePhase.running),
      settings: const AppSettings(),
      voiceMode: VoiceMode.engine,
      // Direct construction must pass the same boundary at export.
      native: NativeDiagnostics(voice: hostile),
    );
    final entries = readZip(DiagnosticsBundle.build(snapshot));
    final text = entries.map((entry) => utf8.decode(entry.data)).join('\n');
    expect(text, isNot(contains('PRIVATE_SPOKEN_WORDS')));
    expect(text, isNot(contains('PRIVATE_AUDIO_BYTES')));
    expect(text, isNot(contains('exceptionMessage')));
    final summary = jsonDecode(utf8.decode(entries.firstWhere((e) => e.name == 'summary.json').data)) as Map;
    expect(summary['voice']['mode'], 'engine');
    expect(summary['voice']['recentFailures'], hasLength(20));
    expect(summary['voice']['recognizerAvailable'], isTrue);
  });
}
