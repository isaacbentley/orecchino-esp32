// traffic_rules.dart — ADS-B conflict watch: manned aircraft near the drones,
// with a resolution advisory for each (14 CFR 107.37(a): the drone gives way).
//
// A line-for-line port of firmware/common/traffic.h (the reference; its
// header comment holds the rules, every choice made where plan §8 left room,
// and the `traffic` host-line format). app/Sources/Orecchino/
// TrafficRules.swift is the other port. All three load every file in
// tests/vectors/traffic/*.json; change one, change all three.
//
// Unknown values are null here (NaN in C). Times are milliseconds on one
// clock; use TrafficRules.nowMs() for wall-clock milliseconds.
// Words: never "collision", "safe", "clear" (other than the instruction
// "KEEP CLEAR OF"), "conflict resolved" or "TCAS".
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:math' as math;

enum TrafficLevel implements Comparable<TrafficLevel> {
  none,
  caution,
  warning;

  @override
  int compareTo(TrafficLevel other) => index.compareTo(other.index);
  bool operator >(TrafficLevel other) => index > other.index;
  bool operator <(TrafficLevel other) => index < other.index;
  bool operator >=(TrafficLevel other) => index >= other.index;
  bool operator <=(TrafficLevel other) => index <= other.index;
}

/// Drone-aircraft pairs, and LOW: an airborne aircraft in UAS airspace (one
/// per aircraft). No emergency-squawk rule.
enum TrafficKind {
  near,
  converging,
  low;

  TrafficLevel get level => this == TrafficKind.low ? TrafficLevel.caution : TrafficLevel.warning;
  bool get isPair => this != TrafficKind.low;

  /// A pair with an aircraft on the ground is a caution, not a warning; LOW is a caution.
  TrafficLevel levelFor({required bool onGround}) =>
      this == TrafficKind.low || onGround ? TrafficLevel.caution : TrafficLevel.warning;
}

/// Where the aircraft is relative to the drone (current vertical; level =
/// within 30 m).
enum TrafficVertical { unknown, above, level, below }

/// One aircraft as reported by ADS-B. [squawk] is the four octal digits read
/// as a decimal number (7700), 0 when unknown.
class TrafficAircraft {
  final String hex; // ICAO address, lower-case hex
  final String callsign;
  final String type;
  final double lat;
  final double lon;
  final double? altGeomM; // geometric, WGS-84 ellipsoid
  final double? altBaroM; // pressure altitude (shown, never compared with drones)
  final double? gsMps;
  final double? trackDeg;
  final double? vsMps;
  final int squawk;
  final bool emergency;
  final bool onGround; // reported on the ground (taxiing, parked)
  final int seenMs; // when the position was reported

  const TrafficAircraft({
    required this.hex,
    this.callsign = '',
    this.type = '',
    required this.lat,
    required this.lon,
    this.altGeomM,
    this.altBaroM,
    this.gsMps,
    this.trackDeg,
    this.vsMps,
    this.squawk = 0,
    this.emergency = false,
    this.onGround = false,
    required this.seenMs,
  });

  /// Callsign, else the hex in capitals.
  String get name => callsign.isEmpty ? hex.toUpperCase() : callsign;
  double ageS(int nowMs) => TrafficRules.ageS(seenMs, nowMs);
}

class TrafficDrone {
  final String id; // stable id (UAS id, else MAC); the words use its last 5
  final double? lat;
  final double? lon;
  final double? altGeoM; // ODID geodetic altitude (WGS-84)
  final double? speedMps;
  final double? headingDeg;
  final bool live; // heard within 60 s with a position
  final double? heightM; // height above take-off/ground (LOW's ground)

  const TrafficDrone({
    required this.id,
    this.lat,
    this.lon,
    this.altGeoM,
    this.speedMps,
    this.headingDeg,
    required this.live,
    this.heightM,
  });
}

class TrafficObserver {
  final double? lat;
  final double? lon;
  final double? elevM; // ellipsoid height preferred; MSL acceptable

  const TrafficObserver({this.lat, this.lon, this.elevM});
  static const unknown = TrafficObserver();
}

class TrafficAlert {
  final TrafficLevel level;
  final TrafficKind kind;
  final bool held; // kept by hysteresis; the raise condition is false now
  final bool heightUnknown;
  final bool onGround; // the aircraft is reported on the ground
  final int? droneIndex; // into this evaluation's drones
  final int? acIndex; // into this evaluation's aircraft (null: gone)
  final String droneId;
  final String hex;
  final String callsign;
  final double? horizM; // drone to aircraft (always set for a pair)
  final double? vertM; // aircraft minus drone
  final double? bearingDeg; // from the drone to the aircraft (always set)
  final double? cpaS;
  final double? cpaM;
  final double ageS; // aircraft position age
  final String text; // 'TRAFFIC NEAR DRONE D9A03'
  final TrafficVertical vertRel;
  final String action; // 'GIVE WAY: DESCEND AND LAND D9A03'
  final String resolution; // action + '; ' + the geometry
  final bool approx; // LOW: barometric aircraft height used
  final bool fromObserver; // LOW: horizM/bearingDeg from the observer (droneId '')

