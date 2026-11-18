// drone_details_test.dart — the full drone details: every field a rid line
// carries is shown in words; anything not broadcast reads "not reported"
// (never a made-up value, never the firmware's unknown markers); History
// records say what the log keeps; the sheet lays out at 2x text with every
// row a screen-reader node; operators have their own words and marks.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orecchino_mobile/app/app_controller.dart';
import 'package:orecchino_mobile/core/ble/ble_service.dart';
import 'package:orecchino_mobile/core/live/contact_tracker.dart';
import 'package:orecchino_mobile/core/location/location_service.dart';
import 'package:orecchino_mobile/core/protocol/messages.dart';
import 'package:orecchino_mobile/core/sync/sync_engine.dart';
import 'package:orecchino_mobile/core/traffic/traffic_rules.dart';
import 'package:orecchino_mobile/data/db.dart';
import 'package:orecchino_mobile/features/details/drone_details.dart';
import 'package:orecchino_mobile/features/details/drone_details_sheet.dart';
import 'package:orecchino_mobile/features/history/history_view.dart';
import 'package:orecchino_mobile/features/live/live_items.dart';
import 'package:orecchino_mobile/ui/theme/theme.dart';

import 'support/fakes.dart';

const obs = ObserverFix(37.8039, -122.4640);

RidMessage rid(Map<String, dynamic> j) => HostMessage.parse(jsonEncode({'type': 'rid', ...j}))! as RidMessage;

/// Everything a receiver can say (accuracies, area and classification are
/// on the firmware's rid line since 0.7; see firmwareFull below).
final full = rid({
  'src': 'ble',
  'mac': 'E2:01:23:45:67:89',
  'rssi': -68,
  'phy': 'coded',
  'proto': 2,
  'basic_id': [
    {'id_type': 1, 'ua_type': 2, 'uas_id': '1581F6Z9ABCD1234'},
    {'id_type': 4, 'ua_type': 2, 'uas_id': 'SESSION-77'},
  ],
  'loc': {
    'status': 2,
    'lat': 37.8089123,
    'lon': -122.4640456,
    'alt_geo': 120.4,
    'alt_baro': 101.2,
    'height': 100.0,
    'height_ref': 0,
    'speed': 12.0,
    'dir': 107,
    'ts': 1234.5,
    'vspeed': 0.2,
    'h_acc': 11,
    'v_acc': 4,
    'baro_acc': 3,
    'spd_acc': 3,
    'ts_acc': 2,
  },
  'self_id': {'desc_type': 0, 'desc': 'Survey flight'},
  'system': {
    'op_lat': 37.8060,
    'op_lon': -122.4680,
    'op_alt': 21.5,
    'op_loc_type': 1,
    'area_count': 1,
    'area_radius': 200,
    'area_ceiling': 120.0,
    'area_floor': 0.0,
    'class_type': 1,
    'cat_eu': 1,
    'class_eu': 2,
    'ts': 212000000,
  },
  'op_id': {'id_type': 0, 'id': 'FIN87astrdge12k8'},
  'auth': {'type': 1, 'len': 90, 'pages': 5, 'state': 'id_valid'},
});

class FakeLocation extends LocationService {
  @override
  Future<void> start() async {}
  @override
  PhoneLocation? get currentLocation => const PhoneLocation(lat: 37.8039, lon: -122.464, timeMs: 0);
  @override
  double? get headingDeg => 0;
}

/// The firmware's own full line (tests/core_test.cpp test_rid_fields, as
/// format_rid prints it): accuracies, area, EU class, auth_ts, the TFR.
const firmwareFull = '{"type":"rid","src":"wifi","mac":"02:00:5E:7E:57:11","rssi":-40,"ch":6,"proto":2,'
    '"basic_id":[{"id_type":1,"ua_type":2,"uas_id":"ORECCHINO-TX-AUTH"}],'
    '"loc":{"status":2,"lat":37.8000000,"lon":-122.4000000,"alt_geo":80.0,"alt_baro":-1000.0,"height":60.0,'
    '"height_ref":0,"speed":5.00,"dir":90,"ts":0.0,"vspeed":0.00,"h_acc":11,"v_acc":4,"baro_acc":3,"spd_acc":2,'
    '"ts_acc":5},"self_id":{"desc_type":0,"desc":"TEST"},"system":{"op_lat":37.8000000,"op_lon":-122.4000000,'
    '"op_alt":10.0,"op_loc_type":1,"area_count":5,"ts":100,"area_radius":120,"area_ceiling":150.0,'
    '"area_floor":20.0,"class_type":1,"cat_eu":2,"class_eu":3},"op_id":{"id_type":0,"id":"OP"},'
    '"auth":{"type":1,"len":64,"pages":4,"auth_ts":100,"state":"test_key"},"in_tfr":true,"tfr_id":"TEST/1"}';

