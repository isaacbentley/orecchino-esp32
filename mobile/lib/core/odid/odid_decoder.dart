// odid_decoder.dart — ASTM F3411 / Open Drone ID broadcast message decoder,
// a line-for-line port of firmware/common/odid_decode.h so the phone and the
// detectors read every frame the same way (test/odid_decoder_test.dart runs
// every case of tests/odid_test.c against this file).
//
// Messages are 25 bytes; the header byte is (message type << 4) | protocol
// version. [OdidDecoder.decodePayload] accepts a single message, a message
// pack (type 0xF) or a GB 46750-2025 packet (gb46750.dart). Transport
// framing (BLE service data, Wi-Fi beacon vendor element, NAN service
// discovery) is in odid_transport.dart.
//
// The fields keep the firmware's "unknown" markers (altitude -1000, speed
// -1, direction -1, vertical speed -999, timestamp -1): rid_line.dart writes
// them into the same JSON the firmware sends, and messages.dart turns them
// into null there, exactly as for a detector's line.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'gb46750.dart';

/// Page 0 holds 17 auth bytes, pages 1..15 hold 23 each; the wire Length
/// field is a uint8, so 255 is the practical ceiling.
const int odidAuthMaxBytes = 255;

/// One ODID message.
const int odidMsgSize = 25;

/// Decoded state for one UAS, filled from whichever messages were received
/// (odid_decode.h `OdidUas`).
class OdidUas {
  // Basic ID: two slots (a serial number and a CAA registration may both
  // be sent).
  final List<bool> hasBasic = [false, false];
  final List<int> idType = [0, 0];
  final List<int> uaType = [0, 0];
  final List<String> uasId = ['', ''];

  bool hasLoc = false;
  int status = 0, heightRef = 0;
  double dir = 0, speed = 0, vspeed = 0;
  double lat = 0, lon = 0;
  double altBaro = 0, altGeo = 0, height = 0;
  int hAcc = 0, vAcc = 0, baroAcc = 0, spdAcc = 0, tsAcc = 0;
  double ts = 0;

  bool hasSelf = false;
  int selfType = 0;
  String selfDesc = '';

  bool hasSys = false;
  int opLocType = 0, classType = 0;
  double opLat = 0, opLon = 0;
  int areaCount = 0;
  double areaRadius = 0, areaCeiling = 0, areaFloor = 0;
  int catEu = 0, classEu = 0;
  double opAlt = 0;

  /// Seconds since 2019-01-01 00:00 UTC.
  int sysTs = 0;

  bool hasOp = false;
  int opIdType = 0;
  String opId = '';

  /// Which wire format this came from: the ASTM protocol version from the
  /// message header, or GB 46750-2025.
  int protoVer = 0;
  bool gb46750 = false;

  /// The Basic ID message as it appeared on the wire (slot 0): the
  /// Authentication signature covers these bytes.
  bool hasBasicRaw = false;
  final Uint8List basicRaw = Uint8List(odidMsgSize);

  // Authentication (message type 2). Pages may arrive together in a pack
  // or spread across frames, so [authPagesSeen] is a bitmap of the pages
  // seen (bit N = page N).
  bool hasAuth = false;
  int authType = 0;
  int authLastPage = 0;
  int authLen = 0; // total bytes claimed by page 0
  int authTs = 0;
  int authPagesSeen = 0;
  final Uint8List authData = Uint8List(odidAuthMaxBytes);

  /// True once every page from 0..[authLastPage] has arrived.
  bool get authComplete {
    if (!hasAuth || (authPagesSeen & 1) == 0) return false;
    final want = (1 << (authLastPage + 1)) - 1;
    return (authPagesSeen & want) == want;
  }

  /// True when any message kind was decoded.
  bool get anyDecoded => hasBasic[0] || hasLoc || hasSys || hasSelf || hasOp || hasAuth;
}

// ------------------------------------------------------------ byte readers

int odidRdU16(List<int> p, int o) => (p[o] & 0xFF) | ((p[o + 1] & 0xFF) << 8);

int odidRdI16(List<int> p, int o) {
  final v = odidRdU16(p, o);
  return v >= 0x8000 ? v - 0x10000 : v;
}

