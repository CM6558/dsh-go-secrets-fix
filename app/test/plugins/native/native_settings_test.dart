// 设置 › 插件 › 某插件: a switch per place the plugin shows up, and one quiet
// 「原生界面」 line that opens the problems with their paths. Plugins without
// a native part get nothing.

import 'package:dsh_app/plugins/native/native_model.dart';
import 'package:dsh_app/plugins/native/native_state.dart';
import 'package:dsh_app/ui/plugins/native/native_plugin_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../chat/support/harness.dart';
import 'support.dart';

Future<ProviderContainer> pumpSection(WidgetTester tester, FakeBridge bridge, String package) async {
  usePhoneView(tester);
  await tester.pumpWidget(
    testApp(
      Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [NativePluginSection(package: package)],
          ),
        ),
      ),
      overrides: nativeOverrides(bridge),
    ),
  );
  await pumpFrames(tester);
  return ProviderScope.containerOf(tester.element(find.byType(NativePluginSection)));
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a switch per declared place, then the status line', (tester) async {
    final container = await pumpSection(tester, FakeBridge(contributions([quickPlugin()])), 'dsh-go-example-quick');
    expect(find.text('输入框按钮'), findsOneWidget);
    expect(find.text('消息菜单'), findsOneWidget);
    expect(find.text('状态条'), findsNothing, reason: 'only what the plugin declares');
    expect(find.text('原生界面'), findsOneWidget);
    expect(find.text('正常'), findsOneWidget);

    await tester.tap(find.text('输入框按钮'));
    await pumpFrames(tester);
    expect(container.read(nativeComposerActionsProvider), isEmpty);
    expect(container.read(nativeMessageActionsProvider), isNotEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(NativeSurfacePrefs.prefsKey), contains('composer.actions'));

    await tester.tap(find.byType(Switch).first);
    await pumpFrames(tester);
    expect(container.read(nativeComposerActionsProvider), hasLength(2));
  });

  testWidgets('problems: counted on the line, listed with their paths; the stats when known', (tester) async {
    final bridge = FakeBridge(
      contributions([
        plugin(
          'p',
          title: '示例',
          composer: [
            {'id': 'a', 'label': 'A'},
          ],
          issues: [
            {'path': '/dshGo/contributes/composer.actions/2/label', 'code': 'too-long', 'severity': 'warn'},
            {'path': '/dshGo/contributes/panels/0/view', 'code': 'view-file', 'severity': 'error'},
          ],
        ),
      ]),
    );
    final container = await pumpSection(tester, bridge, 'p');
    container.read(nativeDiagnosticsProvider.notifier)
      ..view('p', 3277)
      ..invoked('p', const Duration(milliseconds: 48))
      ..report('p', '/runtime/a', [const NativeIssue('', '插件没有及时响应', code: 'timeout')]);
    await pumpFrames(tester);
    expect(find.text('3 项有误'), findsOneWidget);
    expect(find.text('视图 3.2 KB · 响应 48 ms'), findsOneWidget);

    await tester.tap(find.text('原生界面'));
    await tester.pumpAndSettle();
    expect(find.text('最近视图'), findsOneWidget);
    expect(find.text('3.2 KB'), findsOneWidget);
    expect(find.text('48 ms'), findsOneWidget);
    expect(find.text('插件没有及时响应'), findsOneWidget);
    expect(find.text('/runtime/a'), findsOneWidget);
    expect(find.text('文字太长，已截断'), findsOneWidget);
    expect(find.text('/dshGo/contributes/composer.actions/2/label'), findsOneWidget);
    expect(find.text('视图文件读不出'), findsOneWidget);
  });

  testWidgets('a plugin for a newer app: no switches, the line says why', (tester) async {
    await pumpSection(
      tester,
      FakeBridge(
        contributions([
          plugin(
            'old',
            state: 'needs-app',
            issues: [
              {'path': '/dshGo/minApp', 'code': 'needs-app', 'severity': 'error'},
            ],
          ),
        ]),
      ),
      'old',
    );
    expect(find.byType(Switch), findsNothing);
    expect(find.text('需要更新 App'), findsOneWidget);
  });

  testWidgets('a plugin without a native part: nothing here', (tester) async {
    await pumpSection(tester, FakeBridge(contributions([quickPlugin()])), 'some-web-plugin');
    expect(tester.getSize(find.byType(NativePluginSection)), const Size(350, 0));
  });
}