  /// True above, false level or below, null unknown.
  bool? get aircraftAbove => vertRel == TrafficVertical.unknown ? null : vertRel == TrafficVertical.above;

  const TrafficAlert({
    required this.level,
    required this.kind,
    this.held = false,
    this.heightUnknown = false,
    this.onGround = false,
    this.droneIndex,
    this.acIndex,
    this.droneId = '',
    required this.hex,
    this.callsign = '',
    this.horizM,
    this.vertM,
    this.bearingDeg,
    this.cpaS,
    this.cpaM,
    required this.ageS,
    this.text = '',
    this.vertRel = TrafficVertical.unknown,
    this.action = '',
    this.resolution = '',
    this.approx = false,
    this.fromObserver = false,
  });

  String get id => '${kind.name}|$droneId|$hex';

  TrafficAlert copyWith({
    TrafficLevel? level,
    TrafficKind? kind,
    bool? held,
    String? text,
    double? ageS,
    int? Function()? droneIndex,
    int? Function()? acIndex,
    TrafficVertical? vertRel,
    String? action,
    String? resolution,
  }) =>
      TrafficAlert(
        level: level ?? this.level,
        kind: kind ?? this.kind,
        held: held ?? this.held,
        heightUnknown: heightUnknown,
        onGround: onGround,
        droneIndex: droneIndex != null ? droneIndex() : this.droneIndex,
        acIndex: acIndex != null ? acIndex() : this.acIndex,
        droneId: droneId,
        hex: hex,
        callsign: callsign,
        horizM: horizM,
        vertM: vertM,
        bearingDeg: bearingDeg,
        cpaS: cpaS,
        cpaM: cpaM,
        ageS: ageS ?? this.ageS,
        text: text ?? this.text,
        vertRel: vertRel ?? this.vertRel,
        action: action ?? this.action,
        resolution: resolution ?? this.resolution,
        approx: approx,
        fromObserver: fromObserver,
      );
}

class _Entry {
  TrafficAlert a;
  int seenMs;
  int outSinceMs = 0;
  bool out = false;
  bool visited = false;
  _Entry(this.a, this.seenMs);
}

/// Caller-owned hysteresis memory.
class TrafficState {
  final List<_Entry> _entries = [];
}

class TrafficResult {
  final List<TrafficAlert> alerts;
  final bool haveData;
  final bool stale;
  final double? dataAgeS;
  final int aircraftCount; // aircraft present (<= 60 s); never shown as a count of threats

  const TrafficResult({
    this.alerts = const [],
    this.haveData = false,
    this.stale = false,
    this.dataAgeS,
    this.aircraftCount = 0,
  });

  static const empty = TrafficResult();
  TrafficLevel get highest => alerts.isEmpty ? TrafficLevel.none : alerts.first.level;
  String get summary => TrafficRules.summary(this);
  TrafficAlert? alertForHex(String hex) {
    for (final a in alerts) {
      if (a.hex == hex) return a;
    }
    return null;
  }
}

class _Offset {
  final double dx, dy;
  const _Offset(this.dx, this.dy);
}

class TrafficRules {
  static const maxAircraft = 32;
  static const maxAlerts = 16;
  static const freshS = 30.0, presentS = 60.0, staleS = 30.0;
  static const nearHM = 1000.0, nearVM = 150.0;
  static const cpaMaxS = 60.0, cpaMissM = 500.0;
  static const holdHM = 1300.0, holdVM = 200.0;
  static const clearMs = 20000;
  static const levelBandM = 30.0, keepRM = 30000.0;
  static const lowRM = 3000.0, lowAglM = 460.0;

  /// LOW with the ground unknown: only aircraft below 3,500 m MSL (see traffic.h).
  static const lowUnknownGroundMaxM = 3500.0;
  static const earthRM = 6371000.0;
  static const deg = math.pi / 180.0;
  static const ftToM = 0.3048;
  static const ktToMps = 1852.0 / 3600.0;

  static int nowMs([DateTime? t]) => (t ?? DateTime.now()).millisecondsSinceEpoch;

  static bool _known(double? v) => v != null && v.isFinite;
  static bool _altKnown(double? v) => v != null && v.isFinite && v > -999.0;

  static double ageS(int seenMs, int nowMs) => math.max(nowMs - seenMs, 0) / 1000.0;

  /// East/north metres from point 1 to point 2 (flat earth, longitude wrapped).
  static _Offset _offset(double lat1, double lon1, double lat2, double lon2) {
    var dlon = lon2 - lon1;
    if (dlon > 180.0) {
      dlon -= 360.0;
    } else if (dlon < -180.0) {
      dlon += 360.0;
    }
    final mlat = (lat1 + lat2) * 0.5 * deg;
    return _Offset(dlon * deg * math.cos(mlat) * earthRM, (lat2 - lat1) * deg * earthRM);
  }

