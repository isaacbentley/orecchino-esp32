// sensor_chips.dart — the sensors that heard a drone, as small chips: this
// phone (a phone icon and its transport: "BLE4", "BLE5 LR", "NAN", "Wi-Fi
// (slow)") and each detector ("T5 · Wi-Fi"). A sensor not heard for 10 s
// is greyed with its age; after 60 s it is gone (sensors.dart). The chips
// are decoration for a screen reader: the card or row they sit on says
// "heard by this phone over Bluetooth 4 and by T5 over Wi-Fi".
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import '../core/live/sensors.dart';
import 'theme/theme.dart';

class SensorChips extends StatelessWidget {
  final List<SensorChip> chips;

  /// Also show each sensor's signal ("-68 dBm").
  final bool withRssi;

  const SensorChips(this.chips, {super.key, this.withRssi = false});

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Wrap(spacing: 6, runSpacing: 4, children: [for (final s in chips) _chip(s)]),
    );
  }

  Widget _chip(SensorChip s) {
    final color = s.fresh ? (s.phone ? OrecchinoColors.aqua : OrecchinoColors.ink) : OrecchinoColors.inkSubtle;
    final text = [
      s.phone ? s.transport : '${s.detector} · ${s.transport}',
      if (withRssi && s.rssi != null) '${s.rssi} dBm',
      if (!s.fresh) '${s.ageS.round()} s',
    ].join(' · ');
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 2, 8, 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: s.fresh ? 0.10 : 0.05),
        borderRadius: BorderRadius.circular(OrecchinoTheme.pill),
        border: Border.all(color: color.withValues(alpha: s.fresh ? 0.45 : 0.25)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(s.phone ? Icons.smartphone_rounded : Icons.sensors_rounded, size: 12, color: color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(text,
              style: OrecchinoType.eyebrow.copyWith(color: color, letterSpacing: 0.4, fontSize: 11)),
        ),
      ]),
    );
  }
}
