// odid_decoder_test.dart — every case of tests/odid_test.c (the firmware
// decoder's host test) against the Dart port in lib/core/odid, check for
// check, with the same vectors and the same names, so the phone and the
// detectors decode alike:
//   * the vectors below are asserted to be the C file's own (a vector
//     changed there and not here fails),
//   * the number of checks run here must equal the number the C test runs;
//     when a C compiler is on the PATH the C test is built and run, and its
//     "N passed" is the number compared.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orecchino_mobile/core/odid/odid.dart';

/// The C test's check count when no compiler is at hand (its last run:
/// "209 passed, 0 failed").
const int cChecksLastKnown = 209;

int _checks = 0;
final List<String> _failures = [];

void check(bool cond, String name) {
  _checks++;
  if (!cond) _failures.add(name);
}

void checkF(num a, num b, double eps, String name) => check((a - b).abs() < eps, name);
void checkS(String a, String b, String name) => check(a == b, name);

Uint8List hex(String h) {
  final out = Uint8List(h.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(h.substring(2 * i, 2 * i + 2), radix: 16);
  }
  return out;
}

/// A zeroed buffer of [n] bytes with [h] unhexed into its start (C's
/// `uint8_t d[n]; unhex(h, d)`).
Uint8List buf(int n, String h) => Uint8List(n)..setAll(0, hex(h));

/// Every hex vector this file uses; each must appear in tests/odid_test.c.
final List<String> vectors = [];
String v(String h) {
  vectors.add(h);
  return h;
}

OdidUas decode(List<int> d, [int? len]) {
  final u = OdidUas();
  _lastOk = OdidDecoder.decodePayloadInto(len == null ? d : d.sublist(0, len), u);
  return u;
}

bool _lastOk = false;

/// C's `odid_decode_payload(d, len, &u)`: fills [u] and returns the verdict.
bool dp(List<int> d, int len, void Function(OdidUas) keep) {
  final u = decode(d, len);
  keep(u);
  return _lastOk;
}

bool _memeq(List<int> a, int ao, List<int> b, int bo, int n) {
  for (var i = 0; i < n; i++) {
    if (a[ao + i] != b[bo + i]) return false;
  }
  return true;
}

// ---------------------------------------------------------------- the cases

final goldenPack = v('f0190500004d4647314130313233343536373839000000000000'
    '50f610005c527ebcba251ba88cb4b60000aa099808394100000a'
    '00300052656372656174696f6e616c000000000000000000000'
    '04004a485251b6edbb3b601003200000000150000000000000050'
    '004742522d4f502d31323341424344000000000000000000');

void testGoldenPack() {
  final b = hex(goldenPack);
  final n = b.length;
  check(n == 128, 'golden: payload length');
  late OdidUas u;
  check(dp(b, n, (x) => u = x), 'golden: pack decodes');

  check(u.hasBasic[0], 'golden: basic present');
  check(u.idType[0] == 0, 'golden: id_type');
  check(u.uaType[0] == 0, 'golden: ua_type');
  checkS(u.uasId[0], 'MFG1A0123456789', 'golden: uas id');

  check(u.hasLoc, 'golden: loc present');
  check(u.status == 0, 'golden: status');
  check(u.heightRef == 0, 'golden: height ref');
  checkF(u.dir, 92.0, 0.01, 'golden: direction');
  checkF(u.speed, 20.50, 0.001, 'golden: speed');
  checkF(u.vspeed, -999.0, 0.001, 'golden: vspeed unknown marker');
  checkF(u.lat, 45.5457468, 5e-7, 'golden: latitude');
  checkF(u.lon, -122.9681496, 5e-7, 'golden: longitude');
  checkF(u.altBaro, -1000.0, 0.001, 'golden: baro alt unknown');
  checkF(u.altGeo, 237.0, 0.001, 'golden: geo alt');
  checkF(u.height, 100.0, 0.001, 'golden: height');
  check(u.hAcc == 9, 'golden: h_acc');
  check(u.vAcc == 3, 'golden: v_acc');
  check(u.baroAcc == 4, 'golden: baro_acc');
  check(u.spdAcc == 1, 'golden: spd_acc');
  checkF(u.ts, 0.0, 0.001, 'golden: timestamp');
  check(u.tsAcc == 10, 'golden: ts_acc');

  check(u.hasSelf, 'golden: self present');
  check(u.selfType == 0, 'golden: self type');
  checkS(u.selfDesc, 'Recreational', 'golden: self desc');

  check(u.hasSys, 'golden: system present');
  check(u.classType == 1, 'golden: classification type');
  check(u.opLocType == 0, 'golden: op location type');
  checkF(u.opLat, 45.5443876, 5e-7, 'golden: op latitude');
  checkF(u.opLon, -122.9726866, 5e-7, 'golden: op longitude');
  check(u.areaCount == 1, 'golden: area count');
  checkF(u.areaRadius, 500.0, 0.001, 'golden: area radius');
  checkF(u.areaCeiling, -1000.0, 0.001, 'golden: area ceiling unknown');
  checkF(u.areaFloor, -1000.0, 0.001, 'golden: area floor unknown');
  check(u.catEu == 1, 'golden: EU category');
  check(u.classEu == 5, 'golden: EU class');
  checkF(u.opAlt, -1000.0, 0.001, 'golden: op alt unknown');
  check(u.sysTs == 0, 'golden: system timestamp');

  check(u.hasOp, 'golden: operator present');
  check(u.opIdType == 0, 'golden: op id type');
  checkS(u.opId, 'GBR-OP-123ABCD', 'golden: operator id');
}

