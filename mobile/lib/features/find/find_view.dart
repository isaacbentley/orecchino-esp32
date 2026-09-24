// find_view.dart — "point at the sky". A head-up pointer shows where the
// chosen drone is relative to where the phone points (an aircraft can be
// chosen only while an alert names it, as part of that alert): left or
// right (bearing) and how high above the horizon (elevation, from its height
// and distance). A lock-on ring tightens as the phone comes round to it,
// and haptic ticks mark each step closer in angle and in range.
//
// Without a compass the pointer becomes a north-up sky plot (horizon at the
// rim, overhead at the centre) and says so; without positions there is no
// direction, and the screen says why.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_controller.dart';
import '../../core/geo.dart';
import '../../core/live/sensors.dart';
import '../../ui/ambient_clock.dart';
import '../../ui/canvas_text.dart';
import '../../ui/contact_glyph.dart';
import '../../ui/glass.dart';
import '../../ui/sensor_chips.dart';
import '../../ui/theme/theme.dart';
import '../../ui/traffic_widgets.dart';
import '../details/drone_details_sheet.dart';
import '../live/contact_sheet.dart';
import '../live/live_items.dart';
import 'find_geometry.dart';

class FindView extends StatefulWidget {
  final AppController app;

  const FindView({super.key, required this.app});

  @override
  State<FindView> createState() => _FindViewState();
}

class _FindViewState extends State<FindView> {
  String? _targetId;
  final FindHaptics _haptics = FindHaptics();
  // The pointer eases toward the compass on the shared ambient clock (24–30
  // frames a second, not the display's 120) and stops once it arrives; the
  // lock pulse runs on the same clock. Without ambient motion (Reduce
  // Motion, Saver) the pointer jumps.
  final _ease = _Repaint();
  ValueListenable<double>? _ambient;
  ValueListenable<double>? _easingOn; // the clock the easing listens to
  double? _lastClock;
  bool _started = false;

  // Displayed pointer values, eased toward the live ones while they differ.
  double? _rel, _el;
  double? _goalRel, _goalEl;

  @override
  void initState() {
    super.initState();
    // The target, the pointer's goal and the haptic cues follow the app's
    // updates (positions, compass), never a rebuild.
    widget.app.addListener(_changed);
    // The compass has its own listenable (throttled to 10 a second).
    widget.app.heading.addListener(_changed);
  }

  void _changed() {
    _onApp();
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ambient = AmbientClock.of(context);
    if (_easingOn != null && _easingOn != _ambient) {
      _stopEasing();
      _setGoal(_goalRel, _goalEl); // on the new clock, or a jump
    }
    if (!_started) {
      _started = true;
      _onApp();
    }
  }

  @override
  void dispose() {
    widget.app.removeListener(_changed);
    widget.app.heading.removeListener(_changed);
    _stopEasing();
    _ease.dispose();
    super.dispose();
  }

  LiveContactItem? _currentTarget(List<LiveContactItem> contacts) =>
      contacts.isEmpty ? null : (contacts.where((c) => c.id == _targetId).firstOrNull ?? contacts.first);

  void _onApp() {
    final app = widget.app;
    final target = _currentTarget(buildLiveItems(app));
    if (target == null) {
      _setGoal(null, null);
      return;
    }
    if (_targetId != target.id) {
      _targetId = target.id;
      _haptics.reset();
      _rel = null;
      _el = null;
    }
    final heading = app.headingDeg;
    final hasBearing = target.bearingDeg != null;
    final rel = hasBearing && heading != null ? FindGeometry.relativeDeg(target.bearingDeg!, heading) : null;
    _setGoal(rel ?? (hasBearing ? target.bearingDeg : null),
        FindGeometry.elevationDeg(target.heightMetres, target.distanceM));
    _cue(_haptics.update(relDeg: rel, distanceM: target.distanceM));
  }

  void _stopEasing() {
    _easingOn?.removeListener(_onClock);
    _easingOn = null;
    _lastClock = null;
  }

