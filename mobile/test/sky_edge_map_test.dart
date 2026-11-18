// sky_edge_map_test.dart — beyond the range, a mark is pinned to the outer
// ring at its true bearing (a 44 pt target with "beyond <range>" words);
// operators get their own marks; the Map mode shows only the aircraft an
// alert names, always shows its attribution, and says when it is offline.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' show TileProvider, TileCoordinates, TileLayer;
import 'package:flutter_test/flutter_test.dart';
import 'package:orecchino_mobile/app/app_controller.dart';
import 'package:orecchino_mobile/core/ble/ble_service.dart';
import 'package:orecchino_mobile/core/location/location_service.dart';
import 'package:orecchino_mobile/core/protocol/messages.dart';
import 'package:orecchino_mobile/core/traffic/adsb_source.dart';
import 'package:orecchino_mobile/core/traffic/traffic_rules.dart';
import 'package:orecchino_mobile/data/db.dart';
import 'package:orecchino_mobile/features/live/live_map.dart';
import 'package:orecchino_mobile/features/live/live_view.dart';
import 'package:orecchino_mobile/features/live/sky_painter.dart';
import 'package:orecchino_mobile/features/live/sky_projection.dart';
import 'package:orecchino_mobile/features/live/sky_scene.dart';
import 'package:orecchino_mobile/ui/theme/theme.dart';

import 'support/fakes.dart';

class FakeLocation extends LocationService {
  @override
  Future<void> start() async {}
  @override
  PhoneLocation? get currentLocation => const PhoneLocation(lat: 37.8039, lon: -122.464, timeMs: 0);
  @override
  double? get headingDeg => 0;
}