  static double distanceM(double lat1, double lon1, double lat2, double lon2) {
    final o = _offset(lat1, lon1, lat2, lon2);
    return math.sqrt(o.dx * o.dx + o.dy * o.dy);
  }

  /// Bearing in degrees from point 1 to point 2.
  static double bearingDeg(double lat1, double lon1, double lat2, double lon2) {
    final o = _offset(lat1, lon1, lat2, lon2);
    return _bearing(o.dx, o.dy);
  }

  static double _bearing(double dx, double dy) {
    var b = math.atan2(dx, dy) / deg;
    if (b < 0.0) b += 360.0;
    if (b >= 360.0) b -= 360.0;
    return b;
  }

  static String compass8(double d) {
    var i = ((d + 22.5) / 45.0).floor() % 8;
    if (i < 0) i += 8;
    return const ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'][i];
  }

  /// A readable tail of a drone id (traffic_drone_label): 'uas:'/'mac:'
  /// dropped; a MAC reads 'MAC 4C:C5:A2' (its last three bytes); else the id
  /// when <= 8 characters, else its last 5 grown past leading punctuation
  /// ('1581F20000D9A03' -> 'D9A03', 'DRONE-B-9A01' -> 'B-9A01').
  static String droneLabel(String raw) {
    var id = raw;
    if (id.startsWith('uas:') || id.startsWith('mac:')) id = id.substring(4);
    final c = id.codeUnits;
    bool hex(int x) => (x >= 48 && x <= 57) || (x >= 97 && x <= 102) || (x >= 65 && x <= 70);
    bool alnum(int x) => (x >= 48 && x <= 57) || (x >= 97 && x <= 122) || (x >= 65 && x <= 90);
    int? o, s;
    if (c.length == 12 && c.every(hex)) {
      o = 6;
      s = 2;
    } else if (c.length == 17) {
      var ok = true;
      for (var i = 0; i < 17 && ok; i++) {
        ok = i % 3 == 2 ? ((c[i] == 58 || c[i] == 45) && c[i] == c[2]) : hex(c[i]);
      }
      if (ok) {
        o = 9;
        s = 3;
      }
    }
    if (o != null && s != null) {
      String p(int i) => id.substring(i, i + 2).toUpperCase();
      return 'MAC ${p(o)}:${p(o + s)}:${p(o + 2 * s)}';
    }
    if (c.length <= 8) return id;
    var tail = 5;
    while (tail < c.length && !alnum(c[c.length - tail])) {
      tail++;
    }
    return id.substring(c.length - tail);
  }

  /// 'ADS-B 6 s old'
  static String ageWords(double ageS) => 'ADS-B ${(ageS + 0.5).floor()} s old';

  static String kmText(double m) {
    final t = (m / 100.0 + 0.5).floor();
    return '${t ~/ 10}.${t % 10}';
  }

  static int _cmp(TrafficAlert a, TrafficAlert b) {
    if (a.level != b.level) return a.level > b.level ? -1 : 1;
    if (a.kind != b.kind) return a.kind.index < b.kind.index ? -1 : 1;
    final ah = a.horizM ?? double.nan, bh = b.horizM ?? double.nan;
    if (ah.isNaN != bh.isNaN) return ah.isNaN ? 1 : -1;
    if (!ah.isNaN && ah != bh) return ah < bh ? -1 : 1;
    final c = a.droneId.compareTo(b.droneId);
    if (c != 0) return c < 0 ? -1 : 1;
    final h = a.hex.compareTo(b.hex);
    return h < 0 ? -1 : (h > 0 ? 1 : 0);
  }

  /// The aircraft above / level / below the drone, from the current vertical.
  static TrafficVertical vertRel(double? v) {
    if (v == null || v.isNaN) return TrafficVertical.unknown;
    if (v > levelBandM) return TrafficVertical.above;
    if (v < -levelBandM) return TrafficVertical.below;
    return TrafficVertical.level;
  }