  /// Eases the pointer one ambient frame; stops once it has arrived.
  void _onClock() {
    final now = _easingOn?.value ?? 0;
    final dt = _lastClock == null ? 1 / 24 : (now - _lastClock!).clamp(0.0, 0.25);
    _lastClock = now;
    final k = 1 - math.exp(-dt * 7);
    var moving = false;
    if (_goalRel != null) {
      final cur = _rel ?? _goalRel!;
      final diff = FindGeometry.relativeDeg(_goalRel!, cur); // shortest way round
      _rel = FindGeometry.relativeDeg(cur + diff * k, 0);
      moving |= diff.abs() > 0.05;
    }
    if (_goalEl != null) {
      final cur = _el ?? _goalEl!;
      _el = cur + (_goalEl! - cur) * k;
      moving |= (_goalEl! - cur).abs() > 0.05;
    }
    _ease.tick();
    if (!moving) _stopEasing();
  }

  void _setGoal(double? rel, double? el) {
    _goalRel = rel;
    _goalEl = el;
    if (rel == null) _rel = null;
    if (el == null) _el = null;
    final clock = _ambient;
    if (clock == null) {
      _rel = rel;
      _el = el;
      _ease.tick();
      return;
    }
    if (_easingOn == null && (rel != null || el != null)) {
      _easingOn = clock;
      _lastClock = null;
      clock.addListener(_onClock);
    }
  }

  void _cue(FindCue cue) {
    if (cue == FindCue.none || !widget.app.settings.haptics) return;
    switch (cue) {
      case FindCue.lock:
        HapticFeedback.mediumImpact();
      case FindCue.tick:
        HapticFeedback.selectionClick();
      case FindCue.closer:
        HapticFeedback.lightImpact();
      case FindCue.none:
        break;
    }
  }

