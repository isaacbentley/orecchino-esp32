// adsb_source.dart — manned aircraft from adsb.lol (plan §1, §8.1), and the
// set the phone keeps and evaluates (like the Mac's TrafficService.swift).
//
// ADS-B is only for drone-aircraft conflicts, so the query is small: 10 km
// around the phone by default (5-30 km, Detectors > Settings). A live drone
// more than 3 km from the phone moves the centre to the middle of the phone
// and the drones and widens the radius until every live drone has 9 km
// around it, up to 30 km (AdsbArea.plan, a port of the firmware's
// net_adsb_area in firmware/common/net_parse.h). Aircraft beyond the area
// are dropped.
//
// GET https://api.adsb.lol/v2/point/{lat}/{lon}/{radius} (radius in whole
// nautical miles, rounded up; the readsb convention) answers
// {"ac":[...],"now":...}.
// Each aircraft is mapped onto the `traffic` wire object and parsed by
// TrafficWire.aircraftFromWire, so the phone keeps exactly what a receiver
// would (hex, position, age <= 60 s). The query position is rounded to
// 0.01° (about 1 km): the service learns the phone's area, not its spot.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'traffic_rules.dart';

/// Where to ask for aircraft: a centre and a radius in metres.
class AdsbArea {
  static const defaultKm = 10, minKm = 5, maxKm = 30;
  static const droneFarM = 3000.0; // a drone this far from the phone moves the centre
  static const droneCoverM = 9000.0; // ...and gets this much around it

  final double lat, lon, radiusM;
  const AdsbArea(this.lat, this.lon, this.radiusM);

  /// The phone and [baseM], unless a live drone is more than 3 km from the
  /// phone; then the centre of the box around the phone and the live
  /// drones, and a radius giving every live drone 9 km (at least [baseM],
  /// at most [maxM]). [drones]: live drones with a position.
  static AdsbArea plan(double homeLat, double homeLon, List<(double, double)> drones, double baseM,
      {double maxM = maxKm * 1000.0}) {
    var lat = homeLat, lon = homeLon, r = baseM;
    final far = drones.any((d) => TrafficRules.distanceM(homeLat, homeLon, d.$1, d.$2) > droneFarM);
    if (far) {
      // The box in metres east/north of the phone (antimeridian-safe).
      double x0 = 0, x1 = 0, y0 = 0, y1 = 0;
      for (final d in drones) {
        final dist = TrafficRules.distanceM(homeLat, homeLon, d.$1, d.$2);
        final b = TrafficRules.bearingDeg(homeLat, homeLon, d.$1, d.$2) * TrafficRules.deg;
        final dx = dist * math.sin(b), dy = dist * math.cos(b);
        x0 = math.min(x0, dx);
        x1 = math.max(x1, dx);
        y0 = math.min(y0, dy);
        y1 = math.max(y1, dy);
      }
      final cx = (x0 + x1) / 2, cy = (y0 + y1) / 2;
      lat = homeLat + cy / (TrafficRules.earthRM * TrafficRules.deg);
      final k = math.cos(homeLat * TrafficRules.deg);
      lon = homeLon + cx / (TrafficRules.earthRM * TrafficRules.deg * (k < 0.01 ? 0.01 : k));
      if (lon > 180) {
        lon -= 360;
      } else if (lon < -180) {
        lon += 360;
      }
      for (final d in drones) {
        final need = TrafficRules.distanceM(lat, lon, d.$1, d.$2) + droneCoverM;
        if (need > r) r = need;
      }
    }
    return AdsbArea(lat, lon, math.min(r, maxM));
  }

  /// The adsb.lol radius: whole nautical miles, rounded up.
  int get radiusNm => (radiusM / 1852.0 - 1e-9).ceil();

  bool contains(double lat2, double lon2) => TrafficRules.distanceM(lat, lon, lat2, lon2) <= radiusM;
}

class AdsbSource {
  static const defaultBase = 'https://api.adsb.lol/v2/point';
  static const fetchEvery = Duration(seconds: 10);

  final http.Client client;
  final String base;

  AdsbSource({http.Client? client, this.base = defaultBase}) : client = client ?? http.Client();

