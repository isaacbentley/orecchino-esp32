// layout_test.dart — every screen in landscape and on a tablet: a phone on
// its side (874 x 402 pt with the Dynamic Island's inset on the left, at 1x
// and 2x text), and an iPad in portrait and landscape. No overflow; the
// tabs move to a rail on a phone on its side; the Live contacts become a
// side panel on wide screens.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orecchino_mobile/app/app_controller.dart';
import 'package:orecchino_mobile/core/ble/ble_service.dart';
import 'package:orecchino_mobile/core/location/location_service.dart';
import 'package:orecchino_mobile/data/db.dart';
import 'package:orecchino_mobile/features/live/contact_sheet.dart';
import 'package:orecchino_mobile/main.dart';
import 'package:orecchino_mobile/ui/glass_nav_bar.dart';

import 'support/fakes.dart';

class NoLocation extends LocationService {
  @override
  Future<void> start() async {}
}

class Device {
  final String name;
  final Size size;
  final EdgeInsets padding;
  final double textScale;
  final bool rail;
  const Device(this.name, this.size, this.padding, {this.textScale = 1, this.rail = false});
}

const devices = [
  Device('phone landscape', Size(874, 402), EdgeInsets.only(left: 62, right: 62, bottom: 21), rail: true),
  Device('phone landscape 2x text', Size(874, 402), EdgeInsets.only(left: 62, right: 62, bottom: 21),
      textScale: 2, rail: true),
  Device('iPad portrait', Size(1024, 1366), EdgeInsets.only(top: 24, bottom: 20)),
  Device('iPad landscape', Size(1366, 1024), EdgeInsets.only(top: 24, bottom: 20)),
];

void main() {
  testWidgets('every screen lays out in landscape and on a tablet', (tester) async {
    final app = AppController(
      db: AppDatabase(NativeDatabase.memory()),
      ble: BleService(transport: FakeTransport()),
      location: NoLocation(),
      startTimers: false,
    );
    await tester.runAsync(() async {
      await app.start();
      await app.setDemo(true);
      await Future<void>.delayed(const Duration(milliseconds: 2300));
      await app.refreshTraffic();
    });
    app.tick();

    for (final d in devices) {
      const dpr = 3.0;
      tester.view.physicalSize = d.size * dpr;
      tester.view.devicePixelRatio = dpr;
      tester.view.padding = FakeViewPadding(
          left: d.padding.left * dpr,
          top: d.padding.top * dpr,
          right: d.padding.right * dpr,
          bottom: d.padding.bottom * dpr);
      tester.platformDispatcher.textScaleFactorTestValue = d.textScale;
      await tester.pumpWidget(OrecchinoMobileApp(key: ValueKey(d.name), app: app));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull, reason: '${d.name}: Live');

      // Tabs: a rail on a phone on its side, the floating bar otherwise.
      expect(find.byType(GlassNavRail), d.rail ? findsOneWidget : findsNothing, reason: d.name);
      expect(find.byType(GlassNavBar), d.rail ? findsNothing : findsOneWidget, reason: d.name);

      // Wide: the contacts are a side panel under the view controls and the
      // status; on a phone on its side (and at 2x) its top can fill it, and
      // the list is a scroll away.
      final panel = tester.widget<ContactSheet>(find.byType(ContactSheet));
      expect(panel.panel, isTrue, reason: '${d.name}: side panel');
      {
        final pos = tester
            .state<ScrollableState>(
                find.descendant(of: find.byType(ContactSheet), matching: find.byType(Scrollable)).first)
            .position;
        // Step down until the list's heading is inside the panel.
        final panelBox = tester.getRect(find.byType(ContactSheet));
        bool inPanel() {
          final f = find.text('DRONES (3)');
          return f.evaluate().isNotEmpty && panelBox.contains(tester.getCenter(f));
        }

        while (!inPanel() && pos.pixels < pos.maxScrollExtent) {
          pos.jumpTo(math.min(pos.pixels + 60, pos.maxScrollExtent));
          await tester.pump();
        }
      }
      final list = tester.getRect(find.text('DRONES (3)'));
      final panelRect = tester.getRect(find.byType(ContactSheet));
      expect(panelRect.right, lessThanOrEqualTo(d.size.width - d.padding.right),
          reason: '${d.name}: clear of the side inset');
      expect(panelRect.overlaps(list), isTrue, reason: '${d.name}: list in the panel');
      expect(tester.takeException(), isNull, reason: '${d.name}: panel scrolled');

      for (final tab in ['Find', 'History', 'Detectors', 'Live']) {
        await tester.tap(find.text(tab).last);
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(tester.takeException(), isNull, reason: '${d.name}: $tab');
      }
    }

    tester.view.reset();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() async => app.dispose());
  });
}
