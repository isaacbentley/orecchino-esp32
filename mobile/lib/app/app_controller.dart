// app_controller.dart — wires the detector link, sync, live contacts, ADS-B
// traffic and alerts together (plan §5.2), for the screens to watch.
//
// - Real mode: the BLE link. Pairing a new detector is always the person's
//   choice ("Pair"); once it has verified (device info, encrypted link) it
//   is pinned, and later the app reconnects to pinned detectors by itself.
// - On every ready link to a pinned detector: feed on, set_time, set_home,
//   log_get from the stored cursor; then set_time/set_home every 60 s and
//   the ADS-B set every 10 s (boards with "traffic"). The phone's position
//   goes only to a verified, pinned detector, never to "any NUS device".
// - Demo mode: the simulated detector, and a simulated phone position.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';

import '../core/alerts/alert_policy.dart';
import '../core/alerts/notifier.dart';
import '../core/ble/ble_service.dart';
import '../core/ble/simulated_detector.dart';
import '../core/link/detector_link.dart';
import '../core/live/contact_tracker.dart';
import '../core/location/location_service.dart';
import '../core/protocol/commands.dart';
import '../core/protocol/messages.dart';
import '../core/sync/sync_engine.dart';
import '../core/traffic/adsb_source.dart';
import '../core/traffic/traffic_rules.dart';
import '../data/db.dart';

class AppSettings {
  bool demo = false;
  bool adsb = true;
  bool notifications = true;
  bool haptics = true;
  bool spoken = false;
}

class AppController extends ChangeNotifier {
  final AppDatabase db;
  final BleService ble;
  final SimulatedDetector sim;
  final LocationService location;
  final AlertSink alerts;
  final AdsbSource adsb;
  final bool startTimers;

  late final SyncEngine sync;
  final ContactTracker tracker = ContactTracker();
  final TrafficMonitor traffic = TrafficMonitor();
  final AlertPolicy policy = AlertPolicy();
  final AppSettings settings = AppSettings();

  AppController({
    required this.db,
    BleService? ble,
    SimulatedDetector? sim,
    LocationService? location,
    AlertSink? alerts,
    AdsbSource? adsb,
    this.startTimers = true,
  })  : ble = ble ?? BleService(),
        sim = sim ?? SimulatedDetector(),
        location = location ?? LocationService(),
        alerts = alerts ?? SilentAlertSink(),
        adsb = adsb ?? AdsbSource() {
    sync = SyncEngine(db: db, sendCommand: (c) => link.send(c));
  }

  StreamSubscription<HostMessage>? _msgSub;
  StreamSubscription<SyncProgress>? _syncSub;
  Timer? _tick, _ctxTimer, _adsbTimer, _reconnect;
  int _reconnectDelayS = 5;
  bool _disposed = false;
  bool _pairing = false; // the current connect was the person's "Pair"
  String? _pinnedId; // the connected detector, once verified and pinned
  String? _adsbError;
  int _lastHeadingNotifyMs = 0;
  double? _lastHeading;
  String? _ongoingId;

  /// Set when a notification's Show is tapped: the aircraft to select.
  final ValueNotifier<String?> showRequest = ValueNotifier<String?>(null);

  bool get isSimulated => settings.demo;
  DetectorLink get link => settings.demo ? sim : ble;
  bool get detectorReady => settings.demo ? sim.isReady : (ble.isReady && _pinnedId != null);
  String? get connectedDetectorId => settings.demo ? 'simulated' : _pinnedId;
  DeviceInfoMessage? get detectorInfo => settings.demo ? SimulatedDetector.info : ble.info;
  String? get adsbError => _adsbError;
  SyncProgress get syncProgress => sync.lastProgress;

  /// The observer: the phone, or in demo mode the simulated position.
  ObserverFix? get observer {
    if (settings.demo) return const ObserverFix(SimulatedDetector.centerLat, SimulatedDetector.centerLon);
    final l = location.currentLocation;
    return l == null ? null : ObserverFix(l.lat, l.lon);
  }

  double? get headingDeg => location.headingDeg;
  int nowMs() => DateTime.now().millisecondsSinceEpoch;

