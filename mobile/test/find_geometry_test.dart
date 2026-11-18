// find_geometry_test.dart — the Find pointer's elevation angle, relative
// bearing, alignment and words, and the haptic cues as the phone turns and
// the distance shrinks.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:orecchino_mobile/features/find/find_geometry.dart';

void main() {
  group('elevation', () {
    test('from height and distance', () {
      expect(FindGeometry.elevationDeg(100, 100), closeTo(45, 1e-9));
      expect(FindGeometry.elevationDeg(100, 334), closeTo(16.67, 0.01));
      expect(FindGeometry.elevationDeg(0, 500), 0);
      expect(FindGeometry.elevationDeg(-20, 200), lessThan(0));
    });

    test('overhead, and unknown stays unknown', () {
      expect(FindGeometry.elevationDeg(80, 0.2), 90);
      expect(FindGeometry.elevationDeg(null, 100), isNull);
      expect(FindGeometry.elevationDeg(100, null), isNull);
      expect(FindGeometry.elevationDeg(double.nan, 100), isNull);
    });

    test('words', () {
      expect(FindGeometry.elevationWords(16.7), '17° above the horizon');
      expect(FindGeometry.elevationWords(0.3), 'on the horizon');
      expect(FindGeometry.elevationWords(-3), '3° below the horizon');
    });
  });

  group('bearing', () {
    test('relative to where the phone points, shortest way round', () {
      expect(FindGeometry.relativeDeg(90, 0), 90);
      expect(FindGeometry.relativeDeg(10, 350), 20);
      expect(FindGeometry.relativeDeg(350, 10), -20);
      expect(FindGeometry.relativeDeg(180, 0), 180);
      expect(FindGeometry.relativeDeg(0, 0), 0);
    });

    test('alignment, lock and turn words', () {
      expect(FindGeometry.alignment(0), 1);
      expect(FindGeometry.alignment(45), 0.5);
      expect(FindGeometry.alignment(-120), 0);
      expect(FindGeometry.locked(5), isTrue);
      expect(FindGeometry.locked(-7), isFalse);
      expect(FindGeometry.turnWords(3), 'straight ahead');
      expect(FindGeometry.turnWords(40), 'turn right 40°');
      expect(FindGeometry.turnWords(-75), 'turn left 75°');
      expect(FindGeometry.turnWords(170), 'behind you, turn right');
    });
  });

  group('haptics', () {
    test('a tick per 15-degree step toward the target, a tap on lock, nothing turning away', () {
      final h = FindHaptics();
      expect(h.update(relDeg: 80), FindCue.none); // first reading only sets the baseline
      expect(h.update(relDeg: 76), FindCue.none); // same step (75-90)
      expect(h.update(relDeg: 55), FindCue.tick);
      expect(h.update(relDeg: 70), FindCue.none); // turning away
      expect(h.update(relDeg: 20), FindCue.tick);
      expect(h.update(relDeg: 4), FindCue.lock);
      expect(h.update(relDeg: 2), FindCue.none); // still locked
      expect(h.update(relDeg: 30), FindCue.none);
      expect(h.update(relDeg: -3), FindCue.lock); // locked again
    });

    test('a tap for each step closer, in 50 m steps under 1 km, 250 m beyond', () {
      expect(FindHaptics.rangeStep(0), 0);
      expect(FindHaptics.rangeStep(49), 0);
      expect(FindHaptics.rangeStep(50), 1);
      expect(FindHaptics.rangeStep(1000), 20);
      expect(FindHaptics.rangeStep(1300), 21);
      final h = FindHaptics();
      expect(h.update(distanceM: 420), FindCue.none);
      expect(h.update(distanceM: 410), FindCue.none); // same step
      expect(h.update(distanceM: 395), FindCue.closer);
      expect(h.update(distanceM: 460), FindCue.none); // moving away
      h.reset();
      expect(h.update(distanceM: 100), FindCue.none); // a new target starts again
    });
  });
}
