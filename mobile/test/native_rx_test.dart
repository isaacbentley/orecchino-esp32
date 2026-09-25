// native_rx_test.dart — the phone's own receiver plumbing with fakes: the
// shared scan coordinator (leases, union filters, Android's start limit,
// restart after the platform stops a scan), BleService scanning through it
// (CoordinatedBleTransport), the Bluetooth Remote ID scanner, the Android
// Wi-Fi plugin's Dart side, and NativeRxService on top.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orecchino_mobile/core/ble/ble_service.dart';
import 'package:orecchino_mobile/core/ble/ble_transport.dart';
import 'package:orecchino_mobile/core/native_rx/ble_rid_scanner.dart';
import 'package:orecchino_mobile/core/native_rx/ble_scan_coordinator.dart';
import 'package:orecchino_mobile/core/native_rx/native_rx_service.dart';
import 'package:orecchino_mobile/core/native_rx/rid_observation.dart';
import 'package:orecchino_mobile/core/native_rx/wifi_rid_android.dart';
import 'package:orecchino_mobile/core/odid/odid.dart';
import 'package:orecchino_mobile/core/power/power_policy.dart';
import 'package:orecchino_mobile/core/protocol/messages.dart';

import 'support/fakes.dart';

class FakeBackend implements BleScanBackend {
  final advertCtl = StreamController<BleAdvert>.broadcast(sync: true);
  final scanningCtl = StreamController<bool>.broadcast(sync: true);
  final adapterCtl = StreamController<bool>.broadcast(sync: true);
  final List<BleScanFilter> starts = [];
  final List<ScanDuty> duties = [];
  int stops = 0;
  bool on = false;
  Error? failStart;
  BlePhyCaps caps = BlePhyCaps.unknown;

  @override
  Stream<BleAdvert> get adverts => advertCtl.stream;
  @override
  Stream<bool> get scanning => scanningCtl.stream;
  @override
  bool get isScanningNow => on;
  @override
  Stream<bool> get adapterOn => adapterCtl.stream;

  @override
  Future<void> start(BleScanFilter filter, {ScanDuty duty = ScanDuty.lowLatency}) async {
    if (failStart != null) throw failStart!;
    starts.add(filter);
    duties.add(duty);
    on = true;
    scanningCtl.add(true);
  }

  @override
  Future<void> stop() async {
    stops++;
    on = false;
    scanningCtl.add(false);
  }

  /// The platform stops the scan by itself.
  void platformStop() {
    on = false;
    scanningCtl.add(false);
  }

  @override
  Future<BlePhyCaps> phyCaps() async => caps;

  void advert(BleAdvert a) => advertCtl.add(a);

  Future<void> close() async {
    await advertCtl.close();
    await scanningCtl.close();
    await adapterCtl.close();
  }
}

class FakeWifiPlatform implements WifiRidPlatform {
  final events_ = StreamController<Map<Object?, Object?>>.broadcast(sync: true);
  Map<String, Object?> caps = const {};
  Map<String, Object?> startResult = const {'nan': 'started', 'beacon': 'started'};
  final List<String> calls = [];
  bool missing = false;

  @override
  Future<Map<String, Object?>> capabilities() async {
    calls.add('capabilities');
    if (missing) throw MissingPluginException();
    return caps;
  }

  @override
  Future<Map<String, Object?>> requestPermissions() async {
    calls.add('requestPermissions');
    return {'android.permission.NEARBY_WIFI_DEVICES': true};
  }

  @override
  Future<Map<String, Object?>> start({required bool nan, required bool beacon, required int beaconIntervalMs}) async {
    calls.add('start nan=$nan beacon=$beacon every=$beaconIntervalMs');
    return startResult;
  }

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Stream<Map<Object?, Object?>> get events => events_.stream;

  Future<void> close() => events_.close();
}

final nus = BleUuids.nusService.toLowerCase();
final t0 = DateTime(2026, 9, 23, 12);

OdidTxState drone([String id = 'PHONE-RX-1']) => OdidTxState(
      uasId: id,
      protoVer: 2,
      uaType: 2,
      status: 2,
      lat: 37.8,
      lon: -122.4,
      altGeoM: 120,
      heightM: 60,
      speedMs: 7,
      dirDeg: 45,
      opId: 'OP-1',
      selfDesc: 'survey',
    );

