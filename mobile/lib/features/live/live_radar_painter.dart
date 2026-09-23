// live_radar_painter.dart — Custom painter for compass-rotated tactical radar
//
// Heading-up when the phone has a compass (north-up otherwise). Drones are
// filled dots with a heading tick; manned aircraft are outlined diamonds
// (never filled, so the two cannot be confused) with a time ghost: a dot
// every 15 s along the next minute of their track. A drone-aircraft pair
// under a traffic alert is joined by a separation bridge: a translucent
// capsule that thickens as the pair converges (its label is a widget, see
// live_view.dart).
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../core/traffic/traffic_rules.dart';
import '../../ui/theme.dart';

class RadarContact {
  final String id;
  final String label;
  final double distanceM;
  final double bearingDeg;
  final double? trackDeg;
  final bool isAircraft; // true = ADS-B diamond, false = drone dot
  final bool stale;
  final TrafficLevel alertLevel;

  /// Time ghost: (distance, bearing) from the phone at +15/30/45/60 s.
  final List<(double, double)> ghost;

  const RadarContact({
    required this.id,
    required this.label,
    required this.distanceM,
    required this.bearingDeg,
    this.trackDeg,
    required this.isAircraft,
    this.stale = false,
    this.alertLevel = TrafficLevel.none,
    this.ghost = const [],
  });
}

/// A traffic pair to join: drone contact id, aircraft contact id.
class RadarBridge {
  final String droneId;
  final String aircraftId;
  final TrafficAlert alert;
  const RadarBridge({required this.droneId, required this.aircraftId, required this.alert});
}

/// Where things go on the radar; shared by the painter and the overlays
/// (labels, semantics, tap targets) so they line up.
class RadarGeometry {
  final Size size;
  final double headingDeg;
  final double maxRangeM;

  const RadarGeometry(this.size, this.headingDeg, this.maxRangeM);

  Offset get center => Offset(size.width / 2, size.height / 2);
  double get radius => math.max(0, math.min(size.width, size.height) / 2 - 18);

  /// The point for a target, or null when it is beyond the range.
  Offset? point(double distanceM, double bearingDeg) {
    if (distanceM > maxRangeM) return null;
    final rad = ((bearingDeg - headingDeg) - 90) * math.pi / 180.0;
    final r = (distanceM / maxRangeM) * radius;
    return Offset(center.dx + r * math.cos(rad), center.dy + r * math.sin(rad));
  }
}

class LiveRadarPainter extends CustomPainter {
  final double headingDeg;
  final double maxRangeM;
  final List<RadarContact> contacts;
  final List<RadarBridge> bridges;
  final String? selectedId;

