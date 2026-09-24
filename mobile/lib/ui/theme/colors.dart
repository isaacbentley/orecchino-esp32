// colors.dart — the Orecchino palette: night sky and avionics symbology.
//
// Surfaces run from deep space (void) to a raised navy; symbols follow
// cockpit convention (aqua for our own sensor's drones, starlight white for
// manned aircraft, amber caution, red warning). Every text colour is at
// least 4.5:1 on every surface, on glass, and on the brightest colour the
// living background can draw (test/accessibility_test.dart checks it, for
// both looks). The values live in look.dart, one set per look.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/painting.dart';

import '../../core/traffic/traffic_rules.dart';
import 'look.dart';

abstract final class OrecchinoColors {
  // Every colour comes from the active look (look.dart): Sky or Flat.
  static Palette get _p => Look.p;

  // Surfaces, darkest first.
  static Color get void0 => _p.void0; // app background
  static Color get night => _p.night; // surface
  static Color get raised => _p.raised; // cards, dialogs, sheets
  static Color get line => _p.line; // hairlines (not text)
  static Color get lineBright => _p.lineBright; // focus rings, ring labels' rules

  // Glass (Sky): night at 62% over whatever is behind, plus a white veil
  // that is 8% at the top edge (the brightest part; the contrast test uses
  // it) and 3% at the bottom. Flat: an opaque panel with a 1 px rule.
  static Color get glassTint => _p.glassTint;
  static Color get glassVeil => _p.glassVeil;
  static Color get glassVeilLow => _p.glassVeilLow;
  static Color get glassEdge => _p.glassEdge;

  /// A level colour washed into glass (alerts, selections): at most this
  /// (Flat: the banner's tint, stronger, as the mockups' alert banners).
  static double get washAlpha => _p.flat ? 0.2 : 0.12;

  // Text.
  static Color get ink => _p.ink;
  static Color get inkMuted => _p.inkMuted;
  static Color get inkSubtle => _p.inkSubtle;

  // Symbols and states.
  static Color get aqua => _p.aqua; // drones, our accent
  static Color get aircraft => _p.aircraft; // manned aircraft (outlined)
  static Color get caution => _p.caution;
  static Color get warning => _p.warning;
  static Color get advisory => _p.advisory;
  static Color get ok => _p.ok;

  /// Living-background palettes: deep, mid, highlight. The shader only mixes
  /// between these, so the highlight is the brightest it ever draws.
  static List<Color> get auroraCalm => _p.auroraCalm;
  static List<Color> get auroraCaution => _p.auroraCaution;
  static List<Color> get auroraWarning => _p.auroraWarning;

  /// The brightest a star in the living background adds to the sky
  /// (shaders/aurora.frag: vec3(0.32, 0.34, 0.38)); text drawn straight
  /// onto the sky may land on one. None in Flat.
  static Color get starPeak => _p.starPeak;

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

  static Color level(TrafficLevel? level, {Color? none}) => switch (level ?? TrafficLevel.none) {
        TrafficLevel.warning => warning,
        TrafficLevel.caution => caution,
        TrafficLevel.none => none ?? inkMuted,
      };

  static List<Color> aurora(TrafficLevel level) => switch (level) {
        TrafficLevel.warning => auroraWarning,
        TrafficLevel.caution => auroraCaution,
        _ => auroraCalm,
      };
}
