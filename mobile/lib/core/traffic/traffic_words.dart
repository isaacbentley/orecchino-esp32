// traffic_words.dart — the order every traffic surface uses: the alert's
// action first ("GIVE WAY: DESCEND AND LAND D9A11"), then the geometry that
// justifies it (the rest of the rules' resolution), then the rule's words.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'traffic_rules.dart';

/// What to do: 'GIVE WAY: DESCEND AND LAND D9A03', 'BE READY TO LAND
/// DRONES'. Every surface leads with it.
String trafficAction(TrafficAlert a) => a.action.isNotEmpty ? a.action : a.text;

/// Low traffic's height above the ground in whole metres, never below 0
/// (ADS-B and the terrain model can put an aircraft on the ground a little
/// under it; the rules then say "near ground level").
int trafficAglM(double m) {
  final v = (m + 0.5).floor();
  return v < 0 ? 0 : v;
}

/// Why: the resolution after its action, 'AIRCRAFT 90 M ABOVE, 800 M NE,
/// CLOSEST IN 24 S' ('' when the rules gave none).
String trafficGeometry(TrafficAlert a) {
  final lead = '${a.action}; ';
  if (a.action.isNotEmpty && a.resolution.startsWith(lead)) return a.resolution.substring(lead.length);
  return a.resolution == a.action ? '' : a.resolution;
}
