// odid_transport_test.dart — the transport framings of lib/core/odid
// (odid_transport.dart, ports of rx_core.h handle_adv and wifi_cb) on the
// repo's real captures in tests/vectors/, the same files the golden vector
// of tests/odid_test.c was cut from, with the values the reference
// Wireshark dissector (tests/vectors/opendroneid-dissector.lua) reads:
//   * odid_wifi_bcn_sample.pcap: 21 beacons, vendor element FA:0B:BC 0x0D;
//   * odid_wifi_sample.pcap: 21 NAN service discovery frames and 21 beacons;
//   * odid_bt5_lr_sample.pcapng: nRF Sniffer, BLE 5 extended advertising
//     on the coded PHY, service data 0xFFFA.
// Each Wi-Fi frame also goes the way Android hands it over (the vendor
// element body; the NAN service info), which must give the same payload.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orecchino_mobile/core/native_rx/ble_rid_scanner.dart';
import 'package:orecchino_mobile/core/native_rx/ble_scan_coordinator.dart';
import 'package:orecchino_mobile/core/native_rx/rid_observation.dart';
import 'package:orecchino_mobile/core/odid/odid.dart';
import 'package:orecchino_mobile/core/power/power_policy.dart';

const vectors = '../tests/vectors';

String hexOf(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// Classic pcap, little-endian: the packets.
List<Uint8List> readPcap(String path) {
  final d = File(path).readAsBytesSync();
  final bd = ByteData.sublistView(d);
  expect(bd.getUint32(0, Endian.little), 0xa1b2c3d4);
  expect(bd.getUint32(20, Endian.little), 127, reason: 'radiotap link type');
  final out = <Uint8List>[];
  var off = 24;
  while (off + 16 <= d.length) {
    final incl = bd.getUint32(off + 8, Endian.little);
    out.add(Uint8List.sublistView(d, off + 16, off + 16 + incl));
    off += 16 + incl;
  }
  return out;
}

/// The 802.11 frame after the radiotap header.
Uint8List stripRadiotap(Uint8List p) => Uint8List.sublistView(p, p[2] | (p[3] << 8));

/// pcapng enhanced packet blocks: the packets.
List<Uint8List> readPcapng(String path) {
  final d = File(path).readAsBytesSync();
  final bd = ByteData.sublistView(d);
  final out = <Uint8List>[];
  var off = 0;
  while (off + 12 <= d.length) {
    final type = bd.getUint32(off, Endian.little), len = bd.getUint32(off + 4, Endian.little);
    if (type == 1) expect(bd.getUint16(off + 8, Endian.little), 272, reason: 'nRF Sniffer link type');
    if (type == 6) {
      final cap = bd.getUint32(off + 20, Endian.little);
      out.add(Uint8List.sublistView(d, off + 28, off + 28 + cap));
    }
    off += len;
  }
  return out;
}

/// One nRF Sniffer (v3 header) packet: CRC verdict, PHY, RSSI, advertiser
/// address and advertising data.
class NordicAdv {
  final bool crcOk;
  final String phy;
  final int rssi;
  final String mac;
  final bool legacy;
  final Uint8List advData;
  NordicAdv(this.crcOk, this.phy, this.rssi, this.mac, this.legacy, this.advData);

  static NordicAdv? parse(Uint8List p) {
    // board(1) payload_len(2) proto(1) counter(2) id(1) | hdr_len(1) flags(1)
    // channel(1) rssi(1) event(2) timestamp(4) | access address(4) ...
    if (p.length < 7 + 10 + 4 + 2) return null;
    final flags = p[8];
    final crcOk = flags & 1 == 1;
    final phy = switch ((flags >> 4) & 7) { 1 => '2m', 2 => 'coded', _ => '1m' };
    final rssi = -p[10];
    var o = 7 + p[7]; // after the packet header
    o += 4; // access address
    if (phy == 'coded') o += 1; // coding indicator
    final pduType = p[o] & 0x0F;
    final pduLen = p[o + 1];
    o += 2;
    final end = (o + pduLen).clamp(0, p.length);
    String mac(int a) => [for (var i = 5; i >= 0; i--) p[a + i].toRadixString(16).padLeft(2, '0').toUpperCase()].join(':');
    if (pduType == 7) {
      // Extended: ext header length + adv mode, flags, fields in order.
      final extLen = p[o] & 0x3F;
      if (extLen == 0) return null;
      final f = p[o + 1];
      if (f & 1 == 0) return null; // no AdvA
      final adv = o + 2;
      final data = o + 1 + extLen;
      if (data > end) return null;
      return NordicAdv(crcOk, phy, rssi, mac(adv), false, Uint8List.sublistView(p, data, end));
    }
    if (pduType == 0 || pduType == 2 || pduType == 6) {
      return NordicAdv(crcOk, phy, rssi, mac(o), true, Uint8List.sublistView(p, o + 6, end));
    }
    return null;
  }
}

/// The C file's golden vector (odid_decoder_test.dart checks it is).
const golden = 'f0190500004d4647314130313233343536373839000000000000'
    '50f610005c527ebcba251ba88cb4b60000aa099808394100000a'
    '00300052656372656174696f6e616c000000000000000000000'
    '04004a485251b6edbb3b601003200000000150000000000000050'
    '004742522d4f502d31323341424344000000000000000000';

void main() {
  test('Wi-Fi beacons: every frame decodes; frame 1 is the golden pack', () {
    final pkts = readPcap('$vectors/odid_wifi_bcn_sample.pcap');
    expect(pkts.length, 21);
    final lats = <double>[];
    for (final p in pkts) {
      final frame = stripRadiotap(p);
      final got = OdidWifi.parseMgmtFrame(frame);
      expect(got.length, 1);
      final f = got.single;
      expect(f.kind, WifiRidKind.beacon);
      expect(f.mac, '84:CC:A8:60:43:24');
      // The Android path: the vendor element body must give the same payload.
      var off = 36, viaIe = <int>[];
      while (off + 2 <= frame.length) {
        final id = frame[off], l = frame[off + 1];
        if (off + 2 + l > frame.length) break;
        if (id == 221) {
          final ie = OdidWifi.fromVendorIe(frame.sublist(off + 2, off + 2 + l));
          if (ie != null) viaIe = ie.payload;
        }
        off += 2 + l;
      }
      expect(hexOf(viaIe), hexOf(f.payload));
      final u = OdidDecoder.decodePayload(f.payload)!;
      expect(u.uasId[0], 'MFG1A0123456789');
      expect(u.opId, 'GBR-OP-123ABCD');
      lats.add(u.lat);
    }
    expect(hexOf(OdidWifi.parseMgmtFrame(stripRadiotap(pkts.first)).single.payload), golden);
    // The dissector's UA latitudes for frames 1, 2 and 4.
    expect((lats[0] - 45.5457468).abs() < 1e-9, isTrue);
    expect((lats[1] - 45.5457355).abs() < 1e-9, isTrue);
    expect((lats[3] - 45.5458760).abs() < 1e-9, isTrue);
  });

  test('Wi-Fi NAN: 21 service discovery frames (and 21 beacons) decode, as Android would hand them over too', () {
    final pkts = readPcap('$vectors/odid_wifi_sample.pcap');
    expect(pkts.length, 63);
    var nan = 0, beacons = 0;
    final byFrame = <int, OdidUas>{};
    for (var i = 0; i < pkts.length; i++) {
      final frame = stripRadiotap(pkts[i]);
      for (final f in OdidWifi.parseMgmtFrame(frame)) {
        if (f.kind != WifiRidKind.nan) {
          beacons++;
          expect(OdidDecoder.decodePayload(f.payload), isNotNull);
          continue;
        }
        nan++;
        // Android: onServiceDiscovered's service info is [counter][pack].
        final info = OdidWifi.fromNanServiceInfo([f.counter, ...f.payload])!;
        expect(hexOf(info.payload), hexOf(f.payload));
        final u = OdidDecoder.decodePayload(f.payload);
        expect(u, isNotNull, reason: 'frame ${i + 1}');
        byFrame[i + 1] = u!;
      }
    }
    // The dissector: 42 frames carry ODID, 21 NAN action frames and 21
    // beacons (the other 21 beacons are NAN synchronisation beacons).
    expect(nan, 21);
    expect(beacons, 21);
    expect(byFrame[2]!.opId, 'GBR-OP-123ABCD');
    expect((byFrame[5]!.lat - 45.5450519).abs() < 1e-9 && (byFrame[5]!.lon - -122.9722906).abs() < 1e-9, isTrue);
    expect(byFrame[5]!.dir, 288); // the dissector's raw 108, E/W segment set: +180
    expect(byFrame[20]!.selfDesc, 'Recreational');
  });

  test('BLE 5 long range: packs on the coded PHY decode, and are reported as phone-coded', () async {
    final pkts = readPcapng('$vectors/odid_bt5_lr_sample.pcapng');
    expect(pkts.length, 274);
    var decoded = 0, crcOk = 0, full = 0;
    final scanner = BleRidScanner(BleScanCoordinator(_NullBackend()));
    final seen = <RidObservation>[];
    final sub = scanner.observations.listen(seen.add);
    for (final p in pkts) {
      final a = NordicAdv.parse(p);
      if (a == null || !a.crcOk) continue;
      crcOk++;
      expect(a.phy, 'coded');
      for (final f in OdidBle.parseAdvertisingData(a.advData)) {
        final u = OdidDecoder.decodePayload(f.payload);
        if (u == null) continue; // the sample opens with empty packs
        decoded++;
        expect(u.uasId[0], 'SSEVTFG93700070');
        if (u.hasOp && u.hasSelf && u.hasSys && u.hasLoc) {
          full++;
          expect(u.opId, 'FIN87astrdge12kxyz8');
          expect(u.selfDesc, 'Drone ID demo');
        }
        // The same advertisement as a scan API reports it.
        scanner.onAdvert(BleAdvert(
          id: a.mac,
          rssi: a.rssi,
          at: DateTime(2023, 10, 4),
          serviceData: {odidBleUuid128: [odidAppCode, f.counter, ...f.payload]},
          phy: a.phy,
          legacy: a.legacy,
        ));
      }
    }
    expect(crcOk, greaterThan(200));
    expect(decoded, greaterThan(200));
    expect(full, greaterThan(150));
    await Future<void>.delayed(Duration.zero);
    expect(seen.length, decoded);
    expect(seen.every((o) => o.source == NativeRidSource.coded && o.message.src == 'phone-coded'), isTrue);
    expect(seen.first.mac, 'E0:7D:EA:EB:2F:1C');
    expect(seen.first.message.phy, 'coded');
    return sub.cancel();
  });

  test('BLE legacy AD walk: service data, the draft manufacturer layout, and what is not ODID', () {
    final s = OdidTxState(protoVer: 2, uasId: 'LEGACY-1');
    final msg = OdidEncoder.basicId(s);
    // [len][0x16][FA FF][0D][counter][25 B] = 31 bytes, a full legacy ADV.
    final svc = [30, 0x16, 0xFA, 0xFF, 0x0D, 7, ...msg];
    final mfg = [30, 0xFF, 0x00, 0x02, 0x0D, 8, ...msg];
    final flags = [2, 0x01, 0x06];
    var frames = OdidBle.parseAdvertisingData([...flags, ...svc]);
    expect(frames.length, 1);
    expect(frames.single.counter, 7);
    expect(OdidDecoder.decodePayload(frames.single.payload)!.uasId[0], 'LEGACY-1');
    frames = OdidBle.parseAdvertisingData(mfg);
    expect(frames.single.counter, 8);
    // Wrong app code, wrong UUID, short structure, truncated structure.
    expect(OdidBle.parseAdvertisingData([30, 0x16, 0xFA, 0xFF, 0x0E, 7, ...msg]), isEmpty);
    expect(OdidBle.parseAdvertisingData([30, 0x16, 0xFB, 0xFF, 0x0D, 7, ...msg]), isEmpty);
    expect(OdidBle.parseAdvertisingData([10, 0x16, 0xFA, 0xFF, 0x0D, 7, ...msg.sublist(0, 5)]), isEmpty);
    expect(OdidBle.parseAdvertisingData([30, 0x16, 0xFA, 0xFF, 0x0D, 7, ...msg.sublist(0, 10)]), isEmpty);
    // The scan-API forms.
    expect(OdidBle.fromServiceData([0x0D, 3, ...msg])!.counter, 3);
    expect(OdidBle.fromServiceData([0x0D, 3, ...msg.sublist(0, 24)]), isNull);
    expect(OdidBle.fromManufacturerData(0x0200, [0x0D, 4, ...msg])!.counter, 4);
    expect(OdidBle.fromManufacturerData(0x004C, [0x0D, 4, ...msg]), isNull);
  });

  test('Wi-Fi vendor element: both OUIs, and the rest refused', () {
    final pack = OdidEncoder.pack(OdidTxState(protoVer: 2, uasId: 'IE-1'), 0);
    expect(OdidWifi.fromVendorIe([0xFA, 0x0B, 0xBC, 0x0D, 9, ...pack])!.counter, 9);
    expect(OdidWifi.fromVendorIe([0x90, 0x3A, 0xE6, 0x0D, 9, ...pack]), isNotNull);
    expect(OdidWifi.fromVendorIe([0x00, 0x50, 0xF2, 0x0D, 9, ...pack]), isNull);
    expect(OdidWifi.fromVendorIe([0xFA, 0x0B, 0xBC, 0x0E, 9, ...pack]), isNull);
    expect(OdidWifi.fromVendorIe([0xFA, 0x0B, 0xBC, 0x0D, 9, ...pack.sublist(0, 20)]), isNull);
    expect(OdidWifi.fromNanServiceInfo([1, ...pack.sublist(0, 24)]), isNull);
    // Not management, or too short.
    expect(OdidWifi.parseMgmtFrame(List<int>.filled(23, 0)), isEmpty);
    expect(OdidWifi.parseMgmtFrame([0x08, ...List<int>.filled(40, 0)]), isEmpty);
  });
}

class _NullBackend implements BleScanBackend {
  @override
  Stream<BleAdvert> get adverts => const Stream.empty();
  @override
  Stream<bool> get scanning => const Stream.empty();
  @override
  bool get isScanningNow => false;
  @override
  Stream<bool> get adapterOn => const Stream.empty();
  @override
  Future<void> start(BleScanFilter filter, {ScanDuty duty = ScanDuty.lowLatency}) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<BlePhyCaps> phyCaps() async => BlePhyCaps.unknown;
}