  /// The query URL; the centre is rounded to 0.01 degree (about 1 km).
  static Uri urlFor(String base, AdsbArea area) {
    String r(double v) => v.toStringAsFixed(2);
    return Uri.parse('$base/${r(area.lat)}/${r(area.lon)}/${area.radiusNm}');
  }

  /// Fetch the aircraft in [area]. Throws on a network or HTTP error.
  Future<List<TrafficAircraft>> fetch(AdsbArea area, int nowMs) async {
    final res = await client
        .get(urlFor(base, area), headers: const {'Accept': 'application/json'}).timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) throw http.ClientException('adsb.lol answered ${res.statusCode}');
    return parse(res.body, nowMs);
  }

  /// The adsb.lol answer as aircraft, unusable ones dropped.
  static List<TrafficAircraft> parse(String body, int nowMs) {
    final v = jsonDecode(body);
    if (v is! Map<String, dynamic>) return const [];
    final ac = v['ac'];
    if (ac is! List) return const [];
    final out = <TrafficAircraft>[];
    for (final a in ac) {
      if (a is! Map<String, dynamic>) continue;
      final w = wireFromAdsbLol(a);
      final t = TrafficWire.aircraftFromWire(w, nowMs);
      if (t != null) out.add(t);
    }
    return out;
  }

  /// One adsb.lol (readsb) aircraft as the `traffic` wire object.
  static Map<String, dynamic> wireFromAdsbLol(Map<String, dynamic> a) {
    num? n(Object? x) => x is num && x.isFinite ? x : null;
    final altGeomFt = n(a['alt_geom']);
    final altBaro = a['alt_baro']; // feet, or "ground"
    final rate = n(a['baro_rate']) ?? n(a['geom_rate']);
    final flight = a['flight'];
    final type = a['t'];
    return {
      'hex': a['hex'],
      if (flight is String) 'cs': flight.trim(),
      if (type is String) 'ty': type,
      'lat': a['lat'],
      'lon': a['lon'],
      if (altGeomFt != null) 'altg_m': altGeomFt * TrafficRules.ftToM,
      if (altBaro is num) 'altb_ft': altBaro,
      if (altBaro == 'ground') 'gnd': 1, // taxiing / parked
      if (n(a['gs']) != null) 'gs_kt': a['gs'],
      if (n(a['track']) != null) 'trk': a['track'],
      if (rate != null) 'vr_fpm': rate,
      if (a['squawk'] is String) 'sq': a['squawk'],
      if (a['emergency'] != null) 'em': a['emergency'],
      'age_s': n(a['seen_pos']) ?? n(a['seen']),
    };
  }

  void close() => client.close();
}

/// The phone's aircraft set and its evaluation (the Mac's TrafficService).
class TrafficMonitor {
  List<TrafficAircraft> aircraft = const [];
  int? dataMs; // when the set was fetched; null: no source
  AdsbArea? area; // where it was asked for
  TrafficResult result = TrafficResult.empty;
  TrafficState _state = TrafficState();

  /// Install a fetched set: at most 32, none outside [area], nearest its
  /// centre first (as a receiver keeps them).
  void update(List<TrafficAircraft> list, int fetchedMs, AdsbArea area) {
    final cand = <(double, TrafficAircraft)>[];
    for (final a in list) {
      final d = TrafficRules.distanceM(area.lat, area.lon, a.lat, a.lon);
      if (d > area.radiusM) continue;
      cand.add((d, a));
    }
    cand.sort((x, y) => x.$1.compareTo(y.$1));
    aircraft = cand.take(TrafficRules.maxAircraft).map((c) => c.$2).toList();
    dataMs = fetchedMs;
    this.area = area;
  }

  /// [observer] feeds LOW (UAS airspace around you); the pairs use the drones.
  TrafficResult tick({required int nowMs, required TrafficObserver observer, required List<TrafficDrone> drones}) {
    result = TrafficRules.evaluate(
        drones: drones, aircraft: aircraft, observer: observer, dataMs: dataMs, nowMs: nowMs, state: _state);
    return result;
  }

  TrafficAircraft? byHex(String hex) {
    for (final a in aircraft) {
      if (a.hex == hex) return a;
    }
    return null;
  }

  void clear() {
    aircraft = const [];
    dataMs = null;
    area = null;
    result = TrafficResult.empty;
    _state = TrafficState();
  }
}
