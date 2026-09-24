// messages.dart — Host JSON lines, as the firmware writes them
// (firmware/common/rx_core.h format_rid / format_log_rec / emit_log, the
// device-info characteristic in ble_link.h) and as the Mac app reads them
// (app/Sources/Orecchino/RidMessage.swift).
//
// A missing field is unknown and is null here, never zero. The firmware's
// "unknown" markers are turned into null at parse time, exactly as the Mac
// app (AppModel.swift) filters them: altitudes <= -999 (the ODID -1000),
// speed < 0 (255 -> -1), direction outside 0..360 (-1), a position in the
// band around 0,0 that encoders send for "no fix", a timestamp < 0.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import '../geo.dart';

double? _num(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
int? _int(Object? v) => v is num && v.isFinite ? v.toInt() : null;
String? _str(Object? v) => v is String ? v : null;
bool? _bool(Object? v) => v is bool ? v : null;
Map<String, dynamic>? _map(Object? v) => v is Map<String, dynamic> ? v : null;

/// A 4-bit ODID code (0..15), else null.
int? _code(Object? v) {
  final i = _int(v);
  return i != null && i >= 0 && i <= 15 ? i : null;
}

/// An altitude, or null for the ODID "unknown" (-1000) and anything <= -999.
double? _alt(Object? v) {
  final d = _num(v);
  return d != null && d > -999 ? d : null;
}

sealed class HostMessage {
  final String type;
  const HostMessage(this.type);

  static HostMessage? parse(String line) {
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, dynamic>) return null;
      final json = decoded;
      final type = json['type'];
      switch (type) {
        case 'hb':
          return HeartbeatMessage.fromJson(json);
        case 'rid':
          return RidMessage.fromJson(json);
        case 'log':
          return LogRecordMessage.fromJson(json);
        case 'log_done':
          return LogDoneMessage.fromJson(json);
        case 'log_cleared':
          return const LogClearedMessage();
        case 'feed_status':
          return FeedStatusMessage(_bool(json['on']) ?? false);
        case 'info':
          return DeviceInfoMessage.fromJson(json);
        case 'wifi_net':
          return WifiNetMessage.fromJson(json);
        case 'wifi_scan_done':
          return WifiScanDoneMessage.fromJson(json);
        case 'wifi_status':
          return WifiStatusMessage.fromJson(json);
        case 'wifi_err':
          return WifiErrorMessage(command: _str(json['cmd']) ?? '', reason: _str(json['reason']) ?? 'refused');
        case 'net':
          return NetStatusMessage.fromJson(json);
        default:
          return GenericHostMessage(type is String ? type : 'unknown', json);
      }
    } catch (_) {
      return null;
    }
  }
}

class HeartbeatMessage extends HostMessage {
  final int uptimeMs;
  final int? wifiFrames;
  final int? bleAdvs;
  final int? ridCount;
  final int? dropped;
  final int? channel;
  final bool? bleActive;
  final bool? bleExtActive;
  final int? bleDrops;

  const HeartbeatMessage({
    required this.uptimeMs,
    this.wifiFrames,
    this.bleAdvs,
    this.ridCount,
    this.dropped,
    this.channel,
    this.bleActive,
    this.bleExtActive,
    this.bleDrops,
  }) : super('hb');

  factory HeartbeatMessage.fromJson(Map<String, dynamic> json) {
    return HeartbeatMessage(
      uptimeMs: _int(json['up']) ?? 0,
      wifiFrames: _int(json['wifi_frames']),
      bleAdvs: _int(json['ble_advs']),
      ridCount: _int(json['rid']),
      dropped: _int(json['dropped']),
      channel: _int(json['ch']),
      bleActive: _bool(json['ble']),
      bleExtActive: _bool(json['ble_ext']),
      bleDrops: _int(json['ble_drop']),
    );
  }
}

class RidLocation {
  final int? status; // 3 = emergency
  final double? lat;
  final double? lon;
  final double? altGeo; // geodetic (WGS-84 ellipsoid), metres
  final double? altBaro;
  final double? height; // above [heightRef]
  final int? heightRef; // 0 = take-off, 1 = ground
  final double? speed; // m/s
  final double? dir; // degrees true
  final double? vspeed; // m/s, omitted by the firmware when unknown
  final double? timestamp; // seconds past the hour, 0.1 s

