// geo.dart — range, bearing and clock position from the phone.
//
// bearingDeg and distanceM are the firmware's ui_bearing / ui_dist_m
// (firmware/common/ui_common.h): the great-circle initial bearing and the
// haversine distance, so the phone and the boards give the same numbers.
// The traffic rules keep their own flat-earth offsets (traffic_rules.dart),
// which is what traffic.h uses.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

class Geo {
  static const _deg = math.pi / 180.0;

  /// Initial bearing from point 1 to point 2, degrees true, 0 <= b < 360.
  static double bearingDeg(double lat1, double lon1, double lat2, double lon2) {
    final p1 = lat1 * _deg, p2 = lat2 * _deg;
    final dl = (lon2 - lon1) * _deg;
    final y = math.sin(dl) * math.cos(p2);
    final x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl);
    final b = math.atan2(y, x) / _deg;
    return b < 0 ? b + 360.0 : b;
  }

  /// Haversine distance in metres (Earth diameter 12,742 km, as ui_dist_m).
  static double distanceM(double lat1, double lon1, double lat2, double lon2) {
    final dla = (lat2 - lat1) * _deg, dlo = (lon2 - lon1) * _deg;
    final a = math.sin(dla / 2) * math.sin(dla / 2) +
        math.cos(lat1 * _deg) * math.cos(lat2 * _deg) * math.sin(dlo / 2) * math.sin(dlo / 2);
    return 12742000.0 * math.asin(math.sqrt(math.min(1.0, a)));
  }

  /// The band around 0,0 that DJI encoders emit for "no fix" is no position
  /// (AppModel.validCoord on the Mac, and the receivers apply the same rule).
  static bool validCoord(double? lat, double? lon) {
    if (lat == null || lon == null || !lat.isFinite || !lon.isFinite) return false;
    if (lat.abs() < 5 && lon.abs() < 5) return false;
    return lat.abs() <= 90 && lon.abs() <= 180;
  }

  /// Clock position (1..12) of a target at [bearingDeg] for someone facing
  /// [headingDeg]: 12 is straight ahead, 3 to the right.
  static int clockPosition(double bearingDeg, double headingDeg) {
    final rel = ((bearingDeg - headingDeg) % 360 + 360) % 360;
    final h = (rel / 30.0).round() % 12;
    return h == 0 ? 12 : h;
  }

  /// "2 o'clock"
  static String clockWords(double bearingDeg, double headingDeg) =>
      "${clockPosition(bearingDeg, headingDeg)} o'clock";

  /// "350 m" below 1 km, else "1.1 km" (never nautical miles).
  static String rangeText(double m) {
    if (m < 1000) return '${m.round()} m';
    return '${(m / 1000).toStringAsFixed(m < 10000 ? 1 : 0)} km';
  }
}
