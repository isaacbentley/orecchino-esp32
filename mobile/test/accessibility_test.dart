// accessibility_test.dart — text contrast (WCAG AA 4.5:1) on every surface,
// glass panel and living-background colour; screen-reader words on the sky's
// marks and the contact cards; and the Live screen at 2x text size with no
// overflow, down through the sheet and the selected aircraft's card.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orecchino_mobile/app/app_controller.dart';
import 'package:orecchino_mobile/core/alerts/alert_policy.dart';
import 'package:orecchino_mobile/core/ble/ble_service.dart';
import 'package:orecchino_mobile/core/location/location_service.dart';
import 'package:orecchino_mobile/core/protocol/messages.dart';
import 'package:orecchino_mobile/core/traffic/adsb_source.dart';
import 'package:orecchino_mobile/core/traffic/traffic_rules.dart';
import 'package:orecchino_mobile/data/db.dart';
import 'package:orecchino_mobile/features/live/live_view.dart';
import 'package:orecchino_mobile/features/live/sky_painter.dart';
import 'package:orecchino_mobile/ui/ambient_clock.dart';
import 'package:orecchino_mobile/ui/glass.dart';
import 'package:orecchino_mobile/ui/living_background.dart';
import 'package:orecchino_mobile/ui/theme/theme.dart';

import 'support/fakes.dart';

