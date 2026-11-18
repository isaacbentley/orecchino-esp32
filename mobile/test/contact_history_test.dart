// contact_history_test.dart — the cards' sparkline history: one sample a
// second at most, the last 60, and a contact that drops out briefly (a
// skipped ADS-B fetch) keeps its series; one gone a minute is forgotten.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:orecchino_mobile/features/live/live_items.dart';

LiveContactItem drone(String id, int rssi) =>
    LiveContactItem(id: id, label: id, isAircraft: false, ageSeconds: 0, rssi: rssi);

void main() {
  test('samples at most once a second, keeps the last 60', () {
    final h = ContactHistory();
    h.record([drone('a', -60)], 0);
    h.record([drone('a', -61)], 500); // too soon
    h.record([drone('a', -62)], 1000);
    expect(h.series('a'), [-60, -62]);
    for (var i = 2; i < 100; i++) {
      h.record([drone('a', -60 - i)], i * 1000);
    }
    expect(h.series('a').length, ContactHistory.capacity);
  });

  test('a brief absence keeps the series; a minute away forgets it', () {
    final h = ContactHistory();
    h.record([drone('a', -60), drone('b', -70)], 0);
    h.record([drone('a', -61)], 1000); // b missing for a moment
    h.record([drone('a', -62), drone('b', -71)], 2000);
    expect(h.series('b'), [-70, -71]);
    h.record([drone('a', -63)], 2000 + ContactHistory.keepMs + 1);
    expect(h.series('b'), isEmpty);
    expect(h.series('a'), isNotEmpty);
  });
}
