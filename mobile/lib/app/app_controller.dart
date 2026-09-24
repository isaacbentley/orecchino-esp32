// app_controller.dart — wires the detector link, sync, live contacts, ADS-B
// traffic and alerts together (plan §5.2), for the screens to watch.
//
// - Real mode: the BLE link. Pairing a new detector is always the person's
//   choice ("Pair"); once it has verified (device info, encrypted link) it
//   is pinned, and later the app reconnects to pinned detectors by itself.
// - On every ready link to a pinned detector: feed on, set_time, set_home,
//   log_get from the stored cursor; then set_time/set_home every 60 s and
//   the ADS-B set as it is fetched (boards with "traffic").
// - ADS-B is fetched every 10 s only while it matters (a live drone, or a
//   detector that takes traffic), otherwise every 60 s, never without a
//   position; failures back off to 5 minutes (power_policy.dart).
// - Power: the policy (power_policy.dart) follows the power mode, the
//   foreground and the visible tab ([setVisibility]); the location, the
//   compass, the phone's receiver and ADS-B follow it. The compass heading
//   has its own listenable ([heading]): turning the phone repaints the sky
//   and Find's pointer, not the whole app.
// - Reconnecting: to a pinned detector the app keeps one pending connect
//   (no timeout, no scanning) where the platform has one: on iPhone
//   always, on Android once the detector is associated with the app
//   through the CompanionDeviceManager (asked after pairing, or when
//   "Watch in the background" is turned on). Otherwise, the old loop: a
//   15 s connect retried after 5 s, doubling to 60 s.
// - "Watch in the background" (Android, off by default): the native
//   foreground service (watch_service.dart) with its notification, started
//   only while the app is on screen.
// - ADS-B is only for drone-aircraft conflicts: 10 km around the phone by
//   default (5-30 km), widened around far drones (AdsbArea.plan); aircraft
//   outside the area are dropped. The screens show aircraft only while an
//   alert names them. The phone's position
//   goes only to a verified, pinned detector, never to "any NUS device".
// - Demo mode: the simulated detector, and a simulated phone position.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';

import '../core/alerts/alert_policy.dart';
import '../core/alerts/notifier.dart';
import '../core/background/watch_service.dart';
import '../core/ble/ble_service.dart';
import '../core/ble/simulated_detector.dart';
import '../core/link/detector_link.dart';
import '../core/live/contact_tracker.dart';
import '../core/live/phone_history.dart';
import '../core/live/sensors.dart';
import '../core/location/location_service.dart';
import '../core/native_rx/ble_scan_coordinator.dart';
import '../core/native_rx/native_rx_service.dart';
import '../core/power/power_policy.dart';
import '../core/protocol/commands.dart';
import '../core/protocol/messages.dart';
import '../core/sync/sync_engine.dart';
import '../core/traffic/adsb_source.dart';
import '../core/traffic/traffic_rules.dart';
import '../data/db.dart';
import '../ui/theme/look.dart';

class AppSettings {
  bool demo = false;
  bool adsb = true;
  bool notifications = true;
  bool haptics = true;
  bool spoken = false;

  /// "Use this phone as a detector": the phone's own Remote ID receiver.
  bool phoneRx = true;
  int adsbRadiusKm = AdsbArea.defaultKm; // 5-30

  /// Map tiles: '' (the default, Esri Dark Gray Canvas) or the person's own
  /// {z}/{x}/{y} template (with its key) and its attribution.
  String mapUrl = '';
  String mapAttribution = '';

  /// Full / Balanced / Saver (power_policy.dart).
  PowerMode powerMode = PowerMode.balanced;

  /// Android: keep watching with the app closed (a foreground service and
  /// its notification). Off by default.
  bool watchInBackground = false;

  /// Sky (the first-run default) or Flat (ui/theme/look.dart).
  AppLook look = AppLook.sky;
}

