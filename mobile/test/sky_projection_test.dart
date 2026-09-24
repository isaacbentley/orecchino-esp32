// sky_projection_test.dart — the Live sky's 3D camera: heading-up placement,
// the flat view matching a top-down radar, perspective when tilted, heights
// raising a contact on screen, the range cut-off and the height scale.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:orecchino_mobile/features/live/sky_projection.dart';

void main() {
  const size = Size(400, 800);
  const viewport = Rect.fromLTWH(0, 100, 400, 500);

  SkyCamera cam({double tilt = 0, double yaw = 0, double range = 3000}) =>
      SkyCamera.fit(size: size, viewport: viewport, tiltDeg: tilt, yawDeg: yaw, rangeM: range);

  test('flat: a top-down radar, forward up, the range on the ring', () {
    final c = cam();
    final o = c.project(0, 0)!.offset;
    expect(o.dx, closeTo(c.center.dx, 1e-6));
    expect(o.dy, closeTo(c.center.dy, 1e-6));
    final north = c.project(3000, 0)!.offset;
    expect(north.dx, closeTo(c.center.dx, 1e-6));
    expect(c.center.dy - north.dy, closeTo(c.ringRadius, 1e-6)); // on the ring, straight up
    final east = c.project(1500, 90)!.offset;
    expect(east.dx - c.center.dx, closeTo(c.ringRadius / 2, 1e-6)); // half range, to the right
    expect(east.dy, closeTo(c.center.dy, 1e-6));
  });

  test('heading-up: what the phone faces is drawn ahead', () {
    // Facing east: an east target is straight up, a north one to the left.
    final c = cam(yaw: 90);
    final east = c.project(3000, 90)!.offset;
    expect(east.dx, closeTo(c.center.dx, 1e-6));
    expect(east.dy, lessThan(c.center.dy));
    final north = c.project(3000, 0)!.offset;
    expect(north.dx, lessThan(c.center.dx));
    expect(north.dy, closeTo(c.center.dy, 1e-6));
  });

  test('flat: height does not move a mark', () {
    final c = cam();
    final ground = c.project(1000, 45)!.offset;
    final high = c.project(1000, 45, heightM: 500)!.offset;
    expect((high - ground).distance, closeTo(0, 1e-6));
  });

  test('tilted: far side smaller and higher, near side larger and lower, heights rise', () {
    final c = cam(tilt: SkyCamera.defaultTiltDeg);
    final far = c.project(3000, 0)!;
    final near = c.project(3000, 180)!;
    expect(far.offset.dy, lessThan(c.center.dy));
    expect(near.offset.dy, greaterThan(c.center.dy));
    expect(far.scale, lessThan(1));
    expect(near.scale, greaterThan(1));
    // Foreshortened: the far ring point is nearer the centre than the near one.
    expect(c.center.dy - far.offset.dy, lessThan(near.offset.dy - c.center.dy));
    final ground = c.project(1000, 45)!.offset;
    final high = c.project(1000, 45, heightM: 300)!.offset;
    expect(high.dy, lessThan(ground.dy));
    expect(high.dx, closeTo(ground.dx, 20)); // a stem is (nearly) vertical
  });

  test('beyond the range is not drawn (unless allowed slack)', () {
    final c = cam(range: 1000);
    expect(c.project(1200, 0), isNull);
    expect(c.project(1200, 0, slack: 0.5), isNotNull);
    expect(c.project(double.nan, 0), isNull);
  });

  test('height scale: 0 at the ground, rising and compressed, capped', () {
    expect(SkyCamera.heightUnits(0), 0);
    expect(SkyCamera.heightUnits(-5), 0);
    final h50 = SkyCamera.heightUnits(50), h100 = SkyCamera.heightUnits(100), h3000 = SkyCamera.heightUnits(3000);
    expect(h50, greaterThan(0));
    expect(h100, greaterThan(h50));
    expect(h3000, closeTo(0.95, 1e-9));
    expect(SkyCamera.heightUnits(100000), 1.1);
    // Stretched on a shorter range, squeezed on a longer one.
    expect(SkyCamera.heightUnits(100, rangeM: 1000), greaterThan(h100));
    expect(SkyCamera.heightUnits(100, rangeM: 5000), lessThan(h100));
    // Compressed: 60x the height is far less than 60x the stem.
    expect(h3000 / h50, lessThan(10));
  });

  test('the tilt is clamped to the camera range', () {
    expect(cam(tilt: 120).tiltDeg, SkyCamera.maxTiltDeg);
    expect(cam(tilt: -10).tiltDeg, 0);
  });
}