Uint8List locMsg(int flags, int dir, int speed, int vspd) {
  final m = Uint8List(25);
  m[0] = 0x12; // Location, proto v2
  m[1] = flags;
  m[2] = dir;
  m[3] = speed;
  m[4] = vspd & 0xFF;
  return m;
}

void testLocationScales() {
  late OdidUas u;
  var m = locMsg(0x01, 10, 82, 0);
  check(dp(m, 25, (x) => u = x), 'scale: mult decodes');
  checkF(u.speed, 125.25, 0.001, 'scale: speed multiplier');

  m = locMsg(0x02, 92, 0, 0);
  dp(m, 25, (x) => u = x);
  checkF(u.dir, 272.0, 0.01, 'scale: EW direction segment');

  m = locMsg(0x00, 200, 0, 0);
  dp(m, 25, (x) => u = x);
  checkF(u.dir, -1.0, 0.001, 'scale: invalid direction');

  m = locMsg(0x00, 0, 255, 0);
  dp(m, 25, (x) => u = x);
  checkF(u.speed, -1.0, 0.001, 'scale: unknown speed');

  m = locMsg(0x00, 0, 0, -20);
  dp(m, 25, (x) => u = x);
  checkF(u.vspeed, -10.0, 0.001, 'scale: negative vspeed');

  m = locMsg(0x00, 0, 0, 0);
  m[21] = 0xFF;
  m[22] = 0xFF;
  dp(m, 25, (x) => u = x);
  checkF(u.ts, -1.0, 0.001, 'scale: unknown timestamp');

  m = locMsg(0x04, 0, 0, 0);
  dp(m, 25, (x) => u = x);
  check(u.heightRef == 1, 'scale: height type AGL');
}

void testBasicIdUtmUuid() {
  final m = Uint8List(25);
  m[0] = 0x02;
  m[1] = 0x32; // id_type 3 (UTM UUID), ua_type 2
  for (var i = 0; i < 20; i++) {
    m[2 + i] = 0xA0 + i;
  }
  late OdidUas u;
  check(dp(m, 25, (x) => u = x), 'uuid: decodes');
  check(u.idType[0] == 3, 'uuid: id type');
  check(u.uaType[0] == 2, 'uuid: ua type');
  checkS(u.uasId[0], 'a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3', 'uuid: hex encoding');
}

void testTextSanitization() {
  final m = Uint8List(25);
  m[0] = 0x32; // Self ID
  m[1] = 0;
  const evil = [0x41, 0x22, 0x42, 0x5C, 0x43, 0x1F, 0x80, 0x20, 0x65, 0x6E, 0x64, 0x20, 0x20]; // A"B\C\x1f\x80 end  (sizeof-1 = 13)
  m.setAll(2, evil);
  late OdidUas u;
  dp(m, 25, (x) => u = x);
  checkS(u.selfDesc, 'A.B.C.. end', 'sanitize: JSON-breaking chars + trim');
}