  /// The words, the action and the resolution for a pair (traffic_pair_words).
  static TrafficAlert _pairWords(TrafficAlert a, TrafficKind kind) {
    final id = droneLabel(a.droneId);
    final hu = a.onGround ? ', AIRCRAFT ON GROUND' : (a.heightUnknown ? ', HEIGHT UNKNOWN' : '');
    final t = a.cpaS;
    final String text;
    if (kind == TrafficKind.near) {
      text = 'TRAFFIC NEAR DRONE $id$hu';
    } else if (t == null) {
      text = 'TRAFFIC CONVERGING WITH $id$hu';
    } else {
      text = 'TRAFFIC CONVERGING WITH $id, ${(t + 0.5).floor()} S$hu';
    }
    final vr = vertRel(a.vertM);
    final brg = a.bearingDeg ?? 0.0;
    final String action;
    if (a.onGround) {
      action = 'KEEP CLEAR OF AIRCRAFT ON GROUND';
    } else if (vr == TrafficVertical.below) {
      action = 'GIVE WAY: MOVE ${compass8((brg + 180.0) % 360.0)}, THEN LAND $id';
    } else {
      action = 'GIVE WAY: DESCEND AND LAND $id';
    }
    final v = a.vertM == null ? 0 : (a.vertM!.abs() + 0.5).floor();
    final String vert;
    if (a.onGround) {
      vert = 'AIRCRAFT ON GROUND';
    } else {
      vert = switch (vr) {
        TrafficVertical.above => 'AIRCRAFT $v M ABOVE',
        TrafficVertical.below => 'AIRCRAFT $v M BELOW',
        TrafficVertical.level => 'AIRCRAFT LEVEL WITHIN 30 M',
        TrafficVertical.unknown => 'AIRCRAFT HEIGHT UNKNOWN',
      };
    }
    final h = a.horizM ?? 0.0;
    final hz = h < 1000.0 ? '${(h / 10.0 + 0.5).floor() * 10} M' : '${kmText(h)} KM';
    final cpa = t == null ? '' : ', CLOSEST IN ${(t + 0.5).floor()} S';
    return a.copyWith(text: text, vertRel: vr, action: action, resolution: '$action; $vert, $hz ${compass8(brg)}$cpa');
  }

  /// '800 M' to the nearest 10 m under 1 km, else '2.4 KM'.
  static String distText(double m) => m < 1000.0 ? '${(m / 10.0 + 0.5).floor() * 10} M' : '${kmText(m)} KM';

  /// LOW's words from its numbers (traffic_low_words).
  static TrafficAlert _lowWords(TrafficAlert a) {
    final dist = distText(a.horizM ?? 0.0);
    final brg = compass8(a.bearingDeg ?? 0.0);
    final suffix =
        a.onGround ? ', AIRCRAFT ON GROUND' : (a.heightUnknown ? ', HEIGHT UNKNOWN' : (a.approx ? ', APPROX.' : ''));
    final v = a.vertM == null ? 0 : (a.vertM! + 0.5).floor();
    final ab = a.approx ? 'ABOUT ' : '';
    final String vert;
    if (a.onGround) {
      vert = 'AIRCRAFT ON GROUND';
    } else if (a.heightUnknown) {
      vert = 'AIRCRAFT HEIGHT UNKNOWN';
    } else if (v <= 0) {
      vert = 'AIRCRAFT NEAR GROUND LEVEL'; // "near" is the approximation
    } else {
      vert = 'AIRCRAFT $ab$v M ABOVE GROUND';
    }
    const action = 'BE READY TO LAND DRONES';
    return a.copyWith(
      text: 'LOW TRAFFIC $brg $dist$suffix',
      vertRel: vertRel(a.vertM),
      action: action,
      resolution: '$action; $vert, $dist $brg',
    );
  }

  /// Raise or refresh an alert (mirrors traffic_apply): a pair keyed by
  /// drone and aircraft, LOW by the aircraft alone.
  static void _apply(TrafficState s, TrafficAlert cand, bool raw, bool hold, int seenMs, int nowMs) {
    final low = cand.kind == TrafficKind.low;
    _Entry? e;
    for (final x in s._entries) {
      if (x.a.hex != cand.hex) continue;
      if (low ? x.a.kind == TrafficKind.low : (x.a.kind != TrafficKind.low && x.a.droneId == cand.droneId)) {
        e = x;
        break;
      }
    }
    var kind = cand.kind;
    if (e != null) {
      final old = e.a.kind;
      if (low) {
        kind = TrafficKind.low;
      } else if (!raw) {
        kind = old;
      } else if (old == TrafficKind.near && hold) {
        kind = TrafficKind.near;
      }
    } else {
      if (!raw) return;
      final fresh = _Entry(cand, seenMs);
      if (s._entries.length < maxAlerts) {
        s._entries.add(fresh);
      } else {
        var worst = 0;
        for (var k = 1; k < s._entries.length; k++) {
          if (_cmp(s._entries[k].a, s._entries[worst].a) > 0) worst = k;
        }
        if (_cmp(cand, s._entries[worst].a) >= 0) return;
        s._entries[worst] = fresh;
      }
      e = fresh;
    }
    final a = cand.copyWith(kind: kind, level: kind.levelFor(onGround: cand.onGround), held: !raw);
    e.a = low ? _lowWords(a) : _pairWords(a, kind);
    e.visited = true;
    e.seenMs = seenMs;
    if (raw || hold) {
      e.out = false;
    } else if (!e.out) {
      e.out = true;
      e.outSinceMs = nowMs;
    }
  }

  static double? _opt(double v) => v.isNaN ? null : v;

