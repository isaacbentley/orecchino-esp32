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
  static const _firstFixLimit = Duration(seconds: 10);

  PhoneLocation? _current;
  final ValueNotifier<double?> _heading = ValueNotifier<double?>(null);
  bool _started = false; // start() ran for real (the fakes in tests skip it)
  bool _allowed = false;
  bool _requestedPermission = false;
  Future<void>? _checking;
  int _availabilityRevision = 0;
  int _positionRevision = 0;
  int? _firstFixRevision;
  bool _forceLocationManager = false;
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
    final precisionChanged = _precision != precision;
    _precision = precision;
    _compassHz = compassHz;
    if (!_started || _disposed) return;
    if (compassHz > 0) {
      _startCompass();
    } else {
      _stopCompass();
    }
    if (_allowed && precisionChanged) _updatePosition();
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
    if (_disposed) return;
    if (_started) {
      await _checking;
      return;
    }
    _started = true;
    if (_compassHz > 0) _startCompass();
    try {
      _svcSub = Geolocator.getServiceStatusStream().listen(_onServiceStatus,
          onError: (Object e) => debugPrint('location service status: $e'));
    } catch (e) {
      debugPrint('location service status unavailable: $e');
    }
    await resume();
  }

  /// Recheck the Settings switches and retry a missing fix on foregrounding.
  Future<void> resume() async {
    if (!_started || _disposed) return;
    await (_checking ??= _checkAvailability().whenComplete(() => _checking = null));
  }

  void _onServiceStatus(ServiceStatus status) {
    if (_disposed) return;
    if (status == ServiceStatus.disabled) {
      _availabilityRevision++;
      _block(LocationStatus.servicesOff);
    } else if (_status == LocationStatus.servicesOff) {
      unawaited(_resumeAfterCheck());
    }
  }

  Future<void> _resumeAfterCheck() async {
    await _checking;
    if (_status == LocationStatus.servicesOff) await resume();
  }

  Future<void> _checkAvailability() async {
    final revision = _availabilityRevision;
    bool valid() => !_disposed && revision == _availabilityRevision;
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!valid()) return;
      if (!enabled) {
        _block(LocationStatus.servicesOff);
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (!valid()) return;
      if (perm == LocationPermission.denied && !_requestedPermission) {
        perm = await Geolocator.requestPermission();
        _requestedPermission = true;
      }
      if (!valid()) return;
      if (perm == LocationPermission.denied) {
        _block(LocationStatus.denied);
        return;
      }
      if (perm == LocationPermission.deniedForever) {
        _block(LocationStatus.deniedForever);
        return;
      }
      if (!_allowed) {
        _allowed = true;
        if (_current == null && _status != LocationStatus.starting) _set(LocationStatus.starting);
      }
      _updatePosition();
    } catch (e) {
      if (valid()) _set(LocationStatus.error, e.toString());
    }
  }

  static LocationSettings settingsFor(LocationPrecision p, {bool forceLocationManager = false}) {
    final high = p == LocationPrecision.high;
    final accuracy = high ? LocationAccuracy.high : LocationAccuracy.medium;
    final distance = high ? 5 : 50;
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: accuracy,
        distanceFilter: distance,
        intervalDuration: high ? null : const Duration(seconds: 30),
        forceLocationManager: forceLocationManager,
      );
    }
    if (!high && defaultTargetPlatform == TargetPlatform.iOS) {
      return AppleSettings(accuracy: accuracy, distanceFilter: distance);
    }
    return LocationSettings(accuracy: accuracy, distanceFilter: distance);
  }

  void _block(LocationStatus status) {
    _allowed = false;
    _stopPosition();
    _current = null;
    _set(status);
  }

  void _stopPosition() {
    _positionRevision++;
    unawaited(_posSub?.cancel());
    _posSub = null;
    _subscribed = null;
  }

  void _updatePosition() {
    _subscribe();
    final revision = _positionRevision;
    if (defaultTargetPlatform == TargetPlatform.android &&
        _needsFirstFix(revision) && _firstFixRevision != revision) {
      _firstFixRevision = revision;
      if (_status != LocationStatus.starting) _set(LocationStatus.starting);
      unawaited(_requestFirstFix(revision));
    }
  }

  /// (Re)start the position stream at the current precision; none when off.
  void _subscribe({bool restart = false}) {
    if (_disposed || !_allowed) return;
    if (!restart && _subscribed == _precision && (_posSub != null || _precision == LocationPrecision.off)) return;
    _stopPosition();
    _subscribed = _precision;
    if (_precision == LocationPrecision.off) return;
    final revision = _positionRevision;
    try {
      _posSub = Geolocator.getPositionStream(
        locationSettings: settingsFor(_precision, forceLocationManager: _forceLocationManager),
      ).listen((position) {
        if (_positionRevision == revision) _onPosition(position);
      }, onError: (Object e) => _onStreamError(revision, e), onDone: () {
        if (_positionRevision == revision) _posSub = null;
      });
    } catch (e) {
      _onStreamError(revision, e);
    }
  }

  void _onStreamError(int revision, Object e) {
    if (_positionRevision != revision) return;
    if (e is PermissionDeniedException) {
      _block(LocationStatus.denied);
    } else if (defaultTargetPlatform == TargetPlatform.android && _needsFirstFix(revision)) {
      // Android may report a provider error even while the system's Location
      // switch is on. The first-fix request tries the other provider as well.
      debugPrint('location stream: $e');
    } else if (e is LocationServiceDisabledException) {
      _block(LocationStatus.servicesOff);
    } else {
      _set(LocationStatus.error, e.toString());
    }
  }

  bool _needsFirstFix(int revision) => !_disposed && _allowed &&
      _precision != LocationPrecision.off && _positionRevision == revision && _current == null;

  Future<void> _requestFirstFix(int revision) async {
    var useLocationManager = _forceLocationManager;
    final accuracy = _precision == LocationPrecision.high ? LocationAccuracy.high : LocationAccuracy.medium;
    try {
      while (_needsFirstFix(revision)) {
        try {
          final position = await Geolocator.getCurrentPosition(
            desiredAccuracy: accuracy,
            forceAndroidLocationManager: useLocationManager,
            timeLimit: _firstFixLimit,
          ).timeout(_firstFixLimit);
          if (!_needsFirstFix(revision)) return;
          if (!_onPosition(position)) throw StateError('the provider returned invalid coordinates');
          if (useLocationManager && !_forceLocationManager) {
            // Keep using the provider that obtained a fix for subsequent updates.
            _forceLocationManager = true;
            _subscribe(restart: true);
          }
          return;
        } on PermissionDeniedException {
          if (_needsFirstFix(revision)) _block(LocationStatus.denied);
          return;
        } catch (e) {
          if (!_needsFirstFix(revision)) return;
          debugPrint('current position: $e');
          if (useLocationManager) {
            if (e is LocationServiceDisabledException) {
              _block(LocationStatus.servicesOff);
            } else {
              _set(LocationStatus.error, 'the phone has not provided a location fix. '
                  'Try outdoors or reopen the app after checking Location settings.');
            }
            return;
          }
          useLocationManager = true;
        }
      }
    } finally {
      if (_firstFixRevision == revision) _firstFixRevision = null;
    }
  }

  bool _onPosition(Position pos) {
    final timeMs = pos.timestamp.millisecondsSinceEpoch;
    final previous = _current;
    if (!pos.latitude.isFinite || pos.latitude.abs() > 90 ||
        !pos.longitude.isFinite || pos.longitude.abs() > 180 ||
        (previous != null && timeMs < previous.timeMs)) {
      return false;
    }
    _current = PhoneLocation(
      lat: pos.latitude,
      lon: pos.longitude,
      altitudeM: pos.altitudeAccuracy > 0 ? pos.altitude : null,
      accuracyM: pos.accuracy,
      timeMs: timeMs,
    );
    _set(LocationStatus.ok);
    return true;
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
    _stopPosition();
    _compassSub?.cancel();
    _svcSub?.cancel();
    _heading.dispose();
    super.dispose();
  }
}