  Future<void> start() async {
    await _loadSettings();
    await alerts.init(onAction: _onNotificationAction);
    ble.addListener(_onBleChanged);
    location.addListener(_onLocationChanged);
    _syncSub = sync.progress.listen((_) => _changed());
    _bindLink();
    unawaited(location.start());
    if (startTimers) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) => tick());
      _ctxTimer = Timer.periodic(const Duration(seconds: 60), (_) => pushContext());
      _adsbTimer = Timer.periodic(AdsbSource.fetchEvery, (_) => refreshTraffic());
    }
    if (settings.demo) {
      sim.start();
      unawaited(_onLinkReady());
    } else {
      unawaited(_reconnectPinned());
    }
  }

  Future<void> _loadSettings() async {
    Future<bool> b(String k, bool d) async {
      final v = await db.getSetting(k);
      return v == null ? d : v == '1';
    }

    settings.demo = await b('demo', false);
    settings.adsb = await b('adsb', true);
    settings.notifications = await b('notifications', true);
    settings.haptics = await b('haptics', true);
    settings.spoken = await b('spoken', false);
  }

  Future<void> setSetting(String key, bool v) async {
    switch (key) {
      case 'adsb':
        settings.adsb = v;
        if (!v) traffic.clear();
      case 'notifications':
        settings.notifications = v;
      case 'haptics':
        settings.haptics = v;
      case 'spoken':
        settings.spoken = v;
    }
    await db.setSetting(key, v ? '1' : '0');
    _changed();
    if (key == 'adsb' && v) unawaited(refreshTraffic());
  }

  Future<void> setDemo(bool on) async {
    if (on == settings.demo) return;
    settings.demo = on;
    await db.setSetting('demo', on ? '1' : '0');
    sync.abort('switched detector');
    tracker.clear();
    traffic.clear();
    if (on) {
      _reconnect?.cancel();
      await ble.disconnect();
      _pinnedId = null;
      sim.start();
    } else {
      sim.stop();
    }
    _bindLink();
    _changed();
    if (on) {
      unawaited(_onLinkReady());
    } else {
      unawaited(_reconnectPinned());
    }
  }

  void _bindLink() {
    _msgSub?.cancel();
    _msgSub = link.messages.listen(_onMessage);
  }

  void _onMessage(HostMessage msg) {
    // Sync first, in order (the engine queues and awaits each record).
    unawaited(sync.handleMessage(msg).catchError((Object e) => debugPrint('sync: $e')));
    if (msg is RidMessage) {
      tracker.ingest(msg, nowMs(), observer);
    }
  }

  // ------------------------------------------------------------- BLE / pairing

  /// The person chose "Pair" on a scanned detector.
  Future<bool> pair(String id, String name) async {
    _reconnect?.cancel();
    _pairing = true;
    final existing = await db.getDetector(id);
    final info = await ble.connect(id, pinnedBoard: existing?.bonded == true ? existing!.board : null);
    _pairing = false;
    if (info == null) return false;
    await _pin(id, name, info);
    return true;
  }

  Future<void> _pin(String id, String name, DeviceInfoMessage info) async {
    await db.upsertDetector(DetectorsCompanion(
      id: Value(id),
      name: Value(name.isEmpty ? 'Orecchino' : name),
      board: Value(info.board),
      fw: Value(info.firmware),
      ver: Value(info.version),
      caps: Value(info.capabilities.join(',')),
      lastSeen: Value(nowMs() ~/ 1000),
      bonded: const Value(true),
    ));
    _pinnedId = id;
    _reconnectDelayS = 5;
    await _onLinkReady();
  }

  Future<void> connectPinned(String id) async {
    final d = await db.getDetector(id);
    if (d == null || !d.bonded) return; // never auto-connect an unpinned device
    _reconnect?.cancel();
    final info = await ble.connect(id, pinnedBoard: d.board);
    if (info == null) {
      _scheduleReconnect();
      return;
    }
    await db.upsertDetector(DetectorsCompanion(
      id: Value(id),
      name: Value(d.name),
      board: Value(info.board),
      fw: Value(info.firmware),
      ver: Value(info.version),
      caps: Value(info.capabilities.join(',')),
      lastSeen: Value(nowMs() ~/ 1000),
      bonded: const Value(true),
    ));
    _pinnedId = id;
    _reconnectDelayS = 5;
    await _onLinkReady();
  }

  Future<void> _reconnectPinned() async {
    if (settings.demo || ble.state != BleLinkState.idle && ble.state != BleLinkState.failed) return;
    final pinned = await db.pinnedDetectors();
    if (pinned.isEmpty) return;
    pinned.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    await connectPinned(pinned.first.id);
  }

  void _scheduleReconnect() {
    if (settings.demo || _disposed || !startTimers) return;
    _reconnect?.cancel();
    _reconnect = Timer(Duration(seconds: _reconnectDelayS), _reconnectPinned);
    _reconnectDelayS = (_reconnectDelayS * 2).clamp(5, 60);
  }

  Future<void> disconnect() async {
    _reconnect?.cancel();
    sync.abort('disconnected');
    _pinnedId = null;
    await ble.disconnect();
    unawaited(alerts.foreground(null));
    _changed();
  }

  /// Unpin: the app will not connect to it again unless paired again.
  Future<void> forget(String id) async {
    if (_pinnedId == id) await disconnect();
    await db.forgetDetector(id);
    await ble.forgetBond(id);
    _changed();
  }

  void _onBleChanged() {
    if (settings.demo) return;
    if (ble.state != BleLinkState.ready && _pinnedId != null) {
      // The link dropped (or was replaced): stop what needed it.
      _pinnedId = null;
      sync.abort();
      unawaited(alerts.foreground(null));
      if (!_pairing) _scheduleReconnect();
    }
    _changed();
  }

  Future<void> _onLinkReady() async {
    if (!detectorReady) return;
    if (!settings.demo) {
      unawaited(alerts.foreground('Orecchino connected to 1 detector'));
    }
    await _send(HostCommands.feed(on: true));
    await pushContext();
    await syncNow();
    await pushTraffic();
  }

  Future<bool> _send(String cmd) async {
    try {
      await link.send(cmd);
      return true;
    } catch (e) {
      debugPrint('send failed: $e');
      return false;
    }
  }

  /// Send a command for a screen; returns an error in words, or null.
  Future<String?> command(String cmd) async {
    if (!detectorReady) return 'No detector connected';
    try {
      await link.send(cmd);
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<void> syncNow() async {
    final id = connectedDetectorId;
    if (id == null || !detectorReady) return;
    if (settings.demo) {
      await db.upsertDetector(const DetectorsCompanion(
        id: Value('simulated'),
        name: Value('SIMULATED DETECTOR'),
        board: Value('simulated'),
      ));
    }
    await sync.startSync(id);
  }

  /// set_time and set_home: only to the verified, pinned detector (or the
  /// demo detector), never to an unverified device.
  Future<void> pushContext() async {
    if (!detectorReady) return;
    final nowS = nowMs() ~/ 1000;
    if (!await _send(HostCommands.setTime(nowS))) return;
    if (settings.demo) return; // the demo position is not the phone's
    final l = location.currentLocation;
    if (l != null) {
      await _send(HostCommands.setHome(lat: l.lat, lon: l.lon, accuracyM: l.accuracyM, source: 'phone'));
    }
  }

  // ------------------------------------------------------------------ traffic

  Future<void> refreshTraffic() async {
    if (!settings.adsb) return;
    final now = nowMs();
    if (settings.demo) {
      traffic.update(sim.demoAircraft(now), now,
          obsLat: SimulatedDetector.centerLat, obsLon: SimulatedDetector.centerLon);
      _adsbError = null;
      await pushTraffic();
      return;
    }
    final l = location.currentLocation;
    if (l == null) return;
    try {
      final list = await adsb.fetch(l.lat, l.lon, now);
      traffic.update(list, now, obsLat: l.lat, obsLon: l.lon);
      _adsbError = null;
      await pushTraffic();
    } catch (e) {
      _adsbError = 'ADS-B fetch failed';
      debugPrint('adsb: $e');
    }
    _changed();
  }

  /// The `traffic` lines to a board that takes them (plan §8.1).
  Future<void> pushTraffic() async {
    final info = detectorInfo;
    final dataMs = traffic.dataMs;
    if (!detectorReady || info == null || !info.has('traffic') || dataMs == null) return;
    final now = nowMs();
    final lines = TrafficWire.hostLines(traffic.aircraft, now, now ~/ 1000, (now - dataMs) / 1000.0);
    for (final l in lines) {
      if (!await _send(l)) return;
    }
  }

  List<TrafficDrone> _drones(int now) => [
        for (final c in tracker.contacts)
          TrafficDrone(
            id: c.key,
            lat: c.lat,
            lon: c.lon,
            altGeoM: c.altGeoM,
            speedMps: c.speedMps,
            headingDeg: c.headingDeg,
            live: c.hasPosition && c.ageS(now) <= 60,
          )
      ];

  TrafficObserver get _trafficObserver {
    if (settings.demo) {
      return const TrafficObserver(lat: SimulatedDetector.centerLat, lon: SimulatedDetector.centerLon, elevM: 10);
    }
    final l = location.currentLocation;
    return l == null ? TrafficObserver.unknown : TrafficObserver(lat: l.lat, lon: l.lon, elevM: l.altitudeM);
  }

  // --------------------------------------------------------------------- tick

  /// Once a second: expire contacts, run the traffic rules, raise alerts.
  void tick() {
    final now = nowMs();
    tracker.expire(now);
    final result = traffic.tick(nowMs: now, observer: _trafficObserver, drones: _drones(now));
    final o = observer;
    final events = policy.consider(
      nowMs: now,
      traffic: result,
      aircraft: traffic.byHex,
      drones: tracker.contacts,
      detectorConnected: detectorReady,
      obsLat: o?.lat,
      obsLon: o?.lon,
      headingDeg: headingDeg,
    );
    var trafficHaptic = false, droneHaptic = false;
    for (final e in events) {
      if (settings.notifications) unawaited(alerts.notify(e));
      if (e.source == AlertSource.traffic) {
        trafficHaptic = true;
        if (settings.spoken && e.spoken != null) unawaited(alerts.speak(e.spoken!));
      } else {
        droneHaptic = true;
      }
    }
    if (settings.haptics) {
      if (trafficHaptic) {
        unawaited(alerts.haptic(AlertSource.traffic));
      } else if (droneHaptic) {
        unawaited(alerts.haptic(AlertSource.drone));
      }
    }
    _updateOngoing(result, now);
    _changed();
  }

  void _updateOngoing(TrafficResult r, int now) {
    TrafficAlert? w;
    for (final a in r.alerts) {
      if (a.level == TrafficLevel.warning) {
        w = a;
        break;
      }
    }
    if (w == null || !settings.notifications || policy.isMuted(now)) {
      if (_ongoingId != null) unawaited(alerts.ongoing(null));
      _ongoingId = null;
      return;
    }
    final ac = traffic.byHex(w.hex);
    _ongoingId = w.id;
    unawaited(alerts.ongoing(AlertEvent(
      id: 't|${w.id}',
      source: AlertSource.traffic,
      level: w.level,
      title: AlertWords.title(w),
      body: AlertWords.body(w, ac),
      hex: w.hex,
    )));
  }

  void _onNotificationAction(String action, String? payload) {
    if (action == SystemAlertSink.actionMute) {
      policy.mute(nowMs());
      unawaited(alerts.ongoing(null));
      _ongoingId = null;
    } else if (payload != null) {
      final parts = payload.split('|');
      // t|kind|drone|hex  or  d|words|key
      showRequest.value = parts.first == 't' && parts.length >= 4 ? parts[3] : parts.last;
    }
    _changed();
  }

  void muteAlerts() {
    policy.mute(nowMs());
    _changed();
  }

  void _onLocationChanged() {
    final now = nowMs();
    tracker.updateObserver(observer, now);
    // Compass events arrive many times a second: repaint for a change of a
    // degree or more, at most 20 times a second.
    final h = location.headingDeg;
    if (h != null && _lastHeading != null && (h - _lastHeading!).abs() < 1 && now - _lastHeadingNotifyMs < 1000) {
      return;
    }
    if (now - _lastHeadingNotifyMs < 50) return;
    _lastHeading = h;
    _lastHeadingNotifyMs = now;
    _changed();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _tick?.cancel();
    _ctxTimer?.cancel();
    _adsbTimer?.cancel();
    _reconnect?.cancel();
    _msgSub?.cancel();
    _syncSub?.cancel();
    ble.removeListener(_onBleChanged);
    location.removeListener(_onLocationChanged);
    showRequest.dispose();
    sync.dispose();
    sim.dispose();
    ble.dispose();
    location.dispose();
    adsb.close();
    db.close();
    super.dispose();
  }
}
