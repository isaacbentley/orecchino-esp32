// traffic_rules_test.dart — TrafficRules against every shared vector in
// tests/vectors/traffic/*.json (the same files tests/traffic_test.cpp and
// app/Tests/OrecchinoTests/TrafficRulesTests.swift load). Wire aircraft go
// through TrafficWire.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orecchino_mobile/core/traffic/adsb_source.dart';
import 'package:orecchino_mobile/core/traffic/traffic_rules.dart';

/// Banned words: 'clear' only as the instruction 'KEEP CLEAR OF'; 'conflict'
/// only in 'conflict watch' / 'ADS-B conflict(s)', never 'conflict resolved'.
bool forbidden(String s) {
  final l = s.toLowerCase().replaceAll('keep clear of', '');
  return ['collision', 'safe', 'clear', 'tcas', 'conflict resolved', 'no traffic'].any(l.contains);
}

double? dbl(Object? v) => v is num ? v.toDouble() : null;

bool close(double? got, Object? want, double tol) {
  final w = dbl(want);
  if (got == null || w == null) return got == null && w == null;
  return (got - w).abs() <= tol;
}

TrafficObserver observerOf(Object? v) {
  if (v is! Map<String, dynamic>) return TrafficObserver.unknown;
  return TrafficObserver(lat: dbl(v['lat']), lon: dbl(v['lon']), elevM: dbl(v['elev_m']));
}

/// The vector's 'hand_checks': numbers derived by hand from the scenario
/// (right triangles, the CPA formula), never from an implementation, so a
/// geometry slip shared by all three ports still fails. horiz/vert within
/// tol_m (0.5 m unless given), bearing within 0.05 deg, cpa within 0.05 s; a
/// null field must be unknown; an absent one is not checked.
int runHandChecks(String ctx, Map<String, dynamic> v, double ts, TrafficResult r) {
  var n = 0;
  for (final c in ((v['hand_checks'] ?? const <dynamic>[]) as List<dynamic>).cast<Map<String, dynamic>>()) {
    if (dbl(c['t_s']) != ts) continue;
    final m = r.alerts
        .where((a) =>
            a.hex == c['hex'] &&
            (!c.containsKey('drone') || a.droneId == c['drone']) &&
            (!c.containsKey('kind') || a.kind.name == c['kind']))
        .toList();
    expect(m, hasLength(1), reason: '$ctx: hand check ${c['hex']} finds one alert');
    if (m.length != 1) continue;
    final a = m.single;
    final tol = dbl(c['tol_m']) ?? 0.5;
    if (c.containsKey('horiz_m')) {
      expect(close(a.horizM, c['horiz_m'], tol), isTrue, reason: '$ctx: hand ${a.hex} horiz ${a.horizM} want ${c['horiz_m']}');
    }
    if (c.containsKey('vert_m')) {
      expect(close(a.vertM, c['vert_m'], tol), isTrue, reason: '$ctx: hand ${a.hex} vert ${a.vertM} want ${c['vert_m']}');
    }
    if (c.containsKey('bearing_deg')) {
      expect(close(a.bearingDeg, c['bearing_deg'], 0.05), isTrue,
          reason: '$ctx: hand ${a.hex} bearing ${a.bearingDeg} want ${c['bearing_deg']}');
    }
    if (c.containsKey('cpa_s')) {
      expect(close(a.cpaS, c['cpa_s'], 0.05), isTrue, reason: '$ctx: hand ${a.hex} cpa ${a.cpaS} want ${c['cpa_s']}');
    }
    n++;
  }
  return n;
}

int handChecked = 0;