  /// The rule function (traffic_evaluate). dataMs null: no ADS-B source.
  /// [observer] only feeds LOW.
  static TrafficResult evaluate({
    required List<TrafficDrone> drones,
    required List<TrafficAircraft> aircraft,
    TrafficObserver observer = TrafficObserver.unknown,
    required int? dataMs,
    required int nowMs,
    required TrafficState state,
  }) {
    final ac = aircraft;
    final st = state;
    final haveData = dataMs != null;
    final dataAge = dataMs != null ? ageS(dataMs, nowMs) : double.nan;
    final stale = haveData && !(dataAge <= staleS);
    final canRaise = haveData && !stale;

    for (final e in st._entries) {
      e.visited = false;
    }

    bool present(TrafficAircraft a) => ageS(a.seenMs, nowMs) <= presentS && a.lat.isFinite && a.lon.isFinite;
    final aircraftCount = ac.where(present).length;

    for (var i = 0; i < drones.length; i++) {
      final d = drones[i];
      if (!_known(d.lat) || !_known(d.lon)) continue;
      for (var j = 0; j < ac.length; j++) {
        final a = ac[j];
        if (!present(a)) continue;
        final age = ageS(a.seenMs, nowMs);
        final o = _offset(d.lat!, d.lon!, a.lat, a.lon);
        final horiz = math.sqrt(o.dx * o.dx + o.dy * o.dy);
        final vert = (_altKnown(a.altGeomM) && _altKnown(d.altGeoM)) ? a.altGeomM! - d.altGeoM! : double.nan;
        var cpaS = double.nan, cpaM = double.nan;
        var vcpa = vert;
        final gs = a.gsMps, trk = a.trackDeg, sp = d.speedMps, hd = d.headingDeg;
        if (!a.onGround && _known(gs) && gs! >= 0 && _known(trk) && _known(sp) && sp! >= 0 && _known(hd)) {
          final avx = gs * math.sin(trk! * deg), avy = gs * math.cos(trk * deg);
          final dvx = sp * math.sin(hd! * deg), dvy = sp * math.cos(hd * deg);
          final wx = avx - dvx, wy = avy - dvy;
          final ww = wx * wx + wy * wy;
          if (ww > 1e-9) {
            final t = -(o.dx * wx + o.dy * wy) / ww;
            if (t > 0.0 && t <= cpaMaxS) {
              final mx = o.dx + wx * t, my = o.dy + wy * t;
              cpaS = t;
              cpaM = math.sqrt(mx * mx + my * my);
              if (!vcpa.isNaN && _known(a.vsMps)) vcpa = vcpa + a.vsMps! * t;
            }
          }
        }
        final eligible = canRaise && d.live && age < freshS;
        final nearRaw = eligible && horiz <= nearHM && (vert.isNaN || vert.abs() <= nearVM);
        final convRaw = eligible && !cpaS.isNaN && cpaM < cpaMissM && (vcpa.isNaN || vcpa.abs() <= nearVM);
        final hold = d.live && horiz <= holdHM && (vert.isNaN || vert.abs() <= holdVM);
        final kind = nearRaw ? TrafficKind.near : TrafficKind.converging;
        final c = TrafficAlert(
          level: kind.levelFor(onGround: a.onGround),
          kind: kind,
          heightUnknown: vert.isNaN,
          onGround: a.onGround,
          droneIndex: i,
          acIndex: j,
          droneId: d.id,
          hex: a.hex,
          callsign: a.callsign,
          horizM: horiz,
          vertM: _opt(vert),
          bearingDeg: _bearing(o.dx, o.dy),
          cpaS: _opt(cpaS),
          cpaM: _opt(cpaM),
          ageS: age,
        );
        _apply(st, c, nearRaw || convRaw, hold, a.seenMs, nowMs);
      }
    }

    // LOW: airborne aircraft in UAS airspace.
    final obs = observer;
    final obsPos = _known(obs.lat) && _known(obs.lon);
    // The fallback ground (see LOW in traffic.h): the observer's elevation,
    // else the lowest live drone's alt_geo minus its height.
    var fallback = double.nan;
    if (_altKnown(obs.elevM)) {
      fallback = obs.elevM!;
    } else {
      var lowest = double.nan;
      for (final d in drones) {
        if (!d.live || !_known(d.lat) || !_known(d.lon)) continue;
        if (!_altKnown(d.altGeoM) || !_known(d.heightM)) continue;
        if (lowest.isNaN || d.altGeoM! < lowest) {
          lowest = d.altGeoM!;
          fallback = d.altGeoM! - d.heightM!;
        }
      }
    }
    for (var j = 0; j < ac.length; j++) {
      final a = ac[j];
      if (!present(a)) continue;
      final age = ageS(a.seenMs, nowMs);
      var dx = double.nan, dy = double.nan, dist = double.nan;
      int? anchor;
      var fromObs = false, within = false;
      if (obsPos) {
        final o = _offset(obs.lat!, obs.lon!, a.lat, a.lon);
        dx = o.dx;
        dy = o.dy;
        dist = math.sqrt(dx * dx + dy * dy);
        fromObs = true;
        within = dist <= lowRM;
      }
      if (!within) {
        int? bi;
        var bd = double.nan, bx = 0.0, by = 0.0;
        for (var i = 0; i < drones.length; i++) {
          final d = drones[i];
          if (!d.live || !_known(d.lat) || !_known(d.lon)) continue;
          final o = _offset(d.lat!, d.lon!, a.lat, a.lon);
          final h = math.sqrt(o.dx * o.dx + o.dy * o.dy);
          if (bi == null || h < bd) {
            bi = i;
            bd = h;
            bx = o.dx;
            by = o.dy;
          }
        }
        if (bi != null && (bd <= lowRM || !fromObs)) {
          anchor = bi;
          dist = bd;
          dx = bx;
          dy = by;
          fromObs = false;
          within = bd <= lowRM;
        }
      }
      if (!fromObs && anchor == null) continue;
      // Ground under the anchor: the anchor drone's alt_geo minus its height,
      // else the fallback.
      var ground = fallback;
      if (anchor != null && _altKnown(drones[anchor].altGeoM) && _known(drones[anchor].heightM)) {
        ground = drones[anchor].altGeoM! - drones[anchor].heightM!;
      }
      var h = double.nan;
      var approx = false;
      if (_altKnown(a.altGeomM)) {
        h = a.altGeomM!;
      } else if (_altKnown(a.altBaroM)) {
        h = a.altBaroM!;
        approx = true;
      }
      final vert = (!h.isNaN && !ground.isNaN) ? h - ground : double.nan;
      if (vert.isNaN) approx = false;
      final c = TrafficAlert(
        level: TrafficLevel.caution,
        kind: TrafficKind.low,
        heightUnknown: vert.isNaN,
        onGround: a.onGround,
        droneIndex: anchor,
        acIndex: j,
        droneId: anchor == null ? '' : drones[anchor].id,
        hex: a.hex,
        callsign: a.callsign,
        horizM: dist,
        vertM: _opt(vert),
        bearingDeg: _bearing(dx, dy),
        ageS: age,
        approx: approx,
        fromObserver: fromObs,
      );
      final low = !vert.isNaN ? vert < lowAglM : (h.isNaN || !ground.isNaN || h < lowUnknownGroundMaxM);
      final cond = !a.onGround && within && low;
      _apply(st, c, canRaise && age < freshS && cond, cond, a.seenMs, nowMs);
    }

    // Entries not seen are out of hold; expire after 20 s out.
    final kept = <_Entry>[];
    final alerts = <TrafficAlert>[];
    for (final e in st._entries) {
      if (!e.visited) {
        e.a = e.a.copyWith(held: true);
        if (!e.out) {
          e.out = true;
          e.outSinceMs = nowMs;
        }
      }
      if (e.out && nowMs - e.outSinceMs >= clearMs) continue;
      kept.add(e);
      final di = e.a.droneId.isEmpty ? -1 : drones.indexWhere((d) => d.id == e.a.droneId);
      final ai = ac.indexWhere((x) => x.hex == e.a.hex && ageS(x.seenMs, nowMs) <= presentS);
      alerts.add(e.a.copyWith(
          ageS: ageS(e.seenMs, nowMs), droneIndex: () => di < 0 ? null : di, acIndex: () => ai < 0 ? null : ai));
    }
    st._entries
      ..clear()
      ..addAll(kept);
    // A warning for an aircraft supersedes its LOW (kept, not shown).
    final warned = {
      for (final x in alerts)
        if (x.kind != TrafficKind.low && x.level == TrafficLevel.warning) x.hex
    };
    alerts.removeWhere((x) => x.kind == TrafficKind.low && warned.contains(x.hex));
    alerts.sort(_cmp);
    return TrafficResult(
      alerts: alerts,
      haveData: haveData,
      stale: stale,
      dataAgeS: haveData ? dataAge : null,
      aircraftCount: aircraftCount,
    );
  }