  Future<void> _pick(List<LiveContactItem> contacts, LiveContactItem current) async {
    final id = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _TargetPicker(contacts: contacts, currentId: current.id, headingDeg: widget.app.headingDeg),
    );
    if (id != null && mounted) {
      setState(() => _targetId = id);
      _haptics.reset();
      _rel = null;
      _el = null;
      _onApp();
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final contacts = buildLiveItems(app);
    final heading = app.headingDeg;
    final target = _currentTarget(contacts);
    final mq = MediaQuery.of(context);

    final title = Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 10,
      children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text('POINT AT THE SKY', style: OrecchinoType.eyebrow),
          const SizedBox(height: 2),
          Semantics(header: true, child: Text('Find', style: OrecchinoType.title)),
        ]),
        if (target != null)
          Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(
              child: GlassButton(
                semanticLabel: 'Choose what to find, now ${target.kindWord.toLowerCase()} ${target.label}',
                onTap: () => _pick(contacts, target),
                padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  ContactGlyph(aircraft: target.isAircraft, operator: target.isOperator, color: contactColor(target), size: 28),
                  const SizedBox(width: 8),
                  Flexible(child: Text(target.label, style: OrecchinoType.bodyStrong)),
                  const SizedBox(width: 4),
                  Icon(Icons.unfold_more_rounded, size: 18, color: OrecchinoColors.inkMuted),
                ]),
              ),
            ),
            if (!target.isAircraft) ...[
              const SizedBox(width: 8),
              GlassButton(
                semanticLabel: 'All details of drone ${target.isOperator ? target.ofDroneLabel : target.label}',
                onTap: () => DroneDetailsSheet.showLive(context, app, target.ofDrone ?? target.id),
                padding: const EdgeInsets.all(10),
                child: Icon(Icons.info_outline_rounded, size: 22, color: OrecchinoColors.aqua),
              ),
            ],
          ]),
      ],
    );

    return Material(
      type: MaterialType.transparency,
      child: SafeArea(
        bottom: false,
        child: LayoutBuilder(builder: (context, box) {
          final wide = box.maxWidth > box.maxHeight && box.maxWidth >= 600;
          final bottom = mq.padding.bottom + 24;
          if (target == null) {
            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(20, 12, 20, bottom),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                title,
                const SizedBox(height: 16),
                Glass(
                  padding: const EdgeInsets.all(28),
                  child: Column(children: [
                    Icon(Icons.explore_off_rounded, size: 40, color: OrecchinoColors.inkSubtle),
                    const SizedBox(height: 12),
                    Text('No drones yet', style: OrecchinoType.heading.copyWith(fontSize: 18)),
                    const SizedBox(height: 6),
                    Text(
                      app.detectorReady
                          ? 'Drones appear here as the detector hears them.'
                          : 'Connect a detector, or try the demo in Detectors.',
                      textAlign: TextAlign.center,
                      style: OrecchinoType.label,
                    ),
                  ]),
                ),
              ]),
            );
          }
          final (pointer, readouts) = _find(target, heading);
          if (wide) {
            // On its side: the pointer on the left, the words on the right.
            // Both halves centred, the pointer no bigger than on a phone
            // held upright and the words at a readable line length.
            final side = math.min(math.min(box.maxHeight - 24, box.maxWidth * 0.48), 520.0);
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1080),
                child: Row(children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
                    child: SizedBox.square(dimension: side, child: pointer),
                  ),
                  Expanded(
                    child: Align(
                      child: SingleChildScrollView(
                        padding: EdgeInsets.fromLTRB(8, 12, 20, bottom),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          title,
                          const SizedBox(height: 12),
                          ...readouts,
                        ]),
                      ),
                    ),
                  ),
                ]),
              ),
            );
          }
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(20, 12, 20, bottom),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  title,
                  const SizedBox(height: 16),
                  ...readouts.take(2),
                  const SizedBox(height: 12),
                  Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 360), child: pointer)),
                  ...readouts.skip(2),
                ]),
              ),
            ),
          );
        }),
      ),
    );
  }

  /// The pointer (square), and the words around it: the first two readouts
  /// (alert words, trend) go above the pointer in portrait.
  (Widget, List<Widget>) _find(LiveContactItem target, double? heading) {
    final hasBearing = target.bearingDeg != null;
    final rel = hasBearing && heading != null ? FindGeometry.relativeDeg(target.bearingDeg!, heading) : null;
    final el = FindGeometry.elevationDeg(target.heightMetres, target.distanceM);
    final why = !hasBearing
        ? (widget.app.observer == null
            ? 'Your position is unknown: no direction'
            : 'No position reported by the target')
        : (heading == null ? 'No compass on this phone: bearing ${target.bearingDeg!.round()}° true, north up' : null);
    final color = contactColor(target);
    final clock = hasBearing && heading != null ? Geo.clockWords(target.bearingDeg!, heading) : null;
    final locked = rel != null && FindGeometry.locked(rel);
    final approx = target.isAircraft ? 'about ' : '';
    final elWords = el == null ? null : '$approx${FindGeometry.elevationWords(el)}';
    final al = target.alert;
    final words = [...target.alertWords, if (al != null) al.text];

    final pointerLabel = [
      'Pointer to ${target.kindWord.toLowerCase()} ${target.label}',
      if (clock != null) clock,
      if (heading == null && hasBearing) 'bearing ${target.bearingDeg!.round()} degrees true',
      if (rel != null) locked ? 'on target' : FindGeometry.turnWords(rel),
      if (elWords != null) elWords,
      target.rangeText,
    ].join(', ');

    final pointer = hasBearing
        ? AspectRatio(
            aspectRatio: 1,
            child: Semantics(
              label: pointerLabel,
              liveRegion: locked,
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _HudPainter(
                    state: this,
                    northUp: heading == null,
                    headingDeg: heading ?? 0,
                    color: color,
                    aircraft: target.isAircraft,
                    ease: _ease,
                    // The lock pulse only while locked on.
                    clock: locked ? _ambient : null,
                  ),
                ),
              ),
            ),
          )
        : Glass(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.location_disabled_rounded, size: 36, color: OrecchinoColors.inkSubtle),
              const SizedBox(height: 12),
              Text(why ?? '',
                  textAlign: TextAlign.center, style: OrecchinoType.body.copyWith(color: OrecchinoColors.inkMuted)),
            ]),
          );

    final readouts = <Widget>[
      // What to do first (the alert's action and why), then who it is:
      // alert words, where it was heard from (or its type).
      if (al != null) ...[
        Text(trafficAction(al), style: OrecchinoType.alert.copyWith(color: color)),
        if (trafficGeometry(al).isNotEmpty)
          Text(trafficGeometry(al), style: OrecchinoType.label.copyWith(color: OrecchinoColors.ink)),
        const SizedBox(height: 8),
      ],
      Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        for (final w in words) Tag(w, color: color, filled: true),
        if (target.isDrone && target.sensors.isNotEmpty)
          Semantics(label: sensorWords(target.sensors), child: SensorChips(target.sensors))
        else if (target.sublabel != null && target.sublabel!.isNotEmpty)
          Tag(target.sublabel!),
      ]),
      if (target.trendText != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(target.trendText!.toUpperCase(),
              style: OrecchinoType.alert
                  .copyWith(color: target.isClosing ? OrecchinoColors.caution : OrecchinoColors.aqua)),
        )
      else
        const SizedBox.shrink(),
      const SizedBox(height: 14),
      if (rel != null)
        Center(
          child: AnimatedSwitcher(
            duration: Motion.of(context, Motion.base),
            child: locked
                ? Tag('ON TARGET',
                    key: const ValueKey('lock'),
                    color: OrecchinoColors.aqua,
                    filled: true,
                    icon: Icons.center_focus_strong_rounded)
                : Text(FindGeometry.turnWords(rel).toUpperCase(),
                    key: const ValueKey('turn'),
                    style: OrecchinoType.eyebrow.copyWith(color: OrecchinoColors.ink, fontSize: 12)),
          ),
        )
      else if (why != null && hasBearing)
        Text(why, textAlign: TextAlign.center, style: OrecchinoType.label),
      const SizedBox(height: 10),
      Center(child: Text(target.rangeText, style: OrecchinoType.hero)),
      const SizedBox(height: 8),
      Text(
        [
          if (clock != null) clock,
          if (hasBearing) 'bearing ${target.bearingDeg!.round()}°',
          if (elWords != null) elWords,
          'height ${target.heightText ?? 'unknown'}',
          'heard ${target.ageSeconds.round()} s ago',
        ].join(' · '),
        textAlign: TextAlign.center,
        style: OrecchinoType.label,
      ),
    ];
    return (pointer, readouts);
  }
}

