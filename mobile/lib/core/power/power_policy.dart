// power_policy.dart — how hard the app works, from the power mode the
// person picked (Full / Balanced / Saver, Detectors > Settings), whether the
// app is in the foreground, and which tab is on screen. One pure function
// ([PowerPolicy.of]) so every part of the app (the ambient clock, the glass,
// the compass, location, the phone's scan, Wi-Fi Remote ID, ADS-B) follows
// the same table, and the tests can check it:
//
//                     Full               Balanced (default)          Saver
//   animation         30 Hz, live blur   24 Hz aurora at 1/4 res,    static sky, tint
//                                        grouped blur                instead of blur
//   phone BLE, fg     low latency,       low latency on Live/Find,   balanced on Live/
//                     coded PHY          else balanced               Find only
//   phone BLE, bg     balanced           low power (balanced for     off
//   (Android)                            2 min after a drone)
//   Wi-Fi beacon/NAN  30 s / on          60 s fg, 120 s bg /         off
//                                        NAN on Live/Find only
//   ADS-B             10 s               10 s with drones or a       30 s with drones
//                                        traffic detector, else 60 s only
//   detector feed     full               full (a background digest   full (the same)
//                                        needs the firmware)
//   location          high               high on Live/Find, else     medium; kept last
//                                        medium                      fix in background
//   compass           15 Hz Live/Find    10 Hz on Live/Find          Find only, 10 Hz
//
// Background on iOS: the phone's own receiver stops (iOS will not deliver
// Remote ID adverts to a background scan); the detector link, the rules and
// the alerts continue while Bluetooth keeps the app awake.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/foundation.dart';

enum PowerMode {
  full('Full'),
  balanced('Balanced'),
  saver('Saver');

  final String label;
  const PowerMode(this.label);

  static PowerMode parse(String? s) => values.where((m) => m.name == s).firstOrNull ?? PowerMode.balanced;
}

/// The screens the policy cares about (the tab bar's order).
enum AppTab { live, find, history, detectors }

/// The phone's Bluetooth scan duty, from off to low latency.
enum ScanDuty { off, lowPower, balanced, lowLatency }

enum GlassMode { live, grouped, tint }

enum LocationPrecision { off, medium, high }

@immutable
class PowerPolicy {
  final PowerMode mode;
  final bool foreground;
  final AppTab tab;
  final bool isIOS;

  /// Ambient motion (the aurora, the sweep, the glows): frames a second;
  /// 0 = still.
  final int ambientHz;

  /// The aurora's render scale (1/4 = a quarter of the pixels each way).
  final double auroraScale;
  final GlassMode glass;

  /// The phone's own Bluetooth Remote ID scan.
  final ScanDuty phoneScan;

  /// Look for long-range (coded PHY) adverts too.
  final bool codedPhy;

  /// Wi-Fi beacon scan interval (null: off) and NAN (Android only).
  final Duration? beaconEvery;
  final bool nan;

  /// ADS-B polling, fast (with drones or a traffic detector) and slow
  /// (otherwise; null = none).
  final Duration adsbFast;
  final Duration? adsbSlow;

  final LocationPrecision location;

  /// Compass samples a second (0 = off).
  final int compassHz;

  const PowerPolicy._({
    required this.mode,
    required this.foreground,
    required this.tab,
    required this.isIOS,
    required this.ambientHz,
    required this.auroraScale,
    required this.glass,
    required this.phoneScan,
    required this.codedPhy,
    required this.beaconEvery,
    required this.nan,
    required this.adsbFast,
    required this.adsbSlow,
    required this.location,
    required this.compassHz,
  });

  bool get skyTab => tab == AppTab.live || tab == AppTab.find;

  /// A drone was heard in the last 2 minutes (Balanced raises the
  /// background scan while drones are about).
  static const droneRecent = Duration(minutes: 2);

