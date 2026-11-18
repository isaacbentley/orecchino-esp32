// glass.dart — frosted-glass building blocks: panels, pill buttons, tags,
// signal bars and the breathing connection light.
//
// Glass is a backdrop blur, a night tint, a top-lit veil and a hairline edge;
// text on it keeps 4.5:1 over the brightest background (colors.dart).
//
// How the blur is made follows the power mode ([GlassScope]): each panel
// its own blur (Full), panels on one screen sharing one backdrop read
// (Balanced: `BackdropFilter.grouped` under the screen's `BackdropGroup`),
// or no blur at all, a denser tint instead (Saver).
//
// In the Flat look (look.dart) every one of these is the mockups' flat
// component instead: an opaque panel with a 1 px rule and at most an 8 px
// radius, a level shown as a dark banner of its colour, no blur, no glow,
// and a connection light that is a still dot.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/power/power_policy.dart';
import 'ambient_clock.dart';
import 'theme/theme.dart';

/// How [Glass] frosts, for the widgets below: see the file comment.
class GlassScope extends InheritedWidget {
  final GlassMode mode;

  const GlassScope({super.key, required this.mode, required super.child});

  static GlassMode of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GlassScope>()?.mode ?? GlassMode.grouped;

  @override
  bool updateShouldNotify(GlassScope old) => old.mode != mode;
}

class Glass extends StatelessWidget {
  /// Saver's tint: night at 0.8 instead of 0.62 (no blur softens the sky).
  static const Color _denseTint = Color(0xCC0A1020);

  final Widget child;
  final BorderRadius? _radius;
  final EdgeInsetsGeometry padding;

  /// The panel's corners: the look's panel radius unless given.
  BorderRadius get borderRadius => _radius ?? BorderRadius.circular(OrecchinoTheme.radius);

  /// An optional colour wash (a traffic level), mixed into the tint.
  final Color? wash;
  final Color? edge;
  final double blur;
  final List<BoxShadow>? shadows;

  const Glass({
    super.key,
    required this.child,
    BorderRadius? borderRadius,
    this.padding = EdgeInsets.zero,
    this.wash,
    this.edge,
    this.blur = 22,
    this.shadows,
  }) : _radius = borderRadius;

  /// Flat: a level or selection colour as the mockups' dark banner
  /// (#3A1414 for their red).
  static Color flatWash(Color w) =>
      Color.from(alpha: 1, red: w.r * 0.25, green: w.g * 0.19, blue: w.b * 0.19);

  /// Flat corners: never rounder than the look's panel radius.
  static BorderRadius flatRadius(BorderRadius r) {
    final max = OrecchinoTheme.radius;
    Radius c(Radius x) => x.x > max ? Radius.circular(max) : x;
    return BorderRadius.only(
        topLeft: c(r.topLeft), topRight: c(r.topRight), bottomLeft: c(r.bottomLeft), bottomRight: c(r.bottomRight));
  }

  Widget _flat() {
    final r = flatRadius(borderRadius);
    final w = wash;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: w == null ? OrecchinoColors.night : flatWash(w),
        borderRadius: r,
        border: Border.all(color: edge ?? (w == null ? OrecchinoColors.line : w.withValues(alpha: 0.55))),
      ),
      child: ClipRRect(
        borderRadius: r,
        child: Material(type: MaterialType.transparency, child: Padding(padding: padding, child: child)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (Look.flat) return _flat();
    final w = wash;
    final mode = GlassScope.of(context);
    // Without a blur the tint is denser, so text keeps its contrast over
    // the sharp sky behind it.
    final tint = mode == GlassMode.tint ? Glass._denseTint : OrecchinoColors.glassTint;
    final top = Color.alphaBlend(OrecchinoColors.glassVeil, tint);
    final bottom = Color.alphaBlend(OrecchinoColors.glassVeilLow, tint);
    final filter = ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur);
    Widget frost(Widget child) => switch (mode) {
          GlassMode.live => BackdropFilter(filter: filter, child: child),
          GlassMode.grouped => BackdropFilter.grouped(filter: filter, child: child),
          GlassMode.tint => child,
        };
    return DecoratedBox(
      decoration: BoxDecoration(borderRadius: borderRadius, boxShadow: shadows),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: frost(
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: borderRadius,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: w == null
                    ? [top, bottom]
                    : [
                        Color.alphaBlend(w.withValues(alpha: OrecchinoColors.washAlpha), top),
                        Color.alphaBlend(w.withValues(alpha: OrecchinoColors.washAlpha * 0.6), bottom),
                      ],
              ),
              border: Border.all(color: edge ?? OrecchinoColors.glassEdge, width: 1),
            ),
            child: Material(type: MaterialType.transparency, child: Padding(padding: padding, child: child)),
          ),
        ),
      ),
    );
  }
}