void testPackBounds() {
  var d = Uint8List(256);
  late OdidUas u;

  check(!dp(d, 24, (x) => u = x), 'bounds: short buffer');

  d[0] = 0xF2;
  d[1] = 24;
  d[2] = 1;
  check(!dp(d, 30, (x) => u = x), 'bounds: bad pack msg size');

  d = Uint8List(256);
  d[0] = 0xF2;
  d[1] = 25;
  d[2] = 2;
  d[3] = 0x02;
  d[4] = 0x12;
  d.setAll(5, 'TRUNCATED-PACK'.codeUnits);
  check(dp(d, 3 + 25, (x) => u = x), 'bounds: truncated pack decodes');
  check(u.hasBasic[0] && !u.hasLoc, 'bounds: only complete message');

  d = Uint8List(256);
  d[0] = 0x22;
  check(dp(d, 25, (x) => u = x), 'bounds: auth-only accepted');
  check(u.hasAuth, 'bounds: auth flag set');

  d = Uint8List(256);
  d[0] = 0xF2;
  d[1] = 25;
  d[2] = 200;
  d[3] = 0x02;
  d[4] = 0x12;
  d[5] = 0x58; // 'X'
  check(dp(d, 3 + 25, (x) => u = x), 'bounds: count clamp decodes');
  checkS(u.uasId[0], 'X', 'bounds: clamped pack content');

  d = Uint8List(256);
  d[0] = 0xF2;
  d[1] = 25;
  d[2] = 2;
  d[3] = 0x02;
  d[4] = 0x12;
  d[5] = 0x59; // 'Y'
  d[3 + 25] = 0x22;
  d[3 + 25 + 1] = 0x10;
  d[3 + 25 + 2] = 0xFF;
  d[3 + 25 + 3] = 64;
  check(dp(d, 3 + 50, (x) => u = x), 'auth: hostile page index decodes');
  check(u.authLastPage <= 15, 'auth: LastPageIndex clamped to 4 bits');
  check(!u.authComplete, 'auth: one page of many is not complete');
}

void testDualBasicId() {
  final d = Uint8List(3 + 50);
  d[0] = 0xF2;
  d[1] = 25;
  d[2] = 2;
  d[3] = 0x02;
  d[4] = 0x12;
  d.setAll(5, 'SERIAL-1'.codeUnits);
  d[28] = 0x02;
  d[29] = 0x22;
  d.setAll(30, 'CAA-REG-1'.codeUnits);
  late OdidUas u;
  check(dp(d, d.length, (x) => u = x), 'dual: decodes');
  check(u.hasBasic[0] && u.hasBasic[1], 'dual: both slots');
  checkS(u.uasId[0], 'SERIAL-1', 'dual: slot 0');
  checkS(u.uasId[1], 'CAA-REG-1', 'dual: slot 1');
  check(u.idType[1] == 2, 'dual: slot 1 type');
}

void testTxRoundtrip() {
  final s = OdidTxState(
    uasId: 'ORECCHINO-TEST-0001',
    protoVer: 2,
    uaType: 2,
    status: 2,
    lat: 37.803900,
    lon: -122.464000,
    altGeoM: 100.0,
    heightM: 60.0,
    speedMs: 8.25,
    vspeedMs: 1.5,
    dirDeg: 275.0,
    tsS: 1234.5,
    selfDesc: 'orecchino TX self-test',
    opLat: 37.803000,
    opLon: -122.465000,
    opAltM: 15.0,
    opId: 'TEST-OP-0001',
  );
  var pack = OdidEncoder.pack(s, 238000000);
  final n = pack.length;
  check(n == 128, 'tx: pack length');

  late OdidUas u;
  check(dp(pack, n, (x) => u = x), 'tx: decodes');
  checkS(u.uasId[0], 'ORECCHINO-TEST-0001', 'tx: uas id');
  check(u.idType[0] == 1, 'tx: id type serial');
  check(u.uaType[0] == 2, 'tx: ua type');
  check(u.status == 2, 'tx: status airborne');
  checkF(u.lat, 37.803900, 5e-7, 'tx: latitude');
  checkF(u.lon, -122.464000, 5e-7, 'tx: longitude');
  checkF(u.altGeo, 100.0, 0.5, 'tx: geo altitude');
  checkF(u.height, 60.0, 0.5, 'tx: height');
  checkF(u.speed, 8.25, 0.25, 'tx: speed');
  checkF(u.vspeed, 1.5, 0.5, 'tx: vertical speed');
  checkF(u.dir, 275.0, 1.0, 'tx: direction (E/W segment)');
  checkF(u.ts, 1234.5, 0.1, 'tx: timestamp');
  checkS(u.selfDesc, 'orecchino TX self-test', 'tx: self description');
  checkF(u.opLat, 37.803000, 5e-7, 'tx: operator latitude');
  checkF(u.opLon, -122.465000, 5e-7, 'tx: operator longitude');
  checkF(u.opAlt, 15.0, 0.5, 'tx: operator altitude');
  checkS(u.opId, 'TEST-OP-0001', 'tx: operator id');
  check(u.sysTs == 238000000, 'tx: system timestamp');

  s.vspeedMs = double.nan;
  pack = OdidEncoder.pack(s, 0);
  check(dp(pack, n, (x) => u = x), 'tx: decodes with unknown vspeed');
  checkF(u.vspeed, -999.0, 0.001, 'tx: unknown vspeed marker survives');

  s
    ..vspeedMs = 0.0
    ..speedMs = 90.0
    ..dirDeg = 45.0;
  pack = OdidEncoder.pack(s, 0);
  dp(pack, n, (x) => u = x);
  checkF(u.speed, 90.0, 0.75, 'tx: high-speed multiplier band');
  checkF(u.dir, 45.0, 1.0, 'tx: east direction segment');
}

