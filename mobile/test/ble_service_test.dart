// ble_service_test.dart — the connect / verify / pair state machine, stale
// callbacks, and command writes, against a fake BLE transport.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:orecchino_mobile/core/ble/ble_service.dart';
import 'package:orecchino_mobile/core/ble/ble_transport.dart';
import 'package:orecchino_mobile/core/link/detector_link.dart';
import 'package:orecchino_mobile/core/protocol/messages.dart';

import 'support/fakes.dart';

void main() {
  late FakeTransport t;
  late BleService ble;

  setUp(() {
    t = FakeTransport();
    ble = BleService(transport: t, pairTimeout: const Duration(seconds: 2));
  });
  tearDown(() => ble.dispose());

  test('connect: MTU, verify, pair, subscribe -> ready; info is emitted', () async {
    final p = t.peers['A'] = FakePeer('A');
    final states = <BleLinkState>[];
    ble.addListener(() => states.add(ble.state));
    final infos = <HostMessage>[];
    final sub = ble.messages.listen(infos.add);

    final info = await ble.connect('A');
    expect(info, isNotNull);
    expect(info!.board, 'lilygo-t5-epaper-s3-pro');
    expect(p.mtuAsked, [517]);
    expect(p.paired, isTrue);
    expect(ble.isReady, isTrue);
    expect(ble.connectedId, 'A');
    expect(states, [BleLinkState.connecting, BleLinkState.verifying, BleLinkState.pairing, BleLinkState.ready]);
    await Future<void>.delayed(Duration.zero);
    expect(infos.whereType<DeviceInfoMessage>(), hasLength(1));
    await sub.cancel();
  });

  test('notifications are reassembled into messages', () async {
    final p = t.peers['A'] = FakePeer('A');
    await ble.connect('A');
    final got = <HostMessage>[];
    final sub = ble.messages.listen(got.add);
    p.notify('{"type":"hb","up":1');
    p.notify('00}\n{"type":"feed_status","on":true}\n');
    await Future<void>.delayed(Duration.zero);
    expect(got.whereType<HeartbeatMessage>().single.uptimeMs, 100);
    expect(got.whereType<FeedStatusMessage>().single.on, isTrue);
    await sub.cancel();
  });

  test('a device that is not an Orecchino is refused and disconnected', () async {
    final p = t.peers['X'] = FakePeer('X', info: '{"fw":"other","proto":1}');
    expect(await ble.connect('X'), isNull);
    expect(ble.state, BleLinkState.failed);
    expect(ble.error, contains('not an Orecchino'));
    expect(p.disconnectedByUs, isTrue);
    expect(p.paired, isFalse); // never paired with it

    final q = t.peers['Y'] = FakePeer('Y')..hasInfo = false;
    expect(await ble.connect('Y'), isNull);
    expect(ble.error, contains('services missing'));
    expect(q.disconnectedByUs, isTrue);
  });

  test('a pinned detector that now reports another board is refused', () async {
    t.peers['A'] = FakePeer('A');
    expect(await ble.connect('A', pinnedBoard: 'seeed-sensecap-indicator'), isNull);
    expect(ble.error, contains('not the seeed-sensecap-indicator'));
    expect(ble.isReady, isFalse);
  });

  test('no encryption (subscribe refused): failed, not ready', () async {
    t.peers['A'] = FakePeer('A')..refuseSubscribe = true;
    expect(await ble.connect('A'), isNull);
    expect(ble.state, BleLinkState.failed);
    expect(ble.isReady, isFalse);
  });

  test('the board drops us mid-pairing (10 s deadline): failed with words', () async {
    final p = t.peers['A'] = FakePeer('A')..holdPair = Completer<void>();
    final f = ble.connect('A');
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(ble.state, BleLinkState.pairing);
    p.drop();
    await Future<void>.delayed(Duration.zero);
    expect(ble.state, BleLinkState.failed);
    expect(ble.error, contains('before pairing finished'));
    p.holdPair!.complete();
    expect(await f, isNull); // the attempt does not come back to life
    expect(ble.isReady, isFalse);
  });

  test('a late disconnect from an older connection never tears down the new one', () async {
    final a = t.peers['A'] = FakePeer('A');
    final b = t.peers['B'] = FakePeer('B');
    await ble.connect('A');
    // Replace A with B; A's disconnect lands after B is up.
    a.disconnectedByUs = false;
    await ble.connect('B');
    expect(ble.connectedId, 'B');
    expect(a.isDown, isTrue); // A was disconnected by the switch
    a.drop(); // a stray repeat of A's disconnect
    await Future<void>.delayed(Duration.zero);
    expect(ble.isReady, isTrue);
    expect(ble.connectedId, 'B');
    b.drop();
    await Future<void>.delayed(Duration.zero);
    expect(ble.isReady, isFalse);
    expect(ble.state, BleLinkState.idle);
    expect(ble.error, 'connection lost');
  });

  test('send: refused when not ready, never silently dropped', () async {
    await expectLater(ble.send('{"cmd":"feed","on":true}'), throwsA(isA<LinkNotReady>()));
  });

  test('send: MTU-sized chunks, commands never interleave', () async {
    final p = t.peers['A'] = FakePeer('A');
    await ble.connect('A'); // MTU 247 -> 244-byte chunks
    final big = jsonEncode({'cmd': 'traffic', 'pad': 'x' * 600});
    final small = jsonEncode({'cmd': 'feed', 'on': true});
    await Future.wait([ble.send(big), ble.send(small)]);
    expect(p.writes.every((w) => w.length <= 244), isTrue);
    final stream = utf8.decode(p.writes.expand((w) => w).toList());
    expect(stream, '$big\n$small\n');
  });

  test('send after the link dropped fails', () async {
    final p = t.peers['A'] = FakePeer('A');
    await ble.connect('A');
    p.drop();
    await Future<void>.delayed(Duration.zero);
    await expectLater(ble.send('{"cmd":"feed","on":false}'), throwsA(isA<LinkNotReady>()));
  });

  test('connect error is reported', () async {
    t.connectError = StateError('Bluetooth is off');
    expect(await ble.connect('Z'), isNull);
    expect(ble.state, BleLinkState.failed);
    expect(ble.error, 'Bluetooth is off');
  });

  test('scan results are exposed', () async {
    await ble.startScan(timeout: const Duration(milliseconds: 50));
    expect(ble.state, BleLinkState.scanning);
    t.hits([const BleScanHit(id: 'A', name: 'Orecchino-1A2B', rssi: -60)]);
    await Future<void>.delayed(Duration.zero);
    expect(ble.scanHits.single.name, 'Orecchino-1A2B');
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(ble.state, BleLinkState.idle);
  });
}