class _HudPainter extends CustomPainter {
  final _FindViewState state;
  final bool northUp;
  final double headingDeg;
  final Color color;
  final bool aircraft;
  final Listenable ease;
  final ValueListenable<double>? clock;

  _HudPainter({
    required this.state,
    required this.northUp,
    required this.headingDeg,
    required this.color,
    required this.aircraft,
    required this.ease,
    required this.clock,
  }) : super(repaint: clock == null ? ease : Listenable.merge([ease, clock]));

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 14;
    final t = clock?.value ?? 0;
    final rel = state._rel, el = state._el;

    // The scope (Flat: a plain panel inside a rule, as the mockups' radar).
    canvas.drawCircle(
        c,
        r,
        Look.flat
            ? (Paint()..color = OrecchinoColors.night)
            : (Paint()
              ..shader = RadialGradient(colors: [
                OrecchinoColors.night.withValues(alpha: 0.55),
                OrecchinoColors.void0.withValues(alpha: 0.75),
              ]).createShader(Rect.fromCircle(center: c, radius: r))));
    canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = Look.flat ? 1.5 : 1.2
          ..color = Look.flat ? OrecchinoColors.lineBright : OrecchinoColors.aqua.withValues(alpha: 0.35));
    // Where the target mark will be, so the compass letters can step aside.
    Offset? mark;
    if (rel != null) {
      final inner = r * 0.84;
      if (northUp) {
        final a = (rel - 90) * math.pi / 180;
        mark = c + Offset(math.cos(a), math.sin(a)) * inner * (1 - ((el ?? 0).clamp(0.0, 90.0)) / 90);
      } else {
        final x = rel.abs() > 90 ? inner * rel.sign : inner * rel / 90;
        mark = c + Offset(x, -inner * ((el ?? 0).clamp(-45.0, 90.0)) / 90);
      }
    }
    _ringTicks(canvas, c, r, mark);

    if (northUp) {
      _skyPlot(canvas, c, r, rel, el, t);
      return;
    }
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: r - 1)));
    // Labels go on the side away from the target so they never sit under it.
    _horizon(canvas, c, r, targetRight: (rel ?? 0) > 0);
    canvas.restore();

    final inner = r * 0.84;
    if (rel == null) return;
    final behind = rel.abs() > 90;
    final x = behind ? inner * rel.sign : inner * rel / 90;
    final y = -inner * ((el ?? 0).clamp(-45.0, 90.0)) / 90;
    final p = c + Offset(x, y);
    final align = FindGeometry.alignment(rel);
    final locked = FindGeometry.locked(rel);

    // Lock-on ring: wide when far off, tight around the boresight on target.
    final lr = inner * (1 - align) + 30 * align;
    canvas.drawCircle(
        c,
        lr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = locked ? 2.4 : 1.4
          ..color = OrecchinoColors.aqua.withValues(alpha: 0.25 + 0.6 * align));
    if (locked) {
      final pulse = (t % 1.2) / 1.2;
      canvas.drawCircle(
          c,
          lr + 18 * pulse,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = OrecchinoColors.aqua.withValues(alpha: 0.6 * (1 - pulse)));
      if (!Look.flat) {
        canvas.drawCircle(
            c,
            lr * 1.8,
            Paint()
              ..shader = RadialGradient(colors: [
                OrecchinoColors.aqua.withValues(alpha: 0.18),
                OrecchinoColors.aqua.withValues(alpha: 0),
              ]).createShader(Rect.fromCircle(center: c, radius: lr * 1.8)));
      }
    } else {
      // Brackets on the ring at the four quarters, closing in.
      final b = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..color = OrecchinoColors.aqua.withValues(alpha: 0.4 + 0.5 * align);
      for (var q = 0; q < 4; q++) {
        final a0 = q * math.pi / 2 - 0.22;
        canvas.drawArc(Rect.fromCircle(center: c, radius: lr), a0, 0.44, false, b);
      }
    }

    // The pointer: from the boresight to the target.
    final v = p - c;
    if (v.distance > 24 && !locked) {
      final dir = v / v.distance;
      final start = c + dir * 22;
      final end = p - dir * 22;
      if ((end - start).distance > 8) {
        canvas.drawLine(
            start,
            end,
            Paint()
              ..strokeWidth = 5
              ..strokeCap = StrokeCap.round
              ..shader = LinearGradient(colors: [color.withValues(alpha: 0.05), color.withValues(alpha: 0.9)])
                  .createShader(Rect.fromPoints(start, end)));
        final n = Offset(-dir.dy, dir.dx);
        canvas.drawPath(
            Path()
              ..moveTo(end.dx + dir.dx * 10, end.dy + dir.dy * 10)
              ..lineTo(end.dx - dir.dx * 6 + n.dx * 9, end.dy - dir.dy * 6 + n.dy * 9)
              ..lineTo(end.dx - dir.dx * 6 - n.dx * 9, end.dy - dir.dy * 6 - n.dy * 9)
              ..close(),
            Paint()..color = color);
      }
    }
    if (behind) {
      // Turn around: a sweeping arc along the rim on that side.
      final side = rel.sign;
      const start = -math.pi / 2;
      final sweep = side * (rel.abs() / 180) * math.pi;
      canvas.drawArc(
          Rect.fromCircle(center: c, radius: r - 8),
          start,
          sweep,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 4
            ..strokeCap = StrokeCap.round
            ..color = color.withValues(alpha: 0.8));
    }

    _target(canvas, p, t, locked);
    _boresight(canvas, c, locked);
  }

  void _ringTicks(Canvas canvas, Offset c, double r, Offset? mark) {
    final tick = Paint()..strokeCap = StrokeCap.round;
    for (var b = 0; b < 360; b += 10) {
      final a = (b - (northUp ? 0 : headingDeg) - 90) * math.pi / 180;
      final long = b % 30 == 0;
      final d = Offset(math.cos(a), math.sin(a));
      tick
        ..strokeWidth = long ? 1.6 : 1
        ..color = (b == 0 ? OrecchinoColors.aqua : OrecchinoColors.inkSubtle).withValues(alpha: long ? 0.9 : 0.45);
      canvas.drawLine(c + d * (r - (long ? 10 : 6)), c + d * r, tick);
    }
    for (final (b, l) in const [(0, 'N'), (90, 'E'), (180, 'S'), (270, 'W')]) {
      final a = (b - (northUp ? 0 : headingDeg) - 90) * math.pi / 180;
      final at = c + Offset(math.cos(a), math.sin(a)) * (r - 22);
      // A letter under the target's glow gives way to it (the ticks remain).
      if (mark != null && (mark - at).distance < 34) continue;
      _text(canvas, l, at, b == 0 ? OrecchinoColors.aqua : OrecchinoColors.inkMuted, 12, bold: true);
    }
  }

  void _horizon(Canvas canvas, Offset c, double r, {required bool targetRight}) {
    final inner = r * 0.84;
    // Sky above the horizon, a touch lighter.
    canvas.drawRect(
        Rect.fromLTRB(c.dx - r, c.dy - r, c.dx + r, c.dy),
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [OrecchinoColors.aqua.withValues(alpha: 0.0), OrecchinoColors.aqua.withValues(alpha: 0.07)],
          ).createShader(Rect.fromLTRB(c.dx - r, c.dy - r, c.dx + r, c.dy)));
    canvas.drawLine(
        Offset(c.dx - r, c.dy),
        Offset(c.dx + r, c.dy),
        Paint()
          ..strokeWidth = 1.4
          ..shader = LinearGradient(colors: [
            OrecchinoColors.aircraft.withValues(alpha: 0),
            OrecchinoColors.aircraft.withValues(alpha: 0.7),
            OrecchinoColors.aircraft.withValues(alpha: 0),
          ]).createShader(Rect.fromLTRB(c.dx - r, c.dy - 1, c.dx + r, c.dy + 1)));
    // Elevation ladder every 15 degrees.
    final ladder = Paint()
      ..strokeWidth = 1
      ..color = OrecchinoColors.inkSubtle.withValues(alpha: 0.45);
    for (var e = 15; e <= 75; e += 15) {
      final y = c.dy - inner * e / 90;
      final w = e % 30 == 0 ? 34.0 : 20.0;
      canvas.drawLine(Offset(c.dx - w, y), Offset(c.dx - 10, y), ladder);
      canvas.drawLine(Offset(c.dx + 10, y), Offset(c.dx + w, y), ladder);
      if (e % 30 == 0) {
        _text(canvas, '$e°', Offset(targetRight ? c.dx - w - 14 : c.dx + w + 14, y), OrecchinoColors.inkSubtle, 10);
      }
    }
    // Below the line (targets are mostly above it), on the far side.
    _text(
        canvas, 'HORIZON', Offset(targetRight ? c.dx - r + 46 : c.dx + r - 46, c.dy + 10), OrecchinoColors.inkSubtle, 9,
        bold: true);
  }

  void _skyPlot(Canvas canvas, Offset c, double r, double? bearing, double? el, double t) {
    final inner = r * 0.84;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = OrecchinoColors.lineBright.withValues(alpha: 0.6);
    for (final e in [30.0, 60.0]) {
      canvas.drawCircle(c, inner * (1 - e / 90), ring);
      _text(canvas, '${e.round()}°', c + Offset(4, -inner * (1 - e / 90) - 8), OrecchinoColors.inkSubtle, 10);
    }
    canvas.drawCircle(c, inner, ring..color = OrecchinoColors.aircraft.withValues(alpha: 0.45));
    if (bearing == null) return;
    final a = (bearing - 90) * math.pi / 180;
    final rr = inner * (1 - ((el ?? 0).clamp(0.0, 90.0)) / 90);
    final p = c + Offset(math.cos(a), math.sin(a)) * rr;
    final v = p - c;
    if (v.distance > 20) {
      final dir = v / v.distance;
      canvas.drawLine(
          c + dir * 10,
          p - dir * 18,
          Paint()
            ..strokeWidth = 4
            ..strokeCap = StrokeCap.round
            ..shader = LinearGradient(colors: [color.withValues(alpha: 0.05), color.withValues(alpha: 0.85)])
                .createShader(Rect.fromPoints(c, p)));
    }
    _target(canvas, p, t, false);
    canvas.drawCircle(c, 4, Paint()..color = OrecchinoColors.ink);
  }

  void _target(Canvas canvas, Offset p, double t, bool locked) {
    final glow = 26.0 + (locked ? 8 * math.sin(t * 5).abs() : 0.0);
    if (!Look.flat) {
      canvas.drawCircle(
          p,
          glow,
          Paint()
            ..shader =
                RadialGradient(colors: [color.withValues(alpha: aircraft ? 0.25 : 0.5), color.withValues(alpha: 0)])
                    .createShader(Rect.fromCircle(center: p, radius: glow)));
    }
    if (aircraft) {
      canvas.drawPath(
          Path()
            ..moveTo(p.dx, p.dy - 13)
            ..lineTo(p.dx + 11, p.dy + 9)
            ..lineTo(p.dx, p.dy + 3)
            ..lineTo(p.dx - 11, p.dy + 9)
            ..close(),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.2
            ..strokeJoin = StrokeJoin.round
            ..color = color);
    } else {
      canvas.drawCircle(p, 8, Paint()..color = color);
      canvas.drawCircle(p + const Offset(-2.5, -2.5), 3, Paint()..color = Colors.white.withValues(alpha: 0.8));
    }
  }

  void _boresight(Canvas canvas, Offset c, bool locked) {
    // The waterline symbol: where the phone points.
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = locked ? OrecchinoColors.aqua : OrecchinoColors.ink;
    canvas.drawPath(
        Path()
          ..moveTo(c.dx - 22, c.dy)
          ..lineTo(c.dx - 10, c.dy)
          ..lineTo(c.dx - 5, c.dy + 6)
          ..lineTo(c.dx, c.dy)
          ..lineTo(c.dx + 5, c.dy + 6)
          ..lineTo(c.dx + 10, c.dy)
          ..lineTo(c.dx + 22, c.dy),
        p);
  }

  /// Scale text: laid out once and cached, drawn over a dark halo so a
  /// star or the target's glow behind it cannot wash it out.
  void _text(Canvas canvas, String s, Offset at, Color color, double size, {bool bold = false}) {
    CanvasText.paint(
      canvas,
      s,
      at,
      TextStyle(
        fontFamily: OrecchinoType.display,
        fontSize: size,
        fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
        letterSpacing: bold ? 1 : 0,
        color: color,
      ),
      center: true,
    );
  }

  @override
  bool shouldRepaint(covariant _HudPainter old) =>
      old.northUp != northUp ||
      old.headingDeg != headingDeg ||
      old.color != color ||
      old.aircraft != aircraft ||
      old.clock != clock;
}

