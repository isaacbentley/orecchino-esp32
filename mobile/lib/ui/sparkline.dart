// sparkline.dart — a small line of recent values (signal, altitude) with a
// soft fill and a lit last point. Decorative: the value beside it carries
// the words.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme/theme.dart';

class Sparkline extends StatelessWidget {
  final List<double> values;
  final Color? _color;
  final double height;

  Color get color => _color ?? OrecchinoColors.aqua;

  const Sparkline({super.key, required this.values, Color? color, this.height = 28}) : _color = color;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(painter: _SparkPainter(values, color)),
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  final List<double> values;
  final Color color;
  _SparkPainter(this.values, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final base = Paint()
      ..color = OrecchinoColors.line
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, size.height - 0.5), Offset(size.width, size.height - 0.5), base);
    if (values.length < 2) {
      if (values.length == 1) canvas.drawCircle(Offset(size.width - 3, size.height / 2), 2.5, Paint()..color = color);
      return;
    }
    var lo = values.reduce(math.min), hi = values.reduce(math.max);
    if (hi - lo < 4) {
      final mid = (hi + lo) / 2;
      lo = mid - 2;
      hi = mid + 2;
    }
    // Always spread the samples over the full width (newest at the right).
    final n = values.length;
    Offset at(int i) => Offset(
          size.width * i / (n - 1),
          3 + (size.height - 6) * (1 - (values[i] - lo) / (hi - lo)),
        );
    final line = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < n; i++) {
      final p0 = at(i - 1), p1 = at(i);
      final mx = (p0.dx + p1.dx) / 2;
      line.cubicTo(mx, p0.dy, mx, p1.dy, p1.dx, p1.dy);
    }
    final fill = Path.from(line)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
        fill,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [color.withValues(alpha: 0.28), color.withValues(alpha: 0)],
          ).createShader(Offset.zero & size));
    canvas.drawPath(
        line,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..strokeJoin = StrokeJoin.round
          ..color = color);
    final last = at(n - 1);
    canvas.drawCircle(last, 5, Paint()..color = color.withValues(alpha: 0.25));
    canvas.drawCircle(last, 2.6, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_SparkPainter old) => old.values != values || old.color != color;
}