BleAdvert ridAdvert(List<int> payload, {String id = 'AA:BB:CC:00:00:01', int counter = 1, int rssi = -70, DateTime? at}) =>
    BleAdvert(id: id, rssi: rssi, at: at ?? t0, serviceData: {odidBleUuid128: [odidAppCode, counter, ...payload]});

Future<void> pump() => Future<void>.delayed(Duration.zero);

void main() {
  group('BleScanCoordinator', () {
    test('one scan with the union; covered leases change nothing; the last lease stops it', () async {
      final b = FakeBackend();
      final c = BleScanCoordinator(b);
      final rid = await c.acquire('remote-id', BleScanFilter.remoteId);
      expect(b.starts.length, 1);
      // Not covered: restart once with the union.
      final picker = await c.acquire('detector-picker', BleScanFilter.detector);
      expect(b.starts.length, 2);
      expect(b.starts.last, BleScanFilter.detectorAndRid);
      // Leaving never narrows the scan.
      await picker.release();
      expect(b.starts.length, 2);
      expect(b.stops, 0);
      // Covered: nothing.
      final again = await c.acquire('detector-picker', BleScanFilter.detector);
      expect(b.starts.length, 2);
      await again.release();
      await rid.release();
      await rid.release(); // idempotent
      expect(b.stops, 1);
      expect(c.scanning, isFalse);
      c.dispose();
    });

    test('with detectorAndRid from the start, the picker never restarts the Remote ID scan', () async {
      final b = FakeBackend();
      final c = BleScanCoordinator(b);
      await c.acquire('remote-id', BleScanFilter.detectorAndRid);
      for (var i = 0; i < 10; i++) {
        final p = await c.acquire('detector-picker', BleScanFilter.detectorAndRid);
        await p.release();
      }
      expect(b.starts.length, 1);
      expect(b.stops, 0);
      c.dispose();
    });

    test('Android start limit: the sixth start in 30 s waits for the window', () async {
      final b = FakeBackend();
      var now = t0;
      final slept = <Duration>[];
      final c = BleScanCoordinator(b, now: () => now, sleep: (d) async {
        slept.add(d);
        now = now.add(d);
      });
      for (var i = 0; i < 6; i++) {
        final l = await c.acquire('x', BleScanFilter(serviceData: ['fff$i']));
        await l.release();
        now = now.add(const Duration(seconds: 1));
      }
      expect(b.starts.length, 6);
      expect(slept, [const Duration(seconds: 25)]);
      c.dispose();
    });

    test('a scan the platform stops is restarted while a lease holds it', () async {
      final b = FakeBackend();
      final c = BleScanCoordinator(b, retryMin: const Duration(milliseconds: 5));
      await c.acquire('remote-id', BleScanFilter.remoteId);
      b.platformStop();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(b.starts.length, 2);
      expect(b.on, isTrue);
      // The stop half of our own restart (still scanning when looked at) is not a stop.
      b.scanningCtl.add(false);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(b.starts.length, 2);
      c.dispose();
    });

    test('Bluetooth turning on restarts a held scan at once, not after the backoff', () async {
      final b = FakeBackend();
      final c = BleScanCoordinator(b, retryMin: const Duration(seconds: 10));
      await c.acquire('remote-id', BleScanFilter.remoteId);
      // Bluetooth goes off: the platform stops the scan; the retry is 10 s away.
      b.failStart = StateError('Bluetooth is off');
      b.platformStop();
      b.adapterCtl.add(false);
      await pump();
      expect(b.starts.length, 1);
      // Back on: started now.
      b.failStart = null;
      b.adapterCtl.add(true);
      await pump();
      await pump();
      expect(b.starts.length, 2);
      expect(c.scanning, isTrue);
      // On again while the scan runs: nothing to do.
      b.adapterCtl.add(true);
      await pump();
      expect(b.starts.length, 2);
      c.dispose();
    });

    test('a scan that cannot start: acquire throws and holds nothing', () async {
      final b = FakeBackend()..failStart = StateError('Bluetooth is off');
      final c = BleScanCoordinator(b);
      await expectLater(c.acquire('remote-id', BleScanFilter.remoteId), throwsStateError);
      expect(c.owners, isEmpty);
      expect(c.error, contains('Bluetooth is off'));
      b.failStart = null;
      await c.acquire('remote-id', BleScanFilter.remoteId);
      expect(c.scanning, isTrue);
      c.dispose();
    });

    test('filters match service UUIDs, service data and manufacturer IDs in any spelling', () {
      final f = BleScanFilter.detectorAndRid;
      expect(f.matches(BleAdvert(id: 'a', rssi: 0, at: t0, serviceUuids: [nus.toUpperCase()])), isTrue);
      expect(f.matches(BleAdvert(id: 'a', rssi: 0, at: t0, serviceData: const {'fffa': [1]})), isTrue);
      expect(f.matches(BleAdvert(id: 'a', rssi: 0, at: t0, manufacturerData: const {0x0200: [1]})), isTrue);
      expect(f.matches(BleAdvert(id: 'a', rssi: 0, at: t0, manufacturerData: const {0x004C: [1]})), isFalse);
    });
  });

  group('BleService through CoordinatedBleTransport', () {
    test('the picker sees detectors only, and connecting leaves the Remote ID scan running', () async {
      final b = FakeBackend();
      final c = BleScanCoordinator(b);
      final inner = FakeTransport()..peers['D1'] = FakePeer('D1');
      final ble = BleService(transport: CoordinatedBleTransport(c, inner: inner));
      final scanner = BleRidScanner(c);
      await scanner.start();
      expect(b.starts.length, 1);

      await ble.startScan();
      expect(b.starts.length, 1, reason: 'the picker lease is covered by the Remote ID scan');
      b.advert(BleAdvert(id: 'D1', name: 'Orecchino T5', rssi: -50, at: t0, serviceUuids: [nus]));
      b.advert(ridAdvert(OdidEncoder.basicId(drone())));
      await pump();
      expect(ble.scanHits.map((h) => h.id), ['D1']);

      final info = await ble.connect('D1');
      expect(info, isNotNull);
      expect(ble.state, BleLinkState.ready);
      expect(inner.connects, 1);
      expect(c.owners, ['remote-id']);
      expect(b.stops, 0);
      expect(scanner.running, isTrue);

      ble.dispose();
      await scanner.dispose();
      c.dispose();
    });

    test('the picker lease ends by itself after its timeout', () async {
      final b = FakeBackend();
      final c = BleScanCoordinator(b);
      final t = CoordinatedBleTransport(c, inner: FakeTransport());
      await t.startScan(timeout: const Duration(milliseconds: 10));
      expect(c.owners, ['detector-picker']);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(c.owners, isEmpty);
      expect(b.stops, 1);
      c.dispose();
    });
  });

  group('BleRidScanner', () {
    late FakeBackend b;
    late BleScanCoordinator c;
    late BleRidScanner s;
    late List<RidObservation> seen;
    late StreamSubscription<RidObservation> sub;

    setUp(() async {
      b = FakeBackend();
      c = BleScanCoordinator(b);
      s = BleRidScanner(c);
      seen = [];
      sub = s.observations.listen(seen.add);
      await s.start();
    });

    tearDown(() async {
      await sub.cancel();
      await s.dispose();
      c.dispose();
    });

    test('a legacy single message is phone-ble4 on 1M; a pack is phone-ble5', () async {
      final st = drone();
      b.advert(ridAdvert(OdidEncoder.location(st), counter: 5, rssi: -61));
      b.advert(ridAdvert(OdidEncoder.pack(st, 1000), counter: 6, at: t0.add(const Duration(milliseconds: 100))));
      await pump();
      expect(seen.length, 2);
      expect(seen[0].source, NativeRidSource.ble4);
      expect(seen[0].message.src, 'phone-ble4');
      expect(seen[0].message.phy, '1m');
      expect(seen[0].rssi, -61);
      expect(seen[0].counter, 5);
      expect(seen[0].mac, 'AA:BB:CC:00:00:01');
      expect(seen[0].message.loc!.lat, 37.8);
      expect(seen[0].at, t0);
      expect(seen[1].source, NativeRidSource.ble5);
      expect(seen[1].message.phy, isNull);
      expect(seen[1].uasId, 'PHONE-RX-1');
      expect(seen[1].message.operatorId!.opId, 'OP-1');
    });

    test('a known PHY or legacy flag decides the source', () {
      final f = OdidFrame(0, OdidEncoder.basicId(drone()));
      BleAdvert a({String? phy, bool? legacy}) => BleAdvert(id: 'x', rssi: 0, at: t0, phy: phy, legacy: legacy);
      expect(BleRidScanner.sourceOf(a(phy: 'coded'), f), NativeRidSource.coded);
      expect(BleRidScanner.sourceOf(a(legacy: false), f), NativeRidSource.ble5);
      expect(BleRidScanner.sourceOf(a(legacy: true), f), NativeRidSource.ble4);
      expect(BleRidScanner.sourceOf(a(), f), NativeRidSource.ble4);
    });

    test('the draft manufacturer layout; not-ODID and undecodable adverts are skipped', () async {
      final msg = OdidEncoder.basicId(drone('MFG-1'));
      b.advert(BleAdvert(id: 'm', rssi: -80, at: t0, manufacturerData: {0x0200: [0x0D, 1, ...msg]}));
      b.advert(BleAdvert(id: 'n', rssi: -80, at: t0, serviceUuids: [nus]));
      b.advert(ridAdvert(List<int>.filled(25, 0x70))); // message type 7: nothing decodes
      await pump();
      expect(seen.map((o) => o.uasId), ['MFG-1']);
      expect(s.decodeFailures, 1);
      expect(s.framesDecoded, 1);
    });

    test('a repeat within a second is marked, not dropped', () async {
      final loc = OdidEncoder.location(drone());
      b.advert(ridAdvert(loc, at: t0));
      b.advert(ridAdvert(loc, at: t0.add(const Duration(milliseconds: 300))));
      b.advert(ridAdvert(loc, at: t0.add(const Duration(milliseconds: 1400))));
      await pump();
      expect(seen.map((o) => o.fresh), [true, false, true]);
    });

    test('stop releases the lease and stops the scan', () async {
      await s.stop();
      expect(s.running, isFalse);
      expect(b.stops, 1);
    });
  });

  group('WifiRidAndroid', () {
    test('iOS: unsupported, and the channel is never called', () async {
      final p = FakeWifiPlatform();
      final w = WifiRidAndroid(platform: p, isAndroid: false);
      final caps = await w.capabilities();
      expect(caps.platformSupported, isFalse);
      expect(await w.start(), {'nan': 'unsupported: iOS', 'beacon': 'unsupported: iOS'});
      await w.stop();
      expect(p.calls, isEmpty);
      await w.dispose();
    });

    test('a missing plugin reads as unsupported', () async {
      final w = WifiRidAndroid(platform: FakeWifiPlatform()..missing = true, isAndroid: true);
      expect((await w.capabilities()).platformSupported, isFalse);
      await w.dispose();
    });

    test('capabilities from the plugin', () async {
      final p = FakeWifiPlatform()
        ..caps = {
          'sdk': 34,
          'awareFeature': true,
          'awareAvailable': false,
          'beaconIe': true,
          'beaconIntervalMs': 30000,
          'nearbyWifiPermission': true,
          'fineLocationPermission': false,
          'leCodedPhy': true,
          'leExtendedAdvertising': true,
          'leMaxAdvDataLength': 1650,
        };
      final caps = await WifiRidAndroid(platform: p, isAndroid: true).capabilities();
      expect(caps.sdk, 34);
      expect(caps.awareSupported && !caps.awareAvailable && caps.beaconElements, isTrue);
      expect(caps.fineLocationPermission, isFalse);
      expect(caps.leCodedPhy, isTrue);
      expect(caps.leMaxAdvertisingDataLength, 1650);
    });

    test('NAN and beacon events become observations; stale, broken and foreign ones do not', () async {
      final p = FakeWifiPlatform();
      final now = t0;
      final w = WifiRidAndroid(platform: p, isAndroid: true, now: () => now);
      final seen = <RidObservation>[];
      final statuses = <WifiRidStatus>[];
      final s1 = w.observations.listen(seen.add);
      final s2 = w.status.listen(statuses.add);
      expect(await w.start(), {'nan': 'started', 'beacon': 'started'});
      expect(p.calls.last, 'start nan=true beacon=true every=30000');

      final pack = OdidEncoder.pack(drone('NAN-1'), 0);
      p.events_.add({'kind': 'nan', 'data': Uint8List.fromList([9, ...pack]), 'peer': 5, 'ts': now.millisecondsSinceEpoch});
      final ie = Uint8List.fromList([0xFA, 0x0B, 0xBC, 0x0D, 3, ...OdidEncoder.pack(drone('BCN-1'), 0)]);
      p.events_.add({
        'kind': 'beacon',
        'ie': ie,
        'bssid': 'aa:bb:cc:dd:ee:ff',
        'ssid': 'RID-BCN-1',
        'rssi': -77,
        'freq': 2437,
        'ts': now.subtract(const Duration(seconds: 4)).millisecondsSinceEpoch,
      });
      // Too old, not ODID, not bytes.
      p.events_.add({'kind': 'beacon', 'ie': ie, 'bssid': 'x', 'ts': now.subtract(const Duration(minutes: 2)).millisecondsSinceEpoch});
      p.events_.add({'kind': 'beacon', 'ie': Uint8List.fromList([0, 1, 2, 3, 4]), 'bssid': 'x', 'ts': now.millisecondsSinceEpoch});
      p.events_.add({'kind': 'nan', 'data': 'nope'});
      p.events_.add({'kind': 'status', 'path': 'nan', 'state': 'unavailable', 'message': 'Wi-Fi off'});
      await pump();

      expect(seen.length, 2);
      final nan = seen[0], bcn = seen[1];
      expect(nan.source, NativeRidSource.nan);
      expect(nan.message.src, 'phone-nan');
      expect(nan.mac, 'nan-5');
      expect(nan.rssi, isNull);
      expect(nan.counter, 9);
      expect(nan.uasId, 'NAN-1');
      expect(bcn.source, NativeRidSource.beacon);
      expect(bcn.slow, isTrue);
      expect(bcn.mac, 'AA:BB:CC:DD:EE:FF');
      expect(bcn.message.channel, 6);
      expect(bcn.message.ssid, 'RID-BCN-1');
      expect(bcn.message.ssidIdMatch, isNull, reason: 'RID-BCN-1 is not alphanumeric after RID-: no verdict');
      expect(bcn.at, now.subtract(const Duration(seconds: 4)));
      expect(w.dropped, 3);
      expect(statuses.single.toString(), 'nan: unavailable (Wi-Fi off)');
      expect(w.pathStates['nan'], 'unavailable');

      await w.stop();
      expect(p.calls.last, 'stop');
      await s1.cancel();
      await s2.cancel();
      await w.dispose();
    });

    test('frequencies to channels', () {
      expect(wifiChannel(2412), 1);
      expect(wifiChannel(2437), 6);
      expect(wifiChannel(2484), 14);
      expect(wifiChannel(5745), 149);
      expect(wifiChannel(5975), 5);
      expect(wifiChannel(null), isNull);
      expect(wifiChannel(900), isNull);
    });
  });

  group('NativeRxService', () {
    NativeRxService build({required bool android, FakeBackend? backend, FakeWifiPlatform? wifi}) {
      final b = backend ?? FakeBackend();
      final c = BleScanCoordinator(b);
      final d = NativeRidDecoder();
      return NativeRxService(
        coordinator: c,
        ble: BleRidScanner(c, decoder: d),
        wifi: WifiRidAndroid(platform: wifi ?? FakeWifiPlatform(), isAndroid: android, decoder: d),
        decoder: d,
        isAndroid: android,
        isIOS: !android,
      );
    }

    test('Android capabilities', () async {
      final p = FakeWifiPlatform()
        ..caps = {'sdk': 34, 'awareFeature': true, 'awareAvailable': true, 'beaconIe': true, 'beaconIntervalMs': 30000, 'leCodedPhy': true, 'leExtendedAdvertising': true};
      final svc = build(android: true, wifi: p);
      final caps = await svc.refreshCapabilities();
      expect(caps.summary, 'BLE4 yes, BLE5 extended: yes, BLE5 coded: yes, NAN: yes, Wi-Fi beacon: slow (30 s)');
      expect(svc.capabilities, same(caps));
      svc.dispose();
    });

    test('Android without Aware, on Android 10, falling back to flutter_blue_plus for the PHY', () async {
      final p = FakeWifiPlatform()..caps = {'sdk': 29, 'awareFeature': false, 'beaconIe': false};
      final b = FakeBackend()..caps = const BlePhyCaps(le2M: true, leCoded: false);
      final caps = await build(android: true, wifi: p, backend: b).refreshCapabilities();
      expect(caps.summary, 'BLE4 yes, BLE5 extended: yes, BLE5 coded: no, NAN: no, Wi-Fi beacon: no');
      expect(caps.nanReason, 'no Wi-Fi Aware on this phone');
      expect(caps.beaconReason, 'needs Android 11 or later');
    });

    test('iOS capabilities', () async {
      final caps = await build(android: false).refreshCapabilities();
      expect(caps.summary, 'BLE4 yes, BLE5 extended: unknown, BLE5 coded: no, NAN: no, Wi-Fi beacon: no (foreground only)');
      expect(caps.foregroundOnly, isTrue);
    });

    test('start merges every path into one stream of fresh rid lines; stop ends them', () async {
      final b = FakeBackend();
      final p = FakeWifiPlatform();
      final svc = build(android: true, backend: b, wifi: p);
      final msgs = <RidMessage>[];
      final all = <RidObservation>[];
      final s1 = svc.messages.listen(msgs.add);
      final s2 = svc.observations.listen(all.add);
      await svc.start();
      expect(svc.pathStates, {'ble': 'running', 'nan': 'started', 'beacon': 'started'});

      final loc = OdidEncoder.location(drone());
      b.advert(ridAdvert(loc));
      b.advert(ridAdvert(loc, at: t0.add(const Duration(milliseconds: 200)))); // a repeat
      p.events_.add({'kind': 'nan', 'data': Uint8List.fromList([1, ...OdidEncoder.pack(drone('NAN-2'), 0)]), 'peer': 1, 'ts': DateTime.now().millisecondsSinceEpoch});
      await pump();
      await pump();
      expect(all.length, 3);
      expect(msgs.map((m) => m.src), ['phone-ble4', 'phone-nan']);

      await svc.stop();
      expect(svc.running, isFalse);
      expect(b.stops, 1);
      expect(p.calls.last, 'stop');
      expect(svc.pathStates.values.toSet(), {'off'});
      await s1.cancel();
      await s2.cancel();
      svc.dispose();
    });

    test('Bluetooth failing to start does not stop Wi-Fi', () async {
      final b = FakeBackend()..failStart = StateError('Bluetooth is off');
      final svc = build(android: true, backend: b);
      await svc.start(beacon: false);
      expect(svc.pathStates['ble'], contains('Bluetooth is off'));
      expect(svc.pathStates['nan'], 'started');
      expect(svc.pathStates['beacon'], 'off');
      await svc.stop();
      svc.dispose();
    });

    test('started with Bluetooth off, the Bluetooth path starts by itself when it is turned on', () async {
      final b = FakeBackend()..failStart = StateError('Bluetooth is off');
      final svc = build(android: true, backend: b);
      await svc.start(nan: false, beacon: false);
      expect(svc.pathStates['ble'], contains('Bluetooth is off'));
      expect(b.starts, isEmpty);
      // Still off: another try fails the same way, and no scan holds.
      b.adapterCtl.add(true);
      await pump();
      await pump();
      expect(b.starts, isEmpty);
      expect(svc.pathStates['ble'], contains('Bluetooth is off'));
      // On: the receiver's scan starts, no policy change or restart needed.
      b.failStart = null;
      b.adapterCtl.add(true);
      await pump();
      await pump();
      expect(svc.pathStates['ble'], 'running');
      expect(b.starts.length, 1);
      // Once running, the adapter's events do nothing more.
      b.adapterCtl.add(true);
      await pump();
      expect(b.starts.length, 1);
      await svc.stop();
      // Stopped: turning Bluetooth on starts nothing.
      b.adapterCtl.add(true);
      await pump();
      expect(b.starts.length, 1);
      svc.dispose();
    });
  });
}
