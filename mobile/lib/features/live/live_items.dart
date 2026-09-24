// live_items.dart — what the Live and Find screens show about each contact:
// the drones from the tracker, with their alerts, and the words a screen
// reader says for them. Remote ID first: an aircraft from the ADS-B set is
// an item only while an alert names it (a drone pair, or low traffic), and
// never a count, a row or an announcement otherwise. Distances in m / km;
// missing data is blank, never zero.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import '../../app/app_controller.dart';
import '../../core/geo.dart';
import '../../core/live/contact_tracker.dart';
import '../../core/live/sensors.dart';
import '../../core/traffic/traffic_rules.dart';
import '../../ui/traffic_widgets.dart';

class LiveContactItem {
  final String id;
  final String label;
  final String? sublabel;
  final double? lat, lon; // as reported (the map); null when unknown
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

  /// A drone's sensors: this phone's paths and each detector's transports
  /// heard in the last minute (sensors.dart).
  final List<SensorChip> sensors;

  /// A drone's operator (from its System message): [ofDrone] is the drone's
  /// id, [ofDroneLabel] its short label; [fromDroneM] / [fromDroneBearing]
  /// where the operator is from the drone.
  final bool isOperator;
  final String? ofDrone;
  final String? ofDroneLabel;
  final double? fromDroneM;
  final double? fromDroneBearing;

  /// For a drone: its operator's distance from it and from you, when known.
  final double? operatorFromDroneM;
  final double? operatorFromYouM;

  const LiveContactItem({
    required this.id,
    required this.label,
    this.sublabel,
    this.lat,
    this.lon,
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
    this.sensors = const [],
    this.isOperator = false,
    this.ofDrone,
    this.ofDroneLabel,
    this.fromDroneM,
    this.fromDroneBearing,
    this.operatorFromDroneM,
    this.operatorFromYouM,
  });

  bool get isDrone => !isAircraft && !isOperator;

  /// 'Drone', 'Aircraft', 'Operator'
  String get kindWord => isAircraft ? 'Aircraft' : (isOperator ? 'Operator' : 'Drone');

  /// 'Operator 420 m from drone · 1.2 km from you' (a drone's operator line).
  String? get operatorLine {
    final d = operatorFromDroneM, y = operatorFromYouM;
    if (d == null && y == null) return null;
    return [
      if (d != null) 'Operator ${Geo.rangeText(d)} from drone' else 'Operator',
      if (y != null) '${Geo.rangeText(y)} from you',
    ].join(' · ');
  }

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

