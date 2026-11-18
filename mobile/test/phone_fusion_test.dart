// phone_fusion_test.dart — the phone as a detector: one track per drone
// across the phone and the detectors (by UAS ID; iOS gives a peripheral
// UUID, not a MAC), a sensor chip per sensor that heard it (fresh, greyed
// with age, gone after a minute), the phone's "unverified" never replacing
// a detector's verdict, the phone's own History records (no detector cursor
// touched), and the setting that stops the phone's scan.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orecchino_mobile/app/app_controller.dart';
import 'package:orecchino_mobile/core/ble/ble_service.dart';
import 'package:orecchino_mobile/core/live/contact_tracker.dart';
import 'package:orecchino_mobile/core/live/phone_history.dart';
import 'package:orecchino_mobile/core/live/sensors.dart';
import 'package:orecchino_mobile/core/location/location_service.dart';
import 'package:orecchino_mobile/core/native_rx/ble_rid_scanner.dart';
import 'package:orecchino_mobile/core/native_rx/ble_scan_coordinator.dart';
import 'package:orecchino_mobile/core/native_rx/native_rx_service.dart';
import 'package:orecchino_mobile/core/native_rx/rid_observation.dart';
import 'package:orecchino_mobile/core/native_rx/wifi_rid_android.dart';
import 'package:orecchino_mobile/core/power/power_policy.dart';
import 'package:orecchino_mobile/core/protocol/messages.dart';
import 'package:orecchino_mobile/data/db.dart';
import 'package:orecchino_mobile/features/live/live_items.dart';

import 'support/fakes.dart';

RidMessage rid(Map<String, dynamic> j) => HostMessage.parse(jsonEncode({'type': 'rid', ...j}))! as RidMessage;

const uas = '1581F6Z9C7B3F4E1';
Map<String, dynamic> basic([String id = uas]) => {
      'basic_id': [
        {'id_type': 1, 'ua_type': 2, 'uas_id': id}
      ]
    };
Map<String, dynamic> loc(double lat) => {
      'loc': {'status': 2, 'lat': lat, 'lon': -122.46, 'alt_geo': 90.0, 'height': 80.0, 'height_ref': 0}
    };

class NoLocation extends LocationService {
  @override
  Future<void> start() async {}
}

