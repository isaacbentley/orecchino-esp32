// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orecchino_mobile/core/droneguide/droneguide.dart';

const _polygon = {
  'type': 'Polygon',
  'coordinates': [
    [
      [4.0, 50.0],
      [4.3, 50.0],
      [4.3, 50.2],
      [4.0, 50.0],
    ],
  ],
};

Map<String, Object?> _feature(
  String identifier,
  Map<String, Object?> properties, {
  Object? geometry = _polygon,
}) =>
    {
      'type': 'Feature',
      'geometry': geometry,
      'properties': {
        'unique_identifier': identifier,
        'restriction': 'CONDITIONAL',
        'country': 'BEL',
        ...properties,
      },
    };

Map<String, Object?> _ground() => {
      'lowerLimit': 0,
      'lowerVerticalReference': 'AGL',
      'upperLimit': 90,
      'upperVerticalReference': 'AGL',
      'uomDimensions': 'M',
    };

String _collection(List<Object?> features, {int? total}) => jsonEncode({
      'type': 'FeatureCollection',
      'features': features,
      if (total != null) 'numberMatched': total,
      if (total != null) 'totalFeatures': total,
      if (total != null) 'numberReturned': features.length,
    });

void main() {
  test('imports the inclusive AGL band without assuming MSL is AGL', () async {
    final service = DroneguideService(persistent: false);
    addTearDown(service.dispose);
    final source = _collection([
      _feature('boundary', {
        'lower_limit_altitude': 500,
        'lower_limit_reference': 'AGL',
        'lower_limit_unit': 'F',
        'lower_limit_altitude_meter_agl': 153,
        'upper_limit_altitude_meter_agl': 500,
        'name': '{"nl":"Grenszone","en":"Boundary zone"}',
      }),
      _feature('above', {
        'lower_limit_altitude': 501,
        'lower_limit_reference': 'AGL',
        'lower_limit_unit': 'F',
        'lower_limit_altitude_meter_agl': 100,
      }),
      _feature('ground', {
        'lower_limit_reference': 'GND',
        'upper_limit_reference': 'MSL',
        'upper_limit_altitude': 1500,
      }),
      _feature('unknown', {
        'lower_limit_altitude': 1,
        'lower_limit_reference': 'MSL',
        'upper_limit_altitude': 200,
        'upper_limit_reference': 'MSL',
      }),
    ]);
    await service.importBytes(utf8.encode(source),
        filename: 'geozones.geojson');

    expect(service.error, isNull);
    expect(service.snapshot?.source, 'import');
    expect(service.snapshot?.sourceName, 'geozones.geojson');
    expect(service.snapshot?.unknownAltitudeCount, 1);
    expect(service.visibleZones.map((zone) => zone.id), ['boundary', 'ground']);
    expect(service.visibleZones.first.name, 'Grenszone');
    expect(service.visibleZones.first.lowerAglM, droneguideCeilingMeters);
    expect(
        service.visibleZones.first.polygons.single.single.first.latitude, 50);
  });

  test('persists the import and activity preference, including ED overnight',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('orecchino-droneguide');
    addTearDown(() => directory.delete(recursive: true));
    Future<File> storage() async => File('${directory.path}/cache.json');
    var now = DateTime.utc(2026, 11, 17, 0, 30);
    final service = DroneguideService(storageFile: storage, now: () => now);
    addTearDown(service.dispose);
    final source = jsonEncode({
      'features': [
        {
          'identifier': 'BE-A',
          'restriction': 'PROHIBITED',
          'country': 'BE',
          'applicability': [
            {
              'permanent': 'YES',
              'schedule': [
                {
                  'day': ['MON'],
                  'startTime': '22:00:00Z',
                  'endTime': '02:00:00Z',
                },
              ],
            },
          ],
          'geometry': [
            {
              ..._ground(),
              'horizontalProjection': {
                'type': 'Circle',
                'center': [4.2, 50.1],
                'radius': 1000,
              },
            },
          ],
        },
      ],
    });
    await service.importBytes(utf8.encode(source), filename: 'ed-269.json');
    await service.setActiveOnly(true);
    expect(service.visibleZones.single.id, 'BE-A');
    expect(service.visibleZones.single.polygons.single.single.length,
        greaterThan(96));
    service.setForeground(false);
    now = DateTime.utc(2026, 11, 17, 2);
    expect(service.visibleZones, isEmpty);

    final restored = DroneguideService(storageFile: storage, now: () => now);
    addTearDown(restored.dispose);
    await restored.initialize();
    expect(restored.activeOnly, isTrue);
    expect(restored.snapshot?.zones.single.id, 'BE-A');
    expect(restored.visibleZones, isEmpty);
    now = DateTime.utc(2026, 11, 16, 23);
    expect(restored.visibleZones.single.id, 'BE-A');
  });

  test('WFS is opt-in and failed or stale activity does not qualify', () async {
    var now = DateTime.utc(2026, 11, 19, 10);
    final requests = <Uri>[];
    var networkFailed = false;
    final client = MockClient((request) async {
      requests.add(request.url);
      if (networkFailed) return http.Response('unavailable', 503);
      final index = request.url.queryParameters['startIndex'];
      final feature = index == '0'
          ? _feature('active', {..._ground(), 'active_at_window_start': 0})
          : _feature('inactive', {..._ground(), 'active_at_window_start': 1});
      return http.Response(_collection([feature], total: 2), 200);
    });
    addTearDown(client.close);
    final service = DroneguideService(
      persistent: false,
      client: client,
      now: () => now,
    );
    addTearDown(service.dispose);
    service.setForeground(false);
    await service.initialize();
    await service.refresh();
    expect(requests, isEmpty);
    await service.setAutoRefresh(true);
    expect(requests, isEmpty);
    await service.refresh();

    expect(
        requests.map((uri) => uri.queryParameters['startIndex']), ['0', '1']);
    expect(requests.first.host, 'map.droneguide.be');
    expect(requests.first.queryParameters['viewParams'],
        contains('show_planned:true'));
    expect(requests.first.queryParameters['cql_filter'], contains('152.4'));
    expect(service.error, isNull);
    expect(service.snapshot?.source, 'live');
    expect(service.snapshot?.snapshotAt, now);
    await service.setActiveOnly(true);
    expect(service.visibleZones.single.id, 'active');

    networkFailed = true;
    await service.refresh();
    expect(service.stale, isTrue);
    expect(service.visibleZones, isEmpty);
    expect(service.snapshot?.zones, hasLength(2));
    expect(service.error, contains('HTTP 503'));

    networkFailed = false;
    await service.refresh();
    expect(service.visibleZones.single.id, 'active');
    now = now.add(droneguideFreshness);
    expect(service.stale, isTrue);
    expect(service.visibleZones, isEmpty);
  });

  test('import activity uses explicit validity rather than a saved WFS flag',
      () async {
    var now = DateTime.utc(2026, 11, 19, 10);
    final service = DroneguideService(persistent: false, now: () => now);
    addTearDown(service.dispose);
    final file = _collection([
      _feature('valid', {
        ..._ground(),
        'validFrom': '2026-11-19T09:00:00Z',
        'validUntil': '2026-11-19T11:00:00Z',
        'active_at_window_start': 1,
      }),
      _feature('ambiguous', {
        ..._ground(),
        'validFrom': '2026-11-19T09:00:00Z',
        'validUntil': '2026-11-19T11:00:00Z',
        'schedule': 'Check NOTAM',
        'active_at_window_start': 0,
      }),
    ]);
    await service.importBytes(utf8.encode(file), filename: 'geozones.geojson');
    await service.setActiveOnly(true);
    expect(service.visibleZones.single.id, 'valid');
    now = DateTime.utc(2026, 11, 19, 11);
    expect(service.visibleZones, isEmpty);
    final old = service.snapshot;
    await service.importBytes(utf8.encode('{"features":[42]}'),
        filename: 'bad.json');
    expect(service.error, isNotNull);
    expect(service.snapshot, same(old));
  });

  test('reports activity expiry while the app is open', () async {
    var now = DateTime.utc(2026, 11, 19, 10);
    final service = DroneguideService(persistent: false, now: () => now);
    addTearDown(service.dispose);
    final file = _collection([
      _feature('valid', {
        ..._ground(),
        'validFrom': '2026-11-19T09:00:00Z',
        'validUntil': '2026-11-19T11:00:00Z',
      }),
    ]);
    await service.importBytes(utf8.encode(file), filename: 'expiry.geojson');
    await service.setActiveOnly(true);
    expect(service.visibleZones, hasLength(1));

    final expiry = Completer<void>();
    service.addListener(() {
      if (service.visibleZones.isEmpty && !expiry.isCompleted) {
        expiry.complete();
      }
    });
    now = DateTime.utc(2026, 11, 19, 11);
    await expiry.future.timeout(const Duration(seconds: 5));
  });
}
