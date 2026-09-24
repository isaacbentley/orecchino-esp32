// ble_scan_coordinator.dart — one Bluetooth scan for everyone who needs
// one. flutter_blue_plus runs a single scan at a time (a second startScan
// stops the first), and Android refuses a sixth scan start within 30 s, so
// the detector picker (BleService) and the phone's own Remote ID receiver
// (ble_rid_scanner.dart) must not each start and stop their own.
//
// Clients take a [BleScanLease] with the filter they need; the coordinator
// scans with the union of the live leases' filters and hands every
// advertisement to every listener, each of which picks its own. A lease
// joining whose filter the running scan already covers changes nothing; a
// lease leaving never restarts the scan just to narrow it; the last lease
// leaving stops it. Restarts are throttled to Android's limit, a scan the
// platform stops by itself is restarted with backoff while leases remain,
// and a scan that has run [restartEvery] is restarted (Android quietly
// downgrades a scan older than 30 minutes to opportunistic).
//
// [BleScanFilter.detectorAndRid] is the union the app should always use, so
// the picker coming and going never restarts the Remote ID scan.
//
// The scan's duty follows the power policy ([setDuty]): Android's
// LOW_LATENCY on Live and Find, BALANCED on the other tabs, LOW_POWER in
// the background (power_policy.dart). A change restarts the scan through
// the same throttle. Repeats are not thinned natively: flutter_blue_plus'
// continuousDivisor counts per device, and a Bluetooth 4 transmitter
// rotates its message types one per advertisement, so a divisor of 2 would
// drop whole message types, not repeats; the decoder's once-a-second rule
// drops them in Dart instead.
//
// [CoordinatedBleTransport] is the drop-in BleTransport for BleService:
// scanning through the coordinator, connecting as before. It is the whole
// integration: `BleService(transport: CoordinatedBleTransport(coordinator))`.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../ble/ble_transport.dart';
import '../odid/odid_transport.dart';
import '../power/power_policy.dart';

/// One advertisement, as the scan reported it.
class BleAdvert {
  /// flutter_blue_plus remoteId: the MAC on Android, a CoreBluetooth UUID
  /// on iOS.
  final String id;
  final String name;
  final int rssi;

  /// Advertised service UUIDs, 128-bit lowercase.
  final List<String> serviceUuids;

  /// Service data by 128-bit lowercase UUID (the bytes after the UUID).
  final Map<String, List<int>> serviceData;

  /// Manufacturer data by company ID (the bytes after the ID).
  final Map<int, List<int>> manufacturerData;

  /// "1m", "2m" or "coded" when the platform reports the (secondary) PHY;
  /// flutter_blue_plus does not, so null there.
  final String? phy;

  /// True for a legacy advertisement, false for extended; null unknown
  /// (flutter_blue_plus does not say).
  final bool? legacy;
  final DateTime at;

  const BleAdvert({
    required this.id,
    required this.rssi,
    required this.at,
    this.name = '',
    this.serviceUuids = const [],
    this.serviceData = const {},
    this.manufacturerData = const {},
    this.phy,
    this.legacy,
  });
}

String _uuid128(String u) {
  final s = u.toLowerCase();
  if (s.length == 4) return '0000$s-0000-1000-8000-00805f9b34fb';
  if (s.length == 8) return '$s-0000-1000-8000-00805f9b34fb';
  return s;
}

/// What a scan must let through. Filters are OR'ed: an advertisement
/// matching any entry is reported.
@immutable
class BleScanFilter {
  /// Advertised service UUIDs (any form; stored 128-bit lowercase).
  final Set<String> services;

  /// Service-data UUIDs.
  final Set<String> serviceData;

  /// Manufacturer (company) IDs.
  final Set<int> manufacturerIds;

  BleScanFilter({Iterable<String> services = const [], Iterable<String> serviceData = const [], Iterable<int> manufacturerIds = const []})
      : services = services.map(_uuid128).toSet(),
        serviceData = serviceData.map(_uuid128).toSet(),
        manufacturerIds = manufacturerIds.toSet();

  /// The detector picker: Nordic UART Service.
  static final BleScanFilter detector = BleScanFilter(services: const [BleUuids.nusService]);

  /// Remote ID: service data 0xFFFA, and the draft-era company 0x0200.
  static final BleScanFilter remoteId = BleScanFilter(serviceData: const [odidBleUuid128], manufacturerIds: const [odidDraftCompanyId]);

  /// Both, the filter the app should scan with whenever it scans.
  static final BleScanFilter detectorAndRid = detector.union(remoteId);

  bool get isEmpty => services.isEmpty && serviceData.isEmpty && manufacturerIds.isEmpty;

