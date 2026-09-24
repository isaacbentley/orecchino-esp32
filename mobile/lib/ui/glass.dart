// glass.dart — frosted-glass building blocks: panels, pill buttons, tags,
// signal bars and the breathing connection light.
//
// Glass is a backdrop blur, a night tint, a top-lit veil and a hairline edge;
// text on it keeps 4.5:1 over the brightest background (colors.dart).
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'theme/theme.dart';

class Glass extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry padding;

  /// An optional colour wash (a traffic level), mixed into the tint.
  final Color? wash;
  final Color? edge;
  final double blur;
  final List<BoxShadow>? shadows;

  const Glass({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(OrecchinoTheme.radius)),
    this.padding = EdgeInsets.zero,
    this.wash,
    this.edge,
    this.blur = 22,
    this.shadows,
  });

  @override
  Widget build(BuildContext context) {
    final w = wash;
    final top = Color.alphaBlend(OrecchinoColors.glassVeil, OrecchinoColors.glassTint);
    final bottom = Color.alphaBlend(OrecchinoColors.glassVeilLow, OrecchinoColors.glassTint);
    return DecoratedBox(
      decoration: BoxDecoration(borderRadius: borderRadius, boxShadow: shadows),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: DecoratedBox(
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
        borderRadius: BorderRadius.circular(999),
        wash: wash ?? (selected ? OrecchinoColors.aqua : null),
        edge: selected ? OrecchinoColors.aqua.withValues(alpha: 0.55) : null,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            customBorder: const StadiumBorder(),
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
                    color: v == value ? OrecchinoColors.aqua.withValues(alpha: 0.18) : Colors.transparent,
                    borderRadius: BorderRadius.circular(999),
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
  final Color color;
  final bool filled;
  final IconData? icon;

  const Tag(this.text, {super.key, this.color = OrecchinoColors.inkMuted, this.filled = false, this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: filled ? color : color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
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
          const Expanded(child: Divider(height: 1, color: OrecchinoColors.line)),
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
  final Color color;
  final double height;

  const SignalBars({super.key, required this.level, this.color = OrecchinoColors.aqua, this.height = 14});

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
/// (faster while [busy]). Still when motion is reduced.
class BreathingDot extends StatefulWidget {
  final Color color;
  final bool active;
  final bool busy;
  final double size;

  const BreathingDot({super.key, required this.color, this.active = true, this.busy = false, this.size = 18});

  @override
  State<BreathingDot> createState() => _BreathingDotState();
}

class _BreathingDotState extends State<BreathingDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: Motion.breath);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(BreathingDot old) {
    super.didUpdateWidget(old);
    _sync();
  }

  bool? _wasActive, _wasBusy;

  /// Busy (connecting): breathes quickly until it is not. Active: breathes
  /// three times when it becomes active, then rests as a steady glow, so an
  /// idle screen is not animating for nothing. Reduce motion: still.
  void _sync() {
    final reduced = Motion.reduced(context);
    final changed = widget.active != _wasActive || widget.busy != _wasBusy;
    _wasActive = widget.active;
    _wasBusy = widget.busy;
    if (reduced || !widget.active) {
      if (_c.isAnimating) _c.stop();
      _c.value = 0.35;
      return;
    }
    if (!changed) return;
    _c.duration = widget.busy ? const Duration(milliseconds: 900) : Motion.breath;
    if (widget.busy) {
      _c.repeat();
    } else {
      _c.repeat(count: 3).whenCompleteOrCancel(() {
        if (mounted && !_c.isAnimating) _c.value = 0.35;
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: widget.size * 2.2,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => CustomPaint(painter: _BreathPainter(widget.color, _c.value, widget.active)),
      ),
    );
  }
}

class _BreathPainter extends CustomPainter {
  final Color color;
  final double t;
  final bool active;
  _BreathPainter(this.color, this.t, this.active);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
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
  bool shouldRepaint(_BreathPainter old) => old.t != t || old.color != color || old.active != active;
}
