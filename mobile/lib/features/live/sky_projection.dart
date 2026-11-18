// sky_projection.dart — the Live screen's 3D camera, pure maths shared by
// the painter, the tap targets, the labels and the tests.
//
// World units: the phone at the origin, x to the right of the view's
// forward direction, y forward, z up; the selected range is 1 unit. The
// forward direction is [SkyCamera.yawDeg] (degrees true: the phone's
// heading, or north without a compass, plus any rotation the person has
// dragged in). The camera orbits the origin at [SkyCamera.distance] units,
// tilted [SkyCamera.tiltDeg] from straight down: 0 is a flat top-down
// radar, larger values lay the ground plane back into a dome.
//
// Heights are drawn on a compressed scale (heightUnits) so a drone at 50 m
// and an aircraft at 3,000 m both read on one screen; their labels and the
// screen reader carry the real numbers.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:ui';

/// A projected point: where on screen, how far from the camera, and how
/// much bigger or smaller than at the ground centre things there look.
class SkyPoint {
  final Offset offset;
  final double depth;
  final double scale;

  const SkyPoint(this.offset, this.depth, this.scale);
}

class SkyCamera {
  static const double maxTiltDeg = 64;
  static const double defaultTiltDeg = 52;

  /// Camera distance from the ground centre, in range units.
  static const double distance = 2.5;

  final Size size;
  final double tiltDeg;
  final double yawDeg;
  final double rangeM;

  /// Where the ground centre sits on screen, and the screen radius of the
  /// range ring as seen straight down.
  final Offset center;
  final double ringRadius;

  final double _cos, _sin, _focal, _heightFactor;

  SkyCamera._(this.size, this.tiltDeg, this.yawDeg, this.rangeM, this.center, this.ringRadius)
      : _cos = math.cos(tiltDeg * math.pi / 180),
        _sin = math.sin(tiltDeg * math.pi / 180),
        _focal = distance * ringRadius,
        _heightFactor = (tiltDeg / maxTiltDeg).clamp(0.0, 1.0);

  /// Value equality: a rebuild with the same view repaints nothing.
  @override
  bool operator ==(Object other) =>
      other is SkyCamera &&
      other.size == size &&
      other.tiltDeg == tiltDeg &&
      other.yawDeg == yawDeg &&
      other.rangeM == rangeM &&
      other.center == center &&
      other.ringRadius == ringRadius;

  @override
  int get hashCode => Object.hash(size, tiltDeg, yawDeg, rangeM, center, ringRadius);

  /// A camera fitted to [viewport] (the part of the screen the scene may
  /// use; the scene itself can bleed past it).
  factory SkyCamera.fit({
    required Size size,
    required Rect viewport,
    required double tiltDeg,
    required double yawDeg,
    required double rangeM,
  }) {
    final t = (tiltDeg / maxTiltDeg).clamp(0.0, 1.0);
    // Room for the compass letters outside the ring; tilted, the centre sits
    // a little lower so the sky has room above.
    final r = math.max(40.0, math.min(viewport.width * 0.40, viewport.height * (0.46 - 0.02 * t)));
    final c = Offset(viewport.center.dx, viewport.center.dy + viewport.height * 0.04 * t);
    return SkyCamera._(size, tiltDeg.clamp(0.0, maxTiltDeg), yawDeg, rangeM, c, r);
  }

  /// Screen-space units per world unit are scaled by this for heights:
  /// 0 flat (stems vanish), 1 fully tilted.
  double get heightFactor => _heightFactor;

  /// Heights in world units: log-compressed, 0 at the ground, 0.95 at
  /// 3,000 m on the 3 km range, never more than 1.1. A shorter range
  /// stretches them (up to 1.5x at 1 km) so the sky keeps its depth.
  static double heightUnits(double heightM, {double rangeM = 3000}) {
    if (!heightM.isFinite || heightM <= 0) return 0;
    final stretch = math.sqrt(3000 / rangeM).clamp(0.85, 1.5);
    return math.min(1.1, stretch * 0.95 * math.log(1 + heightM / 80) / math.log(1 + 3000 / 80));
  }

  /// Ground position (x, y) in world units for a target [distanceM] away
  /// at [bearingDeg] true.
  (double, double) ground(double distanceM, double bearingDeg) {
    final rel = (bearingDeg - yawDeg) * math.pi / 180;
    final r = distanceM / rangeM;
    return (r * math.sin(rel), r * math.cos(rel));
  }

  /// Projects a world point; null when it is behind the camera.
  SkyPoint? projectXYZ(double x, double y, double z) {
    final zz = z * _heightFactor;
    final vy = y + distance * _sin;
    final vz = zz - distance * _cos;
    final xc = x;
    final yc = vy * _cos + vz * _sin;
    final zc = vy * _sin - vz * _cos;
    if (zc < 0.2) return null;
    final s = _focal / zc;
    return SkyPoint(Offset(center.dx + xc * s, center.dy - yc * s), zc, distance / zc);
  }

  /// A target on screen: [heightM] above the ground (0 for its foot).
  /// Null beyond the range (plus [slack]) or behind the camera.
  SkyPoint? project(double distanceM, double bearingDeg, {double heightM = 0, double slack = 0}) {
    if (!distanceM.isFinite || distanceM > rangeM * (1 + slack)) return null;
    final (x, y) = ground(distanceM, bearingDeg);
    return projectXYZ(x, y, heightUnits(heightM, rangeM: rangeM));
  }

  /// Where a contact's mark goes: its projected top, or, beyond the range,
  /// pinned to the outer ring at its true bearing at ground level
  /// ([beyond] true; an edge marker). Null when behind the camera or the
  /// distance is not a number.
  ({SkyPoint point, bool beyond})? place(double distanceM, double bearingDeg, {double heightM = 0}) {
    if (!distanceM.isFinite || !bearingDeg.isFinite) return null;
    if (distanceM > rangeM) {
      final (x, y) = ground(rangeM, bearingDeg);
      final p = projectXYZ(x, y, 0);
      return p == null ? null : (point: p, beyond: true);
    }
    final p = project(distanceM, bearingDeg, heightM: heightM);
    return p == null ? null : (point: p, beyond: false);
  }

  /// A point on the ground at [r] units and [relDeg] clockwise from the
  /// view's forward direction.
  SkyPoint? groundAt(double r, double relDeg, {double z = 0}) {
    final a = relDeg * math.pi / 180;
    return projectXYZ(r * math.sin(a), r * math.cos(a), z);
  }

  /// The angle on screen (radians, canvas convention: 0 = right, clockwise)
  /// of a ground direction [trackDeg] true drawn at [at].
  double screenAngle(SkyPoint at, double distanceM, double bearingDeg, double trackDeg, {double heightM = 0}) {
    final (x, y) = ground(distanceM, bearingDeg);
    final rel = (trackDeg - yawDeg) * math.pi / 180;
    const step = 0.02;
    final p2 = projectXYZ(x + step * math.sin(rel), y + step * math.cos(rel), heightUnits(heightM, rangeM: rangeM));
    if (p2 == null) return 0;
    final d = p2.offset - at.offset;
    return math.atan2(d.dy, d.dx);
  }
}