  BleScanFilter union(BleScanFilter o) => BleScanFilter(
        services: {...services, ...o.services},
        serviceData: {...serviceData, ...o.serviceData},
        manufacturerIds: {...manufacturerIds, ...o.manufacturerIds},
      );

  /// True when every advertisement [o] lets through, this lets through.
  bool covers(BleScanFilter o) =>
      services.containsAll(o.services) && serviceData.containsAll(o.serviceData) && manufacturerIds.containsAll(o.manufacturerIds);

  bool matches(BleAdvert a) =>
      a.serviceUuids.any((u) => services.contains(_uuid128(u))) ||
      a.serviceData.keys.any((u) => serviceData.contains(_uuid128(u))) ||
      a.manufacturerData.keys.any(manufacturerIds.contains);

  @override
  bool operator ==(Object other) => other is BleScanFilter && covers(other) && other.covers(this);

  @override
  int get hashCode => Object.hash(Object.hashAllUnordered(services), Object.hashAllUnordered(serviceData), Object.hashAllUnordered(manufacturerIds));

  @override
  String toString() => 'BleScanFilter(services: $services, serviceData: $serviceData, msd: $manufacturerIds)';
}

/// PHY support of the phone's Bluetooth controller.
class BlePhyCaps {
  /// null: the platform does not say (iOS).
  final bool? le2M;
  final bool? leCoded;
  const BlePhyCaps({this.le2M, this.leCoded});
  static const unknown = BlePhyCaps();
}

/// The platform scan the coordinator drives (flutter_blue_plus, or a fake).
abstract class BleScanBackend {
  /// Every advertisement while scanning, duplicates included.
  Stream<BleAdvert> get adverts;

  /// True while the platform scan runs; false when it stops for any
  /// reason (asked to, adapter off, platform error).
  Stream<bool> get scanning;

  /// Whether the platform scan runs right now.
  bool get isScanningNow;

  /// Start (or restart) scanning with [filter] at [duty] (never
  /// [ScanDuty.off]: that is no scan); throws when it cannot.
  Future<void> start(BleScanFilter filter, {ScanDuty duty = ScanDuty.lowLatency});
  Future<void> stop();
  Future<BlePhyCaps> phyCaps();
}

/// flutter_blue_plus. Duplicates on (every advertisement carries fresh
/// Location data), one result per event, all PHYs and extended advertising
/// on Android (androidLegacy: false = setLegacy(false) +
/// setPhy(PHY_LE_ALL_SUPPORTED)), no location use (BLUETOOTH_SCAN is
/// neverForLocation).
class FbpScanBackend implements BleScanBackend {
  FbpScanBackend();

  StreamController<BleAdvert>? _ctl;
  StreamSubscription<List<ScanResult>>? _sub;

  @override
  Stream<BleAdvert> get adverts {
    _ctl ??= StreamController<BleAdvert>.broadcast(
      onListen: () {
        _sub ??= FlutterBluePlus.onScanResults.listen((list) {
          for (final r in list) {
            _ctl?.add(_advert(r));
          }
        });
      },
      onCancel: () {
        unawaited(_sub?.cancel());
        _sub = null;
      },
    );
    return _ctl!.stream;
  }

  static BleAdvert _advert(ScanResult r) {
    final a = r.advertisementData;
    return BleAdvert(
      id: r.device.remoteId.str,
      name: a.advName.isNotEmpty ? a.advName : r.device.platformName,
      rssi: r.rssi,
      at: r.timeStamp,
      serviceUuids: [for (final g in a.serviceUuids) g.str128],
      serviceData: {for (final e in a.serviceData.entries) e.key.str128: e.value},
      manufacturerData: a.manufacturerData,
    );
  }

  @override
  Stream<bool> get scanning => FlutterBluePlus.isScanning;

  @override
  bool get isScanningNow => FlutterBluePlus.isScanningNow;

  @override
  Future<void> start(BleScanFilter filter, {ScanDuty duty = ScanDuty.lowLatency}) async {
    if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
      final s = await FlutterBluePlus.adapterState
          .where((s) => s != BluetoothAdapterState.unknown)
          .first
          .timeout(const Duration(seconds: 3), onTimeout: () => FlutterBluePlus.adapterStateNow);
      if (s != BluetoothAdapterState.on) {
        throw StateError(s == BluetoothAdapterState.unauthorized ? 'Bluetooth permission denied' : 'Bluetooth is off');
      }
    }
    await FlutterBluePlus.startScan(
      withServices: [for (final s in filter.services) Guid(s)],
      withServiceData: [for (final s in filter.serviceData) ServiceDataFilter(Guid(s))],
      withMsd: [for (final m in filter.manufacturerIds) MsdFilter(m)],
      continuousUpdates: true,
      oneByOne: true,
      androidLegacy: false,
      androidScanMode: switch (duty) {
        ScanDuty.lowLatency => AndroidScanMode.lowLatency,
        ScanDuty.balanced => AndroidScanMode.balanced,
        ScanDuty.lowPower || ScanDuty.off => AndroidScanMode.lowPower,
      },
      androidUsesFineLocation: false,
      androidCheckLocationServices: false,
    );
  }

  @override
  Future<void> stop() => FlutterBluePlus.stopScan();

  @override
  Future<BlePhyCaps> phyCaps() async {
    if (!Platform.isAndroid) return BlePhyCaps.unknown;
    try {
      final p = await FlutterBluePlus.getPhySupport();
      return BlePhyCaps(le2M: p.le2M, leCoded: p.leCoded);
    } catch (_) {
      return BlePhyCaps.unknown;
    }
  }
}

