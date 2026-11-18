// look.dart — the app's two looks, Sky and Flat, as one set of tokens each.
// Every colour, type style and radius the widgets and painters use
// (colors.dart, typography.dart, theme.dart) reads the active [Palette]
// through [Look], so switching (Detectors > Settings > Theme) is a rebuild,
// not a restart ([Look.apply] then rebuilds and repaints the whole tree).
//
// - Sky (the first-run default): the night-sky palette, frosted glass over
//   the living aurora, Space Grotesk / Inter / JetBrains Mono.
// - Flat: the design mockups (docs/mockups/orecchino-traffic-alerts.html,
//   their dark scheme): flat panels on a near-black ground, 1 px rules, 8 px
//   radii, one teal accent, amber and red for levels; no aurora, no blur, no
//   glows. Type follows the mockups' stack: IBM Plex Sans Condensed for
//   display, IBM Plex Sans for text, IBM Plex Mono for identifiers and
//   eyebrows (bundled, SIL OFL 1.1, assets/fonts/ibm_plex_*).
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

enum AppLook {
  sky('Sky'),
  flat('Flat');

  final String label;
  const AppLook(this.label);

  static AppLook parse(String? s) => values.where((l) => l.name == s).firstOrNull ?? AppLook.sky;
}

@immutable
class Palette {
  final AppLook look;

  // Surfaces, darkest first.
  final Color void0, night, raised, line, lineBright;

  // Panels (glass in Sky, flat in Flat).
  final Color glassTint, glassVeil, glassVeilLow, glassEdge;

  // Text.
  final Color ink, inkMuted, inkSubtle;

  // Symbols and states.
  final Color aqua, aircraft, caution, warning, advisory, ok;

  /// The living background's palettes (deep, mid, highlight); Flat's are
  /// the ground colour.
  final List<Color> auroraCalm, auroraCaution, auroraWarning;
  final Color starPeak;

  // Type faces (with the bundled fallbacks).
  final String display, text, mono;
  final List<String> displayFallback, textFallback, monoFallback;

  // Shapes.
  final double radius, radiusSmall;

  const Palette({
    required this.look,
    required this.void0,
    required this.night,
    required this.raised,
    required this.line,
    required this.lineBright,
    required this.glassTint,
    required this.glassVeil,
    required this.glassVeilLow,
    required this.glassEdge,
    required this.ink,
    required this.inkMuted,
    required this.inkSubtle,
    required this.aqua,
    required this.aircraft,
    required this.caution,
    required this.warning,
    required this.advisory,
    required this.ok,
    required this.auroraCalm,
    required this.auroraCaution,
    required this.auroraWarning,
    required this.starPeak,
    required this.display,
    required this.text,
    required this.mono,
    this.displayFallback = const [],
    this.textFallback = const [],
    this.monoFallback = const [],
    required this.radius,
    required this.radiusSmall,
  });

  bool get flat => look == AppLook.flat;

  /// The night-sky look.
  static const skyLook = Palette(
    look: AppLook.sky,
    void0: Color(0xFF04060C),
    night: Color(0xFF0A1020),
    raised: Color(0xFF121B30),
    line: Color(0xFF24314D),
    lineBright: Color(0xFF3A4A6B),
    glassTint: Color(0x9E0A1020), // night @ 0.62
    glassVeil: Color(0x14FFFFFF), // white @ 0.08
    glassVeilLow: Color(0x08FFFFFF), // white @ 0.03
    glassEdge: Color(0x24FFFFFF),
    ink: Color(0xFFEEF3FF),
    inkMuted: Color(0xFFA7B4CC),
    inkSubtle: Color(0xFF98A6BF),
    aqua: Color(0xFF4BE3C8),
    aircraft: Color(0xFFD6E4FF),
    caution: Color(0xFFFFB84D),
    warning: Color(0xFFFF8585),
    advisory: Color(0xFF7CB8FF),
    ok: Color(0xFF7EE0A5),
    auroraCalm: [Color(0xFF060B1A), Color(0xFF1C2152), Color(0xFF123646)],
    auroraCaution: [Color(0xFF0B0910), Color(0xFF2C1E14), Color(0xFF4A3212)],
    auroraWarning: [Color(0xFF0D070C), Color(0xFF3A1020), Color(0xFF4E161E)],
    starPeak: Color(0xFF525761),
    display: 'SpaceGrotesk',
    text: 'Inter',
    mono: 'JetBrainsMono',
    radius: 22,
    radiusSmall: 14,
  );

