// history_timeline_test.dart — the History ribbon's bins, the record under
// the scrub cursor, and records grouped by day.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:orecchino_mobile/features/history/history_timeline.dart';

void main() {
  test('bins count every record overlapping them, alerts marked', () {
    const spans = <TimeSpan>[
      (first: 1000, last: 1100, alert: false), // bin 0
      (first: 1150, last: 1450, alert: true), // bins 1..4
      (first: 0, last: 1950, alert: false), // no start time: counted at its end, bin 9
      (first: 0, last: 0, alert: true), // no clock: not on the ribbon
      (first: 5000, last: 6000, alert: false), // after the window
    ];
    final bins = HistoryTimeline.bins(spans, 1000, 2000, 10);
    expect(bins.length, 10);
    expect([for (final b in bins) b.count], [1, 1, 1, 1, 1, 0, 0, 0, 0, 1]);
    expect([for (final b in bins) b.alert], [false, true, true, true, true, false, false, false, false, false]);
    expect(bins.first.startUtc, 1000);
    expect(bins.last.endUtc, 2000);
  });

  test('the record at the cursor: containing it, else the nearest within the snap', () {
    const spans = <TimeSpan>[
      (first: 100, last: 200, alert: false),
      (first: 150, last: 400, alert: false),
      (first: 1000, last: 1100, alert: false),
    ];
    expect(HistoryTimeline.recordAt(spans, 180), 1); // both contain it: the one that ended last
    expect(HistoryTimeline.recordAt(spans, 300), 1);
    expect(HistoryTimeline.recordAt(spans, 900, snapS: 150), 2); // 100 s before record 2
    expect(HistoryTimeline.recordAt(spans, 700, snapS: 100), isNull); // too far from anything
  });

  test('days: Today, Yesterday, a date; records without a clock apart', () {
    final now = DateTime(2026, 9, 23, 15, 0);
    int utc(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;
    expect(HistoryTimeline.dayLabel(utc(DateTime(2026, 9, 23, 9)), now), 'Today');
    expect(HistoryTimeline.dayLabel(utc(DateTime(2026, 9, 22, 23)), now), 'Yesterday');
    expect(HistoryTimeline.dayLabel(utc(DateTime(2026, 9, 21, 12)), now), 'Mon 21 Sep');
    expect(HistoryTimeline.dayLabel(utc(DateTime(2025, 12, 31, 12)), now), 'Wed 31 Dec 2025');
    expect(HistoryTimeline.dayLabel(0, now), 'No clock');

    final groups = HistoryTimeline.groupByDay([
      utc(DateTime(2026, 9, 23, 14)),
      utc(DateTime(2026, 9, 22, 10)),
      utc(DateTime(2026, 9, 23, 8)),
      0,
    ], now);
    expect(groups.map((g) => g.$1).toList(), ['Today', 'Yesterday', 'No clock']);
    expect(groups.first.$2, [0, 2]);
  });

  test('durations', () {
    expect(HistoryTimeline.duration(45), '45 s');
    expect(HistoryTimeline.duration(600), '10 min');
    expect(HistoryTimeline.duration(3900), '1 h 5 min');
    expect(HistoryTimeline.duration(7200), '2 h');
  });
}