  /// What a screen reader says for the mark and the row (the same words):
  /// its alert's action first, then the geometry and the rule's words.
  String semantics({double? headingDeg}) {
    if (isOperator) {
      return [
        'Operator of drone $ofDroneLabel',
        if (fromDroneM != null && fromDroneBearing != null)
          '${Geo.rangeText(fromDroneM!)} ${TrafficRules.compass8(fromDroneBearing!)} of the drone',
        '$rangeText from you',
        if (bearingDeg != null)
          headingDeg != null ? Geo.clockWords(bearingDeg!, headingDeg) : 'bearing ${bearingDeg!.round()} degrees',
        'as reported ${ageSeconds.round()} seconds ago',
      ].join(', ');
    }
    final al = alert;
    final parts = <String>[
      isAircraft ? 'Aircraft $label' : 'Drone $label',
      ...alertWords,
      if (al != null) ...[
        trafficAction(al),
        if (trafficGeometry(al).isNotEmpty) trafficGeometry(al),
        al.text,
      ],
      isAircraft ? '$rangeText from you' : rangeText,
      if (bearingDeg != null)
        headingDeg != null ? Geo.clockWords(bearingDeg!, headingDeg) : 'bearing ${bearingDeg!.round()} degrees',
      if (heightText != null) heightText!,
      if (trendText != null) trendText!,
      if (operatorLine != null) operatorLine!,
      if (sensorWords(sensors) != null) sensorWords(sensors)!,
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

/// '📱BLE4 · T5 Wi-Fi': the fresh sensors, compact (null: none fresh).
String? _sensorLine(List<SensorChip> s) {
  final f = [for (final c in s) if (c.fresh) c.compact];
  return f.isEmpty ? null : f.join(' · ');
}

final Expando<(Object, int, List<LiveContactItem>)> _itemsCache = Expando('live items');

/// Live items for the screens: the drones from the tracker, with their
/// alerts, then only the aircraft an alert names. Built once per change of
/// the app (its revision, the contacts, the traffic picture, the position)
/// and reused by every screen that asks within half a second.
List<LiveContactItem> buildLiveItems(AppController app) {
  final now = app.nowMs();
  final contacts = app.tracker.contacts;
  var heard = 0;
  for (final c in contacts) {
    heard = heard * 31 + c.lastSeenMs + (c.posMs ?? 0);
  }
  final o = app.observer;
  final key = Object.hash(app.revision, contacts.length, heard, identityHashCode(app.traffic.result),
      identityHashCode(app.traffic.aircraft), o?.lat, o?.lon, app.settings.phoneRx);
  final hit = _itemsCache[app];
  if (hit != null && hit.$1 == key && (now - hit.$2).abs() < 500) return hit.$3;
  final items = List<LiveContactItem>.unmodifiable(_buildLiveItems(app, now, contacts));
  _itemsCache[app] = (key, now, items);
  return items;
}

List<LiveContactItem> _buildLiveItems(AppController app, int now, List<Contact> contacts) {
  final o = app.observer;
  final result = app.traffic.result;
  final items = <LiveContactItem>[];

  TrafficAlert? droneAlert(String key) {
    for (final a in result.alerts) {
      if (a.droneId == key) return a;
    }
    return null;
  }

  for (final Contact c in contacts) {
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
      sublabel: _sensorLine(sensorChips(c, now)),
      lat: c.lat,
      lon: c.lon,
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
      sensors: sensorChips(c, now),
      operatorFromDroneM: c.hasPosition && c.opLat != null && c.opLon != null
          ? Geo.distanceM(c.lat!, c.lon!, c.opLat!, c.opLon!)
          : null,
      operatorFromYouM:
          o != null && c.opLat != null && c.opLon != null ? Geo.distanceM(o.lat, o.lon, c.opLat!, c.opLon!) : null,
    ));
  }

  // Operators, where their drones report them: a ground pin each.
  for (final Contact c in contacts) {
    if (c.opLat == null || c.opLon == null) continue;
    final label = TrafficRules.droneLabel(c.label);
    final fromDrone = c.hasPosition ? Geo.distanceM(c.lat!, c.lon!, c.opLat!, c.opLon!) : null;
    final fromDroneBrg = c.hasPosition ? Geo.bearingDeg(c.lat!, c.lon!, c.opLat!, c.opLon!) : null;
    items.add(LiveContactItem(
      id: 'op:${c.key}',
      label: fromDrone == null
          ? 'operator'
          : 'operator ${Geo.rangeText(fromDrone)} ${TrafficRules.compass8(fromDroneBrg!)}',
      sublabel: 'Operator of $label',
      lat: c.opLat,
      lon: c.opLon,
      distanceM: o == null ? null : Geo.distanceM(o.lat, o.lon, c.opLat!, c.opLon!),
      bearingDeg: o == null ? null : Geo.bearingDeg(o.lat, o.lon, c.opLat!, c.opLon!),
      isAircraft: false,
      isOperator: true,
      ofDrone: c.key,
      ofDroneLabel: label,
      fromDroneM: fromDrone,
      fromDroneBearing: fromDroneBrg,
      ageSeconds: c.ageS(now),
      stale: ContactTracker.isStale(c, now),
    ));
  }

  for (final a in app.traffic.aircraft) {
    final age = a.ageS(now);
    if (age > TrafficRules.presentS) continue;
    final al = result.alertForHex(a.hex);
    if (al == null) continue; // ADS-B is for conflicts only
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
      lat: a.lat,
      lon: a.lon,
      distanceM: dist,
      bearingDeg: brg,
      heightM: ft == null ? null : ft / TrafficRules.ftToM,
      heightRef: 'ft',
      speedMps: a.gsMps,
      trackDeg: a.trackDeg,
      isAircraft: true,
      ageSeconds: age,
      stale: age >= TrafficRules.freshS,
      alertLevel: al.level,
      alert: al,
      aircraft: a,
      ghost: ghost,
      sources: const ['ADS-B'],
    ));
  }
  return items;
}

/// A short history per drone for the cards' sparklines: the RSSI heard, at
/// most one sample a second, the last [capacity]. Kept per app, so it
/// survives tab changes. (Aircraft have no cards.)
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

  /// Recent positions per drone for the map's trails: one every 2 s, the
  /// last [trailLength].
  static const int trailLength = 30;
  final Map<String, List<(double, double)>> _trails = {};
  final Map<String, int> _trailMs = {};

  void record(List<LiveContactItem> items, int nowMs) {
    final ids = <String>{};
    for (final c in items) {
      if (!c.isDrone) continue;
      ids.add(c.id);
      _seenMs[c.id] = nowMs;
      if (c.lat != null && c.lon != null && nowMs - (_trailMs[c.id] ?? -1 << 40) >= 1900) {
        _trailMs[c.id] = nowMs;
        final t = _trails.putIfAbsent(c.id, () => <(double, double)>[]);
        if (t.isEmpty || t.last != (c.lat!, c.lon!)) t.add((c.lat!, c.lon!));
        if (t.length > trailLength) t.removeRange(0, t.length - trailLength);
      }
      final v = c.rssi?.toDouble();
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
    _trails.removeWhere((k, _) => gone(k));
    _trailMs.removeWhere((k, _) => gone(k));
    _seenMs.removeWhere((k, _) => gone(k));
  }

  List<(double, double)> trail(String id) => List.unmodifiable(_trails[id] ?? const <(double, double)>[]);

  List<double> series(String id) => List.unmodifiable(_series[id] ?? const <double>[]);
}
