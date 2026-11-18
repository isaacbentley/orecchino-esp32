// db.dart — Drift SQLite database schema for Orecchino mobile application
//
// Schema 2 (sync protocol of rx_core.h emit_log):
// - an ended record is final and keyed by its seq; a contact still live has
//   no seq yet ("active") and is keyed by its UAS ID / MAC until it ends;
// - a board whose log was cleared starts its seqs again, so rows carry the
//   detector's log epoch and a clear never overwrites older history;
// - a detector is "pinned" (bonded) after its first verified pairing; only
//   a pinned detector is given the phone's position.
// Schema 3 adds the TFR-now and EU class columns to the records; schema 4
// stores the board's log identity (`log_id`, bumped by every clear) beside
// the cursor, so a clear the phone did not witness is still noticed.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'db.g.dart';

@DataClassName('DetectorEntry')
class Detectors extends Table {
  TextColumn get id => text()(); // BLE remote ID (per phone)
  TextColumn get name => text()();
  TextColumn get board => text().withDefault(const Constant('unknown'))();
  TextColumn get fw => text().withDefault(const Constant('orecchino'))();
  TextColumn get ver => text().withDefault(const Constant(''))();
  TextColumn get caps => text().withDefault(const Constant(''))(); // Comma-separated
  IntColumn get lastSeen => integer().withDefault(const Constant(0))(); // Unix timestamp s
  IntColumn get lastSyncSeq => integer().withDefault(const Constant(0))(); // the stored `next`
  IntColumn get oldestSeq => integer().nullable()();
  BoolColumn get bonded => boolean().withDefault(const Constant(false))(); // pinned
  IntColumn get lastSyncUtc => integer().nullable()();
  BoolColumn get historyGap => boolean().withDefault(const Constant(false))();
  IntColumn get logEpoch => integer().withDefault(const Constant(0))();

  /// The board's log identity the cursor belongs to (log_done `log_id`);
  /// null until the firmware sent one.
  IntColumn get logId => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('DetectionEntry')
class Detections extends Table {
  TextColumn get detectorId => text()();
  TextColumn get rowKey => text()(); // "<epoch>:s<seq>" ended, "a:<uas|mac>" live
  IntColumn get seq => integer().nullable()();
  BoolColumn get active => boolean().withDefault(const Constant(false))();
  TextColumn get uasId => text().nullable()();
  TextColumn get mac => text()();
  IntColumn get srcs => integer().nullable()();
  IntColumn get fmts => integer().nullable()();
  IntColumn get uaType => integer().nullable()();
  IntColumn get firstUtc => integer()();
  IntColumn get lastUtc => integer()();
  IntColumn get durS => integer()();
  RealColumn get lat => real().nullable()();
  RealColumn get lon => real().nullable()();
  RealColumn get maxH => real().nullable()();
  IntColumn get peakRssi => integer().nullable()();
  TextColumn get authState => text().withDefault(const Constant('none'))();
  BoolColumn get tfr => boolean()(); // inside a TFR at some point
  // Schema 3 (firmware 0.7+): inside it at the end (live: now), which TFR,
  // and the EU classification; null from older firmware and the phone.
  BoolColumn get inTfr => boolean().nullable()();
  TextColumn get tfrId => text().nullable()();
  IntColumn get classType => integer().nullable()();
  IntColumn get catEu => integer().nullable()();
  IntColumn get classEu => integer().nullable()();
  BoolColumn get emerg => boolean()();
  IntColumn get msgs => integer()();

  @override
  Set<Column> get primaryKey => {detectorId, rowKey};
}

/// The 24 h live-track ring of plan §5.2. Part of schema 2, but nothing
/// writes or reads it yet.
@DataClassName('LivePointEntry')
class LivePoints extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get detectorId => text()();
  TextColumn get uasKey => text()(); // UAS ID or MAC
  IntColumn get timestamp => integer()(); // UTC seconds
  RealColumn get lat => real().nullable()();
  RealColumn get lon => real().nullable()();
  RealColumn get height => real().nullable()();
  IntColumn get rssi => integer()();
}