class AppController extends ChangeNotifier {
  final AppDatabase db;
  final BleService ble;
  final SimulatedDetector sim;
  final LocationService location;
  final AlertSink alerts;
  final AdsbSource adsb;

  /// The phone's own Remote ID receiver (null: none, as in most tests). It
  /// shares one BleScanCoordinator with [ble] ([AppController.platform]).
  final NativeRxService? nativeRx;

  /// Android's background service and companion association (null: none,
  /// as in most tests).
  final WatchService? watch;
  final PhoneHistory phoneHistory = PhoneHistory();
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
    this.nativeRx,
    this.watch,
    this.startTimers = true,
  })  : ble = ble ?? BleService(),
        sim = sim ?? SimulatedDetector(),
        location = location ?? LocationService(),
        alerts = alerts ?? SilentAlertSink(),
        adsb = adsb ?? AdsbSource() {
    sync = SyncEngine(db: db, sendCommand: (c) => link.send(c));
  }

  /// The real app: one Bluetooth scan coordinator shared by the detector
  /// picker (BleService) and the phone's own receiver, switched together.
  factory AppController.platform({required AppDatabase db, AlertSink? alerts}) {
    final coordinator = BleScanCoordinator(FbpScanBackend());
    return AppController(
      db: db,
      alerts: alerts,
      ble: BleService(transport: CoordinatedBleTransport(coordinator)),
      nativeRx: NativeRxService.platform(coordinator: coordinator),
      watch: WatchService.platform(),
    );
  }

  StreamSubscription<RidMessage>? _phoneSub, _simPhoneSub;
  int _lastPhoneFlushMs = 0;

  /// Whether this phone can be a detector at all (iOS and Android).
  bool get phoneRxSupported => nativeRx != null;

  /// Start the phone's receiver (Android asks for its Wi-Fi permissions
  /// first); its frames go straight to the tracker, never to the sync.
  Future<void> _startPhoneRx() async {
    final rx = nativeRx;
    if (rx == null || !settings.phoneRx || rx.running) return;
    _phoneSub ??= rx.messages.listen(ingestPhoneFrame);
    try {
      if (rx.isAndroid) await rx.wifi.requestPermissions();
    } catch (e) {
      debugPrint('phone rx permissions: $e');
    }
    try {
      await rx.refreshCapabilities();
      await rx.start();
    } catch (e) {
      debugPrint('phone rx: $e');
    }
    _changed();
  }

  Future<void> _stopPhoneRx() async {
    final rx = nativeRx;
    if (rx == null) return;
    await rx.stop();
    _changed();
  }

  /// "Use this phone as a detector".
  Future<void> setPhoneRx(bool on) async {
    settings.phoneRx = on;
    await db.setSetting('phone_rx', on ? '1' : '0');
    if (on) {
      await _startPhoneRx();
    } else {
      await _stopPhoneRx();
    }
    _changed();
  }

  /// A frame the phone heard itself: into the tracker (fused with the
  /// detectors' lines) and the phone's own History records.
  void ingestPhoneFrame(RidMessage m) {
    if (!settings.phoneRx) return;
    final now = nowMs();
    final c = tracker.ingest(m, now, observer);
    if (c != null) phoneHistory.note(c, m, now);
  }

  /// The connected detector's short name for sensor chips ("T5").
  String get detectorShort => detectorShortName(connectedDetectorName, detectorInfo?.board);

  StreamSubscription<HostMessage>? _msgSub;
  StreamSubscription<SyncProgress>? _syncSub;
  Timer? _tick, _ctxTimer, _reconnect;
  int _reconnectDelayS = 5;
  bool _disposed = false;
  bool _pairing = false; // the current connect was the person's "Pair"
  String? _pinnedId; // the connected detector, once verified and pinned
  String? _adsbError;
  int _adsbLastMs = -1 << 40; // the last ADS-B attempt
  int _adsbFailures = 0; // consecutive failed fetches (the backoff)
  PhoneLocation? _lastLocation;
  LocationStatus? _lastLocationStatus;
  String? _ongoingId;
  int _revision = 0;

  /// Bumped on every notify: derived data (the live items) is cached per
  /// revision.
  int get revision => _revision;

  late final ValueNotifier<double?> _heading = ValueNotifier<double?>(location.headingDeg);

  /// The compass heading, throttled (location_service.dart); the sky's
  /// camera and Find's pointer listen to it. The whole app is notified only
  /// by its 1 Hz tick and by real changes, never by a turn of the phone.
  ValueListenable<double?> get heading => _heading;

  // ------------------------------------------------------------------ power

  bool _foreground = true;
  AppTab _tab = AppTab.live;
  bool _reduceMotion = false;
  late PowerPolicy _power = _policyNow();
  late final ValueNotifier<PowerPolicy> power = ValueNotifier<PowerPolicy>(_power);

  /// What the app does now to save power (power_policy.dart).
  PowerPolicy get powerPolicy => _power;
  bool get foreground => _foreground;
  AppTab get visibleTab => _tab;

  bool get _isIOS => defaultTargetPlatform == TargetPlatform.iOS;

  bool _droneRecentlyHeard(int now) =>
      tracker.contacts.any((c) => now - c.lastSeenMs <= PowerPolicy.droneRecent.inMilliseconds);

  PowerPolicy _policyNow() {
    final now = nowMs();
    return PowerPolicy.of(
      mode: settings.powerMode,
      foreground: _foreground,
      tab: _tab,
      isIOS: _isIOS,
      reduceMotion: _reduceMotion,
      droneRecentlyHeard: _droneRecentlyHeard(now),
      paused: now < _watchPausedUntilMs,
    );
  }

  /// The screens say what is visible: the app in the foreground or not,
  /// the tab on screen, Reduce Motion.
  void setVisibility({bool? foreground, AppTab? tab, bool? reduceMotion}) {
    final wasFg = _foreground;
    _foreground = foreground ?? _foreground;
    _tab = tab ?? _tab;
    _reduceMotion = reduceMotion ?? _reduceMotion;
    _applyPower();
    if (_foreground && !wasFg) {
      // Back in front: fresh time and position to the detector, and the
      // traffic picture if it is due; a watch stopped from its
      // notification may start again, and a pause ends.
      _watchStopped = false;
      _watchPausedUntilMs = 0;
      unawaited(pushContext());
      if (adsbDue(nowMs())) unawaited(refreshTraffic());
    }
    if (_foreground != wasFg) unawaited(_syncWatch());
  }

  // ---------------------------------------------------- background watching

  StreamSubscription<WatchAction>? _watchSub;
  Set<String> _companions = {};
  bool _watchStopped = false; // "Stop" in the notification, until the app is opened
  int _watchPausedUntilMs = 0; // "Pause 1 h"

  /// Detectors associated through Android's CompanionDeviceManager.
  Set<String> get companions => Set.unmodifiable(_companions);

  bool get watchRunning => watch?.running ?? false;
  bool get watchPaused => nowMs() < _watchPausedUntilMs;

  /// The notification's words: "Orecchino watching · 2 drones · conflict
  /// watch on · T5 connected".
  String watchText([int? at]) {
    final now = at ?? nowMs();
    if (now < _watchPausedUntilMs) {
      final t = DateTime.fromMillisecondsSinceEpoch(_watchPausedUntilMs);
      return 'Orecchino paused until ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}'
          '${detectorReady ? ' · $detectorShort connected' : ''}';
    }
    final n = tracker.contacts.where((c) => c.ageS(now) <= 60).length;
    final watchWords = !settings.adsb
        ? 'conflict watch off'
        : (observer == null ? 'conflict watch: no position' : (_adsbError != null ? 'conflict watch stale' : 'conflict watch on'));
    return [
      'Orecchino watching',
      n == 0 ? 'no drones' : (n == 1 ? '1 drone' : '$n drones'),
      watchWords,
      detectorReady ? '$detectorShort connected' : 'no detector',
    ].join(' · ');
  }

  /// "Watch in the background" (Android).
  Future<void> setWatchInBackground(bool on) async {
    settings.watchInBackground = on;
    await db.setSetting('watch_bg', on ? '1' : '0');
    if (on) {
      _watchStopped = false;
      // Reconnecting in the background works best with the detector
      // associated (the system asks, once per detector).
      for (final d in await db.pinnedDetectors()) {
        await _associate(d.id, d.name);
      }
    }
    await _syncWatch();
    _changed();
  }

  /// Start, update or stop the service to match the setting. It starts
  /// only while the app is on screen.
  Future<void> _syncWatch() async {
    final w = watch;
    if (w == null || !w.supported || _disposed) return;
    final want = settings.watchInBackground && !_watchStopped;
    if (!want) {
      if (w.running) await w.stop();
      return;
    }
    if (!w.running) {
      if (!_foreground) return;
      await w.start(watchText(), location: location.status == LocationStatus.ok);
      _changed();
    } else {
      await w.update(watchText());
    }
  }

  void _onWatchAction(WatchAction a) {
    final now = nowMs();
    switch (a.action) {
      case 'pause':
        _watchPausedUntilMs = now + const Duration(hours: 1).inMilliseconds;
        policy.mute(now, const Duration(hours: 1).inMilliseconds);
        unawaited(alerts.ongoing(null));
        _ongoingId = null;
        _applyPower();
        unawaited(_syncWatch());
      case 'stop':
        watch?.stoppedByNotification();
        _watchStopped = true;
      case 'appeared':
        // The companion service saw the detector: make sure a connect is
        // waiting for it.
        unawaited(_reconnectPinned());
    }
    _changed();
  }

  /// Associate a pinned detector with the app (Android's companion
  /// dialog), once.
  Future<void> _associate(String id, String name) async {
    final w = watch;
    if (w == null || !w.supported || _companions.contains(id.toUpperCase())) return;
    if (!await w.companionSupported()) return;
    if (await w.associate(id, name)) _companions.add(id.toUpperCase());
  }

  /// A pending connect for [id]: on iPhone always, on Android once the
  /// detector is associated (see the file comment).
  bool _pendingFor(String id) =>
      ble.transport.pendingConnect && (_isIOS || _companions.contains(id.toUpperCase()));

  /// Sky or Flat: applied at once, everywhere, and remembered.
  Future<void> setLook(AppLook l) async {
    if (l == settings.look && l == Look.current) return;
    settings.look = l;
    Look.apply(l);
    await db.setSetting('look', l.name);
    _changed();
  }

  Future<void> setPowerMode(PowerMode m) async {
    if (m == settings.powerMode) return;
    settings.powerMode = m;
    await db.setSetting('power_mode', m.name);
    _applyPower();
    _changed();
  }

  /// Apply the policy to everything that follows it.
  void _applyPower({bool force = false}) {
    final p = _policyNow();
    if (!force && p == _power) return;
    _power = p;
    if (!_disposed) power.value = p;
    location.configure(precision: p.location, compassHz: p.compassHz);
    nativeRx?.applyPolicy(p);
  }

  // ------------------------------------------------------------------ ADS-B

  /// When the next ADS-B fetch is due after the last (null: not now).
  Duration? get adsbInterval {
    final now = nowMs();
    final info = detectorInfo;
    return adsbNextDelay(
      policy: _power,
      enabled: settings.adsb,
      hasPosition: observer != null,
      liveDrones: tracker.contacts.any((c) => c.hasPosition && c.ageS(now) <= 60),
      trafficDetector: detectorReady && info != null && info.has('traffic'),
      failures: _adsbFailures,
    );
  }

  /// Whether an ADS-B fetch is due now.
  bool adsbDue(int now) {
    final d = adsbInterval;
    return d != null && now - _adsbLastMs >= d.inMilliseconds;
  }

  /// Consecutive failed ADS-B fetches (the backoff), for the tests.
  int get adsbFailures => _adsbFailures;

  /// The board's last map plan ("Map: 3 km z12-15; 0.8 MB of 11.9 MB"),
  /// from its "net" status lines; null until one arrives.
  String? mapPlan;

  /// A short notice for the screens ("History cleared on T5"), cleared by
  /// whoever shows it.
  final ValueNotifier<String?> notice = ValueNotifier<String?>(null);

  Completer<void>? _clearWait;
  String? _pinnedName;

  /// The connected detector's name, for the words ("Clear history on T5").
  String? get connectedDetectorName => settings.demo ? 'SIMULATED DETECTOR' : (_pinnedId == null ? null : _pinnedName);

  /// Set when a notification's Show is tapped: the contact to select.
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
    location.heading.addListener(_syncHeading);
    _syncHeading();
    _applyPower(force: true);
    final w = watch;
    if (w != null && w.supported) {
      _watchSub = w.actions.listen(_onWatchAction);
      _companions = {...await w.associations()};
      unawaited(_syncWatch());
    }
    _syncSub = sync.progress.listen((_) => _changed());
    _bindLink();
    unawaited(location.start());
    nativeRx?.addListener(_changed);
    // The demo's stand-in for the phone's receiver (SIMULATED).
    _simPhoneSub = sim.phoneFrames.listen((m) {
      if (settings.demo) ingestPhoneFrame(m);
    });
    unawaited(_startPhoneRx());
    if (startTimers) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) => tick());
      _ctxTimer = Timer.periodic(const Duration(seconds: 60), (_) => pushContext());
      // ADS-B: checked on the tick (adsbDue), fetched only when due.
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
    settings.phoneRx = await b('phone_rx', true);
    settings.powerMode = PowerMode.parse(await db.getSetting('power_mode'));
    settings.watchInBackground = await b('watch_bg', false);
    settings.look = AppLook.parse(await db.getSetting('look'));
    Look.apply(settings.look);
    settings.mapUrl = await db.getSetting('map_url') ?? '';
    settings.mapAttribution = await db.getSetting('map_attribution') ?? '';
    final home = (await db.getSetting('last_home'))?.split(',');
    if (home != null && home.length == 2) {
      final lat = double.tryParse(home[0]), lon = double.tryParse(home[1]);
      if (lat != null && lon != null) lastHome = ObserverFix(lat, lon);
    }
    settings.adsbRadiusKm =
        int.tryParse(await db.getSetting('adsb_km') ?? '')?.clamp(AdsbArea.minKm, AdsbArea.maxKm) ?? AdsbArea.defaultKm;
  }

  /// The map's own tile template ('' for the default) and its attribution.
  Future<void> setMapTiles(String url, String attribution) async {
    settings.mapUrl = url.trim();
    settings.mapAttribution = attribution.trim();
    await db.setSetting('map_url', settings.mapUrl);
    await db.setSetting('map_attribution', settings.mapAttribution);
    _changed();
  }

  /// The phone's last known position (saved, rounded to about 100 m): the
  /// map's centre before a fix.
  ObserverFix? lastHome;
  int _lastHomeSaveMs = 0;

  void _saveHome(int now) {
    final l = location.currentLocation;
    if (l == null || settings.demo) return;
    final h = lastHome;
    final moved = h == null || (h.lat - l.lat).abs() > 0.002 || (h.lon - l.lon).abs() > 0.002;
    if (!moved && now - _lastHomeSaveMs < 10 * 60 * 1000) return;
    lastHome = ObserverFix(l.lat, l.lon);
    _lastHomeSaveMs = now;
    unawaited(db.setSetting('last_home', '${l.lat.toStringAsFixed(3)},${l.lon.toStringAsFixed(3)}'));
  }

  /// The ADS-B query radius around the phone, km (5-30).
  Future<void> setAdsbRadiusKm(int km) async {
    final v = km.clamp(AdsbArea.minKm, AdsbArea.maxKm);
    if (v == settings.adsbRadiusKm) return;
    settings.adsbRadiusKm = v;
    await db.setSetting('adsb_km', '$v');
    _changed();
    unawaited(refreshTraffic());
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
      tracker.ingest(msg, nowMs(), observer, detector: detectorShort);
    } else if (msg is NetStatusMessage && msg.map != null && msg.map!.isNotEmpty) {
      mapPlan = msg.map;
    } else if (msg is LogClearedMessage) {
      unawaited(_onLogCleared());
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
    // Android: associate it now, while the person is here, so later
    // reconnects wait for it instead of scanning.
    unawaited(_associate(id, name));
    return true;
  }

  /// The detector's log was cleared, because this phone asked or from its
  /// own screen (it tells every connected app): start a new log epoch and
  /// sync from the start of its new log. This phone's history stays.
  Future<void> _onLogCleared() async {
    final id = connectedDetectorId;
    if (id == null) return;
    sync.abort('the detector cleared its log');
    await db.resetDetectorLog(id);
    final wait = _clearWait;
    _clearWait = null;
    if (wait != null && !wait.isCompleted) wait.complete();
    notice.value = 'History cleared on ${connectedDetectorName ?? 'the detector'}';
    _changed();
    unawaited(syncNow());
  }

  /// Delete this phone's history (every detector's records); pins, cursors
  /// and settings stay. Returns the records deleted.
  Future<int> clearPhoneHistory() async {
    phoneHistory.clear();
    final n = await db.clearLocalHistory();
    _changed();
    return n;
  }

  /// Ask the connected, verified detector to clear its log, and wait for
  /// its log_cleared. Returns an error in words, or null when it cleared.
  Future<String?> clearDetectorHistory({Duration timeout = const Duration(seconds: 5)}) async {
    if (!detectorReady || connectedDetectorId == null) return 'No verified detector is connected';
    final wait = _clearWait = Completer<void>();
    try {
      await link.send(HostCommands.logClear());
    } catch (e) {
      _clearWait = null;
      return 'Could not send to the detector: $e';
    }
    try {
      await wait.future.timeout(timeout);
      return null;
    } on TimeoutException {
      _clearWait = null;
      final secs = (timeout.inMilliseconds / 1000).toStringAsFixed(timeout.inMilliseconds % 1000 == 0 ? 0 : 1);
      return '${connectedDetectorName ?? 'The detector'} did not confirm within $secs s: '
          'its history may not have been cleared';
    }
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
    _pinnedName = name.isEmpty ? 'Orecchino' : name;
    _reconnectDelayS = 5;
    await _onLinkReady();
  }

  Future<void> connectPinned(String id) async {
    final d = await db.getDetector(id);
    if (d == null || !d.bonded) return; // never auto-connect an unpinned device
    _reconnect?.cancel();
    final info = await ble.connect(id, pinnedBoard: d.board, pending: _pendingFor(id));
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
    _pinnedName = d.name;
    _reconnectDelayS = 5;
    await _onLinkReady();
  }

  Future<void> _reconnectPinned() async {
    if (settings.demo || ble.state != BleLinkState.idle && ble.state != BleLinkState.failed) return;
    if (ble.waitingFor != null) return; // a pending connect already waits
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
    // The connection's ongoing notification: Android's watch service when
    // that is on (its own notification says so), otherwise the alerts'.
    if (!settings.demo && !(watch?.supported ?? false)) {
      unawaited(alerts.foreground('Orecchino connected to 1 detector'));
    }
    unawaited(_syncWatch());
    await _send(HostCommands.feed(on: true));
    await pushContext();
    await syncNow();
    // A fresh ADS-B set at once (it is pushed to the board as it arrives),
    // so the conflict watch does not wait for the first 10 s tick.
    await refreshTraffic();
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

  /// Where to ask for aircraft now: around the phone, widened around live
  /// drones more than 3 km out; null without a position.
  AdsbArea? adsbArea([int? at]) {
    final o = observer;
    if (o == null) return null;
    final now = at ?? nowMs();
    final live = [
      for (final c in tracker.contacts)
        if (c.hasPosition && c.lat != null && c.lon != null && c.ageS(now) <= 60) (c.lat!, c.lon!)
    ];
    return AdsbArea.plan(o.lat, o.lon, live, settings.adsbRadiusKm * 1000.0);
  }

  Future<void> refreshTraffic() async {
    if (!settings.adsb) return;
    final now = nowMs();
    final area = adsbArea(now);
    if (area == null) return;
    _adsbLastMs = now;
    if (settings.demo) {
      traffic.update(sim.demoAircraft(now), now, area);
      _adsbError = null;
      await pushTraffic();
      return;
    }
    try {
      final list = await adsb.fetch(area, now);
      traffic.update(list, now, area);
      if (_adsbFailures > 0 && kDebugMode) debugPrint('adsb: back after $_adsbFailures failures');
      _adsbError = null;
      _adsbFailures = 0;
      await pushTraffic();
    } catch (e) {
      _adsbError = 'ADS-B fetch failed';
      // Back off (10 s doubling to 5 minutes); log the first failure only.
      if (_adsbFailures == 0 && kDebugMode) debugPrint('adsb: $e');
      _adsbFailures++;
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
            heightM: c.heightM,
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
    if (startTimers && adsbDue(now)) unawaited(refreshTraffic());
    // In the background the scan follows whether a drone was heard lately
    // (and a pause's end).
    if (!_foreground) _applyPower();
    if (watchRunning) unawaited(_syncWatch());
    // The phone's own records, every few seconds.
    if (now - _lastPhoneFlushMs >= 5000) {
      _lastPhoneFlushMs = now;
      unawaited(phoneHistory.flush(db, now).catchError((Object e) => debugPrint('phone history: $e')));
    }
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
      // t|kind|drone|hex  or  d|words|key. Traffic shows its drone (the
      // aircraft is drawn beside it while the alert lasts); low traffic
      // anchored on you shows the aircraft.
      if (parts.first == 't' && parts.length >= 4) {
        showRequest.value = parts[2].isNotEmpty ? parts[2] : parts[3];
      } else {
        showRequest.value = parts.last;
      }
    }
    _changed();
  }

  void muteAlerts() {
    policy.mute(nowMs());
    _changed();
  }

  /// The position (or its status) changed; the heading is not notified
  /// here (see [heading]).
  void _onLocationChanged() {
    _syncHeading();
    final l = location.currentLocation;
    final st = location.status;
    if (identical(l, _lastLocation) && st == _lastLocationStatus) return;
    final first = _lastLocation == null && l != null;
    _lastLocation = l;
    _lastLocationStatus = st;
    final now = nowMs();
    tracker.updateObserver(observer, now);
    _saveHome(now);
    _changed();
    // The first fix: the conflict watch need not wait for the next check.
    if (first && startTimers && adsbDue(now)) unawaited(refreshTraffic());
  }

  void _syncHeading() {
    if (!_disposed) _heading.value = location.headingDeg;
  }

  void _changed() {
    if (_disposed) return;
    _revision++;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _tick?.cancel();
    _ctxTimer?.cancel();
    _reconnect?.cancel();
    _msgSub?.cancel();
    _syncSub?.cancel();
    _watchSub?.cancel();
    ble.removeListener(_onBleChanged);
    location.removeListener(_onLocationChanged);
    location.heading.removeListener(_syncHeading);
    _heading.dispose();
    power.dispose();
    showRequest.dispose();
    notice.dispose();
    sync.dispose();
    sim.dispose();
    ble.dispose();
    location.dispose();
    adsb.close();
    unawaited(_phoneSub?.cancel());
    unawaited(_simPhoneSub?.cancel());
    nativeRx?.removeListener(_changed);
    nativeRx?.dispose();
    db.close();
    super.dispose();
  }
}