  /// The conflict watch status, the one status line for every surface; it
  /// never counts aircraft and never claims the airspace is empty.
  static String summary(TrafficResult r) {
    if (!r.haveData) return 'CONFLICT WATCH OFF: no ADS-B source';
    final age = r.dataAgeS;
    if (age == null) return 'TRAFFIC DATA STALE, data age unknown';
    final a = (age + 0.5).floor();
    if (r.stale) return 'TRAFFIC DATA STALE, data $a s old';
    final n = r.alerts.length;
    if (n == 0) return 'conflict watch on, no ADS-B conflicts, data $a s old';
    final low = r.alerts.where((x) => x.kind == TrafficKind.low).length, conf = n - low;
    final l = low > 0 ? 'low traffic, ' : ''; // never a count of aircraft
    final c = conf > 0 ? '$conf ADS-B conflict${conf == 1 ? '' : 's'}, ' : '';
    return 'conflict watch on, $l${c}data $a s old';
  }
}

/// The `traffic` host lines (format: firmware/common/traffic.h).
class TrafficWire {
  /// A number (bools as 1/0) or NaN, like the firmware's reader.
  static double number(Object? v) {
    if (v is bool) return v ? 1.0 : 0.0;
    if (v is num) return v.toDouble();
    return double.nan;
  }

