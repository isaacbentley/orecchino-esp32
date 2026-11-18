// contact_tracker_test.dart — live contacts: expiry, unknown markers,
// emergency, range only with a phone position, closing / opening.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:orecchino_mobile/core/live/contact_tracker.dart';
import 'package:orecchino_mobile/core/protocol/messages.dart';

RidMessage rid({
  String? uas = '1581F204C68D9A11',
  String mac = 'E2:01:23:45:67:89',
  Map<String, dynamic>? loc,
  String? auth,
}) =>
    HostMessage.parse(jsonEncode({
      'type': 'rid',
      'src': 'ble',
      'mac': mac,
      'rssi': -70,
      if (uas != null)
        'basic_id': [
          {'id_type': 1, 'ua_type': 2, 'uas_id': uas}
        ],
      if (loc != null) 'loc': loc,
      if (auth != null) 'auth': {'type': 1, 'len': 90, 'pages': 5, 'state': auth},
    })) as RidMessage;

Map<String, dynamic> loc(double lat, double lon,
        {double altGeo = 120, double height = 100, int ref = 0, double speed = 5, double dir = 90, int status = 2}) =>
    {
      'status': status,
      'lat': lat,
      'lon': lon,
      'alt_geo': altGeo,
      'alt_baro': -1000.0,
      'height': height,
      'height_ref': ref,
      'speed': speed,
      'dir': dir,
      'ts': 1.0,
    };

void main() {
  const obs = ObserverFix(37.8039, -122.4640);
  const t0 = 1000000000;

  test('stale after 60 s, removed after 600 s', () {
    final tr = ContactTracker();
    final c = tr.ingest(rid(loc: loc(37.81, -122.46)), t0, obs)!;
    expect(ContactTracker.isStale(c, t0 + 60000), isFalse);
    expect(ContactTracker.isStale(c, t0 + 60001), isTrue);
    expect(c.ageS(t0 + 12000), 12.0);
    expect(tr.expire(t0 + 600000), isEmpty);
    expect(tr.expire(t0 + 600001), ['1581F204C68D9A11']);
    expect(tr.length, 0);
  });

  test('firmware unknown markers never reach the contact', () {
    final tr = ContactTracker();
    final c = tr.ingest(
        rid(loc: {
          'status': 2,
          'lat': 0.0,
          'lon': 0.0,
          'alt_geo': -1000.0,
          'alt_baro': -1000.0,
          'height': -1000.0,
          'height_ref': 1,
          'speed': -1.0,
          'dir': -1,
          'ts': -1.0,
        }),
        t0,
        obs)!;
    expect(c.hasPosition, isFalse);
    expect(c.altGeoM, isNull);
    expect(c.heightM, isNull);
    expect(c.speedMps, isNull);
    expect(c.headingDeg, isNull);
    expect(c.rangeM, isNull);
    expect(c.bearingDeg, isNull);
  });

  test('a later "unknown" replaces an old value; a position-less message keeps the position', () {
    final tr = ContactTracker();
    tr.ingest(rid(loc: loc(37.81, -122.46, speed: 7, dir: 45)), t0, obs);
    final c = tr.ingest(
        rid(loc: {'status': 2, 'lat': 0.0, 'lon': 0.0, 'alt_geo': -1000.0, 'height': 50.0, 'height_ref': 1, 'speed': -1.0, 'dir': -1}),
        t0 + 1000,
        obs)!;
    expect(c.lat, 37.81); // kept: this message had no fix
    expect(c.speedMps, isNull); // reported unknown now
    expect(c.headingDeg, isNull);
    expect(c.altGeoM, isNull);
    expect(c.heightM, 50);
    expect(c.heightRefShort, 'AGL');
  });

  test('emergency is ODID status 3; auth states', () {
    final tr = ContactTracker();
    final c = tr.ingest(rid(loc: loc(37.81, -122.46, status: 3), auth: 'invalid'), t0, obs)!;
    expect(c.emergency, isTrue);
    expect(c.isAuthInvalid, isTrue);
    final c2 = tr.ingest(rid(loc: loc(37.81, -122.46, status: 2), auth: 'test_key'), t0 + 1000, obs)!;
    expect(c2.emergency, isFalse);
    expect(c2.isAuthInvalid, isFalse);
    expect(AuthState.words(c2.authState), 'TEST KEY');
  });

  test('no phone position: no range, no bearing (no stand-in position)', () {
    final tr = ContactTracker();
    final c = tr.ingest(rid(loc: loc(37.81, -122.46)), t0, null)!;
    expect(c.hasPosition, isTrue);
    expect(c.rangeM, isNull);
    expect(c.bearingDeg, isNull);
    tr.updateObserver(obs, t0 + 500);
    expect(c.rangeM, greaterThan(600));
    expect(c.bearingDeg, isNotNull);
  });

  test('closing and opening from the range rate; unknown until two fixes', () {
    final tr = ContactTracker();
    var c = tr.ingest(rid(loc: loc(37.8139, -122.4640)), t0, obs)!; // ~1.1 km N
    expect(c.closing, isNull);
    for (var i = 1; i <= 5; i++) {
      c = tr.ingest(rid(loc: loc(37.8139 - 0.0001 * i, -122.4640)), t0 + 1000 * i, obs)!; // 11 m/s in
    }
    expect(c.closing, isTrue);
    expect(c.rangeRateMps!, lessThan(-5));
    for (var i = 6; i <= 15; i++) {
      c = tr.ingest(rid(loc: loc(37.8139 - 0.0005 + 0.0001 * (i - 5), -122.4640)), t0 + 1000 * i, obs)!;
    }
    expect(c.closing, isFalse);
  });

  test('a MAC heard before its ID is folded into the ID contact', () {
    final tr = ContactTracker();
    tr.ingest(rid(uas: null, loc: loc(37.81, -122.46)), t0, obs);
    expect(tr.contacts.single.key, 'E2:01:23:45:67:89');
    tr.ingest(rid(), t0 + 1000, obs);
    expect(tr.length, 1);
    final c = tr.contacts.single;
    expect(c.key, '1581F204C68D9A11');
    expect(c.lat, 37.81);
    expect(c.firstSeenMs, t0);
    // Later MAC-only frames land on the same contact.
    tr.ingest(rid(uas: null), t0 + 2000, obs);
    expect(tr.length, 1);
    expect(tr.contacts.single.lastSeenMs, t0 + 2000);
  });
}
