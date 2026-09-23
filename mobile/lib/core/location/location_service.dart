// location_service.dart — the phone's position and compass heading.
//
// Failures are reported, not swallowed: [status] says why there is no
// position (permission denied, location services off, an error), and the
// screens say so instead of showing a range from nowhere. Pushing the
// position to a detector is the app controller's job, and only to a
// verified, pinned detector.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';

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
  double? _heading;
  LocationStatus _status = LocationStatus.starting;
  String? _error;
  StreamSubscription<Position>? _posSub;
  StreamSubscription<CompassEvent>? _compassSub;
  StreamSubscription<ServiceStatus>? _svcSub;
  bool _disposed = false;

  PhoneLocation? get currentLocation => _current;

  /// Compass heading, degrees true-ish (magnetic where the platform gives
  /// no true heading); null when the phone has no compass or no reading.
  double? get headingDeg => _heading;
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
    _startCompass();
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
      await _posSub?.cancel();
      _posSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 5),
      ).listen(_onPosition, onError: (Object e) {
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
      _heading = (h + 360) % 360;
      notifyListeners();
    }, onError: (Object e) => debugPrint('compass: $e'));
  }

  @override
  void dispose() {
    _disposed = true;
    _posSub?.cancel();
    _compassSub?.cancel();
    _svcSub?.cancel();
    super.dispose();
  }
}
