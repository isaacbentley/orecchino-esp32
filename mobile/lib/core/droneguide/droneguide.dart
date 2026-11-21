// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data' show BytesBuilder;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

part 'droneguide_activity.dart';
part 'droneguide_parser.dart';
part 'droneguide_service.dart';

const droneguideMaxBytes = 12 * 1024 * 1024;
const droneguideCeilingMeters = 500 * 0.3048;
const _maxFeatures = 10000;
const _maxPoints = 500000;

typedef DroneguidePolygon = List<List<LatLng>>;

class DroneguideZone {
  final String id;
  final String name;
  final String restriction;
  final String reason;
  final String message;
  final List<DroneguidePolygon> polygons;
  final double? lower;
  final double? upper;
  final String lowerReference;
  final String upperReference;
  final String lowerUnit;
  final String upperUnit;
  final double? lowerAglM;
  final double? upperAglM;
  final String validFrom;
  final String validUntil;
  final String schedule;
  final List<String> authorities;
  final List<String> conditions;
  final List<DroneguidePeriod> applicability;

  /// Activity reported at the WFS window start. Local imports have no
  /// trustworthy timestamp for this flag.
  final bool? activity;

  const DroneguideZone({
    required this.id,
    required this.name,
    required this.restriction,
    required this.polygons,
    this.reason = '',
    this.message = '',
    this.lower,
    this.upper,
    this.lowerReference = '',
    this.upperReference = '',
    this.lowerUnit = '',
    this.upperUnit = '',
    this.lowerAglM,
    this.upperAglM,
    this.validFrom = '',
    this.validUntil = '',
    this.schedule = '',
    this.authorities = const [],
    this.conditions = const [],
    this.applicability = const [],
    this.activity,
  });
}

class DroneguideSnapshot {
  final String source;
  final String? sourceName;
  final DateTime fetchedAt;
  final DateTime? snapshotAt;
  final List<DroneguideZone> zones;
  final int skipped;
  final int unknownAltitudeCount;

  const DroneguideSnapshot({
    required this.source,
    required this.fetchedAt,
    required this.zones,
    this.sourceName,
    this.snapshotAt,
    this.skipped = 0,
    this.unknownAltitudeCount = 0,
  });
}
