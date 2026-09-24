// sky_painter.dart — draws the Live screen's sky: a perspective ground plane
// (range rings, spokes, compass ticks, the direction the phone faces), a
// faint dome overhead, a radar sweep that re-lights fresh contacts, and
// every contact on a height stem above its ground position.
//
// Drones are soft glowing orbs with a heading tick; manned aircraft are
// outlined chevrons (never filled, so the two cannot be confused) with a
// dashed 60-second track projection and time-ghost dots every 15 s. A
// drone-aircraft pair under a traffic alert is joined by a separation
// bridge (its numbers are a widget; see sky_scene.dart). A drone's operator
// is a ground pin (a map-pin outline with a dot, in the drone's colour:
// never an orb or a chevron) joined to its drone by a thin dotted line,
// labelled "operator 420 m SW" (from its drone). Anything beyond the range
// is pinned to the outer ring at its true bearing as an edge marker: a
// chevron pointing outward at ground level (no stem), labelled
// "<id> · <distance> ›". The painter draws no words a screen reader needs:
// each mark has its own semantics node.
//
// The Flat look (look.dart) draws the mockups' radar instead: no ground
// glow, no spokes, no sweep or pulses; plain rings in the rule colour, "▲
// you face" at the top, drones as solid dots (a ring when alerting),
// aircraft as outlined diamonds, the bridge as one translucent band.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/geo.dart';
import '../../core/traffic/traffic_rules.dart';
import '../../ui/canvas_text.dart';
import '../../ui/theme/theme.dart';
import 'sky_projection.dart';

class SkyContact {
  final String id;
  final String label;
  final String? heightLabel;
  final double distanceM;
  final double bearingDeg;
  final double heightM; // metres above the ground; 0 when unknown
  final bool heightKnown;
  final double? trackDeg;
  final bool isAircraft;
  final bool stale;
  final TrafficLevel level;
  final bool alerting;

  /// Time ghost: (distance, bearing) from the phone at +15/30/45/60 s.
  final List<(double, double)> ghost;

  /// A drone's operator (a ground pin), linked to the drone [linkTo]; its
  /// [label] is its words ("operator 420 m SW").
  final bool isOperator;
  final String? linkTo;

  /// The sensors that heard a drone, compact ("📱BLE4 · T5 Wi-Fi").
  final String? sensorLabel;

  const SkyContact({
    required this.id,
    required this.label,
    this.heightLabel,
    required this.distanceM,
    required this.bearingDeg,
    this.heightM = 0,
    this.heightKnown = true,
    this.trackDeg,
    required this.isAircraft,
    this.stale = false,
    this.level = TrafficLevel.none,
    this.alerting = false,
    this.ghost = const [],
    this.isOperator = false,
    this.linkTo,
    this.sensorLabel,
  });

  Color get color {
    final base = OrecchinoColors.level(level, none: isAircraft ? OrecchinoColors.aircraft : OrecchinoColors.aqua);
    return stale ? base.withValues(alpha: 0.45) : base;
  }

  /// Value equality, so the painters can tell a new list of the same marks
  /// (every rebuild makes one) from a change.
  @override
  bool operator ==(Object other) =>
      other is SkyContact &&
      other.id == id &&
      other.label == label &&
      other.heightLabel == heightLabel &&
      other.distanceM == distanceM &&
      other.bearingDeg == bearingDeg &&
      other.heightM == heightM &&
      other.heightKnown == heightKnown &&
      other.trackDeg == trackDeg &&
      other.isAircraft == isAircraft &&
      other.stale == stale &&
      other.level == level &&
      other.alerting == alerting &&
      listEquals(other.ghost, ghost) &&
      other.isOperator == isOperator &&
      other.linkTo == linkTo &&
      other.sensorLabel == sensorLabel;

  @override
  int get hashCode => Object.hash(id, label, heightLabel, distanceM, bearingDeg, heightM, heightKnown, trackDeg,
      isAircraft, stale, level, alerting, Object.hashAll(ghost), isOperator, linkTo, sensorLabel);
}

/// A traffic pair to join: drone contact id, aircraft contact id.
/// A line from an alert's anchor to its aircraft: the drone for a pair, or
/// for low traffic the nearest drone or the phone ([you]).
class SkyBridge {
  /// The anchor id meaning the phone (the centre of the sky).
  static const you = '@you';

  final String droneId; // the anchor: a drone's id, or [you]
  final String aircraftId;
  final TrafficAlert alert;
  const SkyBridge({required this.droneId, required this.aircraftId, required this.alert});

  /// Equal when drawn the same (the painter uses the level and separation).
  @override
  bool operator ==(Object other) =>
      other is SkyBridge &&
      other.droneId == droneId &&
      other.aircraftId == aircraftId &&
      other.alert.level == alert.level &&
      other.alert.horizM == alert.horizM;

  @override
  int get hashCode => Object.hash(droneId, aircraftId, alert.level, alert.horizM);
}

/// Range rings at round distances: 500 m and 1 km on the 1 km range; 1, 2
/// and 3 km on 3 km; 1, 3 and 5 km (the other ranges) on 5 km. As
/// fractions of the range.
List<double> ringFractions(double rangeM) {
  final List<double> metres;
  if (rangeM <= 1000) {
    metres = [rangeM / 2, rangeM];
  } else if (rangeM <= 3000) {
    metres = [rangeM / 3, rangeM * 2 / 3, rangeM];
  } else {
    metres = [1000, 3000, rangeM];
  }
  return [for (final m in metres) m / rangeM];
}

