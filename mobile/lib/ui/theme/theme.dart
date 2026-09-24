// theme.dart — the Material theme built from the tokens (colors.dart,
// typography.dart, motion.dart). Import this one file for all of them.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import 'colors.dart';
import 'look.dart';
import 'typography.dart';

export 'colors.dart';
export 'look.dart';
export 'motion.dart';
export 'typography.dart';

abstract final class OrecchinoTheme {
  static double get radius => Look.p.radius; // panels
  static double get radiusSmall => Look.p.radiusSmall; // chips, buttons

  /// Pills (tags, chips, the status chips): round in Sky, the mockups'
  /// small radius in Flat. (The bridge's badge stays a pill in both.)
  static double get pill => Look.flat ? Look.p.radiusSmall : 999;
  static const double minTarget = 44; // pt: every tap target

  static ThemeData get dark {
    final scheme = ColorScheme.dark(
      primary: OrecchinoColors.aqua,
      onPrimary: OrecchinoColors.void0,
      secondary: OrecchinoColors.aircraft,
      onSecondary: OrecchinoColors.void0,
      surface: OrecchinoColors.night,
      onSurface: OrecchinoColors.ink,
      onSurfaceVariant: OrecchinoColors.inkMuted,
      surfaceContainerHighest: OrecchinoColors.raised,
      error: OrecchinoColors.warning,
      onError: OrecchinoColors.void0,
      outline: OrecchinoColors.lineBright,
      outlineVariant: OrecchinoColors.line,
    );
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusSmall));
    const minSize = Size(minTarget, minTarget);
    final buttonText = TextStyle(fontFamily: OrecchinoType.text, fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: 0.3);
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: OrecchinoColors.void0,
      canvasColor: OrecchinoColors.void0,
      dividerColor: OrecchinoColors.line,
      fontFamily: OrecchinoType.text,
      splashFactory: InkRipple.splashFactory,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      textTheme: TextTheme(
        displayLarge: OrecchinoType.hero,
        headlineMedium: OrecchinoType.title,
        titleLarge: OrecchinoType.heading,
        titleMedium: OrecchinoType.bodyStrong,
        bodyLarge: OrecchinoType.body,
        bodyMedium: OrecchinoType.body,
        bodySmall: OrecchinoType.caption,
        labelLarge: buttonText,
        labelMedium: OrecchinoType.label,
        labelSmall: OrecchinoType.eyebrow,
      ),
      iconTheme: IconThemeData(color: OrecchinoColors.inkMuted, size: 22),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: OrecchinoColors.aqua,
          foregroundColor: OrecchinoColors.void0,
          disabledBackgroundColor: OrecchinoColors.raised,
          disabledForegroundColor: OrecchinoColors.inkSubtle,
          minimumSize: minSize,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          shape: shape,
          textStyle: buttonText,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: OrecchinoColors.ink,
          backgroundColor: const Color(0x0DFFFFFF),
          disabledForegroundColor: OrecchinoColors.inkSubtle,
          side: BorderSide(color: OrecchinoColors.lineBright),
          minimumSize: minSize,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: shape,
          textStyle: buttonText,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: OrecchinoColors.aqua,
          minimumSize: minSize,
          shape: shape,
          textStyle: buttonText,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: minSize, foregroundColor: OrecchinoColors.inkMuted),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? OrecchinoColors.void0 : OrecchinoColors.inkMuted),
        trackColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? OrecchinoColors.aqua : OrecchinoColors.raised),
        trackOutlineColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? OrecchinoColors.aqua : OrecchinoColors.lineBright),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: const Color(0x0DFFFFFF),
        selectedColor: OrecchinoColors.aqua.withValues(alpha: 0.18),
        side: BorderSide(color: OrecchinoColors.lineBright),
        shape: Look.flat
            ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(Look.p.radiusSmall))
            : const StadiumBorder(side: BorderSide.none),
        labelStyle: OrecchinoType.label.copyWith(color: OrecchinoColors.ink),
        secondaryLabelStyle: OrecchinoType.label.copyWith(color: OrecchinoColors.aqua),
        checkmarkColor: OrecchinoColors.aqua,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0x0FFFFFFF),
        hintStyle: OrecchinoType.body.copyWith(color: OrecchinoColors.inkSubtle),
        labelStyle: OrecchinoType.label,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
          borderSide: BorderSide(color: OrecchinoColors.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
          borderSide: BorderSide(color: OrecchinoColors.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
          borderSide: BorderSide(color: OrecchinoColors.aqua, width: 1.5),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: OrecchinoColors.raised,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(color: OrecchinoColors.line),
        ),
        titleTextStyle: OrecchinoType.heading,
        contentTextStyle: OrecchinoType.body.copyWith(color: OrecchinoColors.inkMuted),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: Colors.transparent,
        showDragHandle: false,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: OrecchinoColors.raised,
        contentTextStyle: OrecchinoType.body,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
          side: BorderSide(color: OrecchinoColors.line),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: OrecchinoColors.aqua),
      listTileTheme: ListTileThemeData(
        iconColor: OrecchinoColors.inkMuted,
        textColor: OrecchinoColors.ink,
        minVerticalPadding: 10,
      ),
    );
  }
}
