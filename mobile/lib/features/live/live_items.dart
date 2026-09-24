// live_items.dart — what the Live, Find and History screens show about each
// contact: drones from the tracker, aircraft from the ADS-B set, with their
// alerts and the words a screen reader says for them. Distances in m / km;
// missing data is blank, never zero.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import '../../app/app_controller.dart';
import '../../core/geo.dart';
import '../../core/live/contact_tracker.dart';
import '../../core/traffic/traffic_rules.dart';

class LiveContactItem {
  final String id;
  final String label;
  final String? sublabel;
  final double? distanceM; // from the phone; null when unknown
  final double? bearingDeg;
  final double? heightM;
  final String? heightRef; // 'above T/O' | 'AGL' | 'ft' (aircraft) | null
  final double? speedMps;
  final double? trackDeg;
  final bool isAircraft;
  final bool? closing; // null: unknown
  final double? rangeRateMps;
  final double ageSeconds;
  final bool stale;
  final List<String> alertWords;
  final TrafficLevel alertLevel;
  final TrafficAlert? alert; // the most urgent traffic alert naming it
  final TrafficAircraft? aircraft;
  final List<(double, double)> ghost;

  /// Last RSSI heard (drones), dBm.
  final int? rssi;

  /// Where it was heard from: BLE, WIFI (drones), ADS-B (aircraft).
  final List<String> sources;

  const LiveContactItem({
    required this.id,
    required this.label,
    this.sublabel,
    this.distanceM,
    this.bearingDeg,
    this.heightM,
    this.heightRef,
    this.speedMps,
    this.trackDeg,
    required this.isAircraft,
    this.closing,
    this.rangeRateMps,
    required this.ageSeconds,
    this.stale = false,
    this.alertWords = const [],
    this.alertLevel = TrafficLevel.none,
    this.alert,
    this.aircraft,
    this.ghost = const [],
    this.rssi,
    this.sources = const [],
  });

  bool get isClosing => closing == true;

  /// Height in metres (aircraft keep feet in [heightM], as they are shown).
  double? get heightMetres => heightM == null ? null : (isAircraft ? heightM! * TrafficRules.ftToM : heightM);

  /// The level to draw it in: its alert, else none.
  bool get alerting => alertLevel != TrafficLevel.none || alertWords.isNotEmpty;

  /// '350 m', or 'range unknown'.
  String get rangeText => distanceM == null ? 'range unknown' : Geo.rangeText(distanceM!);

  /// 'closing 4.2 m/s', 'opening', or null when unknown.
  String? get trendText {
    if (closing == true) return 'closing ${rangeRateMps!.abs().toStringAsFixed(1)} m/s';
    if (closing == false) return 'opening';
    return null;
  }

  String? get heightText {
    if (heightM == null) return null;
    if (isAircraft) return '${_thousands(heightM!.round())} ft';
    return '${heightM!.round()} m${heightRef == null ? '' : ' $heightRef'}';
  }

  /// What a screen reader says for the mark and the row (the same words).
  String semantics({double? headingDeg}) {
    final parts = <String>[
      isAircraft ? 'Aircraft $label' : 'Drone $label',
      ...alertWords,
      if (alert != null) alert!.text,
      rangeText,
      if (bearingDeg != null)
        headingDeg != null ? Geo.clockWords(bearingDeg!, headingDeg) : 'bearing ${bearingDeg!.round()} degrees',
      if (heightText != null) heightText!,
      if (trendText != null) trendText!,
      stale ? 'stale, heard ${ageSeconds.round()} seconds ago' : 'heard ${ageSeconds.round()} seconds ago',
    ];
    return parts.join(', ');
  }
}