/// Which part of the sky a painter draws: the [base] (ground, dome, stems,
/// tracks and every label: it changes only when the data or the camera do)
/// or the [live] layer (sweep, glowing marks, pulses, bridges: every frame
/// while motion is on); [all] for a single painter (the History replay).
enum SkyLayer { base, live, all }

class SkyPainter extends CustomPainter {
  final SkyCamera camera;
  final List<SkyContact> contacts;
  final List<SkyBridge> bridges;
  final String? selectedId;
  final bool showFacing; // the phone's facing wedge (only with a compass)
  final bool compact; // the History mini dome: no labels or compass letters
  final SkyLayer layer;

  /// Seconds of ambient motion; null when motion is off (no sweep).
  final ValueListenable<double>? clock;
  final TextScaler textScaler;

  /// Screen areas labels must keep clear of (the bridges' numbers).
  final List<Rect> reserved;

  /// Edges labels keep clear of: the notch, and the tab rail of a phone on
  /// its side (the sky is drawn under them, its words are not).
  final EdgeInsets labelInsets;

  static const double _sweepPeriodS = 4.0;

  SkyPainter({
    required this.camera,
    required this.contacts,
    this.bridges = const [],
    this.selectedId,
    this.showFacing = true,
    this.compact = false,
    this.layer = SkyLayer.all,
    this.clock,
    this.textScaler = TextScaler.noScaling,
    this.reserved = const [],
    this.labelInsets = EdgeInsets.zero,
  }) : super(repaint: layer == SkyLayer.base ? null : clock);

  double? get _time => layer == SkyLayer.base ? null : clock?.value;

  bool get _base => layer != SkyLayer.live;
  bool get _live => layer != SkyLayer.base;

  Size _canvas = Size.infinite;

  @override
  void paint(Canvas canvas, Size size) {
    _canvas = size;
    final cam = camera;
    final t = _time;
    final tops = <String, SkyPoint>{};
    final feet = <String, SkyPoint>{};
    final ordered = <(SkyContact, SkyPoint, SkyPoint)>[];
    _beyond.clear();
    for (final c in contacts) {
      final top = cam.place(c.distanceM, c.bearingDeg, heightM: c.isOperator ? 0 : c.heightM);
      if (top == null) continue;
      final foot = top.beyond ? top.point : cam.project(c.distanceM, c.bearingDeg);
      if (foot == null) continue;
      if (top.beyond) _beyond.add(c.id);
      tops[c.id] = top.point;
      feet[c.id] = foot;
      ordered.add((c, foot, top.point));
    }
    final you = cam.groundAt(0, 0);
    if (you != null) tops[SkyBridge.you] = you;
    ordered.sort((a, b) => b.$3.depth.compareTo(a.$3.depth)); // far first

    if (_base) {
      _groundDisc(canvas, cam);
      if (cam.heightFactor > 0.05) _dome(canvas, cam);
      _rings(canvas, cam);
      if (showFacing) _facing(canvas, cam);
    }
    if (_live) {
      if (t != null) _sweep(canvas, cam, t);
      _you(canvas, cam, t);
    }
    if (_base) {
      // Operators' links first (under everything), on the ground.
      for (final (c, foot, _) in ordered) {
        final to = c.linkTo == null ? null : feet[c.linkTo];
        if (c.isOperator && to != null) _link(canvas, foot, to, c.color);
      }
      for (final (c, foot, top) in ordered) {
        if (_beyond.contains(c.id) || c.isOperator) continue;
        _shadowAndStem(canvas, cam, c, foot, top);
        if (c.isAircraft) _track(canvas, cam, c, top);
      }
    }
    if (_live) {
      for (final b in bridges) {
        final p1 = tops[b.droneId], p2 = tops[b.aircraftId];
        if (p1 != null && p2 != null) _bridge(canvas, b, p1, p2, t);
      }
      for (final (c, _, top) in ordered) {
        final boost = t == null || c.stale ? 0.0 : _relight(cam, c, t);
        if (_beyond.contains(c.id)) {
          _edge(canvas, cam, c, top, boost);
        } else if (c.isOperator) {
          _operator(canvas, c, top);
        } else if (c.isAircraft) {
          _chevron(canvas, cam, c, top, boost);
        } else {
          _orb(canvas, cam, c, top, boost, t);
        }
        if (c.id == selectedId) _reticle(canvas, top, c.color, t);
      }
    }
    if (_base && !compact) {
      // Labels keep clear of the bridges' numbers, every mark, the selection
      // reticle and the phone; nearest (and the selected one) first.
      _placed
        ..clear()
        ..addAll(reserved)
        ..addAll([
          for (final (c, _, top) in ordered)
            if (c.id == selectedId) Rect.fromCircle(center: top.offset, radius: 24 * top.scale.clamp(0.7, 1.6)),
          for (final (_, _, top) in ordered)
            Rect.fromCircle(center: top.offset, radius: 11 * top.scale.clamp(0.7, 1.6)),
          if (cam.groundAt(0, 0) case final o?) Rect.fromCircle(center: o.offset, radius: 10),
        ]);
      final byNear = [...ordered]..sort((a, b) {
          if (a.$1.id == selectedId) return -1;
          if (b.$1.id == selectedId) return 1;
          return a.$3.depth.compareTo(b.$3.depth);
        });
      // The compass letters keep their places: labels go round them.
      for (final (b, _) in const [(0, 'N'), (90, 'E'), (180, 'S'), (270, 'W')]) {
        final p = cam.groundAt(1.16, b - cam.yawDeg);
        if (p != null) _placed.add(Rect.fromCenter(center: p.offset, width: 22, height: 22));
      }
      // Drones and aircraft first, then the operators' labels in what room
      // is left.
      for (final (c, _, top) in byNear) {
        if (!c.isOperator) _label(canvas, c, top, outward: _beyond.contains(c.id) ? _out(cam, top) : null);
      }
      for (final (c, _, top) in byNear) {
        if (c.isOperator) _label(canvas, c, top, outward: _beyond.contains(c.id) ? _out(cam, top) : null);
      }
      _ringLabels(canvas, cam);
      _cardinals(canvas, cam, [
        for (final (_, foot, top) in ordered) ...[foot.offset, top.offset]
      ]);
    }
  }