/// A glass pill that is a button: 44 pt minimum, one semantics node.
class GlassButton extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final String semanticLabel;
  final bool selected;
  final EdgeInsetsGeometry padding;
  final Color? wash;

  const GlassButton({
    super.key,
    required this.child,
    required this.semanticLabel,
    this.onTap,
    this.selected = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    this.wash,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: semanticLabel,
      excludeSemantics: true,
      child: Glass(
        borderRadius: BorderRadius.circular(OrecchinoTheme.pill),
        wash: wash ?? (selected ? OrecchinoColors.aqua : null),
        edge: selected ? OrecchinoColors.aqua.withValues(alpha: 0.55) : null,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            customBorder: Look.flat
                ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(OrecchinoTheme.radiusSmall))
                : const StadiumBorder(),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: OrecchinoTheme.minTarget, minHeight: OrecchinoTheme.minTarget),
              child: Padding(padding: padding, child: Center(widthFactor: 1, heightFactor: 1, child: child)),
            ),
          ),
        ),
      ),
    );
  }
}

/// A segmented glass control: one pill, several options, a sliding light.
class GlassSegmented<T> extends StatelessWidget {
  final List<(T, String, String)> options; // value, label, semantics
  final T value;
  final ValueChanged<T> onChanged;

  const GlassSegmented({super.key, required this.options, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    // A Wrap, not a Row: at large text sizes the options flow onto a second
    // line instead of overflowing.
    return Glass(
      borderRadius: BorderRadius.circular(24),
      padding: const EdgeInsets.all(2),
      child: Wrap(
        children: [
          for (final (v, label, sem) in options)
            Semantics(
              button: true,
              selected: v == value,
              label: sem,
              excludeSemantics: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(v),
                child: AnimatedContainer(
                  duration: Motion.of(context, Motion.base),
                  curve: Motion.standard,
                  constraints: const BoxConstraints(minWidth: OrecchinoTheme.minTarget, minHeight: OrecchinoTheme.minTarget),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  decoration: BoxDecoration(
                    color: v == value
                        ? (Look.flat ? OrecchinoColors.raised : OrecchinoColors.aqua.withValues(alpha: 0.18))
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(Look.flat ? OrecchinoTheme.radiusSmall - 2 : 999),
                    border: Border.all(color: v == value ? OrecchinoColors.aqua.withValues(alpha: 0.6) : Colors.transparent),
                  ),
                  child: Text(
                    label,
                    style: OrecchinoType.label.copyWith(
                      color: v == value ? OrecchinoColors.aqua : OrecchinoColors.inkMuted,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A small outlined tag: a source, a capability, a status word.
class Tag extends StatelessWidget {
  final String text;
  final Color? _color;
  final bool filled;
  final IconData? icon;

  Color get color => _color ?? OrecchinoColors.inkMuted;

  const Tag(this.text, {super.key, Color? color, this.filled = false, this.icon}) : _color = color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: filled ? color : color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(OrecchinoTheme.pill),
        border: Border.all(color: color.withValues(alpha: filled ? 1 : 0.45)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[
          Icon(icon, size: 12, color: filled ? OrecchinoColors.void0 : color),
          const SizedBox(width: 4),
        ],
        Flexible(
          child: Text(
            text,
            style: OrecchinoType.eyebrow.copyWith(
              color: filled ? OrecchinoColors.void0 : color,
              letterSpacing: 0.8,
            ),
          ),
        ),
      ]),
    );
  }
}

/// Section heading: an eyebrow with a hairline.
class Eyebrow extends StatelessWidget {
  final String text;
  final Widget? trailing;

  const Eyebrow(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: LayoutBuilder(
        builder: (context, box) => Row(children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: box.maxWidth * 0.75),
            child: Semantics(header: true, child: Text(text.toUpperCase(), style: OrecchinoType.eyebrow)),
          ),
          const SizedBox(width: 10),
          Expanded(child: Divider(height: 1, color: OrecchinoColors.line)),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ]),
      ),
    );
  }
}

/// Metric tiles in two even columns (one on a narrow width or at large
/// text sizes, where a tile needs the room).
class MetricGrid extends StatelessWidget {
  final List<Widget> children;
  final double spacing;

  const MetricGrid({super.key, required this.children, this.spacing = 10});

  @override
  Widget build(BuildContext context) {
    final big = MediaQuery.textScalerOf(context).scale(1) > 1.5;
    return LayoutBuilder(builder: (context, box) {
      final cols = box.maxWidth < 280 || big ? 1 : 2;
      final w = (box.maxWidth - spacing * (cols - 1)) / cols;
      return Wrap(
        spacing: spacing,
        runSpacing: spacing,
        children: [for (final c in children) SizedBox(width: w, child: c)],
      );
    });
  }
}

/// Four bars; [level] 0..4 lit.
class SignalBars extends StatelessWidget {
  final int level;
  final Color? _color;
  final double height;

  Color get color => _color ?? OrecchinoColors.aqua;

  const SignalBars({super.key, required this.level, Color? color, this.height = 14}) : _color = color;

  /// Bars for a BLE / Wi-Fi RSSI: >= -55 four, -65 three, -75 two, else one.
  static int fromRssi(int? rssi) =>
      rssi == null ? 0 : (rssi >= -55 ? 4 : rssi >= -65 ? 3 : rssi >= -75 ? 2 : 1);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: height * 1.3,
      height: height,
      child: CustomPaint(painter: _BarsPainter(level, color)),
    );
  }
}

class _BarsPainter extends CustomPainter {
  final int level;
  final Color color;
  _BarsPainter(this.level, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width / 4;
    for (var i = 0; i < 4; i++) {
      final h = size.height * (0.35 + 0.65 * i / 3);
      final r = RRect.fromLTRBR(i * w + 1, size.height - h, (i + 1) * w - 1, size.height, const Radius.circular(1.5));
      canvas.drawRRect(r, Paint()..color = i < level ? color : OrecchinoColors.lineBright);
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) => old.level != level || old.color != color;
}

/// The connection light: a core with a halo that breathes while [active]
/// (faster while [busy]), on the shared ambient clock (24–30 frames a
/// second; a vsync ticker would ask for a frame on every refresh). Still
/// when motion is reduced, in Saver and in Flat.
class BreathingDot extends StatefulWidget {
  final Color color;
  final bool active;
  final bool busy;
  final double size;