  /// The mockups' dark scheme (--ground #0B0F12, --panel #12181C, --ink
  /// #E3E8EA, --muted #8C9AA2, --rule #243036, --accent #35D0BA, --chip
  /// #1A2227, --warn #E0A83A, --danger #E05A5A). The red is lifted a little
  /// (#F27373) so red words keep 4.5:1 on every surface.
  static const flatLook = Palette(
    look: AppLook.flat,
    void0: Color(0xFF0B0F12),
    night: Color(0xFF12181C),
    raised: Color(0xFF1A2227),
    line: Color(0xFF243036),
    lineBright: Color(0xFF34444C),
    glassTint: Color(0xFF12181C), // an opaque panel
    glassVeil: Color(0x00000000),
    glassVeilLow: Color(0x00000000),
    glassEdge: Color(0xFF243036), // the rule
    ink: Color(0xFFE3E8EA),
    inkMuted: Color(0xFF8C9AA2),
    inkSubtle: Color(0xFF8C9AA2),
    aqua: Color(0xFF35D0BA),
    aircraft: Color(0xFFB4C1CA),
    caution: Color(0xFFE0A83A),
    warning: Color(0xFFF27373),
    advisory: Color(0xFF7FB2DA),
    ok: Color(0xFF5ECB7A),
    auroraCalm: [Color(0xFF0B0F12), Color(0xFF0B0F12), Color(0xFF0B0F12)],
    auroraCaution: [Color(0xFF0B0F12), Color(0xFF0B0F12), Color(0xFF0B0F12)],
    auroraWarning: [Color(0xFF0B0F12), Color(0xFF0B0F12), Color(0xFF0B0F12)],
    starPeak: Color(0xFF000000),
    // The mockups' stack: IBM Plex Sans Condensed / Sans / Mono (bundled,
    // SIL OFL 1.1; assets/fonts/ibm_plex_*).
    display: 'IBMPlexSansCondensed',
    text: 'IBMPlexSans',
    mono: 'IBMPlexMono',
    // Glyphs Plex lacks (▲, ›) come from the Sky's bundled faces.
    displayFallback: ['Inter'],
    textFallback: ['Inter'],
    monoFallback: ['JetBrainsMono'],
    radius: 8,
    radiusSmall: 6,
  );

  static Palette of(AppLook l) => l == AppLook.flat ? flatLook : skyLook;
}

/// The active look.
abstract final class Look {
  static Palette _p = Palette.skyLook;
  static final ValueNotifier<AppLook> notifier = ValueNotifier<AppLook>(AppLook.sky);

  static Palette get p => _p;
  static AppLook get current => _p.look;
  static bool get flat => _p.flat;

  /// Switch the look and redraw everything (every element rebuilds and
  /// every render object repaints, as a hot reload does), keeping the
  /// app's state: the tab, the selection, the open sheet.
  static void apply(AppLook l) {
    if (l == _p.look) return;
    _p = Palette.of(l);
    notifier.value = l;
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return;
    void rebuild(Element e) {
      e.markNeedsBuild();
      e.visitChildren(rebuild);
    }

    root.visitChildren(rebuild);
    void repaint(RenderObject r) {
      r.markNeedsPaint();
      r.visitChildren(repaint);
    }

    for (final view in RendererBinding.instance.renderViews) {
      view.visitChildren(repaint);
    }
  }

  /// Tests: set the look without touching a tree.
  @visibleForTesting
  static void setForTest(AppLook l) {
    _p = Palette.of(l);
    notifier.value = l;
  }
}