  // --- Ground --------------------------------------------------------------

  Path? _ringPath(SkyCamera cam, double r, {double z = 0, int steps = 96}) {
    final path = Path();
    var started = false;
    for (var i = 0; i <= steps; i++) {
      final p = cam.groundAt(r, i * 360 / steps, z: z);
      if (p == null) {
        started = false;
        continue;
      }
      if (!started) {
        path.moveTo(p.offset.dx, p.offset.dy);
        started = true;
      } else {
        path.lineTo(p.offset.dx, p.offset.dy);
      }
    }
    return path;
  }

  void _groundDisc(Canvas canvas, SkyCamera cam) {
    if (Look.flat) return; // the plain ground shows through
    final path = _ringPath(cam, 1.0);
    if (path == null) return;
    final bounds = path.getBounds();
    canvas.drawPath(
      path,
      Paint()
        ..shader = RadialGradient(
          colors: [
            OrecchinoColors.aqua.withValues(alpha: 0.10),
            OrecchinoColors.night.withValues(alpha: 0.35),
            OrecchinoColors.void0.withValues(alpha: 0.55),
          ],
          stops: const [0, 0.7, 1],
        ).createShader(Rect.fromCenter(center: cam.center, width: bounds.width, height: bounds.height * 1.4)),
    );
  }

  void _dome(Canvas canvas, SkyCamera cam) {
    final a = 0.10 * cam.heightFactor;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = OrecchinoColors.aircraft.withValues(alpha: a);
    const domeH = 1.0;
    for (final el in [30.0, 60.0]) {
      final r = math.cos(el * math.pi / 180);
      final p = _ringPath(cam, r, z: domeH * math.sin(el * math.pi / 180), steps: 72);
      if (p != null) canvas.drawPath(p, paint);
    }
    // Meridians from the ground ring over the top.
    for (var m = 0; m < 360; m += 45) {
      final path = Path();
      var started = false;
      for (var e = 0; e <= 90; e += 6) {
        final r = math.cos(e * math.pi / 180);
        final p = cam.groundAt(r, m.toDouble(), z: domeH * math.sin(e * math.pi / 180));
        if (p == null) continue;
        if (!started) {
          path.moveTo(p.offset.dx, p.offset.dy);
          started = true;
        } else {
          path.lineTo(p.offset.dx, p.offset.dy);
        }
      }
      canvas.drawPath(path, paint..color = OrecchinoColors.aircraft.withValues(alpha: a * 0.6));
    }
  }