int runRules(String file, Map<String, dynamic> v, List<dynamic> steps) {
  final state = TrafficState();
  var checked = 0;
  for (final step in steps.cast<Map<String, dynamic>>()) {
    final ts = dbl(step['t_s'])!;
    final ctx = '$file t=$ts';
    final now = 1000000 + (ts * 1000).round();
    final dj = (step['drones'] ?? v['drones'] ?? const <dynamic>[]) as List<dynamic>;
    final drones = dj
        .cast<Map<String, dynamic>>()
        .map((d) => TrafficDrone(
              id: d['id'] as String? ?? '',
              lat: dbl(d['lat']),
              lon: dbl(d['lon']),
              altGeoM: dbl(d['alt_geo_m']),
              speedMps: dbl(d['speed_mps']),
              headingDeg: dbl(d['heading_deg']),
              live: d['live'] == true,
              heightM: dbl(d['height_m']),
            ))
        .toList();
    final obs = observerOf(step['observer'] ?? v['observer']);
    final aircraft = <TrafficAircraft>[];
    for (final w in (step['aircraft'] as List<dynamic>).cast<Map<String, dynamic>>()) {
      final a = TrafficWire.aircraftFromWire(w, now);
      expect(a, isNotNull, reason: '$ctx: aircraft ${w['hex']} parses');
      if (a != null) aircraft.add(a);
    }
    final da = dbl(step['data_age_s']);
    final dataMs = da == null ? null : now - (da * 1000).round();
    final r = TrafficRules.evaluate(
        drones: drones, aircraft: aircraft, observer: obs, dataMs: dataMs, nowMs: now, state: state);
    final e = step['expect'] as Map<String, dynamic>;
    expect(r.haveData, e['have_data'], reason: '$ctx: have_data');
    expect(r.stale, e['stale'], reason: '$ctx: stale');
    expect(r.highest.name, e['highest'], reason: '$ctx: highest');
    expect(r.aircraftCount, e['aircraft_count'], reason: '$ctx: aircraft_count');
    expect(r.summary, e['summary'], reason: '$ctx: summary');
    expect(forbidden(r.summary), isFalse);
    final want = (e['alerts'] as List<dynamic>).cast<Map<String, dynamic>>();
    expect(r.alerts.map((a) => a.text).toList(), want.map((w) => w['text']).toList(), reason: '$ctx: alerts');
    for (var i = 0; i < r.alerts.length && i < want.length; i++) {
      final a = r.alerts[i], w = want[i];
      final c = '$ctx #$i';
      expect(a.level.name, w['level'], reason: '$c: level');
      expect(a.kind.name, w['kind'], reason: '$c: kind');
      expect(a.droneId, w['drone'], reason: '$c: drone');
      expect(a.hex, w['hex'], reason: '$c: hex');
      expect(a.held, w['held'], reason: '$c: held');
      expect(a.heightUnknown, w['height_unknown'], reason: '$c: height_unknown');
      expect(a.vertRel.name, w['vert_rel'], reason: '$c: vert_rel');
      expect(a.approx, w['approx'], reason: '$c: approx');
      expect(a.fromObserver, w['from_observer'], reason: '$c: from_observer');
      expect(a.action, w['action'], reason: '$c: action');
      expect(a.resolution, w['resolution'], reason: '$c: resolution');
      expect(a.resolution.startsWith(a.action) && !forbidden(a.resolution), isTrue, reason: '$c: resolution words');
      expect(a.onGround, w['on_ground'], reason: '$c: on_ground');
      expect(close(a.horizM, w['horiz_m'], 1e-6), isTrue, reason: '$c: horiz ${a.horizM}');
      expect(close(a.vertM, w['vert_m'], 1e-6), isTrue, reason: '$c: vert ${a.vertM}');
      expect(close(a.bearingDeg, w['bearing_deg'], 1e-6), isTrue, reason: '$c: bearing');
      expect(close(a.cpaS, w['cpa_s'], 1e-6), isTrue, reason: '$c: cpa ${a.cpaS}');
      expect(close(a.ageS, w['age_s'], 1e-9), isTrue, reason: '$c: age');
      expect(forbidden(a.text), isFalse);
      if (a.acIndex != null) expect(aircraft[a.acIndex!].hex, a.hex);
      if (a.droneIndex != null) expect(drones[a.droneIndex!].id, a.droneId);
      checked++;
    }
    handChecked += runHandChecks(ctx, v, ts, r);
  }
  return checked;
}

int runHostLines(String file, Map<String, dynamic> v) {
  final now = (v['now_ms'] as num).toInt();
  final cases = (v['cases'] as List<dynamic>).cast<Map<String, dynamic>>();
  for (var k = 0; k < cases.length; k++) {
    final c = cases[k];
    final ctx = '$file case $k';
    final feed = TrafficHostFeed(observerOf(c['observer']));
    final e = c['expect'] as Map<String, dynamic>;
    final lines = (c['lines'] as List<dynamic>).cast<String>();
    final handled = (e['handled'] as List<dynamic>).cast<bool>();
    for (var i = 0; i < lines.length; i++) {
      expect(feed.handle(lines[i], now), handled[i], reason: '$ctx: line $i handled');
    }
    expect(feed.haveData, e['have_data'], reason: '$ctx: have_data');
    expect(feed.partial, e['partial'], reason: '$ctx: partial');
    expect(feed.aircraft.length, e['count'], reason: '$ctx: count');
    if (feed.haveData) {
      expect(close(TrafficRules.ageS(feed.dataMs, now), e['data_age_s'], 1e-9), isTrue, reason: '$ctx: data age');
    }
    final want = (e['aircraft'] as List<dynamic>).cast<Map<String, dynamic>>();
    for (var i = 0; i < feed.aircraft.length && i < want.length; i++) {
      final a = feed.aircraft[i], w = want[i];
      final cc = '$ctx #$i';
      expect(a.hex, w['hex'], reason: '$cc: hex');
      expect(a.callsign, w['callsign'], reason: '$cc: callsign');
      expect(a.type, w['type'], reason: '$cc: type');
      expect(close(a.lat, w['lat'], 1e-12) && close(a.lon, w['lon'], 1e-12), isTrue, reason: '$cc: position');
      expect(close(a.altGeomM, w['alt_geom_m'], 1e-9), isTrue, reason: '$cc: alt_geom');
      expect(close(a.altBaroM, w['alt_baro_m'], 1e-9), isTrue, reason: '$cc: alt_baro');
      expect(close(a.gsMps, w['gs_mps'], 1e-9), isTrue, reason: '$cc: gs');
      expect(close(a.trackDeg, w['track_deg'], 1e-9), isTrue, reason: '$cc: track');
      expect(close(a.vsMps, w['vs_mps'], 1e-9), isTrue, reason: '$cc: vs');
      expect(a.squawk, w['squawk'], reason: '$cc: squawk');
      expect(a.emergency, w['emergency'], reason: '$cc: emergency');
      expect(a.onGround, w['on_ground'], reason: '$cc: on_ground');
      expect(close(a.ageS(now), w['age_s'], 1e-9), isTrue, reason: '$cc: age');
    }
    // What this app would push for the same set parses back to it.
    if (feed.aircraft.isNotEmpty) {
      final back = TrafficHostFeed(observerOf(c['observer']));
      for (final l in TrafficWire.hostLines(feed.aircraft, now, 1727000000, 2)) {
        expect(utf8.encode(l).length, lessThan(1600), reason: '$ctx: line length');
        expect(back.handle(l, now), isTrue);
      }
      expect(back.aircraft.map((a) => a.hex).toList(), feed.aircraft.map((a) => a.hex).toList(),
          reason: '$ctx: round trip');
      expect(back.partial, isFalse);
      for (var i = 0; i < back.aircraft.length; i++) {
        final a = back.aircraft[i], b = feed.aircraft[i];
        expect(a.squawk == b.squawk && a.emergency == b.emergency && a.callsign == b.callsign, isTrue);
        expect(a.onGround, b.onGround);
        expect((a.lat - b.lat).abs() < 1e-6 && ((a.gsMps ?? 0) - (b.gsMps ?? 0)).abs() < 0.05, isTrue);
      }
    }
  }
  return cases.length;
}

