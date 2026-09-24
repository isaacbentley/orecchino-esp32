// alerts_test.dart — notification policy (rate limit, mute, held alerts,
// drone alerts only with a detector), the words (the action first, then the
// geometry and the rule), the adsb.lol mapping onto the traffic wire
// format, and where the phone asks for aircraft (AdsbArea).
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:orecchino_mobile/core/alerts/alert_policy.dart';
import 'package:orecchino_mobile/core/live/contact_tracker.dart';
import 'package:orecchino_mobile/core/protocol/messages.dart';
import 'package:orecchino_mobile/core/traffic/adsb_source.dart';
import 'package:orecchino_mobile/core/traffic/traffic_rules.dart';
import 'package:orecchino_mobile/core/traffic/traffic_words.dart';

bool forbidden(String s) {
  final l = s.toLowerCase().replaceAll('keep clear of', '');
  return ['collision', 'conflict resolved', 'safe', 'clear', 'tcas', ' nm', 'tau'].any(l.contains);
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
      vertRel: vert == null ? TrafficVertical.unknown : TrafficVertical.above,
      action: 'GIVE WAY: DESCEND AND LAND D9A03',
      resolution:
          'GIVE WAY: DESCEND AND LAND D9A03; AIRCRAFT ${vert == null ? 'HEIGHT UNKNOWN' : '90 M ABOVE'}, 1.1 KM NE',
    );

const low = TrafficAlert(
  level: TrafficLevel.caution,
  kind: TrafficKind.low,
  hex: 'a1b2c3',
  callsign: 'UAL123',
  horizM: 2400,
  vertM: 240,
  bearingDeg: 270,
  ageS: 3,
  fromObserver: true,
  text: 'LOW TRAFFIC W 2.4 KM',
  vertRel: TrafficVertical.above,
  action: 'BE READY TO LAND DRONES',
  resolution: 'BE READY TO LAND DRONES; AIRCRAFT 240 M ABOVE GROUND, 2.4 KM W',
);