int odidRdU32(List<int> p, int o) =>
    (p[o] & 0xFF) | ((p[o + 1] & 0xFF) << 8) | ((p[o + 2] & 0xFF) << 16) | ((p[o + 3] & 0xFF) << 24);

int odidRdI32(List<int> p, int o) {
  final v = odidRdU32(p, o);
  return v >= 0x80000000 ? v - 0x100000000 : v;
}

int _i8(int b) => (b & 0xFF) >= 0x80 ? (b & 0xFF) - 0x100 : b & 0xFF;

/// 0.5 m steps offset by 1000 m; -1000 = unknown.
double odidDecodeAlt(int raw) => raw * 0.5 - 1000.0;

/// A position worth believing: on the globe and outside the band around
/// 0,0 that DJI encoders emit for "no fix" (small non-zero values, open
/// ocean in the Gulf of Guinea). The firmware and the Mac app apply the
/// same rule.
bool odidCoordPlausible(double lat, double lon) {
  if (lat.isNaN || lon.isNaN) return false;
  if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return false;
  if (lat > -5 && lat < 5 && lon > -5 && lon < 5) return false;
  return true;
}

/// Copy a fixed-width ASCII field of [n] bytes at [o]: stop at a NUL, turn
/// anything that would break a JSON string into '.', trim trailing spaces,
/// keep at most [maxLen] characters (odid_copy_text with dstsz = maxLen+1).
String odidCopyText(List<int> src, int o, int n, {int? maxLen}) {
  final cap = maxLen ?? n;
  final out = StringBuffer();
  var count = 0;
  for (var i = 0; i < n && count < cap && o + i < src.length; i++) {
    var c = src[o + i] & 0xFF;
    if (c == 0) break;
    if (c < 0x20 || c > 0x7E || c == 0x22 || c == 0x5C) c = 0x2E;
    out.writeCharCode(c);
    count++;
  }
  var s = out.toString();
  var end = s.length;
  while (end > 0 && s.codeUnitAt(end - 1) == 0x20) {
    end--;
  }
  if (end != s.length) s = s.substring(0, end);
  return s;
}

String _hex20(List<int> p, int o) {
  final b = StringBuffer();
  for (var i = 0; i < 20; i++) {
    b.write((p[o + i] & 0xFF).toRadixString(16).padLeft(2, '0'));
  }
  return b.toString();
}

class OdidDecoder {
  const OdidDecoder._();

