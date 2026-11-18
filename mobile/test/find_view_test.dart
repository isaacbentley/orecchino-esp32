// find_view_test.dart — the Find screen follows the app, not its rebuilds:
// a rebuild (a text-size change, a parent rebuild) plays no haptic cue and
// does not move the pointer's baseline; a real change in the target's
// bearing does. And the pointer settles: no frames once it has arrived.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orecchino_mobile/app/app_controller.dart';
import 'package:orecchino_mobile/core/ble/ble_service.dart';
import 'package:orecchino_mobile/core/location/location_service.dart';
import 'package:orecchino_mobile/core/protocol/messages.dart';
import 'package:orecchino_mobile/data/db.dart';
import 'package:orecchino_mobile/features/find/find_view.dart';
import 'package:orecchino_mobile/ui/theme/theme.dart';

import 'support/fakes.dart';

class TurningLocation extends LocationService {
  double h = 0;
  @override
  Future<void> start() async {}
  @override
  PhoneLocation? get currentLocation => const PhoneLocation(lat: 37.8039, lon: -122.464, timeMs: 0);
  @override
  double? get headingDeg => h;
  void turn(double to) {
    h = to;
    notifyListeners();
  }
}

void main() {
  testWidgets('haptics follow the app, not rebuilds; the pointer settles', (tester) async {
    final haptics = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') haptics.add('${call.arguments}');
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    final loc = TurningLocation();
    final app = AppController(
      db: AppDatabase(NativeDatabase.memory()),
      ble: BleService(transport: FakeTransport()),
      location: loc,
      startTimers: false,
    );
    await tester.runAsync(app.start);
    app.tracker.ingest(
        HostMessage.parse(jsonEncode({
          'type': 'rid',
          'src': 'ble',
          'mac': 'AA:BB:CC:DD:EE:01',
          'basic_id': [
            {'id_type': 1, 'ua_type': 2, 'uas_id': '1581F20000D9A03'}
          ],
          // Due north of the phone, about 330 m.
          'loc': {'status': 2, 'lat': 37.8069, 'lon': -122.4640, 'height': 100.0, 'height_ref': 0},
        })) as RidMessage,
        app.nowMs(),
        app.observer);
    app.tick();

    Widget view(double scale) => MaterialApp(
          theme: OrecchinoTheme.dark,
          home: MediaQuery(
            data: MediaQueryData(size: const Size(390, 844), textScaler: TextScaler.linear(scale)),
            child: Scaffold(body: FindView(app: app)),
          ),
        );

    loc.turn(100); // facing east: the drone is 100 degrees to the left
    await tester.pumpWidget(view(1));
    await tester.pump(const Duration(seconds: 2));
    final before = haptics.length;

    // Rebuilds with nothing changed in the app: no cue.
    await tester.pumpWidget(view(1.3));
    await tester.pump();
    await tester.pumpWidget(view(1));
    await tester.pump();
    expect(haptics.length, before);

    // The pointer has arrived: nothing is animating.
    await tester.pump(const Duration(seconds: 3));
    expect(tester.binding.transientCallbackCount, 0, reason: 'no ticker left running');

    // Turning toward it: a tick per 15-degree step, and a firmer tap on lock.
    // (The app passes compass changes on at most every 50 ms of real time.)
    Future<void> settle() => tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await settle();
    loc.turn(40);
    await tester.pump(const Duration(milliseconds: 50));
    expect(haptics.length, greaterThan(before));
    await settle();
    loc.turn(2);
    await tester.pump(const Duration(milliseconds: 50));
    expect(haptics.last, 'HapticFeedbackType.mediumImpact');
    expect(find.text('ON TARGET'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() async => app.dispose());
  });
}
