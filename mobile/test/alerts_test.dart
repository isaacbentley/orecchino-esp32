// alerts_test.dart — notification policy (rate limit, mute, held alerts,
// drone alerts only with a detector), the words (plan §8.4), and the
// adsb.lol mapping onto the traffic wire format.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:orecchino_mobile/core/alerts/alert_policy.dart';
import 'package:orecchino_mobile/core/live/contact_tracker.dart';
import 'package:orecchino_mobile/core/protocol/messages.dart';
import 'package:orecchino_mobile/core/traffic/adsb_source.dart';
import 'package:orecchino_mobile/core/traffic/traffic_rules.dart';

bool forbidden(String s) {
  final l = s.toLowerCase();
  return ['collision', 'conflict', 'safe', 'clear', 'tcas', ' nm', 'tau'].any(l.contains);
}

const now = 1000000000;
const ac = TrafficAircraft(
  hex: 'a1b2c3',
  callsign: 'UAL123',
  type: 'B738',
  lat: 37.8139,
  lon: -122.4540,
  altGeomM: 820,
  altBaroM: 2650 * TrafficRules.ftToM,
  gsMps: 180 * TrafficRules.ktToMps,
  trackDeg: 270,
  vsMps: -640 * TrafficRules.ftToM / 60,
  seenMs: now - 6000,
);

TrafficAlert near({bool held = false, double? vert = 90}) => TrafficAlert(
      level: TrafficLevel.warning,
      kind: TrafficKind.near,
      held: held,
      droneId: '1581F20000D9A03',
      hex: 'a1b2c3',
      callsign: 'UAL123',
      horizM: 1100,
      vertM: vert,
      bearingDeg: 45,
      ageS: 6,
      text: 'TRAFFIC NEAR DRONE D9A03',
    );

