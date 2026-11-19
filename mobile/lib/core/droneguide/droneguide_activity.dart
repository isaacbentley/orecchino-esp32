// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
part of 'droneguide.dart';

class DroneguidePeriod {
  final DateTime? start;
  final DateTime? end;
  final bool permanent;
  final List<DroneguideDailyPeriod> schedule;

  const DroneguidePeriod({
    this.start,
    this.end,
    this.permanent = false,
    this.schedule = const [],
  });
}

class DroneguideDailyPeriod {
  final List<String> days;
  final String startTime;
  final String endTime;

  const DroneguideDailyPeriod(this.days, this.startTime, this.endTime);
}

List<DroneguidePeriod> _periods(Object? raw) => List.unmodifiable([
      for (final period in _array(raw ?? const <Object?>[]).map(_object))
        DroneguidePeriod(
          start: _validTime(_string(period['startDateTime'])),
          end: _validTime(_string(period['endDateTime'])),
          permanent: _string(period['permanent']).toUpperCase() == 'YES',
          schedule: List.unmodifiable([
            for (final daily
                in _array(period['schedule'] ?? const <Object?>[]).map(_object))
              DroneguideDailyPeriod(
                List.unmodifiable(_strings(daily['day'])),
                _string(daily['startTime']),
                _string(daily['endTime']),
              ),
          ]),
        ),
    ]);

bool? _dates(DateTime? start, DateTime? end, bool permanent, DateTime now) {
  if (start != null && end != null && !start.isBefore(end)) return null;
  if ((start != null && now.isBefore(start)) ||
      (end != null && !now.isBefore(end))) {
    return false;
  }
  return permanent || (start != null && end != null) ? true : null;
}

bool? _importActivity(DroneguideZone zone, DateTime now) {
  if (zone.applicability.isEmpty) {
    final dates = _dates(
      _validTime(zone.validFrom),
      _validTime(zone.validUntil),
      false,
      now,
    );
    if (dates == true && zone.schedule.isNotEmpty) return null;
    return dates;
  }
  var unknown = false;
  for (final period in zone.applicability) {
    final dates = _dates(period.start, period.end, period.permanent, now);
    if (dates == false) continue;
    final active = _scheduleActivity(period.schedule, now);
    if (active == true && dates == true) return true;
    if (active == null || (active == true && dates == null)) unknown = true;
  }
  return unknown ? null : false;
}

bool? _scheduleActivity(List<DroneguideDailyPeriod> periods, DateTime now) {
  if (periods.isEmpty) return true;
  var unknown = false;
  for (final period in periods) {
    final active = _dailyActivity(period, now);
    if (active == true) return true;
    if (active == null) unknown = true;
  }
  return unknown ? null : false;
}

final _explicitClock = RegExp(
  r'^(\d{2}):(\d{2}):(\d{2})(?:[.,](\d+))?(Z|[+-]\d{2}:\d{2})$',
);

({Duration clock, Duration offset})? _dailyTime(String field) {
  final match = _explicitClock.firstMatch(field);
  if (match == null) return null;
  final hour = int.parse(match[1]!);
  final minute = int.parse(match[2]!);
  final second = int.parse(match[3]!);
  if (hour > 23 || minute > 59 || second > 59) return null;
  final fraction = (match[4] ?? '').padRight(6, '0').substring(0, 6);
  final zone = match[5]!;
  var offset = Duration.zero;
  if (zone != 'Z') {
    final zoneHour = int.parse(zone.substring(1, 3));
    final zoneMinute = int.parse(zone.substring(4, 6));
    if (zoneHour > 23 || zoneMinute > 59) return null;
    offset = Duration(hours: zoneHour, minutes: zoneMinute) *
        (zone.startsWith('-') ? -1 : 1);
  }
  return (
    clock: Duration(
      hours: hour,
      minutes: minute,
      seconds: second,
      microseconds: int.parse(fraction),
    ),
    offset: offset,
  );
}

bool? _dailyActivity(DroneguideDailyPeriod period, DateTime now) {
  final start = _dailyTime(period.startTime);
  final end = _dailyTime(period.endTime);
  if (start == null ||
      end == null ||
      start.offset != end.offset ||
      start.clock == end.clock ||
      period.days.isEmpty) {
    return null;
  }
  const weekdays = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
  final days = period.days.map((day) => day.toUpperCase()).toSet();
  if (days.any((day) => day != 'ANY' && !weekdays.contains(day))) return null;

  final local = now.toUtc().add(start.offset);
  final at = Duration(
    hours: local.hour,
    minutes: local.minute,
    seconds: local.second,
    milliseconds: local.millisecond,
    microseconds: local.microsecond,
  );
  final today = local.weekday - 1;
  final anyDay = days.contains('ANY');
  final todayAllowed = anyDay || days.contains(weekdays[today]);

  if (start.clock < end.clock) {
    return todayAllowed && at >= start.clock && at < end.clock;
  }
  final previousDayAllowed = anyDay || days.contains(weekdays[(today + 6) % 7]);
  return (todayAllowed && at >= start.clock) ||
      (previousDayAllowed && at < end.clock);
}