  /// ODID accuracy codes (F3411 enums; 0 = unknown). The decoder has them;
  /// the firmware's rid line does not carry them yet, so they are null
  /// unless a receiver sends "h_acc", "v_acc", "baro_acc", "spd_acc",
  /// "ts_acc".
  final int? hAcc, vAcc, baroAcc, spdAcc, tsAcc;

  const RidLocation({
    this.status,
    this.lat,
    this.lon,
    this.altGeo,
    this.altBaro,
    this.height,
    this.heightRef,
    this.speed,
    this.dir,
    this.vspeed,
    this.timestamp,
    this.hAcc,
    this.vAcc,
    this.baroAcc,
    this.spdAcc,
    this.tsAcc,
  });

  bool get hasPosition => lat != null && lon != null;

  factory RidLocation.fromJson(Map<String, dynamic> json) {
    final lat = _num(json['lat']), lon = _num(json['lon']);
    final ok = Geo.validCoord(lat, lon);
    final speed = _num(json['speed']);
    final dir = _num(json['dir']);
    final ref = _int(json['height_ref']);
    final ts = _num(json['ts']);
    final vs = _num(json['vspeed']);
    return RidLocation(
      status: _int(json['status']),
      lat: ok ? lat : null,
      lon: ok ? lon : null,
      altGeo: _alt(json['alt_geo']),
      altBaro: _alt(json['alt_baro']),
      height: _alt(json['height']),
      heightRef: ref != null && ref >= 0 && ref <= 1 ? ref : null,
      speed: speed != null && speed >= 0 ? speed : null,
      dir: dir != null && dir >= 0 && dir <= 360 ? dir : null,
      vspeed: vs != null && vs > -900 ? vs : null,
      timestamp: ts != null && ts >= 0 ? ts : null,
      hAcc: _code(json['h_acc']),
      vAcc: _code(json['v_acc']),
      baroAcc: _code(json['baro_acc']),
      spdAcc: _code(json['spd_acc']),
      tsAcc: _code(json['ts_acc']),
    );
  }
}

class RidBasicId {
  final int idType;
  final int uaType;
  final String uasId;

  const RidBasicId({required this.idType, required this.uaType, required this.uasId});

  factory RidBasicId.fromJson(Map<String, dynamic> json) {
    return RidBasicId(
      idType: _int(json['id_type']) ?? 0,
      uaType: _int(json['ua_type']) ?? 0,
      uasId: _str(json['uas_id']) ?? '',
    );
  }
}

class RidSelfId {
  final int descType;
  final String text;

  const RidSelfId({required this.descType, required this.text});

  factory RidSelfId.fromJson(Map<String, dynamic> json) {
    return RidSelfId(
      descType: _int(json['desc_type']) ?? 0,
      text: _str(json['desc']) ?? _str(json['text']) ?? '',
    );
  }
}

class RidSystem {
  final double? operatorLat;
  final double? operatorLon;
  final double? operatorAltGeo;
  final int? operatorLocType;
  final int? areaCount;
  final int? timestamp; // seconds since 2019-01-01 00:00 UTC

  /// The operating area and the EU classification (firmware 0.7+): null
  /// when not sent. "area_radius" (m), "area_ceiling", "area_floor" (m;
  /// absent or -1000 when unknown), "class_type" (1 = EU), "cat_eu" (1
  /// Open, 2 Specific, 3 Certified), "class_eu" (1-7 = C0-C6).
  final double? areaRadius, areaCeiling, areaFloor;
  final int? classType, catEu, classEu;

  const RidSystem({
    this.operatorLat,
    this.operatorLon,
    this.operatorAltGeo,
    this.operatorLocType,
    this.areaCount,
    this.timestamp,
    this.areaRadius,
    this.areaCeiling,
    this.areaFloor,
    this.classType,
    this.catEu,
    this.classEu,
  });

