// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
part of 'droneguide.dart';

typedef _Json = Map<String, Object?>;
typedef _ParsedZones = ({List<DroneguideZone> zones, int skipped, int unknown});

enum _AltitudeMatch { unknown, outside, inside }

class _NoArea implements Exception {
  const _NoArea();
}

_Json _object(Object? raw, [String message = 'Expected a JSON object.']) {
  if (raw is _Json) return raw;
  throw FormatException(message);
}

List<Object?> _array(Object? raw, [String message = 'Expected a JSON list.']) {
  if (raw is List<Object?>) return raw;
  throw FormatException(message);
}

Object? _decode(String raw) {
  final text = raw.startsWith('\uFEFF') ? raw.substring(1) : raw;
  return jsonDecode(text);
}

String _string(Object? value) => value is String ? value.trim() : '';

String _first(Iterable<String> values) {
  for (final value in values) {
    if (value.isNotEmpty) return value;
  }
  return '';
}

String _text(Object? raw) {
  if (raw is String) {
    if (!raw.trimLeft().startsWith('{')) return raw.trim();
    try {
      final Object? decoded = _decode(raw);
      if (decoded is _Json) return _text(decoded);
    } on FormatException {
      return raw.trim();
    }
    return raw.trim();
  }
  if (raw is _Json) {
    final keys = raw.keys.toList()..sort();
    return _first([
      for (final key in ['nl', 'nl-BE', 'en', 'fr', 'de', ...keys])
        _string(raw[key]),
    ]);
  }
  if (raw is List<Object?>) {
    return raw.map(_string).where((part) => part.isNotEmpty).join(', ');
  }
  return '';
}

double? _number(Object? value) =>
    value is num && value.isFinite ? value.toDouble() : null;

String _unit(String value) => switch (value.toUpperCase()) {
      'F' || 'FEET' || 'FT' => 'FT',
      'METRES' || 'METERS' || 'M' => 'M',
      final other => other,
    };

double? _directAgl(double? value, String reference, String unit) {
  final ground = reference == 'GND' || reference == 'SFC';
  if (!ground && reference != 'AGL') return null;
  if (value == null) return ground ? 0 : null;
  return switch (unit) {
    'M' => value,
    'FT' => value * 0.3048,
    '' when value == 0 => 0,
    _ => null,
  };
}

_AltitudeMatch _intersectsAltitude(double? lower, double? upper) {
  // A boundary in range establishes overlap even with an unknown
  // opposite bound. Inconsistent known limits cannot establish overlap.
  if (lower != null && upper != null && lower > upper) {
    return _AltitudeMatch.unknown;
  }
  if ((lower != null && lower > droneguideCeilingMeters) ||
      (upper != null && upper < 0)) {
    return _AltitudeMatch.outside;
  }
  if ((lower != null && upper != null) ||
      (lower != null && lower >= 0) ||
      (upper != null && upper <= droneguideCeilingMeters)) {
    return _AltitudeMatch.inside;
  }
  return _AltitudeMatch.unknown;
}

void _checkCrs(_Json featureCollection) {
  final crs = featureCollection['crs'];
  if (crs == null) return;
  final properties = _object(_object(crs)['properties']);
  final name = _string(properties['name']).toUpperCase();
  if (!name.endsWith(':4326') &&
      !name.endsWith(':CRS84') &&
      !name.endsWith('/CRS84')) {
    throw const FormatException('The dataset does not use WGS 84.');
  }
}

String _restriction(Object? raw) {
  final value = _string(raw).toUpperCase();
  return switch (value) {
    'PROHIBITED' ||
    'REQ_AUTHORISATION' ||
    'CONDITIONAL' ||
    'NO_RESTRICTION' =>
      value,
    'REQ_AUTHORIZATION' => 'REQ_AUTHORISATION',
    _ => throw FormatException('Unknown restriction: $value.'),
  };
}

final _validityTime = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:[.,]\d+)?(Z|[+-]\d{2}:\d{2})$',
);

DateTime? _validTime(String field) {
  if (field.isEmpty) return null;
  final match = _validityTime.firstMatch(field);
  if (match == null) throw const FormatException('Invalid validity time.');
  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  final calendar = DateTime.utc(year, month, day);
  final offset = match[7]!;
  if (calendar.month != month ||
      calendar.day != day ||
      int.parse(match[4]!) > 23 ||
      int.parse(match[5]!) > 59 ||
      int.parse(match[6]!) > 59 ||
      (offset != 'Z' &&
          (int.parse(offset.substring(1, 3)) > 23 ||
              int.parse(offset.substring(4, 6)) > 59))) {
    throw const FormatException('Invalid validity time.');
  }
  return DateTime.parse(field);
}

