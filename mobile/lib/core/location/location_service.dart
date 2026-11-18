// location_service.dart — the phone's position and compass heading.
//
// Failures are reported, not swallowed: [status] says why there is no
// position (permission denied, location services off, an error), and the
// screens say so instead of showing a range from nowhere. Pushing the
// position to a detector is the app controller's job, and only to a
// verified, pinned detector.
//
// How hard it works follows the power policy ([configure]): high accuracy
// with a 5 m filter on Live and Find, medium with 50 m (every 30 s at most
// on Android) elsewhere, none at all in Saver's background (the last fix
// stays). The compass runs only while a screen that turns with it is
// visible, and its heading has its own listenable ([heading]), published at
// most [compassHz] times a second and only for a turn of 2° or more (or any
// turn after a second), so turning the phone never rebuilds the whole app.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';

import '../power/power_policy.dart';

class PhoneLocation {
  final double lat;
  final double lon;
  final double? altitudeM; // only when the platform gives a valid altitude
  final double? accuracyM;
  final int timeMs;

  const PhoneLocation({
    required this.lat,
    required this.lon,
    this.altitudeM,
    this.accuracyM,
    required this.timeMs,
  });
}

enum LocationStatus { starting, ok, denied, deniedForever, servicesOff, error }

class LocationService extends ChangeNotifier {
  PhoneLocation? _current;
  final ValueNotifier<double?> _heading = ValueNotifier<double?>(null);
  bool _started = false; // start() ran for real (the fakes in tests skip it)
  LocationPrecision _precision = LocationPrecision.high;
  LocationPrecision? _subscribed; // the precision of the running stream
  int _compassHz = 10;
  int _headingMs = 0;
  double? _rawHeading;
  LocationStatus _status = LocationStatus.starting;
  String? _error;
  StreamSubscription<Position>? _posSub;
  StreamSubscription<CompassEvent>? _compassSub;
  StreamSubscription<ServiceStatus>? _svcSub;
  bool _disposed = false;

  PhoneLocation? get currentLocation => _current;

  /// Compass heading, degrees true-ish (magnetic where the platform gives
  /// no true heading); null when the phone has no compass or no reading.
  double? get headingDeg => _heading.value;

  /// The heading, throttled (see the file comment); only the views that
  /// turn with the phone listen to it.
  ValueListenable<double?> get heading => _heading;

  LocationPrecision get precision => _precision;
  int get compassHz => _compassHz;
  bool get compassRunning => _compassSub != null;

  /// Apply the power policy: position precision, and the compass rate
  /// (0 = off).
  void configure({required LocationPrecision precision, required int compassHz}) {
    _precision = precision;
    _compassHz = compassHz;
    if (!_started || _disposed) return;
    if (compassHz > 0) {
      _startCompass();
    } else {
      _stopCompass();
    }
    if (_status == LocationStatus.ok || _subscribed != null) _subscribe();
  }
  LocationStatus get status => _status;
  String? get error => _error;

  /// Words for the screens, or null when the position is fine.
  String? get problem => switch (_status) {
        LocationStatus.ok => null,
        LocationStatus.starting => 'Finding your position',
        LocationStatus.denied => 'Location permission denied: no range or bearing',
        LocationStatus.deniedForever => 'Location permission denied in Settings: no range or bearing',
        LocationStatus.servicesOff => 'Location services are off: no range or bearing',
        LocationStatus.error => 'No position: ${_error ?? 'unknown error'}',
      };

  void _set(LocationStatus s, [String? err]) {
    if (_disposed) return;
    _status = s;
    _error = err;
    notifyListeners();
  }

  Future<void> start() async {
    _started = true;
    if (_compassHz > 0) _startCompass();
    try {
      _svcSub ??= Geolocator.getServiceStatusStream().listen((s) {
        if (s == ServiceStatus.disabled) {
          _set(LocationStatus.servicesOff);
        } else if (_status == LocationStatus.servicesOff) {
          start();
        }
      }, onError: (Object e) => debugPrint('location service status: $e'));
    } catch (e) {
      debugPrint('location service status unavailable: $e');
    }
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _set(LocationStatus.servicesOff);
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied) {
        _set(LocationStatus.denied);
        return;
      }
      if (perm == LocationPermission.deniedForever) {
        _set(LocationStatus.deniedForever);
        return;
      }
      _subscribed = null;
      _subscribe();
    } catch (e) {
      _set(LocationStatus.error, e.toString());
    }
  }

  static LocationSettings settingsFor(LocationPrecision p) {
    if (p == LocationPrecision.high) {
      return const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 5);
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
          accuracy: LocationAccuracy.medium, distanceFilter: 50, intervalDuration: const Duration(seconds: 30));
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return AppleSettings(accuracy: LocationAccuracy.medium, distanceFilter: 50);
    }
    return const LocationSettings(accuracy: LocationAccuracy.medium, distanceFilter: 50);
  }

  /// (Re)start the position stream at the current precision; none when off.
  void _subscribe() {
    if (_subscribed == _precision && (_posSub != null || _precision == LocationPrecision.off)) return;
    _posSub?.cancel();
    _posSub = null;
    _subscribed = _precision;
    if (_precision == LocationPrecision.off) return;
    try {
      _posSub = Geolocator.getPositionStream(locationSettings: settingsFor(_precision)).listen(_onPosition,
          onError: (Object e) {
        if (e is LocationServiceDisabledException) {
          _set(LocationStatus.servicesOff);
        } else if (e is PermissionDeniedException) {
          _set(LocationStatus.denied);
        } else {
          _set(LocationStatus.error, e.toString());
        }
      });
    } catch (e) {
      _set(LocationStatus.error, e.toString());
    }
  }

  void _onPosition(Position pos) {
    _current = PhoneLocation(
      lat: pos.latitude,
      lon: pos.longitude,
      altitudeM: pos.altitudeAccuracy > 0 ? pos.altitude : null,
      accuracyM: pos.accuracy,
      timeMs: pos.timestamp.millisecondsSinceEpoch,
    );
    _set(LocationStatus.ok);
  }

  void _startCompass() {
    if (_compassSub != null) return;
    final events = FlutterCompass.events;
    if (events == null) return; // no magnetometer
    _compassSub = events.listen((event) {
      final h = event.heading;
      if (h == null || _disposed) return;
      onCompass((h + 360) % 360, DateTime.now().millisecondsSinceEpoch);
    }, onError: (Object e) => debugPrint('compass: $e'));
  }

  void _stopCompass() {
    _compassSub?.cancel();
    _compassSub = null;
  }

  /// A compass reading: published at most [compassHz] a second, and only
  /// for a turn of 2° or more (any turn after a second).
  @visibleForTesting
  void onCompass(double deg, int nowMs) {
    _rawHeading = deg;
    final last = _heading.value;
    final hz = _compassHz <= 0 ? 10 : _compassHz;
    final since = nowMs - _headingMs;
    if (last != null) {
      if (since < 1000 ~/ hz) return;
      final turn = ((deg - last + 540) % 360 - 180).abs();
      if (turn < 2 && !(turn >= 0.5 && since >= 1000)) return;
    }
    _headingMs = nowMs;
    _heading.value = deg;
  }

  /// The last raw compass reading (unthrottled), for tests.
  @visibleForTesting
  double? get rawHeading => _rawHeading;

  @override
  void dispose() {
    _disposed = true;
    _posSub?.cancel();
    _compassSub?.cancel();
    _svcSub?.cancel();
    _heading.dispose();
    super.dispose();
  }
}