void main() {
  test('every shared traffic vector file', () {
    final dir = Directory('../tests/vectors/traffic');
    final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    expect(files.length, greaterThanOrEqualTo(16));
    var ruleFiles = 0, steps = 0, alerts = 0, cases = 0;
    handChecked = 0;
    for (final f in files) {
      final name = f.uri.pathSegments.last;
      final v = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      if (v.containsKey('cases')) {
        cases += runHostLines(name, v);
      } else if (v.containsKey('steps')) {
        ruleFiles++;
        final st = v['steps'] as List<dynamic>;
        steps += st.length;
        alerts += runRules(name, v, st);
      } else {
        fail('$name: unknown vector shape');
      }
    }
    expect(ruleFiles >= 15 && steps >= 60 && alerts >= 180 && cases >= 9 && handChecked >= 40, isTrue,
        reason: 'coverage: $ruleFiles rule files, $steps steps, $alerts alerts, $cases host cases, $handChecked hand checks');
  });

  test('the phone keeps aircraft an answer omits while under 60 s, like the Mac', () {
    // adsb.lol drops an aircraft from one answer now and then; the Mac's
    // install() keeps it (its alert then holds up to 60 + 20 s, not 20 s).
    final m = TrafficMonitor();
    const area = AdsbArea(37.8, -122.46, 10000);
    const t0 = 1000000;
    m.update(const [
      TrafficAircraft(hex: 'a1', lat: 37.81, lon: -122.46, seenMs: t0 - 1000),
      TrafficAircraft(hex: 'b2', lat: 37.82, lon: -122.46, seenMs: t0 - 1000),
    ], t0, area);
    // The next answer omits a1: kept (11 s old); b2's newer position wins.
    m.update(const [TrafficAircraft(hex: 'b2', lat: 37.82, lon: -122.46, seenMs: t0 + 9000)], t0 + 10000, area);
    expect(m.aircraft.map((a) => a.hex).toList(), ['a1', 'b2']);
    expect(m.byHex('b2')!.seenMs, t0 + 9000);
    // An older copy never replaces a newer one.
    m.update(const [TrafficAircraft(hex: 'b2', lat: 37.82, lon: -122.46, seenMs: t0 + 5000)], t0 + 20000, area);
    expect(m.byHex('b2')!.seenMs, t0 + 9000);
    // Past 60 s an omitted aircraft is gone (a1 at 62 s; b2 at 52 s stays).
    m.update(const [], t0 + 61000, area);
    expect(m.aircraft.map((a) => a.hex).toList(), ['b2']);
    m.update(const [], t0 + 70000, area);
    expect(m.aircraft, isEmpty);
    expect(m.dataMs, t0 + 70000);
  });

  test('antimeridian distance wraps', () {
    // The old flat-earth code measured 24,643 km here.
    final d = TrafficRules.distanceM(52.0, 179.99, 52.0, -179.99);
    expect(d, inInclusiveRange(1300, 1400));
  });

  test('no source and empty set wording', () {
    final st = TrafficState();
    final none = TrafficRules.evaluate(drones: const [], aircraft: const [], dataMs: null, nowMs: 10000, state: st);
    expect(none.summary, 'CONFLICT WATCH OFF: no ADS-B source');
    final empty = TrafficRules.evaluate(drones: const [], aircraft: const [], dataMs: 9000, nowMs: 10000, state: st);
    expect(empty.summary, 'conflict watch on, no ADS-B conflicts, data 1 s old');
  });
}