/// A client's hold on the scan. [release] is idempotent.
class BleScanLease {
  final String owner;
  final BleScanFilter filter;
  final BleScanCoordinator _coordinator;
  bool _released = false;

  BleScanLease._(this._coordinator, this.owner, this.filter);

  bool get active => !_released;

  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _coordinator._release(this);
  }
}

class BleScanCoordinator extends ChangeNotifier {
  final BleScanBackend backend;

  /// Android: at most [maxStarts] scan starts per [startWindow].
  final int maxStarts;
  final Duration startWindow;

  /// Restart a scan that has run this long (null: never).
  final Duration? restartEvery;

  /// Backoff after the platform stops a scan by itself.
  final Duration retryMin, retryMax;

  final DateTime Function() _now;
  final Future<void> Function(Duration) _sleep;

  BleScanCoordinator(
    this.backend, {
    this.maxStarts = 5,
    this.startWindow = const Duration(seconds: 30),
    this.restartEvery = const Duration(minutes: 25),
    this.retryMin = const Duration(seconds: 2),
    this.retryMax = const Duration(seconds: 30),
    DateTime Function()? now,
    Future<void> Function(Duration)? sleep,
  })  : _now = now ?? DateTime.now,
        _sleep = sleep ?? Future<void>.delayed {
    _scanSub = backend.scanning.listen(_onScanning);
  }

  final List<BleScanLease> _leases = [];
  final List<DateTime> _starts = [];
  ScanDuty _duty = ScanDuty.lowLatency;
  ScanDuty? _runningDuty;
  BleScanFilter? _running; // the filter of the scan we started, while it runs
  Future<void> _chain = Future.value();
  StreamSubscription<bool>? _scanSub;
  Timer? _retry, _refresh;
  Duration _backoff = Duration.zero;
  bool _disposed = false;
  String? _error;

  /// Every advertisement of the shared scan.
  Stream<BleAdvert> get adverts => backend.adverts;

  bool get scanning => _running != null;
  BleScanFilter? get runningFilter => _running;
  String? get error => _error;
  List<String> get owners => [for (final l in _leases) l.owner];
  int get startCount => _starts.length;

  /// The duty the scan runs at (or will, when it starts).
  ScanDuty get duty => _duty;

  /// Scan harder or lighter (the power policy). A running scan restarts
  /// at the new duty; [ScanDuty.off] is treated as low power here (whether
  /// to scan at all is the leases' business).
  Future<void> setDuty(ScanDuty d) async {
    if (d == ScanDuty.off) d = ScanDuty.lowPower;
    if (d == _duty) return;
    _duty = d;
    if (_running != null) await _reconcile(force: true).catchError((Object _) {});
  }

  /// Hold the scan open with [filter] until the lease is released. Throws
  /// what the platform threw when the scan cannot start; the lease is then
  /// already released.
  Future<BleScanLease> acquire(String owner, BleScanFilter filter) async {
    final lease = BleScanLease._(this, owner, filter);
    _leases.add(lease);
    try {
      await _reconcile();
    } catch (_) {
      await lease.release();
      rethrow;
    }
    return lease;
  }

  Future<void> _release(BleScanLease lease) async {
    _leases.remove(lease);
    await _reconcile();
  }

  BleScanFilter? get _wanted {
    if (_leases.isEmpty) return null;
    return _leases.map((l) => l.filter).reduce((a, b) => a.union(b));
  }

  /// Bring the platform scan in line with the leases; serialized.
  Future<void> _reconcile({bool force = false}) {
    final next = _chain.then((_) => _apply(force));
    _chain = next.catchError((Object _) {});
    return next;
  }

