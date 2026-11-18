// phone_history.dart — what the phone's own receiver heard, kept in History
// as the phone's records: detector "phone" ("This phone"), one record per
// drone per spell of hearing it (a gap of more than 60 s starts a new one),
// shaped like a detector's match-log record (first/last, duration, one
// position, the highest height, peak RSSI, the transports, alerts). Live
// while heard; ended 60 s after the last frame. Written every few seconds
// by the app, never through the detector sync (no cursor, no epoch).
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'package:drift/drift.dart' show Value;

import '../../data/db.dart';
import '../protocol/messages.dart';
import 'contact_tracker.dart';

class PhoneHistory {
  static const detectorId = 'phone';
  static const detectorName = 'This phone';
  static const endAfterMs = 60000;

  final Map<String, _Spell> _spells = {};
  bool _dirty = false;

  /// A frame the phone heard for contact [c].
  void note(Contact c, RidMessage m, int nowMs) {
    var s = _spells[c.key];
    if (s == null || nowMs - s.lastMs > endAfterMs) {
      s = _spells[c.key] = _Spell(c.key, nowMs);
    }
    s
      ..lastMs = nowMs
      ..msgs += 1
      ..uasId = c.uasId ?? s.uasId
      ..mac = m.mac.isNotEmpty ? m.mac : s.mac
      ..uaType = m.basicId.where((b) => b.uasId.isNotEmpty).firstOrNull?.uaType ?? s.uaType
      ..emergency = s.emergency || m.emergency
      ..authState = c.authState ?? s.authState;
    s.srcs |= switch (m.src) { 'phone-nan' => 2, 'phone-beacon' => 1, _ => 4 };
    s.fmts |= m.fmt == 'gb46750' ? 2 : 1;
    final l = m.loc;
    if (l != null && l.hasPosition) {
      s.lat = l.lat;
      s.lon = l.lon;
    }
    final h = l?.height;
    if (h != null && (s.maxH == null || h > s.maxH!)) s.maxH = h;
    final r = m.rssi;
    if (r != null && (s.peakRssi == null || r > s.peakRssi!)) s.peakRssi = r;
    _dirty = true;
  }

  AppDatabase? _rowIn; // the database the detector row was written to

  /// Forget every spell (the phone's history was cleared).
  void clear() {
    _spells.clear();
    _dirty = false;
    _rowIn = null; // clearing may have removed the row
  }

  /// Write the spells that changed, and end those not heard for a minute.
  Future<void> flush(AppDatabase db, int nowMs) async {
    final ending = [for (final s in _spells.values) if (nowMs - s.lastMs > endAfterMs) s];
    if (!_dirty && ending.isEmpty) return;
    _dirty = false;
    // The "This phone" detector row, once per database (not every flush:
    // each write wakes every screen watching the detectors).
    if (!identical(_rowIn, db)) {
      await db.upsertDetector(const DetectorsCompanion(
        id: Value(detectorId),
        name: Value(detectorName),
        board: Value('phone'),
        bonded: Value(false),
      ));
      _rowIn = db;
    }
    final rows = [for (final s in _spells.values) s.row(active: nowMs - s.lastMs <= endAfterMs)];
    if (rows.isNotEmpty) await db.insertDetections(rows);
    for (final s in ending) {
      _spells.remove(s.key);
    }
  }

  int get openSpells => _spells.length;
}

class _Spell {
  final String key;
  final int firstMs;
  int lastMs;
  int msgs = 0;
  String? uasId;
  String mac = '';
  int? uaType;
  int srcs = 0, fmts = 0;
  double? lat, lon, maxH;
  int? peakRssi;
  bool emergency = false;
  String? authState;

  _Spell(this.key, this.firstMs) : lastMs = firstMs;

  DetectionsCompanion row({required bool active}) => DetectionsCompanion(
        detectorId: const Value(PhoneHistory.detectorId),
        rowKey: Value('phone:$key:${firstMs ~/ 1000}'),
        seq: const Value(null),
        active: Value(active),
        uasId: Value(uasId),
        mac: Value(mac),
        srcs: Value(srcs),
        fmts: Value(fmts),
        uaType: Value(uaType),
        firstUtc: Value(firstMs ~/ 1000),
        lastUtc: Value(lastMs ~/ 1000),
        durS: Value((lastMs - firstMs) ~/ 1000),
        lat: Value(lat),
        lon: Value(lon),
        maxH: Value(maxH),
        peakRssi: Value(peakRssi),
        // The phone does not check signatures: its verdict is at most
        // "unverified", which the log's words treat as no badge.
        authState: Value(authState ?? AuthState.none),
        tfr: const Value(false),
        emerg: Value(emergency),
        msgs: Value(msgs),
      );
}