  factory RidSystem.fromJson(Map<String, dynamic> json) {
    final lat = _num(json['op_lat']), lon = _num(json['op_lon']);
    final ok = Geo.validCoord(lat, lon);
    return RidSystem(
      operatorLat: ok ? lat : null,
      operatorLon: ok ? lon : null,
      operatorAltGeo: _alt(json['op_alt']),
      operatorLocType: _int(json['op_loc_type']),
      areaCount: _int(json['area_count']),
      timestamp: _int(json['ts']),
      areaRadius: _num(json['area_radius']),
      areaCeiling: _alt(json['area_ceiling']),
      areaFloor: _alt(json['area_floor']),
      classType: _code(json['class_type']),
      catEu: _code(json['cat_eu']),
      classEu: _code(json['class_eu']),
    );
  }
}

class RidOperatorId {
  final int opIdType;
  final String opId;

  const RidOperatorId({required this.opIdType, required this.opId});

  factory RidOperatorId.fromJson(Map<String, dynamic> json) {
    return RidOperatorId(
      opIdType: _int(json['id_type']) ?? 0,
      opId: _str(json['id']) ?? '',
    );
  }
}

/// Authentication verdict names (odid_verify.h odid_auth_state_name).
class AuthState {
  static const none = 'none';
  static const partial = 'partial';
  static const unknownKey = 'unknown_key';
  static const idValid = 'id_valid';
  static const invalid = 'invalid';
  static const testKey = 'test_key';

  /// Words for a badge, or null when there is nothing to say. `id_valid`
  /// means the ID was signed, never that the position is trustworthy;
  /// `test_key` proves nothing and is shown neutrally.
  static String? words(String? s) {
    switch (s) {
      case invalid:
        return 'ID SIGNATURE INVALID';
      case idValid:
        return 'ID SIGNED';
      case testKey:
        return 'TEST KEY';
      case unknownKey:
        return 'SIGNED, UNKNOWN KEY';
      default:
        return null;
    }
  }
}

class RidAuth {
  final int? authType;
  final int? length;
  final int? pages;
  final String state;

  /// Page 0's timestamp, seconds since 2019-01-01 00:00 UTC ("auth_ts";
  /// firmware 0.7+, once page 0 of the set held has arrived).
  final int? authTs;

  const RidAuth({this.authType, this.length, this.pages, required this.state, this.authTs});

  /// [authTs] as a time.
  DateTime? get signedAt =>
      authTs == null || authTs! <= 0 ? null : DateTime.utc(2019).add(Duration(seconds: authTs!));

  factory RidAuth.fromJson(Map<String, dynamic> json) => RidAuth(
        authType: _int(json['type']),
        length: _int(json['len']),
        pages: _int(json['pages']),
        state: _str(json['state']) ?? AuthState.none,
        authTs: _int(json['auth_ts']),
      );
}

class RidMessage extends HostMessage {
  final String src;
  final String mac;
  final int? rssi;
  final int? channel;
  final String? phy;
  final String? fmt;
  final int? proto;
  final String? ssid;
  final bool? ssidIdMatch;
  final List<RidBasicId> basicId;
  final RidLocation? loc;
  final RidSelfId? selfId;
  final RidSystem? system;
  final RidOperatorId? operatorId;
  final RidAuth? auth;

  /// Inside a TFR a host pushed (tfr_add), and which ("in_tfr", "tfr_id";
  /// firmware 0.7+). Null when the detector has no TFRs, or no position.
  final bool? inTfr;
  final String? tfrId;

  const RidMessage({
    required this.src,
    required this.mac,
    this.rssi,
    this.channel,
    this.phy,
    this.fmt,
    this.proto,
    this.ssid,
    this.ssidIdMatch,
    this.basicId = const [],
    this.loc,
    this.selfId,
    this.system,
    this.operatorId,
    this.auth,
    this.inTfr,
    this.tfrId,
  }) : super('rid');

  String? get primaryUasId {
    for (final b in basicId) {
      if (b.uasId.isNotEmpty) return b.uasId;
    }
    return null;
  }

  /// ODID status 3: the aircraft reports an emergency.
  bool get emergency => loc?.status == 3;
  String? get authState => auth?.state;

