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
// - A cursor above `total`: the board's log was cleared. The log epoch is
//   bumped (so the new seqs never overwrite older history) and the sync
//   asks again from `oldest`, once.
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
  bool _restarted = false;
  bool _gap = false;
  bool _cleared = false;
  int _received = 0;
  int _failed = 0;
  final List<DetectionsCompanion> _active = [];
  Timer? _watchdog;
  Future<void> _queue = Future.value();
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
    _active.clear();
    final d = await db.getDetector(detectorId);
    _cursor = d?.lastSyncSeq ?? 0;
    _epoch = d?.logEpoch ?? 0;
    _emit();
    return _ask(afterUtc: afterUtc);
  }

  Future<bool> _ask({int? afterUtc}) async {
    _kick();
    try {
      await sendCommand(HostCommands.logGet(since: _cursor, afterUtc: afterUtc));
      return true;
    } catch (e) {
      _finish(error: 'could not ask for the log: $e');
      return false;
    }
  }

  void _kick() {
    _watchdog?.cancel();
    _watchdog = Timer(timeout, () => _finish(error: 'the detector stopped answering'));
  }

  /// Abandon a running sync (the link dropped). The cursor is not moved, so
  /// the next sync resumes from it.
  void abort([String reason = 'connection lost']) {
    if (_isSyncing) _finish(error: reason);
  }

  void _finish({String? error}) {
    _watchdog?.cancel();
    _watchdog = null;
    _isSyncing = false;
    _emit(error: error);
  }

  /// Queue [msg] behind the previous message; completes when it is stored.
  Future<void> handleMessage(HostMessage msg) {
    final f = _queue.then((_) => _handle(msg));
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
        try {
          await db.insertDetections([row]);
          _received++;
        } catch (_) {
          _failed++;
        }
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
        tfr: Value(m.inTfr),
        emerg: Value(m.emergency),
        msgs: Value(m.msgCount),
      );

  Future<void> _done(String id, LogDoneMessage m) async {
    final total = m.total ?? m.nextSeq;
    final next = m.nextSeq ?? total;
    final oldest = m.oldestSeq;
    if (total != null && _cursor > total && !_restarted) {
      // The board's log was cleared (or reset): its seqs start again.
      _restarted = true;
      _cleared = true;
      _epoch++;
      _cursor = oldest ?? 0;
      _active.clear();
      _emit();
      await _ask();
      return;
    }
    if (oldest != null && oldest > _cursor) _gap = true;
    try {
      await db.replaceActive(id, List.of(_active));
    } catch (_) {
      _failed++;
    }
    if (next != null && _failed == 0) {
      await db.updateSyncCursor(id, next, oldest, gap: _gap ? true : null, epoch: _epoch, syncUtc: nowUtc());
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
