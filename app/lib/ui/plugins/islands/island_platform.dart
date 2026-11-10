import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The phone, as the island budget sees it (§7).
@immutable
class IslandDevice {
  const IslandDevice({required this.totalMem, this.availMem = 0, this.lowRam = false, this.webView});

  /// Unknown: assume the smallest tier.
  static const unknown = IslandDevice(totalMem: 0);

  /// `ActivityManager.MemoryInfo.totalMem`, bytes.
  final int totalMem;
  final int availMem;

  /// `ActivityManager.isLowRamDevice()`.
  final bool lowRam;

  /// The WebView provider's package and version, for diagnostics.
  final String? webView;

  static IslandDevice fromJson(Object? json) {
    if (json is! Map) return unknown;
    int n(Object? v) => v is int ? v : 0;
    return IslandDevice(
      totalMem: n(json['totalMem']),
      availMem: n(json['availMem']),
      lowRam: json['lowRam'] == true,
      webView: json['webView'] is String ? json['webView'] as String : null,
    );
  }
}

/// Something the platform tells the island runtime.
@immutable
sealed class IslandPlatformEvent {
  const IslandPlatformEvent();
}

/// A WebView's renderer is gone (crashed or killed for memory). Every WebView
/// of the app shares that renderer: every island is gone with it.
final class IslandRendererGone extends IslandPlatformEvent {
  const IslandRendererGone({required this.webViewId, required this.crashed});
  final int webViewId;
  final bool crashed;
}

/// `ComponentCallbacks2.onTrimMemory`.
final class IslandTrimMemory extends IslandPlatformEvent {
  const IslandTrimMemory(this.level);
  final int level;

  /// `TRIM_MEMORY_RUNNING_LOW` (10) and up: the budget drops every island
  /// that isn't on screen.
  bool get low => level >= 10;
}

/// The Android side of the islands (`islands/IslandsPlugin.kt`): what
/// webview_flutter doesn't do. Every call is best effort and never throws.
abstract class IslandPlatform {
  static IslandPlatform instance = MethodChannelIslandPlatform();

  Future<IslandDevice> device();

  /// Takes over the WebView behind [webViewId] (webview_flutter's
  /// `AndroidWebViewController.webViewIdentifier`): follows [dark] for
  /// `prefers-color-scheme`, zooms text to [textZoom] percent and survives
  /// a renderer crash instead of taking the app down. False when there's no
  /// such WebView (or not on Android).
  Future<bool> attach(int webViewId, {required bool dark, required int textZoom});

  Future<void> setDark(int webViewId, bool dark);
  Future<void> setTextZoom(int webViewId, int percent);

  /// `WebView.onPause()` / `onResume()`: the page stops animating while the
  /// app is in the background.
  Future<void> pause(int webViewId);
  Future<void> resume(int webViewId);

  /// `WebView.destroy()`; call only once no WebViewWidget shows it.
  Future<void> destroy(int webViewId);

  /// The app process's PSS, kB (diagnostics and the PoC).
  Future<int?> appPss();

  Stream<IslandPlatformEvent> get events;
}

class MethodChannelIslandPlatform extends IslandPlatform {
  MethodChannelIslandPlatform([MethodChannel? channel]) : _channel = channel ?? const MethodChannel('dsh/islands');

  final MethodChannel _channel;
  final _events = StreamController<IslandPlatformEvent>.broadcast();
  bool _listening = false;

  /// Lazily: the binding has to be up before a handler can be set.
  void _listen() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler(_onCall);
  }

  Future<dynamic> _onCall(MethodCall call) async {
    final args = call.arguments;
    switch (call.method) {
      case 'rendererGone':
        if (args is Map && args['id'] is int) {
          _events.add(IslandRendererGone(webViewId: args['id'] as int, crashed: args['crashed'] == true));
        }
      case 'trimMemory':
        if (args is Map && args['level'] is int) _events.add(IslandTrimMemory(args['level'] as int));
    }
    return null;
  }

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    if (defaultTargetPlatform != TargetPlatform.android || kIsWeb) return null;
    _listen();
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<IslandDevice> device() async => IslandDevice.fromJson(await _call<Object>('device'));

  @override
  Future<bool> attach(int webViewId, {required bool dark, required int textZoom}) async =>
      await _call<bool>('attach', {'id': webViewId, 'dark': dark, 'textZoom': textZoom}) ?? false;

  @override
  Future<void> setDark(int webViewId, bool dark) => _call<void>('setDark', {'id': webViewId, 'dark': dark});

  @override
  Future<void> setTextZoom(int webViewId, int percent) =>
      _call<void>('setTextZoom', {'id': webViewId, 'zoom': percent});

  @override
  Future<void> pause(int webViewId) => _call<void>('pause', {'id': webViewId});

  @override
  Future<void> resume(int webViewId) => _call<void>('resume', {'id': webViewId});

  @override
  Future<void> destroy(int webViewId) => _call<void>('destroy', {'id': webViewId});

  @override
  Future<int?> appPss() => _call<int>('appPss');

  @override
  Stream<IslandPlatformEvent> get events {
    if (defaultTargetPlatform == TargetPlatform.android && !kIsWeb) _listen();
    return _events.stream;
  }
}
