// odid_transport.dart — where an ODID payload sits in each broadcast
// transport, ported from the receive paths of firmware/common/rx_core.h
// (handle_adv, wifi_cb) so the phone accepts exactly the frames a detector
// accepts:
//
//   * Bluetooth LE: AD type 0x16 Service Data, 16-bit UUID 0xFFFA (ASTM),
//     app code 0x0D, then [message counter][ODID message or pack]; or the
//     draft-era manufacturer-specific layout, company 0x0200, same 0x0D.
//     Legacy (BT4) advertisements carry one 25-byte message, extended (BT5)
//     advertisements a whole pack.
//   * Wi-Fi beacon / probe response: vendor-specific element (221), OUI
//     FA:0B:BC (ASD-STAN) or 90:3A:E6 (Parrot), type 0x0D, then
//     [counter][ODID pack or GB 46750 packet].
//   * Wi-Fi NAN: public action frame (0x04 0x09), WFA OUI 50:6F:9A, NAN
//     type 0x13, a Service Descriptor Attribute whose service ID is
//     SHA-256("org.opendroneid.remoteid")[0..5] = 88 69 19 9D 92 09, and
//     service info [counter][ODID pack]. Android's Wi-Fi Aware subscribe
//     hands over just that service info ([OdidWifi.fromNanServiceInfo]).
//
// Every parser returns the payload after the counter; odid_decoder.dart
// decodes it. Nothing here allocates more than the payload it returns.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

/// The ODID service name (ASTM F3411 / opendroneid-core-c wifi.c) and its
/// NAN service ID.
const String odidNanServiceName = 'org.opendroneid.remoteid';
const List<int> odidNanServiceId = [0x88, 0x69, 0x19, 0x9D, 0x92, 0x09];

/// 16-bit service UUID of ASTM Remote ID, and its 128-bit form as
/// flutter_blue_plus prints it.
const int odidBleUuid16 = 0xFFFA;
const String odidBleUuid128 = '0000fffa-0000-1000-8000-00805f9b34fb';
const int odidAppCode = 0x0D;

/// Draft-era manufacturer-specific layout: company ID 0x0200.
const int odidDraftCompanyId = 0x0200;

/// One ODID payload lifted out of its transport.
class OdidFrame {
  /// The transmitter's message counter (increments per transmission).
  final int counter;

  /// A single message, a message pack, or a GB 46750 packet.
  final Uint8List payload;

  const OdidFrame(this.counter, this.payload);
}

/// Which Wi-Fi frame an ODID payload rode.
enum WifiRidKind { beacon, nan }

class WifiRidFrame extends OdidFrame {
  final WifiRidKind kind;

  /// Transmitter address ("AA:BB:CC:DD:EE:FF"), the frame's SA.
  final String mac;

  /// Beacon SSID (DJI puts "RID-" + serial there); null for NAN.
  final String? ssid;

  const WifiRidFrame(this.kind, this.mac, this.ssid, super.counter, super.payload);
}

/// "AA:BB:CC:DD:EE:FF" from six bytes at [o].
String odidMac(List<int> b, [int o = 0]) =>
    [for (var i = 0; i < 6; i++) (b[o + i] & 0xFF).toRadixString(16).padLeft(2, '0').toUpperCase()].join(':');

class OdidBle {
  const OdidBle._();

  /// Service data for UUID 0xFFFA as a scan API reports it (the bytes after
  /// the UUID): [0x0D][counter][ODID...]. Requires a full 25-byte message
  /// (the firmware's AD length >= 30).
  static OdidFrame? fromServiceData(List<int> sd) {
    if (sd.length < 2 + 25 || (sd[0] & 0xFF) != odidAppCode) return null;
    return OdidFrame(sd[1] & 0xFF, Uint8List.fromList(sd.sublist(2)));
  }

  /// Manufacturer data for company 0x0200 (the bytes after the company ID).
  static OdidFrame? fromManufacturerData(int companyId, List<int> data) {
    if (companyId != odidDraftCompanyId) return null;
    return fromServiceData(data);
  }

