// rid_line.dart — turn a decoded ODID frame into the `rid` line a detector
// would have sent for it, so a frame the phone hears itself flows through
// the same model (messages.dart RidMessage.fromJson) as one relayed by a
// detector. A port of the per-frame half of firmware/common/rx_core.h:
// rx_process (decode, repeat suppression), the auth and SSID parts of
// tracker_ingest, and format_rid (field names, rounding, omissions).
//
// Differences from a detector, all deliberate:
//   * "src" names the phone's own receive path ("phone-ble4", "phone-ble5",
//     "phone-coded", "phone-nan", "phone-beacon"), never a detector's
//     "ble"/"nan"/"wifi", so fusion can tell who heard what.
//   * The Location accuracies ("h_acc", "v_acc", "baro_acc", "spd_acc",
//     "ts_acc") and the System area/class fields are included: messages.dart
//     already reads them, the firmware line just has no room for them yet.
//   * Authentication pages are assembled per transmitter as the firmware
//     does, but the phone does not check Ed25519 signatures: a complete set
//     reports "unverified" ([authStateUnverified]; AuthState.words gives it
//     no badge), a complete set that cannot be an Ed25519 signature (length
//     not 64) "unknown_key", as the firmware says for it. A detector's
//     verdict for the same drone is the one to show.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'odid_decoder.dart';

/// Auth state for a complete signature set the phone has not verified.
const String authStateUnverified = 'unverified';

/// One received frame, before decoding.
class RidFrameIn {
  /// "phone-ble4", "phone-ble5", "phone-coded", "phone-nan", "phone-beacon".
  final String src;

  /// Transmitter address: a MAC ("AA:BB:..."), on iOS the CoreBluetooth
  /// peripheral UUID, for NAN a peer handle ("nan-<id>").
  final String mac;
  final int? rssi;
  final int? channel;

  /// BLE PHY when the platform reports it: "1m", "2m", "coded".
  final String? phy;
  final String? ssid;
  final Uint8List payload;

  const RidFrameIn({
    required this.src,
    required this.mac,
    required this.payload,
    this.rssi,
    this.channel,
    this.phy,
    this.ssid,
  });
}

/// A decoded frame and its line.
class RidLine {
  final OdidUas uas;
  final Map<String, dynamic> json;

  /// False when the same frame from the same source was reported less than
  /// a second ago (the firmware sends such a repeat at most once a second).
  final bool fresh;
  const RidLine(this.uas, this.json, {required this.fresh});
}

/// Fixed-point with [dec] decimals, rounded half away from zero, exactly as
/// the firmware's jfix prints it; null for a non-finite value.
num? ridFix(double v, int dec) {
  if (!v.isFinite || v.abs() > 1e12) return null;
  final p = [1, 10, 100, 1000, 10000, 100000, 1000000, 10000000][dec];
  final neg = v < 0;
  final q = ((neg ? -v : v) * p + 0.5).floor();
  if (dec == 0) return neg && q != 0 ? -q : q;
  final s = '${neg && q != 0 ? '-' : ''}${q ~/ p}.${(q % p).toString().padLeft(dec, '0')}';
  return double.parse(s);
}

class _AuthAssembly {
  bool hasBasicRaw = false;
  final Uint8List basicRaw = Uint8List(odidMsgSize);
  bool hasAuth = false;
  int authType = 0, authLastPage = 0, authLen = 0, authTs = 0, pagesSeen = 0;
  bool complete = false; // the pages held form a complete set
  String state = 'none';
}

class _Contact {
  final _AuthAssembly auth = _AuthAssembly();
  int ssidCheck = 0; // 0 unknown, 1 SSID serial matches Basic ID, 2 differs
  final Map<String, (int, int)> emit = {}; // src -> (hash, ms)
  int lastMs;
  _Contact(this.lastMs);
}

/// Per-transmitter state across frames, as the firmware's track table
/// keeps it: authentication pages, the beacon SSID check, and the last
/// report per source.
class RidLineBuilder {
  /// Transmitters not heard for this long are forgotten.
  final int forgetMs;

  /// At most this many transmitters are remembered (oldest dropped).
  final int maxContacts;

