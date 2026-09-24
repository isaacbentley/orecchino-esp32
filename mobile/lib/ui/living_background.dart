// living_background.dart — the aurora behind every screen. A GPU fragment
// shader (shaders/aurora.frag) whose palette follows the threat level: calm
// teal and indigo, amber for caution, red for warning. The palette cross-
// fades when the level changes. Without shaders (tests, a failed load) a
// static gradient of the same colours stands in, and with reduce motion on
// the sky stops moving.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/traffic/traffic_rules.dart';
import 'theme/theme.dart';

class LivingBackground extends StatefulWidget {
  final TrafficLevel level;

  const LivingBackground({super.key, this.level = TrafficLevel.none});

  /// Off under `flutter test` (no GPU), or to force the static gradient.
  static bool useShader = !Platform.environment.containsKey('FLUTTER_TEST');

  static Future<ui.FragmentProgram?>? _program;

  static Future<ui.FragmentProgram?> _load() => _program ??= ui.FragmentProgram.fromAsset('shaders/aurora.frag')
      .then<ui.FragmentProgram?>((p) => p)
      .catchError((Object _) => null);

  @override
  State<LivingBackground> createState() => _LivingBackgroundState();
}

class _LivingBackgroundState extends State<LivingBackground> with SingleTickerProviderStateMixin {
  ui.FragmentShader? _shader;
  late final Ticker _ticker = createTicker(_onTick);
  final _time = ValueNotifier<double>(0);
  late List<Color> _from = OrecchinoColors.aurora(widget.level);
  late List<Color> _to = _from;
  double _mix = 1; // 0 = _from, 1 = _to
  Duration _last = Duration.zero;
  double _pulse = 0;

  @override
  void initState() {
    super.initState();
    if (LivingBackground.useShader) {
      LivingBackground._load().then((p) {
        if (!mounted || p == null) return;
        setState(() => _shader = p.fragmentShader());
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTicker();
  }

  @override
  void didUpdateWidget(LivingBackground old) {
    super.didUpdateWidget(old);
    if (old.level != widget.level) {
      _from = _current;
      _to = OrecchinoColors.aurora(widget.level);
      _mix = Motion.reduced(context) ? 1 : 0;
    }
    _syncTicker();
  }

  void _syncTicker() {
    final run = !Motion.reduced(context);
    if (run && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    } else if (!run && _ticker.isActive) {
      _ticker.stop();
      _mix = 1;
    }
  }

  /// The sky drifts slowly: 24 frames a second look the same as 120 and
  /// cost the GPU a fifth as much.
  static const double _frameS = 1 / 24;
  double _pending = 0;

  void _onTick(Duration elapsed) {
    final dt = _last == Duration.zero ? 0.016 : (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    _pending += dt;
    if (_pending < _frameS) return;
    if (_mix < 1) _mix = (_mix + _pending / 1.2).clamp(0, 1);
    final alert = widget.level == TrafficLevel.warning || widget.level == TrafficLevel.caution;
    _pulse = alert ? 0.5 + 0.5 * math.sin(elapsed.inMicroseconds / 1e6 * 2 * math.pi / 2.4) : 0;
    _time.value = _time.value + _pending;
    _pending = 0;
  }

  List<Color> get _current => [for (var i = 0; i < 3; i++) Color.lerp(_from[i], _to[i], Curves.easeInOut.transform(_mix))!];

  @override
  void dispose() {
    _ticker.dispose();
    _time.dispose();
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _SkyPainter(this, _shader),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _SkyPainter extends CustomPainter {
  final _LivingBackgroundState s;
  final ui.FragmentShader? shader;

  _SkyPainter(this.s, this.shader) : super(repaint: s._time);

  @override
  void paint(Canvas canvas, Size size) {
    final colors = s._current;
    final rect = Offset.zero & size;
    final sh = shader;
    if (sh != null) {
      var i = 0;
      sh
        ..setFloat(i++, size.width)
        ..setFloat(i++, size.height)
        ..setFloat(i++, s._time.value);
      for (final c in colors) {
        sh
          ..setFloat(i++, c.r)
          ..setFloat(i++, c.g)
          ..setFloat(i++, c.b);
      }
      sh.setFloat(i++, s._pulse);
      canvas.drawRect(rect, Paint()..shader = sh);
      return;
    }
    // Static stand-in: deep base, a nebula low left, a curtain high right.
    canvas.drawRect(rect, Paint()..color = colors[0]);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.6, 0.2),
          radius: 1.1,
          colors: [colors[1].withValues(alpha: 0.8), colors[1].withValues(alpha: 0)],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0.5, -0.75),
          radius: 0.9,
          colors: [colors[2].withValues(alpha: 0.9), colors[2].withValues(alpha: 0)],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_SkyPainter old) => true; // palette and time live in the state
}