void testAuthPages() {
  final s = OdidTxState(protoVer: 2);
  final data = List<int>.generate(64, (i) => i);

  check(OdidEncoder.authPages(17) == 1, 'auth: 17 bytes is one page');
  check(OdidEncoder.authPages(18) == 2, 'auth: 18 bytes spills to two');
  check(OdidEncoder.authPages(63) == 3, 'auth: 63 bytes fills three pages');
  check(OdidEncoder.authPages(64) == 4, 'auth: 64 bytes spills to four');
  check(OdidEncoder.authPages(17 + 15 * 23) == 16, 'auth: 16 pages max');

  var m = OdidEncoder.authPage(s, 1, 0, data, 64, 0x11223344);
  check((m[0] >> 4) == 2, 'auth: message type 2');
  check((m[0] & 0x0F) == 2, 'auth: protocol version');
  check((m[1] >> 4) == 1, 'auth: auth type in the high nibble');
  check((m[1] & 0x0F) == 0, 'auth: page number in the low nibble');
  check(m[2] == 3, 'auth: page 0 carries LastPageIndex, not a count');
  check(m[3] == 64, 'auth: page 0 carries the total length');
  check(odidRdU32(m, 4) == 0x11223344, 'auth: page 0 timestamp');
  check(_memeq(m, 8, data, 0, 17), 'auth: page 0 holds 17 bytes');

  m = OdidEncoder.authPage(s, 1, 1, data, 64, 0);
  check((m[1] & 0x0F) == 1, 'auth: page 1 number');
  check(_memeq(m, 2, data, 17, 23), 'auth: page 1 holds 17..39');

  m = OdidEncoder.authPage(s, 1, 2, data, 64, 0);
  check(_memeq(m, 2, data, 40, 23), 'auth: page 2 holds 40..62');

  m = OdidEncoder.authPage(s, 1, 3, data, 64, 0);
  check(m[2] == data[63], 'auth: page 3 holds the final byte');
  check(m[3] == 0, 'auth: page 3 zero-pads past the data');

  m = OdidEncoder.authPage(s, 1, 0, data, 300, 0);
  check(m[3] == 255, 'auth: length clamps at 255');
}

void testVersionGating() {
  final s = OdidTxState(uasId: 'VERSION-TEST', selfDesc: 'v', opId: 'OP');
  late OdidUas u;

  s.protoVer = 2;
  var pack = OdidEncoder.pack(s, 238000000);
  check((pack[0] & 0x0F) == 2, 'version: pack header carries v2');
  check(dp(pack, pack.length, (x) => u = x), 'version: v2 decodes');
  check(u.sysTs == 238000000, 'version: v2 keeps the system timestamp');

  s.protoVer = 0;
  pack = OdidEncoder.pack(s, 238000000);
  check((pack[0] & 0x0F) == 0, 'version: pack header carries v0');
  check((pack[3] & 0x0F) == 0, 'version: messages carry v0 too');
  check(dp(pack, pack.length, (x) => u = x), 'version: v0 decodes');
  check(u.sysTs == 0, 'version: v0 omits the v2-only system timestamp');
  checkS(u.uasId[0], 'VERSION-TEST', 'version: v0 identity intact');
}