/// A Bluetooth scan that only records whether it runs.
// ignore: close_sinks
class FakeBackend implements BleScanBackend {
  // ignore: close_sinks
  final _adverts = StreamController<BleAdvert>.broadcast(sync: true);
  // ignore: close_sinks
  final _scanning = StreamController<bool>.broadcast(sync: true);
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

class NoWifi implements WifiRidPlatform {
  @override
  Future<Map<String, Object?>> capabilities() async => const {};
  @override
  Future<Map<String, Object?>> requestPermissions() async => const {};
  @override
  Future<Map<String, Object?>> start({required bool nan, required bool beacon, required int beaconIntervalMs}) async =>
      const {};
  @override
  Future<void> stop() async {}
  @override
  Stream<Map<Object?, Object?>> get events => const Stream.empty();
}

void main() {
  const t0 = 1790000000000;
  const obs = ObserverFix(37.80, -122.46);

  group('fusion', () {
    test('one drone heard by a detector and by the phone (iOS: a UUID, no MAC) is one track, two chips', () {
      final t = ContactTracker();
      t.ingest(rid({'src': 'ble', 'phy': 'coded', 'mac': 'C1:22:33:44:55:66', 'rssi': -91, ...basic(), ...loc(37.82)}),
          t0, obs,
          detector: 'T5');
      const iosUuid = '6F1D2C3B-0A9E-4E3F-8B7A-1C2D3E4F5A6B';
      t.ingest(rid({'src': 'phone-ble4', 'mac': iosUuid, 'rssi': -79, ...basic(), ...loc(37.821)}), t0 + 500, obs);
      // A later Location-only frame from the same UUID joins the same track.
      t.ingest(rid({'src': 'phone-ble4', 'mac': iosUuid, 'rssi': -77, ...loc(37.822)}), t0 + 1000, obs);
      expect(t.length, 1);
      final c = t[uas]!;
      expect(c.lat, 37.822); // the freshest position wins
      expect(c.heardBy.length, 2);
      final chips = sensorChips(c, t0 + 1000);
      expect(chips.map((s) => s.label), ['📱 BLE4', 'T5 · BLE LR']);
      expect(chips.first.rssi, -77);
      expect(chips.last.rssi, -91);
      expect(sensorWords(chips), 'heard by this phone over Bluetooth 4 and by T5 over Bluetooth long range');
    });

    test('a phone contact first heard without its ID joins the detector\'s track when the ID arrives', () {
      final t = ContactTracker();
      t.ingest(rid({'src': 'ble', 'mac': 'C1:22:33:44:55:66', ...basic(), ...loc(37.82)}), t0, obs, detector: 'T5');
      const iosUuid = '6F1D2C3B-0A9E-4E3F-8B7A-1C2D3E4F5A6B';
      // The phone hears a Location before any Basic ID: a UUID-keyed contact...
      t.ingest(rid({'src': 'phone-ble4', 'mac': iosUuid, 'rssi': -80, ...loc(37.821)}), t0 + 200, obs);
      expect(t.length, 2);
      // ...until its Basic ID names the drone the detector already tracks.
      t.ingest(rid({'src': 'phone-ble4', 'mac': iosUuid, 'rssi': -78, ...basic()}), t0 + 700, obs);
      expect(t.length, 1);
      final c = t[uas]!;
      expect(c.macs, containsAll(['C1:22:33:44:55:66', iosUuid]));
      expect(c.heardBy.length, 2);
      expect(c.firstSeenMs, t0);
      expect(c.msgCount, 3);
      t.ingest(rid({'src': 'phone-ble4', 'mac': iosUuid, ...loc(37.823)}), t0 + 1200, obs);
      expect(t.length, 1);
      expect(t[uas]!.lat, 37.823);
    });

    test('a phone-only transmitter with no ID is its own track, keyed by what the phone saw', () {
      final t = ContactTracker();
      t.ingest(rid({'src': 'phone-ble5', 'mac': 'UUID-ONLY', ...loc(37.83)}), t0, obs);
      t.ingest(rid({'src': 'ble', 'mac': 'AA:AA:AA:AA:AA:AA', ...basic('OTHER-ID'), ...loc(37.84)}), t0, obs,
          detector: 'T5');
      expect(t.length, 2);
      expect(t['UUID-ONLY']!.heardByPhone, isTrue);
      expect(t['OTHER-ID']!.heardByPhone, isFalse);
    });

    test('the phone\'s "unverified" never replaces a detector\'s verdict (a detector\'s replaces the phone\'s)', () {
      final t = ContactTracker();
      Map<String, dynamic> auth(String s) => {
            'auth': {'type': 1, 'len': 64, 'pages': 4, 'state': s}
          };
      t.ingest(rid({'src': 'ble', 'mac': 'M1', ...basic(), ...auth('id_valid')}), t0, obs, detector: 'T5');
      t.ingest(rid({'src': 'phone-ble4', 'mac': 'U1', ...basic(), ...auth('unverified')}), t0 + 100, obs);
      expect(t[uas]!.authState, 'id_valid');
      final t2 = ContactTracker();
      t2.ingest(rid({'src': 'phone-ble4', 'mac': 'U1', ...basic(), ...auth('unverified')}), t0, obs);
      expect(t2[uas]!.authState, 'unverified');
      t2.ingest(rid({'src': 'wifi', 'mac': 'M1', ...basic(), ...auth('invalid')}), t0 + 100, obs, detector: 'T5');
      expect(t2[uas]!.authState, 'invalid');
    });

    test('chips: fresh for 10 s, then greyed with their age, gone after 60 s', () {
      final t = ContactTracker();
      t.ingest(rid({'src': 'phone-nan', 'mac': 'nan-7', 'rssi': -70, ...basic()}), t0, obs);
      final c = t[uas]!;
      var chips = sensorChips(c, t0 + 5000);
      expect(chips.single.label, '📱 NAN');
      expect(chips.single.fresh, isTrue);
      t.ingest(rid({'src': 'wifi', 'mac': 'M1', 'rssi': -60, ...basic()}), t0 + 40000, obs, detector: 'T-Embed');
      chips = sensorChips(c, t0 + 45000);
      expect(chips.map((s) => s.label), ['📱 NAN · 45 s', 'T-Embed · Wi-Fi']);
      expect(chips.first.fresh, isFalse);
      chips = sensorChips(c, t0 + 61000);
      expect(chips.map((s) => s.label), ['T-Embed · Wi-Fi · 21 s']);
      expect(sensorChips(c, t0 + 101000), isEmpty);
    });

    test('names: the phone\'s paths and the detectors\' transports', () {
      final t = ContactTracker();
      for (final (src, det) in [
        ('phone-ble5', null),
        ('phone-coded', null),
        ('phone-beacon', null),
        ('nan', 'T-Embed'),
      ]) {
        t.ingest(rid({'src': src, 'mac': 'M-$src', ...basic()}), t0, obs, detector: det);
      }
      expect(sensorChips(t[uas]!, t0).map((s) => s.label),
          containsAll(['📱 BLE5', '📱 BLE5 LR', '📱 Wi-Fi (slow)', 'T-Embed · NAN']));
      expect(detectorShortName('Orecchino', 'lilygo-t5-epaper-s3-pro'), 'T5');
      expect(detectorShortName('Orecchino', 'lilygo-t-embed-cc1101'), 'T-Embed');
      expect(detectorShortName('My board', 'other'), 'My board');
    });
  });

  group('app', () {
    late AppController app;
    late FakeBackend backend;

    setUp(() async {
      backend = FakeBackend();
      final coord = BleScanCoordinator(backend);
      final decoder = NativeRidDecoder();
      final rx = NativeRxService(
        coordinator: coord,
        ble: BleRidScanner(coord, decoder: decoder),
        wifi: WifiRidAndroid(platform: NoWifi(), isAndroid: false, decoder: decoder),
        decoder: decoder,
        isAndroid: false,
        isIOS: true,
      );
      app = AppController(
        db: AppDatabase(NativeDatabase.memory()),
        ble: BleService(transport: CoordinatedBleTransport(coord, inner: FakeTransport())),
        nativeRx: rx,
        location: NoLocation(),
        startTimers: false,
      );
      await app.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    tearDown(() => app.dispose());

    test('on by default: the phone scans; the setting stops it, and its frames are then ignored', () async {
      expect(app.settings.phoneRx, isTrue);
      expect(app.nativeRx!.running, isTrue);
      expect(backend.on, isTrue);
      expect(app.nativeRx!.capabilities.foregroundOnly, isTrue); // iOS: while the app is open
      await app.setPhoneRx(false);
      expect(app.nativeRx!.running, isFalse);
      expect(backend.on, isFalse);
      app.ingestPhoneFrame(rid({'src': 'phone-ble4', 'mac': 'U1', ...basic(), ...loc(37.82)}));
      expect(app.tracker.length, 0);
      await app.setPhoneRx(true);
      expect(backend.on, isTrue);
      expect(await app.db.getSetting('phone_rx'), '1');
    });

    test('the phone\'s own History records: "This phone", live then ended; no detector cursor touched', () async {
      await app.db.upsertDetector(
          const DetectorsCompanion(id: Value('t5'), name: Value('T5'), bonded: Value(true), lastSyncSeq: Value(42)));
      app.ingestPhoneFrame(rid({'src': 'phone-ble4', 'mac': 'U1', 'rssi': -80, ...basic(), ...loc(37.82)}));
      app.ingestPhoneFrame(rid({'src': 'phone-ble5', 'mac': 'U1', 'rssi': -70, ...basic(), ...loc(37.821)}));
      final now = app.nowMs();
      await app.phoneHistory.flush(app.db, now);
      var rows = await app.db.getDetectionsList(detectorId: PhoneHistory.detectorId);
      expect(rows, hasLength(1));
      final r = rows.single;
      expect((r.uasId, r.active, r.peakRssi, r.msgs, r.srcs), (uas, true, -70, 2, 4));
      expect(r.lat, 37.821);
      final d = (await app.db.getDetector('phone'))!;
      expect((d.name, d.bonded), ('This phone', false));
      expect((await app.db.getDetector('t5'))!.lastSyncSeq, 42);
      expect((await app.db.pinnedDetectors()).map((d) => d.id), ['t5']);
      // A minute without a frame ends it.
      await app.phoneHistory.flush(app.db, now + 61000);
      rows = await app.db.getDetectionsList(detectorId: PhoneHistory.detectorId);
      expect(rows.single.active, isFalse);
      expect(app.phoneHistory.openSpells, 0);
      // The drone's item carries the phone's chips and words.
      final item = buildLiveItems(app).singleWhere((c) => c.isDrone);
      expect(item.sensors.map((s) => s.label), ['📱 BLE5', '📱 BLE4']);
      expect(item.semantics(), contains('heard by this phone over Bluetooth 5 and Bluetooth 4'));
    });
  });
}
