// app_controller_test.dart — the BLE path end to end with a fake transport:
// pairing pins a verified detector and starts feed / time / position / sync;
// the phone's position goes only to a verified, pinned detector.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orecchino_mobile/app/app_controller.dart';
import 'package:orecchino_mobile/core/ble/ble_service.dart';
import 'package:orecchino_mobile/core/location/location_service.dart';
import 'package:orecchino_mobile/core/traffic/adsb_source.dart';
import 'package:orecchino_mobile/data/db.dart';

import 'support/fakes.dart';

class FakeLocation extends LocationService {
  PhoneLocation? fix;
  FakeLocation(this.fix);
  @override
  Future<void> start() async {}
  @override
  PhoneLocation? get currentLocation => fix;
  @override
  double? get headingDeg => 0;
}

void main() {
  late FakeTransport t;
  late AppController app;
  late List<Uri> adsbGets;

  setUp(() async {
    t = FakeTransport();
    // Never the real adsb.lol: a ready detector fetches ADS-B at once.
    adsbGets = [];
    final adsbClient = MockClient((req) async {
      adsbGets.add(req.url);
      return http.Response('{"ac":[]}', 200);
    });
    app = AppController(
      db: AppDatabase(NativeDatabase.memory()),
      ble: BleService(transport: t, pairTimeout: const Duration(seconds: 2)),
      location: FakeLocation(const PhoneLocation(lat: 37.8039, lon: -122.464, accuracyM: 5, timeMs: 0)),
      adsb: AdsbSource(client: adsbClient),
      startTimers: false,
    );
    await app.start();
  });

  tearDown(() => app.dispose());

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('pairing a verified detector pins it, then feed, time, position and sync', () async {
    final p = t.peers['A'] = FakePeer('A');
    expect(await app.pair('A', 'Orecchino-1A2B'), isTrue);
    await settle();
    final cmds = p.lines.map((l) => jsonDecode(l) as Map<String, dynamic>).toList();
    expect(cmds.map((c) => c['cmd']).toList(), ['feed', 'set_time', 'set_home', 'log_get']);
    expect(cmds[0]['on'], isTrue);
    expect(cmds[2]['lat'], 37.8039);
    expect(cmds[2]['src'], 'phone');
    expect(cmds[3]['since'], 0);
    final d = (await app.db.getDetector('A'))!;
    expect(d.bonded, isTrue);
    expect(d.board, 'lilygo-t5-epaper-s3-pro');
    expect(app.detectorReady, isTrue);

    // Every 60 s: time and position again.
    p.writes.clear();
    await app.pushContext();
    expect(p.lines.map((l) => (jsonDecode(l) as Map<String, dynamic>)['cmd']).toList(), ['set_time', 'set_home']);
  });

  test('history resumes from the stored cursor on the next connection', () async {
    final p = t.peers['A'] = FakePeer('A');
    await app.pair('A', 'Orecchino');
    await settle();
    p.notify('{"type":"log","seq":0,"i":0,"active":false,"uas":"X","mac":"AA:AA:AA:AA:AA:AA","first":1,"last":2,'
        '"dur":1,"peak_rssi":-60,"auth_state":"none","tfr":false,"emerg":false,"msgs":1}\n');
    p.notify('{"type":"log","seq":null,"i":null,"active":true,"uas":"Y","mac":"BB:BB:BB:BB:BB:BB","first":1,"last":2,'
        '"dur":1,"peak_rssi":-60,"auth_state":"none","tfr":false,"emerg":false,"msgs":1}\n');
    p.notify('{"type":"log_done","n":1,"live":1,"total":1,"clock":true,"next":1,"oldest":0}\n');
    for (var i = 0; i < 20 && app.sync.isSyncing; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(app.sync.isSyncing, isFalse);
    expect((await app.db.getDetector('A'))!.lastSyncSeq, 1);

    await app.disconnect();
    final p2 = t.peers['A'] = FakePeer('A');
    await app.connectPinned('A');
    await settle();
    final logGet = p2.lines.map((l) => jsonDecode(l) as Map<String, dynamic>).firstWhere((c) => c['cmd'] == 'log_get');
    expect(logGet['since'], 1);
    expect((await app.db.getDetector('A'))!.lastSyncSeq, 1); // the re-pin kept the cursor
  });

  test('a device that fails verification gets nothing, and is not pinned', () async {
    final p = t.peers['X'] = FakePeer('X', info: '{"fw":"nus-echo","proto":1}');
    expect(await app.pair('X', 'Nordic_UART'), isFalse);
    await app.pushContext();
    expect(p.writes, isEmpty);
    expect(await app.db.getDetector('X'), isNull);
  });

  test('a link the app did not verify and pin never receives the position', () async {
    final p = t.peers['B'] = FakePeer('B');
    await app.ble.connect('B'); // connected and encrypted, but not paired through the app
    expect(app.ble.isReady, isTrue);
    expect(app.detectorReady, isFalse);
    await app.pushContext();
    await app.pushTraffic();
    expect(p.writes, isEmpty);
  });

  test('after the link drops, nothing is sent and the sync stops', () async {
    final p = t.peers['A'] = FakePeer('A');
    await app.pair('A', 'Orecchino');
    await settle();
    expect(app.sync.isSyncing, isTrue);
    p.drop();
    await settle();
    expect(app.detectorReady, isFalse);
    expect(app.sync.isSyncing, isFalse);
    final n = p.writes.length;
    await app.pushContext();
    expect(p.writes.length, n);
  });

  test('pinned detectors are reconnected with their board checked', () async {
    t.peers['A'] = FakePeer('A');
    await app.pair('A', 'Orecchino');
    await app.disconnect();
    expect(app.detectorReady, isFalse);
    // Same ID, different board: refused, and never given the position.
    final impostor = t.peers['A'] = FakePeer('A',
        info: '{"fw":"orecchino","ver":"0.6.0","board":"lilygo-t-embed","caps":["log"],"proto":1}');
    await app.connectPinned('A');
    expect(app.detectorReady, isFalse);
    expect(app.ble.error, contains('not the lilygo-t5-epaper-s3-pro'));
    expect(impostor.writes, isEmpty);
  });

  test('a ready detector fetches ADS-B at once, 10 km (6 NM) around the phone', () async {
    t.peers['A'] = FakePeer('A');
    expect(adsbGets, isEmpty);
    expect(await app.pair('A', 'Orecchino'), isTrue);
    await settle();
    expect(adsbGets, hasLength(1));
    expect(adsbGets.single.path, '/v2/point/37.80/-122.46/6');
  });

  test('forget unpins: no automatic connection afterwards', () async {
    t.peers['A'] = FakePeer('A');
    await app.pair('A', 'Orecchino');
    await app.forget('A');
    expect((await app.db.getDetector('A'))!.bonded, isFalse);
    final before = t.connects;
    await app.connectPinned('A');
    expect(t.connects, before);
  });
}
