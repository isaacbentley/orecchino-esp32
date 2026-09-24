// motion.dart — durations, curves and springs. Everything that moves asks
// [Motion.reduced] first: with the system's reduce-motion setting on,
// continuous animation stops and transitions jump.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

abstract final class Motion {
  static const Duration quick = Duration(milliseconds: 160);
  static const Duration base = Duration(milliseconds: 280);
  static const Duration morph = Duration(milliseconds: 460);
  static const Duration slow = Duration(milliseconds: 640);
  static const Duration sweep = Duration(seconds: 4); // one radar revolution
  static const Duration breath = Duration(milliseconds: 2600);
  static const Duration replay = Duration(seconds: 4);

  /// Material 3's emphasized decelerate: fast out, long settle.
  static const Curve emphasized = Cubic(0.05, 0.7, 0.1, 1.0);
  static const Curve standard = Cubic(0.2, 0.0, 0.0, 1.0);
  static const Curve exit = Cubic(0.3, 0.0, 0.8, 0.15);

  /// A lively spring for morphs (slight overshoot) and a soft one for the
  /// camera and pointers.
  static const SpringDescription spring = SpringDescription(mass: 1, stiffness: 320, damping: 24);
  static const SpringDescription softSpring = SpringDescription(mass: 1, stiffness: 120, damping: 20);

  /// The spring as a curve, for implicit animations.
  static const Curve springy = SpringCurve(spring);

  static bool reduced(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// [d], or zero when motion is reduced.
  static Duration of(BuildContext context, Duration d) => reduced(context) ? Duration.zero : d;
}

/// A critically-or-under-damped spring from 0 to 1 as a [Curve]. The curve's
/// t = 1 is when the spring has settled (to within 0.1%).
class SpringCurve extends Curve {
  final SpringDescription description;

  const SpringCurve(this.description);

  double get _settle {
    // Time for the envelope e^(-zeta w t) to fall to 1e-3.
    final w = _omega;
    final zeta = description.damping / (2 * description.mass * w);
    final rate = zeta < 1 ? zeta * w : w; // decay rate of the slowest mode
    return 6.9 / rate;
  }

  double get _omega => math.sqrt(description.stiffness / description.mass);

  @override
  double transformInternal(double t) {
    final sim = SpringSimulation(description, 0, 1, 0);
    return sim.x(t * _settle);
  }
}
