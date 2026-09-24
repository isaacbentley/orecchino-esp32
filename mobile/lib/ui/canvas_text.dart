// canvas_text.dart — text drawn straight onto a canvas (the sky's labels, the
// Find pointer's scale), laid out once and cached, and drawn over a dark
// halo so it keeps its contrast over anything behind it, even a star
// (OrecchinoColors.haloAlpha; the contrast test checks the worst case).
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:collection';

import 'package:flutter/painting.dart';

import 'theme/colors.dart';

abstract final class CanvasText {
  static const int _capacity = 192;
  static final LinkedHashMap<String, TextPainter> _cache = LinkedHashMap<String, TextPainter>();

  /// A dark stroke around every glyph: the text's own local background.
  static final Paint _halo = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 3.2
    ..strokeJoin = StrokeJoin.round
    ..color = OrecchinoColors.void0.withValues(alpha: OrecchinoColors.haloAlpha);

  /// A laid-out painter for [text] in [style], reused while it is in the
  /// cache (least recently used goes first).
  static TextPainter layout(String text, TextStyle style, [TextScaler scaler = TextScaler.noScaling]) {
    final key = '$text\u0000${style.hashCode}\u0000${scaler.scale(100)}';
    final hit = _cache.remove(key);
    if (hit != null) {
      _cache[key] = hit;
      return hit;
    }
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    _cache[key] = tp;
    if (_cache.length > _capacity) {
      final oldest = _cache.keys.first;
      _cache.remove(oldest)!.dispose();
    }
    return tp;
  }

  static TextStyle _haloOf(TextStyle s) => TextStyle(
        fontFamily: s.fontFamily,
        fontSize: s.fontSize,
        fontWeight: s.fontWeight,
        letterSpacing: s.letterSpacing,
        height: s.height,
        fontFeatures: s.fontFeatures,
        foreground: _halo,
      );

  /// The size [text] takes in [style].
  static Size measure(String text, TextStyle style, [TextScaler scaler = TextScaler.noScaling]) =>
      layout(text, style, scaler).size;

  /// Draws [text] at [at] (its top left, or its centre with [center]) over
  /// its halo; returns its size.
  static Size paint(Canvas canvas, String text, Offset at, TextStyle style,
      {TextScaler scaler = TextScaler.noScaling, bool center = false}) {
    final fill = layout(text, style, scaler);
    final halo = layout(text, _haloOf(style), scaler);
    final o = center ? at - Offset(fill.width / 2, fill.height / 2) : at;
    halo.paint(canvas, o);
    fill.paint(canvas, o);
    return fill.size;
  }
}