  /// Every ODID payload in raw advertising data (a sequence of
  /// [len][type][data] structures), as handle_adv walks it.
  static List<OdidFrame> parseAdvertisingData(List<int> data) {
    final out = <OdidFrame>[];
    final len = data.length;
    var i = 0;
    while (i + 1 < len) {
      final l = data[i] & 0xFF; // AD length: type byte + payload
      if (l == 0 || i + 1 + l > len) break;
      final t = data[i + 1] & 0xFF;
      if (l >= 30) {
        final sd = i + 2;
        int b(int k) => data[sd + k] & 0xFF;
        final svc = t == 0x16 && b(0) == 0xFA && b(1) == 0xFF && b(2) == odidAppCode;
        final mfg = t == 0xFF && b(0) == 0x00 && b(1) == 0x02 && b(2) == odidAppCode;
        if (svc || mfg) {
          // sd[3] = message counter, sd+4 = ODID message or pack
          out.add(OdidFrame(b(3), Uint8List.fromList(data.sublist(sd + 4, sd + 4 + (l - 5)))));
        }
      }
      i += 1 + l;
    }
    return out;
  }
}

class OdidWifi {
  const OdidWifi._();

  static bool _odidOui(List<int> ie, int o) {
    final a = ie[o] & 0xFF, b = ie[o + 1] & 0xFF, c = ie[o + 2] & 0xFF;
    return (a == 0xFA && b == 0x0B && c == 0xBC) || (a == 0x90 && b == 0x3A && c == 0xE6);
  }

  /// A vendor-specific element's body (after the element ID and length, as
  /// Android's ScanResult.InformationElement.getBytes() returns it):
  /// OUI(3), type 0x0D, counter, payload.
  static OdidFrame? fromVendorIe(List<int> body) {
    if (body.length < 30 || (body[3] & 0xFF) != odidAppCode || !_odidOui(body, 0)) return null;
    return OdidFrame(body[4] & 0xFF, Uint8List.fromList(body.sublist(5)));
  }

  /// The service-specific info of an ODID NAN publish, as Android's Wi-Fi
  /// Aware DiscoverySessionCallback.onServiceDiscovered delivers it:
  /// [counter][ODID pack].
  static OdidFrame? fromNanServiceInfo(List<int> info) {
    if (info.length < 1 + 25) return null;
    return OdidFrame(info[0] & 0xFF, Uint8List.fromList(info.sublist(1)));
  }

  /// A raw 802.11 management frame (header onwards, FCS stripped), as
  /// wifi_cb reads it: beacons and probe responses for the vendor element,
  /// action frames for a NAN service discovery frame.
  static List<WifiRidFrame> parseMgmtFrame(List<int> d) {
    final out = <WifiRidFrame>[];
    final len = d.length;
    if (len < 24) return out;
    final fc0 = d[0] & 0xFF;
    if ((fc0 & 0x0C) != 0x00) return out; // management frames only
    final stype = fc0 & 0xF0;
    final sa = odidMac(d, 10); // SA in the management header

    if (stype == 0x80 || stype == 0x50) {
      // Beacon or probe response: 24 B header + 12 B fixed fields, then IEs.
      var off = 36;
      String? ssid;
      while (off + 2 <= len) {
        final id = d[off] & 0xFF, l = d[off + 1] & 0xFF;
        if (off + 2 + l > len) break;
        final ie = off + 2;
        if (id == 0 && l <= 32) ssid = String.fromCharCodes(d.sublist(ie, ie + l).takeWhile((c) => c != 0));
        if (id == 221 && l >= 30) {
          final f = fromVendorIe(d.sublist(ie, ie + l));
          if (f != null) out.add(WifiRidFrame(WifiRidKind.beacon, sa, ssid, f.counter, f.payload));
        }
        off += 2 + l;
      }
    } else if (stype == 0xD0) {
      // Action frame: a NAN service discovery frame?
      const b0 = 24;
      final blen = len - 24;
      if (blen < 12) return out;
      int b(int k) => d[b0 + k] & 0xFF;
      if (b(0) != 0x04 || b(1) != 0x09) return out; // public action / vendor
      if (b(2) != 0x50 || b(3) != 0x6F || b(4) != 0x9A) return out; // WFA OUI
      if (b(5) != 0x13) return out; // NAN
      for (var i = 6; i + 12 < blen; i++) {
        var match = true;
        for (var k = 0; k < 6; k++) {
          if (b(i + k) != odidNanServiceId[k]) {
            match = false;
            break;
          }
        }
        if (!match) continue;
        // service_id[6], instance, requestor, control, info_len, counter, ODID...
        final infoLen = b(i + 9);
        var n = infoLen > 0 ? infoLen - 1 : 0;
        final avail = blen - (i + 11);
        if (n > avail) n = avail;
        final start = b0 + i + 11;
        out.add(WifiRidFrame(WifiRidKind.nan, sa, null, b(i + 10), Uint8List.fromList(d.sublist(start, start + n))));
        break;
      }
    }
    return out;
  }
}
