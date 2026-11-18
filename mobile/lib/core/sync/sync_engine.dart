// sync_engine.dart — incremental history sync (plan §5.2, protocol in
// firmware/common/rx_core.h emit_log).
//
// Send {"cmd":"log_get","since":<cursor>}; the board answers with the ended
// records whose seq >= cursor, then every contact still live
// ("active":true, "seq":null, not counted), then log_done
// {"n","live","total","next","oldest"}.
// - Ended records are upserted by (epoch, seq); live ones replace the
//   detector's previous live set at log_done.
// - On log_done the cursor becomes `next`, unless a record failed to store
//   (then it stays, and the next sync asks again).
// - `oldest` above the cursor: records rotated out before this phone saw
//   them (a gap, remembered on the detector).
// - The board's log was cleared (its seqs start again) when log_done says
//   so in one of three ways: its `log_id` (the board's persisted log
//   identity, bumped by every clear; firmware that sends it) differs from
//   the one the cursor was stored with; the cursor is above `total`; or
//   `oldest` is below the `oldest` stored at the last sync, which a ring
//   that only appends can never do (the fallback for firmware without
//   `log_id`, for a log cleared while the phone was away and refilled past
//   the cursor; it needs the old log to have rotated). The log epoch is
//   bumped (so the new seqs never overwrite older history) and the sync
//   asks again from `oldest`, once. (The first returned record's first_utc
//   says nothing: the record at the cursor is a new contact whenever none
//   was live at the last sync, cleared or not.)
// - A cut reply (log_done `"err":"dropped"`: the link dropped part of it;
//   `next` is then the `since` asked for) or no log_done within [timeout]:
//   the records that came are stored (they are good, and come again
//   harmlessly), the cursor stays, and the same question is asked again,
//   up to [maxRetries] times, then the sync ends with an error and the
//   next one asks from the same cursor.
// Ended records are written in batches (up to [batchSize] at a time, and
// the rest before log_done is acted on), not one write per record.
// Messages are handled strictly in order: [handleMessage] queues behind the
// previous one, and returns when this one is stored.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:drift/drift.dart';

import '../../data/db.dart';
import '../protocol/commands.dart';
import '../protocol/messages.dart';

class SyncProgress {
  final bool isSyncing;
  final int recordsSynced;
  final int liveContacts;
  final bool gapDetected;
  final bool logCleared;
  final String? error;

  const SyncProgress({
    required this.isSyncing,
    required this.recordsSynced,
    this.liveContacts = 0,
    required this.gapDetected,
    this.logCleared = false,
    this.error,
  });

  static const idle = SyncProgress(isSyncing: false, recordsSynced: 0, gapDetected: false);
}

class SyncEngine {
  final AppDatabase db;
  final Future<void> Function(String) sendCommand;
  final Duration timeout;
  final int Function() nowUtc;

  SyncEngine({
    required this.db,
    required this.sendCommand,
    this.timeout = const Duration(seconds: 90),
    int Function()? nowUtc,
  }) : nowUtc = nowUtc ?? (() => DateTime.now().millisecondsSinceEpoch ~/ 1000);

  bool _isSyncing = false;
  String? _detectorId;
  int _cursor = 0;
  int _epoch = 0;
  int? _logId; // the log the cursor belongs to (null: the board never said)
  int? _knownOldest; // `oldest` at the last sync (null: none, or reset)
  bool _restarted = false;
  bool _gap = false;
  bool _cleared = false;
  int _received = 0;
  int _failed = 0;
  int _retries = 0; // cut replies and timeouts asked again this sync
  final List<DetectionsCompanion> _active = [];
  final List<DetectionsCompanion> _ended = []; // received, not yet written
  int? _afterUtc; // this sync's filter, kept for a re-ask

  /// Ended records written per database batch.
  static const batchSize = 64;

  /// How many times one sync asks again after a cut reply or a timeout.
  static const maxRetries = 3;
  Timer? _watchdog;
  /// The previous message's handling; null before the first. (Not a
  /// pre-made completed future: its callbacks would be scheduled in the
  /// zone it was made in, not the one the messages arrive in.)
  Future<void>? _queue;
  SyncProgress _last = SyncProgress.idle;

  final _progress = StreamController<SyncProgress>.broadcast();
  Stream<SyncProgress> get progress => _progress.stream;
  SyncProgress get lastProgress => _last;

  bool get isSyncing => _isSyncing;
  bool get gapDetected => _gap;
  String? get detectorId => _detectorId;

  void _emit({String? error}) {
    _last = SyncProgress(
      isSyncing: _isSyncing,
      recordsSynced: _received,
      liveContacts: _active.length,
      gapDetected: _gap,
      logCleared: _cleared,
      error: error,
    );
    if (!_progress.isClosed) _progress.add(_last);
  }

  /// Start a sync with [detectorId] from its stored cursor. Returns false
  /// when one is already running or the command could not be sent.
  Future<bool> startSync(String detectorId, {int? afterUtc}) async {
    if (_isSyncing) return false;
    _isSyncing = true;
    _detectorId = detectorId;
    _received = 0;
    _failed = 0;
    _gap = false;
    _cleared = false;
    _restarted = false;
    _retries = 0;
    _active.clear();
    _ended.clear();
    final d = await db.getDetector(detectorId);
    _cursor = d?.lastSyncSeq ?? 0;
    _epoch = d?.logEpoch ?? 0;
    _logId = d?.logId;
    _knownOldest = d?.oldestSeq;
    _afterUtc = afterUtc;
    _emit();
    return _ask();
  }