  factory RidMessage.fromJson(Map<String, dynamic> json) {
    final basicList = <RidBasicId>[];
    final b = json['basic_id'];
    if (b is List) {
      for (final item in b) {
        if (item is Map<String, dynamic>) basicList.add(RidBasicId.fromJson(item));
      }
    }
    final loc = _map(json['loc']);
    final self = _map(json['self_id']);
    final sys = _map(json['system']) ?? _map(json['sys']);
    final op = _map(json['op_id']);
    final auth = _map(json['auth']);
    return RidMessage(
      src: _str(json['src']) ?? 'unknown',
      mac: _str(json['mac']) ?? '',
      rssi: _int(json['rssi']),
      channel: _int(json['ch']),
      phy: _str(json['phy']),
      fmt: _str(json['fmt']),
      proto: _int(json['proto']),
      ssid: _str(json['ssid']),
      ssidIdMatch: _bool(json['ssid_id_match']),
      basicId: basicList,
      loc: loc == null ? null : RidLocation.fromJson(loc),
      selfId: self == null ? null : RidSelfId.fromJson(self),
      system: sys == null ? null : RidSystem.fromJson(sys),
      operatorId: op == null ? null : RidOperatorId.fromJson(op),
      auth: auth == null ? null : RidAuth.fromJson(auth),
      inTfr: _bool(json['in_tfr']),
      tfrId: _str(json['tfr_id']),
    );
  }
}

/// One match-log record. An ended contact has a [seq] (final); a contact
/// still live has `"seq":null` and `"active":true` and gets its number
/// only when it ends.
class LogRecordMessage extends HostMessage {
  final int? seq;
  final bool active;
  final String? uasId;
  final String mac;
  final int? sources;
  final int? formats;
  final int? uaType;
  final int firstUtc;
  final int lastUtc;
  final int durationS;
  final double? lat;
  final double? lon;
  final double? maxHeightM;
  final int? peakRssi;
  final String authState;

  /// Inside a pushed TFR at some point ("tfr").
  final bool tfrEver;

  /// Inside it at the end (live: now) ("in_tfr"; null from firmware before
  /// 0.7), and the TFR's id ("tfr_id").
  final bool? inTfrNow;
  final String? tfrId;

  /// The EU classification ("class_type", "cat_eu", "class_eu"), as in
  /// [RidSystem].
  final int? classType, catEu, classEu;
  final bool emergency;
  final int msgCount;

  const LogRecordMessage({
    this.seq,
    this.active = false,
    this.uasId,
    required this.mac,
    this.sources,
    this.formats,
    this.uaType,
    required this.firstUtc,
    required this.lastUtc,
    required this.durationS,
    this.lat,
    this.lon,
    this.maxHeightM,
    this.peakRssi,
    this.authState = AuthState.none,
    this.tfrEver = false,
    this.inTfrNow,
    this.tfrId,
    this.classType,
    this.catEu,
    this.classEu,
    this.emergency = false,
    this.msgCount = 0,
  }) : super('log');

  /// The contact's key when it has no seq yet: its UAS ID, else its MAC.
  String get contactKey => (uasId != null && uasId!.isNotEmpty) ? uasId! : mac;

  factory LogRecordMessage.fromJson(Map<String, dynamic> json) {
    final uas = _str(json['uas']) ?? _str(json['uas_id']);
    final lat = _num(json['lat']), lon = _num(json['lon']);
    final ok = Geo.validCoord(lat, lon);
    final seq = _int(json['seq']) ?? _int(json['i']);
    final auth = json['auth_state'];
    return LogRecordMessage(
      seq: seq,
      active: _bool(json['active']) ?? (json.containsKey('seq') && json['seq'] == null),
      uasId: (uas == null || uas.isEmpty) ? null : uas,
      mac: _str(json['mac']) ?? '',
      sources: _int(json['srcs']),
      formats: _int(json['fmts']),
      uaType: _int(json['ua_type']),
      firstUtc: _int(json['first']) ?? _int(json['first_utc']) ?? 0,
      lastUtc: _int(json['last']) ?? _int(json['last_utc']) ?? 0,
      durationS: _int(json['dur']) ?? _int(json['dur_s']) ?? 0,
      lat: ok ? lat : null,
      lon: ok ? lon : null,
      maxHeightM: _num(json['max_h']),
      peakRssi: _int(json['peak_rssi']),
      authState: auth is String ? auth : AuthState.none,
      tfrEver: _bool(json['tfr']) ?? false,
      inTfrNow: _bool(json['in_tfr']),
      tfrId: _str(json['tfr_id']),
      classType: _code(json['class_type']),
      catEu: _code(json['cat_eu']),
      classEu: _code(json['class_eu']),
      emergency: _bool(json['emerg']) ?? false,
      msgCount: _int(json['msgs']) ?? 0,
    );
  }
}

