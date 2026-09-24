// native_rx_service.dart — the phone as a Remote ID receiver of its own:
// the Bluetooth scanner (ble_rid_scanner.dart) and, on Android, the Wi-Fi
// NAN and beacon paths (wifi_rid_android.dart), behind one start/stop, one
// stream of observations in the app's message model, and one capability
// report ("BLE4 yes, BLE5 extended: yes, BLE5 coded: yes, NAN: no, Wi-Fi
// beacon: slow (30 s)").
//
// The sources share one NativeRidDecoder, so authentication pages and the
// once-a-second repeat rule are per transmitter across paths, as on a
// detector. [messages] carries only fresh frames (a repeat within a second
// is dropped, as the firmware drops it); [observations] carries every
// frame for whoever wants the raw count.
//
// How hard each path works follows the power policy ([applyPolicy]): the
// Bluetooth scan's duty (off in Saver's background, and on iOS whenever
// the app is not in front: iOS delivers no Remote ID adverts to a
// background scan), the beacon scan interval, and NAN only while Live or
// Find is open (Balanced). [start] and [stop] remain the person's "use
// this phone as a detector".
//
// This service only receives. Fusion with the detectors' lines is the
// caller's (AppController): feed [messages] to ContactTracker.ingest, never
// to the SyncEngine (the phone's frames are not detector history).
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import '../power/power_policy.dart';
import '../protocol/messages.dart';
import 'ble_rid_scanner.dart';
import 'ble_scan_coordinator.dart';
import 'rid_observation.dart';
import 'wifi_rid_android.dart';

enum CapState { yes, no, unknown }

String _cap(CapState s) => switch (s) { CapState.yes => 'yes', CapState.no => 'no', CapState.unknown => 'unknown' };

/// What the phone itself can receive.
@immutable
class NativeRxCapabilities {
  /// Bluetooth legacy advertising (every phone with BLE).
  final CapState ble4;

  /// Bluetooth 5 extended advertising (message packs) on the 1M PHY.
  final CapState ble5Extended;

  /// Bluetooth 5 coded PHY (long range). Received as phone-ble5, not told
  /// apart (see ble_rid_scanner.dart).
  final CapState codedPhy;

  /// Wi-Fi NAN, and why not.
  final CapState nan;
  final String? nanReason;

  /// Wi-Fi beacons: [CapState.yes] means available but slow
  /// ([beaconIntervalS] between scans).
  final CapState beacon;
  final int? beaconIntervalS;
  final String? beaconReason;

  /// iOS: the receiver works only while the app is in the foreground.
  final bool foregroundOnly;

  const NativeRxCapabilities({
    required this.ble4,
    required this.ble5Extended,
    required this.codedPhy,
    required this.nan,
    required this.beacon,
    this.nanReason,
    this.beaconIntervalS,
    this.beaconReason,
    this.foregroundOnly = false,
  });

  static const unknown = NativeRxCapabilities(
    ble4: CapState.unknown,
    ble5Extended: CapState.unknown,
    codedPhy: CapState.unknown,
    nan: CapState.unknown,
    beacon: CapState.unknown,
  );

  /// "BLE4 yes, BLE5 extended: yes, BLE5 coded: no, NAN: no, Wi-Fi beacon:
  /// slow (30 s)".
  String get summary {
    final b = switch (beacon) {
      CapState.yes => beaconIntervalS == null ? 'slow' : 'slow ($beaconIntervalS s)',
      CapState.no => 'no',
      CapState.unknown => 'unknown',
    };
    return 'BLE4 ${_cap(ble4)}, BLE5 extended: ${_cap(ble5Extended)}, BLE5 coded: ${_cap(codedPhy)}, '
        'NAN: ${_cap(nan)}, Wi-Fi beacon: $b${foregroundOnly ? ' (foreground only)' : ''}';
  }

  @override
  String toString() => summary;
}

