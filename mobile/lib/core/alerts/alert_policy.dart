// alert_policy.dart — which alerts become notifications, and their words
// (plan §5.3 Alerts, §8.2 rate limits, §8.4 On the phone).
//
// - Traffic: one notification per alert (drone-aircraft pair, or aircraft
//   for LOW / EMERGENCY) per 5 minutes; warnings are time-sensitive.
// - Drones: EMERGENCY REPORTED and ID SIGNATURE INVALID, once per contact
//   per 5 minutes, only while a detector is connected.
// - "Mute 10 min" silences notifications, callouts and haptics (not the
//   on-screen alert, which stays as long as the condition does).
// Words: never "collision", "conflict", "safe", "clear" or "TCAS"; km and m
// for distances, feet for aircraft altitude, always the data age.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import '../geo.dart';
import '../live/contact_tracker.dart';
import '../traffic/traffic_rules.dart';

enum AlertSource { traffic, drone }

class AlertEvent {
  final String id; // rate-limit key, and the notification payload
  final AlertSource source;
  final TrafficLevel level;
  final String title;
  final String body;
  final String? spoken;
  final String? hex; // aircraft to show
  final String? droneId;

  const AlertEvent({
    required this.id,
    required this.source,
    required this.level,
    required this.title,
    required this.body,
    this.spoken,
    this.hex,
    this.droneId,
  });

  bool get timeSensitive => level == TrafficLevel.warning;
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

class AlertWords {
  /// '2,650 ft' (pressure altitude as reported), or null.
  static String? altitudeFt(TrafficAircraft? a) {
    final m = a?.altBaroM ?? a?.altGeomM;
    if (m == null) return null;
    return '${_thousands((m / TrafficRules.ftToM).round())} ft';
  }

  /// 'descending', 'climbing' or null (level or unknown); 1 m/s ~ 200 fpm.
  static String? trend(TrafficAircraft? a) {
    final v = a?.vsMps;
    if (v == null) return null;
    if (v < -1.0) return 'descending';
    if (v > 1.0) return 'climbing';
    return null;
  }

  static String aircraftName(TrafficAircraft? a, TrafficAlert al) {
    final name = a?.name ?? (al.callsign.isNotEmpty ? al.callsign : al.hex.toUpperCase());
    final type = a?.type ?? '';
    return type.isEmpty ? name : '$type $name';
  }

  static String title(TrafficAlert al) {
    final id = TrafficRules.droneLabel(al.droneId);
    switch (al.kind) {
      case TrafficKind.near:
        return 'Traffic near drone $id';
      case TrafficKind.converging:
        return 'Traffic converging with drone $id';
      case TrafficKind.low:
        final b = al.bearingDeg == null ? '' : ' ${TrafficRules.compass8(al.bearingDeg!)}';
        return 'Low traffic$b ${al.horizM == null ? '' : '${TrafficRules.kmText(al.horizM!)} km'}'.trim();
      case TrafficKind.emergency:
        return al.text;
    }
  }

  /// 'B738 UAL123 · 2,650 ft · 1.1 km NE of the drone · reported 6 s ago'
  static String body(TrafficAlert al, TrafficAircraft? a) {
    final parts = <String>[aircraftName(a, al)];
    final alt = altitudeFt(a);
    if (alt != null) parts.add(alt);
    if (al.horizM != null) {
      final dir = al.bearingDeg == null ? '' : ' ${TrafficRules.compass8(al.bearingDeg!)}';
      final of = al.kind.isPair ? ' of the drone' : ' of you';
      parts.add('${TrafficRules.kmText(al.horizM!)} km$dir$of');
    }
    if (al.kind.isPair) {
      if (al.vertM == null) {
        parts.add('height unknown');
      } else {
        final v = al.vertM!.round();
        parts.add(v >= 0 ? '$v m above it' : '${-v} m below it');
      }
    }
    if (al.kind == TrafficKind.converging && al.cpaS != null) {
      parts.add('closest in ${al.cpaS!.round()} s');
    }
    parts.add('reported ${al.ageS.round()} s ago');
    return parts.join(' · ');
  }

