// find_geometry.dart — the Find screen's maths, pure and tested: where the
// target is relative to where the phone points (bearing), how high above
// the horizon (elevation, from its height and distance), how well aligned
// the phone is, and when to play a haptic tick.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

abstract final class FindGeometry {
  /// Within this many degrees of the target the pointer is locked on.
  static const double lockDeg = 6;

  /// Degrees above the horizon of a target [heightM] above the phone and
  /// [distanceM] away along the ground; null when either is unknown.
  static double? elevationDeg(double? heightM, double? distanceM) {
    if (heightM == null || distanceM == null || !heightM.isFinite || !distanceM.isFinite) return null;
    if (distanceM < 1) return heightM > 0 ? 90 : (heightM < 0 ? -90 : 0);
    return math.atan2(heightM, distanceM) * 180 / math.pi;
  }

  /// Where the target is relative to where the phone points, -180..180
  /// degrees; positive is to the right.
  static double relativeDeg(double bearingDeg, double headingDeg) {
    final r = ((bearingDeg - headingDeg) % 360 + 360) % 360;
    return r > 180 ? r - 360 : r;
  }

  /// 1 pointing straight at the target, falling to 0 at 90 degrees off.
  static double alignment(double relDeg) => (1 - relDeg.abs() / 90).clamp(0.0, 1.0);

  static bool locked(double relDeg) => relDeg.abs() <= lockDeg;

  /// '17° above the horizon', 'on the horizon', '3° below the horizon'.
  static String elevationWords(double el) {
    final e = el.round();
    if (e == 0) return 'on the horizon';
    return e > 0 ? '$e° above the horizon' : '${-e}° below the horizon';
  }

  /// 'turn right 40°', 'straight ahead', 'behind you, turn left'.
  static String turnWords(double relDeg) {
    final r = relDeg.round();
    if (r.abs() <= lockDeg) return 'straight ahead';
    if (r.abs() >= 150) return r > 0 ? 'behind you, turn right' : 'behind you, turn left';
    return r > 0 ? 'turn right ${r.abs()}°' : 'turn left ${r.abs()}°';
  }
}

enum FindCue { none, tick, closer, lock }

/// Decides the haptic cues as the phone turns and the distance shrinks: a
/// tick each time the alignment improves by a 15-degree step, a firmer tap
/// on locking on, and a light tap for each step closer (50 m steps under
/// 1 km, 250 m beyond). Nothing when moving away or turning off target.
class FindHaptics {
  int? _align;
  int? _range;
  bool _locked = false;

  void reset() {
    _align = null;
    _range = null;
    _locked = false;
  }

  static int rangeStep(double m) => m < 1000 ? (m / 50).floor() : 20 + ((m - 1000) / 250).floor();

  FindCue update({double? relDeg, double? distanceM}) {
    var cue = FindCue.none;
    if (relDeg != null) {
      final a = (relDeg.abs() / 15).floor();
      final lock = FindGeometry.locked(relDeg);
      if (lock && !_locked) {
        cue = FindCue.lock;
      } else if (_align != null && a < _align!) {
        cue = FindCue.tick;
      }
      _align = a;
      _locked = lock;
    }
    if (distanceM != null) {
      final r = rangeStep(distanceM);
      if (_range != null && r < _range! && cue == FindCue.none) cue = FindCue.closer;
      _range = r;
    }
    return cue;
  }
}