class NativeRxService extends ChangeNotifier {
  final BleScanCoordinator coordinator;
  final BleRidScanner ble;
  final WifiRidAndroid wifi;
  final NativeRidDecoder decoder;
  final bool isAndroid;
  final bool isIOS;

  /// Build from parts (tests), or with [NativeRxService.platform].
  NativeRxService({
    required this.coordinator,
    required this.ble,
    required this.wifi,
    required this.decoder,
    required this.isAndroid,
    required this.isIOS,
  });

  /// The real thing: flutter_blue_plus and the Android plugin, one shared
  /// decoder. Pass the app's [coordinator] so BleService scans through the
  /// same one (CoordinatedBleTransport).
  factory NativeRxService.platform({BleScanCoordinator? coordinator}) {
    final c = coordinator ?? BleScanCoordinator(FbpScanBackend());
    final d = NativeRidDecoder();
    return NativeRxService(
      coordinator: c,
      ble: BleRidScanner(c, decoder: d),
      wifi: WifiRidAndroid(decoder: d),
      decoder: d,
      isAndroid: Platform.isAndroid,
      isIOS: Platform.isIOS,
    );
  }

  final _obs = StreamController<RidObservation>.broadcast();
  final List<StreamSubscription<Object?>> _subs = [];
  NativeRxCapabilities _caps = NativeRxCapabilities.unknown;
  bool _running = false;
  bool _disposed = false;
  final Map<String, String> _state = {};
  PowerPolicy? _policy;
  Future<void> _paths = Future.value(); // path changes, one at a time
  bool _bleOn = false;
  (bool, bool, int?)? _wifiOn; // nan, beacon, interval of the running Wi-Fi paths

  /// The policy last applied (null: none yet, every path on).
  PowerPolicy? get policy => _policy;

  /// Every frame the phone decoded (repeats included, marked !fresh).
  Stream<RidObservation> get observations => _obs.stream;

  /// Fresh frames as rid lines, for ContactTracker.ingest.
  Stream<RidMessage> get messages => _obs.stream.where((o) => o.fresh).map((o) => o.message);

  NativeRxCapabilities get capabilities => _caps;
  bool get running => _running;

  /// Per path: "ble", "nan", "beacon" -> "running", "off", "unsupported:
  /// ...", "permission", "error: ...".
  Map<String, String> get pathStates => Map.unmodifiable(_state);

  /// Ask the platforms what they can do.
  Future<NativeRxCapabilities> refreshCapabilities() async {
    final phy = await coordinator.backend.phyCaps();
    final w = await wifi.capabilities();
    CapState tri(bool? v) => v == null ? CapState.unknown : (v ? CapState.yes : CapState.no);
    NativeRxCapabilities caps;
    if (isAndroid) {
      final coded = w.leCodedPhy ?? phy.leCoded;
      final ext = w.leExtendedAdvertising ?? (phy.leCoded == true || phy.le2M == true ? true : null);
      final nanOk = w.awareSupported;
      final beaconOk = w.beaconElements;
      caps = NativeRxCapabilities(
        ble4: CapState.yes,
        ble5Extended: tri(ext),
        codedPhy: tri(coded),
        nan: w.platformSupported ? (nanOk ? CapState.yes : CapState.no) : CapState.unknown,
        nanReason: !w.platformSupported
            ? w.reason
            : !nanOk
                ? 'no Wi-Fi Aware on this phone'
                : (!w.awareAvailable ? 'Wi-Fi Aware unavailable now (Wi-Fi off or in use)' : null),
        beacon: w.platformSupported ? (beaconOk ? CapState.yes : CapState.no) : CapState.unknown,
        beaconIntervalS: beaconOk ? (w.beaconIntervalMs / 1000).round() : null,
        beaconReason: !w.platformSupported ? w.reason : (!beaconOk ? 'needs Android 11 or later' : null),
      );
    } else {
      caps = NativeRxCapabilities(
        ble4: CapState.yes,
        // CoreBluetooth neither promises nor reports extended advertising.
        ble5Extended: CapState.unknown,
        codedPhy: isIOS ? CapState.no : CapState.unknown,
        nan: CapState.no,
        nanReason: w.reason ?? 'not on iOS',
        beacon: CapState.no,
        beaconReason: w.reason ?? 'not on iOS',
        foregroundOnly: isIOS,
      );
    }
    _caps = caps;
    _changed();
    return caps;
  }