  static String _trimmed(String s, int max) {
    var t = s.replaceFirst(RegExp(r'^ +'), '');
    if (t.length > max) t = t.substring(0, max);
    return t.replaceFirst(RegExp(r' +$'), '');
  }

  static double? _opt(double v) => v.isNaN ? null : v;

  /// One wire aircraft object; null when unusable (no hex, no position, no
  /// finite age, older than 60 s). Mirrors traffic_parse_aircraft.
  static TrafficAircraft? aircraftFromWire(Map<String, dynamic> w, int nowMs) {
    var hex = '';
    final hs = w['hex'];
    if (hs is String) {
      for (final code in hs.codeUnits) {
        if (hex.length >= 6) break;
        var c = code;
        if (c >= 0x41 && c <= 0x46) c += 32; // A-F
        if ((c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66)) {
          hex += String.fromCharCode(c);
        } else if (c == 0x7E) {
          continue; // '~' marks a non-ICAO address
        } else {
          hex = '';
          break;
        }
      }
    }
    var lat = number(w['lat']);
    if (!(lat.isFinite && lat.abs() <= 90)) lat = double.nan;
    var lon = number(w['lon']);
    if (!(lon.isFinite && lon.abs() <= 180)) lon = double.nan;
    final gs = number(w['gs_kt']);
    var sq = 0;
    final sqv = w['sq'];
    if (sqv is String) {
      if (sqv.isNotEmpty && sqv.length <= 4 && sqv.codeUnits.every((c) => c >= 0x30 && c <= 0x37)) {
        sq = int.parse(sqv);
      }
    } else if (sqv is num) {
      final n = sqv.toDouble();
      if (n.isFinite && n >= 0 && n <= 7777) sq = n.truncate();
    }
    final emv = w['em'];
    final bool em;
    if (emv is String) {
      em = emv.isNotEmpty && emv != 'none' && emv != '0';
    } else {
      final n = number(emv);
      em = n.isFinite && n != 0;
    }
    var gnd = w['altb_ft'] == 'ground';
    if (w.containsKey('gnd')) {
      final g = w['gnd'];
      if (g is String) {
        gnd = g.isNotEmpty && g != '0' && g != 'false';
      } else {
        final n = number(g);
        gnd = n.isFinite && n != 0;
      }
    }
    final age = number(w['age_s']);
    if (hex.isEmpty || lat.isNaN || lon.isNaN || !(age >= 0) || age > TrafficRules.presentS) return null;
    return TrafficAircraft(
      hex: hex,
      callsign: _trimmed(w['cs'] is String ? w['cs'] as String : '', 8),
      type: _trimmed(w['ty'] is String ? w['ty'] as String : '', 4),
      lat: lat,
      lon: lon,
      altGeomM: _opt(number(w['altg_m'])),
      altBaroM: _opt(number(w['altb_ft']) * TrafficRules.ftToM),
      gsMps: gs >= 0 ? gs * TrafficRules.ktToMps : null,
      trackDeg: _opt(number(w['trk'])),
      vsMps: _opt(number(w['vr_fpm']) * TrafficRules.ftToM / 60.0),
      squawk: sq,
      emergency: em,
      onGround: gnd,
      seenMs: nowMs - (age * 1000).round(),
    );
  }

  /// The wire object for one aircraft (the inverse of [aircraftFromWire]).
  static Map<String, Object> toWire(TrafficAircraft a, int nowMs) {
    double r(double v, int places) => double.parse(v.toStringAsFixed(places));
    return {
      'hex': a.hex,
      if (a.callsign.isNotEmpty) 'cs': a.callsign,
      if (a.type.isNotEmpty) 'ty': a.type,
      'lat': r(a.lat, 6),
      'lon': r(a.lon, 6),
      if (a.altGeomM != null && a.altGeomM!.isFinite) 'altg_m': r(a.altGeomM!, 1),
      if (a.altBaroM != null && a.altBaroM!.isFinite) 'altb_ft': (a.altBaroM! / TrafficRules.ftToM).round(),
      if (a.gsMps != null && a.gsMps!.isFinite) 'gs_kt': r(a.gsMps! / TrafficRules.ktToMps, 1),
      if (a.trackDeg != null && a.trackDeg!.isFinite) 'trk': r(a.trackDeg!, 1),
      if (a.vsMps != null && a.vsMps!.isFinite) 'vr_fpm': (a.vsMps! * 60.0 / TrafficRules.ftToM).round(),
      if (a.squawk > 0) 'sq': a.squawk.toString().padLeft(4, '0'),
      if (a.emergency) 'em': 1,
      if (a.onGround) 'gnd': 1,
      'age_s': r(a.ageS(nowMs), 1),
    };
  }

