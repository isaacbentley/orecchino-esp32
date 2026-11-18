// living_background.dart — the aurora behind every screen. A GPU fragment
// shader (shaders/aurora.frag) whose palette follows the threat level: calm
// teal and indigo, amber for caution, red for warning. The palette cross-
// fades when the level changes. Without shaders (tests, a failed load) a
// static gradient of the same colours stands in, and with reduce motion on
// the sky stops moving. It moves on the shared ambient clock (24–30 frames
// a second, ambient_clock.dart), is rendered at a quarter of the screen's
// resolution each way and scaled up, and stands still while Map mode
// covers it or the app is in the background. The Flat look has none: a
// plain ground colour.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/traffic/traffic_rules.dart';
import 'ambient_clock.dart';
import 'theme/theme.dart';

class LivingBackground extends StatefulWidget {
  final TrafficLevel level;

  /// The aurora's render scale against the screen's pixels, each way (1/4:
  /// a sixteenth of the pixels, scaled up; the aurora has no fine detail).
  final double renderScale;

  const LivingBackground({super.key, this.level = TrafficLevel.none, this.renderScale = 0.25});

  /// Off under `flutter test` (no GPU), or to force the static gradient.
  static bool useShader = !Platform.environment.containsKey('FLUTTER_TEST');

  /// True while an opaque surface covers the whole sky (Map mode): the
  /// aurora stops moving until it is uncovered.
  static final ValueNotifier<bool> covered = ValueNotifier<bool>(false);

  static Future<ui.FragmentProgram?>? _program;

  static Future<ui.FragmentProgram?> _load() => _program ??= ui.FragmentProgram.fromAsset('shaders/aurora.frag')
      .then<ui.FragmentProgram?>((p) => p)
      .catchError((Object _) => null);

  @override
  State<LivingBackground> createState() => _LivingBackgroundState();
}

class _LivingBackgroundState extends State<LivingBackground> {
  ui.FragmentShader? _shader;
  ValueListenable<double>? _clock; // the ambient clock while listened to
  ValueListenable<double>? _available; // the ambient clock, or null (still)
  final _frame = _Frame();
  late List<Color> _from = OrecchinoColors.aurora(widget.level);
  late List<Color> _to = _from;
  double _mix = 1; // 0 = _from, 1 = _to
  double _time = 0;
  double? _lastClock;
  double _pulse = 0;

  @override
  void initState() {
    super.initState();
    LivingBackground.covered.addListener(_sync);
    if (LivingBackground.useShader) {
      LivingBackground._load().then((p) {
        if (!mounted || p == null) return;
        setState(() => _shader = p.fragmentShader());
        _sync();
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _available = AmbientClock.of(context);
    if (_available == null) _mix = 1;
    _sync();
  }

  @override
  void didUpdateWidget(LivingBackground old) {
    super.didUpdateWidget(old);
    if (old.level != widget.level) {
      _from = _current;
      _to = OrecchinoColors.aurora(widget.level);
      _mix = _available == null ? 1 : 0;
      if (_available == null) _pulse = 0;
    }
    _sync();
  }

  bool get _alert => widget.level == TrafficLevel.warning || widget.level == TrafficLevel.caution;

  /// Listen to the ambient clock only while there is something to move:
  /// the shader's drift (uncovered), or the palette's cross-fade.
  void _sync() {
    // Flat (look.dart): a plain ground, nothing moves.
    final want = !Look.flat &&
        _available != null &&
        ((_shader != null && !LivingBackground.covered.value) || _mix < 1);
    final next = want ? _available : null;
    if (next == _clock) return;
    _clock?.removeListener(_onTick);
    _clock = next;
    _lastClock = null;
    _clock?.addListener(_onTick);
  }

  void _onTick() {
    final now = _clock!.value;
    final dt = _lastClock == null ? 0.0 : (now - _lastClock!).clamp(0.0, 0.25);
    _lastClock = now;
    _time += dt;
    if (_mix < 1) {
      _mix = (_mix + dt / 1.2).clamp(0, 1);
      if (_mix >= 1) scheduleMicrotask(_sync); // the fade is done: stop if nothing else moves
    }
    _pulse = _alert ? 0.5 + 0.5 * math.sin(_time * 2 * math.pi / 2.4) : 0;
    _frame.tick();
  }

  List<Color> get _current => [for (var i = 0; i < 3; i++) Color.lerp(_from[i], _to[i], Curves.easeInOut.transform(_mix))!];

  @override
  void dispose() {
    LivingBackground.covered.removeListener(_sync);
    _clock?.removeListener(_onTick);
    _frame.dispose();
    _shader?.dispose();
    _image?.dispose();
    super.dispose();
  }

  ui.Image? _image; // the last aurora frame, freed when the next is drawn

  @override
  Widget build(BuildContext context) {
    if (Look.flat) {
      scheduleMicrotask(_sync); // stop listening if a switch left it on
      return ColoredBox(color: OrecchinoColors.void0, child: const SizedBox.expand());
    }
    return RepaintBoundary(
      child: CustomPaint(
        painter: _SkyPainter(
          this,
          _shader,
          to: _to,
          dpr: MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
          scale: widget.renderScale,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _SkyPainter extends CustomPainter {
  final _LivingBackgroundState s;
  final ui.FragmentShader? shader;
  final List<Color> to;
  final double dpr;
  final double scale;

  _SkyPainter(this.s, this.shader, {required this.to, required this.dpr, required this.scale})
      : super(repaint: s._frame);

  @override
  void paint(Canvas canvas, Size size) {
    final colors = s._current;
    final rect = Offset.zero & size;
    final sh = shader;
    if (sh != null && !size.isEmpty) {
      // Rendered small and scaled up: the aurora is soft, so a quarter of
      // the screen's resolution each way looks the same at a sixteenth of
      // the shader work.
      final px = (dpr * scale).clamp(0.25, 4.0);
      final w = math.max(1, (size.width * px).ceil()), h = math.max(1, (size.height * px).ceil());
      var i = 0;
      sh
        ..setFloat(i++, w.toDouble())
        ..setFloat(i++, h.toDouble())
        ..setFloat(i++, s._time);
      for (final c in colors) {
        sh
          ..setFloat(i++, c.r)
          ..setFloat(i++, c.g)
          ..setFloat(i++, c.b);
      }
      sh
        ..setFloat(i++, s._pulse)
        ..setFloat(i++, px);
      final rec = ui.PictureRecorder();
      Canvas(rec).drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..shader = sh);
      final pic = rec.endRecording();
      final img = pic.toImageSync(w, h);
      pic.dispose();
      canvas.drawImageRect(img, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), rect,
          Paint()..filterQuality = FilterQuality.low);
      s._image?.dispose();
      s._image = img;
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

  /// Time, the cross-fade and the pulse repaint through the state's frame
  /// notifier; a rebuild repaints only for a new palette, shader or scale.
  @override
  bool shouldRepaint(_SkyPainter old) =>
      old.shader != shader || old.dpr != dpr || old.scale != scale || !listEquals(old.to, to);
}

class _Frame extends ChangeNotifier {
  void tick() => notifyListeners();
}