String _thousands(int v) {
  final s = v.abs().toString();
  final b = StringBuffer(v < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

/// Live items for the screens: drones from the tracker, aircraft from the
/// ADS-B set, with their alerts.
List<LiveContactItem> buildLiveItems(AppController app) {
  final now = app.nowMs();
  final o = app.observer;
  final result = app.traffic.result;
  final items = <LiveContactItem>[];

  TrafficAlert? droneAlert(String key) {
    for (final a in result.alerts) {
      if (a.droneId == key) return a;
    }
    return null;
  }

  for (final Contact c in app.tracker.contacts) {
    final words = <String>[
      if (c.emergency) 'EMERGENCY REPORTED',
      if (c.isAuthInvalid) 'ID SIGNATURE INVALID',
      if (c.authState == 'test_key') 'TEST KEY',
    ];
    final ta = droneAlert(c.key);
    final level = c.emergency
        ? TrafficLevel.warning
        : (ta?.level ?? (c.isAuthInvalid ? TrafficLevel.caution : TrafficLevel.none));
    items.add(LiveContactItem(
      id: c.key,
      label: TrafficRules.droneLabel(c.label),
      sublabel: c.sources.map((s) => s.toUpperCase()).join('+'),
      distanceM: c.rangeM,
      bearingDeg: c.bearingDeg,
      heightM: c.heightM,
      heightRef: c.heightRefShort,
      speedMps: c.speedMps,
      trackDeg: c.headingDeg,
      isAircraft: false,
      closing: c.closing,
      rangeRateMps: c.rangeRateMps,
      ageSeconds: c.ageS(now),
      stale: ContactTracker.isStale(c, now),
      alertWords: words,
      alertLevel: level,
      alert: ta,
      rssi: c.rssi,
      sources: [for (final s in c.sources) s.toUpperCase()],
    ));
  }

  for (final a in app.traffic.aircraft) {
    final age = a.ageS(now);
    if (age > TrafficRules.presentS) continue;
    final al = result.alertForHex(a.hex);
    double? dist, brg;
    final ghost = <(double, double)>[];
    if (o != null) {
      dist = Geo.distanceM(o.lat, o.lon, a.lat, a.lon);
      brg = Geo.bearingDeg(o.lat, o.lon, a.lat, a.lon);
      if (a.gsMps != null && a.trackDeg != null) {
        for (final t in const [15, 30, 45, 60]) {
          final d = a.gsMps! * t;
          final r = a.trackDeg! * math.pi / 180;
          final lat = a.lat + d * math.cos(r) / 111320.0;
          final lon = a.lon + d * math.sin(r) / (111320.0 * math.cos(a.lat * math.pi / 180));
          ghost.add((Geo.distanceM(o.lat, o.lon, lat, lon), Geo.bearingDeg(o.lat, o.lon, lat, lon)));
        }
      }
    }
    final ft = a.altBaroM ?? a.altGeomM;
    items.add(LiveContactItem(
      id: 'ac:${a.hex}',
      label: a.name,
      sublabel: a.type.isEmpty ? 'ADS-B' : 'ADS-B ${a.type}',
      distanceM: dist,
      bearingDeg: brg,
      heightM: ft == null ? null : ft / TrafficRules.ftToM,
      heightRef: 'ft',
      speedMps: a.gsMps,
      trackDeg: a.trackDeg,
      isAircraft: true,
      ageSeconds: age,
      stale: age >= TrafficRules.freshS,
      alertWords: [if (a.squawk == 7700 || a.squawk == 7600 || a.squawk == 7500 || a.emergency) 'EMERGENCY SQUAWK'],
      alertLevel: al?.level ?? TrafficLevel.none,
      alert: al,
      aircraft: a,
      ghost: ghost,
      sources: const ['ADS-B'],
    ));
  }
  return items;
}

/// A short history per contact for the cards' sparklines: the RSSI heard
/// (drones) or the reported altitude in feet (aircraft), at most one sample
/// a second, the last [capacity]. Kept per app, so it survives tab changes.
class ContactHistory {
  static final Expando<ContactHistory> _of = Expando<ContactHistory>();

  /// The history kept for [owner] (the app controller).
  static ContactHistory of(Object owner) => _of[owner] ??= ContactHistory();

  static const int capacity = 60;

  /// A contact missing from the items (a skipped ADS-B fetch, say) keeps
  /// its series this long before it is forgotten.
  static const int keepMs = 60000;
  final Map<String, List<double>> _series = {};
  final Map<String, int> _lastMs = {};
  final Map<String, int> _seenMs = {};

  void record(List<LiveContactItem> items, int nowMs) {
    final ids = <String>{};
    for (final c in items) {
      ids.add(c.id);
      _seenMs[c.id] = nowMs;
      final v = c.isAircraft ? c.heightM : c.rssi?.toDouble();
      if (v == null) continue;
      final last = _lastMs[c.id];
      if (last != null && nowMs - last < 900) continue;
      _lastMs[c.id] = nowMs;
      final s = _series.putIfAbsent(c.id, () => <double>[]);
      s.add(v);
      if (s.length > capacity) s.removeRange(0, s.length - capacity);
    }
    bool gone(String k) => !ids.contains(k) && nowMs - (_seenMs[k] ?? 0) > keepMs;
    _series.removeWhere((k, _) => gone(k));
    _lastMs.removeWhere((k, _) => gone(k));
    _seenMs.removeWhere((k, _) => gone(k));
  }

  List<double> series(String id) => List.unmodifiable(_series[id] ?? const <double>[]);
}
