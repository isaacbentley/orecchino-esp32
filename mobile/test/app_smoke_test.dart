// app_smoke_test.dart — the whole app shell in demo mode: every tab builds,
// the simulated detector's drones and the demo aircraft reach the screens,
// and the Detectors tab shows the demo card and the settings.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orecchino_mobile/app/app_controller.dart';
import 'package:orecchino_mobile/core/ble/ble_service.dart';
import 'package:orecchino_mobile/core/location/location_service.dart';
import 'package:orecchino_mobile/data/db.dart';
import 'package:orecchino_mobile/main.dart';

import 'support/fakes.dart';

class NoLocation extends LocationService {
  @override
  Future<void> start() async {}
}

void main() {
  testWidgets('demo mode end to end through every tab', (tester) async {
    final handle = tester.ensureSemantics();
    tester.view.physicalSize = const Size(430, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppController(
      db: AppDatabase(NativeDatabase.memory()),
      ble: BleService(transport: FakeTransport()),
      location: NoLocation(),
      startTimers: false,
    );
    await tester.runAsync(() async {
      await app.start();
      await app.setDemo(true);
      // Let the simulator speak for a few seconds (real time: drift runs
      // its queries off the fake clock).
      await Future<void>.delayed(const Duration(milliseconds: 2300));
      await app.refreshTraffic();
    });
    app.tick();
    await tester.pumpWidget(OrecchinoMobileApp(app: app));
    await tester.pump();

    expect(app.tracker.length, 2);
    expect(find.text('SIMULATED detector and position'), findsOneWidget);
    expect(find.text('CONTACTS (3)'), findsOneWidget);
    // Pull up the contacts sheet: the demo aircraft has a card.
    await tester.tap(find.bySemanticsLabel(RegExp(r'^Contacts sheet')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('D9A11'), findsWidgets); // drone 1's label
    expect(find.textContaining('N123SIM'), findsWidgets); // the demo aircraft

    // The sky, north up without a compass, with the demo's marks.
    expect(find.bySemanticsLabel(RegExp(r'^Sky view, 3D, north up, 3.0 km range, \d marks')), findsOneWidget);

    await tester.tap(find.text('Find'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('POINT AT THE SKY'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Pointer to drone D9A11, bearing \d+ degrees true')), findsOneWidget);

    await tester.tap(find.text('History'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('FLIGHT LOG'), findsOneWidget);
    expect(find.text('ACTIVITY'), findsOneWidget);
    expect(find.text('TODAY'), findsWidgets); // records grouped by day

    await tester.tap(find.text('Detectors'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('SIMULATED DETECTOR'), findsOneWidget);
    expect(find.text('Spoken traffic callouts'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1)); // drift closes its watch streams on a timer
    await tester.runAsync(() async => app.dispose());
    handle.dispose();
  });
}