  LiveRadarPainter({
    required this.headingDeg,
    required this.maxRangeM,
    required this.contacts,
    this.bridges = const [],
    this.selectedId,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final g = RadarGeometry(size, headingDeg, maxRangeM);
    final center = g.center;
    final radius = g.radius;

    final ringPaint = Paint()
      ..color = OrecchinoTheme.border
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    for (int i = 1; i <= 3; i++) {
      canvas.drawCircle(center, radius * (i / 3.0), ringPaint);
    }
    canvas.drawLine(Offset(center.dx, center.dy - radius), Offset(center.dx, center.dy + radius), ringPaint);
    canvas.drawLine(Offset(center.dx - radius, center.dy), Offset(center.dx + radius, center.dy), ringPaint);

    final byId = {for (final c in contacts) c.id: c};

    // Separation bridges first, under the marks.
    for (final b in bridges) {
      final d = byId[b.droneId], a = byId[b.aircraftId];
      if (d == null || a == null) continue;
      final p1 = g.point(d.distanceM, d.bearingDeg), p2 = g.point(a.distanceM, a.bearingDeg);
      if (p1 == null || p2 == null) continue;
      final h = b.alert.horizM ?? TrafficRules.holdHM;
      final t = (1 - (h / TrafficRules.holdHM)).clamp(0.0, 1.0);
      final paint = Paint()
        ..color = _getColor(b.alert.level, true).withValues(alpha: 0.28 + 0.2 * t)
        ..strokeWidth = 5 + 11 * t
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(p1, p2, paint);
    }

    // Aircraft under drones.
    final ordered = [...contacts.where((c) => c.isAircraft), ...contacts.where((c) => !c.isAircraft)];
    for (final c in ordered) {
      final pt = g.point(c.distanceM, c.bearingDeg);
      if (pt == null) continue;
      final isSelected = c.id == selectedId;
      var color = _getColor(c.alertLevel, c.isAircraft);
      if (c.stale) color = color.withValues(alpha: 0.5);

      if (c.isAircraft) {
        final ghostPaint = Paint()..color = color.withValues(alpha: 0.7);
        for (final (dist, brg) in c.ghost) {
          final gp = g.point(dist, brg);
          if (gp != null) canvas.drawCircle(gp, 1.8, ghostPaint);
        }
        _drawDiamond(canvas, pt, 7.0, color, isSelected);
      } else {
        canvas.drawCircle(pt, isSelected ? 6.0 : 4.5, Paint()..color = color);
        if (isSelected) {
          canvas.drawCircle(
              pt,
              9.0,
              Paint()
                ..color = OrecchinoTheme.text
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.5);
        }
      }

      if (c.trackDeg != null) {
        final trackRelRad = ((c.trackDeg! - headingDeg) - 90) * math.pi / 180.0;
        final vEnd = Offset(pt.dx + 14 * math.cos(trackRelRad), pt.dy + 14 * math.sin(trackRelRad));
        canvas.drawLine(
            pt,
            vEnd,
            Paint()
              ..color = color
              ..strokeWidth = 1.5);
      }
    }

    // The phone, and which way it faces.
    canvas.drawCircle(center, 4.0, Paint()..color = OrecchinoTheme.accent);

    _drawCardinal(canvas, center, radius + 10, 0 - headingDeg, 'N', isNorth: true);
    _drawCardinal(canvas, center, radius + 10, 90 - headingDeg, 'E');
    _drawCardinal(canvas, center, radius + 10, 180 - headingDeg, 'S');
    _drawCardinal(canvas, center, radius + 10, 270 - headingDeg, 'W');
  }

  void _drawDiamond(Canvas canvas, Offset center, double size, Color color, bool selected) {
    final path = Path()
      ..moveTo(center.dx, center.dy - size)
      ..lineTo(center.dx + size, center.dy)
      ..lineTo(center.dx, center.dy + size)
      ..lineTo(center.dx - size, center.dy)
      ..close();
    canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = selected ? 2.5 : 1.8);
  }

  void _drawCardinal(Canvas canvas, Offset center, double dist, double angleDeg, String label, {bool isNorth = false}) {
    final rad = (angleDeg - 90) * math.pi / 180.0;
    final x = center.dx + dist * math.cos(rad);
    final y = center.dy + dist * math.sin(rad);
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: isNorth ? OrecchinoTheme.accent : OrecchinoTheme.muted,
          fontSize: 11,
          fontWeight: isNorth ? FontWeight.bold : FontWeight.normal,
          fontFamily: 'monospace',
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(x - tp.width / 2, y - tp.height / 2));
  }

  Color _getColor(TrafficLevel level, bool isAircraft) {
    switch (level) {
      case TrafficLevel.warning:
        return OrecchinoTheme.danger;
      case TrafficLevel.caution:
        return OrecchinoTheme.amber;
      case TrafficLevel.advisory:
        return OrecchinoTheme.advisoryBlue;
      case TrafficLevel.none:
        return isAircraft ? OrecchinoTheme.muted : OrecchinoTheme.accent;
    }
  }

  @override
  bool shouldRepaint(covariant LiveRadarPainter old) => true; // cheap; contacts move every second
}