/// The same contact's live log record (format_log_rec), and the ended one
/// after it flew out of the TFR.
const firmwareLiveLog = '{"type":"log","seq":null,"i":null,"active":true,"uas":"ORECCHINO-TX-AUTH",'
    '"mac":"02:00:5E:7E:57:11","srcs":1,"fmts":1,"ua_type":2,"first":1790000700,"last":1790000700,"dur":0,'
    '"lat":37.80000,"lon":-122.40000,"max_h":60,"peak_rssi":-40,"auth_state":"test_key","tfr":true,'
    '"in_tfr":true,"tfr_id":"TEST/1","emerg":false,"class_type":1,"cat_eu":2,"class_eu":3,"msgs":1}';
const firmwareEndedLog = '{"type":"log","seq":5,"i":5,"active":false,"uas":"ORECCHINO-TX-AUTH",'
    '"mac":"02:00:5E:7E:57:11","srcs":1,"fmts":1,"ua_type":2,"first":1790000700,"last":1790000760,"dur":60,'
    '"lat":40.00000,"lon":-122.40000,"max_h":60,"peak_rssi":-40,"auth_state":"test_key","tfr":true,'
    '"in_tfr":false,"tfr_id":"TEST/1","emerg":false,"class_type":1,"cat_eu":2,"class_eu":3,"msgs":2}';