  const BreathingDot({super.key, required this.color, this.active = true, this.busy = false, this.size = 18});

  @override
  State<BreathingDot> createState() => _BreathingDotState();
}

class _BreathingDotState extends State<BreathingDot> {
  /// The ambient clock, or null: a still light.
  ValueListenable<double>? _clock;

  /// The clock time the breathing started; null while resting.
  double? _from;
  bool? _wasActive, _wasBusy;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final clock = AmbientClock.of(context);
    if (clock != _clock) {
      _clock?.removeListener(_onClock);
      _clock = clock;
      _from = null;
      _wasActive = null; // a new clock: start over
    }
    _sync();
  }

  @override
  void didUpdateWidget(BreathingDot old) {
    super.didUpdateWidget(old);
    _sync();
  }

  /// Busy (connecting): breathes quickly until it is not. Active: breathes
  /// three times when it becomes active, then rests as a steady glow, so an
  /// idle screen is not animating for nothing. No clock (Reduce Motion,
  /// Saver, the background) or Flat: still.
  void _sync() {
    final clock = _clock;
    final changed = widget.active != _wasActive || widget.busy != _wasBusy;
    _wasActive = widget.active;
    _wasBusy = widget.busy;
    if (clock == null || Look.flat || !widget.active) {
      _rest();
      return;
    }
    if (!changed) return;
    _from = clock.value;
    clock.removeListener(_onClock); // busy toggling while active: never two
    clock.addListener(_onClock);
  }

