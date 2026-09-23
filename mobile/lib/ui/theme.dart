// theme.dart — Tactical design tokens for Orecchino mobile application
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

class OrecchinoTheme {
  // Palette
  static const Color ground = Color(0xFF07090E);
  static const Color surface = Color(0xFF0D111A);
  static const Color surfaceHigh = Color(0xFF141A26);
  static const Color border = Color(0xFF1E293B);

  // Text colours keep >= 4.5:1 on ground, surface, surfaceHigh and border
  // (WCAG AA; test/theme_contrast_test.dart). `subtle` was #475569, 2.5:1.
  static const Color text = Color(0xFFE2E8F0);
  static const Color muted = Color(0xFF8A99AD);
  static const Color subtle = Color(0xFF8290A4);

  // Semantics
  static const Color accent = Color(0xFF35D0BA);
  static const Color ok = Color(0xFF5ECB7A);
  static const Color amber = Color(0xFFE0A83A);
  static const Color danger = Color(0xFFE05A5A);
  static const Color advisoryBlue = Color(0xFF38BDF8);

  static ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: ground,
      primaryColor: accent,
      canvasColor: ground,
      cardColor: surface,
      dividerColor: border,
      colorScheme: const ColorScheme.dark(
        primary: accent,
        surface: surface,
        error: danger,
        onPrimary: ground,
        onSurface: text,
      ),
      fontFamily: 'monospace',
      appBarTheme: const AppBarTheme(
        backgroundColor: surface,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: text,
          fontSize: 16,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
          fontFamily: 'monospace',
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: surface,
        selectedItemColor: accent,
        unselectedItemColor: muted,
        type: BottomNavigationBarType.fixed,
        elevation: 8,
      ),
    );
  }
}
