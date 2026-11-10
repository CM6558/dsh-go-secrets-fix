import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/ui/settings/background_guide_page.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';

class _BatteryBridge extends RuntimeBridge {
  bool exempt = false;
  int requests = 0;
  @override
  Future<bool?> batteryExempt() async => exempt;
  @override
  Future<bool?> requestBatteryExempt() async {
    requests++;
    return true;
  }
}

class _VendorBridge extends _BatteryBridge {
  _VendorBridge(this.vendor);

  final String? vendor;
  int opened = 0;

  @override
  Future<BackgroundSettingsInfo?> backgroundSettings() async => BackgroundSettingsInfo(vendor: vendor, label: 'DSH');

  @override
  Future<String?> openBackgroundSettings() async {
    opened++;
    return 'vendor';
  }
}

const _makers = [
  'vivo / iQOO（OriginOS）',
  '小米 / Redmi（HyperOS、MIUI）',
  '华为 / 荣耀（HarmonyOS、MagicOS）',
  'OPPO / 一加 / realme（ColorOS）',
  '三星（One UI）',
];

void main() {
  // vivo: its own switch on top.
  goldenBoth(
    'background_guide_vivo',
    () => const BackgroundGuidePage(),
    overrides: () => [runtimeBridgeProvider.overrideWithValue(_VendorBridge('vivo'))],
  );

  testWidgets('this phone\'s maker first: its switch opens in one tap, the others below', (tester) async {
    final bridge = _VendorBridge('vivo');
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: const BackgroundGuidePage(),
        brightness: Brightness.light,
        overrides: [runtimeBridgeProvider.overrideWithValue(bridge)],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('vivo / iQOO'), findsOneWidget);
    expect(find.text('电池 › 后台耗电管理 › DSH'), findsOneWidget);
    expect(tester.getRect(find.text('允许后台高耗电')).top, lessThan(tester.getRect(find.text('系统电池优化')).top));
    expect(find.text('其他品牌'), findsOneWidget);
    expect(find.text(_makers.first), findsNothing);
    for (final maker in _makers.skip(1)) {
      expect(find.text(maker), findsOneWidget);
    }
    await tester.tap(find.text('允许后台高耗电'));
    await tester.pumpAndSettle();
    expect(bridge.opened, 1);
  });

  testWidgets('honor shares Huawei\'s row title and is left out below', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: const BackgroundGuidePage(),
        brightness: Brightness.light,
        overrides: [runtimeBridgeProvider.overrideWithValue(_VendorBridge('honor'))],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('荣耀'), findsOneWidget);
    expect(find.text('允许后台活动'), findsOneWidget);
    expect(find.text('华为 / 荣耀（HarmonyOS、MagicOS）'), findsNothing);
  });

  testWidgets('other phones: no maker row, every maker listed', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: const BackgroundGuidePage(),
        brightness: Brightness.light,
        overrides: [runtimeBridgeProvider.overrideWithValue(_VendorBridge(null))],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('各品牌'), findsOneWidget);
    for (final maker in _makers) {
      expect(find.text(maker), findsOneWidget);
    }
  });

  testWidgets('request once, resume refreshes exemption and disables row', (tester) async {
    final bridge = _BatteryBridge();
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: const BackgroundGuidePage(),
        brightness: Brightness.light,
        overrides: [runtimeBridgeProvider.overrideWithValue(bridge)],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('未关闭'), findsOneWidget);
    await tester.tap(find.text('系统电池优化'));
    await tester.pumpAndSettle();
    expect(bridge.requests, 1);
    // Back from the system dialog.
    bridge.exempt = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('已关闭'), findsOneWidget);
    final tile = tester.widget<SettingsTile>(find.widgetWithText(SettingsTile, '系统电池优化'));
    expect(tile.onTap, isNull);
    await tester.tap(find.text('系统电池优化'));
    expect(bridge.requests, 1);
  });

  testWidgets('unsupported platform hides system battery row', (tester) async {
    await tester.pumpWidget(
      goldenApp(
        home: const BackgroundGuidePage(),
        brightness: Brightness.dark,
        overrides: [batteryExemptProvider.overrideWith((ref) async => null)],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('系统电池优化'), findsNothing);
  });
}