void main() {
  const size = Size(400, 800);
  const viewport = Rect.fromLTWH(0, 100, 400, 500);

  group('beyond the range', () {
    for (final tilt in [0.0, 52.0]) {
      test('pinned to the ring at its bearing, on the ground (tilt $tilt)', () {
        final c = SkyCamera.fit(size: size, viewport: viewport, tiltDeg: tilt, yawDeg: 30, rangeM: 3000);
        for (final brg in [0.0, 45.0, 137.0, 222.0, 300.0]) {
          final p = c.place(4300, brg, heightM: 120)!;
          expect(p.beyond, isTrue);
          final ring = c.project(3000, brg)!.offset; // on the ring, at the ground
          expect((p.point.offset - ring).distance, lessThan(1e-6), reason: 'bearing $brg');
          final inside = c.place(2000, brg, heightM: 120)!;
          expect(inside.beyond, isFalse);
          expect(inside.point.offset, c.project(2000, brg, heightM: 120)!.offset);
        }
        // Flat: the pinned point is on the ring's circle.
        if (tilt == 0) {
          final p = c.place(9000, 77)!.point.offset;
          expect((p - c.center).distance, closeTo(c.ringRadius, 1e-6));
          final a = math.atan2(p.dx - c.center.dx, c.center.dy - p.dy) * 180 / math.pi;
          expect((a + 360) % 360, closeTo(77 - 30, 1e-6)); // heading-up: relative to the view
        }
      });
    }

    testWidgets('a far drone: a 44 pt target on the ring, with "beyond" words, that answers a tap', (tester) async {
      final handle = tester.ensureSemantics();
      tester.view.physicalSize = size * 2;
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final cam = SkyCamera.fit(size: size, viewport: viewport, tiltDeg: 52, yawDeg: 0, rangeM: 3000);
      const far = SkyContact(id: 'far', label: 'F4E1', distanceM: 4300, bearingDeg: 45, heightM: 80, isAircraft: false);
      const item = LiveContactItem(
          id: 'far', label: 'F4E1', distanceM: 4300, bearingDeg: 45, heightM: 80, isAircraft: false, ageSeconds: 1);
      String? tapped;
      await tester.pumpWidget(MaterialApp(
        home: SizedBox.fromSize(
          size: size,
          child: SkyScene(
            camera: cam,
            marks: const [far],
            bridges: const [],
            items: const {'far': item},
            selectedId: null,
            headingDeg: 0,
            showFacing: true,
            clock: null,
            semanticLabel: 'Sky',
            onSelect: (id) => tapped = id,
          ),
        ),
      ));
      final mark = find.bySemanticsLabel(RegExp(r'^Drone F4E1, .*, beyond 3.0 km, 4.3 km NE, shown on the edge$'));
      expect(mark, findsOneWidget);
      final r = tester.getRect(mark);
      expect(r.width, greaterThanOrEqualTo(44));
      expect((r.center - cam.place(4300, 45)!.point.offset).distance, lessThan(1));
      await tester.tapAt(r.center);
      expect(tapped, 'far');
      handle.dispose();
    });
  });

  group('app', () {
    late AppController app;
    setUp(() async {
      MapTiles.caching = false;
      app = AppController(
        db: AppDatabase(NativeDatabase.memory()),
        ble: BleService(transport: FakeTransport()),
        location: FakeLocation(),
        startTimers: false,
      );
      await app.start();
      final now = app.nowMs();
      app.tracker.ingest(
          HostMessage.parse(jsonEncode({
            'type': 'rid',
            'src': 'ble',
            'mac': 'AA:BB:CC:DD:EE:01',
            'basic_id': [
              {'id_type': 1, 'ua_type': 2, 'uas_id': '1581F20000D9A03'}
            ],
            'loc': {
              'status': 2,
              'lat': 37.8069,
              'lon': -122.4640,
              'alt_geo': 120.0,
              'height': 100.0,
              'height_ref': 0,
              'speed': 5.0,
              'dir': 90
            },
            'system': {'op_lat': 37.8045, 'op_lon': -122.4668, 'op_alt': 10.0, 'op_loc_type': 0},
          })) as RidMessage,
          now,
          app.observer);
      app.traffic.update([
        TrafficAircraft(
            hex: 'a1b2c3',
            callsign: 'UAL123',
            lat: 37.8079,
            lon: -122.4640,
            altGeomM: 200,
            altBaroM: 190,
            gsMps: 60,
            trackDeg: 180,
            seenMs: now - 3000),
        TrafficAircraft(
            hex: 'c0ffee',
            callsign: 'DAL9',
            lat: 37.8039,
            lon: -122.5140,
            altGeomM: 3000,
            altBaroM: 2980,
            gsMps: 200,
            trackDeg: 270,
            seenMs: now - 2000),
      ], now, const AdsbArea(37.8039, -122.4640, 10000));
      app.tick();
    });
    tearDown(() => app.dispose());

    Future<void> pumpLive(WidgetTester tester) async {
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: OrecchinoTheme.dark,
        home: MediaQuery(data: const MediaQueryData(size: Size(390, 844)), child: LiveView(app: app)),
      ));
      await tester.pump();
    }

    testWidgets('the sky: an operator pin with its words, linked to its drone', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpLive(tester);
      expect(find.bySemanticsLabel(RegExp(r'^Operator of drone D9A03, \d+ m SW of the drone, \d+ m from you')),
          findsOneWidget);
      final painter =
          tester.widgetList<CustomPaint>(find.byType(CustomPaint)).map((p) => p.painter).whereType<SkyPainter>().first;
      final op = painter.contacts.singleWhere((c) => c.isOperator);
      expect(op.linkTo, '1581F20000D9A03');
      expect(op.label, matches(RegExp(r'^operator \d+ m SW$')));
      handle.dispose();
    });

    testWidgets('Map mode: only the aircraft an alert names, the attribution, offline said in words', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpLive(tester);
      await tester.tap(find.bySemanticsLabel('Map view'));
      await tester.pump();
      expect(find.byType(LiveMap), findsOneWidget);
      // The alerting aircraft is on the map; the other one is not anywhere.
      expect(find.bySemanticsLabel(RegExp(r'^Aircraft UAL123, GIVE WAY')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('DAL9')), findsNothing);
      expect(mapAircraft(buildLiveItems(app)).map((c) => c.label), ['UAL123']);
      // The drone and its operator are marks too.
      expect(find.bySemanticsLabel(RegExp(r'^Drone D9A03')), findsWidgets);
      expect(find.bySemanticsLabel(RegExp(r'^Operator of drone D9A03')), findsOneWidget);
      // Attribution: always there, and tappable.
      final attribution = find.bySemanticsLabel(RegExp(r'^Map data Esri, HERE, Garmin, © OpenStreetMap contributors'));
      expect(attribution, findsOneWidget);
      expect(tester.getSemantics(attribution), isSemantics(isButton: true));
      // No network in tests: every tile fails, and the map says so over its grid.
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      final state = tester.state<LiveMapState>(find.byType(LiveMap));
      expect(state.offline, isTrue);
      await tester.pump();
      expect(find.text('Map tiles unavailable: showing a plain grid'), findsOneWidget);
      await tester.tap(attribution);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.textContaining('openstreetmap.org/copyright'), findsOneWidget);
      handle.dispose();
    });

    // The map shows its tiles, or says why it cannot.
    Future<LiveMapState> pumpMap(WidgetTester tester,
        {double? lat, double? lon, double? savedLat, double? savedLon}) async {
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: OrecchinoTheme.dark,
        home: SizedBox(
          width: 390,
          height: 844,
          child: LiveMap(
            items: const [],
            bridges: const [],
            history: ContactHistory(),
            selectedId: null,
            observerLat: lat,
            observerLon: lon,
            headingDeg: null,
            rangeM: 3000,
            viewport: const Rect.fromLTWH(0, 200, 390, 400),
            onSelect: (_) {},
            fallbackLat: savedLat,
            fallbackLon: savedLon,
          ),
        ),
      ));
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      return tester.state<LiveMapState>(find.byType(LiveMap));
    }

    testWidgets('tiles that load are drawn, and the map says nothing', (tester) async {
      MapTiles.providerOverride = _MemoryTiles.new;
      addTearDown(() => MapTiles.providerOverride = null);
      final s = await pumpMap(tester, lat: 37.8039, lon: -122.464);
      expect(s.tilesShown, isTrue);
      expect(s.status, isNull);
      expect(find.byType(RawImage), findsWidgets); // tile images on screen
    });

    testWidgets('no fix yet: centred on the last saved position, and says it is finding yours', (tester) async {
      MapTiles.providerOverride = _MemoryTiles.new;
      addTearDown(() => MapTiles.providerOverride = null);
      final s = await pumpMap(tester, savedLat: 37.80, savedLon: -122.46);
      expect(s.tilesShown, isTrue);
      expect(find.text('Finding your position… (centred on your last one)'), findsOneWidget);
    });

    testWidgets('no position at all and no network: says both, never a blank screen', (tester) async {
      final s = await pumpMap(tester);
      expect(s.offline, isTrue);
      expect(find.text('Map tiles unavailable: showing a plain grid'), findsOneWidget);
      expect(s.status, 'Map tiles unavailable: showing a plain grid');
      await tester.pump();
    });
  });
}

/// Tiles from memory: a 1x1 dark PNG for every tile.
class _MemoryTiles extends TileProvider {
  static final _png =
      base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) => MemoryImage(_png);
}