  /// Start the paths asked for (each only where supported). A path that
  /// cannot start is reported in [pathStates]; the others run regardless.
  Future<void> start({bool ble = true, bool nan = true, bool beacon = true}) async {
    if (_running) return;
    _running = true;
    _allowBle = ble;
    _allowNan = nan;
    _allowBeacon = beacon;
    _subs
      ..add(this.ble.observations.listen(_add))
      ..add(wifi.observations.listen(_add))
      ..add(wifi.status.listen((s) {
        _state[s.path] = s.state;
        _changed();
      }));
    await _queuePaths();
  }

  bool _allowBle = true, _allowNan = true, _allowBeacon = true;

  /// Follow the power policy (see the file comment). Paths change only
  /// while the receiver runs; the coordinator's duty changes at once.
  void applyPolicy(PowerPolicy p) {
    _policy = p;
    unawaited(coordinator.setDuty(p.phoneScan));
    if (_running) unawaited(_queuePaths());
  }

  Future<void> _queuePaths() {
    final next = _paths.then((_) => _syncPaths());
    _paths = next.catchError((Object _) {});
    return next;
  }

  /// Start or stop each path to match [start]'s choice and the policy.
  Future<void> _syncPaths() async {
    if (!_running || _disposed) return;
    final p = _policy;
    final wantBle = _allowBle && (p == null || p.phoneScan != ScanDuty.off);
    final wantNan = _allowNan && (p == null || p.nan);
    final wantBeacon = _allowBeacon && (p == null || p.beaconEvery != null);
    final interval = p?.beaconEvery?.inMilliseconds;
    if (wantBle && !_bleOn) {
      try {
        await ble.start();
        _bleOn = true;
        _state['ble'] = 'running';
      } catch (e) {
        _state['ble'] = 'error: $e';
      }
    } else if (!wantBle) {
      if (_bleOn) await ble.stop();
      _bleOn = false;
      _state['ble'] = p != null && p.phoneScan == ScanDuty.off && _allowBle ? 'paused' : 'off';
    }
    final wifiWant = (wantNan, wantBeacon, interval);
    if (wifiWant != _wifiOn) {
      if (_wifiOn != null) await wifi.stop();
      _wifiOn = null;
      if (wantNan || wantBeacon) {
        try {
          final r = await wifi.start(nan: wantNan, beacon: wantBeacon, beaconIntervalMs: interval);
          _state.addAll(r);
          _wifiOn = wifiWant;
        } catch (e) {
          if (wantNan) _state['nan'] = 'error: $e';
          if (wantBeacon) _state['beacon'] = 'error: $e';
        }
      }
      if (!wantNan) _state['nan'] = _allowNan && p != null && !p.nan ? 'paused' : 'off';
      if (!wantBeacon) _state['beacon'] = _allowBeacon && p != null && p.beaconEvery == null ? 'paused' : 'off';
    }
    _changed();
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _paths;
    await ble.stop();
    await wifi.stop();
    _bleOn = false;
    _wifiOn = null;
    _state.updateAll((_, __) => 'off');
    decoder.lines.clear();
    _changed();
  }

  void _add(RidObservation o) {
    if (!_obs.isClosed) _obs.add(o);
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    // The paths' own streams too (the coordinator is shared: not ours).
    unawaited(stop().whenComplete(() async {
      await ble.dispose();
      await wifi.dispose();
    }));
    unawaited(_obs.close());
    super.dispose();
  }
}
