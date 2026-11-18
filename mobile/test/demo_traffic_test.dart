// demo_traffic_test.dart — the demo's made-up aircraft run the alert path:
// over its 6-minute cycle the Cessna comes near drone 1 (a warning, with
// low traffic before and after it), the helicopter crosses low north of
// you (low traffic only), and there are quiet stretches in between.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:orecchino_mobile/core/ble/simulated_detector.dart';
import 'package:orecchino_mobile/core/traffic/adsb_source.dart';
import 'package:orecchino_mobile/core/traffic/traffic_rules.dart';

void main() {
  test('the demo produces a warning pair, low traffic and quiet time', () {
    final sim = SimulatedDetector();
    const lat0 = SimulatedDetector.centerLat, lon0 = SimulatedDetector.centerLon;
    final area = AdsbArea.plan(lat0, lon0, const [], 10000);
    final monitor = TrafficMonitor();
    const t0 = 1790000000 * 1000 - (1790000000 % 360) * 1000; // a cycle's start
    final kinds = <String>{};
    var quiet = 0;
    for (var s = 0; s < 720; s++) {
      final now = t0 + s * 1000;
      final a = s * 0.05; // the simulator's drone 1 angle, 0.05 rad a second
      final drones = [
        TrafficDrone(
          id: '1581F204C68D9A11',
          lat: lat0 + 0.005 * math.cos(a),
          lon: lon0 + 0.006 * math.sin(a),
          altGeoM: 120,
          heightM: 100,
          speedMps: 12,
          headingDeg: ((a * 180 / math.pi) + 90) % 360,
          live: true,
        ),
        const TrafficDrone(
            id: '1581F999E412A002', lat: lat0 - 0.003, lon: lon0 + 0.004, altGeoM: 60, heightM: 50, live: true),
      ];
      if (s % 10 == 0) monitor.update(sim.demoAircraft(now), now, area);
      final r =
          monitor.tick(nowMs: now, observer: const TrafficObserver(lat: lat0, lon: lon0, elevM: 10), drones: drones);
      if (r.alerts.isEmpty) quiet++;
      for (final al in r.alerts) {
        kinds.add('${al.kind.name}:${al.hex}:${al.level.name}');
        expect(al.action, isNotEmpty);
      }
    }
    expect(kinds, contains('near:a1b2c3:warning'));
    expect(kinds, contains('low:a1b2c3:caution'));
    expect(kinds, contains('low:a7c0de:caution'));
    expect(kinds.where((k) => k.contains('a7c0de') && !k.startsWith('low')), isEmpty);
    expect(quiet, greaterThan(60)); // at least a minute a cycle with nothing to show
  });
}
