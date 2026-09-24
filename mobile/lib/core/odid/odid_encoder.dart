// odid_encoder.dart — ASTM F3411 / Open Drone ID message encoder, a port of
// firmware/common/odid_build.h (the inverse of odid_decoder.dart). The phone
// never transmits; this exists so tests and simulated sources can build the
// exact bytes the firmware's test beacon sends, and round-trip them through
// the decoder as tests/odid_test.c does.
//
// Everything here builds a TEST payload: the caller supplies the ID.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'odid_decoder.dart' show odidMsgSize;

/// A pack may never carry more messages than this.
const int odidPackMaxMessages = 9;
const int odidAuthPage0Data = 17;
const int odidAuthPageNData = 23;

/// The order a single-message transmitter sends in, as [OdidEncoder.single]
/// indices: Location in every other slot, the four static messages in turn.
const int odidSingleSeqLen = 8;
const List<int> _singleSeq = [1, 0, 1, 2, 1, 3, 1, 4];
int odidSingleSeq(int slot) => _singleSeq[slot % odidSingleSeqLen];

/// Live state a beacon transmits (odid_build.h OdidTxState).
class OdidTxState {
  String? uasId; // serial number (CTA-2063-A style)
  String? caaId; // optional second Basic ID (CAA registration)
  int protoVer; // 0/1 = F3411-19, 2 = F3411-22
  int uaType; // 2 = multirotor
  int status; // 0 undeclared, 1 ground, 2 airborne, 3 emergency
  double lat, lon;
  double altGeoM; // WGS-84 altitude; NaN = unknown
  double heightM; // above take-off
  double speedMs; // horizontal
  double vspeedMs; // + up; NaN -> the "unknown" marker
  double dirDeg; // 0..359 true
  double tsS; // seconds since the hour
  String? selfDesc;
  double opLat, opLon;
  double opAltM;
  String? opId;

  OdidTxState({
    this.uasId,
    this.caaId,
    this.protoVer = 0,
    this.uaType = 0,
    this.status = 0,
    this.lat = 0,
    this.lon = 0,
    this.altGeoM = 0,
    this.heightM = 0,
    this.speedMs = 0,
    this.vspeedMs = 0,
    this.dirDeg = 0,
    this.tsS = 0,
    this.selfDesc,
    this.opLat = 0,
    this.opLon = 0,
    this.opAltM = 0,
    this.opId,
  });
}

class OdidEncoder {
  const OdidEncoder._();

  static void _putU16(Uint8List p, int o, int v) {
    p[o] = v & 0xFF;
    p[o + 1] = (v >> 8) & 0xFF;
  }

  static void _putU32(Uint8List p, int o, int v) {
    p[o] = v & 0xFF;
    p[o + 1] = (v >> 8) & 0xFF;
    p[o + 2] = (v >> 16) & 0xFF;
    p[o + 3] = (v >> 24) & 0xFF;
  }

  /// C's (int32_t) cast of a double: truncation toward zero.
  static void _putI32(Uint8List p, int o, double v) => _putU32(p, o, v.truncate() & 0xFFFFFFFF);

  /// 0.5 m steps with a -1000 m offset; 0 means unknown.
  static int encAlt(double m) {
    if (m.isNaN) return 0;
    var v = (m + 1000.0) * 2.0;
    if (v < 0) v = 0;
    if (v > 65535.0) v = 65535.0;
    return (v + 0.5).truncate();
  }

  static void _putText(Uint8List p, int o, String? s, int n) {
    for (var i = 0; i < n; i++) {
      p[o + i] = 0;
    }
    if (s == null) return;
    final units = s.codeUnits;
    final l = units.length > n ? n : units.length;
    for (var i = 0; i < l; i++) {
      p[o + i] = units[i] & 0xFF;
    }
  }

  /// Header byte: message type in the high nibble, protocol version low.
  static int hdr(int type, OdidTxState s) => ((type << 4) | (s.protoVer & 0x0F)) & 0xFF;

  static Uint8List basicId(OdidTxState s) {
    final m = Uint8List(odidMsgSize);
    m[0] = hdr(0, s);
    m[1] = (1 << 4) | (s.uaType & 0x0F); // ID type 1 = serial
    _putText(m, 2, s.uasId, 20);
    return m;
  }

  /// Second Basic ID carrying a CAA registration number (ID type 2).
  static Uint8List basicIdCaa(OdidTxState s) {
    final m = Uint8List(odidMsgSize);
    m[0] = hdr(0, s);
    m[1] = (2 << 4) | (s.uaType & 0x0F);
    _putText(m, 2, s.caaId ?? '', 20);
    return m;
  }

  static int authPages(int dataLen) {
    if (dataLen <= odidAuthPage0Data) return 1;
    return 1 + (dataLen - odidAuthPage0Data + odidAuthPageNData - 1) ~/ odidAuthPageNData;
  }

  /// One Authentication page. Page 0 carries LastPageIndex (not a count),
  /// the TOTAL length (uint8, saturating), the timestamp and 17 data bytes;
  /// pages 1..15 carry 23 bytes each.
  static Uint8List authPage(OdidTxState s, int authType, int page, List<int>? data, int dataLen, int timestamp) {
    final m = Uint8List(odidMsgSize);
    m[0] = hdr(2, s);
    m[1] = ((authType & 0x0F) << 4) | (page & 0x0F);
    if (page == 0) {
      m[2] = (authPages(dataLen) - 1) & 0xFF;
      m[3] = dataLen > 255 ? 255 : dataLen;
      _putU32(m, 4, timestamp);
      final n = dataLen < odidAuthPage0Data ? dataLen : odidAuthPage0Data;
      if (data != null) {
        for (var i = 0; i < n; i++) {
          m[8 + i] = data[i] & 0xFF;
        }
      }
    } else {
      final off = odidAuthPage0Data + (page - 1) * odidAuthPageNData;
      var n = dataLen - off;
      if (n > odidAuthPageNData) n = odidAuthPageNData;
      if (data != null) {
        for (var i = 0; i < n; i++) {
          m[2 + i] = data[off + i] & 0xFF;
        }
      }
    }
    return m;
  }

