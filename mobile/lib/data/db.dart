// db.dart — Drift SQLite database schema for Orecchino mobile application
//
// Schema 2 (sync protocol of rx_core.h emit_log):
// - an ended record is final and keyed by its seq; a contact still live has
//   no seq yet ("active") and is keyed by its UAS ID / MAC until it ends;
// - a board whose log was cleared starts its seqs again, so rows carry the
//   detector's log epoch and a clear never overwrites older history;
// - a detector is "pinned" (bonded) after its first verified pairing; only
//   a pinned detector is given the phone's position.
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
  BoolColumn get tfr => boolean()();
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
  int get schemaVersion => 2;

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
            await customStatement('UPDATE detectors SET last_sync_seq = 0, oldest_seq = NULL');
          }
        },
      );

  static LazyDatabase _openConnection() {
    return LazyDatabase(() async {
      final dbFolder = await getApplicationDocumentsDirectory();
      final file = File(p.join(dbFolder.path, 'orecchino.sqlite'));
      return NativeDatabase.createInBackground(file);
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
    ));
  }

  Future<void> updateSyncCursor(String detectorId, int nextSeq, int? oldestSeq,
      {bool? gap, int? epoch, int? syncUtc}) async {
    await (update(detectors)..where((t) => t.id.equals(detectorId))).write(
      DetectorsCompanion(
        lastSyncSeq: Value(nextSeq),
        oldestSeq: Value(oldestSeq),
        historyGap: gap == null ? const Value.absent() : Value(gap),
        logEpoch: epoch == null ? const Value.absent() : Value(epoch),
        lastSyncUtc: syncUtc == null ? const Value.absent() : Value(syncUtc),
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

  Stream<List<DetectionEntry>> watchDetections({
    String? detectorId,
    int? afterUtc,
  }) {
    var query = select(detections);
    if (detectorId != null) {
      query = query..where((t) => t.detectorId.equals(detectorId));
    }
    if (afterUtc != null) {
      query = query..where((t) => t.lastUtc.isBiggerOrEqualValue(afterUtc));
    }
    query = query..orderBy([(t) => OrderingTerm.desc(t.lastUtc)]);
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

  // --- Settings (key/value) ---
  Future<String?> getSetting(String key) async =>
      (await (select(settings)..where((t) => t.key.equals(key))).getSingleOrNull())?.value;

  Future<void> setSetting(String key, String value) =>
      into(settings).insertOnConflictUpdate(SettingsCompanion(key: Value(key), value: Value(value)));
}