double _lum(Color c) {
  double ch(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

double contrast(Color a, Color b) {
  final la = _lum(a), lb = _lum(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

class FakeLocation extends LocationService {
  @override
  Future<void> start() async {}
  @override
  PhoneLocation? get currentLocation => const PhoneLocation(lat: 37.8039, lon: -122.464, timeMs: 0);
  @override
  double? get headingDeg => 0;
}

void main() {
  for (final look in AppLook.values) {
  test('${look.label}: text colours reach 4.5:1 on every background', () {
    Look.setForTest(look);
    addTearDown(() => Look.setForTest(AppLook.sky));
    final texts = {
      'ink': OrecchinoColors.ink,
      'inkMuted': OrecchinoColors.inkMuted,
      'inkSubtle': OrecchinoColors.inkSubtle,
      'aqua': OrecchinoColors.aqua,
      'aircraft': OrecchinoColors.aircraft,
      'caution': OrecchinoColors.caution,
      'warning': OrecchinoColors.warning,
      'advisory': OrecchinoColors.advisory,
      'ok': OrecchinoColors.ok,
    };
    // Surfaces, glass over each living-background colour, and those colours
    // bare (the shader never draws brighter than a palette's highlight).
    final backgrounds = OrecchinoColors.textBackgrounds;
    expect(backgrounds.length, greaterThanOrEqualTo(21));
    for (final bg in backgrounds) {
      for (final e in texts.entries) {
        expect(contrast(e.value, bg), greaterThanOrEqualTo(4.5), reason: '${e.key} on $bg');
      }
    }
    for (final c in [
      OrecchinoColors.warning,
      OrecchinoColors.caution,
      OrecchinoColors.advisory,
      OrecchinoColors.aqua,
    ]) {
      // Alert text on glass washed with its own colour (the alert capsule,
      // selected cards), over the darkest and every brightest background.
      for (final behind in [
        OrecchinoColors.void0,
        OrecchinoColors.auroraCalm.last,
        OrecchinoColors.auroraCaution.last,
        OrecchinoColors.auroraWarning.last,
      ]) {
        final wash =
            Color.alphaBlend(c.withValues(alpha: OrecchinoColors.washAlpha), OrecchinoColors.glassOver(behind));
        expect(contrast(c, wash), greaterThanOrEqualTo(4.5), reason: 'alert $c over $behind');
      }
      // Bridge badge and filled tags: deep-space text on the solid colour.
      expect(contrast(OrecchinoColors.void0, c), greaterThanOrEqualTo(4.5), reason: 'badge $c');
      // Flat: the mockups' dark banner of the colour, with the colour's
      // words and ink on it.
      if (look == AppLook.flat) {
        final banner = Glass.flatWash(c);
        expect(contrast(c, banner), greaterThanOrEqualTo(4.5), reason: 'flat banner $c');
        expect(contrast(OrecchinoColors.ink, banner), greaterThanOrEqualTo(4.5), reason: 'ink on banner $c');
        expect(contrast(OrecchinoColors.inkMuted, banner), greaterThanOrEqualTo(4.5), reason: 'muted on banner $c');
      }
    }
  });

  test('${look.label}: text drawn straight onto the sky keeps 4.5:1 over a star, on its halo', () {
    Look.setForTest(look);
    addTearDown(() => Look.setForTest(AppLook.sky));
    // The worst case: the brightest living-background colour plus a star at
    // its peak (shaders/aurora.frag), under the dark halo every canvas label
    // is drawn on (lib/ui/canvas_text.dart).
    final canvasTexts = {
      'ink': OrecchinoColors.ink,
      'inkMuted': OrecchinoColors.inkMuted,
      'inkSubtle': OrecchinoColors.inkSubtle,
      'aqua': OrecchinoColors.aqua,
      'caution': OrecchinoColors.caution,
      'warning': OrecchinoColors.warning,
    };
    final worst = OrecchinoColors.haloBackgrounds;
    expect(worst.length, 9);
    for (final bg in worst) {
      for (final e in canvasTexts.entries) {
        expect(contrast(e.value, bg), greaterThanOrEqualTo(4.5), reason: '${e.key} on star + halo $bg');
      }
    }
    // Without the halo a star would break it: the halo is doing the work
    // (Sky; Flat has no stars).
    if (look == AppLook.sky) {
      final bare = Color.alphaBlend(OrecchinoColors.starPeak.withValues(alpha: 1), OrecchinoColors.auroraCalm.last);
      expect(contrast(OrecchinoColors.inkSubtle, bare), lessThan(4.5));
    }
  });
  }

  group('Live screen', () {
    late AppController app;

    setUp(() async {
      app = AppController(
        db: AppDatabase(NativeDatabase.memory()),
        ble: BleService(transport: FakeTransport()),
        location: FakeLocation(),
        startTimers: false,
      );
      await app.start();
      final now = app.nowMs();
      for (final (id, lat, lon, status) in [
        ('1581F20000D9A03', 37.8069, -122.4640, 3),
        ('1581F999E412A002', 37.8009, -122.4600, 2),
      ]) {
        app.tracker.ingest(
            HostMessage.parse(jsonEncode({
              'type': 'rid',
              'src': 'ble',
              'mac': 'AA:BB:CC:DD:EE:0${id.length % 10}',
              'basic_id': [
                {'id_type': 1, 'ua_type': 2, 'uas_id': id}
              ],
              'loc': {
                'status': status,
                'lat': lat,
                'lon': lon,
                'alt_geo': 120.0,
                'height': 100.0,
                'height_ref': 0,
                'speed': 5.0,
                'dir': 90
              },
            })) as RidMessage,
            now,
            app.observer);
      }
      app.traffic.update([
        TrafficAircraft(
            hex: 'a1b2c3',
            callsign: 'UAL123',
            type: 'B738',
            lat: 37.8079,
            lon: -122.4640,
            altGeomM: 200,
            altBaroM: 190,
            gsMps: 60,
            trackDeg: 180,
            seenMs: now - 3000),
      ], now, const AdsbArea(37.8039, -122.4640, 10000));
      app.tick();
    });

    tearDown(() => app.dispose());

    Future<void> pumpLive(WidgetTester tester, double scale) async {
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: OrecchinoTheme.dark,
        home: MediaQuery(
          data: MediaQueryData(size: const Size(390, 844), textScaler: TextScaler.linear(scale)),
          child: LiveView(app: app),
        ),
      ));
      await tester.pump();
    }

    Finder sheetScrollable() =>
        find.descendant(of: find.byType(DraggableScrollableSheet), matching: find.byType(Scrollable)).first;

    Future<void> settle(WidgetTester tester) async {
      // The sky keeps animating (the sweep), so pump a fixed time instead of
      // waiting for it to settle.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('marks and cards read the same words to a screen reader', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpLive(tester, 1.0);
      // The alert capsule leads with the action, then the geometry and the rule.
      expect(find.text('GIVE WAY: DESCEND AND LAND D9A03'), findsWidgets);
      expect(
          find.bySemanticsLabel(RegExp(r'^GIVE WAY: DESCEND AND LAND D9A03, AIRCRAFT 80 M ABOVE, .*, '
              r'TRAFFIC NEAR DRONE D9A03 · ADS-B 3 s old')),
          findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Sky view, 3D, heading up, 3.0 km range, 3 marks')), findsOneWidget);
      // The sheet's handle says what it holds (drones only); pull it all the way up.
      expect(find.bySemanticsLabel(RegExp(r'^Drones sheet, 2 drones, show or hide')), findsOneWidget);
      await tester.drag(find.text('drones'), const Offset(0, -700));
      await settle(tester);
      // A mark on the sky for the drone with its alert's action, the
      // geometry and the rule, and its range, as its card.
      final drone = find.bySemanticsLabel(RegExp(r'^Drone D9A03, EMERGENCY REPORTED, GIVE WAY: DESCEND AND LAND D9A03, '
          r'AIRCRAFT 80 M ABOVE, 110 M N, CLOSEST IN [0-9]+ S, TRAFFIC NEAR DRONE D9A03, 334 m'));
      expect(drone, findsNWidgets(2)); // the mark and the card
      // The aircraft in the alert: a mark on the sky, never a card.
      expect(find.bySemanticsLabel(RegExp(r'^Aircraft UAL123, GIVE WAY: DESCEND AND LAND D9A03')), findsOneWidget);
      expect(find.text('DRONES (2)'), findsOneWidget);
      // The conflict watch says it is on.
      expect(
          find.bySemanticsLabel(RegExp(r'^conflict watch on, 1 ADS-B conflict|^conflict watch on, 2 ADS-B conflicts')),
          findsOneWidget);
      // Every mark is a 44 pt target.
      for (final e in drone.evaluate()) {
        final size = tester.getSize(find.byWidget(e.widget));
        expect(size.width, greaterThanOrEqualTo(44));
        expect(size.height, greaterThanOrEqualTo(44));
      }
      handle.dispose();
    });

    testWidgets('2x text: no overflow anywhere down the screen', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpLive(tester, 2.0);
      expect(tester.takeException(), isNull);
      // The aircraft's card (from its mark on the sky: it has no row), at the
      // top of the sheet, at 2x.
      await tester.tap(find.bySemanticsLabel(RegExp(r'^Aircraft UAL123')).first);
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('GIVE WAY: DESCEND AND LAND D9A03'), findsWidgets);
      // Drag the sheet all the way up and walk down it.
      await tester.drag(find.text('drones'), const Offset(0, -700));
      await settle(tester);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.textContaining('Positions as reported'), 200, scrollable: sheetScrollable());
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.text('DRONES (2)'), 200, scrollable: sheetScrollable());
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.text('2A002'), 200, scrollable: sheetScrollable());
      expect(tester.takeException(), isNull);
      handle.dispose();
    });

    testWidgets('the living background animates, and stops under reduce motion', (tester) async {
      // A change of level cross-fades the palette on the ambient clock
      // (without a GPU the aurora itself is a still gradient).
      await tester.pumpWidget(const MediaQuery(data: MediaQueryData(), child: LivingBackground()));
      await tester.pumpWidget(
          const MediaQuery(data: MediaQueryData(), child: LivingBackground(level: TrafficLevel.caution)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(AmbientClock.instance.running, isTrue);
      await tester.pump(const Duration(seconds: 2)); // the fade ends: the clock stops
      await tester.pump();
      expect(AmbientClock.instance.running, isFalse);
      await tester.pumpWidget(const MediaQuery(
          data: MediaQueryData(disableAnimations: true), child: LivingBackground(key: ValueKey('still'))));
      await tester.pumpWidget(const MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: LivingBackground(key: ValueKey('still'), level: TrafficLevel.warning)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(AmbientClock.instance.running, isFalse);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('reduce motion: the sky, the sweep and the lights stop moving', (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: OrecchinoTheme.dark,
        home: MediaQuery(
          data: const MediaQueryData(size: Size(390, 844), disableAnimations: true),
          child: Stack(children: [const Positioned.fill(child: LivingBackground()), LiveView(app: app)]),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.hasScheduledFrame, isFalse);
      // Without reduce motion the scene keeps animating.
      await tester.pumpWidget(MaterialApp(
        theme: OrecchinoTheme.dark,
        home: MediaQuery(data: const MediaQueryData(size: Size(390, 844)), child: LiveView(app: app)),
      ));
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.hasScheduledFrame, isTrue);
    });

    testWidgets('a drone emergency is not hidden by a traffic alert: the capsule shows both', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpLive(tester, 1.0);
      // Drone D9A03 reports an emergency and is also in a traffic pair.
      expect(find.bySemanticsLabel(RegExp(r'^EMERGENCY REPORTED, drone D9A03')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^GIVE WAY: DESCEND AND LAND D9A03, ')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('44 pt targets: the sheet handle and the range segments', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpLive(tester, 1.0);
      for (final f in [
        find.bySemanticsLabel(RegExp(r'^Drones sheet')),
        find.bySemanticsLabel('1 km range'),
        find.bySemanticsLabel('3 km range'),
        find.bySemanticsLabel('5 km range'),
      ]) {
        final size = tester.getSize(f);
        expect(size.width, greaterThanOrEqualTo(44), reason: '$f');
        expect(size.height, greaterThanOrEqualTo(44), reason: '$f');
      }
      handle.dispose();
    });

    testWidgets('reduce motion: selecting a mark jumps the sheet (no zero-length animation)', (tester) async {
      final handle = tester.ensureSemantics();
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: OrecchinoTheme.dark,
        home: MediaQuery(
          data: const MediaQueryData(size: Size(390, 844), disableAnimations: true),
          child: LiveView(app: app),
        ),
      ));
      await tester.pump();
      await tester.tap(find.bySemanticsLabel(RegExp(r'^Aircraft UAL123')).first);
      await tester.pump();
      expect(tester.takeException(), isNull);
      // The selected aircraft's card is up in the sheet at once.
      expect(find.textContaining('Positions as reported'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('a mark answers a tap at once; a double tap on the sky resets the view', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpLive(tester, 1.0);
      // One frame after the tap: no wait to rule out a double tap.
      final mark = find.bySemanticsLabel(RegExp(r'^Aircraft UAL123')).first;
      await tester.tap(mark);
      await tester.pump();
      expect(tester.getSemantics(mark), isSemantics(isSelected: true));

      await tester.tap(find.bySemanticsLabel('1 km range'));
      await tester.pump();
      expect(find.bySemanticsLabel(RegExp(r'^Sky view, 3D, heading up, 1.0 km range')), findsOneWidget);
      // Double tap on open sky (away from the marks and the header).
      // Open sky: between the header and the sheet (back down to its peek:
      // with both alerts the header is tall).
      await settle(tester);
      await tester.tap(find.bySemanticsLabel(RegExp(r'^Drones sheet')));
      await settle(tester);
      final headerBottom = tester.getRect(find.byType(SingleChildScrollView).first).bottom;
      final sheetTop = tester.getRect(find.bySemanticsLabel(RegExp(r'^Drones sheet'))).top;
      final sky = Offset(20, (headerBottom + sheetTop) / 2);
      await tester.tapAt(sky);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(sky);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.bySemanticsLabel(RegExp(r'^Sky view, 3D, heading up, 3.0 km range')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('an aircraft no alert names is never drawn, listed, counted or announced', (tester) async {
      final handle = tester.ensureSemantics();
      final now = app.nowMs();
      // UAL123 near D9A03 as before, and DAL9 high and far: no alert names it.
      app.traffic.update([
        ...app.traffic.aircraft,
        TrafficAircraft(
            hex: 'c0ffee',
            callsign: 'DAL9',
            type: 'A321',
            lat: 37.8039,
            lon: -122.5140, // ~4.4 km west of the phone, 4.4 km from both drones
            altGeomM: 3000,
            altBaroM: 2980,
            gsMps: 200,
            trackDeg: 270,
            seenMs: now - 2000),
      ], now, const AdsbArea(37.8039, -122.4640, 10000));
      app.tick();
      expect(app.traffic.aircraft.map((a) => a.hex), contains('c0ffee'));
      expect(app.traffic.result.alertForHex('c0ffee'), isNull);
      // Not an item: so not on the sky, in the sheet, in Find or in the counts.
      expect(buildLiveItems(app).map((c) => c.label), isNot(contains('DAL9')));
      await pumpLive(tester, 1.0);
      await tester.drag(find.text('drones'), const Offset(0, -700));
      await settle(tester);
      expect(find.textContaining('DAL9'), findsNothing);
      expect(find.bySemanticsLabel(RegExp('DAL9')), findsNothing);
      expect(find.bySemanticsLabel(RegExp(r'^Sky view, .*, 3 marks')), findsOneWidget); // 2 drones + UAL123
      expect(find.textContaining('aircraft'), findsNothing); // no aircraft count anywhere
      // Nor a notification.
      final events = AlertPolicy().consider(
          nowMs: now,
          traffic: app.traffic.result,
          aircraft: app.traffic.byHex,
          drones: const [],
          detectorConnected: true);
      expect(events.map((e) => e.body).join(), isNot(contains('DAL9')));
      handle.dispose();
    });

    testWidgets('low traffic: drawn with a line to you, caution, "be ready to land"', (tester) async {
      final handle = tester.ensureSemantics();
      final now = app.nowMs();
      // Only a helicopter 2 km north of you at 300 m, far from both drones'
      // pairs (over 150 m above them): LOW, anchored on you.
      app.traffic.clear();
      app.traffic.update([
        TrafficAircraft(
            hex: 'a7c0de',
            callsign: 'N911SIM',
            type: 'EC35',
            lat: 37.8219,
            lon: -122.4640,
            altGeomM: 300,
            altBaroM: 290,
            gsMps: 45,
            trackDeg: 90,
            seenMs: now - 1500),
      ], now, const AdsbArea(37.8039, -122.4640, 10000));
      app.tick();
      final al = app.traffic.result.alerts.single;
      expect(al.kind, TrafficKind.low);
      expect(al.level, TrafficLevel.caution);
      await pumpLive(tester, 1.0);
      expect(find.text('BE READY TO LAND DRONES'), findsOneWidget);
      expect(
          find.bySemanticsLabel(RegExp(r'^Aircraft N911SIM, BE READY TO LAND DRONES, AIRCRAFT [0-9]+ M ABOVE GROUND')),
          findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^conflict watch on, 1 low aircraft')), findsOneWidget);
      // Drawn: a bridge from you (the sky's centre) to it.
      final live =
          tester.widgetList<CustomPaint>(find.byType(CustomPaint)).map((p) => p.painter).whereType<SkyPainter>();
      expect(live.first.bridges.single.droneId, SkyBridge.you);
      handle.dispose();
    });

    testWidgets('the 2D view and range keep the words in step', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpLive(tester, 1.0);
      await tester.tap(find.bySemanticsLabel('Flat sky view'));
      await tester.tap(find.bySemanticsLabel('1 km range'));
      await settle(tester);
      expect(find.bySemanticsLabel(RegExp(r'^Sky view, flat, heading up, 1.0 km range, 3 marks')), findsOneWidget);
      handle.dispose();
    });
  });
}