  static Uint8List location(OdidTxState s) {
    final m = Uint8List(odidMsgSize);
    m[0] = hdr(1, s);
    var dir = s.dirDeg;
    while (dir < 0) {
      dir += 360.0;
    }
    while (dir >= 360.0) {
      dir -= 360.0;
    }
    final ew = dir >= 180.0 ? 1 : 0;
    // Speeds above 63.75 m/s switch to the coarse 0.75 m/s multiplier.
    final mult = s.speedMs > 63.75 ? 1 : 0;
    int rawSpeed;
    if (s.speedMs < 0 || s.speedMs.isNaN) {
      rawSpeed = 255; // unknown
    } else if (mult != 0) {
      final v = (s.speedMs - 63.75) / 0.75;
      rawSpeed = v < 0 ? 0 : (v > 254 ? 254 : (v + 0.5).truncate());
    } else {
      final v = s.speedMs / 0.25;
      rawSpeed = v > 254 ? 254 : (v + 0.5).truncate();
    }
    m[1] = ((s.status & 0x0F) << 4) | (ew << 1) | mult;
    m[2] = (ew != 0 ? dir - 180.0 : dir).truncate() & 0xFF;
    m[3] = rawSpeed;
    // 0.5 m/s steps, +/-62 m/s at most; 126 is the unknown marker.
    var vs = s.vspeedMs;
    if (!vs.isNaN) vs = vs > 62.0 ? 62.0 : (vs < -62.0 ? -62.0 : vs);
    m[4] = vs.isNaN ? 126 : (vs / 0.5).round() & 0xFF;
    _putI32(m, 5, s.lat * 1e7);
    _putI32(m, 9, s.lon * 1e7);
    _putU16(m, 13, 0); // baro alt unknown
    _putU16(m, 15, encAlt(s.altGeoM));
    _putU16(m, 17, encAlt(s.heightM));
    m[19] = (3 << 4) | 9; // vertical <25 m, horizontal <30 m
    m[20] = (0 << 4) | 1; // baro unknown, speed <10 m/s
    _putU16(m, 21, (s.tsS * 10.0).truncate() & 0xFFFF);
    m[23] = 10; // timestamp accuracy 1.0 s
    return m;
  }

  static Uint8List selfId(OdidTxState s) {
    final m = Uint8List(odidMsgSize);
    m[0] = hdr(3, s);
    m[1] = 0; // text description
    _putText(m, 2, s.selfDesc, 23);
    return m;
  }

  static Uint8List system(OdidTxState s, int sysTs) {
    final m = Uint8List(odidMsgSize);
    m[0] = hdr(4, s);
    m[1] = 0x01; // classification none, operator location = take-off/dynamic
    _putI32(m, 2, s.opLat * 1e7);
    _putI32(m, 6, s.opLon * 1e7);
    _putU16(m, 10, 1); // area count
    m[12] = 0; // area radius
    _putU16(m, 13, 0); // ceiling unknown
    _putU16(m, 15, 0); // floor unknown
    m[17] = 0; // EU category/class undeclared
    _putU16(m, 18, encAlt(s.opAltM));
    // The System timestamp exists only in F3411-22a (protocol v2).
    _putU32(m, 20, s.protoVer >= 2 ? sysTs : 0);
    return m;
  }

  static Uint8List operatorId(OdidTxState s) {
    final m = Uint8List(odidMsgSize);
    m[0] = hdr(5, s);
    m[1] = 0;
    _putText(m, 2, s.opId, 20);
    return m;
  }

  /// A message pack of [messages] (each 25 bytes): 3 + n*25 bytes.
  static Uint8List packOf(OdidTxState s, List<Uint8List> messages) {
    final out = Uint8List(3 + messages.length * odidMsgSize);
    out[0] = hdr(0xF, s);
    out[1] = odidMsgSize;
    out[2] = messages.length;
    for (var i = 0; i < messages.length; i++) {
      out.setRange(3 + i * odidMsgSize, 3 + (i + 1) * odidMsgSize, messages[i]);
    }
    return out;
  }

  /// The 5-message pack (Basic ID, [CAA Basic ID,] Location, Self ID,
  /// System, Operator ID), as odid_build_pack.
  static Uint8List pack(OdidTxState s, int sysTs) => packOf(s, [
        basicId(s),
        if (s.caaId != null && s.caaId!.isNotEmpty) basicIdCaa(s),
        location(s),
        selfId(s),
        system(s, sysTs),
        operatorId(s),
      ]);

  /// One message of the rotating single-message sequence: [idx] selects
  /// Basic ID / Location / Self ID / System / Operator ID.
  static Uint8List single(OdidTxState s, int sysTs, int idx) {
    switch (idx % 5) {
      case 0:
        return basicId(s);
      case 1:
        return location(s);
      case 2:
        return selfId(s);
      case 3:
        return system(s, sysTs);
      default:
        return operatorId(s);
    }
  }
}
