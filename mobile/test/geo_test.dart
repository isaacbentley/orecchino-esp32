// geo_test.dart — bearing and range against the firmware's ui_bearing /
// ui_dist_m (firmware/common/ui_common.h); expected diagonal values were
// computed with that C code.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:orecchino_mobile/core/geo.dart';

void main() {
  const lat = 37.8039, lon = -122.4640;

  test('cardinal bearings', () {
    expect(Geo.bearingDeg(lat, lon, lat + 0.01, lon), closeTo(0, 1e-9));
    expect(Geo.bearingDeg(lat, lon, lat, lon + 0.01), closeTo(90, 0.01));
    expect(Geo.bearingDeg(lat, lon, lat - 0.01, lon), closeTo(180, 1e-9));
    expect(Geo.bearingDeg(lat, lon, lat, lon - 0.01), closeTo(270, 0.01));
  });

  test('diagonals match the firmware formula', () {
    // ui_bearing(37.8039,-122.4640,37.8139,-122.4540) = 38.307780023
    expect(Geo.bearingDeg(lat, lon, 37.8139, -122.4540), closeTo(38.307780023, 1e-6));
    // ui_bearing(37.8039,-122.4640,37.7939,-122.4740) = 218.317683372
    expect(Geo.bearingDeg(lat, lon, 37.7939, -122.4740), closeTo(218.317683372, 1e-6));
    // London -> Paris: 148.210255648
    expect(Geo.bearingDeg(51.5, -0.12, 48.85, 2.35), closeTo(148.210255648, 1e-6));
    // ui_dist_m for the first pair: 1417.111386 m
    expect(Geo.distanceM(lat, lon, 37.8139, -122.4540), closeTo(1417.111386, 1e-3));
  });

  test('bearing is always in [0, 360)', () {
    for (var d = -179.0; d < 180; d += 7) {
      final b = Geo.bearingDeg(0.5, 0.5, 0.5 + 0.01 * (d / 180), 0.5 + 0.01 * ((180 - d.abs()) / 180));
      expect(b, inInclusiveRange(0, 359.999999));
    }
  });

  test('clock position relative to heading', () {
    expect(Geo.clockPosition(0, 0), 12);
    expect(Geo.clockPosition(60, 0), 2);
    expect(Geo.clockPosition(90, 0), 3);
    expect(Geo.clockPosition(180, 0), 6);
    expect(Geo.clockPosition(270, 0), 9);
    expect(Geo.clockPosition(100, 40), 2); // 60° right of where the phone faces
    expect(Geo.clockPosition(10, 350), 1); // wraps through north
    expect(Geo.clockPosition(344, 0), 11);
    expect(Geo.clockWords(60, 0), "2 o'clock");
  });

  test('no-fix band and range text', () {
    expect(Geo.validCoord(0, 0), isFalse);
    expect(Geo.validCoord(0.0001, 4.9), isFalse);
    expect(Geo.validCoord(null, 1), isFalse);
    expect(Geo.validCoord(91, 10), isFalse);
    expect(Geo.validCoord(lat, lon), isTrue);
    expect(Geo.rangeText(350.4), '350 m');
    expect(Geo.rangeText(1149), '1.1 km');
    expect(Geo.rangeText(12400), '12 km');
  });
}