void main() {
  const now = 1790000000000;

  group('firmware 0.7 fields', () {
    test('the rid line: accuracies, area, EU class, auth time and the TFR, in words', () {
      final m = HostMessage.parse(firmwareFull)! as RidMessage;
      expect((m.loc!.hAcc, m.loc!.vAcc, m.loc!.baroAcc, m.loc!.spdAcc, m.loc!.tsAcc), (11, 4, 3, 2, 5));
      final s = m.system!;
      expect((s.areaCount, s.areaRadius, s.areaCeiling, s.areaFloor), (5, 120.0, 150.0, 20.0));
      expect((s.classType, s.catEu, s.classEu), (1, 2, 3));
      expect(m.auth!.authTs, 100);
      expect(m.auth!.signedAt, DateTime.utc(2019, 1, 1, 0, 1, 40));
      expect((m.inTfr, m.tfrId), (true, 'TEST/1'));

      final t = ContactTracker();
      t.ingest(m, now, obs, detector: 'T5');
      final c = t['ORECCHINO-TX-AUTH']!;
      final d = liveDroneDetails(c, nowMs: now, observer: obs);
      String? v(String sec, String l) => d.row(sec, l)?.value;
      expect(v('Identity', 'Classification'), 'EU · Specific · C2');
      expect(v('Position', 'Horizontal accuracy'), '< 3 m');
      expect(v('Position', 'Vertical accuracy'), '< 10 m');
      expect(v('Position', 'Pressure altitude accuracy'), '< 25 m');
      expect(v('Position', 'Speed accuracy'), '< 3 m/s');
      expect(v('Position', 'Time accuracy'), '< 0.5 s');
      expect(v('System', 'Area count'), '5');
      expect(v('System', 'Area radius'), '120 m');
      expect(v('System', 'Area ceiling'), '150.0 m');
      expect(v('System', 'Area floor'), '20.0 m');
      expect(v('Authentication', 'Signed at'), '2019-01-01 00:01:40 UTC');
      expect(v('Alerts', 'In a TFR'), 'IN TFR TEST/1');
      expect(d.row('Alerts', 'In a TFR')!.tone, DetailTone.caution);
      expect(d.alerts, contains('IN TFR TEST/1'));
      // A later line without the verdict (the phone, no TFRs) keeps it.
      t.ingest(rid({'src': 'phone-ble4', 'mac': 'U1', 'basic_id': [
        {'id_type': 1, 'ua_type': 2, 'uas_id': 'ORECCHINO-TX-AUTH'}
      ]}), now + 1000, obs);
      expect(c.inTfr, isTrue);
      // A detector that places it outside: no, and no TFR named.
      t.ingest(HostMessage.parse(firmwareFull.replaceFirst('"in_tfr":true,"tfr_id":"TEST/1"', '"in_tfr":false'))!
          as RidMessage, now + 2000, obs, detector: 'T5');
      expect((c.inTfr, c.tfrId), (false, null));
      expect(liveDroneDetails(c, nowMs: now + 2000).row('Alerts', 'In a TFR')!.value, 'No');
    });

    test('older lines: every new field absent is "not reported", never a guess', () {
      final c = ContactTracker()..ingest(rid({'src': 'ble', 'mac': 'A1', 'basic_id': [
        {'id_type': 1, 'ua_type': 2, 'uas_id': 'OLD-1'}
      ], 'auth': {'type': 1, 'len': 64, 'pages': 4, 'state': 'partial'}}), now, obs);
      final d = liveDroneDetails(c['OLD-1']!, nowMs: now);
      for (final (sec, l) in [
        ('Identity', 'Classification'),
        ('Position', 'Horizontal accuracy'),
        ('System', 'Area radius'),
        ('Authentication', 'Signed at'),
        ('Alerts', 'In a TFR'),
      ]) {
        expect(d.row(sec, l)!.shown, notReported, reason: '$sec / $l');
      }
      expect(RidWords.classification(1, null, null), 'EU · category undeclared · class undeclared');
      expect(RidWords.classification(1, 1, 1), 'EU · Open · C0');
      expect(RidWords.classification(1, 3, 7), 'EU · Certified · C6');
      expect(RidWords.classification(0, null, null), 'Undeclared');
    });

    test('a schema-2 database gains the new columns and keeps its records', () async {
      final db = AppDatabase(NativeDatabase.memory(setup: (raw) {
        raw.execute('CREATE TABLE "detections" ("detector_id" TEXT NOT NULL, "row_key" TEXT NOT NULL, '
            '"seq" INTEGER NULL, "active" INTEGER NOT NULL DEFAULT 0, "uas_id" TEXT NULL, "mac" TEXT NOT NULL, '
            '"srcs" INTEGER NULL, "fmts" INTEGER NULL, "ua_type" INTEGER NULL, "first_utc" INTEGER NOT NULL, '
            '"last_utc" INTEGER NOT NULL, "dur_s" INTEGER NOT NULL, "lat" REAL NULL, "lon" REAL NULL, '
            '"max_h" REAL NULL, "peak_rssi" INTEGER NULL, "auth_state" TEXT NOT NULL DEFAULT \'none\', '
            '"tfr" INTEGER NOT NULL, "emerg" INTEGER NOT NULL, "msgs" INTEGER NOT NULL, '
            'PRIMARY KEY ("detector_id", "row_key"))');
        raw.execute('CREATE TABLE "detectors" ("id" TEXT NOT NULL, "name" TEXT NOT NULL, '
            '"board" TEXT NOT NULL DEFAULT \'unknown\', "fw" TEXT NOT NULL DEFAULT \'orecchino\', '
            '"ver" TEXT NOT NULL DEFAULT \'\', "caps" TEXT NOT NULL DEFAULT \'\', "last_seen" INTEGER NOT NULL DEFAULT 0, '
            '"last_sync_seq" INTEGER NOT NULL DEFAULT 0, "oldest_seq" INTEGER NULL, "bonded" INTEGER NOT NULL DEFAULT 0, '
            '"last_sync_utc" INTEGER NULL, "history_gap" INTEGER NOT NULL DEFAULT 0, '
            '"log_epoch" INTEGER NOT NULL DEFAULT 0, PRIMARY KEY ("id"))');
        raw.execute('CREATE TABLE "live_points" ("id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, '
            '"detector_id" TEXT NOT NULL, "uas_key" TEXT NOT NULL, "timestamp" INTEGER NOT NULL, "lat" REAL NULL, '
            '"lon" REAL NULL, "height" REAL NULL, "rssi" INTEGER NOT NULL)');
        raw.execute('CREATE TABLE "settings" ("key" TEXT NOT NULL, "value" TEXT NOT NULL, PRIMARY KEY ("key"))');
        raw.execute("INSERT INTO detections VALUES ('t5','0:s1',1,0,'OLD','M',1,1,2,10,20,10,NULL,NULL,NULL,-60,"
            "'none',1,0,5)");
        raw.execute('PRAGMA user_version = 2');
      }));
      final rows = await db.getDetectionsList();
      expect(rows.single.uasId, 'OLD');
      expect((rows.single.tfr, rows.single.inTfr, rows.single.tfrId, rows.single.classType), (true, null, null, null));
      await db.close();
    });

    test('a schema-1 database upgrades straight to 3, and clearing the history works on it', () async {
      final db = AppDatabase(NativeDatabase.memory(setup: (raw) {
        raw.execute('CREATE TABLE "detections" ("detector_id" TEXT NOT NULL, "seq" INTEGER NOT NULL, '
            '"auth_state" INTEGER NOT NULL DEFAULT 0, PRIMARY KEY ("detector_id", "seq"))');
        raw.execute('CREATE TABLE "detectors" ("id" TEXT NOT NULL, "name" TEXT NOT NULL, '
            '"board" TEXT NOT NULL DEFAULT \'unknown\', "fw" TEXT NOT NULL DEFAULT \'orecchino\', '
            '"ver" TEXT NOT NULL DEFAULT \'\', "caps" TEXT NOT NULL DEFAULT \'\', "last_seen" INTEGER NOT NULL DEFAULT 0, '
            '"last_sync_seq" INTEGER NOT NULL DEFAULT 0, "oldest_seq" INTEGER NULL, "bonded" INTEGER NOT NULL DEFAULT 0, '
            'PRIMARY KEY ("id"))');
        raw.execute("INSERT INTO detectors (id, name, last_sync_seq, oldest_seq) VALUES ('t5', 'T5', 9, 3)");
        raw.execute('PRAGMA user_version = 1');
      }));
      final d = await db.getDetector('t5');
      expect((d!.name, d.lastSyncSeq, d.oldestSeq, d.logEpoch), ('T5', 0, null, 0));
      await db.insertDetections([
        DetectionsCompanion.insert(
            detectorId: 't5', rowKey: '0:s1', mac: 'M', firstUtc: 1, lastUtc: 2, durS: 1, tfr: false,
            emerg: false, msgs: 1, classEu: const Value(3)),
      ]);
      expect(await db.clearLocalHistory(), 1); // live_points exists too
      await db.close();
    });

    test('log records: TFR now and then, its id and the EU class, into History and the details', () async {
      final live = HostMessage.parse(firmwareLiveLog)! as LogRecordMessage;
      expect((live.tfrEver, live.inTfrNow, live.tfrId), (true, true, 'TEST/1'));
      expect((live.classType, live.catEu, live.classEu), (1, 2, 3));
      final ended = HostMessage.parse(firmwareEndedLog)! as LogRecordMessage;
      expect((ended.seq, ended.tfrEver, ended.inTfrNow, ended.tfrId), (5, true, false, 'TEST/1'));
      // An older record: only "tfr".
      final old = HostMessage.parse(
          '{"type":"log","seq":1,"active":false,"uas":"X","mac":"M","first":1,"last":2,"dur":1,"tfr":true,"msgs":3}')!
          as LogRecordMessage;
      expect((old.tfrEver, old.inTfrNow, old.tfrId, old.classType), (true, null, null, null));

      // Through the sync into the database, and out as words.
      final db = AppDatabase(NativeDatabase.memory());
      final lines = <String>[];
      final sync = SyncEngine(db: db, sendCommand: (c) async => lines.add(c));
      await db.upsertDetector(const DetectorsCompanion(id: Value('t5'), name: Value('T5')));
      await sync.startSync('t5');
      await sync.handleMessage(ended);
      await sync.handleMessage(live);
      await sync.handleMessage(HostMessage.parse('{"type":"log_done","n":1,"live":1,"total":6,"next":6}')!);
      final rows = await db.getDetectionsList(detectorId: 't5');
      final e = rows.singleWhere((r) => !r.active);
      expect((e.tfr, e.inTfr, e.tfrId, e.classType, e.catEu, e.classEu), (true, false, 'TEST/1', 1, 2, 3));
      final d = recordDroneDetails(e);
      expect(d.alerts, contains('IN TFR TEST/1'));
      expect(d.row('Alerts', 'In a TFR')!.value, 'IN TFR TEST/1');
      expect(d.row('Alerts', 'In a TFR')!.secondary, 'Had left it by the end');
      expect(d.row('Alerts', 'TFR')!.value, 'TEST/1');
      expect(d.row('Identity', 'Classification')!.value, 'EU · Specific · C2');
      expect(recordWords(e), contains('IN TFR TEST/1'));
      final l = rows.singleWhere((r) => r.active);
      expect(recordDroneDetails(l).row('Alerts', 'In a TFR')!.secondary, 'Inside it now');
      sync.dispose();
      await db.close();
    });
  });

  test('every field a receiver sends is shown, in words', () {
    final t = ContactTracker();
    t.ingest(full, now - 5000, obs);
    t.ingest(
        rid({
          'src': 'wifi',
          'mac': 'E2:01:23:45:67:8A',
          'rssi': -60,
          'ch': 6,
          'ssid': 'RID-1581F6Z9ABCD1234',
          'ssid_id_match': true,
          'basic_id': [
            {'id_type': 1, 'ua_type': 2, 'uas_id': '1581F6Z9ABCD1234'}
          ],
        }),
        now,
        obs);
    final c = t['1581F6Z9ABCD1234']!;
    final d = liveDroneDetails(c,
        nowMs: now, observer: obs, conflictWatch: 'conflict watch on, no ADS-B conflicts, data 3 s old');
    String? v(String s, String l) => d.row(s, l)?.value;

    expect(d.title, 'D1234');
    expect(d.model, 'DJI Mini 4 Pro');
    expect(v('Identity', 'UAS ID'), '1581F6Z9ABCD1234');
    expect(v('Identity', 'ID type'), 'Serial number (CTA-2063-A)');
    expect(v('Identity', 'Also broadcast'), 'SESSION-77 (Specific session ID)');
    expect(v('Identity', 'UA type'), 'Multirotor');
    expect(v('Identity', 'Classification'), 'EU · Open · C1');
    expect(v('Identity', 'Operator ID'), 'FIN87astrdge12k8');
    expect(v('Identity', 'Self-ID'), 'Survey flight');

    expect(v('Position', 'Status'), 'Airborne');
    expect(v('Position', 'Latitude, longitude'), '37.8089123, -122.4640456');
    expect(d.row('Position', 'Latitude, longitude')!.copy, '37.8089123, -122.4640456');
    expect(v('Position', 'From you'), startsWith('557 m, 0° N'));
    expect(v('Position', 'Geodetic altitude'), '120.4 m');
    expect(v('Position', 'Pressure altitude'), '101.2 m');
    expect(v('Position', 'Height'), '100.0 m above take-off');
    expect(v('Position', 'Horizontal accuracy'), '< 3 m');
    expect(v('Position', 'Vertical accuracy'), '< 10 m');
    expect(v('Position', 'Pressure altitude accuracy'), '< 25 m');
    expect(v('Position', 'Speed accuracy'), '< 1 m/s');
    expect(v('Position', 'Position time'), '1234.5 s past the hour');
    expect(v('Position', 'Time accuracy'), '< 0.2 s');

    expect(v('Motion', 'Speed'), '12.0 m/s');
    expect(v('Motion', 'Vertical speed'), '+0.2 m/s');
    expect(v('Motion', 'Track'), '107° ESE');

    expect(v('Operator', 'Location'), '37.8060000, -122.4680000');
    expect(d.row('Operator', 'Location')!.secondary, 'Live (operator GNSS)');
    expect(v('Operator', 'Altitude'), '21.5 m');
    expect(v('Operator', 'From the drone'), matches(RegExp(r'^\d+ m, \d+° SW$')));
    expect(v('Operator', 'From you'), matches(RegExp(r'^\d+ m, \d+° [WS]+')));

    expect(v('System', 'Area count'), '1');
    expect(v('System', 'Area radius'), '200 m');
    expect(v('System', 'Area ceiling'), '120.0 m');
    expect(v('System', 'Area floor'), '0.0 m');
    expect(v('System', 'System time'), startsWith('2025-'));

    expect(v('Signal', 'Transports'), 'Bluetooth LE Long Range (coded PHY) · Wi-Fi beacon (ch 6)');
    // Both sensors, each with its own signal and last heard.
    expect(v('Signal', 'Heard by'), 'Detector over Wi-Fi and Bluetooth long range');
    expect(v('Signal', 'Detector · BLE LR'), '-68 dBm');
    expect(d.row('Signal', 'Detector · BLE LR')!.secondary, 'last heard 5 s ago, via Detector');
    expect(v('Signal', 'Detector · Wi-Fi'), '-60 dBm');
    expect(v('Signal', 'Signal now'), '-60 dBm');
    expect(v('Signal', 'Peak signal'), '-60 dBm');
    expect(v('Signal', 'MAC addresses'), 'E2:01:23:45:67:89\nE2:01:23:45:67:8A');
    expect(v('Signal', 'Wi-Fi SSID'), 'RID-1581F6Z9ABCD1234');
    expect(v('Signal', 'Messages'), '2');
    expect(v('Signal', 'Last heard'), '0 s ago');
    expect(v('Signal', 'Protocol'), 'ASTM F3411 / ASD-STAN, protocol v2');

    expect(v('Authentication', 'Verdict'), 'ID signature valid (the position is not signed)');
    expect(v('Authentication', 'Type'), 'UAS ID signature');
    expect(v('Authentication', 'Pages'), '5');
    expect(v('Authentication', 'Length'), '90 bytes');

    expect(v('Alerts', 'Emergency'), 'None reported');
    expect(v('Alerts', 'ADS-B'), 'No alert names this drone');
    // The one thing the live line never carries: said so.
    expect(d.row('Alerts', 'In a TFR')!.reported, isFalse);
  });

  test('what was not broadcast reads "not reported", never an unknown marker', () {
    final t = ContactTracker();
    // A drone heard by MAC with a Location of unknowns (the firmware's
    // markers: -1000 altitudes, speed -1, direction -1, ts -1).
    t.ingest(
        rid({
          'src': 'ble',
          'mac': 'AA:BB:CC:DD:EE:FF',
          'rssi': -80,
          'loc': {
            'status': 0,
            'lat': 0.0,
            'lon': 0.0,
            'alt_geo': -1000.0,
            'alt_baro': -1000.0,
            'height': -1000.0,
            'height_ref': 0,
            'speed': -1,
            'dir': -1,
            'ts': -1,
          },
        }),
        now,
        null);
    final c = t['AA:BB:CC:DD:EE:FF']!;
    final d = liveDroneDetails(c, nowMs: now);
    for (final s in d.sections) {
      for (final r in s.rows) {
        expect(r.shown, isNot(matches(RegExp(r'-1000|NaN|null|-1\b|Infinity'))), reason: '${s.title} ${r.label}');
      }
    }
    for (final (s, l) in [
      ('Identity', 'UAS ID'),
      ('Identity', 'ID type'),
      ('Identity', 'Operator ID'),
      ('Position', 'Latitude, longitude'),
      ('Position', 'Geodetic altitude'),
      ('Position', 'Height'),
      ('Position', 'Horizontal accuracy'),
      ('Position', 'Position time'),
      ('Motion', 'Speed'),
      ('Motion', 'Track'),
      ('Operator', 'Location'),
      ('System', 'Area radius'),
      ('Authentication', 'Verdict'),
    ]) {
      expect(d.row(s, l)!.shown, notReported, reason: '$s $l');
    }
    expect(d.row('Position', 'Status')!.value, 'Undeclared');
  });

  test('a History record: what the log keeps, the rest said to be not kept', () {
    const e = DetectionEntry(
      detectorId: 'det',
      rowKey: '0:s4',
      seq: 4,
      active: false,
      uasId: '1581F5FJ00000001',
      mac: 'E2:01:23:45:67:04',
      srcs: 5,
      fmts: 1,
      uaType: 2,
      firstUtc: 1790000000,
      lastUtc: 1790000600,
      durS: 600,
      lat: 37.80391,
      lon: -122.46401,
      maxH: 118,
      peakRssi: -61,
      authState: 'invalid',
      tfr: true,
      emerg: false,
      msgs: 150,
    );
    final d = recordDroneDetails(e);
    expect(d.model, 'DJI Mavic 3 Thermal');
    expect(d.alerts, ['IN TFR', 'ID SIGNATURE INVALID']);
    expect(d.row('Signal', 'Heard by')!.value, 'A detector');
    expect(d.row('Signal', 'Heard by')!.secondary, 'Bluetooth LE · Wi-Fi beacon');
    expect(d.row('Position', 'Highest height')!.value, '118 m');
    expect(d.row('Signal', 'Last heard')!.secondary, 'In range 10 min 0 s');
    expect(d.row('Identity', 'Operator ID')!.shown, notReported);
    expect(d.row('Identity', 'Operator ID')!.secondary, 'Not kept in the history log');
    expect(d.row('Alerts', 'In a TFR')!.value, 'IN TFR');
    // An older detector's record: in a TFR, but not which.
    expect(d.row('Alerts', 'TFR')!.secondary, 'This detector\'s firmware does not send the TFR\'s name');
  });

  group('app', () {
    late AppController app;
    setUp(() async {
      app = AppController(
        db: AppDatabase(NativeDatabase.memory()),
        ble: BleService(transport: FakeTransport()),
        location: FakeLocation(),
        startTimers: false,
      );
      await app.start();
      app.tracker.ingest(full, app.nowMs(), app.observer);
    });
    tearDown(() => app.dispose());

    test('the operator: its own item, words from its drone and from you', () {
      final items = buildLiveItems(app);
      final op = items.singleWhere((c) => c.isOperator);
      expect(op.id, 'op:1581F6Z9ABCD1234');
      expect(op.label, matches(RegExp(r'^operator \d+ m SW$')));
      expect(op.semantics(headingDeg: 0),
          matches(RegExp(r'^Operator of drone D1234, \d+ m SW of the drone, \d+ m from you, \d+ o.clock')));
      final drone = items.singleWhere((c) => c.isDrone);
      expect(drone.operatorLine, matches(RegExp(r'^Operator \d+ m from drone · \d+ m from you$')));
      expect(drone.semantics(headingDeg: 0), contains('Operator '));
    });

    testWidgets('the sheet: every section, rows as screen-reader nodes, 2x text without overflow', (tester) async {
      final handle = tester.ensureSemantics();
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: OrecchinoTheme.dark,
        home: MediaQuery(
          data: const MediaQueryData(size: Size(390, 844), textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: DroneDetailsSheet(listenable: app, details: () => liveDetailsFor(app, '1581F6Z9ABCD1234')),
          ),
        ),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.bySemanticsLabel(RegExp(r'^Drone D1234 details, DJI Mini 4 Pro')), findsOneWidget);
      expect(find.byTooltip('Copy UAS ID'), findsOneWidget); // IDs and positions can be copied
      for (final s in ['Identity', 'Position', 'Motion', 'Operator', 'System', 'Signal', 'Authentication', 'Alerts']) {
        await tester.scrollUntilVisible(find.text(s.toUpperCase()), 200);
        expect(tester.takeException(), isNull, reason: s);
      }
      await tester.scrollUntilVisible(find.text('No detector with TFRs loaded has placed it'), 200);
      expect(find.bySemanticsLabel(RegExp(r'^In a TFR, not reported')), findsOneWidget);
      handle.dispose();
    });

    test('an alert naming the drone: its action in the Alerts section', () {
      final c = app.tracker['1581F6Z9ABCD1234']!;
      const al = TrafficAlert(
        level: TrafficLevel.warning,
        kind: TrafficKind.near,
        droneId: '1581F6Z9ABCD1234',
        hex: 'a1b2c3',
        horizM: 600,
        vertM: 80,
        bearingDeg: 200,
        ageS: 3,
        text: 'TRAFFIC NEAR DRONE D1234',
        action: 'GIVE WAY: DESCEND AND LAND D1234',
        resolution: 'GIVE WAY: DESCEND AND LAND D1234; AIRCRAFT 80 M ABOVE, 600 M SSW',
      );
      final d = liveDroneDetails(c, nowMs: app.nowMs(), alerts: [al]);
      expect(d.alerts.first, 'GIVE WAY: DESCEND AND LAND D1234');
      expect(d.row('Alerts', 'ADS-B')!.value, 'GIVE WAY: DESCEND AND LAND D1234');
      expect(
          d.row('Alerts', 'ADS-B')!.secondary, startsWith('AIRCRAFT 80 M ABOVE, 600 M SSW · TRAFFIC NEAR DRONE D1234'));
      expect(d.alertTone, DetailTone.warning);
    });
  });
}