void testDualBasicAndPackLimit() {
  final s = OdidTxState(protoVer: 2, uasId: 'SERIAL-1', caaId: 'CAA-REG-1', selfDesc: 'd', opId: 'OP');
  final pack = OdidEncoder.pack(s, 0);
  check(pack[2] == 6, 'dual: pack holds six messages');
  check(pack[2] <= odidPackMaxMessages, 'dual: within the nine limit');

  late OdidUas u;
  check(dp(pack, pack.length, (x) => u = x), 'dual: decodes');
  check(u.hasBasic[0] && u.hasBasic[1], 'dual: both Basic ID slots filled');
  check(u.idType[0] == 1 && u.idType[1] == 2, 'dual: serial then CAA');
  checkS(u.uasId[1], 'CAA-REG-1', 'dual: registration in slot 1');
}

void testSingleMessageRotation() {
  final s = OdidTxState(protoVer: 2, uasId: 'ROTATE-1', selfDesc: 'r', opId: 'OP-R');
  const want = [0, 1, 3, 4, 5];
  for (var i = 0; i < 5; i++) {
    final m = OdidEncoder.single(s, 0, i);
    check(m.length == odidMsgSize, 'single: one message');
    check((m[0] >> 4) == want[i], 'single: rotation order');
  }
  final last = List<int>.filled(6, -1), gap = List<int>.filled(6, 0);
  for (var slot = 0; slot < 3 * odidSingleSeqLen; slot++) {
    final m = OdidEncoder.single(s, 0, odidSingleSeq(slot));
    final t = m[0] >> 4;
    if (last[t] >= 0 && slot - last[t] > gap[t]) gap[t] = slot - last[t];
    last[t] = slot;
  }
  check(gap[1] == 2, 'single seq: Location every other slot');
  check(gap[0] == 8 && gap[3] == 8 && gap[4] == 8 && gap[5] == 8,
      'single seq: Basic ID, Self ID, System and Operator ID once in eight slots');
}

void testStandaloneAuthDecoding() {
  final s = OdidTxState(protoVer: 2);
  final sig = List<int>.filled(64, 0);
  final m = OdidEncoder.authPage(s, 1, 0, sig, sig.length, 12345);
  late OdidUas u;
  check(dp(m, m.length, (x) => u = x), 'standalone auth: decodes payload');
  check(u.hasAuth, 'standalone auth: has_auth true');
  check(u.authType == 1, 'standalone auth: auth_type 1');
  check(u.authTs == 12345, 'standalone auth: timestamp preserved');
  check(u.authPagesSeen == 1, 'standalone auth: page 0 seen');
}

final djiCapture = v('f11903011231353831463844425732354238303042333431370000001120ac1600a3d4ea11cbfe3c48'
    'e2089e0879082c04c6250a004109ffeeea1199b73d4801000000000000020008d774da0d00');

void testDjiV1Capture() {
  final d = buf(78, djiCapture);
  late OdidUas u;
  check(dp(d, 78, (x) => u = x), 'dji: pack decodes');
  check(u.protoVer == 1 && !u.gb46750, 'dji: protocol v1, not GB');
  check(u.hasBasic[0] && u.idType[0] == 1 && u.uaType[0] == 2, 'dji: serial-number basic id, multirotor');
  checkS(u.uasId[0], '1581F8DBW25B800B3417', 'dji: serial');
  check(u.hasLoc && u.status == 2, 'dji: airborne location');
  checkF(u.dir, 172.0, 0.01, 'dji: direction');
  checkF(u.speed, 5.5, 0.01, 'dji: speed');
  checkF(u.vspeed, 0.0, 0.01, 'dji: vertical speed');
  checkF(u.lat, 30.0602531, 1e-7, 'dji: latitude');
  checkF(u.lon, 121.1956939, 1e-7, 'dji: longitude');
  checkF(u.altBaro, 137.0, 0.01, 'dji: baro altitude');
  checkF(u.altGeo, 103.0, 0.01, 'dji: geodetic altitude');
  checkF(u.height, 84.5, 0.01, 'dji: height');
  check(u.heightRef == 0, 'dji: height above take-off');
  check(u.hAcc == 12 && u.vAcc == 2 && u.tsAcc == 10, 'dji: accuracies');
  checkF(u.ts, 967.0, 0.01, 'dji: timestamp');
  check(u.hasSys && u.opLocType == 1 && u.areaCount == 1, 'dji: system message');
  checkF(u.opLat, 30.0609279, 1e-7, 'dji: operator latitude');
  checkF(u.opLon, 121.2004249, 1e-7, 'dji: operator longitude');
  checkF(u.opAlt, 24.0, 0.01, 'dji: operator altitude');
  check(u.sysTs == 232420567, 'dji: system timestamp');
  check(!u.hasSelf && !u.hasOp && !u.hasAuth, 'dji: nothing else claimed');
}

