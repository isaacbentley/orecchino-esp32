// history_timeline.dart — the History screen's pure logic: records binned
// across a time window for the activity ribbon, the record under the scrub
// cursor, and records grouped by local day.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

/// A record's time span (UTC seconds; 0 when the detector had no clock).
typedef TimeSpan = ({int first, int last, bool alert});

class TimelineBin {
  final int startUtc;
  final int endUtc;
  final int count;
  final bool alert;

  const TimelineBin(this.startUtc, this.endUtc, this.count, this.alert);
}

abstract final class HistoryTimeline {
  /// [n] equal bins from [startUtc] to [endUtc], each counting the records
  /// whose span overlaps it (a record lasting an hour lights every bin it
  /// covers) and whether any of them carried an alert.
  static List<TimelineBin> bins(List<TimeSpan> spans, int startUtc, int endUtc, int n) {
    final w = (endUtc - startUtc) / n;
    final counts = List<int>.filled(n, 0);
    final alerts = List<bool>.filled(n, false);
    for (final s in spans) {
      if (s.last <= 0 || s.last < startUtc || s.first > endUtc) continue;
      final first = math.max(s.first > 0 ? s.first : s.last, startUtc);
      final last = math.min(s.last, endUtc);
      final a = ((first - startUtc) / w).floor().clamp(0, n - 1);
      // End-exclusive: a record ending exactly on a bin edge stays out of the next bin.
      final b = math.max(a, (((last - startUtc) / w).ceil() - 1).clamp(0, n - 1));
      for (var i = a; i <= b; i++) {
        counts[i]++;
        if (s.alert) alerts[i] = true;
      }
    }
    return [
      for (var i = 0; i < n; i++)
        TimelineBin((startUtc + w * i).round(), (startUtc + w * (i + 1)).round(), counts[i], alerts[i]),
    ];
  }

  /// The index of the record at [utc]: one whose span contains it (the
  /// most recent if several), else the nearest within [snapS], else null.
  static int? recordAt(List<TimeSpan> spans, int utc, {int snapS = 1800}) {
    int? best;
    var bestD = snapS + 1;
    var bestLast = -1;
    for (var i = 0; i < spans.length; i++) {
      final s = spans[i];
      if (s.last <= 0) continue;
      final first = s.first > 0 ? s.first : s.last;
      final d = utc < first ? first - utc : (utc > s.last ? utc - s.last : 0);
      if (d < bestD || (d == bestD && s.last > bestLast)) {
        best = i;
        bestD = d;
        bestLast = s.last;
      }
    }
    return bestD <= snapS ? best : null;
  }

  /// 'Today', 'Yesterday', 'Mon 21 Sep', or 'No clock' for records the
  /// detector could not time.
  static String dayLabel(int utc, DateTime now) {
    if (utc <= 0) return 'No clock';
    final d = DateTime.fromMillisecondsSinceEpoch(utc * 1000).toLocal();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const mo = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${wd[d.weekday - 1]} ${d.day} ${mo[d.month - 1]}${d.year == now.year ? '' : ' ${d.year}'}';
  }

  /// Indexes of [lastUtcs] grouped by local day, newest day first, keeping
  /// the order within a day.
  static List<(String, List<int>)> groupByDay(List<int> lastUtcs, DateTime now) {
    final groups = <String, List<int>>{};
    final order = <String>[];
    final newest = <String, int>{};
    for (var i = 0; i < lastUtcs.length; i++) {
      final l = dayLabel(lastUtcs[i], now);
      if (!groups.containsKey(l)) order.add(l);
      groups.putIfAbsent(l, () => []).add(i);
      newest[l] = math.max(newest[l] ?? 0, lastUtcs[i]);
    }
    order.sort((a, b) => newest[b]!.compareTo(newest[a]!));
    return [for (final l in order) (l, groups[l]!)];
  }

  /// '14:05' local.
  static String clock(int utc) {
    if (utc <= 0) return 'no clock';
    final d = DateTime.fromMillisecondsSinceEpoch(utc * 1000).toLocal();
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  /// '10 min', '45 s', '1 h 5 min'.
  static String duration(int s) {
    if (s < 60) return '$s s';
    final m = (s / 60).round();
    if (m < 60) return '$m min';
    return '${m ~/ 60} h${m % 60 == 0 ? '' : ' ${m % 60} min'}';
  }
}