  factory PowerPolicy.of({
    required PowerMode mode,
    required bool foreground,
    required AppTab tab,
    bool isIOS = false,
    bool reduceMotion = false,
    bool droneRecentlyHeard = false,
    bool paused = false,
  }) {
    final sky = tab == AppTab.live || tab == AppTab.find;
    final fg = foreground;
    // "Pause 1 h" from the background notification: the phone's own
    // receiver and the position rest until the app is opened or the hour
    // is up (the detector link stays).
    final rest = paused && !fg;
    int ambient = switch (mode) { PowerMode.full => 30, PowerMode.balanced => 24, PowerMode.saver => 0 };
    if (reduceMotion || !fg) ambient = 0;
    final glass = switch (mode) {
      PowerMode.full => GlassMode.live,
      PowerMode.balanced => GlassMode.grouped,
      PowerMode.saver => GlassMode.tint,
    };
    ScanDuty scan;
    if (fg) {
      scan = switch (mode) {
        PowerMode.full => ScanDuty.lowLatency,
        PowerMode.balanced => sky ? ScanDuty.lowLatency : ScanDuty.balanced,
        PowerMode.saver => sky ? ScanDuty.balanced : ScanDuty.off,
      };
    } else if (isIOS || rest) {
      scan = ScanDuty.off; // iOS delivers no Remote ID adverts to a background scan
    } else {
      scan = switch (mode) {
        PowerMode.full => ScanDuty.balanced,
        PowerMode.balanced => droneRecentlyHeard ? ScanDuty.balanced : ScanDuty.lowPower,
        PowerMode.saver => ScanDuty.off,
      };
    }
    final Duration? beacon = switch (mode) {
      PowerMode.full => const Duration(seconds: 30),
      PowerMode.balanced => fg ? const Duration(seconds: 60) : const Duration(minutes: 2),
      PowerMode.saver => null,
    };
    final nan = switch (mode) { PowerMode.full => true, PowerMode.balanced => fg && sky, PowerMode.saver => false };
    final loc = switch (mode) {
      PowerMode.full => LocationPrecision.high,
      PowerMode.balanced => fg && sky ? LocationPrecision.high : LocationPrecision.medium,
      PowerMode.saver => fg ? LocationPrecision.medium : LocationPrecision.off,
    };
    int compass = switch (mode) {
      PowerMode.full => sky ? 15 : 0,
      PowerMode.balanced => sky ? 10 : 0,
      PowerMode.saver => tab == AppTab.find ? 10 : 0,
    };
    if (!fg) compass = 0;
    return PowerPolicy._(
      mode: mode,
      foreground: fg,
      tab: tab,
      isIOS: isIOS,
      ambientHz: ambient,
      auroraScale: mode == PowerMode.full ? 0.5 : 0.25,
      glass: glass,
      phoneScan: scan,
      codedPhy: mode == PowerMode.full,
      beaconEvery: isIOS || rest ? null : beacon,
      nan: !isIOS && !rest && nan,
      adsbFast: switch (mode) {
        PowerMode.full => const Duration(seconds: 10),
        PowerMode.balanced => const Duration(seconds: 10),
        PowerMode.saver => const Duration(seconds: 30),
      },
      adsbSlow: switch (mode) {
        PowerMode.full => const Duration(seconds: 10),
        PowerMode.balanced => const Duration(seconds: 60),
        PowerMode.saver => null,
      },
      location: rest ? LocationPrecision.off : loc,
      compassHz: compass,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PowerPolicy &&
      other.mode == mode &&
      other.foreground == foreground &&
      other.tab == tab &&
      other.ambientHz == ambientHz &&
      other.phoneScan == phoneScan &&
      other.beaconEvery == beaconEvery &&
      other.nan == nan &&
      other.location == location &&
      other.compassHz == compassHz;

  @override
  int get hashCode => Object.hash(mode, foreground, tab, ambientHz, phoneScan, beaconEvery, nan,
      location, compassHz);

  @override
  String toString() => 'PowerPolicy(${mode.name}, ${foreground ? 'fg' : 'bg'} ${tab.name}: ambient $ambientHz Hz, '
      'scan ${phoneScan.name}, beacon ${beaconEvery?.inSeconds}, nan $nan, location ${location.name}, '
      'compass $compassHz Hz)';
}

/// When to ask adsb.lol next (null: not until something changes).
/// [failures]: consecutive failed fetches (backoff 10, 20, 40 s ... up to
/// 5 minutes, never sooner than the usual interval, and none where the
/// policy asks for none); without a position there is nothing to ask.
Duration? adsbNextDelay({
  required PowerPolicy policy,
  required bool enabled,
  required bool hasPosition,
  required bool liveDrones,
  required bool trafficDetector,
  int failures = 0,
}) {
  if (!enabled || !hasPosition) return null;
  final usual = liveDrones || trafficDetector ? policy.adsbFast : policy.adsbSlow;
  if (usual == null || failures <= 0) return usual;
  final s = 10 * (1 << (failures - 1).clamp(0, 5));
  final backoff = Duration(seconds: s.clamp(10, 300));
  return backoff > usual ? backoff : usual;
}
