// contact_tracker.dart — live drone contacts from `rid` lines, with the
// Mac app's rules (app/Sources/Orecchino/AppModel.swift):
// - a contact is keyed by its UAS ID, else its MAC; a MAC seen with an ID
//   later is merged into that ID's contact;
// - unknown values stay unknown (messages.dart turns the firmware's markers
//   into null): each Location message replaces the heights, speed and
//   heading, so a reported "unknown" is never covered by an older value;
//   only the position is kept when a message carries none (as the Mac does);
// - stale after 60 s, removed after 600 s;
// - the emergency flag is ODID status 3; heights keep their reference;
//   alt_geo is kept apart (it is what the traffic rules compare).
// Range and bearing are from the observer (the phone), and only when the
// observer's position is known: there is no stand-in position.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import '../geo.dart';
import '../protocol/messages.dart';

class Contact {
  final String key;
  String? uasId;
  final Set<String> macs = {};
  final Set<String> sources = {};
  int firstSeenMs;
  int lastSeenMs;
  int? rssi;
  double? lat, lon;
  int? posMs; // when the position was reported
  double? altGeoM;
  double? heightM;
  int? heightRef;
  double? speedMps;
  double? headingDeg;
  double? vspeedMps;
  double? opLat, opLon;
  String? operatorId;
  String? selfDesc;
  bool emergency = false;
  String? authState;

  // Range from the observer, and its rate of change.
  double? rangeM;
  double? bearingDeg;
  double? rangeRateMps;
  double? _prevRange;
  int? _prevRangeMs;

  Contact(this.key, int nowMs)
      : firstSeenMs = nowMs,
        lastSeenMs = nowMs;

  bool get hasPosition => lat != null && lon != null;
  String get label => uasId ?? (macs.isNotEmpty ? macs.first : key);
  double ageS(int nowMs) => (nowMs - lastSeenMs).clamp(0, 1 << 62) / 1000.0;

  /// "above T/O", "AGL", or null when the reference is unknown.
  String? get heightRefShort => switch (heightRef) { 0 => 'above T/O', 1 => 'AGL', _ => null };

  /// Closing faster than 0.5 m/s: true; opening: false; unknown: null.
  bool? get closing {
    final r = rangeRateMps;
    if (r == null) return null;
    if (r < -0.5) return true;
    if (r > 0.5) return false;
    return null;
  }

  bool get isAuthInvalid => authState == AuthState.invalid;
}

class ObserverFix {
  final double lat, lon;
  const ObserverFix(this.lat, this.lon);
}

class ContactTracker {
  static const staleAfterS = 60.0;
  static const expireAfterS = 600.0;

  final Map<String, Contact> _contacts = {};
  final Map<String, String> _macIndex = {};

  List<Contact> get contacts => _contacts.values.toList()..sort((a, b) => a.firstSeenMs.compareTo(b.firstSeenMs));
  Contact? operator [](String key) => _contacts[key];
  int get length => _contacts.length;

  static bool isStale(Contact c, int nowMs) => c.ageS(nowMs) > staleAfterS;

  void clear() {
    _contacts.clear();
    _macIndex.clear();
  }

