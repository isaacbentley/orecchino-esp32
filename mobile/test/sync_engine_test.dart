// sync_engine_test.dart — the log_get/log_done cursor protocol of
// firmware/common/rx_core.h emit_log, against an in-memory database.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orecchino_mobile/core/protocol/messages.dart';
import 'package:orecchino_mobile/core/sync/sync_engine.dart';
import 'package:orecchino_mobile/data/db.dart';

HostMessage rec(int? seq, {String uas = '', String mac = 'AA:AA:AA:AA:AA:01', bool? active, int last = 1700000000}) =>
    HostMessage.parse(jsonEncode({
      'type': 'log',
      'seq': seq,
      'i': seq,
      'active': active ?? seq == null,
      'uas': uas,
      'mac': mac,
      'first': last - 60,
      'last': last,
      'dur': 60,
      'peak_rssi': -60,
      'auth_state': 'none',
      'tfr': false,
      'emerg': false,
      'msgs': 10,
    }))!;

HostMessage done({required int total, required int oldest, int live = 0}) => HostMessage.parse(jsonEncode(
    {'type': 'log_done', 'n': total - oldest, 'live': live, 'total': total, 'clock': true, 'next': total, 'oldest': oldest}))!;

void main() {
  late AppDatabase db;
  late List<String> sent;
  late SyncEngine sync;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    sent = [];
    sync = SyncEngine(db: db, sendCommand: (c) async => sent.add(c), nowUtc: () => 1700001000);
    await db.upsertDetector(const DetectorsCompanion(id: Value('det'), name: Value('T5'), bonded: Value(true)));
  });

  tearDown(() async {
    sync.dispose();
    await db.close();
  });

  Future<void> feedAll(List<HostMessage> msgs) async {
    // As the app does: fire and forget, in stream order; the engine queues.
    final futures = [for (final m in msgs) sync.handleMessage(m)];
    await Future.wait(futures);
  }

  test('first sync: asks since 0, stores ended records, cursor = next, live not counted', () async {
    await sync.startSync('det');
    expect(jsonDecode(sent.single), {'cmd': 'log_get', 'since': 0});
    await feedAll([
      rec(0, uas: 'A'),
      rec(1, uas: 'B'),
      rec(2, uas: 'C'),
      rec(null, uas: 'LIVE1'), // still in range: seq null, active
      done(total: 3, oldest: 0, live: 1),
    ]);
    expect(sync.isSyncing, isFalse);
    final d = (await db.getDetector('det'))!;
    expect(d.lastSyncSeq, 3); // next = total, the live contact not counted
    expect(d.historyGap, isFalse);
    final rows = await db.getDetectionsList(detectorId: 'det');
    expect(rows.where((r) => !r.active).map((r) => r.seq).toSet(), {0, 1, 2});
    final live = rows.where((r) => r.active).toList();
    expect(live.single.uasId, 'LIVE1');
    expect(live.single.seq, isNull);
  });

  test('next sync resumes from the cursor; a live contact that ended arrives with its seq', () async {
    await sync.startSync('det');
    await feedAll([rec(0, uas: 'A'), rec(null, uas: 'LIVE1'), done(total: 1, oldest: 0, live: 1)]);
    sent.clear();

    await sync.startSync('det');
    expect(jsonDecode(sent.single), {'cmd': 'log_get', 'since': 1});
    await feedAll([rec(1, uas: 'LIVE1'), rec(null, uas: 'LIVE2'), done(total: 2, oldest: 0, live: 1)]);
    final rows = await db.getDetectionsList(detectorId: 'det');
    expect(rows.where((r) => !r.active).map((r) => r.uasId).toSet(), {'A', 'LIVE1'});
    // The old live row is replaced by this sync's live set.
    expect(rows.where((r) => r.active).map((r) => r.uasId).toList(), ['LIVE2']);
    expect((await db.getDetector('det'))!.lastSyncSeq, 2);
  });

  test('records rotated out before this phone synced: a gap', () async {
    await db.updateSyncCursor('det', 5, 0);
    await sync.startSync('det');
    expect((jsonDecode(sent.single) as Map<String, dynamic>)['since'], 5);
    await feedAll([rec(20), done(total: 21, oldest: 20)]);
    expect(sync.gapDetected, isTrue);
    final d = (await db.getDetector('det'))!;
    expect(d.historyGap, isTrue);
    expect(d.lastSyncSeq, 21);
    expect(d.oldestSeq, 20);
  });

  test('cursor above total: the log was cleared; restart from oldest in a new epoch', () async {
    await sync.startSync('det');
    await feedAll([rec(0, uas: 'OLD0'), rec(1, uas: 'OLD1'), done(total: 2, oldest: 0)]);
    sent.clear();

    await sync.startSync('det'); // since 2, but the board was cleared: total 1
    await feedAll([rec(null, uas: 'LIVE'), done(total: 1, oldest: 0, live: 1)]);
    expect(sent.map((c) => (jsonDecode(c) as Map<String, dynamic>)['since']).toList(), [2, 0]);
    expect(sync.isSyncing, isTrue);
    await feedAll([rec(0, uas: 'NEW0'), rec(null, uas: 'LIVE'), done(total: 1, oldest: 0, live: 1)]);
    expect(sync.isSyncing, isFalse);
    expect(sync.lastProgress.logCleared, isTrue);

    final rows = await db.getDetectionsList(detectorId: 'det');
    // The new seq 0 did not overwrite the old seq 0.
    expect(rows.where((r) => !r.active).map((r) => r.uasId).toSet(), {'OLD0', 'OLD1', 'NEW0'});
    final d = (await db.getDetector('det'))!;
    expect(d.lastSyncSeq, 1);
    expect(d.logEpoch, 1);
  });

  test('a record that cannot be stored keeps the cursor where it was', () async {
    final failing = _FailingDb(NativeDatabase.memory());
    await failing.upsertDetector(const DetectorsCompanion(id: Value('det'), name: Value('T5')));
    await failing.updateSyncCursor('det', 7, 0);
    final s = SyncEngine(db: failing, sendCommand: (_) async {});
    await s.startSync('det');
    await s.handleMessage(rec(7));
    await s.handleMessage(rec(8));
    await s.handleMessage(done(total: 9, oldest: 0));
    expect(s.lastProgress.error, contains('could not be stored'));
    expect((await failing.getDetector('det'))!.lastSyncSeq, 7);
    s.dispose();
    await failing.close();
  });

  test('abort (link lost) leaves the cursor for the next sync', () async {
    await db.updateSyncCursor('det', 4, 0);
    await sync.startSync('det');
    await sync.handleMessage(rec(4));
    sync.abort();
    await sync.handleMessage(done(total: 5, oldest: 0)); // late; ignored
    expect(sync.isSyncing, isFalse);
    expect((await db.getDetector('det'))!.lastSyncSeq, 4);
    expect(sync.lastProgress.error, 'connection lost');
  });

  test('a send failure ends the sync with an error', () async {
    final s = SyncEngine(db: db, sendCommand: (_) async => throw StateError('no link'));
    expect(await s.startSync('det'), isFalse);
    expect(s.isSyncing, isFalse);
    expect(s.lastProgress.error, contains('could not ask'));
    s.dispose();
  });
}

class _FailingDb extends AppDatabase {
  _FailingDb(super.e);
  @override
  Future<void> insertDetections(List<DetectionsCompanion> records) async {
    if (records.any((r) => r.seq.value == 8)) throw StateError('disk full');
    return super.insertDetections(records);
  }
}
