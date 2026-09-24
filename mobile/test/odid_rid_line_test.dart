// odid_rid_line_test.dart — rid_line.dart, the port of rx_core.h's
// per-frame path (rx_process, the auth and SSID parts of tracker_ingest,
// format_rid), on the cases tests/core_test.cpp runs through the firmware:
// the DJI and GB 46750 beacons of test_sniffer (same frames; asserted to be
// that file's), the fixed-point writer of test_json_and_log, its repeat
// rules, and test_rx's authentication assembly across frames (without the
// signature check: the phone reports a complete set as "unverified").
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orecchino_mobile/core/odid/odid.dart';
import 'package:orecchino_mobile/core/protocol/messages.dart';

Uint8List unhex(String h) {
  final out = Uint8List(h.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(h.substring(2 * i, 2 * i + 2), radix: 16);
  }
  return out;
}

// tests/core_test.cpp test_sniffer's frames.
const djiBeacon = '80000000ffffffffffff8c1ed90309b28c1ed90309b20000e80c6b2200000000a000210400185249442d3135383146'
    '384442573235423830304233343137dd53fa0bbc0d06f11903011231353831463844425732354238303042333431'
    '370000001120ac1600a3d4ea11cbfe3c48e2089e0879082c04c6250a004109ffeeea1199b73d480100000000000002'
    '0008d774da0d00';
const gbHeader = '80000000ffffffffffff8c1ed90309c38c1ed90309c30000' '0000000000000000' '6400' '0000';
const gbVendor = 'fa0bbc0d24ff2048fffffe3135383146414e4c433235385530323952544e363030303030303030000101d1823b483bf2eb11'
    'ed0769833b4822f0eb1105001c00284700c2083d0902000c050478acc5529e0103';

/// build_signed of core_test.cpp, with a stand-in 64-byte signature (the
/// phone does not verify): Basic, Location, Self, System, Operator, then
/// four auth pages.
Uint8List buildSigned({int ts = 100, int sigSeed = 0}) {
  final st = OdidTxState(
    uasId: 'ORECCHINO-TX-AUTH',
    protoVer: 2,
    uaType: 2,
    status: 2,
    lat: 37.8,
    lon: -122.4,
    altGeoM: 80,
    heightM: 60,
    speedMs: 5,
    dirDeg: 90,
    selfDesc: 'TEST',
    opLat: 37.8,
    opLon: -122.4,
    opAltM: 10,
    opId: 'OP',
  );
  final sig = List<int>.generate(64, (i) => (i * 7 + sigSeed) & 0xFF);
  final msgs = <Uint8List>[
    OdidEncoder.basicId(st),
    OdidEncoder.location(st),
    OdidEncoder.selfId(st),
    OdidEncoder.system(st, ts),
    OdidEncoder.operatorId(st),
    for (var pg = 0; pg < OdidEncoder.authPages(64); pg++) OdidEncoder.authPage(st, 1, pg, sig, 64, ts),
  ];
  return OdidEncoder.packOf(st, msgs);
}

Uint8List msgOf(Uint8List pack, int i) => Uint8List.sublistView(pack, 3 + i * 25, 3 + (i + 1) * 25);