void _checkValidity(String from, String until) {
  final start = _validTime(from);
  final end = _validTime(until);
  if (start != null && end != null && start.isAfter(end)) {
    throw const FormatException('The validity period ends before it starts.');
  }
}

List<String> _strings(Object? raw) => raw is List<Object?>
    ? raw.map(_string).where((part) => part.isNotEmpty).toList()
    : const [];

({String from, String until, String schedule}) _timing(_Json p) {
  final periods =
      _array(p['applicability'] ?? const <Object?>[]).map(_object).toList();
  final from = _first([
    _string(p['validFrom']),
    if (periods.length == 1) _string(periods.first['startDateTime'])
  ]);
  final until = _first([
    _string(p['validUntil']),
    if (periods.length == 1) _string(periods.first['endDateTime'])
  ]);
  _checkValidity(from, until);
  final descriptions = <String>[];
  for (final period in periods) {
    final start = _string(period['startDateTime']);
    final end = _string(period['endDateTime']);
    _checkValidity(start, end);
    final details = [
      if (_string(period['permanent']).toUpperCase() == 'YES') 'Permanent',
      if (periods.length > 1 && start.isNotEmpty) 'From $start',
      if (periods.length > 1 && end.isNotEmpty) 'Until $end',
    ];
    for (final raw in _array(period['schedule'] ?? const <Object?>[])) {
      final daily = _object(raw);
      final startTime = _string(daily['startTime']);
      final endTime = _string(daily['endTime']);
      if (startTime.isNotEmpty || endTime.isNotEmpty) {
        final days = _strings(daily['day']).join(', ');
        details.add('$days $startTime – $endTime'.trim());
      }
    }
    if (details.isNotEmpty) descriptions.add(details.join(' · '));
  }
  return (
    from: from,
    until: until,
    schedule: _first([_string(p['schedule']), descriptions.join(' | ')]),
  );
}

List<String> _authorities(Object? raw) {
  final entries = _array(raw ?? const <Object?>[]);
  return List.unmodifiable([
    for (final entry in entries.map(_object))
      [
        for (final field in [
          'name',
          'service',
          'contactName',
          'email',
          'phone',
          'siteURL',
          'purpose',
          'intervalBefore',
        ])
          if (_string(entry[field]).isNotEmpty) _string(entry[field]),
      ].join(' · '),
  ].where((entry) => entry.isNotEmpty));
}

DroneguideZone _zone(
  _Json metadata,
  _Json altitude,
  List<DroneguidePolygon> polygons, {
  required String id,
  required bool geoJson,
  required bool live,
}) {
  final country = _string(metadata['country']).toUpperCase();
  if (country.isNotEmpty && country != 'BE' && country != 'BEL') {
    throw const FormatException('The zone is outside Belgium.');
  }
  if (id.isEmpty) throw const FormatException('The zone has no identifier.');
  final restrictions = _restriction(metadata['restriction']);
  final lower = _number(altitude['lowerLimit']) ??
      (geoJson
          ? _number(altitude['lower_limit_altitude']) ??
              _number(altitude['lower'])
          : null);
  final upper = _number(altitude['upperLimit']) ??
      (geoJson
          ? _number(altitude['upper_limit_altitude']) ??
              _number(altitude['upper'])
          : null);
  final lowerRef = _first([
    _string(altitude['lowerVerticalReference']),
    if (geoJson) ...[
      _string(altitude['lower_limit_reference']),
      _string(altitude['lowerReference'])
    ],
  ]).toUpperCase();
  final upperRef = _first([
    _string(altitude['upperVerticalReference']),
    if (geoJson) ...[
      _string(altitude['upper_limit_reference']),
      _string(altitude['upperReference'])
    ],
  ]).toUpperCase();
  final units = _first([
    _string(altitude['uomDimensions']),
    if (geoJson) _string(altitude['unit'])
  ]);
  final lowerUnit = _unit(_first([
    if (geoJson) ...[
      _string(altitude['lower_limit_unit']),
      _string(altitude['lowerUnit'])
    ],
    units,
  ]));
  final upperUnit = _unit(_first([
    if (geoJson) ...[
      _string(altitude['upper_limit_unit']),
      _string(altitude['upperUnit'])
    ],
    units,
  ]));
  final lowerAgl = _directAgl(lower, lowerRef, lowerUnit) ??
      (geoJson ? _number(altitude['lower_limit_altitude_meter_agl']) : null);
  final upperAgl = _directAgl(upper, upperRef, upperUnit) ??
      (geoJson ? _number(altitude['upper_limit_altitude_meter_agl']) : null);
  final timing = _timing(metadata);
  final flag = geoJson && live ? metadata['active_at_window_start'] : null;
  final reason = [
    _text(metadata['reason']),
    _string(metadata['otherReasonInfo'])
  ].where((value) => value.isNotEmpty).join(' · ');
  return DroneguideZone(
    id: id,
    name: _first([_text(metadata['name']), id]),
    restriction: restrictions,
    reason: _first([reason, _string(metadata['type_code'])]),
    message:
        _first([_text(metadata['message']), _text(metadata['description'])]),
    polygons: List.unmodifiable(polygons),
    lower: lower,
    upper: upper,
    lowerReference: lowerRef,
    upperReference: upperRef,
    lowerUnit: lowerUnit,
    upperUnit: upperUnit,
    lowerAglM: lowerAgl,
    upperAglM: upperAgl,
    validFrom: timing.from,
    validUntil: timing.until,
    schedule: timing.schedule,
    activity: flag == 0
        ? true
        : flag == 1
            ? false
            : null,
    authorities: _authorities(metadata['zoneAuthority']),
    conditions: List.unmodifiable(_strings(metadata['restrictionConditions'])),
    applicability: _periods(metadata['applicability']),
  );
}

