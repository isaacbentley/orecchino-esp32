// power_test.dart — the power policy (Full / Balanced / Saver), ADS-B gating
// and backoff, the app following the lifecycle and the visible tab (the
// compass, location, the phone's scan and Wi-Fi paths), the compass
// throttle, the ambient clock, "Watch in the background" over its channel,
// pending reconnects, and the frames-per-second budget of the Live screen.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orecchino_mobile/app/app_controller.dart';
import 'package:orecchino_mobile/core/background/watch_service.dart';
import 'package:orecchino_mobile/core/ble/ble_service.dart';
import 'package:orecchino_mobile/core/location/location_service.dart';
import 'package:orecchino_mobile/core/native_rx/ble_rid_scanner.dart';
import 'package:orecchino_mobile/core/native_rx/ble_scan_coordinator.dart';
import 'package:orecchino_mobile/core/native_rx/native_rx_service.dart';
import 'package:orecchino_mobile/core/native_rx/rid_observation.dart';
import 'package:orecchino_mobile/core/native_rx/wifi_rid_android.dart';
import 'package:orecchino_mobile/core/power/power_policy.dart';
import 'package:orecchino_mobile/core/traffic/adsb_source.dart';
import 'package:orecchino_mobile/data/db.dart';
import 'package:orecchino_mobile/main.dart';
import 'package:orecchino_mobile/ui/ambient_clock.dart';
import 'package:orecchino_mobile/ui/glass_nav_bar.dart';

import 'support/fakes.dart';

/// A position, a fixed heading, and a record of what the policy asked for.
class PolicyLocation extends LocationService {
  final List<(LocationPrecision, int)> configured = [];
  PhoneLocation? fix = const PhoneLocation(lat: 37.8039, lon: -122.464, timeMs: 0);
  @override
  Future<void> start() async {}
  @override
  PhoneLocation? get currentLocation => fix;
  @override
  double? get headingDeg => 0;
  @override
  void configure({required LocationPrecision precision, required int compassHz}) {
    configured.add((precision, compassHz));
    super.configure(precision: precision, compassHz: compassHz);
  }
}

// ignore: close_sinks
class DutyBackend implements BleScanBackend {
  // ignore: close_sinks
  final _adverts = StreamController<BleAdvert>.broadcast(sync: true);
  // ignore: close_sinks
  final _scanning = StreamController<bool>.broadcast(sync: true);
  final List<ScanDuty> duties = [];
  bool on = false;
  @override
  Stream<BleAdvert> get adverts => _adverts.stream;
  @override
  Stream<bool> get scanning => _scanning.stream;
  @override
  bool get isScanningNow => on;
  @override
  Stream<bool> get adapterOn => const Stream.empty();
  @override
  Future<void> start(BleScanFilter filter, {ScanDuty duty = ScanDuty.lowLatency}) async {
    duties.add(duty);
    on = true;
    _scanning.add(true);
  }

  @override
  Future<void> stop() async {
    on = false;
    _scanning.add(false);
  }

  @override
  Future<BlePhyCaps> phyCaps() async => BlePhyCaps.unknown;
}

class RecordingWifi implements WifiRidPlatform {
  final List<String> calls = [];
  @override
  Future<Map<String, Object?>> capabilities() async => const {};
  @override
  Future<Map<String, Object?>> requestPermissions() async => const {};
  @override
  Future<Map<String, Object?>> start({required bool nan, required bool beacon, required int beaconIntervalMs}) async {
    calls.add('start nan:$nan beacon:$beacon every:$beaconIntervalMs');
    return {if (nan) 'nan': 'running', if (beacon) 'beacon': 'running'};
  }

  @override
  Future<void> stop() async => calls.add('stop');
  @override
  Stream<Map<Object?, Object?>> get events => const Stream.empty();
}