final gbStandard = v('ff2048fffffe3135383146414e4c433235385530323952544e363030303030303030000101d1823b48'
    '3bf2eb11ed0769833b4822f0eb1105001c00284700c2083d0902000c050478acc5529e0103');

void testGb46750StandardPacket() {
  final d = buf(78, gbStandard);
  late OdidUas u;
  check(dp(d, 78, (x) => u = x), 'gb: packet decodes');
  check(u.gb46750, 'gb: flagged as GB 46750');
  check(u.hasBasic[0] && u.idType[0] == 1, 'gb: serial-number basic id');
  checkS(u.uasId[0], '1581FANLC258U029RTN6', 'gb: serial');
  check(!u.hasBasic[1], 'gb: an all-zero registration mark is not an id');
  check(u.hasLoc && u.status == 2, 'gb: airborne location');
  checkF(u.lat, 30.0675106, 1e-7, 'gb: aircraft latitude');
  checkF(u.lon, 121.1859817, 1e-7, 'gb: aircraft longitude');
  checkF(u.dir, 0.5, 0.01, 'gb: track');
  checkF(u.speed, 2.8, 0.01, 'gb: ground speed');
  checkF(u.height, 108.0, 0.01, 'gb: relative altitude');
  check(u.heightRef == 0, 'gb: relative altitude is above take-off');
  checkF(u.vspeed, 0.0, 0.01, 'gb: vertical speed');
  checkF(u.altGeo, 121.0, 0.01, 'gb: geodetic altitude');
  checkF(u.altBaro, 182.5, 0.01, 'gb: barometric altitude');
  check(u.hAcc == 12 && u.vAcc == 5 && u.spdAcc == 4 && u.tsAcc == 3, 'gb: accuracies');
  checkF(u.ts, 3547.0, 0.01, 'gb: seconds into the hour');
  check(u.sysTs == 233204347, 'gb: timestamp since 2019');
  check(u.hasSys && u.opLocType == 1, 'gb: live remote-station position');
  checkF(u.opLat, 30.0675643, 1e-7, 'gb: operator latitude');
  checkF(u.opLon, 121.1859665, 1e-7, 'gb: operator longitude');
  checkF(u.opAlt, 14.5, 0.01, 'gb: operator altitude');
}

final gbSynthetic = v('ff2048fffffe31353831463844425732354238303042333431375541534944313233000000cbfe3c48'
    'a3d4ea11000099b73d48ffeeea11000000000000000000000000');
final gbLongBitmap = v('ff2048ffffff0101003135383146414e4c433235385530323952544e363030303030303030000101d1823b48'
    '3bf2eb11ed0769833b4822f0eb1105001c00284700c2083d0902000c050478acc5529e0103');
final gbUnterminated = v('ff2048ffffffffffff');