  /// Ingest one rid line at [nowMs]; [observer] is the phone's position
  /// (null when unknown). Returns the contact it updated.
  Contact? ingest(RidMessage msg, int nowMs, ObserverFix? observer) {
    final uas = msg.primaryUasId;
    final mac = msg.mac;
    if ((uas == null || uas.isEmpty) && mac.isEmpty) return null;
    String key;
    if (uas != null && uas.isNotEmpty) {
      key = uas;
      // A contact first heard by MAC only: fold it into the ID's contact.
      final prior = _macIndex[mac];
      if (prior != null && prior != key && _contacts.containsKey(prior) && !_contacts.containsKey(key)) {
        final c = _contacts.remove(prior)!;
        final merged = Contact(key, c.firstSeenMs).._copyFrom(c);
        _contacts[key] = merged;
        _macIndex.updateAll((_, v) => v == prior ? key : v);
      }
    } else {
      key = _macIndex[mac] ?? mac;
    }
    final c = _contacts.putIfAbsent(key, () => Contact(key, nowMs));
    if (mac.isNotEmpty) {
      c.macs.add(mac);
      _macIndex[mac] = key;
    }
    if (uas != null && uas.isNotEmpty) c.uasId = uas;
    c.sources.add(msg.src);
    c.lastSeenMs = nowMs;
    if (msg.rssi != null) c.rssi = msg.rssi;

    final l = msg.loc;
    if (l != null) {
      c.emergency = l.status == 3;
      if (l.hasPosition) {
        c.lat = l.lat;
        c.lon = l.lon;
        c.posMs = nowMs;
      }
      c.altGeoM = l.altGeo;
      c.heightM = l.height;
      c.heightRef = l.heightRef;
      c.speedMps = l.speed;
      c.headingDeg = l.dir;
      c.vspeedMps = l.vspeed;
    }
    final s = msg.system;
    if (s != null && s.operatorLat != null && s.operatorLon != null) {
      c.opLat = s.operatorLat;
      c.opLon = s.operatorLon;
    }
    final op = msg.operatorId;
    if (op != null && op.opId.isNotEmpty) c.operatorId = op.opId;
    if (msg.selfId != null && msg.selfId!.text.isNotEmpty) c.selfDesc = msg.selfId!.text;
    if (msg.auth != null) c.authState = msg.auth!.state;
    _range(c, nowMs, observer);
    return c;
  }

  /// Recompute range and bearing for every contact (the observer moved).
  void updateObserver(ObserverFix? observer, int nowMs) {
    for (final c in _contacts.values) {
      _range(c, nowMs, observer, rate: false);
    }
  }

  void _range(Contact c, int nowMs, ObserverFix? o, {bool rate = true}) {
    if (o == null || !c.hasPosition) {
      c.rangeM = null;
      c.bearingDeg = null;
      c.rangeRateMps = null;
      c._prevRange = null;
      c._prevRangeMs = null;
      return;
    }
    final r = Geo.distanceM(o.lat, o.lon, c.lat!, c.lon!);
    c.rangeM = r;
    c.bearingDeg = Geo.bearingDeg(o.lat, o.lon, c.lat!, c.lon!);
    if (!rate) return;
    final pr = c._prevRange, pm = c._prevRangeMs;
    if (pr != null && pm != null && nowMs - pm >= 1000) {
      final raw = (r - pr) / ((nowMs - pm) / 1000.0);
      // Smooth: a single noisy fix should not flip closing/opening.
      c.rangeRateMps = c.rangeRateMps == null ? raw : c.rangeRateMps! * 0.6 + raw * 0.4;
      c._prevRange = r;
      c._prevRangeMs = nowMs;
    } else if (pr == null) {
      c._prevRange = r;
      c._prevRangeMs = nowMs;
    }
  }

  /// Drop contacts unheard for [expireAfterS]. Returns the keys removed.
  List<String> expire(int nowMs) {
    final gone = [
      for (final e in _contacts.entries)
        if (e.value.ageS(nowMs) > expireAfterS) e.key
    ];
    for (final k in gone) {
      _contacts.remove(k);
    }
    _macIndex.removeWhere((_, v) => !_contacts.containsKey(v));
    return gone;
  }
}

extension on Contact {
  void _copyFrom(Contact o) {
    uasId = o.uasId;
    macs.addAll(o.macs);
    sources.addAll(o.sources);
    lastSeenMs = o.lastSeenMs;
    rssi = o.rssi;
    lat = o.lat;
    lon = o.lon;
    posMs = o.posMs;
    altGeoM = o.altGeoM;
    heightM = o.heightM;
    heightRef = o.heightRef;
    speedMps = o.speedMps;
    headingDeg = o.headingDeg;
    vspeedMps = o.vspeedMps;
    opLat = o.opLat;
    opLon = o.opLon;
    operatorId = o.operatorId;
    selfDesc = o.selfDesc;
    emergency = o.emergency;
    authState = o.authState;
  }
}
