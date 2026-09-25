// alert_capsule_test.dart — the alert capsule announces an alert once: its
// live region carries only the action and the rule's words, so a screen
// reader is not made to restart the sentence every second as the data age
// and the range tick. The age and the range stay on the button's own node.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orecchino_mobile/core/traffic/traffic_rules.dart';
import 'package:orecchino_mobile/features/live/alert_capsule.dart';
import 'package:orecchino_mobile/features/live/live_items.dart';
import 'package:orecchino_mobile/ui/theme/theme.dart';

TrafficAlert alert({required double ageS, double? cpaS}) => TrafficAlert(
      level: TrafficLevel.warning,
      kind: TrafficKind.converging,
      droneId: '1581F20000D9A03',
      hex: 'a1b2c3',
      callsign: 'UAL123',
      horizM: 110,
      vertM: 80,
      bearingDeg: 0,
      cpaS: cpaS,
      ageS: ageS,
      text: 'TRAFFIC NEAR DRONE D9A03',
      vertRel: TrafficVertical.above,
      action: 'GIVE WAY: DESCEND AND LAND D9A03',
      resolution: 'GIVE WAY: DESCEND AND LAND D9A03; AIRCRAFT 80 M ABOVE, 110 M N'
          '${cpaS == null ? '' : ', CLOSEST IN ${cpaS.round()} S'}',
    );

LiveContactItem drone({required double distanceM, required double ageSeconds}) => LiveContactItem(
      id: '1581F999E412A002',
      label: '2A002',
      distanceM: distanceM,
      bearingDeg: 90,
      isAircraft: false,
      ageSeconds: ageSeconds,
      alertWords: const ['EMERGENCY REPORTED'],
      alertLevel: TrafficLevel.warning,
    );

Widget capsule({TrafficAlert? traffic, LiveContactItem? droneAlert, required int nowMs}) => MaterialApp(
      theme: OrecchinoTheme.dark,
      home: MediaQuery(
        data: const MediaQueryData(size: Size(390, 844)),
        child: Scaffold(
          body: Center(
            child: AlertCapsule(
              traffic: traffic,
              trafficExtra: traffic == null ? null : '2 o\'clock',
              droneAlert: droneAlert,
              idleText: '2 drones',
              nowMs: nowMs,
              onSelect: (_) {},
            ),
          ),
        ),
      ),
    );

/// The one live-region node under the capsule, and its label.
SemanticsNode liveNode(WidgetTester tester) {
  final nodes = <SemanticsNode>[];
  void walk(SemanticsNode n) {
    if (n.flagsCollection.isLiveRegion) nodes.add(n);
    n.visitChildren((SemanticsNode c) {
      walk(c);
      return true;
    });
  }

  walk(tester.getSemantics(find.byType(AlertCapsule)));
  expect(nodes, hasLength(1), reason: 'one live region per alert');
  return nodes.single;
}

void main() {
  testWidgets('a traffic alert: the live region does not change as the age and geometry tick', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(capsule(traffic: alert(ageS: 3, cpaS: 24), nowMs: 1000));
    await tester.pump(const Duration(seconds: 1));
    final live = liveNode(tester);
    final announced = live.label;
    expect(announced, 'GIVE WAY: DESCEND AND LAND D9A03, TRAFFIC NEAR DRONE D9A03');
    expect(announced, isNot(contains('s old')));
    // The button says it all, age included.
    expect(
        find.bySemanticsLabel(RegExp(r'^GIVE WAY: DESCEND AND LAND D9A03, AIRCRAFT 80 M ABOVE, 110 M N, '
            r"CLOSEST IN 24 S, TRAFFIC NEAR DRONE D9A03 · ADS-B 3 s old, 2 o'clock$")),
        findsOneWidget);

    // Two ticks: the age and the closest-approach time move on.
    await tester.pumpWidget(capsule(traffic: alert(ageS: 4, cpaS: 23), nowMs: 2000));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(capsule(traffic: alert(ageS: 5, cpaS: 22), nowMs: 3000));
    await tester.pump(const Duration(seconds: 1));
    expect(find.bySemanticsLabel(RegExp(r'CLOSEST IN 22 S, TRAFFIC NEAR DRONE D9A03 · ADS-B 5 s old')),
        findsOneWidget);
    final after = liveNode(tester);
    expect(after.label, announced);
    expect(after.id, live.id, reason: 'the same node, not a new one (a new one would announce)');
    // Only the words that lead: never the age, the range or the geometry.
    expect(after.label, isNot(contains('M ABOVE')));
    expect(after.label, isNot(contains('CLOSEST')));
    handle.dispose();
  });

  testWidgets('a drone alert: the live region keeps its words as the range changes', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(capsule(droneAlert: drone(distanceM: 485, ageSeconds: 1), nowMs: 1000));
    await tester.pump(const Duration(seconds: 1));
    final live = liveNode(tester);
    expect(live.label, 'EMERGENCY REPORTED, drone 2A002');
    expect(find.bySemanticsLabel('EMERGENCY REPORTED, drone 2A002, 485 m'), findsOneWidget);
    await tester.pumpWidget(capsule(droneAlert: drone(distanceM: 470, ageSeconds: 2), nowMs: 2000));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(capsule(droneAlert: drone(distanceM: 455, ageSeconds: 3), nowMs: 3000));
    await tester.pump(const Duration(seconds: 1));
    expect(find.bySemanticsLabel('EMERGENCY REPORTED, drone 2A002, 455 m'), findsOneWidget);
    final after = liveNode(tester);
    expect(after.label, live.label);
    expect(after.id, live.id);
    handle.dispose();
  });

  testWidgets('the live region says the action and the rule, in that order, in both looks', (tester) async {
    for (final look in AppLook.values) {
      Look.setForTest(look);
      addTearDown(() => Look.setForTest(AppLook.sky));
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(capsule(traffic: alert(ageS: 3), nowMs: 1000));
      await tester.pump(const Duration(seconds: 1));
      expect(liveNode(tester).label, startsWith('GIVE WAY: DESCEND AND LAND D9A03'));
      expect(AlertCapsule.liveAlertLabel(alert(ageS: 9)), 'GIVE WAY: DESCEND AND LAND D9A03, TRAFFIC NEAR DRONE D9A03');
      await tester.pumpWidget(const SizedBox());
      handle.dispose();
    }
  });
}
