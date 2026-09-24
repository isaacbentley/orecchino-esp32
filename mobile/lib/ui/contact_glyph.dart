// contact_glyph.dart — the scene's two marks as small icons for cards and
// pickers: a glowing orb for a drone, an outlined chevron for an aircraft.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import 'theme/theme.dart';

class ContactGlyph extends StatelessWidget {
  final bool aircraft;
  final Color color;
  final double size;

  const ContactGlyph({super.key, required this.aircraft, required this.color, this.size = 36});

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox.square(dimension: size, child: CustomPaint(painter: _GlyphPainter(aircraft, color))),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  final bool aircraft;
  final Color color;
  _GlyphPainter(this.aircraft, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    // A faint well behind every glyph.
    canvas.drawCircle(c, r, Paint()..color = color.withValues(alpha: 0.08));
    canvas.drawCircle(
        c,
        r - 0.5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = color.withValues(alpha: 0.25));
    if (aircraft) {
      final k = r / 18;
      canvas.save();
      canvas.translate(c.dx, c.dy);
      canvas.rotate(-1.5708); // pointing up
      canvas.drawPath(
          Path()
            ..moveTo(10 * k, 0)
            ..lineTo(-7 * k, 7 * k)
            ..lineTo(-2.5 * k, 0)
            ..lineTo(-7 * k, -7 * k)
            ..close(),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.8
            ..strokeJoin = StrokeJoin.round
            ..color = color);
      canvas.restore();
    } else {
      canvas.drawCircle(
          c,
          r * 0.62,
          Paint()
            ..shader = RadialGradient(colors: [color.withValues(alpha: 0.6), color.withValues(alpha: 0)])
                .createShader(Rect.fromCircle(center: c, radius: r * 0.62)));
      canvas.drawCircle(c, r * 0.24, Paint()..color = color);
      canvas.drawCircle(c + Offset(-r * 0.07, -r * 0.07), r * 0.08, Paint()..color = OrecchinoColors.ink);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.aircraft != aircraft || old.color != color;
}
