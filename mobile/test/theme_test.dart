// theme_test.dart — the Sky and Flat looks: Sky on first run, switching from
// Detectors > Settings at once and without losing the screen's state,
// remembered, Flat's flat surfaces (no aurora, no blur) and radar (no 3D),
// the Saver hint, and every main screen laid out in both looks, at 1x and
// 2x text, without an overflow or an exception.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orecchino_mobile/app/app_controller.dart';
import 'package:orecchino_mobile/core/ble/ble_service.dart';
import 'package:orecchino_mobile/core/location/location_service.dart';
import 'package:orecchino_mobile/core/power/power_policy.dart';
import 'package:orecchino_mobile/data/db.dart';
import 'package:orecchino_mobile/features/details/drone_details_sheet.dart';
import 'package:orecchino_mobile/main.dart';
import 'package:orecchino_mobile/ui/glass_nav_bar.dart';
import 'package:orecchino_mobile/ui/theme/theme.dart';

import 'support/fakes.dart';

class Loc extends LocationService {
  @override
  Future<void> start() async {}
  @override
  PhoneLocation? get currentLocation => const PhoneLocation(lat: 37.8039, lon: -122.464, timeMs: 0);
  @override
  double? get headingDeg => 20;
}

Future<AppController> demoApp(WidgetTester tester, {AppLook? stored}) async {
  final db = AppDatabase(NativeDatabase.memory());
  final app = AppController(db: db, ble: BleService(transport: FakeTransport()), location: Loc(), startTimers: false);
  await tester.runAsync(() async {
    if (stored != null) await db.setSetting('look', stored.name);
    await app.start();
    await app.setDemo(true);
    await Future<void>.delayed(const Duration(milliseconds: 2300));
  });
  app.tick();
  return app;
}

Future<void> settle(WidgetTester tester, AppController app) async {
  for (var i = 0; i < 6; i++) {
    app.tick();
    await tester.pump(const Duration(milliseconds: 300));
  }
}

Future<void> tab(WidgetTester tester, AppController app, String name) async {
  final bar = find.byType(GlassNavBar).evaluate().isNotEmpty ? find.byType(GlassNavBar) : find.byType(GlassNavRail);
  await tester.tap(find.descendant(of: bar, matching: find.text(name)).first, warnIfMissed: false);
  await settle(tester, app);
}

Future<void> finish(WidgetTester tester, AppController app) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
  await tester.runAsync(() async => app.dispose());
  Look.setForTest(AppLook.sky);
}

void main() {
  setUp(() => Look.setForTest(AppLook.sky));

  testWidgets('Sky on first run; Flat from Settings at once, kept on the same screen, remembered', (tester) async {
    tester.view.physicalSize = const Size(430, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = await demoApp(tester);
    expect(app.settings.look, AppLook.sky);
    expect(Look.current, AppLook.sky);
    await tester.pumpWidget(OrecchinoMobileApp(app: app));
    await settle(tester, app);
    expect(find.text('3D'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsWidgets);

    await tab(tester, app, 'Detectors');
    final flat = find.text('Flat');
    await tester.ensureVisible(flat);
    await tester.tap(flat);
    await settle(tester, app);
    expect(Look.current, AppLook.flat);
    expect(app.settings.look, AppLook.flat);
    expect(await tester.runAsync(() => app.db.getSetting('look')), 'flat');
    // Still on Detectors (nothing restarted), and nothing is frosted.
    expect(find.text('Theme'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(scaffold.backgroundColor, Palette.flatLook.void0);

    // Live: a radar and the map, no 3D dome.
    await tab(tester, app, 'Live');
    expect(find.text('3D'), findsNothing);
    expect(find.text('Radar'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Sky view, flat')), findsOneWidget);

    // And back.
    await tab(tester, app, 'Detectors');
    await tester.ensureVisible(find.text('Sky').first);
    await tester.tap(find.text('Sky').first);
    await settle(tester, app);
    expect(Look.current, AppLook.sky);
    await tab(tester, app, 'Live');
    expect(find.text('3D'), findsOneWidget);
    await finish(tester, app);
  });

  testWidgets('a remembered Flat comes back on start', (tester) async {
    final app = await demoApp(tester, stored: AppLook.flat);
    expect(app.settings.look, AppLook.flat);
    expect(Look.current, AppLook.flat);
    await tester.runAsync(() async => app.dispose());
    Look.setForTest(AppLook.sky);
  });

  testWidgets('Saver in the Sky suggests Flat', (tester) async {
    tester.view.physicalSize = const Size(430, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = await demoApp(tester);
    await tester.runAsync(() => app.setPowerMode(PowerMode.saver));
    await tester.pumpWidget(OrecchinoMobileApp(app: app));
    await tab(tester, app, 'Detectors');
    expect(find.textContaining('Flat is the natural choice'), findsOneWidget);
    await tester.runAsync(() => app.setLook(AppLook.flat));
    await settle(tester, app);
    expect(find.textContaining('Flat is the natural choice'), findsNothing);
    await finish(tester, app);
  });

  for (final look in AppLook.values) {
    for (final (name, size, text) in [
      ('portrait', const Size(393, 852), 1.0),
      ('portrait, 2x text', const Size(393, 852), 2.0),
      ('landscape', const Size(852, 393), 1.0),
    ]) {
      testWidgets('${look.label}, $name: every main screen lays out', (tester) async {
        tester.view.physicalSize = size * 3;
        tester.view.devicePixelRatio = 3;
        tester.platformDispatcher.textScaleFactorTestValue = text;
        addTearDown(() {
          tester.view.reset();
          tester.platformDispatcher.clearTextScaleFactorTestValue();
        });
        final app = await demoApp(tester, stored: look);
        await tester.pumpWidget(OrecchinoMobileApp(app: app));
        await settle(tester, app);
        expect(tester.takeException(), isNull);
        expect(find.byType(BackdropFilter), look == AppLook.flat ? findsNothing : findsWidgets);
        await tester.tap(find.text('Map').first, warnIfMissed: false);
        await settle(tester, app);
        expect(tester.takeException(), isNull);
        for (final t in ['Find', 'History', 'Detectors', 'Live']) {
          await tab(tester, app, t);
          expect(tester.takeException(), isNull, reason: t);
        }
        final ctx = tester.element(find.byType(Scaffold).first);
        unawaited(DroneDetailsSheet.showLive(ctx, app, app.tracker.contacts.first.key));
        await settle(tester, app);
        expect(tester.takeException(), isNull);
        expect(find.textContaining('UAS ID'), findsWidgets);
        await finish(tester, app);
      });
    }
  }
}
