// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orecchino_mobile/core/droneguide/droneguide.dart';
import 'package:orecchino_mobile/features/droneguide/droneguide_widgets.dart';
import 'package:orecchino_mobile/features/live/live_items.dart';
import 'package:orecchino_mobile/features/live/live_map.dart';
import 'package:orecchino_mobile/ui/theme/theme.dart';

void main() {
  testWidgets('Droneguide choices and live opt-in are independent from layer visibility', (tester) async {
    final semantics = tester.ensureSemantics();
    final service = DroneguideService(persistent: false);
    addTearDown(service.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: OrecchinoTheme.dark,
      home: Scaffold(body: DroneguideSettingsTile(service: service)),
    ));
    await tester.tap(find.text('Belgian geozones · Droneguide'));
    await tester.pumpAndSettle();

    expect(service.autoRefresh, isFalse);
    expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Refresh now')).onPressed, isNull);
    final activeChoice = tester.getSemantics(find.bySemanticsLabel('Active only')).getSemanticsData();
    expect(activeChoice.hasAction(SemanticsAction.tap), isTrue);
    semantics.dispose();
    await tester.tap(find.text('Active only'));
    await tester.pumpAndSettle();
    expect(service.activeOnly, isTrue);

    await tester.tap(find.text('Show layer on the map'));
    await tester.pumpAndSettle();
    expect(service.layerEnabled, isFalse);
    expect(service.activeOnly, isTrue);
    expect(service.autoRefresh, isFalse);

    await tester.tap(find.text('All zones'));
    await tester.pumpAndSettle();
    expect(service.activeOnly, isFalse);
    expect(service.layerEnabled, isFalse);
  });

  testWidgets('map details show overlapping Droneguide zones, then filter out unknown activity', (tester) async {
    final polygon = {
      'type': 'Polygon',
      'coordinates': [
        [
          [4.28, 50.81],
          [4.42, 50.81],
          [4.42, 50.89],
          [4.28, 50.89],
          [4.28, 50.81],
        ],
      ],
    };
    Map<String, Object?> zone(String id, String name, {bool scheduled = false}) => {
          'type': 'Feature',
          'geometry': polygon,
          'properties': {
            'country': 'BEL',
            'identifier': id,
            'name': name,
            'restriction': 'REQ_AUTHORISATION',
            'lower': 0,
            'upper': 100,
            'lowerReference': 'AGL',
            'upperReference': 'AGL',
            'unit': 'M',
            if (scheduled) ...{
              'validFrom': '2000-01-01T00:00:00Z',
              'validUntil': '2099-01-01T00:00:00Z',
            },
          },
        };

    final service = (await tester.runAsync(() async {
      final service = DroneguideService(persistent: false);
      await service.importBytes(
        utf8.encode(jsonEncode({
          'type': 'FeatureCollection',
          'features': [
            zone('BE-A', 'Scheduled zone', scheduled: true),
            zone('BE-B', 'Unknown zone'),
          ],
        })),
        filename: 'test-geozones.json',
      );
      await service.setLayerEnabled(true);
      return service;
    }))!;
    addTearDown(service.dispose);
    MapTiles.caching = false;
    MapTiles.providerOverride = _TestTiles.new;
    addTearDown(() {
      MapTiles.caching = true;
      MapTiles.providerOverride = null;
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final history = ContactHistory();
    await tester.pumpWidget(MaterialApp(
      theme: OrecchinoTheme.dark,
      home: Scaffold(
        body: ListenableBuilder(
          listenable: service,
          builder: (_, __) => LiveMap(
            droneguide: service,
            items: const [],
            bridges: const [],
            history: history,
            selectedId: null,
            observerLat: 50.85,
            observerLon: 4.35,
            headingDeg: null,
            rangeM: 3000,
            viewport: const Rect.fromLTWH(0, 200, 390, 400),
            onSelect: (_) {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final polygons = find.byType(PolygonLayer<DroneguideZone>);
    expect(tester.widget<PolygonLayer<DroneguideZone>>(polygons).polygons, hasLength(2));
    await tester.tapAt(const Offset(195, 400));
    // flutter_map waits for a possible double-tap before calling onTap.
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('2 overlapping Belgian geozones'), findsOneWidget);
    expect(find.text('Scheduled zone'), findsOneWidget);
    expect(find.text('Unknown zone'), findsOneWidget);
    Navigator.pop(tester.element(find.text('Scheduled zone')));
    await tester.pumpAndSettle();

    await tester.runAsync(() => service.setActiveOnly(true));
    await tester.pumpAndSettle();
    expect(tester.widget<PolygonLayer<DroneguideZone>>(polygons).polygons.single.hitValue?.id, 'BE-A');
    await tester.runAsync(() => service.setLayerEnabled(false));
    await tester.pumpAndSettle();
    expect(polygons, findsNothing);
    expect(service.activeOnly, isTrue);
  });
}

class _TestTiles extends TileProvider {
  static final _pixel = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
  );

  @override
  ImageProvider<Object> getImage(TileCoordinates coordinates, TileLayer options) => MemoryImage(_pixel);
}
