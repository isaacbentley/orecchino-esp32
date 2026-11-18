// clear_history_test.dart — "Clear history…": this phone's records go (pins,
// cursors and settings stay); the detector's log is cleared with log_clear
// and confirmed by log_cleared (a new log epoch, the cursor back to the
// start, this phone's records kept); no confirmation within the time is a
// failure in words; a log_cleared the phone did not ask for (the board's own
// screen) is handled the same way, with a notice; and the sheet never
// deletes on a single tap.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orecchino_mobile/app/app_controller.dart';
import 'package:orecchino_mobile/core/ble/ble_service.dart';
import 'package:orecchino_mobile/core/ble/simulated_detector.dart';
import 'package:orecchino_mobile/core/location/location_service.dart';
import 'package:orecchino_mobile/data/db.dart';
import 'package:orecchino_mobile/features/history/clear_history_sheet.dart';
import 'package:orecchino_mobile/ui/theme/theme.dart';

import 'support/fakes.dart';

class NoLocation extends LocationService {
  @override
  Future<void> start() async {}
}

/// The demo detector, recording the commands it gets; [silent] ignores
/// log_clear (a board that never answers).
class RecordingSim extends SimulatedDetector {
  final List<String> commands = [];
  bool silent = false;

  @override
  void handleCommand(String jsonCmd) {
    commands.add((jsonDecode(jsonCmd) as Map<String, dynamic>)['cmd'] as String);
    if (silent && jsonCmd.contains('log_clear')) return;
    super.handleCommand(jsonCmd);
  }
}

DetectionsCompanion row(String det, int seq) => DetectionsCompanion(
      detectorId: Value(det),
      rowKey: Value('0:s$seq'),
      seq: Value(seq),
      uasId: Value('UAS$seq'),
      mac: const Value('AA:BB:CC:DD:EE:FF'),
      firstUtc: const Value(1790000000),
      lastUtc: const Value(1790000600),
      durS: const Value(600),
      tfr: const Value(false),
      emerg: const Value(false),
      msgs: const Value(10),
    );

void main() {
  late AppController app;
  late RecordingSim sim;
  late AppDatabase db;

  Future<void> wait(WidgetTester t, int ms) => t.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));

  Future<void> start(WidgetTester t) async {
    await t.runAsync(() async {
      db = AppDatabase(NativeDatabase.memory());
      sim = RecordingSim();
      app = AppController(
          db: db, ble: BleService(transport: FakeTransport()), sim: sim, location: NoLocation(), startTimers: false);
      await app.start();
      await app.setDemo(true);
      await Future<void>.delayed(const Duration(milliseconds: 600)); // the demo's first sync
      await db.upsertDetector(const DetectorsCompanion(id: Value('t5'), name: Value('T5'), bonded: Value(true)));
      await db.insertDetections([row('t5', 1), row('t5', 2), row('simulated', 90)]);
    });
  }

  Future<void> stop(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
    await t.runAsync(() async => app.dispose());
  }

  testWidgets('this phone: every record goes, detectors and cursors stay', (t) async {
    await start(t);
    await t.runAsync(() async {
      final before = (await db.getDetector('simulated'))!;
      final n = await app.clearPhoneHistory();
      expect(n, greaterThanOrEqualTo(3));
      expect(await db.getDetectionsList(), isEmpty);
      expect((await db.pinnedDetectors()).map((d) => d.id), contains('t5'));
      expect((await db.getDetector('simulated'))!.lastSyncSeq, before.lastSyncSeq);
      expect(sim.commands, isNot(contains('log_clear')));
    });
    await stop(t);
  });

  testWidgets('the detector: log_clear, confirmed; a new epoch from the start; this phone keeps its copy', (t) async {
    await start(t);
    await t.runAsync(() async {
      final before = (await db.getDetector('simulated'))!;
      expect(before.lastSyncSeq, greaterThan(0));
      final err = await app.clearDetectorHistory();
      expect(err, isNull);
      expect(sim.commands, contains('log_clear'));
      final after = (await db.getDetector('simulated'))!;
      expect(after.logEpoch, before.logEpoch + 1);
      // The phone's records are all still there.
      expect((await db.getDetectionsList()).where((r) => r.uasId == 'UAS90'), hasLength(1));
      expect(await db.getDetectionsList(detectorId: 't5'), hasLength(2));
      // The next sync (started at once) asked from the start of the new log
      // (its database reset and start run on real time: wait for it, up to
      // a deadline a loaded machine still meets).
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (sim.commands.where((c) => c == 'log_get').length < 2 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(sim.commands.where((c) => c == 'log_get').length, greaterThanOrEqualTo(2));
    });
    await stop(t);
  });

  testWidgets('no log_cleared within the time: a failure in words, nothing changed', (t) async {
    await start(t);
    sim.silent = true;
    await t.runAsync(() async {
      final before = (await db.getDetector('simulated'))!;
      final err = await app.clearDetectorHistory(timeout: const Duration(milliseconds: 400));
      expect(err, 'SIMULATED DETECTOR did not confirm within 0.4 s: its history may not have been cleared');
      final after = (await db.getDetector('simulated'))!;
      expect(after.logEpoch, before.logEpoch);
      expect(after.lastSyncSeq, before.lastSyncSeq);
      expect(await db.getDetectionsList(), hasLength(greaterThanOrEqualTo(3)));
    });
    await stop(t);
  });

  testWidgets('a log_cleared the phone did not ask for: same reset, a notice, the phone keeps its history', (t) async {
    await start(t);
    final notices = <String>[];
    app.notice.addListener(() {
      if (app.notice.value != null) notices.add(app.notice.value!);
    });
    await t.runAsync(() async {
      final before = (await db.getDetector('simulated'))!;
      sim.handleCommand('{"cmd":"log_clear"}'); // cleared from the board's own screen
      await Future<void>.delayed(const Duration(milliseconds: 700));
      final after = (await db.getDetector('simulated'))!;
      expect(after.logEpoch, before.logEpoch + 1);
      expect(await db.getDetectionsList(detectorId: 't5'), hasLength(2));
      expect((await db.getDetectionsList()).where((r) => r.uasId == 'UAS90'), hasLength(1));
    });
    expect(notices, ['History cleared on SIMULATED DETECTOR']);
    await stop(t);
  });

  testWidgets('the sheet: a single tap asks again; only the red button deletes', (t) async {
    await start(t);
    t.view.physicalSize = const Size(390 * 3, 844 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: OrecchinoTheme.dark,
      home: Scaffold(body: ClearHistorySheet(app: app)),
    ));
    expect(find.text('Clear history on SIMULATED DETECTOR'), findsOneWidget);
    expect(find.textContaining('This can\'t be undone'), findsWidgets);
    await t.tap(find.byKey(const ValueKey('choose-phone')));
    await t.pump();
    await wait(t, 100);
    expect(await t.runAsync(() => db.getDetectionsList()), hasLength(greaterThanOrEqualTo(3)));
    expect(find.byKey(const ValueKey('confirm-phone')), findsOneWidget);
    // Cancel puts it back; nothing deleted.
    await t.tap(find.text('Cancel'));
    await t.pump();
    expect(find.byKey(const ValueKey('confirm-phone')), findsNothing);
    await t.tap(find.byKey(const ValueKey('choose-phone')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('confirm-phone')));
    await t.pump();
    await wait(t, 200);
    await t.pump();
    expect(await t.runAsync(() => db.getDetectionsList()), isEmpty);
    expect(find.textContaining('from this phone'), findsOneWidget);
    await stop(t);
  });
}
