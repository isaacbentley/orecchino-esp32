// typography.dart — three bundled OFL faces (assets/fonts, licences beside
// them): Space Grotesk for display and numbers, Inter for text, JetBrains
// Mono for identifiers. Every numeric style uses tabular figures so ranges
// and ages do not jitter as they count.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/painting.dart';

import 'colors.dart';

abstract final class OrecchinoType {
  static const String display = 'SpaceGrotesk';
  static const String text = 'Inter';
  static const String mono = 'JetBrainsMono';

  static const List<FontFeature> tabular = [FontFeature.tabularFigures()];

  // Display (Space Grotesk).
  static const TextStyle hero = TextStyle(
      fontFamily: display, fontSize: 56, height: 1.0, fontWeight: FontWeight.w600, letterSpacing: -1.5,
      color: OrecchinoColors.ink, fontFeatures: tabular);
  static const TextStyle title = TextStyle(
      fontFamily: display, fontSize: 30, height: 1.1, fontWeight: FontWeight.w600, letterSpacing: -0.6,
      color: OrecchinoColors.ink);
  static const TextStyle heading = TextStyle(
      fontFamily: display, fontSize: 20, height: 1.2, fontWeight: FontWeight.w600, letterSpacing: -0.2,
      color: OrecchinoColors.ink);
  static const TextStyle metric = TextStyle(
      fontFamily: display, fontSize: 18, height: 1.15, fontWeight: FontWeight.w600,
      color: OrecchinoColors.ink, fontFeatures: tabular);

  // Text (Inter).
  static const TextStyle body = TextStyle(
      fontFamily: text, fontSize: 15, height: 1.35, fontWeight: FontWeight.w400, color: OrecchinoColors.ink);
  static const TextStyle bodyStrong = TextStyle(
      fontFamily: text, fontSize: 15, height: 1.3, fontWeight: FontWeight.w600, color: OrecchinoColors.ink);
  static const TextStyle label = TextStyle(
      fontFamily: text, fontSize: 13, height: 1.3, fontWeight: FontWeight.w500, color: OrecchinoColors.inkMuted,
      fontFeatures: tabular);
  static const TextStyle caption = TextStyle(
      fontFamily: text, fontSize: 12, height: 1.35, fontWeight: FontWeight.w400, color: OrecchinoColors.inkMuted,
      fontFeatures: tabular);
  static const TextStyle eyebrow = TextStyle(
      fontFamily: text, fontSize: 11, height: 1.2, fontWeight: FontWeight.w700, letterSpacing: 1.4,
      color: OrecchinoColors.inkSubtle);
  static const TextStyle alert = TextStyle(
      fontFamily: text, fontSize: 14, height: 1.25, fontWeight: FontWeight.w700, letterSpacing: 0.2,
      fontFeatures: tabular);

  // Identifiers (JetBrains Mono).
  static const TextStyle id = TextStyle(
      fontFamily: mono, fontSize: 13, height: 1.3, fontWeight: FontWeight.w500, color: OrecchinoColors.ink);
  static const TextStyle idSmall = TextStyle(
      fontFamily: mono, fontSize: 11, height: 1.3, fontWeight: FontWeight.w400, color: OrecchinoColors.inkMuted);
}