@DataClassName('SettingEntry')
class Settings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(tables: [Detectors, Detections, LivePoints, Settings])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? e]) : super(e ?? _openConnection());

  /// An in-memory database for tests.
  AppDatabase.memory() : super(NativeDatabase.memory());

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            // Schema 1 keyed records by seq alone and stored the auth state
            // as a number; the log is on the boards, so start the history
            // again rather than convert it.
            await m.deleteTable('detections');
            await m.createTable(detections);
            await m.addColumn(detectors, detectors.lastSyncUtc);
            await m.addColumn(detectors, detectors.historyGap);
            await m.addColumn(detectors, detectors.logEpoch);
            await m.createTable(settings);
            await m.createTable(livePoints); // new in schema 2 (IF NOT EXISTS)
            await customStatement('UPDATE detectors SET last_sync_seq = 0, oldest_seq = NULL');
          }
          if (from >= 2 && from < 3) {
            // A new table in schema 2 above already has these.
            await m.addColumn(detections, detections.inTfr);
            await m.addColumn(detections, detections.tfrId);
            await m.addColumn(detections, detections.classType);
            await m.addColumn(detections, detections.catEu);
            await m.addColumn(detections, detections.classEu);
          }
          if (from < 4) {
            // The detectors table is never recreated above: every older
            // schema needs the column.
            await m.addColumn(detectors, detectors.logId);
          }
        },
      );

  static LazyDatabase _openConnection() {
    return LazyDatabase(() async {
      final dbFolder = await getApplicationDocumentsDirectory();
      final file = File(p.join(dbFolder.path, 'orecchino.sqlite'));
      // WAL: the History screen's reads never wait on the sync's and the
      // phone's writes, and a write is one append, not a journal copy.
      return NativeDatabase.createInBackground(file, setup: (db) {
        db.execute('PRAGMA journal_mode=WAL');
        db.execute('PRAGMA synchronous=NORMAL');
      });
    });
  }

  // --- Detector queries ---
  Future<void> upsertDetector(DetectorsCompanion detector) =>
      into(detectors).insertOnConflictUpdate(detector);

  Future<DetectorEntry?> getDetector(String id) =>
      (select(detectors)..where((t) => t.id.equals(id))).getSingleOrNull();

  Stream<List<DetectorEntry>> watchAllDetectors() => select(detectors).watch();

  Future<List<DetectorEntry>> pinnedDetectors() =>
      (select(detectors)..where((t) => t.bonded.equals(true))).get();

  /// Forget a detector: unpin it and drop its cursor (its history stays).
  Future<void> forgetDetector(String id) async {
    await (update(detectors)..where((t) => t.id.equals(id))).write(const DetectorsCompanion(
      bonded: Value(false),
      lastSyncSeq: Value(0),
      oldestSeq: Value(null),
      logId: Value(null),
    ));
  }

  /// Store the cursor after a sync, with the log identity it belongs to
  /// ([logId]: absent leaves it, as older firmware sends none).
  Future<void> updateSyncCursor(String detectorId, int nextSeq, int? oldestSeq,
      {bool? gap, int? epoch, int? syncUtc, int? logId}) async {
    await (update(detectors)..where((t) => t.id.equals(detectorId))).write(
      DetectorsCompanion(
        lastSyncSeq: Value(nextSeq),
        oldestSeq: Value(oldestSeq),
        historyGap: gap == null ? const Value.absent() : Value(gap),
        logEpoch: epoch == null ? const Value.absent() : Value(epoch),
        lastSyncUtc: syncUtc == null ? const Value.absent() : Value(syncUtc),
        logId: logId == null ? const Value.absent() : Value(logId),
      ),
    );
  }

  // --- Detection records ---
  Future<void> insertDetections(List<DetectionsCompanion> records) async {
    await batch((batch) {
      batch.insertAllOnConflictUpdate(detections, records);
    });
  }

  /// Replace a detector's live (active) contacts with [records].
  Future<void> replaceActive(String detectorId, List<DetectionsCompanion> records) {
    return transaction(() async {
      await (delete(detections)..where((t) => t.detectorId.equals(detectorId) & t.active.equals(true))).go();
      if (records.isNotEmpty) await insertDetections(records);
    });
  }

  /// Records, newest first: from [afterUtc] on, at most [limit] (the
  /// History screen asks for its ribbon's week, bounded, so a write does
  /// not re-read the whole table).
  Stream<List<DetectionEntry>> watchDetections({
    String? detectorId,
    int? afterUtc,
    int? limit,
  }) {
    var query = select(detections);
    if (detectorId != null) {
      query = query..where((t) => t.detectorId.equals(detectorId));
    }
    if (afterUtc != null) {
      query = query..where((t) => t.lastUtc.isBiggerOrEqualValue(afterUtc) | t.active.equals(true));
    }
    query = query..orderBy([(t) => OrderingTerm.desc(t.lastUtc)]);
    if (limit != null) query = query..limit(limit);
    return query.watch();
  }

  Future<List<DetectionEntry>> getDetectionsList({String? detectorId}) {
    var query = select(detections);
    if (detectorId != null) {
      query = query..where((t) => t.detectorId.equals(detectorId));
    }
    query = query..orderBy([(t) => OrderingTerm.desc(t.lastUtc)]);
    return query.get();
  }

  /// Delete every history record on this phone (all detectors) and the
  /// live track points; detectors, their pins and cursors, and the settings
  /// stay. Returns the records deleted.
  Future<int> clearLocalHistory() => transaction(() async {
        final n = await delete(detections).go();
        await delete(livePoints).go();
        return n;
      });

  /// The detector's own log was cleared: its seqs start again, so start a
  /// new log epoch (new seqs never overwrite this phone's older records)
  /// and sync from the beginning of the new log, whose identity is
  /// [logId] when the board said (null otherwise: the old one must not be
  /// taken for a clear again).
  Future<void> resetDetectorLog(String detectorId, {int? logId}) async {
    final d = await getDetector(detectorId);
    if (d == null) return;
    await (update(detectors)..where((t) => t.id.equals(detectorId))).write(DetectorsCompanion(
      logEpoch: Value(d.logEpoch + 1),
      lastSyncSeq: const Value(0),
      oldestSeq: const Value(null),
      historyGap: const Value(false),
      logId: Value(logId),
    ));
  }

  // --- Settings (key/value) ---
  Future<String?> getSetting(String key) async =>
      (await (select(settings)..where((t) => t.key.equals(key))).getSingleOrNull())?.value;

  Future<void> setSetting(String key, String value) =>
      into(settings).insertOnConflictUpdate(SettingsCompanion(key: Value(key), value: Value(value)));
}