  RidLineBuilder({this.forgetMs = 600000, this.maxContacts = 256});

  final Map<String, _Contact> _contacts = {};

  int get contactCount => _contacts.length;

  void clear() => _contacts.clear();

  /// Decode [f] and build its line; null when the payload does not decode.
  RidLine? build(RidFrameIn f, int nowMs) {
    final u = OdidDecoder.decodePayload(f.payload);
    if (u == null) return null;
    final c = _contact(f.mac, nowMs);
    _ingestAuth(c.auth, u);
    _checkSsid(c, f.ssid, u);

    // FNV-1a over the frame, plus what the contact adds to the line.
    var h = 0x811C9DC5;
    for (final b in f.payload) {
      h = ((h ^ b) * 16777619) & 0xFFFFFFFF;
    }
    h = ((h ^ c.auth.state.hashCode) * 16777619) & 0xFFFFFFFF;
    h = ((h ^ c.ssidCheck) * 16777619) & 0xFFFFFFFF;
    final last = c.emit[f.src];
    final repeat = last != null && last.$1 == h && nowMs - last.$2 < 1000;
    if (!repeat) c.emit[f.src] = (h, nowMs);
    return RidLine(u, _format(f, u, c), fresh: !repeat);
  }

  _Contact _contact(String mac, int nowMs) {
    final c = _contacts[mac];
    if (c != null) {
      c.lastMs = nowMs;
      return c;
    }
    _contacts.removeWhere((_, v) => nowMs - v.lastMs > forgetMs);
    while (_contacts.length >= maxContacts) {
      String? oldest;
      var oldestMs = 0;
      _contacts.forEach((k, v) {
        if (oldest == null || v.lastMs < oldestMs) {
          oldest = k;
          oldestMs = v.lastMs;
        }
      });
      _contacts.remove(oldest);
    }
    return _contacts[mac] = _Contact(nowMs);
  }

  /// tracker_ingest's assembly: a different Basic ID drops everything
  /// collected; page 0 with a new timestamp or type starts a new set; pages
  /// after a complete set belong to the next one.
  static void _ingestAuth(_AuthAssembly a, OdidUas u) {
    var changed = false;
    if (u.hasBasicRaw) {
      if (a.hasBasicRaw && !_same(a.basicRaw, u.basicRaw)) {
        a
          ..hasAuth = false
          ..pagesSeen = 0
          ..complete = false
          ..state = 'none';
        a.hasBasicRaw = false;
      }
      if (!a.hasBasicRaw) {
        a.hasBasicRaw = true;
        a.basicRaw.setAll(0, u.basicRaw);
        changed = true;
      }
    }
    if (u.hasAuth) {
      if ((u.authPagesSeen & 1) != 0) {
        if ((a.pagesSeen & 1) != 0 && (a.authTs != u.authTs || a.authType != u.authType)) {
          a.pagesSeen = 0;
          a.complete = false;
        }
        a
          ..authType = u.authType
          ..authLastPage = u.authLastPage
          ..authLen = u.authLen
          ..authTs = u.authTs;
      } else if (a.complete) {
        a.pagesSeen = 0;
        a.complete = false;
      }
      a.hasAuth = true;
      a.pagesSeen |= u.authPagesSeen;
      changed = true;
    }
    if (a.hasAuth) {
      // Hand the assembled picture back so the line reports it.
      u
        ..hasAuth = true
        ..authType = a.authType
        ..authLastPage = a.authLastPage
        ..authLen = a.authLen
        ..authTs = a.authTs
        ..authPagesSeen = a.pagesSeen;
      if (changed) {
        var v = _verdict(u, a);
        if (v != 'partial' && v != 'none') a.complete = true;
        // While the next set is still arriving, keep the verdict of the last
        // complete one rather than flapping back to "partial".
        if (v == 'partial' && a.state != 'none' && a.state != 'partial') v = a.state;
        a.state = v;
      }
    }
  }