  /// log_done describes another log than the cursor's (see the file
  /// comment): its id changed, the cursor is past its end, or its oldest
  /// held seq went backwards.
  bool _otherLog(LogDoneMessage m, int? total, int? oldest) {
    if (m.logId != null && _logId != null && m.logId != _logId) return true;
    if (total != null && _cursor > total) return true;
    if (oldest != null && _knownOldest != null && oldest < _knownOldest!) return true;
    return false;
  }

  /// Asks from the cursor with the sync's own filter, so a re-ask or a
  /// restart asks the same question.
  Future<bool> _ask() async {
    _kick();
    try {
      await sendCommand(HostCommands.logGet(since: _cursor, afterUtc: _afterUtc));
      return true;
    } catch (e) {
      _finish(error: 'could not ask for the log: $e');
      return false;
    }
  }

  void _kick() {
    _watchdog?.cancel();
    _watchdog = Timer(timeout, () {
      if (!_isSyncing) return;
      if (_retries < maxRetries) {
        unawaited(_askAgain().catchError((Object _) {}));
      } else {
        _finish(error: 'the detector stopped answering');
      }
    });
  }

  /// A cut reply or a timeout: keep what came (the records are good), keep
  /// the cursor, and ask the same question again.
  Future<void> _askAgain() async {
    _retries++;
    await _flush();
    _active.clear();
    _emit();
    await _ask();
  }

  /// Abandon a running sync (the link dropped). The cursor is not moved, so
  /// the next sync resumes from it.
  void abort([String reason = 'connection lost']) {
    if (_isSyncing) _finish(error: reason);
  }

  void _finish({String? error}) {
    _ended.clear(); // an abandoned sync asks for these again
    _watchdog?.cancel();
    _watchdog = null;
    _isSyncing = false;
    _emit(error: error);
  }

  /// Queue [msg] behind the previous message; completes when it is stored.
  Future<void> handleMessage(HostMessage msg) {
    final prev = _queue;
    final f = prev == null ? _handle(msg) : prev.then((_) => _handle(msg));
    _queue = f.catchError((_) {});
    return f;
  }

  Future<void> _handle(HostMessage msg) async {
    if (!_isSyncing || _detectorId == null) return;
    final id = _detectorId!;
    if (msg is LogRecordMessage) {
      _kick();
      final ended = msg.seq != null && !msg.active;
      final row = _row(id, msg, ended);
      if (ended) {
        _ended.add(row);
        _received++;
        if (_ended.length >= batchSize) await _flush();
      } else {
        _active.add(row);
      }
      _emit();
    } else if (msg is LogDoneMessage) {
      await _done(id, msg);
    }
  }

  DetectionsCompanion _row(String id, LogRecordMessage m, bool ended) => DetectionsCompanion(
        detectorId: Value(id),
        rowKey: Value(ended ? '$_epoch:s${m.seq}' : 'a:${m.contactKey}'),
        seq: Value(ended ? m.seq : null),
        active: Value(!ended),
        uasId: Value(m.uasId),
        mac: Value(m.mac),
        srcs: Value(m.sources),
        fmts: Value(m.formats),
        uaType: Value(m.uaType),
        firstUtc: Value(m.firstUtc),
        lastUtc: Value(m.lastUtc),
        durS: Value(m.durationS),
        lat: Value(m.lat),
        lon: Value(m.lon),
        maxH: Value(m.maxHeightM),
        peakRssi: Value(m.peakRssi),
        authState: Value(m.authState),
        tfr: Value(m.tfrEver),
        inTfr: Value(m.inTfrNow),
        tfrId: Value(m.tfrId),
        classType: Value(m.classType),
        catEu: Value(m.catEu),
        classEu: Value(m.classEu),
        emerg: Value(m.emergency),
        msgs: Value(m.msgCount),
      );

  /// Write the ended records received so far, in one batch.
  Future<void> _flush() async {
    if (_ended.isEmpty) return;
    final rows = List.of(_ended);
    _ended.clear();
    try {
      await db.insertDetections(rows);
    } catch (_) {
      _received -= rows.length;
      _failed += rows.length;
    }
  }

  Future<void> _done(String id, LogDoneMessage m) async {
    final total = m.total ?? m.nextSeq;
    final next = m.nextSeq ?? total;
    final oldest = m.oldestSeq;
    if (!_restarted && _otherLog(m, total, oldest)) {
      // The board's log was cleared (or reset): its seqs start again. The
      // records not yet written were the new log's, keyed to the old
      // epoch: dropped, they come again from oldest under the new one.
      _ended.clear();
      _received = 0;
      _restarted = true;
      _cleared = true;
      _epoch++;
      _cursor = oldest ?? 0;
      _logId = m.logId;
      _knownOldest = null;
      _active.clear();
      _emit();
      await _ask();
      return;
    }
    if (m.cut) {
      if (_retries < maxRetries) {
        await _askAgain();
      } else {
        await _flush();
        _finish(error: 'the detector\'s reply was cut short $maxRetries times; the next sync asks again');
      }
      return;
    }
    await _flush();
    if (oldest != null && oldest > _cursor) _gap = true;
    try {
      await db.replaceActive(id, List.of(_active));
    } catch (_) {
      _failed++;
    }
    if (next != null && _failed == 0) {
      await db.updateSyncCursor(id, next, oldest,
          gap: _gap ? true : null, epoch: _epoch, syncUtc: nowUtc(), logId: m.logId);
      _cursor = next;
      _finish();
    } else {
      _finish(error: _failed > 0 ? '$_failed records could not be stored; the next sync asks again' : null);
    }
  }

  void dispose() {
    _watchdog?.cancel();
    _progress.close();
  }
}