LatLng _point(Object? raw) {
  final values = _array(raw, 'Invalid map point.');
  if (values.length >= 2) {
    final longitude = _number(values[0]);
    final latitude = _number(values[1]);
    if (longitude != null &&
        latitude != null &&
        longitude.abs() <= 180 &&
        latitude.abs() <= 90) {
      return LatLng(latitude, longitude);
    }
  }
  throw const FormatException('Invalid map point.');
}

bool _hasArea(List<LatLng> ring) {
  if (ring.length < 3) return false;
  var previous = ring.last;
  final origin = ring.first;
  var area = 0.0;
  double relativeLongitude(LatLng point) =>
      (point.longitude - origin.longitude + 180) % 360 - 180;
  for (final point in ring) {
    area += relativeLongitude(previous) * (point.latitude - origin.latitude) -
        relativeLongitude(point) * (previous.latitude - origin.latitude);
    previous = point;
  }
  return area != 0;
}

DroneguidePolygon _polygon(Object? raw, bool live) {
  final rings = _array(raw, 'Invalid polygon coordinates.');
  if (rings.isEmpty) throw const _NoArea();
  final polygon = <List<LatLng>>[];
  for (var index = 0; index < rings.length; index++) {
    final ring =
        _array(rings[index], 'Invalid polygon ring.').map(_point).toList();
    if (!_hasArea(ring)) {
      if (index == 0 || !live) throw const _NoArea();
      continue;
    }
    if (ring.first != ring.last) ring.add(ring.first);
    polygon.add(List.unmodifiable(ring));
  }
  return List.unmodifiable(polygon);
}

bool _isSupplementary(String type) => const {
      'point',
      'multipoint',
      'linestring',
      'multilinestring',
    }.contains(type);

List<DroneguidePolygon> _polygons(Object? raw, bool live, [int depth = 0]) {
  if (raw == null) throw const _NoArea();
  if (depth > 12) {
    throw const FormatException('The geometry is nested too deeply.');
  }
  final geometry = _object(raw, 'Invalid zone geometry.');
  final type = _string(geometry['type']).toLowerCase();
  switch (type) {
    case 'polygon':
      return [_polygon(geometry['coordinates'], live)];
    case 'multipolygon':
      final polygons = <DroneguidePolygon>[];
      for (final item in _array(
          geometry['coordinates'], 'Invalid MultiPolygon coordinates.')) {
        try {
          polygons.add(_polygon(item, live));
        } on _NoArea {
          if (!live) rethrow;
        }
      }
      if (polygons.isEmpty) throw const _NoArea();
      return polygons;
    case 'circle':
      final center = _point(geometry['center']);
      final radius = _number(geometry['radius']);
      if (radius == null || radius <= 0 || radius > 1000000) {
        throw const FormatException('Invalid circle radius.');
      }
      final segments = (math.pi / math.acos(1 - math.min(0.5 / radius, 1)))
          .ceil()
          .clamp(96, 720);
      const distance = Distance(calculator: Vincenty());
      final ring = List<LatLng>.generate(
        segments,
        (index) => distance.offset(center, radius, 360 * index / segments),
      );
      return [
        [
          List.unmodifiable([...ring, ring.first])
        ],
      ];
    case 'geometrycollection':
      final result = <DroneguidePolygon>[];
      for (final rawPart in _array(geometry['geometries'])) {
        final part = _object(rawPart);
        if (_isSupplementary(_string(part['type']).toLowerCase())) continue;
        try {
          result.addAll(_polygons(part, live, depth + 1));
        } on _NoArea {
          if (!live) rethrow;
        }
      }
      if (result.isEmpty) throw const _NoArea();
      return result;
    default:
      if (live && _isSupplementary(type)) throw const _NoArea();
      throw FormatException('Unsupported zone geometry: $type.');
  }
}

