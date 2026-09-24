// wifi_sheet_test.dart — the T5 Wi-Fi sheet: one listener for its life
// (none after a swipe-dismiss), no duplicate networks on rebuilds or
// repeated lines, and every state visible.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orecchino_mobile/core/link/detector_link.dart';
import 'package:orecchino_mobile/core/protocol/messages.dart';
import 'package:orecchino_mobile/features/detectors/wifi_setup_sheet.dart';

class FakeLink implements DetectorLink {
  int listens = 0, cancels = 0;
  late final StreamController<HostMessage> ctl = StreamController<HostMessage>.broadcast(
    onListen: () => listens++,
    onCancel: () => cancels++,
  );
  final List<Map<String, dynamic>> sent = [];
  bool ready = true;

  @override
  Stream<HostMessage> get messages => ctl.stream;
  @override
  bool get isReady => ready;
  @override
  Future<void> send(String command) async {
    if (!ready) throw const LinkNotReady();
    sent.add(jsonDecode(command) as Map<String, dynamic>);
  }

  void line(Map<String, dynamic> m) => ctl.add(HostMessage.parse(jsonEncode(m))!);
  List<String> get commands => sent.map((c) => c['cmd'] as String).toList();
}

Widget host(FakeLink link) => MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(onPressed: () => WifiSetupSheet.show(context, link), child: const Text('open')),
          ),
        ),
      ),
    );

void main() {
  testWidgets('one listener, cancelled when the sheet is dismissed by a tap outside', (tester) async {
    final link = FakeLink();
    await tester.pumpWidget(host(link));
    await tester.tap(find.text('open'));
    // The status light breathes while the sheet waits for the board, so
    // pump past the sheet's entrance instead of waiting for stillness.
    await tester.pump(const Duration(seconds: 1));
    expect(link.listens, 1);
    expect(link.commands, ['wifi_status', 'wifi_scan']);

    // Lines and rebuilds do not add listeners.
    for (var i = 0; i < 5; i++) {
      link.line({'type': 'wifi_net', 'ssid': 'Home', 'rssi': -58, 'secure': true, 'saved': false, 'ch': 6});
      await tester.pump();
    }
    expect(link.listens, 1);
    expect(find.text('Home'), findsOneWidget); // repeated line, one row

    // Dismiss the way a swipe or a tap on the barrier does (not the close button).
    await tester.tapAt(const Offset(10, 10));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(WifiSetupSheet), findsNothing);
    expect(link.cancels, 1);
    expect(link.ctl.hasListener, isFalse);
  });

  testWidgets('empty scan, scan failure and the mode reported by the board', (tester) async {
    final link = FakeLink();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: WifiSetupSheet(link: link))));
    link.line({'type': 'wifi_status', 'state': 'idle', 'mode': 'stay', 'every_min': 30, 'saved': <String>[]});
    link.line({'type': 'wifi_scan_done', 'n': 0});
    await tester.pump();
    expect(find.text('No networks found'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);
    final stay = tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Stay connected'));
    final sync = tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Sync every 30 min'));
    expect(stay.selected, isTrue);
    expect(sync.selected, isFalse);

    await tester.tap(find.text('SCAN AGAIN'));
    await tester.pump();
    link.line({'type': 'wifi_scan_done', 'n': 0, 'err': 'scan failed'});
    await tester.pump();
    expect(find.text('Scan failed: scan failed'), findsOneWidget);

    await tester.tap(find.text('Off'));
    await tester.pump();
    expect(link.sent.last, {'cmd': 'wifi_mode', 'mode': 'off', 'every_min': 30});
  });

  testWidgets('join: connecting, then failed with the board\'s reason, then connected', (tester) async {
    final link = FakeLink();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: WifiSetupSheet(link: link))));
    link.line({'type': 'wifi_net', 'ssid': 'Cafe', 'rssi': -70, 'secure': false, 'saved': false});
    link.line({'type': 'wifi_scan_done', 'n': 1});
    await tester.pump();
    await tester.tap(find.text('Cafe'));
    await tester.pump();
    expect(link.sent.last, {'cmd': 'wifi_join', 'ssid': 'Cafe', 'psk': ''});
    expect(find.text('Connecting to Cafe…'), findsOneWidget);

    link.line({'type': 'wifi_status', 'state': 'failed', 'mode': 'sync', 'reason': 'no IP address'});
    await tester.pump();
    expect(find.text('Could not connect: no IP address'), findsOneWidget);

    link.line(
        {'type': 'wifi_status', 'state': 'connected', 'mode': 'sync', 'ssid': 'Cafe', 'ip': '10.0.0.7', 'ch': 11});
    await tester.pump();
    expect(find.text('Connected to Cafe (ch 11) · 10.0.0.7'), findsOneWidget);
  });

  testWidgets('a refused command and no link are shown, not swallowed', (tester) async {
    final link = FakeLink();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: WifiSetupSheet(link: link))));
    link.line({'type': 'wifi_err', 'cmd': 'wifi_join', 'reason': 'needs a bonded BLE link'});
    await tester.pump();
    expect(find.text('wifi_join: needs a bonded BLE link'), findsOneWidget);

    final gone = FakeLink()..ready = false;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: WifiSetupSheet(key: UniqueKey(), link: gone))));
    await tester.pump();
    expect(find.textContaining('Could not send to the detector'), findsOneWidget);
  });

  testWidgets('no answer to a scan times out into a visible failure', (tester) async {
    final link = FakeLink();
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: WifiSetupSheet(link: link, scanTimeout: const Duration(seconds: 3)))));
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('Scan failed: The detector did not answer the scan'), findsOneWidget);
  });

  testWidgets('a short sheet (a phone on its side, 2x text) scrolls as one, no overflow', (tester) async {
    tester.view.physicalSize = const Size(874 * 3, 402 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final link = FakeLink();
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(size: Size(874, 402), textScaler: TextScaler.linear(2)),
        child: Scaffold(body: SizedBox(height: 340, child: WifiSetupSheet(link: link))),
      ),
    ));
    for (var i = 0; i < 6; i++) {
      link.line({'type': 'wifi_net', 'ssid': 'Net $i', 'rssi': -60, 'secure': i.isEven, 'saved': false});
    }
    link.line({'type': 'wifi_scan_done', 'n': 6});
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text('Net 5'), 120);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduce motion: the sheet settles (its status light is still)', (tester) async {
    final link = FakeLink();
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Scaffold(body: WifiSetupSheet(link: link)),
      ),
    ));
    link.line({'type': 'wifi_status', 'state': 'connected', 'mode': 'sync', 'ssid': 'Home', 'saved': <String>[]});
    link.line({'type': 'wifi_scan_done', 'n': 0});
    await tester.pumpAndSettle();
    expect(find.text('Connected to Home'), findsOneWidget);
  });
}
