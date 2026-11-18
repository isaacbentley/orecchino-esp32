// typography.dart — the type of the active look (look.dart). Sky: three
// bundled OFL faces (assets/fonts, licences beside them): Space Grotesk for
// display and numbers, Inter for text, JetBrains Mono for identifiers.
// Flat: the mockups' IBM Plex Sans Condensed / Sans / Mono (bundled, OFL).
// Every numeric style uses tabular figures so ranges and ages do not
// jitter as they count.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/painting.dart';

import 'colors.dart';
import 'look.dart';

abstract final class OrecchinoType {
  static String get display => Look.p.display;
  static String get text => Look.p.text;
  static String get mono => Look.p.mono;
  static List<String> get _df => Look.p.displayFallback;
  static List<String> get _tf => Look.p.textFallback;
  static List<String> get _mf => Look.p.monoFallback;

  static const List<FontFeature> tabular = [FontFeature.tabularFigures()];

  static bool get _flat => Look.flat;

  // Display: Space Grotesk (Sky); a condensed bold, as the mockups' IBM Plex
  // Sans Condensed 700 (Flat).
  static TextStyle get hero => TextStyle(
      fontFamily: display, fontFamilyFallback: _df, fontSize: 56, height: 1.0,
      fontWeight: _flat ? FontWeight.w700 : FontWeight.w600, letterSpacing: _flat ? -0.5 : -1.5,
      color: OrecchinoColors.ink, fontFeatures: tabular);
  static TextStyle get title => TextStyle(
      fontFamily: display, fontFamilyFallback: _df, fontSize: _flat ? 32 : 30, height: 1.05,
      fontWeight: _flat ? FontWeight.w700 : FontWeight.w600, letterSpacing: _flat ? 0 : -0.6,
      color: OrecchinoColors.ink);
  static TextStyle get heading => TextStyle(
      fontFamily: display, fontFamilyFallback: _df, fontSize: _flat ? 22 : 20, height: 1.15,
      fontWeight: _flat ? FontWeight.w700 : FontWeight.w600, letterSpacing: _flat ? 0 : -0.2,
      color: OrecchinoColors.ink);
  static TextStyle get metric => TextStyle(
      fontFamily: display, fontFamilyFallback: _df, fontSize: _flat ? 20 : 18, height: 1.15,
      fontWeight: _flat ? FontWeight.w700 : FontWeight.w600,
      color: OrecchinoColors.ink, fontFeatures: tabular);

  // Text: Inter (Sky); IBM Plex Sans (Flat).
  static TextStyle get body => TextStyle(
      fontFamily: text, fontFamilyFallback: _tf, fontSize: 15, height: _flat ? 1.45 : 1.35, fontWeight: FontWeight.w400,
      color: OrecchinoColors.ink);
  static TextStyle get bodyStrong => TextStyle(
      fontFamily: text, fontFamilyFallback: _tf, fontSize: 15, height: 1.3, fontWeight: FontWeight.w600,
      color: OrecchinoColors.ink);
  static TextStyle get label => TextStyle(
      fontFamily: text, fontFamilyFallback: _tf, fontSize: 13, height: 1.3, fontWeight: FontWeight.w500,
      color: OrecchinoColors.inkMuted, fontFeatures: tabular);
  static TextStyle get caption => TextStyle(
      fontFamily: text, fontFamilyFallback: _tf, fontSize: 12, height: 1.35, fontWeight: FontWeight.w400,
      color: OrecchinoColors.inkMuted, fontFeatures: tabular);

  /// Section labels: small caps of Inter (Sky); the mockups' mono section
  /// heads, 600 with wide tracking (Flat).
  static TextStyle get eyebrow => _flat
      ? TextStyle(
          fontFamily: mono, fontFamilyFallback: _mf, fontSize: 11.5, height: 1.2, fontWeight: FontWeight.w600,
          letterSpacing: 1.6, color: OrecchinoColors.inkMuted)
      : TextStyle(
          fontFamily: text, fontFamilyFallback: _tf, fontSize: 11, height: 1.2, fontWeight: FontWeight.w700,
          letterSpacing: 1.4, color: OrecchinoColors.inkSubtle);

  /// Alert words: bold text (Sky); the condensed display face, as the
  /// mockups' banners (Flat).
  static TextStyle get alert => _flat
      ? TextStyle(
          fontFamily: display, fontFamilyFallback: _df, fontSize: 16, height: 1.2, fontWeight: FontWeight.w700,
          letterSpacing: 0.2, fontFeatures: tabular)
      : TextStyle(
          fontFamily: text, fontFamilyFallback: _tf, fontSize: 14, height: 1.25, fontWeight: FontWeight.w700,
          letterSpacing: 0.2, fontFeatures: tabular);

  // Identifiers: JetBrains Mono (Sky); IBM Plex Mono (Flat).
  static TextStyle get id => TextStyle(
      fontFamily: mono, fontFamilyFallback: _mf, fontSize: 13, height: 1.3, fontWeight: FontWeight.w500,
      color: OrecchinoColors.ink);
  static TextStyle get idSmall => TextStyle(
      fontFamily: mono, fontFamilyFallback: _mf, fontSize: 11, height: 1.3, fontWeight: FontWeight.w400,
      color: OrecchinoColors.inkMuted);
}