  /// The banner's second line: the notification's words plus the clock
  /// position from the phone, when the phone's position and heading are
  /// known.
  static String? clockFromPhone(TrafficAircraft? a, double? obsLat, double? obsLon, double? headingDeg) {
    if (a == null || obsLat == null || obsLon == null || headingDeg == null) return null;
    final brg = Geo.bearingDeg(obsLat, obsLon, a.lat, a.lon);
    final d = Geo.distanceM(obsLat, obsLon, a.lat, a.lon);
    return '${Geo.clockWords(brg, headingDeg)} · ${TrafficRules.kmText(d)} km from you';
  }

  /// 'Traffic, 2 o'clock, 1.1 kilometres, 2,600 feet, descending.'
  static String spoken(TrafficAircraft a, double obsLat, double obsLon, double headingDeg) {
    final brg = Geo.bearingDeg(obsLat, obsLon, a.lat, a.lon);
    final d = Geo.distanceM(obsLat, obsLon, a.lat, a.lon);
    final parts = <String>['Traffic', Geo.clockWords(brg, headingDeg), '${TrafficRules.kmText(d)} kilometres'];
    final m = a.altBaroM ?? a.altGeomM;
    // Hundreds of feet, rounded down as in the plan's example (2,650 -> 2,600).
    if (m != null) parts.add('${_thousands(((m / TrafficRules.ftToM) + 0.5).floor() ~/ 100 * 100)} feet');
    final t = trend(a);
    if (t != null) parts.add(t);
    return '${parts.join(', ')}.';
  }

  static String? droneAlertWords(Contact c) {
    if (c.emergency) return 'EMERGENCY REPORTED';
    if (c.isAuthInvalid) return 'ID SIGNATURE INVALID';
    return null;
  }
}

class AlertPolicy {
  static const repeatMs = 5 * 60 * 1000;
  static const muteMs = 10 * 60 * 1000;

  final Map<String, int> _lastNotified = {};
  int _mutedUntilMs = 0;

  bool isMuted(int nowMs) => nowMs < _mutedUntilMs;
  void mute(int nowMs, [int forMs = muteMs]) => _mutedUntilMs = nowMs + forMs;

  bool _due(String id, int nowMs) {
    final last = _lastNotified[id];
    if (last != null && nowMs - last < repeatMs) return false;
    _lastNotified[id] = nowMs;
    return true;
  }

  /// The alerts to notify now. [aircraft] looks an aircraft up by hex.
  /// Held alerts (kept by hysteresis) never notify.
  List<AlertEvent> consider({
    required int nowMs,
    required TrafficResult traffic,
    required TrafficAircraft? Function(String hex) aircraft,
    required List<Contact> drones,
    required bool detectorConnected,
    double? obsLat,
    double? obsLon,
    double? headingDeg,
  }) {
    _lastNotified.removeWhere((_, t) => nowMs - t >= repeatMs);
    if (isMuted(nowMs)) return const [];
    final out = <AlertEvent>[];
    for (final al in traffic.alerts) {
      if (al.held || al.level == TrafficLevel.none) continue;
      if (!_due('t|${al.id}', nowMs)) continue;
      final a = aircraft(al.hex);
      out.add(AlertEvent(
        id: 't|${al.id}',
        source: AlertSource.traffic,
        level: al.level,
        title: AlertWords.title(al),
        body: AlertWords.body(al, a),
        spoken: (a != null && obsLat != null && obsLon != null && headingDeg != null)
            ? AlertWords.spoken(a, obsLat, obsLon, headingDeg)
            : null,
        hex: al.hex,
        droneId: al.droneId.isEmpty ? null : al.droneId,
      ));
    }
    if (detectorConnected) {
      for (final c in drones) {
        final w = AlertWords.droneAlertWords(c);
        if (w == null || ContactTracker.isStale(c, nowMs)) continue;
        final id = 'd|$w|${c.key}';
        if (!_due(id, nowMs)) continue;
        out.add(AlertEvent(
          id: id,
          source: AlertSource.drone,
          level: c.emergency ? TrafficLevel.warning : TrafficLevel.caution,
          title: '$w · ${TrafficRules.droneLabel(c.label)}',
          body: [
            c.label,
            if (c.rangeM != null) '${Geo.rangeText(c.rangeM!)} from you',
            'heard ${c.ageS(nowMs).round()} s ago',
          ].join(' · '),
          droneId: c.key,
        ));
      }
    }
    return out;
  }
}