  /// The lines to push to a receiver every 10 s while there is data (nearest
  /// first, at most 6 aircraft per line, then traffic_done; an empty set is
  /// just traffic_done). [dataAgeS]: how old the set is.
  static List<String> hostLines(List<TrafficAircraft> aircraft, int nowMs, int unixS, double dataAgeS) {
    final age = double.parse(math.max(0.0, dataAgeS).toStringAsFixed(1));
    final lines = <String>[];
    for (var i = 0; i < aircraft.length; i += 6) {
      final chunk = aircraft.sublist(i, math.min(i + 6, aircraft.length)).map((a) => toWire(a, nowMs)).toList();
      lines.add(jsonEncode({'cmd': 'traffic', 't': unixS, 'age_s': age, 'ac': chunk}));
    }
    lines.add(jsonEncode({'cmd': 'traffic_done', 'n': aircraft.length, 'age_s': age}));
    return lines;
  }
}

/// A receiver's side of the host lines (mirrors traffic_host_line /
/// traffic_ingest); used by the tests to pin the format in Dart too.
class TrafficHostFeed {
  TrafficObserver observer;
  List<TrafficAircraft> aircraft = const [];
  bool haveData = false;
  int dataMs = 0;
  bool partial = false;
  bool _open = false;
  int _t = 0;
  List<TrafficAircraft> _stage = [];
  int _rx = 0;
  double _stageAge = 0;

  TrafficHostFeed(this.observer);

  void _ingest(List<TrafficAircraft> list, int dataMs, int nowMs) {
    final pos = TrafficRules._known(observer.lat) && TrafficRules._known(observer.lon);
    final cand = <(double, int, TrafficAircraft)>[];
    for (var i = 0; i < list.length; i++) {
      final a = list[i];
      if (a.ageS(nowMs) > TrafficRules.presentS || !a.lat.isFinite || !a.lon.isFinite) continue;
      final d = pos ? TrafficRules.distanceM(observer.lat!, observer.lon!, a.lat, a.lon) : 0.0;
      if (pos && d > TrafficRules.keepRM) continue;
      cand.add((d, i, a));
    }
    cand.sort((x, y) => x.$1 != y.$1 ? x.$1.compareTo(y.$1) : x.$2.compareTo(y.$2));
    final taken = <TrafficAircraft>[];
    final seen = <String>{};
    for (final c in cand) {
      if (taken.length >= TrafficRules.maxAircraft) break;
      if (seen.add(c.$3.hex)) taken.add(c.$3); // one entry per hex, its nearest copy
    }
    aircraft = taken;
    haveData = true;
    this.dataMs = dataMs;
  }

  bool handle(String line, int nowMs) {
    if (!line.contains('"traffic')) return false;
    Map<String, dynamic> o;
    try {
      final v = jsonDecode(line);
      if (v is! Map<String, dynamic>) throw const FormatException();
      o = v;
    } catch (_) {
      return line.contains('"cmd":"traffic"') || line.contains('"cmd":"traffic_done"');
    }
    final cmd = o['cmd'];
    if (cmd == 'traffic') {
      final tv = TrafficWire.number(o['t']);
      final t = (tv.isFinite && tv > 0 && tv < 4294967295.0) ? tv.truncate() : 0;
      if (!_open || t != _t) {
        _open = true;
        _t = t;
        _stage = [];
        _rx = 0;
        _stageAge = 0;
      }
      if (o.containsKey('age_s')) _stageAge = TrafficWire.number(o['age_s']);
      final list = o['ac'];
      if (list is List) {
        for (final item in list) {
          if (item is! Map<String, dynamic>) break;
          _rx++;
          final a = TrafficWire.aircraftFromWire(item, nowMs);
          if (a != null && _stage.length < TrafficRules.maxAircraft) _stage.add(a);
        }
      }
      return true;
    }
    if (cmd == 'traffic_done') {
      var age = o.containsKey('age_s') ? TrafficWire.number(o['age_s']) : (_open ? _stageAge : 0.0);
      final list = _open ? _stage : <TrafficAircraft>[];
      final received = _open ? _rx : 0;
      final n = TrafficWire.number(o['n']);
      partial = o.containsKey('n') && n.isFinite && n.truncate() != received;
      if (!(age >= 0.0)) age = TrafficRules.staleS + 1.0;
      if (age > 86400.0) age = 86400.0;
      _ingest(list, nowMs - (age * 1000).round(), nowMs);
      _open = false;
      _stage = [];
      return true;
    }
    return false;
  }
}