  /// odid_verify_auth without the signature check.
  static String _verdict(OdidUas u, _AuthAssembly a) {
    if (!u.hasAuth) return 'none';
    if (!u.authComplete) return 'partial';
    if (u.authLen != 64) return 'unknown_key'; // not an Ed25519 signature
    if (!a.hasBasicRaw) return 'partial'; // nothing to bind to
    return authStateUnverified;
  }

  static bool _same(List<int> a, List<int> b) {
    for (var i = 0; i < odidMsgSize; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// DJI puts "RID-" + serial in the SSID: an SSID serial that disagrees
  /// with the Basic ID is a broadcast at odds with itself.
  static void _checkSsid(_Contact c, String? ssid, OdidUas u) {
    if (ssid == null || ssid.isEmpty) return;
    final sl = ssid.length;
    if (ssid.startsWith('RID-') && sl >= 8 && sl <= 24 && u.hasBasic[0] && u.idType[0] == 1) {
      final alnum = RegExp(r'^[0-9A-Za-z]+$').hasMatch(ssid.substring(4));
      if (alnum) c.ssidCheck = ssid.substring(4) == u.uasId[0] ? 1 : 2;
    }
  }

  static Map<String, dynamic> _format(RidFrameIn f, OdidUas u, _Contact c) {
    final j = <String, dynamic>{'type': 'rid', 'src': f.src, 'mac': f.mac};
    if (f.rssi != null) j['rssi'] = f.rssi;
    if (f.channel != null && f.channel != 0) j['ch'] = f.channel;
    if (f.phy != null) j['phy'] = f.phy;
    if (u.gb46750) {
      j['fmt'] = 'gb46750';
    } else {
      j['proto'] = u.protoVer;
    }
    if (f.ssid != null && f.ssid!.isNotEmpty) {
      j['ssid'] = odidCopyText(f.ssid!.codeUnits, 0, f.ssid!.length, maxLen: 32);
      if (c.ssidCheck != 0) j['ssid_id_match'] = c.ssidCheck == 1;
    }
    if (u.hasBasic[0] || u.hasBasic[1]) {
      j['basic_id'] = [
        for (var i = 0; i < 2; i++)
          if (u.hasBasic[i]) {'id_type': u.idType[i], 'ua_type': u.uaType[i], 'uas_id': u.uasId[i]},
      ];
    }
    if (u.hasLoc) {
      j['loc'] = {
        'status': u.status,
        'lat': ridFix(u.lat, 7),
        'lon': ridFix(u.lon, 7),
        'alt_geo': ridFix(u.altGeo, 1),
        'alt_baro': ridFix(u.altBaro, 1),
        'height': ridFix(u.height, 1),
        'height_ref': u.heightRef,
        'speed': ridFix(u.speed, 2),
        'dir': ridFix(u.dir, 0),
        'ts': ridFix(u.ts, 1),
        if (u.vspeed > -900) 'vspeed': ridFix(u.vspeed, 2),
        'h_acc': u.hAcc,
        'v_acc': u.vAcc,
        'baro_acc': u.baroAcc,
        'spd_acc': u.spdAcc,
        'ts_acc': u.tsAcc,
      };
    }
    if (u.hasSelf) j['self_id'] = {'desc_type': u.selfType, 'desc': u.selfDesc};
    if (u.hasSys) {
      j['system'] = {
        'op_lat': ridFix(u.opLat, 7),
        'op_lon': ridFix(u.opLon, 7),
        'op_alt': ridFix(u.opAlt, 1),
        'op_loc_type': u.opLocType,
        'area_count': u.areaCount,
        'ts': u.sysTs,
        if (!u.gb46750) ...{
          'area_radius': ridFix(u.areaRadius, 0),
          'area_ceiling': ridFix(u.areaCeiling, 1),
          'area_floor': ridFix(u.areaFloor, 1),
          'class_type': u.classType,
          'cat_eu': u.catEu,
          'class_eu': u.classEu,
        },
      };
    }
    if (u.hasOp) j['op_id'] = {'id_type': u.opIdType, 'id': u.opId};
    if (u.hasAuth) {
      j['auth'] = {'type': u.authType, 'len': u.authLen, 'pages': u.authLastPage + 1, 'state': c.auth.state};
    }
    return j;
  }
}