  /// Resting: the light no longer listens, so it does not keep the clock
  /// running on a screen where nothing else moves.
  void _rest() {
    _clock?.removeListener(_onClock);
    _from = null;
  }

  /// Three breaths after becoming active, the light rests.
  void _onClock() {
    final from = _from, clock = _clock;
    if (from == null || clock == null || widget.busy || !mounted) return;
    if (clock.value - from >= 3 * Motion.breath.inMilliseconds / 1000) setState(_rest);
  }

  @override
  void dispose() {
    _clock?.removeListener(_onClock);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: widget.size * 2.2,
      // Its own layer: while it breathes, only the light repaints (not the
      // list it sits in), and without a rebuild.
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _BreathPainter(widget.color, _from == null ? null : _clock, _from ?? 0, widget.active, widget.busy),
        ),
      ),
    );
  }
}

class _BreathPainter extends CustomPainter {
  final Color color;
  final ValueListenable<double>? clock; // null: a still light
  final double from; // the clock time the breathing started
  final bool active;
  final bool busy;
  _BreathPainter(this.color, this.clock, this.from, this.active, this.busy) : super(repaint: clock);

  /// The breath's phase, 0..1: one breath per [Motion.breath] (0.9 s busy).
  double get _phase {
    final c = clock;
    if (c == null) return 0.35;
    final period = busy ? 0.9 : Motion.breath.inMilliseconds / 1000;
    return ((c.value - from) / period) % 1.0;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final t = _phase;
    final c = size.center(Offset.zero);
    if (Look.flat) {
      final r = size.shortestSide / 2.2 / 2;
      canvas.drawCircle(c, r * 0.62, Paint()..color = active ? color : color.withValues(alpha: 0.6));
      if (!active) {
        canvas.drawCircle(
            c,
            r * 0.9,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1
              ..color = color.withValues(alpha: 0.5));
      }
      return;
    }
    final r = size.shortestSide / 2.2 / 2;
    if (active) {
      // Two rings expanding out of phase, and a soft glow that swells.
      for (final phase in [0.0, 0.5]) {
        final p = (t + phase) % 1.0;
        canvas.drawCircle(
          c,
          r * (1 + 1.1 * p),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = color.withValues(alpha: 0.55 * (1 - p)),
        );
      }
      final swell = 0.5 + 0.5 * math.sin(t * 2 * math.pi);
      canvas.drawCircle(
        c,
        r * 1.6,
        Paint()
          ..shader = RadialGradient(colors: [color.withValues(alpha: 0.35 + 0.2 * swell), color.withValues(alpha: 0)])
              .createShader(Rect.fromCircle(center: c, radius: r * 1.6)),
      );
    }
    canvas.drawCircle(c, r * 0.62, Paint()..color = active ? color : color.withValues(alpha: 0.6));
    if (!active) {
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = color.withValues(alpha: 0.5),
      );
    }
  }

  @override
  bool shouldRepaint(_BreathPainter old) =>
      old.clock != clock || old.from != from || old.color != color || old.active != active || old.busy != busy;
}