  Future<void> _apply(bool force) async {
    if (_disposed) return;
    final want = _wanted;
    if (want == null) {
      _retry?.cancel();
      _refresh?.cancel();
      if (_running != null) {
        _running = null;
        try {
          await backend.stop();
        } catch (_) {}
        _changed();
      }
      return;
    }
    if (!force && _running != null && _running!.covers(want) && _runningDuty == _duty) return;
    final start = _running == null ? want : _running!.union(want);
    await _throttle();
    _starts.add(_now());
    try {
      final duty = _duty;
      await backend.start(start, duty: duty);
      _running = start;
      _runningDuty = duty;
      _error = null;
      _backoff = Duration.zero;
      _armRefresh();
      _changed();
    } catch (e) {
      _running = null;
      _error = e.toString();
      _changed();
      rethrow;
    }
  }

  /// Wait until another start is within Android's limit.
  Future<void> _throttle() async {
    final now = _now();
    _starts.removeWhere((t) => now.difference(t) >= startWindow);
    if (_starts.length < maxStarts) return;
    final wait = startWindow - now.difference(_starts.first);
    if (wait > Duration.zero) await _sleep(wait);
    final later = _now();
    _starts.removeWhere((t) => later.difference(t) >= startWindow);
  }

  void _armRefresh() {
    _refresh?.cancel();
    final every = restartEvery;
    if (every == null) return;
    _refresh = Timer(every, () => unawaited(_reconcile(force: true).catchError((Object _) {})));
  }

  void _onScanning(bool on) {
    if (on || _running == null || _disposed || _leases.isEmpty) return;
    // Maybe the platform stopped our scan (adapter off, error, another
    // caller), maybe this is the stop half of our own restart. Look again
    // after a backoff, and start over if it is still down.
    _backoff = _backoff == Duration.zero ? retryMin : _backoff * 2;
    if (_backoff > retryMax) _backoff = retryMax;
    _retry?.cancel();
    _retry = Timer(_backoff, () {
      if (_disposed || _leases.isEmpty) return;
      if (backend.isScanningNow) {
        _backoff = Duration.zero; // it was our own restart
        return;
      }
      _running = null;
      _changed();
      unawaited(_reconcile(force: true).catchError((Object e) => _onScanningFailed()));
    });
  }

  /// A retry that failed: keep trying, slower, while leases remain.
  void _onScanningFailed() {
    if (_disposed || _leases.isEmpty) return;
    _running ??= BleScanFilter();
    _onScanning(false);
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _refresh?.cancel();
    unawaited(_scanSub?.cancel());
    if (_running != null) unawaited(backend.stop().catchError((Object _) {}));
    _running = null;
    super.dispose();
  }
}

/// BleService's transport, scanning through the coordinator: the picker's
/// scan is a lease on the shared scan (filter [BleScanFilter.detectorAndRid],
/// so taking or dropping it never restarts the Remote ID scan), and
/// connecting, bonding and forgetting go to [inner] (flutter_blue_plus).
class CoordinatedBleTransport implements BleTransport {
  final BleScanCoordinator coordinator;
  final BleTransport inner;

  /// The filter the picker's lease asks for.
  final BleScanFilter pickerFilter;

  CoordinatedBleTransport(this.coordinator, {BleTransport? inner, BleScanFilter? pickerFilter})
      : inner = inner ?? FbpTransport(),
        pickerFilter = pickerFilter ?? BleScanFilter.detectorAndRid;

  final _hits = StreamController<List<BleScanHit>>.broadcast();
  final Map<String, BleScanHit> _seen = {};
  BleScanLease? _lease;
  StreamSubscription<BleAdvert>? _sub;
  Timer? _timeout;

  @override
  Stream<List<BleScanHit>> get scanResults => _hits.stream;

  @override
  Future<void> startScan({Duration timeout = const Duration(seconds: 10)}) async {
    await stopScan();
    _seen.clear();
    final nus = BleScanFilter.detector;
    _sub = coordinator.adverts.listen((a) {
      if (!nus.matches(a)) return;
      _seen[a.id] = BleScanHit(id: a.id, name: a.name, rssi: a.rssi);
      _hits.add(_seen.values.toList());
    });
    try {
      _lease = await coordinator.acquire('detector-picker', pickerFilter);
    } catch (_) {
      await _sub?.cancel();
      _sub = null;
      rethrow;
    }
    _timeout = Timer(timeout, () => unawaited(stopScan()));
  }

  @override
  Future<void> stopScan() async {
    _timeout?.cancel();
    _timeout = null;
    await _sub?.cancel();
    _sub = null;
    final l = _lease;
    _lease = null;
    await l?.release();
  }

  @override
  Future<BlePeer> connect(String id, {Duration timeout = const Duration(seconds: 15), bool pending = false}) =>
      inner.connect(id, timeout: timeout, pending: pending);

  @override
  bool get pendingConnect => inner.pendingConnect;

  @override
  Future<void> cancelConnect(String id) => inner.cancelConnect(id);

  @override
  Future<void> forgetBond(String id) => inner.forgetBond(id);
}