class _TargetPicker extends StatelessWidget {
  final List<LiveContactItem> contacts;
  final String currentId;
  final double? headingDeg;

  const _TargetPicker({required this.contacts, required this.currentId, required this.headingDeg});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: SafeArea(
        child: Glass(
          blur: 30,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(child: Text('What to find', style: OrecchinoType.heading)),
                IconButton(
                    tooltip: 'Close', icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.pop(context)),
              ]),
              Flexible(
                child: ListView(shrinkWrap: true, children: [
                  for (final c in contacts)
                    Semantics(
                      button: true,
                      selected: c.id == currentId,
                      label: [
                        '${c.kindWord} ${c.label}',
                        if (c.alert != null) trafficAction(c.alert!),
                        c.rangeText,
                      ].join(', '),
                      excludeSemantics: true,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () => Navigator.pop(context, c.id),
                        child: Container(
                          constraints: const BoxConstraints(minHeight: 56),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                          decoration: BoxDecoration(
                            color: c.id == currentId ? OrecchinoColors.aqua.withValues(alpha: 0.10) : null,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Row(children: [
                            ContactGlyph(aircraft: c.isAircraft, operator: c.isOperator, color: contactColor(c), size: 32),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text('${c.kindWord} ${c.label}',
                                    style: OrecchinoType.bodyStrong),
                                if (c.alert != null)
                                  Text(trafficAction(c.alert!),
                                      style: OrecchinoType.caption.copyWith(color: contactColor(c)))
                                else if (c.sublabel != null)
                                  Text(c.sublabel!, style: OrecchinoType.caption),
                              ]),
                            ),
                            Text(c.rangeText, style: OrecchinoType.metric.copyWith(fontSize: 15)),
                          ]),
                        ),
                      ),
                    ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Repaint extends ChangeNotifier {
  void tick() => notifyListeners();
}
