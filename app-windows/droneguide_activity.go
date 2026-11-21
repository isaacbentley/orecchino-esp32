// SPDX-License-Identifier: GPL-3.0-or-later
package main

import (
	"strings"
	"time"
)

type droneguideActivity uint8

const (
	droneguideActivityUnknown droneguideActivity = iota
	droneguideActivityInactive
	droneguideActivityActive
)

func (state droneguideActivity) label() string {
	switch state {
	case droneguideActivityActive:
		return "active"
	case droneguideActivityInactive:
		return "inactive"
	default:
		return "unknown"
	}
}

func droneguideZoneActivity(zone droneguideZone, view droneguideView, now time.Time) droneguideActivity {
	if view.SnapshotAt != nil {
		if view.Stale || zone.ActiveAtSnapshot == nil {
			return droneguideActivityUnknown
		}
		if *zone.ActiveAtSnapshot {
			return droneguideActivityActive
		}
		return droneguideActivityInactive
	}

	if len(zone.Applicability) == 0 {
		dates := droneguideDateActivity(zone.ValidFrom, zone.ValidUntil, false, now)
		if dates == droneguideActivityActive && strings.TrimSpace(zone.Schedule) != "" {
			// The standalone GeoJSON schedule is display text, not a defined
			// recurrence, so it cannot establish activity.
			return droneguideActivityUnknown
		}
		return dates
	}

	activity := droneguideActivityInactive
	for _, period := range zone.Applicability {
		switch droneguidePeriodActivity(period, now) {
		case droneguideActivityActive:
			return droneguideActivityActive
		case droneguideActivityUnknown:
			activity = droneguideActivityUnknown
		}
	}
	return activity
}

func droneguideDateActivity(from, until string, permanent bool, now time.Time) droneguideActivity {
	var start, end time.Time
	var err error
	if from != "" {
		start, err = time.Parse(time.RFC3339Nano, from)
		if err != nil {
			return droneguideActivityUnknown
		}
	}
	if until != "" {
		end, err = time.Parse(time.RFC3339Nano, until)
		if err != nil {
			return droneguideActivityUnknown
		}
	}
	if !start.IsZero() && !end.IsZero() && !end.After(start) {
		return droneguideActivityUnknown
	}
	if !start.IsZero() && now.Before(start) || !end.IsZero() && !now.Before(end) {
		return droneguideActivityInactive
	}
	if permanent || !start.IsZero() && !end.IsZero() {
		return droneguideActivityActive
	}
	return droneguideActivityUnknown
}

func droneguidePeriodActivity(period droneguidePeriod, now time.Time) droneguideActivity {
	dates := droneguideDateActivity(period.StartDateTime, period.EndDateTime,
		strings.EqualFold(strings.TrimSpace(period.Permanent), "YES"), now)
	if dates == droneguideActivityInactive || len(period.Schedule) == 0 {
		return dates
	}
	activity := droneguideActivityInactive
	for _, schedule := range period.Schedule {
		switch droneguideDailyActivity(schedule, now) {
		case droneguideActivityActive:
			return dates
		case droneguideActivityUnknown:
			activity = droneguideActivityUnknown
		}
	}
	return activity
}

func droneguideDailyActivity(period droneguideDailyPeriod, now time.Time) droneguideActivity {
	const clockLayout = "15:04:05Z07:00"
	start, startErr := time.Parse(clockLayout, period.StartTime)
	end, endErr := time.Parse(clockLayout, period.EndTime)
	if startErr != nil || endErr != nil || len(period.Day) == 0 {
		return droneguideActivityUnknown
	}
	_, offset := start.Zone()
	_, endOffset := end.Zone()
	if offset != endOffset || start.Equal(end) {
		return droneguideActivityUnknown
	}
	days := [...]string{"SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"}
	var selected [7]bool
	for _, day := range period.Day {
		code := strings.ToUpper(strings.TrimSpace(day))
		if code == "ANY" {
			selected = [7]bool{true, true, true, true, true, true, true}
			continue
		}
		found := false
		for weekday, label := range days {
			if code == label {
				selected[weekday] = true
				found = true
				break
			}
		}
		if !found {
			return droneguideActivityUnknown
		}
	}

	wallTime := func(t time.Time) time.Duration {
		return time.Duration(t.Hour())*time.Hour + time.Duration(t.Minute())*time.Minute +
			time.Duration(t.Second())*time.Second + time.Duration(t.Nanosecond())
	}
	wallNow := now.UTC().Add(time.Duration(offset) * time.Second)
	today := wallNow.Weekday()
	startAt, endAt, current := wallTime(start), wallTime(end), wallTime(wallNow)
	active := false
	if startAt < endAt {
		active = selected[today] && current >= startAt && current < endAt
	} else {
		yesterday := (today + 6) % 7
		active = selected[today] && current >= startAt || selected[yesterday] && current < endAt
	}
	if active {
		return droneguideActivityActive
	}
	return droneguideActivityInactive
}