  void _rings(Canvas canvas, SkyCamera cam) {
    if (Look.flat) {
      _flatRings(canvas, cam);
      return;
    }
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = OrecchinoColors.lineBright.withValues(alpha: 0.55);
    for (final r in ringFractions(cam.rangeM).where((f) => f < 1)) {
      final p = _ringPath(cam, r);
      if (p != null) canvas.drawPath(p, ring);
    }
    final outer = _ringPath(cam, 1.0);
    if (outer != null) {
      canvas.drawPath(
          outer,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 7
            ..color = OrecchinoColors.aqua.withValues(alpha: 0.06)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
      canvas.drawPath(
          outer,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4
            ..color = OrecchinoColors.aqua.withValues(alpha: 0.45));
    }
    // Spokes every 30 degrees.
    final spoke = Paint()
      ..strokeWidth = 0.8
      ..color = OrecchinoColors.line.withValues(alpha: 0.9);
    for (var a = 0; a < 360; a += 30) {
      final p1 = cam.groundAt(0.06, a.toDouble()), p2 = cam.groundAt(1.0, a.toDouble());
      if (p1 != null && p2 != null) canvas.drawLine(p1.offset, p2.offset, spoke);
    }
    // Compass ticks, true north based: every 10 degrees, long every 30.
    final tick = Paint()..strokeCap = StrokeCap.round;
    for (var b = 0; b < 360; b += 10) {
      final rel = b - cam.yawDeg;
      final long = b % 30 == 0;
      final p1 = cam.groundAt(1.0, rel), p2 = cam.groundAt(long ? 1.07 : 1.035, rel);
      if (p1 == null || p2 == null) continue;
      tick
        ..strokeWidth = long ? 1.6 : 1
        ..color = (b == 0 ? OrecchinoColors.aqua : OrecchinoColors.inkSubtle).withValues(alpha: long ? 0.9 : 0.5);
      canvas.drawLine(p1.offset, p2.offset, tick);
    }
  }

  /// The mockups' radar: rule-coloured rings (the outer one stronger),
  /// quiet compass ticks, and "▲ you face" above the ring when heading-up.
  void _flatRings(Canvas canvas, SkyCamera cam) {
    final inner = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = OrecchinoColors.line;
    for (final r in ringFractions(cam.rangeM).where((f) => f < 1)) {
      final p = _ringPath(cam, r);
      if (p != null) canvas.drawPath(p, inner);
    }
    final outer = _ringPath(cam, 1.0);
    if (outer != null) {
      canvas.drawPath(
          outer,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = OrecchinoColors.lineBright);
    }
    final tick = Paint()..strokeWidth = 1;
    for (var b = 0; b < 360; b += 30) {
      final rel = b - cam.yawDeg;
      final p1 = cam.groundAt(1.0, rel), p2 = cam.groundAt(1.05, rel);
      if (p1 == null || p2 == null) continue;
      tick.color = b == 0 ? OrecchinoColors.aqua : OrecchinoColors.lineBright;
      canvas.drawLine(p1.offset, p2.offset, tick);
    }
    if (showFacing && !compact) {
      final top = cam.groundAt(1.0, 0);
      if (top != null) {
        final style = OrecchinoType.idSmall.copyWith(color: OrecchinoColors.inkMuted);
        final size = CanvasText.measure('▲ you face', style, textScaler);
        final at = top.offset + Offset(-size.width / 2, -size.height - 6);
        CanvasText.paint(canvas, '▲ you face', at, style, scaler: textScaler);
        _placed.add((at & size).inflate(2));
      }
    }
  }

  /// N, E, S, W just outside the ring; a letter under a mark gives way to
  /// it (the ticks remain).
  void _cardinals(Canvas canvas, SkyCamera cam, List<Offset> marks) {
    for (final (b, l) in const [(0, 'N'), (90, 'E'), (180, 'S'), (270, 'W')]) {
      final p = cam.groundAt(1.16, b - cam.yawDeg);
      if (p == null) continue;
      if (marks.any((m) => (m - p.offset).distance < 26)) continue;
      _text(
          canvas,
          l,
          p.offset,
          TextStyle(
            fontFamily: OrecchinoType.display,
            fontSize: _step(13 * (0.8 + 0.2 * p.scale)),
            fontWeight: FontWeight.w700,
            color: b == 0 ? OrecchinoColors.aqua : OrecchinoColors.inkMuted,
          ),
          center: true);
    }
  }

  /// Ring distances on the near left, drawn after the contacts' labels and
  /// only where they do not cover one.
  void _ringLabels(Canvas canvas, SkyCamera cam) {
    for (final f in ringFractions(cam.rangeM)) {
      final m = cam.rangeM * f;
      final p = cam.groundAt(f, 202);
      if (p == null) continue;
      final txt = m < 1000 ? '${m.round()} m' : '${(m / 1000).toStringAsFixed(m % 1000 == 0 ? 0 : 1)} km';
      final style = OrecchinoType.idSmall.copyWith(fontSize: 10, color: OrecchinoColors.inkSubtle);
      final size = CanvasText.measure(txt, style, textScaler);
      final at = p.offset + Offset(-size.width / 2, 9 - size.height / 2);
      if (!_placed.any((o) => o.overlaps(at & size))) CanvasText.paint(canvas, txt, at, style, scaler: textScaler);
    }
  }

  void _facing(Canvas canvas, SkyCamera cam) {
    if (Look.flat) return; // "▲ you face" instead (_flatRings)
    final path = Path();
    final o = cam.groundAt(0, 0);
    if (o == null) return;
    path.moveTo(o.offset.dx, o.offset.dy);
    for (var a = -30; a <= 30; a += 5) {
      final p = cam.groundAt(1.0, a.toDouble());
      if (p != null) path.lineTo(p.offset.dx, p.offset.dy);
    }
    path.close();
    final far = cam.groundAt(1.0, 0)!;
    canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          colors: [OrecchinoColors.aqua.withValues(alpha: 0.16), OrecchinoColors.aqua.withValues(alpha: 0.0)],
        ).createShader(Rect.fromPoints(o.offset, far.offset)),
    );
  }

  /// The sweep: one wedge on the ground trailing the leading edge, shaded
  /// by one sweep gradient around the phone (it used to be 14 slices, each
  /// its own path and paint, every frame).
  void _sweep(Canvas canvas, SkyCamera cam, double t) {
    final lead = (t % _sweepPeriodS) / _sweepPeriodS * 360;
    const trail = 50.0;
    final o = cam.groundAt(0, 0);
    if (o == null) return;
    final path = Path()..moveTo(o.offset.dx, o.offset.dy);
    Offset? first, last;
    for (var i = 0; i <= 10; i++) {
      final p = cam.groundAt(1.0, lead - trail + trail * i / 10);
      if (p == null) continue;
      first ??= p.offset;
      last = p.offset;
      path.lineTo(p.offset.dx, p.offset.dy);
    }
    path.close();
    if (first == null || last == null) return;
    // Screen angles of the trailing and leading edges around the phone.
    final a0 = math.atan2(first.dy - o.offset.dy, first.dx - o.offset.dx);
    final a1 = math.atan2(last.dy - o.offset.dy, last.dx - o.offset.dx);
    var span = (a1 - a0) % (2 * math.pi);
    final forward = span <= math.pi; // the sweep turns clockwise on screen
    if (!forward) span = 2 * math.pi - span;
    if (span < 1e-3) return;
    const fade = [0.0, 0.25, 0.5, 0.75, 1.0];
    final colors = [for (final f in fade) _aqua(0.2 * f * f)];
    _sweepPaint.shader = SweepGradient(
      startAngle: 0,
      endAngle: span,
      colors: forward ? colors : colors.reversed.toList(),
      stops: fade,
      transform: GradientRotation(forward ? a0 : a1),
    ).createShader(Rect.fromCircle(center: o.offset, radius: 1)); // centred on the phone
    canvas.drawPath(path, _sweepPaint);
    canvas.drawLine(
        o.offset,
        last,
        _edgePaint
          ..shader = LinearGradient(colors: [_aqua(0.0), _aqua(0.7)]).createShader(Rect.fromPoints(o.offset, last)));
  }

  static final Paint _sweepPaint = Paint();
  static final Paint _edgePaint = Paint()..strokeWidth = 1.4;
  static final Map<int, Color> _aquaCache = {};
  static Color _aqua(double alpha) =>
      _aquaCache.putIfAbsent((alpha * 1000).round(), () => OrecchinoColors.aqua.withValues(alpha: alpha));

  /// 1 just after the sweep passes a contact, fading over ~1.2 s.
  double _relight(SkyCamera cam, SkyContact c, double t) {
    final lead = (t % _sweepPeriodS) / _sweepPeriodS * 360;
    final rel = c.bearingDeg - cam.yawDeg;
    final behind = ((lead - rel) % 360 + 360) % 360; // degrees since it passed
    final dt = behind / 360 * _sweepPeriodS;
    return math.exp(-dt / 0.9);
  }

  void _you(Canvas canvas, SkyCamera cam, double? t) {
    final o = cam.groundAt(0, 0);
    if (o == null) return;
    if (Look.flat) {
      canvas.drawCircle(o.offset, 5, Paint()..color = OrecchinoColors.inkMuted);
      return;
    }
    final pulse = t == null ? 0.5 : (t % 2.4) / 2.4;
    canvas.drawCircle(
        o.offset,
        6 + 14 * pulse,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = OrecchinoColors.aqua.withValues(alpha: 0.5 * (1 - pulse)));
    canvas.drawCircle(o.offset, 4.5, Paint()..color = OrecchinoColors.ink);
    canvas.drawCircle(
        o.offset,
        4.5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = OrecchinoColors.aqua);
  }

  // --- Contacts ------------------------------------------------------------

  void _shadowAndStem(Canvas canvas, SkyCamera cam, SkyContact c, SkyPoint foot, SkyPoint top) {
    if (Look.flat) return; // top-down: no stems, no shadows
    final color = c.color;
    final rx = 7 * foot.scale;
    final ry = rx * math.max(0.25, math.cos(cam.tiltDeg * math.pi / 180));
    canvas.drawOval(Rect.fromCenter(center: foot.offset, width: rx * 2, height: ry * 2),
        Paint()..color = color.withValues(alpha: 0.14 * color.a));
    canvas.drawOval(
        Rect.fromCenter(center: foot.offset, width: rx * 2, height: ry * 2),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = color.withValues(alpha: 0.5 * color.a));
    final len = (top.offset - foot.offset).distance;
    if (len < 2) return;
    final stem = Paint()
      ..strokeWidth = 1.4
      ..shader = LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [color.withValues(alpha: 0.08 * color.a), color.withValues(alpha: 0.75 * color.a)],
      ).createShader(Rect.fromPoints(foot.offset, top.offset));
    if (c.isAircraft || !c.heightKnown) {
      // Dashed: aircraft (a different family of mark), or a height guessed.
      const dash = 4.0, gap = 3.0;
      final dir = (top.offset - foot.offset) / len;
      for (var d = 0.0; d < len; d += dash + gap) {
        canvas.drawLine(foot.offset + dir * d, foot.offset + dir * math.min(len, d + dash), stem);
      }
    } else {
      canvas.drawLine(foot.offset, top.offset, stem);
    }
  }

  void _orb(Canvas canvas, SkyCamera cam, SkyContact c, SkyPoint p, double boost, double? t) {
    final color = c.color;
    final s = p.scale.clamp(0.6, 1.8);
    if (Look.flat) {
      // A solid dot; alerting adds a ring (still, no pulse).
      canvas.drawCircle(p.offset, 6 * s, Paint()..color = color);
      if (c.alerting) {
        canvas.drawCircle(
            p.offset,
            11 * s,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2
              ..color = color);
      }
      final trk = c.trackDeg;
      if (trk != null) {
        final a = cam.screenAngle(p, c.distanceM, c.bearingDeg, trk, heightM: c.heightM);
        final dir = Offset(math.cos(a), math.sin(a));
        canvas.drawLine(
            p.offset + dir * (c.alerting ? 12 : 8) * s,
            p.offset + dir * 18 * s,
            Paint()
              ..strokeWidth = 2
              ..color = color);
      }
      return;
    }
    final glowR = (18 + 10 * boost) * s;
    canvas.drawCircle(
      p.offset,
      glowR,
      Paint()
        ..shader = RadialGradient(colors: [
          color.withValues(alpha: (0.45 + 0.4 * boost) * color.a),
          color.withValues(alpha: 0.0),
        ]).createShader(Rect.fromCircle(center: p.offset, radius: glowR)),
    );
    if (c.alerting && t != null) {
      final ph = (t % 1.6) / 1.6;
      canvas.drawCircle(
          p.offset,
          (8 + 14 * ph) * s,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = color.withValues(alpha: 0.8 * (1 - ph)));
    }
    canvas.drawCircle(p.offset, 5.5 * s, Paint()..color = color);
    canvas.drawCircle(p.offset + Offset(-1.6 * s, -1.6 * s), 2.0 * s,
        Paint()..color = Colors.white.withValues(alpha: 0.75 * color.a));
    final trk = c.trackDeg;
    if (trk != null) {
      final a = cam.screenAngle(p, c.distanceM, c.bearingDeg, trk, heightM: c.heightM);
      final dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(
          p.offset + dir * 7 * s,
          p.offset + dir * 17 * s,
          Paint()
            ..strokeWidth = 2
            ..strokeCap = StrokeCap.round
            ..color = color);
    }
  }

  void _chevron(Canvas canvas, SkyCamera cam, SkyContact c, SkyPoint p, double boost) {
    final color = c.color;
    final s = p.scale.clamp(0.6, 1.8);
    if (Look.flat) {
      // The mockups' aircraft: an outlined diamond, never filled.
      final d = 10 * s;
      canvas.drawPath(
          Path()
            ..moveTo(p.offset.dx, p.offset.dy - d)
            ..lineTo(p.offset.dx + d, p.offset.dy)
            ..lineTo(p.offset.dx, p.offset.dy + d)
            ..lineTo(p.offset.dx - d, p.offset.dy)
            ..close(),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = c.id == selectedId ? 3 : 2.5
            ..strokeJoin = StrokeJoin.miter
            ..color = color);
      return;
    }
    if (boost > 0.02) {
      final r = 20 * s;
      canvas.drawCircle(
        p.offset,
        r,
        Paint()
          ..shader = RadialGradient(colors: [
            color.withValues(alpha: 0.30 * boost),
            color.withValues(alpha: 0.0),
          ]).createShader(Rect.fromCircle(center: p.offset, radius: r)),
      );
    }
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = (c.id == selectedId ? 2.4 : 1.8)
      ..strokeJoin = StrokeJoin.round
      ..color = color;
    final trk = c.trackDeg;
    canvas.save();
    canvas.translate(p.offset.dx, p.offset.dy);
    if (trk == null) {
      // No track: an outlined diamond.
      final d = 8 * s;
      canvas.drawPath(
          Path()
            ..moveTo(0, -d)
            ..lineTo(d, 0)
            ..lineTo(0, d)
            ..lineTo(-d, 0)
            ..close(),
          stroke);
    } else {
      canvas.rotate(cam.screenAngle(p, c.distanceM, c.bearingDeg, trk, heightM: c.heightM));
      final k = 1.0 * s;
      canvas.drawPath(
          Path()
            ..moveTo(12 * k, 0)
            ..lineTo(-8 * k, 8 * k)
            ..lineTo(-3 * k, 0)
            ..lineTo(-8 * k, -8 * k)
            ..close(),
          stroke);
    }
    canvas.restore();
  }

  void _track(Canvas canvas, SkyCamera cam, SkyContact c, SkyPoint top) {
    if (c.ghost.isEmpty) return;
    final color = c.color;
    var prev = top.offset;
    for (var i = 0; i < c.ghost.length; i++) {
      final (d, b) = c.ghost[i];
      final g = cam.project(d, b, heightM: c.heightM, slack: 0.6);
      if (g == null) break;
      final k = 1 - i / (c.ghost.length + 1);
      final seg = g.offset - prev;
      final len = seg.distance;
      if (len > 0.5) {
        final dir = seg / len;
        final paint = Paint()
          ..strokeWidth = 1.2
          ..color = color.withValues(alpha: 0.55 * k * color.a);
        for (var s = 0.0; s < len; s += 7) {
          canvas.drawLine(prev + dir * s, prev + dir * math.min(len, s + 3.5), paint);
        }
      }
      canvas.drawCircle(
          g.offset, 2.6 * g.scale.clamp(0.6, 1.6), Paint()..color = color.withValues(alpha: 0.8 * k * color.a));
      prev = g.offset;
    }
  }

  void _bridge(Canvas canvas, SkyBridge b, SkyPoint p1, SkyPoint p2, double? t) {
    final color = OrecchinoColors.level(b.alert.level, none: OrecchinoColors.caution);
    final h = b.alert.horizM ?? TrafficRules.holdHM;
    final k = (1 - (h / TrafficRules.holdHM)).clamp(0.0, 1.0); // thicker as the pair converges
    if (Look.flat) {
      // One translucent band, thicker as they converge (the mockups').
      canvas.drawLine(
          p1.offset,
          p2.offset,
          Paint()
            ..strokeWidth = 8 + 8 * k
            ..strokeCap = StrokeCap.round
            ..color = color.withValues(alpha: 0.28));
      return;
    }
    // The glow: two soft strokes (a blur here would cost an offscreen pass
    // on every frame of the live layer).
    final glow = Paint()..strokeCap = StrokeCap.round;
    canvas.drawLine(
        p1.offset,
        p2.offset,
        glow
          ..strokeWidth = 10 + 16 * k
          ..color = color.withValues(alpha: 0.07 + 0.05 * k));
    canvas.drawLine(
        p1.offset,
        p2.offset,
        glow
          ..strokeWidth = 5 + 8 * k
          ..color = color.withValues(alpha: 0.10 + 0.07 * k));
    final core = Paint()
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.9);
    final seg = p2.offset - p1.offset;
    final len = seg.distance;
    if (len < 1) return;
    final dir = seg / len;
    // Flowing dashes from the drone toward the aircraft.
    final phase = t == null ? 0.0 : (t * 18) % 10;
    for (var s = -10 + phase; s < len; s += 10) {
      final a = math.max(0.0, s), e = math.min(len, s + 6);
      if (e > a) canvas.drawLine(p1.offset + dir * a, p1.offset + dir * e, core);
    }
  }

  void _reticle(Canvas canvas, SkyPoint p, Color color, double? t) {
    final s = p.scale.clamp(0.7, 1.6);
    final breathe = t == null || Look.flat ? 0.0 : math.sin(t * 3) * 1.5;
    final r = 20 * s + breathe;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..color = OrecchinoColors.ink;
    const arm = 7.0;
    for (final (sx, sy) in const [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)]) {
      final c = p.offset + Offset(sx * r, sy * r);
      canvas.drawLine(c, c + Offset(-sx * arm, 0), paint);
      canvas.drawLine(c, c + Offset(0, -sy * arm), paint);
    }
  }

  /// Labels placed so far this frame, nearest first (see [paint]).
  final List<Rect> _placed = [];

  /// Marks pinned to the ring this frame (beyond the range).
  final Set<String> _beyond = {};

  /// The unit direction on screen from the ground centre out to [p].
  Offset _out(SkyCamera cam, SkyPoint p) {
    final c = cam.groundAt(0, 0)?.offset ?? cam.center;
    final d = p.offset - c;
    final l = d.distance;
    return l < 1e-6 ? const Offset(0, -1) : d / l;
  }

  /// A mark beyond the range: a chevron on the ring pointing outward (filled
  /// for a drone, outlined for an aircraft, as their marks), with a soft
  /// glow; the label says how far it really is.
  void _edge(Canvas canvas, SkyCamera cam, SkyContact c, SkyPoint p, double boost) {
    final color = c.color;
    final dir = _out(cam, p);
    final s = p.scale.clamp(0.7, 1.4);
    if (!Look.flat) {
      canvas.drawCircle(
        p.offset,
        16 * s,
        Paint()
          ..shader = RadialGradient(colors: [color.withValues(alpha: 0.28 + 0.25 * boost), color.withValues(alpha: 0)])
              .createShader(Rect.fromCircle(center: p.offset, radius: 16 * s)),
      );
    }
    canvas.save();
    canvas.translate(p.offset.dx, p.offset.dy);
    canvas.rotate(math.atan2(dir.dy, dir.dx));
    final k = 1.0 * s;
    final path = Path()
      ..moveTo(9 * k, 0)
      ..lineTo(-5 * k, 7 * k)
      ..lineTo(-2 * k, 0)
      ..lineTo(-5 * k, -7 * k)
      ..close();
    if (c.isAircraft || c.isOperator) {
      canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.8
            ..strokeJoin = StrokeJoin.round
            ..color = color);
    } else {
      canvas.drawPath(path, Paint()..color = color);
      canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = OrecchinoColors.void0.withValues(alpha: 0.6));
    }
    canvas.restore();
  }

  /// An operator: a map-pin outline with a dot, standing on the ground.
  void _operator(Canvas canvas, SkyContact c, SkyPoint p) {
    final color = c.color;
    final s = p.scale.clamp(0.7, 1.4);
    final tip = p.offset;
    final head = tip - Offset(0, 13 * s);
    final r = 5.5 * s;
    final pin = Path()
      ..moveTo(tip.dx, tip.dy)
      ..quadraticBezierTo(head.dx - r * 1.1, head.dy + r * 0.9, head.dx - r, head.dy)
      ..arcToPoint(Offset(head.dx + r, head.dy), radius: Radius.circular(r))
      ..quadraticBezierTo(head.dx + r * 1.1, head.dy + r * 0.9, tip.dx, tip.dy)
      ..close();
    canvas.drawPath(pin, Paint()..color = OrecchinoColors.void0.withValues(alpha: 0.75));
    canvas.drawPath(
        pin,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = color);
    canvas.drawCircle(head, 2 * s, Paint()..color = color);
    canvas.drawOval(
        Rect.fromCenter(center: tip, width: 8 * s, height: 3 * s), Paint()..color = color.withValues(alpha: 0.35));
  }

  /// A drone's link to its operator: a thin dotted line on the ground.
  void _link(Canvas canvas, SkyPoint a, SkyPoint b, Color color) {
    final d = b.offset - a.offset;
    final len = d.distance;
    if (len < 2) return;
    final u = d / len;
    final paint = Paint()
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.55);
    for (var x = 0.0; x < len; x += 7) {
      canvas.drawLine(a.offset + u * x, a.offset + u * math.min(len, x + 3), paint);
    }
  }

  /// A size step for canvas text (so the text cache is not flooded by
  /// every fractional scale).
  static double _step(double v) => (v * 20).round() / 20;

  /// A contact's name and height beside its mark: to the right if that is
  /// free, else to the left, else nudged down until it clears the labels
  /// already placed.
  void _label(Canvas canvas, SkyContact c, SkyPoint p, {Offset? outward}) {
    final s = _step(p.scale.clamp(0.75, 1.3));
    final mainStyle = TextStyle(
      fontFamily: OrecchinoType.display,
      fontSize: (c.isOperator ? 10.5 : 12) * s,
      fontWeight: c.isOperator ? FontWeight.w500 : FontWeight.w600,
      color: c.stale ? OrecchinoColors.inkSubtle : OrecchinoColors.ink,
    );
    final subStyle = TextStyle(
      fontFamily: OrecchinoType.text,
      fontSize: 10.5 * s,
      fontWeight: FontWeight.w500,
      fontFeatures: OrecchinoType.tabular,
      color: OrecchinoColors.inkMuted,
    );
    // Beyond the range: '<id> · <distance> ›', no height (it is on the ground).
    final text = outward == null ? c.label : '${c.label} · ${Geo.rangeText(c.distanceM)} ›';
    final main = CanvasText.measure(text, mainStyle, textScaler);
    // The second line: the height and, for a drone, the sensors that heard
    // it ("100 m · 📱BLE4 · T5 Wi-Fi"); without room, the height alone.
    final withSensors = outward == null && c.sensorLabel != null
        ? [c.heightLabel, c.sensorLabel].whereType<String>().join(' · ')
        : null;
    var hl = outward == null ? (withSensors ?? c.heightLabel) : null;
    var sub = hl == null ? null : CanvasText.measure(hl, subStyle, textScaler);
    // Free of the labels already placed, and on the screen.
    bool free(Rect r) =>
        !_placed.any((o) => o.overlaps(r)) &&
        r.left >= labelInsets.left + 2 &&
        r.top >= labelInsets.top &&
        r.right <= _canvas.width - labelInsets.right - 2;
    // Try the full label, then the name alone; beside the mark on the right,
    // on the left, then a little lower each way.
    Offset? spot(double w, double h) {
      final right = p.offset + Offset(16 * s, -10 * s);
      final left = p.offset + Offset(-16 * s - w, -10 * s);
      // An edge marker's label goes outside the ring when it can.
      final out = outward == null
          ? null
          : p.offset + outward * 20 * s + Offset(outward.dx >= 0 ? 0 : -w, outward.dy >= 0 ? 0 : -h);
      if (out != null && free(out & Size(w, h))) return out;
      for (var dy = 0.0; dy <= 2 * h; dy += h * 0.5) {
        for (final base in [right, left]) {
          final at = base + Offset(0, dy);
          if (free(at & Size(w, h))) return at;
        }
      }
      return null;
    }

    var fullW = [main.width, sub?.width ?? 0].reduce((a, b) => a > b ? a : b);
    var fullH = main.height + (sub?.height ?? 0);
    var at = spot(fullW, fullH);
    if (at == null && withSensors != null && c.heightLabel != null) {
      hl = c.heightLabel;
      sub = CanvasText.measure(hl!, subStyle, textScaler);
      fullW = [main.width, sub.width].reduce((a, b) => a > b ? a : b);
      fullH = main.height + sub.height;
      at = spot(fullW, fullH);
    }
    var withSub = sub != null;
    if (at == null && sub != null) {
      at = spot(main.width, main.height);
      withSub = false;
    }
    // No room at all: the selected contact still gets its name; the others'
    // names are on their cards (and every mark keeps its screen-reader words).
    if (at == null && c.id == selectedId) at = p.offset + Offset(16 * s, -10 * s);
    if (at != null) {
      final size = withSub ? Size(fullW, fullH) : main;
      _placed.add((at & size).inflate(2));
      CanvasText.paint(canvas, text, at, c.isOperator ? mainStyle.copyWith(color: c.color) : mainStyle,
          scaler: textScaler);
      if (withSub) CanvasText.paint(canvas, hl!, at + Offset(0, main.height), subStyle, scaler: textScaler);
    }
  }

  Size _text(Canvas canvas, String s, Offset at, TextStyle style, {bool center = false}) =>
      CanvasText.paint(canvas, s, at, style, scaler: textScaler, center: center);

  /// The base layer repaints when its inputs change (the widget rebuilds
  /// once a second with fresh positions, or while the camera moves); the
  /// live layer also repaints on every [clock] tick.
  @override
  bool shouldRepaint(covariant SkyPainter old) =>
      old.layer != layer ||
      old.compact != compact ||
      old.camera != camera ||
      !listEquals(old.contacts, contacts) ||
      !listEquals(old.bridges, bridges) ||
      old.selectedId != selectedId ||
      old.showFacing != showFacing ||
      old.textScaler != textScaler ||
      !listEquals(old.reserved, reserved) ||
      old.labelInsets != labelInsets ||
      old.clock != clock;
}
