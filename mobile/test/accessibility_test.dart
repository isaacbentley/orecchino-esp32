// accessibility_test.dart — text contrast (WCAG AA 4.5:1), screen-reader
// words on radar marks and rows, and the Live screen at 2x text size with no
// overflow.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orecchino_mobile/app/app_controller.dart';
import 'package:orecchino_mobile/core/ble/ble_service.dart';
import 'package:orecchino_mobile/core/location/location_service.dart';
import 'package:orecchino_mobile/core/protocol/messages.dart';
import 'package:orecchino_mobile/core/traffic/traffic_rules.dart';
import 'package:orecchino_mobile/data/db.dart';
import 'package:orecchino_mobile/features/live/live_view.dart';
import 'package:orecchino_mobile/ui/theme.dart';

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
  test('text colours reach 4.5:1 on every background', () {
    const backgrounds = [OrecchinoTheme.ground, OrecchinoTheme.surface, OrecchinoTheme.surfaceHigh];
    const texts = {
      'text': OrecchinoTheme.text,
      'muted': OrecchinoTheme.muted,
      'subtle': OrecchinoTheme.subtle,
      'accent': OrecchinoTheme.accent,
      'amber': OrecchinoTheme.amber,
      'danger': OrecchinoTheme.danger,
      'advisoryBlue': OrecchinoTheme.advisoryBlue,
      'ok': OrecchinoTheme.ok,
    };
    for (final bg in backgrounds) {
      for (final e in texts.entries) {
        expect(contrast(e.value, bg), greaterThanOrEqualTo(4.5), reason: '${e.key} on $bg');
      }
    }
    // Banner text on its own tint (level colour at 18% over ground).
    for (final c in [OrecchinoTheme.danger, OrecchinoTheme.amber, OrecchinoTheme.advisoryBlue]) {
      final tint = Color.alphaBlend(c.withValues(alpha: 0.18), OrecchinoTheme.ground);
      expect(contrast(c, tint), greaterThanOrEqualTo(4.5), reason: 'banner $c');
      // Bridge badge: ground-coloured text on the solid level colour.
      expect(contrast(OrecchinoTheme.ground, c), greaterThanOrEqualTo(4.5), reason: 'badge $c');
    }
  });

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
      ], now);
      app.tick();
    });

    tearDown(() => app.dispose());

    Future<void> pumpLive(WidgetTester tester, double scale) async {
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: OrecchinoTheme.darkTheme,
        home: MediaQuery(
          data: MediaQueryData(size: const Size(390, 844), textScaler: TextScaler.linear(scale)),
          child: LiveView(app: app),
        ),
      ));
      await tester.pump();
    }

    testWidgets('marks and rows read the same words to a screen reader', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpLive(tester, 1.0);
      // The traffic banner leads with the rule's words.
      expect(find.textContaining('TRAFFIC NEAR DRONE D9A03'), findsWidgets);
      // A radar mark for the drone with its alert and range, as in its row.
      final drone = find.bySemanticsLabel(RegExp(r'^Drone D9A03, EMERGENCY REPORTED, TRAFFIC NEAR DRONE D9A03, 334 m'));
      expect(drone, findsNWidgets(2)); // the mark and the list row
      expect(find.bySemanticsLabel(RegExp(r'^Aircraft UAL123, TRAFFIC NEAR DRONE D9A03')), findsWidgets);
      expect(find.bySemanticsLabel(RegExp(r'^Radar, heading up, 3.0 km range, 3 marks')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('2x text: no overflow anywhere down the screen', (tester) async {
      await pumpLive(tester, 2.0);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.text('CONTACTS (3)'), 200);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.textContaining('UAL123'), 200);
      expect(tester.takeException(), isNull);
      // A selected drone's card, below the radar, at 2x.
      await tester.tap(find.textContaining('UAL123').last);
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.textContaining('Positions as reported'), -200);
      expect(tester.takeException(), isNull);
    });
  });
}
