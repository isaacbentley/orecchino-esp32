// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:orecchino_mobile/core/location/location_service.dart';
import 'package:orecchino_mobile/core/power/power_policy.dart';

class FakeGeolocator extends GeolocatorPlatform {
  final changes = StreamController<ServiceStatus>.broadcast();
  final positions = StreamController<Position>.broadcast();
  final currentRequests = <(AndroidSettings, Completer<Position>)>[];
  final streams = <AndroidSettings>[];
  bool enabled = true;
  LocationPermission permission = LocationPermission.whileInUse;
  int serviceChecks = 0;
  int permissionRequests = 0;

  @override
  Future<bool> isLocationServiceEnabled() async {
    serviceChecks++;
    return enabled;
  }

  @override
  Future<LocationPermission> checkPermission() async => permission;

  @override
  Future<LocationPermission> requestPermission() async {
    permissionRequests++;
    return permission;
  }

  @override
  Stream<ServiceStatus> getServiceStatusStream() => changes.stream;

  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) {
    streams.add(locationSettings! as AndroidSettings);
    return positions.stream;
  }

  @override
  Future<Position> getCurrentPosition({LocationSettings? locationSettings}) {
    final completer = Completer<Position>();
    currentRequests.add((locationSettings! as AndroidSettings, completer));
    return completer.future;
  }

  void setEnabled(bool value) {
    enabled = value;
    changes.add(value ? ServiceStatus.enabled : ServiceStatus.disabled);
  }

  Future<void> close() async {
    await changes.close();
    await positions.close();
  }
}

Position fix(double lat, int seconds) => Position(
      latitude: lat,
      longitude: 4.35,
      timestamp: DateTime.fromMillisecondsSinceEpoch(seconds * 1000),
      accuracy: 10,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

void main() {
  const android = TargetPlatformVariant({TargetPlatform.android});
  late FakeGeolocator platform;
  late LocationService service;

  setUp(() {
    final original = GeolocatorPlatform.instance;
    platform = FakeGeolocator();
    GeolocatorPlatform.instance = platform;
    service = LocationService()..configure(precision: LocationPrecision.high, compassHz: 0);
    addTearDown(() async {
      service.dispose();
      GeolocatorPlatform.instance = original;
      await platform.close();
    });
  });

  testWidgets('starts a bounded request alongside the stream and keeps a newer streamed fix', (tester) async {
    await service.resume();
    expect(platform.serviceChecks, 0);

    await Future.wait<void>([service.start(), service.start(), service.resume()]);
    expect(platform.serviceChecks, 1);
    expect(platform.streams, hasLength(1));
    expect(platform.currentRequests, hasLength(1));
    expect(platform.currentRequests.single.$1.forceLocationManager, isFalse);
    expect(platform.currentRequests.single.$1.timeLimit, const Duration(seconds: 10));
    expect(service.problem, 'Finding your position');

    platform.positions.add(fix(51, 10));
    await tester.pump();
    platform.currentRequests.single.$2.complete(fix(50, 5));
    await tester.pump();
    expect(service.status, LocationStatus.ok);
    expect(service.currentLocation?.lat, 51);
  }, variant: android);

  testWidgets('Android times out on the fused provider and continues on LocationManager', (tester) async {
    await service.start();
    await tester.pump(const Duration(seconds: 10));
    expect(platform.currentRequests.map((request) => request.$1.forceLocationManager), [false, true]);
    platform.currentRequests.last.$2.complete(fix(50, 10));
    await tester.pump();
    expect(service.currentLocation?.lat, 50);
    expect(platform.streams.map((settings) => settings.forceLocationManager), [false, true]);

    platform.positions.add(fix(51, 11));
    await tester.pump();
    expect(service.currentLocation?.lat, 51);
  }, variant: android);

  testWidgets('reports a missing fix after both providers time out and retries on foreground', (tester) async {
    await service.start();
    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 10));
    expect(service.currentLocation, isNull);
    expect(service.status, LocationStatus.error);
    expect(service.problem, contains('has not provided a location fix'));

    await service.resume();
    expect(platform.currentRequests, hasLength(3));
    expect(service.status, LocationStatus.starting);
    platform.currentRequests.last.$2.complete(fix(50, 15));
    await tester.pump();
    expect(service.currentLocation?.lat, 50);
  }, variant: android);

  testWidgets('service switches invalidate old requests and permission is rechecked on foreground', (tester) async {
    await service.start();
    final oldRequest = platform.currentRequests.single.$2;
    platform.setEnabled(false);
    await tester.pump();
    expect(service.status, LocationStatus.servicesOff);

    oldRequest.complete(fix(50, 10));
    await tester.pump();
    expect(service.currentLocation, isNull);

    platform.permission = LocationPermission.denied;
    platform.setEnabled(true);
    await tester.pump();
    await service.resume();
    expect(service.status, LocationStatus.denied);
    expect(platform.permissionRequests, 1);
    expect(platform.currentRequests, hasLength(1));

    platform.permission = LocationPermission.whileInUse;
    await service.resume();
    expect(platform.currentRequests, hasLength(2));
    platform.currentRequests.last.$2.complete(fix(51, 11));
    await tester.pump();
    expect(service.currentLocation?.lat, 51);
  }, variant: android);
}