/// End of a log_get answer. [next] is the cursor to send as `since` next
/// time (= [total]; live contacts are not counted); [oldest] the lowest seq
/// still held. A cursor above [total] means the log was cleared.
class LogDoneMessage extends HostMessage {
  final int count; // records held
  final int? live;
  final int? total;
  final bool? clock;
  final int? nextSeq;
  final int? oldestSeq;

  const LogDoneMessage({
    required this.count,
    this.live,
    this.total,
    this.clock,
    this.nextSeq,
    this.oldestSeq,
  }) : super('log_done');

  factory LogDoneMessage.fromJson(Map<String, dynamic> json) {
    return LogDoneMessage(
      count: _int(json['n']) ?? 0,
      live: _int(json['live']),
      total: _int(json['total']),
      clock: _bool(json['clock']),
      nextSeq: _int(json['next']),
      oldestSeq: _int(json['oldest']),
    );
  }
}

class LogClearedMessage extends HostMessage {
  const LogClearedMessage() : super('log_cleared');
}

class FeedStatusMessage extends HostMessage {
  final bool on;
  const FeedStatusMessage(this.on) : super('feed_status');
}

/// The device-info characteristic (ble_link.h), readable before pairing:
/// `{"fw":"orecchino","ver":"0.6.0","board":"...","caps":[...],"proto":1}`.
class DeviceInfoMessage extends HostMessage {
  final String board;
  final String firmware;
  final String version;
  final List<String> capabilities;
  final int? proto;

  const DeviceInfoMessage({
    required this.board,
    required this.firmware,
    required this.version,
    required this.capabilities,
    this.proto,
  }) : super('info');

  bool has(String cap) => capabilities.contains(cap);

  /// True for an Orecchino board speaking a protocol this app knows.
  bool get isOrecchino => firmware == 'orecchino' && (proto ?? 0) >= 1;

  factory DeviceInfoMessage.fromJson(Map<String, dynamic> json) {
    final caps = <String>[];
    final c = json['caps'];
    if (c is List) {
      for (final x in c) {
        if (x is String) caps.add(x);
      }
    }
    return DeviceInfoMessage(
      board: _str(json['board']) ?? 'unknown',
      firmware: _str(json['fw']) ?? '',
      version: _str(json['ver']) ?? '',
      capabilities: caps,
      proto: _int(json['proto']),
    );
  }

  /// Parses the characteristic's bytes; null when they are not the JSON
  /// object above.
  static DeviceInfoMessage? fromBytes(List<int> bytes) {
    try {
      final v = jsonDecode(utf8.decode(bytes));
      return v is Map<String, dynamic> ? DeviceInfoMessage.fromJson(v) : null;
    } catch (_) {
      return null;
    }
  }
}

// Wi-Fi provisioning on a T5 (firmware/common/net_sync.h, "HOST COMMANDS").

class WifiNetMessage extends HostMessage {
  final String ssid;
  final int? rssi;
  final bool secure;
  final bool saved;
  final int? channel;

  const WifiNetMessage({required this.ssid, this.rssi, required this.secure, this.saved = false, this.channel})
      : super('wifi_net');

  factory WifiNetMessage.fromJson(Map<String, dynamic> json) {
    return WifiNetMessage(
      ssid: _str(json['ssid']) ?? '',
      rssi: _int(json['rssi']),
      secure: _bool(json['secure']) ?? false,
      saved: _bool(json['saved']) ?? false,
      channel: _int(json['ch']),
    );
  }
}

