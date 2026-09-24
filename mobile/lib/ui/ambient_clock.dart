// ambient_clock.dart — one shared clock for the ambient motion (the aurora,
// the radar sweep, the glowing marks, Find's lock pulse). A Timer at 24–30
// frames a second, not a vsync Ticker: slow drift looks the same at 24 as
// at 120, and a Ticker asks the engine for a frame on every vsync (up to
// 120 a second on ProMotion) even when the painter skips it.
//
// The clock runs only while something listens, the rate is above zero and
// it is not paused (the app in the background). [AmbientMotion] tells the
// widgets below it whether ambient motion is on at all (off with Reduce
// Motion, in Saver, and in the background); [AmbientClock.of] gives them
// the clock, or null for a still frame.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'theme/motion.dart';

class AmbientClock extends ChangeNotifier implements ValueListenable<double> {
  AmbientClock._();

  /// The app's one ambient clock.
  static final AmbientClock instance = AmbientClock._();

  int _hz = 24;
  bool _paused = false;
  Timer? _timer;
  int _timerHz = 0;
  double _value = 0;

  /// Seconds of ambient motion so far (it does not advance while stopped).
  @override
  double get value => _value;

  /// Frames a second; 0 stops the clock.
  int get hz => _hz;
  set hz(int v) {
    v = v.clamp(0, 60);
    if (v == _hz) return;
    _hz = v;
    _sync();
  }

  /// Paused with the app in the background.
  bool get paused => _paused;
  set paused(bool v) {
    if (v == _paused) return;
    _paused = v;
    _sync();
  }

  /// Whether the timer is running now.
  bool get running => _timer != null;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _sync();
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    _sync();
  }

  void _sync() {
    final want = hasListeners && _hz > 0 && !_paused;
    if (_timer != null && (!want || _timerHz != _hz)) {
      _timer!.cancel();
      _timer = null;
    }
    if (want && _timer == null) {
      _timerHz = _hz;
      _timer = Timer.periodic(Duration(microseconds: 1000000 ~/ _hz), _tick);
    }
  }

  void _tick(Timer _) {
    _value += 1 / _timerHz;
    notifyListeners();
  }

  /// The clock for [context], or null for a still frame: ambient motion off
  /// ([AmbientMotion]), Reduce Motion, or tickers muted (a hidden screen).
  static ValueListenable<double>? of(BuildContext context) {
    if (!AmbientMotion.on(context) || Motion.reduced(context) || !TickerMode.valuesOf(context).enabled) return null;
    return instance;
  }

  @visibleForTesting
  void resetForTest() {
    _timer?.cancel();
    _timer = null;
    _hz = 24;
    _paused = false;
  }
}

/// Whether ambient motion is on below this widget (the power mode, and the
/// app in the foreground). Without one, it is on.
class AmbientMotion extends InheritedWidget {
  final bool enabled;

  const AmbientMotion({super.key, required this.enabled, required super.child});

  static bool on(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AmbientMotion>()?.enabled ?? true;

  @override
  bool updateShouldNotify(AmbientMotion old) => old.enabled != enabled;
}
