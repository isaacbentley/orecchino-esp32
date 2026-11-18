// watch_service.dart — "Watch in the background" (Android): the Dart side
// of the native OrecchinoWatchService (android/.../OrecchinoWatchService.kt),
// a foreground service that keeps this app's one Flutter engine running
// with the app closed, so the detector link, the phone's receiver, the
// rules and the alerts carry on. Its notification says what it watches
// ("Orecchino watching · 2 drones · conflict watch on · T5 connected") and
// has Open, Pause 1 h and Stop.
//
// The service is started only while the app is on screen (Android refuses
// most starts from the background), with the types connectedDevice, plus
// location when the location permission is granted; never dataSync.
//
// The same channel carries the CompanionDeviceManager association of a
// pinned detector: once associated, Android lets the app run and start its
// service in the background for that detector, wakes it when the detector
// comes into range (Android 12+), and the app reconnects with a pending
// connect instead of a scan loop (app_controller.dart).
//
// MethodChannel "orecchino/watch":
//   Dart -> native: start {text, location}, update {text}, stop, running,
//     companionSupported, associations, associate {mac, name}
//   native -> Dart: action {action: open | pause | stop | appeared, mac?}
//
// iOS has no such service: CoreBluetooth's bluetooth-central background
// mode keeps the detector link and its alerts going (see mobile/README.md).
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One action from the notification or the companion service.
@immutable
class WatchAction {
  /// open, pause, stop, or appeared (the detector [mac] came into range).
  final String action;
  final String? mac;
  const WatchAction(this.action, [this.mac]);

  @override
  String toString() => mac == null ? action : '$action $mac';
}

abstract class WatchPlatform {
  Future<bool> start(String text, {required bool location});
  Future<void> update(String text);
  Future<void> stop();
  Future<bool> running();
  Future<bool> companionSupported();
  Future<List<String>> associations();
  Future<bool> associate(String mac, String name);
  Stream<WatchAction> get actions;
}

class MethodChannelWatch implements WatchPlatform {
  static const channel = MethodChannel('orecchino/watch');

  final _actions = StreamController<WatchAction>.broadcast();

  MethodChannelWatch() {
    channel.setMethodCallHandler((call) async {
      if (call.method != 'action') return null;
      final a = call.arguments;
      if (a is Map) {
        final action = a['action'];
        if (action is String) _actions.add(WatchAction(action, a['mac'] is String ? a['mac'] as String : null));
      }
      return null;
    });
  }

  @override
  Stream<WatchAction> get actions => _actions.stream;

  @override
  Future<bool> start(String text, {required bool location}) async =>
      await channel.invokeMethod<bool>('start', {'text': text, 'location': location}) ?? false;

  @override
  Future<void> update(String text) => channel.invokeMethod<void>('update', {'text': text});

  @override
  Future<void> stop() => channel.invokeMethod<void>('stop');

  @override
  Future<bool> running() async => await channel.invokeMethod<bool>('running') ?? false;

  @override
  Future<bool> companionSupported() async => await channel.invokeMethod<bool>('companionSupported') ?? false;

  @override
  Future<List<String>> associations() async =>
      [for (final m in await channel.invokeListMethod<Object?>('associations') ?? const []) if (m is String) m];

  @override
  Future<bool> associate(String mac, String name) async =>
      await channel.invokeMethod<bool>('associate', {'mac': mac, 'name': name}) ?? false;
}

class WatchService {
  final WatchPlatform platform;

  /// Android only; elsewhere every call is a no-op.
  final bool supported;

  WatchService({WatchPlatform? platform, bool? supported})
      : platform = platform ?? MethodChannelWatch(),
        supported = supported ?? Platform.isAndroid;

  /// The real one: Android's service, nothing elsewhere.
  factory WatchService.platform() => WatchService(supported: !kIsWeb && Platform.isAndroid);

  bool _running = false;
  String? _text;
  String? _error;

  bool get running => _running;

  /// The notification's words now (null when stopped).
  String? get text => _running ? _text : null;

  /// Why the last start failed, in words.
  String? get error => _error;

  Stream<WatchAction> get actions => supported ? platform.actions : const Stream.empty();

  /// Start the service with its notification; call only while the app is
  /// on screen. Returns whether it runs.
  Future<bool> start(String text, {bool location = false}) async {
    if (!supported) return false;
    if (_running) {
      await update(text);
      return true;
    }
    try {
      _running = await platform.start(text, location: location);
      _text = text;
      _error = _running ? null : 'Android did not start the background service';
    } on PlatformException catch (e) {
      _running = false;
      _error = e.message ?? e.code;
    } on MissingPluginException {
      _running = false;
      _error = 'the background service is not available in this build';
    }
    return _running;
  }

  /// New words for the notification (only when they changed).
  Future<void> update(String text) async {
    if (!supported || !_running || text == _text) return;
    _text = text;
    try {
      await platform.update(text);
    } catch (e) {
      debugPrint('watch update: $e');
    }
  }

  Future<void> stop() async {
    if (!supported || !_running) return;
    _running = false;
    _text = null;
    try {
      await platform.stop();
    } catch (e) {
      debugPrint('watch stop: $e');
    }
  }

  /// The service stopped from its notification ("Stop"): no call back.
  void stoppedByNotification() {
    _running = false;
    _text = null;
  }

  Future<bool> companionSupported() async {
    if (!supported) return false;
    try {
      return await platform.companionSupported();
    } catch (_) {
      return false;
    }
  }

  /// Detector addresses associated with this app (upper case).
  Future<Set<String>> associations() async {
    if (!supported) return const {};
    try {
      return {for (final m in await platform.associations()) m.toUpperCase()};
    } catch (_) {
      return const {};
    }
  }

  /// Ask Android to associate [mac] (a system dialog). Returns whether it
  /// is associated now.
  Future<bool> associate(String mac, String name) async {
    if (!supported) return false;
    try {
      return await platform.associate(mac, name);
    } catch (e) {
      debugPrint('companion associate: $e');
      return false;
    }
  }
}