void testGb46750RegistrationAndTruncation() {
  final d = buf(67, gbSynthetic);
  late OdidUas u;
  check(dp(d, 67, (x) => u = x), 'gb2: truncated packet still decodes what arrived');
  checkS(u.uasId[0], '1581F8DBW25B800B3417', 'gb2: serial');
  check(u.hasBasic[1] && u.idType[1] == 2, 'gb2: registration mark as a CAA-type id');
  checkS(u.uasId[1], 'UASID123', 'gb2: registration mark');
  checkF(u.opLat, 30.0602531, 1e-7, 'gb2: operator latitude from item 6');
  checkF(u.opLon, 121.1956939, 1e-7, 'gb2: operator longitude');
  checkF(u.lat, 30.0609279, 1e-7, 'gb2: aircraft latitude from item 8');
  checkF(u.lon, 121.2004249, 1e-7, 'gb2: aircraft longitude');
  check(u.altGeo == -1000.0 && u.height == -1000.0, 'gb2: zero altitudes stay unknown');
  check(u.status == 0, 'gb2: status undeclared');
  final e = buf(81, gbLongBitmap);
  final ok = dp(e, 81, (x) => u = x);
  check(ok && u.uasId[0] == '1581FANLC258U029RTN6' && (u.lat - 30.0675106).abs() < 1e-7,
      'gb2: a longer bitmap still lands on the content');
  final f = buf(9, gbUnterminated);
  check(!dp(f, 9, (x) => u = x), 'gb2: an unterminated bitmap is rejected');
  final bad = Uint8List(25)..setAll(0, [0xF2, 0x20, 0x01]);
  check(!dp(bad, 25, (x) => u = x), 'gb2: ODID pack with wrong size still rejected');
}

void testCoordPlausibility() {
  check(!odidCoordPlausible(0, 0), 'coord: 0,0 is no fix');
  check(!odidCoordPlausible(1e-7, -1e-7), 'coord: sentinel near zero is no fix');
  check(!odidCoordPlausible(4.9, 4.9), 'coord: inside the 5-degree band');
  check(odidCoordPlausible(5.6, -0.2), 'coord: Accra is a real place');
  check(odidCoordPlausible(37.8, -122.4), 'coord: San Francisco');
  check(!odidCoordPlausible(91, 0) && !odidCoordPlausible(0, 181), 'coord: off the globe');
  check(!odidCoordPlausible(double.nan, 10), 'coord: NaN');
}

/// The C test's check count: built and run when a compiler is at hand.
Future<(int, String)> cCheckCount() async {
  try {
    final dir = Directory.systemTemp.createTempSync('odid_test');
    try {
      final exe = '${dir.path}/odid_test';
      final cc = await Process.run('cc', ['-std=c11', '-O2', '../tests/odid_test.c', '-o', exe]);
      if (cc.exitCode != 0) return (cChecksLastKnown, 'last known (cc failed)');
      final r = await Process.run(exe, const []);
      final m = RegExp(r'(\d+) passed, (\d+) failed').firstMatch('${r.stdout}');
      if (m == null) return (cChecksLastKnown, 'last known (no summary)');
      return (int.parse(m.group(1)!) + int.parse(m.group(2)!), 'from the C run');
    } finally {
      dir.deleteSync(recursive: true);
    }
  } on ProcessException {
    return (cChecksLastKnown, 'last known (no cc)');
  }
}

void main() {
  // tests/odid_test.c main()'s order.
  final cases = <String, void Function()>{
    'dji v1 capture': testDjiV1Capture,
    'gb46750 standard packet': testGb46750StandardPacket,
    'gb46750 registration and truncation': testGb46750RegistrationAndTruncation,
    'coord plausibility': testCoordPlausibility,
    'golden pack': testGoldenPack,
    'tx roundtrip': testTxRoundtrip,
    'auth pages': testAuthPages,
    'version gating': testVersionGating,
    'dual basic and pack limit': testDualBasicAndPackLimit,
    'single message rotation': testSingleMessageRotation,
    'standalone auth decoding': testStandaloneAuthDecoding,
    'location scales': testLocationScales,
    'basic id utm uuid': testBasicIdUtmUuid,
    'text sanitization': testTextSanitization,
    'pack bounds': testPackBounds,
    'dual basic id': testDualBasicId,
  };
  for (final e in cases.entries) {
    test(e.key, () {
      final before = _failures.length;
      e.value();
      expect(_failures.sublist(before), isEmpty);
    });
  }

  test('the vectors are tests/odid_test.c\'s own', () {
    // Join the C file's adjacent string literals, then find each vector.
    final src = File('../tests/odid_test.c').readAsStringSync().replaceAll(RegExp(r'"\s*"'), '');
    for (final h in vectors) {
      expect(src.contains(h), isTrue, reason: 'vector not in tests/odid_test.c: $h');
    }
    expect(vectors.length, 6);
  });

  test('as many checks as the C test', () async {
    final (want, how) = await cCheckCount();
    expect(_failures, isEmpty);
    expect(_checks, want, reason: 'C checks $how');
  });
}