void main() {
  group('words', () {
    test('notifications lead with the action, then the geometry, the rule and the aircraft', () {
      expect(AlertWords.title(near()), 'GIVE WAY: DESCEND AND LAND D9A03');
      expect(
          AlertWords.body(near(), ac),
          'AIRCRAFT 90 M ABOVE, 1.1 KM NE · Traffic near drone D9A03 · B738 UAL123 · 2,650 ft · '
          '1.1 km NE of the drone · 90 m above it · reported 6 s ago');
      expect(AlertWords.body(near(vert: null), ac), contains('height unknown'));
      expect(forbidden(AlertWords.body(near(), ac)), isFalse);
      expect(AlertWords.spokenAction(near()), 'Give way: descend and land D9A03.');
    });

    test('low traffic: be ready to land, from you, height above ground', () {
      expect(AlertWords.title(low), 'BE READY TO LAND DRONES');
      expect(AlertWords.rule(low), 'Low traffic W 2.4 km');
      final b = AlertWords.body(low, ac);
      expect(b, startsWith('AIRCRAFT 240 M ABOVE GROUND, 2.4 KM W · Low traffic W 2.4 km · B738 UAL123'));
      expect(b, contains('2.4 km W of you'));
      expect(b, contains('240 m above ground'));
      expect(forbidden(b), isFalse);
      // An aircraft reported a little under the terrain is at the ground, not below it.
      const under = TrafficAlert(
        kind: TrafficKind.low,
        level: TrafficLevel.caution,
        hex: 'a1b2c3',
        droneId: '',
        horizM: 2400,
        vertM: -12,
        ageS: 3,
        fromObserver: true,
      );
      expect(AlertWords.body(under, ac), contains('0 m above ground'));
      expect(trafficAglM(-12), 0);
      expect(trafficAglM(239.6), 240);
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
      List<AlertEvent> at(int t, List<TrafficAlert> a) =>
          p.consider(nowMs: t, traffic: result(a), aircraft: (_) => ac, drones: const [], detectorConnected: true);
      expect(at(now, [near()]), hasLength(1));
      expect(at(now + 1000, [near()]), isEmpty);
      expect(at(now + 299000, [near()]), isEmpty);
      final again = at(now + 300000, [near()]).single;
      expect(again.timeSensitive, isTrue);
      expect(again.title, 'GIVE WAY: DESCEND AND LAND D9A03');
      expect(again.spoken, startsWith('Give way: descend and land D9A03.'));
      final p2 = AlertPolicy();
      expect(
          p2.consider(
              nowMs: now,
              traffic: result([near(held: true)]),
              aircraft: (_) => ac,
              drones: const [],
              detectorConnected: true),
          isEmpty);
    });

    test('low traffic notifies once, as a caution (not time-sensitive)', () {
      final p = AlertPolicy();
      final e = p
          .consider(nowMs: now, traffic: result([low]), aircraft: (_) => ac, drones: const [], detectorConnected: true)
          .single;
      expect(e.level, TrafficLevel.caution);
      expect(e.timeSensitive, isFalse);
      expect(e.title, 'BE READY TO LAND DRONES');
      expect(e.droneId, isNull);
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
          p.consider(
              nowMs: now, traffic: TrafficResult.empty, aircraft: (_) => null, drones: [c], detectorConnected: false),
          isEmpty);
      final e = p
          .consider(
              nowMs: now, traffic: TrafficResult.empty, aircraft: (_) => null, drones: [c], detectorConnected: true)
          .single;
      expect(e.title, 'EMERGENCY REPORTED · D9A03');
      expect(e.source, AlertSource.drone);
      expect(forbidden(e.body), isFalse);
      // Stale contacts do not notify.
      final p2 = AlertPolicy();
      expect(
          p2.consider(
              nowMs: now + 61000,
              traffic: TrafficResult.empty,
              aircraft: (_) => null,
              drones: [c],
              detectorConnected: true),
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

    test('the query rounds the position to about 1 km, the radius up to whole NM', () {
      expect(AdsbSource.urlFor(AdsbSource.defaultBase, const AdsbArea(37.80391234, -122.46401234, 10000)).toString(),
          'https://api.adsb.lol/v2/point/37.80/-122.46/6');
      expect(const AdsbArea(0, 0, 30000).radiusNm, 17);
      expect(const AdsbArea(0, 0, 1852).radiusNm, 1);
    });

    group('area', () {
      const lat = 37.8, lon = -122.46;
      (double, double) east(double m) =>
          (lat, lon + m / (TrafficRules.earthRM * TrafficRules.deg * 0.790155)); // cos(37.8°)

      test('around the phone at the setting while every drone is within 3 km', () {
        final a = AdsbArea.plan(lat, lon, [east(2900)], 10000);
        expect((a.lat, a.lon, a.radiusM), (lat, lon, 10000));
        expect(AdsbArea.plan(lat, lon, const [], 5000).radiusM, 5000);
      });

      test('a drone more than 3 km out moves the centre and gives it 9 km', () {
        final a = AdsbArea.plan(lat, lon, [east(5000)], 10000);
        expect(TrafficRules.distanceM(lat, lon, a.lat, a.lon), closeTo(2500, 5));
        expect(a.radiusM, closeTo(11500, 5));
        final d = east(5000);
        expect(
            TrafficRules.distanceM(a.lat, a.lon, d.$1, d.$2) + AdsbArea.droneCoverM, lessThanOrEqualTo(a.radiusM + 1));
        // A larger setting stays larger.
        expect(AdsbArea.plan(lat, lon, [east(5000)], 20000).radiusM, 20000);
      });

      test('never more than 30 km', () {
        expect(AdsbArea.plan(lat, lon, [east(60000)], 10000).radiusM, 30000);
      });
    });

    test('the monitor keeps 32 inside the area, nearest its centre first', () {
      final m = TrafficMonitor();
      final many = [
        for (var i = 0; i < 40; i++)
          TrafficAircraft(hex: i.toRadixString(16).padLeft(6, '0'), lat: 37.8 + i * 0.005, lon: -122.46, seenMs: now),
        const TrafficAircraft(hex: 'ffffff', lat: 38.5, lon: -122.46, seenMs: now), // ~78 km
      ];
      m.update(many, now, const AdsbArea(37.8, -122.46, 30000));
      expect(m.aircraft, hasLength(TrafficRules.maxAircraft));
      expect(m.aircraft.first.hex, '000000');
      expect(m.aircraft.any((a) => a.hex == 'ffffff'), isFalse);
      expect(m.dataMs, now);
      // A 10 km area drops everything beyond 10 km (i >= 18 is ~10 km north).
      m.update(many, now, const AdsbArea(37.8, -122.46, 10000));
      expect(m.aircraft.every((a) => TrafficRules.distanceM(37.8, -122.46, a.lat, a.lon) <= 10000), isTrue);
      expect(m.aircraft, hasLength(18));
    });
  });
}