  /// Decode one 25-byte message at [o] of [d] into [u] (odid_decode_msg).
  static void decodeMessage(List<int> d, int o, OdidUas u) {
    int m(int i) => d[o + i] & 0xFF;
    final type = m(0) >> 4;
    switch (type) {
      case 0x0: // Basic ID
        var slot = u.hasBasic[0] ? 1 : 0;
        if (u.hasBasic[0] && u.idType[0] == (m(1) >> 4)) slot = 0; // refresh
        u.hasBasic[slot] = true;
        u.idType[slot] = m(1) >> 4;
        u.uaType[slot] = m(1) & 0x0F;
        // UTM UUID (3) and Specific Session ID (4) are binary, not text:
        // hex-encode all 20 bytes rather than let a NUL cut them short.
        if (u.idType[slot] == 3 || u.idType[slot] == 4) {
          u.uasId[slot] = _hex20(d, o + 2);
        } else {
          u.uasId[slot] = odidCopyText(d, o + 2, 20, maxLen: 40);
        }
        if (slot == 0) {
          for (var i = 0; i < odidMsgSize; i++) {
            u.basicRaw[i] = m(i);
          }
          u.hasBasicRaw = true;
        }
      case 0x1: // Location / Vector
        u.hasLoc = true;
        u.status = m(1) >> 4;
        u.heightRef = (m(1) >> 2) & 1;
        final ew = (m(1) >> 1) & 1;
        final mult = m(1) & 1;
        u.dir = m(2) <= 180 ? m(2) + (ew != 0 ? 180.0 : 0.0) : -1.0;
        u.speed = m(3) == 255 ? -1.0 : (mult != 0 ? m(3) * 0.75 + 63.75 : m(3) * 0.25);
        // Raw 126 (+63 m/s) is the spec's invalid marker (range is +/-62).
        u.vspeed = _i8(m(4)) == 126 ? -999.0 : _i8(m(4)) * 0.5;
        u.lat = odidRdI32(d, o + 5) * 1e-7;
        u.lon = odidRdI32(d, o + 9) * 1e-7;
        u.altBaro = odidDecodeAlt(odidRdU16(d, o + 13));
        u.altGeo = odidDecodeAlt(odidRdU16(d, o + 15));
        u.height = odidDecodeAlt(odidRdU16(d, o + 17));
        u.vAcc = m(19) >> 4;
        u.hAcc = m(19) & 0x0F;
        u.baroAcc = m(20) >> 4;
        u.spdAcc = m(20) & 0x0F;
        final ts = odidRdU16(d, o + 21);
        u.ts = ts == 0xFFFF ? -1.0 : ts * 0.1;
        u.tsAcc = m(23) & 0x0F;
      case 0x3: // Self ID
        u.hasSelf = true;
        u.selfType = m(1);
        u.selfDesc = odidCopyText(d, o + 2, 23);
      case 0x4: // System
        u.hasSys = true;
        u.opLocType = m(1) & 0x03;
        u.classType = (m(1) >> 2) & 0x07;
        u.opLat = odidRdI32(d, o + 2) * 1e-7;
        u.opLon = odidRdI32(d, o + 6) * 1e-7;
        u.areaCount = odidRdU16(d, o + 10);
        u.areaRadius = m(12) * 10.0;
        u.areaCeiling = odidDecodeAlt(odidRdU16(d, o + 13));
        u.areaFloor = odidDecodeAlt(odidRdU16(d, o + 15));
        u.catEu = m(17) >> 4;
        u.classEu = m(17) & 0x0F;
        u.opAlt = odidDecodeAlt(odidRdU16(d, o + 18));
        u.sysTs = odidRdU32(d, o + 20);
      case 0x5: // Operator ID
        u.hasOp = true;
        u.opIdType = m(1);
        u.opId = odidCopyText(d, o + 2, 20);
      case 0x2: // Authentication
        final page = m(1) & 0x0F;
        u.hasAuth = true;
        u.authType = m(1) >> 4;
        if (page == 0) {
          // LastPageIndex arrives straight off the air; the page field is 4
          // bits, so 15 is the highest page that can ever be addressed.
          u.authLastPage = m(2) > 15 ? 15 : m(2);
          u.authLen = m(3);
          u.authTs = odidRdU32(d, o + 4);
          final n = u.authLen < 17 ? u.authLen : 17;
          for (var i = 0; i < n; i++) {
            u.authData[i] = m(8 + i);
          }
        } else {
          final off = 17 + (page - 1) * 23;
          var n = 23;
          if (off + n > odidAuthMaxBytes) n = odidAuthMaxBytes - off;
          for (var i = 0; i < n; i++) {
            u.authData[off + i] = m(2 + i);
          }
        }
        u.authPagesSeen |= 1 << page;
      default:
        break; // unknown message types are ignored
    }
  }

  /// Decode a single message, a message pack (type 0xF) or a GB 46750
  /// packet (odid_decode_payload). Returns null when nothing decodes.
  static OdidUas? decodePayload(List<int> d) {
    final u = OdidUas();
    return decodePayloadInto(d, u) ? u : null;
  }

  /// [decodePayload] into a fresh [u]; true when something decoded.
  static bool decodePayloadInto(List<int> d, OdidUas u) {
    final len = d.length;
    if (len < 25) return false;
    final type = (d[0] & 0xFF) >> 4;
    u.protoVer = d[0] & 0x0F;
    var any = false;
    if (type == 0xF) {
      if ((d[0] & 0xFF) == 0xFF) return Gb46750.decode(d, u); // not an ODID pack
      if ((d[1] & 0xFF) != 25) return false;
      var n = d[2] & 0xFF;
      if (n > 9) n = 9;
      for (var i = 0; i < n; i++) {
        final o = 3 + i * 25;
        if (3 + (i + 1) * 25 > len) break;
        if (((d[o] & 0xFF) >> 4) <= 0x5) {
          decodeMessage(d, o, u);
          any = true;
        }
      }
    } else if (type <= 0x5) {
      decodeMessage(d, 0, u);
      any = true;
    }
    return any && u.anyDecoded;
  }
}