/// A wifi_* command the board refused: {"type":"wifi_err","cmd","reason"}.
class WifiErrorMessage extends HostMessage {
  final String command;
  final String reason;
  const WifiErrorMessage({required this.command, required this.reason}) : super('wifi_err');
}

class WifiScanDoneMessage extends HostMessage {
  final int count;
  final String? error;
  const WifiScanDoneMessage(this.count, {this.error}) : super('wifi_scan_done');

  factory WifiScanDoneMessage.fromJson(Map<String, dynamic> json) {
    return WifiScanDoneMessage(_int(json['n']) ?? 0, error: _str(json['err']));
  }
}

/// Wi-Fi state on a T5: `state` is off | idle | connecting | connected |
/// failed, with the reason for a failure in words (wrong password, network
/// not found, no IP address, timed out, could not connect, cancelled).
class WifiStatusMessage extends HostMessage {
  final String state;
  final String? reason;
  final String? ssid;
  final String? ip;
  final int? channel;
  final int? rssi;
  final String? mode; // off | sync | stay
  final int? everyMin;
  final bool scanning;
  final bool syncing;
  final int? lastSyncUtc;
  final List<String> saved;

  /// "phone" while a connected phone pauses the automatic Wi-Fi windows.
  final String? paused;
  final int? adsbKm; // the T5's ADS-B radius setting (5-30)
  final int? tileKm; // its map area radius setting
  final double? tileMaxKm; // the largest map radius its flash holds (from the last plan)

  const WifiStatusMessage({
    required this.state,
    this.reason,
    this.ssid,
    this.ip,
    this.channel,
    this.rssi,
    this.mode,
    this.everyMin,
    this.scanning = false,
    this.syncing = false,
    this.lastSyncUtc,
    this.saved = const [],
    this.paused,
    this.adsbKm,
    this.tileKm,
    this.tileMaxKm,
  }) : super('wifi_status');

  bool get pausedByPhone => paused == 'phone';

  factory WifiStatusMessage.fromJson(Map<String, dynamic> json) {
    final saved = <String>[];
    final s = json['saved'];
    if (s is List) {
      for (final x in s) {
        if (x is String) saved.add(x);
      }
    }
    return WifiStatusMessage(
      state: _str(json['state']) ?? 'idle',
      reason: _str(json['reason']),
      ssid: _str(json['ssid']),
      ip: _str(json['ip']),
      channel: _int(json['ch']),
      rssi: _int(json['rssi']),
      mode: _str(json['mode']),
      everyMin: _int(json['every_min']),
      scanning: _bool(json['scanning']) ?? false,
      syncing: _bool(json['syncing']) ?? false,
      lastSyncUtc: _int(json['last_sync']),
      saved: saved,
      paused: _str(json['paused']),
      adsbKm: _int(json['adsb_km']),
      tileKm: _int(json['tile_km']),
      tileMaxKm: _num(json['tile_max_km']),
    );
  }
}

/// A T5's broadcast Wi-Fi status line (net_sync.h "BROADCAST STATUS
/// LINES"): {"type":"net","state":"paused","reason":"phone"} / "resumed" /
/// "synced" (+ "map": "Map: 3 km z12-15; 0.8 MB of 11.9 MB", "tile_max_km")
/// and others; only what the app shows is kept.
class NetStatusMessage extends HostMessage {
  final String state;
  final String? reason;
  final String? map;
  final double? tileMaxKm;
  final bool storageFull;

  const NetStatusMessage({required this.state, this.reason, this.map, this.tileMaxKm, this.storageFull = false})
      : super('net');

  factory NetStatusMessage.fromJson(Map<String, dynamic> json) => NetStatusMessage(
        state: _str(json['state']) ?? '',
        reason: _str(json['reason']),
        map: _str(json['map']),
        tileMaxKm: _num(json['tile_max_km']),
        storageFull: _bool(json['storage_full']) ?? false,
      );
}

class GenericHostMessage extends HostMessage {
  final Map<String, dynamic> raw;
  const GenericHostMessage(super.type, this.raw);
}
