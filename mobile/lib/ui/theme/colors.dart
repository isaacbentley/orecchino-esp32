// colors.dart — the Orecchino palette: night sky and avionics symbology.
//
// Surfaces run from deep space (void) to a raised navy; symbols follow
// cockpit convention (aqua for our own sensor's drones, starlight white for
// manned aircraft, amber caution, red warning). Every text colour is at
// least 4.5:1 on every surface, on glass, and on the brightest colour the
// living background can draw (test/accessibility_test.dart checks it).
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/painting.dart';

import '../../core/traffic/traffic_rules.dart';

abstract final class OrecchinoColors {
  // Surfaces, darkest first.
  static const Color void0 = Color(0xFF04060C); // app background, deep space
  static const Color night = Color(0xFF0A1020); // surface
  static const Color raised = Color(0xFF121B30); // cards, dialogs, sheets
  static const Color line = Color(0xFF24314D); // hairlines (not text)
  static const Color lineBright = Color(0xFF3A4A6B); // focus rings, ring labels' rules

  // Glass: night at 62% over whatever is behind, plus a white veil that is
  // 8% at the top edge (the brightest part; the contrast test uses it) and
  // 3% at the bottom.
  static const Color glassTint = Color(0x9E0A1020); // night @ 0.62
  static const Color glassVeil = Color(0x14FFFFFF); // white @ 0.08
  static const Color glassVeilLow = Color(0x08FFFFFF); // white @ 0.03
  static const Color glassEdge = Color(0x24FFFFFF); // top-light hairline

  /// A level colour washed into glass (alerts, selections): at most this.
  static const double washAlpha = 0.12;
  static const Color glassEdgeLow = Color(0x0AFFFFFF);

  // Text.
  static const Color ink = Color(0xFFEEF3FF); // starlight
  static const Color inkMuted = Color(0xFFA7B4CC);
  static const Color inkSubtle = Color(0xFF98A6BF);

  // Symbols and states.
  static const Color aqua = Color(0xFF4BE3C8); // drones, our accent
  static const Color aircraft = Color(0xFFD6E4FF); // manned aircraft (outlined)
  static const Color caution = Color(0xFFFFB84D);
  static const Color warning = Color(0xFFFF8585);
  static const Color advisory = Color(0xFF7CB8FF);
  static const Color ok = Color(0xFF7EE0A5);

  /// Living-background palettes: deep, mid, highlight. The shader only mixes
  /// between these, so the highlight is the brightest it ever draws.
  static const List<Color> auroraCalm = [Color(0xFF060B1A), Color(0xFF1C2152), Color(0xFF123646)];
  static const List<Color> auroraCaution = [Color(0xFF0B0910), Color(0xFF2C1E14), Color(0xFF4A3212)];
  static const List<Color> auroraWarning = [Color(0xFF0D070C), Color(0xFF3A1020), Color(0xFF4E161E)];

  /// The brightest a star in the living background adds to the sky
  /// (shaders/aurora.frag: vec3(0.32, 0.34, 0.38)); text drawn straight
  /// onto the sky may land on one.
  static const Color starPeak = Color(0xFF525761);

  /// Text drawn straight onto a canvas sits on a halo of deep space at this
  /// opacity (lib/ui/canvas_text.dart), so a star behind it cannot wash it out.
  static const double haloAlpha = 0.85;

  /// The worst background canvas text can have: the brightest sky colour
  /// plus a star at its peak, under the halo.
  static List<Color> get haloBackgrounds => [
        for (final p in [auroraCalm, auroraCaution, auroraWarning])
          for (final c in p) Color.alphaBlend(void0.withValues(alpha: haloAlpha), _add(c, starPeak)),
      ];

  static Color _add(Color a, Color b) => Color.from(
        alpha: 1,
        red: (a.r + b.r).clamp(0.0, 1.0),
        green: (a.g + b.g).clamp(0.0, 1.0),
        blue: (a.b + b.b).clamp(0.0, 1.0),
      );

  /// Every colour text may sit on (for the contrast test).
  static List<Color> get textBackgrounds => [
        void0,
        night,
        raised,
        for (final p in [auroraCalm, auroraCaution, auroraWarning]) ...[
          ...p,
          for (final c in p) glassOver(c),
        ],
      ];

  /// What a glass panel looks like over [behind] (before blur, which only
  /// averages colours that are already in the palette).
  static Color glassOver(Color behind) => Color.alphaBlend(glassVeil, Color.alphaBlend(glassTint, behind));

  static Color level(TrafficLevel? level, {Color none = inkMuted}) => switch (level ?? TrafficLevel.none) {
        TrafficLevel.warning => warning,
        TrafficLevel.caution => caution,
        TrafficLevel.advisory => advisory,
        TrafficLevel.none => none,
      };

  static List<Color> aurora(TrafficLevel level) => switch (level) {
        TrafficLevel.warning => auroraWarning,
        TrafficLevel.caution => auroraCaution,
        _ => auroraCalm,
      };
}