Future<void> settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// An app whose clock the test can move forward ([skewMs]) or hold still
/// ([fixedMs]).
class ClockApp extends AppController {
  int skewMs = 0;
  int? fixedMs;
  ClockApp({required super.db, super.ble, super.location, super.watch, super.startTimers});
  @override
  int nowMs() => fixedMs ?? super.nowMs() + skewMs;
}

void main() {
  group('power policy', () {
    PowerPolicy p(PowerMode m, {bool fg = true, AppTab tab = AppTab.live, bool ios = false, bool drone = false}) =>
        PowerPolicy.of(mode: m, foreground: fg, tab: tab, isIOS: ios, droneRecentlyHeard: drone);

    test('Full: 30 Hz, live blur, low latency with the coded PHY, balanced in the background', () {
      final f = p(PowerMode.full);
      expect(f.ambientHz, 30);
      expect(f.glass, GlassMode.live);
      expect(f.phoneScan, ScanDuty.lowLatency);
      expect(f.codedPhy, isTrue);
      expect(f.beaconEvery, const Duration(seconds: 30));
      expect(f.nan, isTrue);
      expect(f.adsbFast, const Duration(seconds: 10));
      expect(f.adsbSlow, const Duration(seconds: 10));
      expect(f.location, LocationPrecision.high);
      expect(f.compassHz, 15);
      final bg = p(PowerMode.full, fg: false);
      expect(bg.phoneScan, ScanDuty.balanced);
      expect(bg.ambientHz, 0);
      expect(bg.compassHz, 0);
    });

    test('Balanced: hardest on Live and Find, lighter elsewhere and in the background', () {
      final live = p(PowerMode.balanced);
      expect(live.ambientHz, 24);
      expect(live.auroraScale, 0.25);
      expect(live.glass, GlassMode.grouped);
      expect(live.phoneScan, ScanDuty.lowLatency);
      expect(live.nan, isTrue);
      expect(live.beaconEvery, const Duration(seconds: 60));
      expect(live.location, LocationPrecision.high);
      expect(live.compassHz, 10);
      final history = p(PowerMode.balanced, tab: AppTab.history);
      expect(history.phoneScan, ScanDuty.balanced);
      expect(history.nan, isFalse);
      expect(history.location, LocationPrecision.medium);
      expect(history.compassHz, 0);
      final bg = p(PowerMode.balanced, fg: false);
      expect(bg.phoneScan, ScanDuty.lowPower);
      expect(bg.beaconEvery, const Duration(minutes: 2));
      expect(bg.nan, isFalse);
      expect(p(PowerMode.balanced, fg: false, drone: true).phoneScan, ScanDuty.balanced);
      expect(live.adsbFast, const Duration(seconds: 10));
      expect(live.adsbSlow, const Duration(seconds: 60));
    });

    test('Saver: a still sky, no blur, the phone listens on Live and Find only', () {
      final live = p(PowerMode.saver);
      expect(live.ambientHz, 0);
      expect(live.glass, GlassMode.tint);
      expect(live.phoneScan, ScanDuty.balanced);
      expect(live.beaconEvery, isNull);
      expect(live.nan, isFalse);
      expect(live.location, LocationPrecision.medium);
      expect(live.compassHz, 0); // Find only
      expect(p(PowerMode.saver, tab: AppTab.find).compassHz, 10);
      expect(p(PowerMode.saver, tab: AppTab.detectors).phoneScan, ScanDuty.off);
      final bg = p(PowerMode.saver, fg: false);
      expect(bg.phoneScan, ScanDuty.off);
      expect(bg.location, LocationPrecision.off);
      expect(live.adsbFast, const Duration(seconds: 30));
      expect(live.adsbSlow, isNull);
    });

    test('iPhone: no Wi-Fi paths, and no phone scan in the background in any mode', () {
      for (final m in PowerMode.values) {
        expect(p(m, fg: false, ios: true).phoneScan, ScanDuty.off, reason: m.name);
        expect(p(m, ios: true).beaconEvery, isNull);
        expect(p(m, ios: true).nan, isFalse);
      }
      expect(p(PowerMode.balanced, ios: true).phoneScan, ScanDuty.lowLatency);
    });

    test('Reduce Motion stills the ambient motion; a pause rests the background', () {
      expect(PowerPolicy.of(mode: PowerMode.full, foreground: true, tab: AppTab.live, reduceMotion: true).ambientHz, 0);
      final paused = PowerPolicy.of(mode: PowerMode.full, foreground: false, tab: AppTab.live, paused: true);
      expect(paused.phoneScan, ScanDuty.off);
      expect(paused.nan, isFalse);
      expect(paused.beaconEvery, isNull);
      expect(paused.location, LocationPrecision.off);
      // In front a pause changes nothing.
      expect(PowerPolicy.of(mode: PowerMode.full, foreground: true, tab: AppTab.live, paused: true).phoneScan,
          ScanDuty.lowLatency);
    });

    test('PowerMode round-trips through its setting, Balanced by default', () {
      for (final m in PowerMode.values) {
        expect(PowerMode.parse(m.name), m);
      }
      expect(PowerMode.parse(null), PowerMode.balanced);
      expect(PowerMode.parse('turbo'), PowerMode.balanced);
    });
  });

  group('ADS-B gating and backoff', () {
    final balanced = PowerPolicy.of(mode: PowerMode.balanced, foreground: true, tab: AppTab.live);
    final saver = PowerPolicy.of(mode: PowerMode.saver, foreground: true, tab: AppTab.live);
    Duration? d(PowerPolicy p,
            {bool on = true, bool pos = true, bool drones = false, bool traffic = false, int failures = 0}) =>
        adsbNextDelay(
            policy: p, enabled: on, hasPosition: pos, liveDrones: drones, trafficDetector: traffic, failures: failures);

    test('10 s only with live drones or a traffic detector, otherwise 60 s; none without a position', () {
      expect(d(balanced), const Duration(seconds: 60));
      expect(d(balanced, drones: true), const Duration(seconds: 10));
      expect(d(balanced, traffic: true), const Duration(seconds: 10));
      expect(d(balanced, pos: false, drones: true), isNull);
      expect(d(balanced, on: false, drones: true), isNull);
      expect(d(saver), isNull);
      expect(d(saver, drones: true), const Duration(seconds: 30));
    });

    test('failures back off 10, 20, 40 s ... to 5 minutes', () {
      expect([for (var f = 1; f <= 8; f++) d(balanced, drones: true, failures: f)!.inSeconds],
          [10, 20, 40, 80, 160, 300, 300, 300]);
    });

    test('a failure never asks sooner than usual, nor at all where the policy asks for none', () {
      expect([for (var f = 1; f <= 4; f++) d(balanced, failures: f)!.inSeconds], [60, 60, 60, 80]);
      expect(d(saver, failures: 1), isNull);
      expect(d(saver, drones: true, failures: 1), const Duration(seconds: 30));
    });

    test('the app: 60 s with nothing about, 10 s with a live drone, and backs off after errors', () async {
      var fail = true;
      final gets = <Uri>[];
      final app = AppController(
        db: AppDatabase(NativeDatabase.memory()),
        ble: BleService(transport: FakeTransport()),
        location: PolicyLocation(),
        adsb: AdsbSource(client: MockClient((req) async {
          gets.add(req.url);
          return fail ? http.Response('down', 503) : http.Response('{"ac":[]}', 200);
        })),
        startTimers: false,
      );
      await app.start();
      expect(app.adsbInterval, const Duration(seconds: 60));
      final now = app.nowMs();
      expect(app.adsbDue(now), isTrue); // never fetched
      await app.refreshTraffic();
      expect(gets, hasLength(1));
      expect(app.adsbFailures, 1);
      expect(app.adsbInterval, const Duration(seconds: 60)); // never sooner than usual
      await app.refreshTraffic();
      expect(app.adsbFailures, 2);
      expect(app.adsbInterval, const Duration(seconds: 60));
      expect(app.adsbDue(app.nowMs()), isFalse);
      fail = false;
      await app.refreshTraffic();
      expect(app.adsbFailures, 0);
      expect(app.adsbError, isNull);
      expect(app.adsbInterval, const Duration(seconds: 60));
      // No position: nothing to ask.
      (app.location as PolicyLocation).fix = null;
      expect(app.adsbInterval, isNull);
      app.dispose();
    });

    test('demo drones make it 10 s', () async {
      final app = AppController(
        db: AppDatabase(NativeDatabase.memory()),
        ble: BleService(transport: FakeTransport()),
        location: PolicyLocation(),
        startTimers: false,
      );
      await app.start();
      await app.setDemo(true);
      await Future<void>.delayed(const Duration(milliseconds: 2300)); // the simulator's first frames
      app.tick();
      expect(app.tracker.contacts, isNotEmpty);
      expect(app.adsbInterval, const Duration(seconds: 10));
      app.dispose();
    });
  });

  group('lifecycle', () {
    late DutyBackend backend;
    late RecordingWifi wifi;
    late NativeRxService rx;
    late PolicyLocation loc;
    late AppController app;

    setUp(() async {
      backend = DutyBackend();
      wifi = RecordingWifi();
      final coord = BleScanCoordinator(backend, sleep: (_) async {});
      final decoder = NativeRidDecoder();
      rx = NativeRxService(
        coordinator: coord,
        ble: BleRidScanner(coord, decoder: decoder),
        wifi: WifiRidAndroid(platform: wifi, isAndroid: true, decoder: decoder),
        decoder: decoder,
        isAndroid: true,
        isIOS: false,
      );
      loc = PolicyLocation();
      app = AppController(
        db: AppDatabase(NativeDatabase.memory()),
        ble: BleService(transport: FakeTransport()),
        location: loc,
        nativeRx: rx,
        startTimers: false,
      );
      await app.start();
      await settle();
    });

    tearDown(() => app.dispose());

    test('Live in front: low latency scan, NAN and beacons every 60 s, high accuracy, compass 10 Hz', () async {
      expect(app.powerPolicy.mode, PowerMode.balanced);
      expect(backend.duties.last, ScanDuty.lowLatency);
      expect(wifi.calls.last, 'start nan:true beacon:true every:60000');
      expect(loc.configured.last, (LocationPrecision.high, 10));
      expect(rx.pathStates['ble'], 'running');
    });

    test('another tab, then the background, then back: each follows the policy', () async {
      app.setVisibility(tab: AppTab.detectors);
      await settle();
      expect(backend.duties.last, ScanDuty.balanced);
      expect(wifi.calls.last, 'start nan:false beacon:true every:60000');
      expect(loc.configured.last, (LocationPrecision.medium, 0));
      expect(rx.pathStates['nan'], 'paused');

      app.setVisibility(foreground: false);
      await settle();
      expect(app.powerPolicy.foreground, isFalse);
      expect(backend.duties.last, ScanDuty.lowPower);
      expect(wifi.calls.last, 'start nan:false beacon:true every:120000');
      expect(loc.configured.last, (LocationPrecision.medium, 0));

      app.setVisibility(foreground: true, tab: AppTab.live);
      await settle();
      expect(backend.duties.last, ScanDuty.lowLatency);
      expect(wifi.calls.last, 'start nan:true beacon:true every:60000');
      expect(loc.configured.last, (LocationPrecision.high, 10));
    });

    test('Saver in the background: the phone stops listening, and starts again in front', () async {
      await app.setPowerMode(PowerMode.saver);
      app.setVisibility(foreground: false);
      await settle();
      expect(rx.pathStates['ble'], 'paused');
      expect(backend.on, isFalse);
      expect(wifi.calls.last, 'stop');
      app.setVisibility(foreground: true);
      await settle();
      expect(rx.pathStates['ble'], 'running');
      expect(backend.on, isTrue);
      expect(await app.db.getSetting('power_mode'), 'saver');
    });

    test('the power notifier fires once per real change', () async {
      var n = 0;
      app.power.addListener(() => n++);
      app.setVisibility(tab: AppTab.live); // no change
      app.setVisibility(tab: AppTab.find);
      app.setVisibility(tab: AppTab.find);
      expect(n, 1);
    });
  });

  test('the compass is published at most 10 times a second, and only for a turn of 2° or more', () {
    final loc = LocationService();
    var published = 0;
    loc.heading.addListener(() => published++);
    // 30 readings a second for 2 s, turning 1.5° each.
    for (var i = 0; i < 60; i++) {
      loc.onCompass((i * 1.5) % 360, 1000 + i * 33);
    }
    expect(published, inInclusiveRange(15, 20));
    // Holding still: nothing more.
    final before = published;
    for (var i = 0; i < 30; i++) {
      loc.onCompass(89.0, 4000 + i * 33);
    }
    expect(published - before, lessThanOrEqualTo(1));
    // A wobble under 2° within a second of a turn is not published.
    loc.onCompass(120, 6000);
    expect(loc.headingDeg, 120);
    loc.onCompass(121, 6200);
    loc.onCompass(121.5, 6400);
    expect(loc.headingDeg, 120);
    loc.dispose();
  });

  test('the ambient clock runs only while listened to, at its rate, and not while paused', () {
    final c = AmbientClock.instance;
    addTearDown(c.resetForTest);
    expect(c.running, isFalse);
    var ticks = 0;
    void l() => ticks++;
    c.addListener(l);
    expect(c.running, isTrue);
    c.paused = true;
    expect(c.running, isFalse);
    c.paused = false;
    c.hz = 0;
    expect(c.running, isFalse);
    c.hz = 24;
    expect(c.running, isTrue);
    c.removeListener(l);
    expect(c.running, isFalse);
    expect(ticks, 0);
  });

  group('watch in the background (Android)', () {
    late List<MethodCall> calls;
    late ClockApp app;
    late bool startOk; // what Android answers a start with
    const channel = MethodChannelWatch.channel;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      calls = [];
      startOk = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'start' => startOk,
          'associations' => <String>[],
          'companionSupported' => true,
          'associate' => true,
          _ => null,
        };
      });
      app = ClockApp(
        db: AppDatabase(NativeDatabase.memory()),
        ble: BleService(transport: FakeTransport()),
        location: PolicyLocation(),
        watch: WatchService(platform: MethodChannelWatch(), supported: true),
        startTimers: false,
      );
      await app.start();
    });

    tearDown(() {
      app.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });

    Future<void> fromNative(String action) async {
      final data = const StandardMethodCodec().encodeMethodCall(MethodCall('action', {'action': action}));
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(channel.name, data, (_) {});
      await settle();
    }

    test('off by default; on starts the service with its words; off stops it', () async {
      expect(app.settings.watchInBackground, isFalse);
      expect(calls.where((c) => c.method == 'start'), isEmpty);
      await app.setWatchInBackground(true);
      final start = calls.lastWhere((c) => c.method == 'start');
      expect((start.arguments as Map)['text'], 'Orecchino watching · no drones · conflict watch on · no detector');
      expect((start.arguments as Map)['location'], isFalse); // the fake location reports no status ok
      expect(app.watchRunning, isTrue);
      expect(await app.db.getSetting('watch_bg'), '1');
      await app.setWatchInBackground(false);
      expect(calls.last.method, 'stop');
      expect(app.watchRunning, isFalse);
    });

    test('it starts only while the app is on screen', () async {
      app.setVisibility(foreground: false);
      await app.setWatchInBackground(true);
      expect(calls.where((c) => c.method == 'start'), isEmpty);
      app.setVisibility(foreground: true);
      await settle();
      expect(calls.where((c) => c.method == 'start'), hasLength(1));
    });

    test('Pause 1 h mutes and rests the phone in the background; Stop holds until the app is opened', () async {
      await app.setWatchInBackground(true);
      app.setVisibility(foreground: false);
      await fromNative('pause');
      expect(app.watchPaused, isTrue);
      expect(app.policy.isMuted(app.nowMs()), isTrue);
      expect(app.powerPolicy.phoneScan, ScanDuty.off);
      expect((calls.lastWhere((c) => c.method == 'update').arguments as Map)['text'],
          startsWith('Orecchino paused until '));
      await fromNative('stop');
      expect(app.watchRunning, isFalse);
      // Opening the app ends the pause, and its mute, and starts watching again.
      app.setVisibility(foreground: true);
      await settle();
      expect(app.watchPaused, isFalse);
      expect(app.policy.isMuted(app.nowMs()), isFalse);
      expect(app.watchRunning, isTrue);
      expect(calls.where((c) => c.method == 'start'), hasLength(2));
    });

    test('a Mute 10 min of the person\'s own outlasts opening the app; only the pause\'s ends', () async {
      await app.setWatchInBackground(true);
      app.setVisibility(foreground: false);
      await fromNative('pause');
      // Muted by the pause; then the person mutes for 10 minutes on top
      // (a shorter mute than the pause's replaces it).
      app.muteAlerts();
      final theirs = app.policy.mutedUntilMs;
      app.setVisibility(foreground: true);
      await settle();
      expect(app.watchPaused, isFalse);
      expect(app.policy.mutedUntilMs, theirs);
      expect(app.policy.isMuted(app.nowMs()), isTrue);
    });

    test('a start Android refused is tried again in a while, while the app is on screen', () async {
      startOk = false;
      await app.setWatchInBackground(true);
      expect(app.watchRunning, isFalse);
      expect(app.watch!.error, 'Android did not start the background service');
      expect(calls.where((c) => c.method == 'start'), hasLength(1));
      // Not on every tick.
      app.tick();
      await settle();
      expect(calls.where((c) => c.method == 'start'), hasLength(1));
      // Nor in the background.
      startOk = true;
      app.skewMs = AppController.watchRetry.inMilliseconds + 1000;
      app.setVisibility(foreground: false);
      app.tick();
      await settle();
      expect(calls.where((c) => c.method == 'start'), hasLength(1));
      // On screen, once the retry is due: started.
      app.setVisibility(foreground: true);
      await settle();
      expect(calls.where((c) => c.method == 'start'), hasLength(2));
      expect(app.watchRunning, isTrue);
      expect(app.watch!.error, isNull);
      // Turning it on again asks at once, whatever the backoff.
      startOk = false;
      await app.setWatchInBackground(false);
      await app.setWatchInBackground(true);
      expect(calls.where((c) => c.method == 'start'), hasLength(3));
      expect(app.watchRunning, isFalse);
    });

    test('turning it on associates the pinned detectors with the app', () async {
      await app.db.upsertDetector(const DetectorsCompanion(
          id: Value('AA:BB:CC:DD:EE:FF'), name: Value('T5'), board: Value('t5'), bonded: Value(true)));
      await app.setWatchInBackground(true);
      final a = calls.firstWhere((c) => c.method == 'associate');
      expect((a.arguments as Map)['mac'], 'AA:BB:CC:DD:EE:FF');
      expect(app.companions, contains('AA:BB:CC:DD:EE:FF'));
    });
  });

  group('pending reconnect', () {
    test('a pending connect waits for the detector without a timeout, then verifies as usual', () async {
      final t = FakeTransport()..pendingConnect = true;
      final ble = BleService(transport: t);
      final f = ble.connect('A', pending: true);
      await settle();
      expect(ble.waitingFor, 'A');
      expect(ble.state, BleLinkState.idle); // the picker can still scan
      t.arrive('A', FakePeer('A'));
      final info = await f;
      expect(info, isNotNull);
      expect(ble.state, BleLinkState.ready);
      expect(ble.waitingFor, isNull);
      expect(t.pendingAsked, [true]);
      ble.dispose();
    });

    test('disconnect gives up a waiting connect', () async {
      final t = FakeTransport()..pendingConnect = true;
      final ble = BleService(transport: t);
      final f = ble.connect('A', pending: true);
      await settle();
      await ble.disconnect();
      expect(await f, isNull);
      expect(t.cancelled, ['A']);
      expect(ble.waitingFor, isNull);
      ble.dispose();
    });
  });

  group('frames a second on an idle Live screen', () {
    Future<double> framesPerSecond(WidgetTester tester, {required PowerMode mode, bool reduced = false}) async {
      tester.view.physicalSize = const Size(393, 852) * 3;
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.accessibilityFeaturesTestValue = FakeAccessibilityFeatures(disableAnimations: reduced);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      // The app's clock held at a quiet second of the demo's 360 s traffic
      // cycle (test/demo_traffic_test.dart): the demo aircraft pass on the
      // wall clock, and an alert's capsule breathes (a ticker: a frame on
      // every pump) for a few seconds when one appears, which would make
      // the count depend on the second the test runs at.
      final app = ClockApp(
        db: AppDatabase(NativeDatabase.memory()),
        ble: BleService(transport: FakeTransport()),
        location: PolicyLocation(),
        startTimers: false,
      )..fixedMs = (1790000000 - 1790000000 % 360 + 30) * 1000;
      await tester.runAsync(() async {
        await app.start();
        await app.setPowerMode(mode);
        await app.setDemo(true);
        await Future<void>.delayed(const Duration(milliseconds: 2300));
        // The simulator runs on real timers: stopped, so the count does not
        // depend on how fast this machine pumps (its drones stay listed).
        app.sim.stop();
      });
      app.tick();
      await tester.pumpWidget(OrecchinoMobileApp(app: app));
      expect(find.byType(GlassNavBar), findsOneWidget);
      // Settle (sheet, header measurement), then count the frames asked
      // for over 5 s of a simulated 120 Hz display.
      for (var i = 0; i < 240; i++) {
        await tester.pump(const Duration(microseconds: 8333));
      }
      var frames = 0;
      for (var i = 0; i < 600; i++) {
        if (i % 120 == 0) app.tick();
        if (tester.binding.hasScheduledFrame) frames++;
        await tester.pump(const Duration(microseconds: 8333));
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(() async => app.dispose());
      return frames / 5;
    }

    // The budgets are the ambient rate (24 Hz Balanced, 30 Hz Full) plus the
    // once-a-second update; a few frames of slack cover the wall-clock
    // things (contact ages, the tick's real time) that a loaded machine
    // shifts across the fake clock's frames. The display's 120 is far off.
    testWidgets('Balanced: about 24 a second, at most 33 (never the display\'s 120)', (tester) async {
      final fps = await framesPerSecond(tester, mode: PowerMode.balanced);
      expect(fps, lessThanOrEqualTo(33));
      expect(fps, greaterThan(0)); // the sweep still moves
    });

    testWidgets('Full: about 30 a second, at most 34', (tester) async {
      expect(await framesPerSecond(tester, mode: PowerMode.full), lessThanOrEqualTo(34));
    });

    testWidgets('Saver and Reduce Motion: none but the once-a-second update', (tester) async {
      expect(await framesPerSecond(tester, mode: PowerMode.saver), lessThanOrEqualTo(2));
      expect(await framesPerSecond(tester, mode: PowerMode.balanced, reduced: true), lessThanOrEqualTo(2));
    });
  });
}