void main() {
  test('the frames are tests/core_test.cpp\'s own', () {
    final src = File('../tests/core_test.cpp').readAsStringSync().replaceAll(RegExp(r'"\s*"'), '');
    for (final h in [djiBeacon, gbHeader, gbVendor]) {
      expect(src.contains(h), isTrue, reason: h);
    }
  });

  group('sniffer (core_test test_sniffer)', () {
    RidLine line(RidLineBuilder b, List<int> frame, int now) {
      final f = OdidWifi.parseMgmtFrame(frame).single;
      return b.build(RidFrameIn(src: 'phone-beacon', mac: f.mac, rssi: -40, channel: 6, ssid: f.ssid, payload: f.payload), now)!;
    }

    test('DJI v1 beacon: serial, position, SSID kept and matching, proto 1', () {
      final l = line(RidLineBuilder(), unhex(djiBeacon), 1000);
      final m = RidMessage.fromJson(l.json);
      expect(m.primaryUasId, '1581F8DBW25B800B3417');
      expect(m.mac, '8C:1E:D9:03:09:B2');
      expect((m.loc!.lat! - 30.0602531).abs() < 1e-6, isTrue);
      expect(m.loc!.heightRef, 0);
      expect(l.json['proto'], 1);
      expect(l.json['ssid'], 'RID-1581F8DBW25B800B3417');
      expect(l.json['ssid_id_match'], isTrue);
      expect(m.src, 'phone-beacon');
      expect(m.channel, 6);
    });

    test('an SSID naming another serial is flagged', () {
      final odd = unhex(djiBeacon);
      odd[36 + 2 + 23] = 0x39; // '9': the SSID now names ...3419
      final l = line(RidLineBuilder(), odd, 1000);
      expect(l.json['ssid_id_match'], isFalse);
    });

    test('GB 46750 beacon: serial, position, height, speed, status, format and operator', () {
      final ssid = 'RID-1581FANLC258U029RTN6'.codeUnits;
      final vend = unhex(gbVendor);
      final gb = [...unhex(gbHeader), 0, ssid.length, ...ssid, 0xDD, vend.length, ...vend];
      final l = line(RidLineBuilder(), gb, 1000);
      final m = RidMessage.fromJson(l.json);
      expect(m.primaryUasId, '1581FANLC258U029RTN6');
      expect(m.fmt, 'gb46750');
      expect(l.json.containsKey('proto'), isFalse);
      expect((m.loc!.lat! - 30.0675106).abs() < 1e-6 && (m.loc!.lon! - 121.1859817).abs() < 1e-6, isTrue);
      expect((m.loc!.height! - 108.0).abs() < 0.01 && (m.loc!.speed! - 2.8).abs() < 0.01 && m.loc!.status == 2, isTrue);
      expect(l.json['ssid_id_match'], isTrue);
      expect((l.json['system'] as Map)['op_lat'], 30.0675643);
    });

    test('the DJI no-fix sentinel yields no position', () {
      final nofix = unhex(djiBeacon);
      for (var i = 0; i < 8; i++) {
        nofix[36 + 26 + 2 + 5 + 3 + 25 + 5 + i] = 0;
      }
      final m = RidMessage.fromJson(line(RidLineBuilder(), nofix, 1000).json);
      expect(m.loc, isNotNull);
      expect(m.loc!.hasPosition, isFalse);
    });
  });

  test('fixed-point numbers match printf (core_test test_json_and_log)', () {
    const vals = [0.0, 1.0, -1.0, 37.8039, -122.464, 0.05, 123.456789, 1e-8, -0.0000001, 359.4, 99999.99];
    for (final v in vals) {
      for (var d = 0; d <= 7; d++) {
        expect(ridFix(v, d), num.parse(v.toStringAsFixed(d)), reason: 'ridFix($v, $d)');
      }
    }
    expect(ridFix(double.nan, 2), isNull);
    expect(ridFix(double.infinity, 2), isNull);
    // Exactly as printed: 7 decimals of a coordinate, 0 of a direction.
    expect(ridFix(37.8, 7), 37.8);
    expect(ridFix(90.0, 0), 90);
    expect(ridFix(0.5, 0), 1); // half away from zero, as jfix
  });

  test('repeats: once a second per source, a different frame at once', () {
    final pack = buildSigned();
    final b = RidLineBuilder();
    var now = 1000;
    bool fresh(String src, Uint8List p) {
      now += 50;
      return b.build(RidFrameIn(src: src, mac: 'M1', payload: p), now)!.fresh;
    }

    final loc = msgOf(pack, 1);
    expect([fresh('phone-beacon', loc), fresh('phone-beacon', loc), fresh('phone-beacon', loc)], [true, false, false]);
    now += 1000;
    expect(fresh('phone-beacon', loc), isTrue, reason: 'again after a second');
    expect(fresh('phone-beacon', msgOf(pack, 0)), isTrue, reason: 'a different frame');
    expect(fresh('phone-ble4', msgOf(pack, 0)), isTrue, reason: 'the same frame on another source');
    final m = RidMessage.fromJson(b.build(RidFrameIn(src: 'phone-ble4', mac: 'M1', payload: loc), now + 5000)!.json);
    expect(m.loc!.lat, 37.8);
    expect(m.loc!.dir, 90);
  });

  group('authentication across frames (core_test test_rx)', () {
    String? state(RidLine l) => (l.json['auth'] as Map<String, dynamic>?)?['state'] as String?;

    test('a whole signed pack in one frame is a complete set', () {
      final l = RidLineBuilder().build(RidFrameIn(src: 'phone-ble5', mac: 'M1', payload: buildSigned()), 1000)!;
      expect(state(l), authStateUnverified);
      final m = RidMessage.fromJson(l.json);
      expect(m.auth!.pages, 4);
      expect(m.auth!.length, 64);
      expect(AuthState.words(m.authState), isNull, reason: 'no badge for an unchecked signature');
    });

    test('Basic ID + four single-message pages: partial three times, then complete; a Location keeps it', () {
      final pack = buildSigned();
      final b = RidLineBuilder();
      var now = 1000;
      RidLine feed(Uint8List p) => b.build(RidFrameIn(src: 'phone-ble4', mac: 'M2', payload: p), now += 50)!;
      expect(state(feed(msgOf(pack, 0))), isNull);
      final states = [for (var pg = 0; pg < 4; pg++) state(feed(msgOf(pack, 5 + pg)))];
      expect(states, ['partial', 'partial', 'partial', authStateUnverified]);
      expect(state(feed(msgOf(pack, 1))), authStateUnverified);
    });

    test('a new set whose page 0 arrives last: the old verdict holds, then the new set completes', () {
      final b = RidLineBuilder();
      var now = 1000;
      RidLine feed(Uint8List p) => b.build(RidFrameIn(src: 'phone-ble4', mac: 'M2', payload: p), now += 50)!;
      final first = buildSigned(ts: 100);
      feed(msgOf(first, 0));
      for (var pg = 0; pg < 4; pg++) {
        feed(msgOf(first, 5 + pg));
      }
      final second = buildSigned(ts: 200, sigSeed: 1);
      for (var pg = 1; pg < 4; pg++) {
        expect(state(feed(msgOf(second, 5 + pg))), authStateUnverified, reason: 'old verdict holds');
      }
      final done = feed(msgOf(second, 5));
      expect(state(done), authStateUnverified);
      expect(done.uas.authTs, 200);
      expect(done.uas.authPagesSeen, 0xF);
    });

    test('a different Basic ID drops what was collected', () {
      final b = RidLineBuilder();
      final pack = buildSigned();
      b.build(RidFrameIn(src: 'phone-ble4', mac: 'M3', payload: msgOf(pack, 0)), 1000);
      b.build(RidFrameIn(src: 'phone-ble4', mac: 'M3', payload: msgOf(pack, 5)), 1050);
      final other = OdidEncoder.basicId(OdidTxState(protoVer: 2, uasId: 'SOMEONE-ELSE'));
      final l = b.build(RidFrameIn(src: 'phone-ble4', mac: 'M3', payload: other), 1100)!;
      expect(l.json.containsKey('auth'), isFalse);
    });

    test('a complete set that is not 64 bytes cannot be Ed25519: unknown_key, as the firmware says', () {
      final st = OdidTxState(protoVer: 2, uasId: 'SHORT-SIG');
      final pack = OdidEncoder.packOf(st, [OdidEncoder.basicId(st), OdidEncoder.authPage(st, 1, 0, List<int>.filled(10, 1), 10, 5)]);
      final l = RidLineBuilder().build(RidFrameIn(src: 'phone-ble5', mac: 'M4', payload: pack), 1000)!;
      expect(state(l), 'unknown_key');
    });
  });

  test('the line maps onto the app model with the firmware\'s unknowns as null', () {
    final golden = unhex('f0190500004d4647314130313233343536373839000000000000'
        '50f610005c527ebcba251ba88cb4b60000aa099808394100000a'
        '00300052656372656174696f6e616c000000000000000000000'
        '04004a485251b6edbb3b601003200000000150000000000000050'
        '004742522d4f502d31323341424344000000000000000000');
    final l = RidLineBuilder().build(RidFrameIn(src: 'phone-nan', mac: 'nan-7', payload: golden), 1000)!;
    final m = HostMessage.parse(jsonEncode(l.json))! as RidMessage;
    expect(m.src, 'phone-nan');
    expect(m.proto, 0);
    expect(m.primaryUasId, 'MFG1A0123456789');
    expect(m.loc!.dir, 92);
    expect(m.loc!.speed, 20.5);
    expect(m.loc!.vspeed, isNull, reason: 'the 126 marker is omitted, as the firmware omits it');
    expect(m.loc!.altBaro, isNull);
    expect(m.loc!.altGeo, 237.0);
    expect(m.loc!.height, 100.0);
    expect(m.loc!.hAcc, 9);
    expect(m.loc!.tsAcc, 10);
    expect(m.system!.operatorLat, 45.5443876);
    expect(m.system!.areaRadius, 500);
    expect(m.system!.classEu, 5);
    expect(m.system!.operatorAltGeo, isNull);
    expect(m.selfId!.text, 'Recreational');
    expect(m.operatorId!.opId, 'GBR-OP-123ABCD');
    expect(m.auth, isNull);
    expect(l.json.containsKey('rssi'), isFalse);
  });
}