List<DroneguideZone> _featureZones(Object? raw, bool geoJson, bool live) {
  final feature = _object(raw, 'Invalid zone object.');
  if (geoJson || feature['type'] == 'Feature') {
    if (feature['type'] != 'Feature') {
      throw const FormatException('Invalid GeoJSON feature.');
    }
    final properties =
        _object(feature['properties'], 'Missing GeoJSON properties.');
    if (_string(properties['type_code']).toUpperCase() == 'TIME_ZONE') {
      return const [];
    }
    final rawId = feature['id'];
    final id = _first([
      _string(properties['identifier']),
      _string(properties['unique_identifier']),
      rawId is num ? rawId.toString() : _string(rawId),
      _string(properties['code']),
    ]);
    final polygons = _polygons(feature['geometry'], live);
    return [
      _zone(properties, properties, polygons, id: id, geoJson: true, live: live)
    ];
  }
  final id = _string(feature['identifier']);
  final volumes = _array(feature['geometry'], 'Missing ED-269 zone volumes.');
  if (volumes.isEmpty || volumes.length > _maxFeatures) {
    throw const FormatException('The ED-269 zone has no valid volumes.');
  }
  return [
    for (var index = 0; index < volumes.length; index++)
      _edVolume(feature, _object(volumes[index]),
          index == 0 ? id : '$id#${index + 1}'),
  ];
}

DroneguideZone _edVolume(_Json feature, _Json volume, String id) => _zone(
      feature,
      volume,
      _polygons(volume['horizontalProjection'], false),
      id: id,
      geoJson: false,
      live: false,
    );

_ParsedZones _parseZones(({String raw, bool live}) job) {
  final decoded = _decode(job.raw);
  final root = decoded is _Json ? decoded : null;
  final geoJson =
      root?['type'] == 'FeatureCollection' || root?['type'] == 'Feature';
  if (job.live && root?['type'] != 'FeatureCollection') {
    throw const FormatException(
        'Droneguide did not return a GeoJSON collection.');
  }
  if (geoJson && root != null) _checkCrs(root);
  final List<Object?> features;
  if (decoded is List<Object?>) {
    features = decoded;
  } else if (root != null && root.containsKey('features')) {
    features = _array(root['features'], 'Invalid zone collection.');
  } else if (root != null) {
    features = [root];
  } else {
    throw const FormatException('Invalid geozone JSON.');
  }
  if (features.isEmpty || features.length > _maxFeatures) {
    throw const FormatException(
        'The dataset must contain between 1 and 10,000 features.');
  }
  final zones = <DroneguideZone>[];
  final ids = <String>{};
  var points = 0;
  var skipped = 0;
  var unknown = 0;
  for (var index = 0; index < features.length; index++) {
    final List<DroneguideZone> parsed;
    try {
      parsed = _featureZones(features[index], geoJson, job.live);
    } on _NoArea {
      if (!job.live) {
        throw FormatException('Zone ${index + 1} has a polygon with no area.');
      }
      skipped++;
      continue;
    } on FormatException catch (error) {
      throw FormatException('Zone ${index + 1}: ${error.message}');
    }
    for (final zone in parsed) {
      if (!ids.add(zone.id)) {
        throw FormatException('Duplicate zone identifier: ${zone.id}.');
      }
      for (final polygon in zone.polygons) {
        for (final ring in polygon) {
          points += ring.length;
        }
      }
      if (ids.length > _maxFeatures || points > _maxPoints) {
        throw const FormatException(
            'The dataset contains too many zones or map points.');
      }
      switch (_intersectsAltitude(zone.lowerAglM, zone.upperAglM)) {
        case _AltitudeMatch.inside:
          zones.add(zone);
        case _AltitudeMatch.unknown:
          unknown++;
        case _AltitudeMatch.outside:
          break;
      }
    }
  }
  if (ids.isEmpty) {
    throw const FormatException('The dataset contains no Belgian geozones.');
  }
  return (zones: List.unmodifiable(zones), skipped: skipped, unknown: unknown);
}