void main() {
  group('words', () {
    test('notification title and body as in plan §8.4', () {
      expect(AlertWords.title(near()), 'Traffic near drone D9A03');
      expect(AlertWords.body(near(), ac), 'B738 UAL123 · 2,650 ft · 1.1 km NE of the drone · 90 m above it · reported 6 s ago');
      expect(AlertWords.body(near(vert: null), ac), contains('height unknown'));
      expect(forbidden(AlertWords.body(near(), ac)), isFalse);
    });

    test('spoken callout: clock position from the phone, km, feet, trend', () {
      // The aircraft is 38° from the phone: facing north, 1 o'clock; facing
      // east, 10 o'clock.
      final s = AlertWords.spoken(ac, 37.8039, -122.4640, 0);
      expect(s, "Traffic, 1 o'clock, 1.4 kilometres, 2,600 feet, descending.");
      expect(AlertWords.spoken(ac, 37.8039, -122.4640, 330), startsWith("Traffic, 2 o'clock"));
      expect(AlertWords.clockFromPhone(ac, 37.8039, -122.4640, 90), "10 o'clock · 1.4 km from you");
      expect(AlertWords.clockFromPhone(ac, null, null, 0), isNull);
      expect(forbidden(s), isFalse);
    });
  });

  group('policy', () {
    TrafficResult result(List<TrafficAlert> a) => TrafficResult(alerts: a, haveData: true, dataAgeS: 6);

    test('once per pair per 5 minutes; held alerts never notify', () {
      final p = AlertPolicy();
      List<AlertEvent> at(int t, List<TrafficAlert> a) => p.consider(
          nowMs: t, traffic: result(a), aircraft: (_) => ac, drones: const [], detectorConnected: true);
      expect(at(now, [near()]), hasLength(1));
      expect(at(now + 1000, [near()]), isEmpty);
      expect(at(now + 299000, [near()]), isEmpty);
      expect(at(now + 300000, [near()]).single.timeSensitive, isTrue);
      final p2 = AlertPolicy();
      expect(
          p2.consider(
              nowMs: now, traffic: result([near(held: true)]), aircraft: (_) => ac, drones: const [], detectorConnected: true),
          isEmpty);
    });

    test('mute 10 min silences, then alerts resume', () {
      final p = AlertPolicy()..mute(now);
      List<AlertEvent> at(int t) => p.consider(
          nowMs: t, traffic: result([near()]), aircraft: (_) => ac, drones: const [], detectorConnected: true);
      expect(at(now + 599000), isEmpty);
      expect(at(now + 600000), hasLength(1));
    });

    test('drone alerts: emergency and invalid signature, only with a detector connected', () {
      final tr = ContactTracker();
      final c = tr.ingest(
          HostMessage.parse(jsonEncode({
            'type': 'rid',
            'src': 'ble',
            'mac': 'AA:BB:CC:DD:EE:FF',
            'basic_id': [
              {'id_type': 1, 'ua_type': 2, 'uas_id': '1581F20000D9A03'}
            ],
            'loc': {'status': 3, 'lat': 37.81, 'lon': -122.46, 'alt_geo': 100.0, 'height': 50.0, 'height_ref': 0},
          })) as RidMessage,
          now,
          const ObserverFix(37.8039, -122.4640))!;
      final p = AlertPolicy();
      expect(
          p.consider(nowMs: now, traffic: TrafficResult.empty, aircraft: (_) => null, drones: [c], detectorConnected: false),
          isEmpty);
      final e = p
          .consider(nowMs: now, traffic: TrafficResult.empty, aircraft: (_) => null, drones: [c], detectorConnected: true)
          .single;
      expect(e.title, 'EMERGENCY REPORTED · D9A03');
      expect(e.source, AlertSource.drone);
      expect(forbidden(e.body), isFalse);
      // Stale contacts do not notify.
      final p2 = AlertPolicy();
      expect(
          p2.consider(
              nowMs: now + 61000, traffic: TrafficResult.empty, aircraft: (_) => null, drones: [c], detectorConnected: true),
          isEmpty);
    });
  });

  group('adsb.lol', () {
    test('an answer maps onto the traffic wire format', () {
      final body = jsonEncode({
        'now': 1790000000000,
        'total': 3,
        'ac': [
          {
            'hex': 'A1B2C3',
            'flight': 'UAL123  ',
            't': 'B738',
            'lat': 37.8,
            'lon': -122.4,
            'alt_baro': 2650,
            'alt_geom': 2700,
            'gs': 180.2,
            'track': 270.5,
            'baro_rate': -640,
            'squawk': '7700',
            'emergency': 'general',
            'seen_pos': 3.2,
            'seen': 0.4,
          },
          {'hex': '~2d0001', 'lat': 37.7, 'lon': -122.3, 'alt_baro': 'ground', 'seen': 1.0},
          {'hex': 'c0ffee', 'alt_baro': 3000, 'seen': 1}, // no position: dropped
          {'hex': 'bad', 'lat': 37.7, 'lon': -122.3, 'seen_pos': 90}, // older than 60 s: dropped
        ],
      });
      final list = AdsbSource.parse(body, now);
      expect(list, hasLength(2));
      final a = list.first;
      expect(a.hex, 'a1b2c3');
      expect(a.callsign, 'UAL123');
      expect(a.type, 'B738');
      expect(a.altGeomM, closeTo(2700 * 0.3048, 0.01));
      expect(a.altBaroM, closeTo(2650 * 0.3048, 0.01));
      expect(a.gsMps, closeTo(180.2 * 1852 / 3600, 0.01));
      expect(a.vsMps, closeTo(-640 * 0.3048 / 60, 0.001));
      expect(a.squawk, 7700);
      expect(a.emergency, isTrue);
      expect(a.seenMs, now - 3200);
      final g = list[1];
      expect(g.hex, '2d0001'); // '~' marks a non-ICAO address
      expect(g.altBaroM, isNull); // "ground" is not a number
      expect(g.altGeomM, isNull);
    });

    test('the query rounds the position to about 1 km', () {
      expect(AdsbSource.urlFor(AdsbSource.defaultBase, 37.80391234, -122.46401234).toString(),
          'https://api.adsb.lol/v2/point/37.80/-122.46/16');
    });

    test('the monitor keeps 32 within 30 km, nearest first', () {
      final m = TrafficMonitor();
      final many = [
        for (var i = 0; i < 40; i++)
          TrafficAircraft(hex: i.toRadixString(16).padLeft(6, '0'), lat: 37.8 + i * 0.005, lon: -122.46, seenMs: now),
        const TrafficAircraft(hex: 'ffffff', lat: 38.5, lon: -122.46, seenMs: now), // ~78 km
      ];
      m.update(many, now, obsLat: 37.8, obsLon: -122.46);
      expect(m.aircraft, hasLength(TrafficRules.maxAircraft));
      expect(m.aircraft.first.hex, '000000');
      expect(m.aircraft.any((a) => a.hex == 'ffffff'), isFalse);
      expect(m.dataMs, now);
    });
  });
}
