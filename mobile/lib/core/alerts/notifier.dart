// notifier.dart — how an alert reaches the person (plan §8.4): a local
// notification (time-sensitive for warnings on iOS; the "Traffic near
// drones" high-importance channel on Android) with Show / Mute 10 min, a
// haptic pattern (three short pulses for traffic, one for drone alerts), an
// optional spoken callout, and on Android an ongoing notification for the
// active warning (updated at most every 5 s). The detector connection has
// no notification of its own: Android's "Watch in the background" service
// says "T5 connected" in its notification (core/background/watch_service.dart).
//
// The Live Activity / Dynamic Island needs a native widget extension; see
// mobile/README.md ("Follow-ups").
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../traffic/traffic_rules.dart';
import 'alert_policy.dart';

/// What the app controller needs; a fake stands in for it in tests.
abstract class AlertSink {
  Future<void> init({required void Function(String action, String? payload) onAction});
  Future<void> notify(AlertEvent e);
  Future<void> ongoing(AlertEvent? e);
  Future<void> haptic(AlertSource source);
  Future<void> speak(String text);
}

class SilentAlertSink implements AlertSink {
  @override
  Future<void> init({required void Function(String action, String? payload) onAction}) async {}
  @override
  Future<void> notify(AlertEvent e) async {}
  @override
  Future<void> ongoing(AlertEvent? e) async {}
  @override
  Future<void> haptic(AlertSource source) async {}
  @override
  Future<void> speak(String text) async {}
}

class SystemAlertSink implements AlertSink {
  static const actionShow = 'show';
  static const actionMute = 'mute';
  static const _category = 'orecchino_alert';
  static const _chanTraffic = 'traffic_near_drones';
  static const _chanDrone = 'drone_alerts';
  static const _chanOngoing = 'traffic_ongoing';
  static const _idOngoing = 1;

  final _plugin = FlutterLocalNotificationsPlugin();
  FlutterTts? _tts;
  int _nextId = 100;
  int _lastOngoingMs = 0;
  String? _lastOngoingKey;
  bool _ready = false;

  bool get _android => Platform.isAndroid;
  bool get _ios => Platform.isIOS;

  @override
  Future<void> init({required void Function(String action, String? payload) onAction}) async {
    if (!(_android || _ios)) return;
    final darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
      notificationCategories: [
        DarwinNotificationCategory(_category, actions: [
          DarwinNotificationAction.plain(actionShow, 'Show',
              options: {DarwinNotificationActionOption.foreground}),
          DarwinNotificationAction.plain(actionMute, 'Mute 10 min',
              options: {DarwinNotificationActionOption.foreground}),
        ]),
      ],
    );
    try {
      await _plugin.initialize(
        settings: InitializationSettings(
          android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: darwin,
        ),
        onDidReceiveNotificationResponse: (r) =>
            onAction(r.actionId?.isNotEmpty == true ? r.actionId! : actionShow, r.payload),
      );
      if (_android) {
        final a = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
        await a?.requestNotificationsPermission();
      } else {
        final i = _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
        await i?.requestPermissions(alert: true, sound: true, badge: false);
      }
      _ready = true;
    } catch (e) {
      debugPrint('notifications unavailable: $e');
    }
  }

  NotificationDetails _details(AlertEvent e, {bool ongoing = false}) {
    final warning = e.level == TrafficLevel.warning;
    final chan = ongoing ? _chanOngoing : (e.source == AlertSource.traffic ? _chanTraffic : _chanDrone);
    final chanName = ongoing
        ? 'Active traffic warning'
        : (e.source == AlertSource.traffic ? 'Traffic near drones' : 'Drone alerts');
    return NotificationDetails(
      android: AndroidNotificationDetails(
        chan,
        chanName,
        importance: ongoing ? Importance.low : Importance.high,
        priority: ongoing ? Priority.low : Priority.high,
        ongoing: ongoing,
        onlyAlertOnce: ongoing,
        autoCancel: !ongoing,
        category: AndroidNotificationCategory.status,
        styleInformation: BigTextStyleInformation(e.body),
        actions: ongoing
            ? null
            : const [
                AndroidNotificationAction(actionShow, 'Show', showsUserInterface: true),
                AndroidNotificationAction(actionMute, 'Mute 10 min', showsUserInterface: true),
              ],
      ),
      iOS: DarwinNotificationDetails(
        categoryIdentifier: _category,
        interruptionLevel: warning ? InterruptionLevel.timeSensitive : InterruptionLevel.active,
        threadIdentifier: e.source.name,
      ),
    );
  }

  @override
  Future<void> notify(AlertEvent e) async {
    if (!_ready) return;
    try {
      await _plugin.show(id: _nextId++, title: e.title, body: e.body, notificationDetails: _details(e), payload: e.id);
    } catch (err) {
      debugPrint('notify failed: $err');
    }
  }

  @override
  Future<void> ongoing(AlertEvent? e) async {
    if (!_ready || !_android) return;
    try {
      if (e == null) {
        if (_lastOngoingKey != null) await _plugin.cancel(id: _idOngoing);
        _lastOngoingKey = null;
        return;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final key = '${e.title}|${e.body}';
      if (key == _lastOngoingKey || now - _lastOngoingMs < 5000) return; // at most every 5 s
      _lastOngoingMs = now;
      _lastOngoingKey = key;
      await _plugin.show(id: _idOngoing, title: e.title, body: e.body, notificationDetails: _details(e, ongoing: true), payload: e.id);
    } catch (err) {
      debugPrint('ongoing failed: $err');
    }
  }

  @override
  Future<void> haptic(AlertSource source) async {
    if (source == AlertSource.traffic) {
      for (var i = 0; i < 3; i++) {
        await HapticFeedback.heavyImpact();
        await Future<void>.delayed(const Duration(milliseconds: 140));
      }
    } else {
      await HapticFeedback.vibrate();
    }
  }

  @override
  Future<void> speak(String text) async {
    try {
      final tts = _tts ??= FlutterTts();
      if (_ios) {
        await tts.setIosAudioCategory(IosTextToSpeechAudioCategory.playback, [
          IosTextToSpeechAudioCategoryOptions.duckOthers,
        ]);
      }
      await tts.speak(text);
    } catch (e) {
      debugPrint('speech failed: $e');
    }
  }
}
