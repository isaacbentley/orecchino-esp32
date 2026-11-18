// sensors.dart — which sensors heard a drone, as chips and words: this
// phone's own receiver ("📱 BLE4", "📱 BLE5 LR", "📱 NAN", "📱 Wi-Fi
// (slow)") and each detector with its transport ("T5 · Wi-Fi", "T5 · BLE
// LR", "T-Embed · NAN"). A sensor heard in the last 10 s is fresh; up to
// 60 s it stays, greyed, with its age; after that it is dropped. The words
// for a screen reader: "heard by this phone over Bluetooth 4 and by T5 over
// Wi-Fi".
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'contact_tracker.dart';

class SensorChip {
  static const freshS = 10.0, keepS = 60.0;

  final String key;
  final bool phone;
  final String? detector; // its short name ("T5"); null for the phone
  final String transport; // 'BLE4', 'BLE5 LR', 'Wi-Fi', 'NAN', 'Wi-Fi (slow)'
  final String transportWords; // 'Bluetooth 4', 'Wi-Fi beacons (slow)'
  final double ageS;
  final int? rssi;

  const SensorChip({
    required this.key,
    required this.phone,
    required this.detector,
    required this.transport,
    required this.transportWords,
    required this.ageS,
    this.rssi,
  });

  bool get fresh => ageS <= freshS;

  /// The chip's text: '📱 BLE4', 'T5 · Wi-Fi' (and ' · 25 s' when not fresh).
  String get label => '${phone ? '📱 ' : '$detector · '}$transport${fresh ? '' : ' · ${ageS.round()} s'}';

  /// Compact, for the sky: '📱BLE4', 'T5 Wi-Fi'.
  String get compact => phone ? '📱$transport' : '$detector $transport';

  /// 'this phone over Bluetooth 4', 'T5 over Wi-Fi'.
  String get words => '${phone ? 'this phone' : detector} over $transportWords';
}

/// A detector's short name for chips: its board ("T5", "T-Embed",
/// "SenseCAP", "Demo" for the simulated one), else its paired name.
String detectorShortName(String? name, String? board) {
  final b = (board ?? '').toLowerCase();
  if (b.contains('t5')) return 'T5';
  if (b.contains('embed')) return 'T-Embed';
  if (b.contains('sensecap') || b.contains('t1000')) return 'SenseCAP';
  if (b == 'simulated') return 'Demo';
  final n = (name ?? '').trim();
  return n.isEmpty ? 'Detector' : n;
}

(String, String) _transport(String src, String? phy) => switch (src) {
      'phone-ble4' => ('BLE4', 'Bluetooth 4'),
      'phone-ble5' => ('BLE5', 'Bluetooth 5'),
      'phone-coded' => ('BLE5 LR', 'Bluetooth 5 long range'),
      'phone-nan' => ('NAN', 'Wi-Fi NAN'),
      'phone-beacon' => ('Wi-Fi (slow)', 'Wi-Fi beacons (slow)'),
      'ble' => phy == 'coded' ? ('BLE LR', 'Bluetooth long range') : ('BLE', 'Bluetooth'),
      'wifi' => ('Wi-Fi', 'Wi-Fi'),
      'nan' => ('NAN', 'Wi-Fi NAN'),
      _ => (src.toUpperCase(), src),
    };

/// The sensors that heard [c] in the last minute: the phone's first, then
/// the detectors, each by name; freshest first within each.
List<SensorChip> sensorChips(Contact c, int nowMs) {
  final out = <SensorChip>[];
  for (final h in c.heardBy.values) {
    final age = (nowMs - h.lastMs).clamp(0, 1 << 40) / 1000.0;
    if (age > SensorChip.keepS) continue;
    final (t, w) = _transport(h.src, h.phy);
    out.add(SensorChip(
      key: h.key,
      phone: h.isPhone,
      detector: h.detector,
      transport: t,
      transportWords: w,
      ageS: age,
      rssi: h.rssi,
    ));
  }
  // Heard in the same millisecond: the one heard last first (the map keeps
  // the order each sensor was first heard in, not the last).
  final order = Map<SensorChip, int>.identity();
  for (var i = 0; i < out.length; i++) {
    order[out[i]] = i;
  }
  out.sort((a, b) {
    if (a.phone != b.phone) return a.phone ? -1 : 1;
    final d = (a.detector ?? '').compareTo(b.detector ?? '');
    if (d != 0) return d;
    final age = a.ageS.compareTo(b.ageS);
    return age != 0 ? age : order[b]!.compareTo(order[a]!);
  });
  return out;
}

/// 'heard by this phone over Bluetooth 4 and Bluetooth 5 and by T5 over
/// Wi-Fi' (null when nobody heard it in the last minute).
String? sensorWords(List<SensorChip> chips) {
  if (chips.isEmpty) return null;
  final groups = <String, List<String>>{};
  for (final s in chips) {
    groups.putIfAbsent(s.phone ? 'this phone' : s.detector!, () => []).add(s.transportWords);
  }
  final parts = [for (final e in groups.entries) '${e.key} over ${e.value.join(' and ')}'];
  return 'heard by ${parts.join(' and by ')}';
}
