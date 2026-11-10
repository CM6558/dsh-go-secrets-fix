// PhoneControlScreen, section by section: master switch + disclosure, blockers
// (未就绪 / safe mode / remote host), permission rows with fixes, the test read,
// a running task, the recent log and live status events.

import 'package:dsh_app/state/compose_inbox.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/phone_state.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_app/ui/phone/action_log_page.dart';
import 'package:dsh_app/ui/phone/dnd_mode_page.dart';
import 'package:dsh_app/ui/phone/phone_control_screen.dart';
import 'package:dsh_app/ui/phone/phone_background_guide.dart';
import 'package:dsh_app/ui/phone/phone_widgets.dart';
import 'package:dsh_app/ui/phone/restricted_settings_guide.dart';
import 'package:dsh_app/ui/settings/background_guide_page.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'harness.dart';
import 'support.dart';

Finder tileWith(String title) => find.ancestor(of: find.text(title), matching: find.byType(ListPageRow)).first;

Finder inTile(String title, Finder inner) => find.descendant(of: tileWith(title), matching: inner);

Switch masterSwitch(WidgetTester tester) => tester.widget<Switch>(find.byType(Switch).first);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('问 AI', () {
    const question = '/dsh-go-guide 手机操控是怎么工作的？有什么风险？';
    String? queued(WidgetTester tester) =>
        ProviderScope.containerOf(tester.element(find.byType(MaterialApp)))
            .read(composeInboxProvider)
            .singleOrNull
            ?.text;

    testWidgets('the bar key asks how phone control works', (tester) async {
      await pumpPhone(tester, const PhoneControlScreen());
      await tester.tap(find.byTooltip('问 AI'));
      await tester.pumpAndSettle();
      expect(queued(tester), question);
    });

    testWidgets('the disclosure offers it, and asking leaves phone control off', (tester) async {
      final h = await pumpPhone(
        tester,
        const PhoneControlScreen(),
        native: FakePhoneNative(status: phoneStatus(enabled: false)),
      );
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(find.text('开启手机操控前'), findsOneWidget);
      await tester.tap(find.text('不确定？问 AI'));
      await tester.pumpAndSettle();
      expect(find.text('开启手机操控前'), findsNothing);
      expect(h.native!.callsOf('setEnabled'), isEmpty);
      expect((await SharedPreferences.getInstance()).getBool(PhoneController.disclosureKey), isNot(true));
      expect(queued(tester), question);
    });
  });

  group('master switch', () {
    testWidgets('first enable goes through the disclosure; 先不开 keeps it off', (tester) async {
      final h = await pumpPhone(
        tester,
        const PhoneControlScreen(),
        native: FakePhoneNative(status: phoneStatus(enabled: false)),
      );
      expect(find.text('未开启'), findsOneWidget);
      expect(find.text('开启后能做什么'), findsOneWidget);
      expect(find.text('准备'), findsNothing);
      expect(find.text('进阶'), findsNothing);

      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(find.text('开启手机操控前'), findsOneWidget);
      for (final t in ['读什么', '什么时候读', '发给谁', '默认不做', '你随时能停']) {
        expect(find.text(t), findsOneWidget);
      }
      await tester.tap(find.text('先不开'));
      await tester.pumpAndSettle();
      expect(h.native!.callsOf('setEnabled'), isEmpty);
      expect(masterSwitch(tester).value, isFalse);

      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('同意并开启'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('phone-background-guide')), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '知道了'));
      await tester.pumpAndSettle();
      expect(h.native!.callsOf('setEnabled').single.arguments, {'enabled': true});
      expect(masterSwitch(tester).value, isTrue);
      expect(h.runtime.stops, 1);
      expect(h.runtime.starts, ['start']);
      expect(find.text('已开启，引擎正在重启'), findsOneWidget);
      expect(find.text('准备'), findsOneWidget);
      expect(find.text('进阶'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(PhoneController.disclosureKey), isTrue);
      expect(prefs.getBool(phoneBackgroundGuideSeenKey), isTrue);

      // Off, then on again: no second disclosure.
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(h.native!.callsOf('setEnabled').last.arguments, {'enabled': false});
      expect(find.text('开启后能做什么'), findsOneWidget);
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(find.text('开启手机操控前'), findsNothing);
      expect(find.byKey(const Key('phone-background-guide')), findsNothing);
      expect(h.native!.callsOf('setEnabled').last.arguments, {'enabled': true});
    });

    testWidgets('a refused switch says so and stays put', (tester) async {
      SharedPreferences.setMockInitialValues({PhoneController.disclosureKey: true});
      final native = FakePhoneNative(status: phoneStatus(enabled: false))..accept = false;
      final h = await pumpPhone(tester, const PhoneControlScreen(), native: native);
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(find.text('开启手机操控前'), findsNothing);
      expect(find.text('没能开启，稍后再试'), findsOneWidget);
      expect(masterSwitch(tester).value, isFalse);
      expect(h.runtime.stops, 0);
    });
  });

  group('blockers', () {
    testWidgets('no native module: 未就绪, switch disabled, nothing else', (tester) async {
      await pumpPhone(tester, const PhoneControlScreen(), missingNative: true);
      expect(find.text('未就绪'), findsWidgets);
      expect(find.textContaining('手机操控模块还没有就绪'), findsOneWidget);
      expect(masterSwitch(tester).onChanged, isNull);
      expect(find.text('应用名单'), findsNothing);
    });

    testWidgets('safe mode: unavailable, can turn off but not on', (tester) async {
      final h = await pumpPhone(
        tester,
        const PhoneControlScreen(),
        engine: safeRuntime,
        native: FakePhoneNative(status: phoneStatus(enabled: false)),
      );
      expect(find.text('安全模式下不可用'), findsOneWidget);
      expect(masterSwitch(tester).onChanged, isNull);

      h.native!.push(phoneStatus(enabled: true));
      await settlePhone(tester);
      expect(find.text('安全模式下不加载'), findsOneWidget);
      expect(masterSwitch(tester).onChanged, isNotNull);
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(h.native!.callsOf('setEnabled').single.arguments, {'enabled': false});
      // Safe mode loads no plugins: no restart needed.
      expect(h.runtime.stops, 0);
      expect(find.text('已关闭'), findsOneWidget);
    });

    testWidgets('remote host: explains it only works on the local engine', (tester) async {
      await pumpPhone(tester, const PhoneControlScreen(), host: const HostRef.ssh('lab'));
      expect(find.text('当前连的是远程主机'), findsOneWidget);
      expect(find.textContaining('「实验室服务器」上的 DSH 操作不了这台手机'), findsOneWidget);
      expect(find.text('只在本机引擎可用'), findsOneWidget);
    });
  });

  group('准备', () {
    testWidgets('accessibility: opens settings, detects on resume, else points at restricted settings', (tester) async {
      final h = await pumpPhone(tester, const PhoneControlScreen());
      expect(find.text('还差一步：打开无障碍'), findsOneWidget);
      // vivo, Android 15, sideloaded: the hint is there from the start.
      expect(find.text('无障碍开关点不动？'), findsOneWidget);
      expect(find.text('侧载安装的 App 要先「允许受限制的设置」'), findsOneWidget);

      await tester.tap(inTile('无障碍服务', find.text('去开启')));
      await tester.pump();
      expect(h.native!.callsOf('openAccessibilitySettings'), hasLength(1));

      // Came back without turning it on.
      await leaveAndResume(tester);
      expect(find.text('看起来没开成。侧载的 App 要先「允许受限制的设置」'), findsOneWidget);

      await tester.tap(inTile('无障碍服务', find.text('去开启')));
      await tester.pump();
      h.native!.status = phoneStatus(a11y: true);
      await leaveAndResume(tester);
      expect(inTile('无障碍服务', find.byType(DoneMark)), findsOneWidget);
      expect(find.text('无障碍开关点不动？'), findsNothing);
      expect(find.text('可以操作手机'), findsOneWidget);
    });

    testWidgets('restricted-settings row leads to the guide for this ROM', (tester) async {
      await pumpPhone(tester, const PhoneControlScreen());
      await tester.tap(find.text('无障碍开关点不动？'));
      await tester.pumpAndSettle();
      expect(find.byType(RestrictedSettingsGuidePage), findsOneWidget);
      final vivo = tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'vivo / iQOO'));
      expect(vivo.selected, isTrue);
    });

    testWidgets('no restricted-settings hint on Android 12 or a store install', (tester) async {
      await pumpPhone(
        tester,
        const PhoneControlScreen(),
        native: FakePhoneNative(
          status: phoneStatus(device: {'manufacturer': 'Xiaomi', 'sdkInt': 32, 'sideloaded': true}),
        ),
      );
      expect(find.text('无障碍开关点不动？'), findsNothing);
    });

    testWidgets('a connected-but-dead service asks to toggle it again', (tester) async {
      await pumpPhone(
        tester,
        const PhoneControlScreen(),
        native: FakePhoneNative(status: phoneStatus(a11y: true, serviceConnected: false)),
      );
      expect(find.text('服务没连上，关掉再打开一次'), findsOneWidget);
      expect(inTile('无障碍服务', find.text('去设置')), findsOneWidget);
    });

    testWidgets('notifications open App info; background opens the keep-alive guide', (tester) async {
      final h = await pumpPhone(
        tester,
        const PhoneControlScreen(),
        native: FakePhoneNative(status: phoneStatus(notifications: false)),
      );
      await tester.tap(inTile('通知', find.text('去开启')));
      await tester.pump();
      expect(h.native!.callsOf('openAppDetails'), hasLength(1));

      h.native!.status = phoneStatus(notifications: true);
      await leaveAndResume(tester);
      expect(inTile('通知', find.text('已允许')), findsOneWidget);

      await tester.tap(find.text('后台运行'));
      await tester.pumpAndSettle();
      expect(find.byType(BackgroundGuidePage), findsOneWidget);
    });
  });

  group('试一下', () {
    testWidgets('reads the screen into a monospace sheet', (tester) async {
      final h = await pumpPhone(
        tester,
        const PhoneControlScreen(),
        native: FakePhoneNative(status: phoneStatus(a11y: true)),
      );
      await tester.tap(find.text('读一下当前屏幕'));
      await tester.pumpAndSettle();
      expect(h.native!.callsOf('testScreen'), hasLength(1));
      expect(find.text('当前屏幕'), findsOneWidget);
      final text = tester.widget<SelectableText>(find.byType(SelectableText));
      expect(text.data, sampleScreenText);
      expect(text.style?.fontFamily, AppType.monoFamily);
      expect(find.textContaining('没有发给模型'), findsOneWidget);
    });

    testWidgets('a failed read shows the reason', (tester) async {
      final native = FakePhoneNative(status: phoneStatus(a11y: true))..screen = {'ok': false, 'reason': '这个页面不允许读取'};
      await pumpPhone(tester, const PhoneControlScreen(), native: native);
      await tester.tap(find.text('读一下当前屏幕'));
      await tester.pumpAndSettle();
      expect(find.text('没能读到屏幕'), findsOneWidget);
      expect(find.text('这个页面不允许读取'), findsOneWidget);
    });

    testWidgets('disabled until accessibility is on', (tester) async {
      final h = await pumpPhone(tester, const PhoneControlScreen());
      expect(find.text('先打开无障碍服务'), findsOneWidget);
      await tester.tap(find.text('读一下当前屏幕'));
      await tester.pumpAndSettle();
      expect(h.native!.callsOf('testScreen'), isEmpty);
    });
  });

  testWidgets('a running task can be stopped from here', (tester) async {
    final h = await pumpPhone(
      tester,
      const PhoneControlScreen(),
      native: FakePhoneNative(status: phoneStatus(a11y: true, taskActive: true, taskApp: '美团')),
    );
    expect(find.text('正在操作「美团」'), findsOneWidget);
    await tester.tap(inTile('正在操作「美团」', find.text('停止')));
    await tester.pump();
    expect(h.native!.callsOf('stopTask'), hasLength(1));

    h.native!.push(phoneStatus(a11y: true));
    await settlePhone(tester);
    expect(find.text('正在操作「美团」'), findsNothing);
  });

  testWidgets('status events update the page live', (tester) async {
    final h = await pumpPhone(tester, const PhoneControlScreen());
    expect(inTile('无障碍服务', find.byType(DoneMark)), findsNothing);
    h.native!.push(phoneStatus(a11y: true));
    await settlePhone(tester);
    expect(inTile('无障碍服务', find.byType(DoneMark)), findsOneWidget);
  });

  group('规则 and 最近操作', () {
    testWidgets('shows the newest three actions and the full log page', (tester) async {
      final h = await pumpPhone(tester, const PhoneControlScreen());
      expect(find.text('4 个不碰 · 1 个每步确认'), findsOneWidget);
      expect(find.text('点「路线」'), findsOneWidget);
      expect(find.text('给 张三 发送：“晚上见”'), findsOneWidget);
      expect(find.text('打开「支付宝」'), findsOneWidget);
      expect(find.text('看屏幕'), findsNothing);
      expect(find.text('已执行'), findsOneWidget);
      expect(find.text('你允许了'), findsOneWidget);
      expect(find.text('已拦下'), findsOneWidget);

      await tester.tap(find.text('全部记录'));
      await tester.pumpAndSettle();
      expect(find.byType(PhoneActionLogPage), findsOneWidget);
      expect(find.byType(ActionLogRow), findsNWidgets(4));
      expect(find.text('看屏幕'), findsOneWidget);
      expect(h.native!.callsOf('actionLog').last.arguments, {'limit': PhoneActionLogPage.limit});
    });

    testWidgets('an empty log says what will appear there', (tester) async {
      await pumpPhone(tester, const PhoneControlScreen(), native: FakePhoneNative(log: const []));
      expect(find.text('还没有记录'), findsOneWidget);
      expect(find.text('全部记录'), findsNothing);
    });

    testWidgets('不打扰模式 row shows its state and opens the page', (tester) async {
      await pumpPhone(
        tester,
        const PhoneControlScreen(),
        native: FakePhoneNative(
          status: phoneStatus(mode: 'shizuku', backgroundReason: 'Shizuku 没有在运行'),
        ),
      );
      expect(find.text('Shizuku · Shizuku 没有在运行'), findsOneWidget);
      await tester.tap(find.text('不打扰模式'));
      await tester.pumpAndSettle();
      expect(find.byType(PhoneDndPage), findsOneWidget);
    });
  });
}
