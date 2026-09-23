// adsb_source.dart — manned aircraft from adsb.lol (plan §1, §8.1), and the
// set the phone keeps and evaluates (like the Mac's TrafficService.swift).
//
// GET https://api.adsb.lol/v2/point/{lat}/{lon}/{radius} (radius in
// nautical miles, the readsb convention) answers {"ac":[...],"now":...}.
// Each aircraft is mapped onto the `traffic` wire object and parsed by
// TrafficWire.aircraftFromWire, so the phone keeps exactly what a receiver
// would (hex, position, age <= 60 s). The query position is rounded to
// 0.01° (about 1 km): the service learns the phone's area, not its spot.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../geo.dart';
import 'traffic_rules.dart';

class AdsbSource {
  static const defaultBase = 'https://api.adsb.lol/v2/point';
  static const radiusNm = 16; // ~30 km, the rules' keep radius
  static const fetchEvery = Duration(seconds: 10);

  final http.Client client;
  final String base;

  AdsbSource({http.Client? client, this.base = defaultBase}) : client = client ?? http.Client();

  static Uri urlFor(String base, double lat, double lon) {
    String r(double v) => v.toStringAsFixed(2);
    return Uri.parse('$base/${r(lat)}/${r(lon)}/$radiusNm');
  }

  /// Fetch around (lat, lon). Throws on a network or HTTP error.
  Future<List<TrafficAircraft>> fetch(double lat, double lon, int nowMs) async {
    final res = await client
        .get(urlFor(base, lat, lon), headers: const {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 8));
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
  TrafficResult result = TrafficResult.empty;
  TrafficState _state = TrafficState();

  /// Install a fetched set: at most 32, within 30 km of the observer,
  /// nearest first (as a receiver keeps them).
  void update(List<TrafficAircraft> list, int fetchedMs, {double? obsLat, double? obsLon}) {
    final pos = obsLat != null && obsLon != null;
    final cand = <(double, TrafficAircraft)>[];
    for (final a in list) {
      final d = pos ? Geo.distanceM(obsLat, obsLon, a.lat, a.lon) : 0.0;
      if (pos && d > TrafficRules.keepRM) continue;
      cand.add((d, a));
    }
    cand.sort((x, y) => x.$1.compareTo(y.$1));
    aircraft = cand.take(TrafficRules.maxAircraft).map((c) => c.$2).toList();
    dataMs = fetchedMs;
  }

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
    result = TrafficResult.empty;
    _state = TrafficState();
  }
}
