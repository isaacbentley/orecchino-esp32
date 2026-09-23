// traffic_widgets.dart — traffic alert banner, aircraft card, separation bridge.
// Fed by the pair rules in core/traffic/traffic_rules.dart; the banner adds
// the clock position from the phone (plan §8.4), and every widget reads the
// same words to a screen reader.
// Words: never "collision", "conflict", "safe", "clear" or "TCAS".
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import '../core/traffic/traffic_rules.dart';
import 'theme.dart';

Color trafficColor(TrafficLevel? level) {
  switch (level ?? TrafficLevel.none) {
    case TrafficLevel.warning:
      return OrecchinoTheme.danger;
    case TrafficLevel.caution:
      return OrecchinoTheme.amber;
    case TrafficLevel.advisory:
      return OrecchinoTheme.advisoryBlue;
    case TrafficLevel.none:
      return OrecchinoTheme.muted;
  }
}

/// '1.1 km'
String trafficKm(double? m) => m == null ? '--' : '${TrafficRules.kmText(m)} km';

/// '+90 m', or 'height unknown'
String trafficVert(double? m) {
  if (m == null) return 'height unknown';
  final v = (m + 0.5).floor();
  return v >= 0 ? '+$v m' : '$v m';
}

class TrafficAlertBanner extends StatelessWidget {
  final TrafficAlert alert;
  final VoidCallback? onTap;

  /// A third line, e.g. the clock position from the phone.
  final String? extra;

  const TrafficAlertBanner({super.key, required this.alert, this.onTap, this.extra});

  IconData get bannerIcon {
    switch (alert.level) {
      case TrafficLevel.warning:
        return Icons.warning_amber_rounded;
      case TrafficLevel.caution:
        return Icons.info_outline_rounded;
      case TrafficLevel.advisory:
      case TrafficLevel.none:
        return Icons.airplanemode_active;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = trafficColor(alert.level);
    final detail = alert.kind.isPair
        ? '${trafficKm(alert.horizM)} · ${trafficVert(alert.vertM)} · ${TrafficRules.ageWords(alert.ageS)}'
        : '${trafficKm(alert.horizM)} · ${TrafficRules.ageWords(alert.ageS)}';
    final text = [alert.text, detail, if (extra != null) extra!].join('\n');
    return Semantics(
      liveRegion: true,
      button: onTap != null,
      label: text.replaceAll('\n', ', '),
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.18),
            border: Border.all(color: color, width: 1.5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(bannerIcon, color: color, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 13, fontFamily: 'monospace'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Labels one drone-aircraft pair alert with that pair's own numbers.
class SeparationBridgeBadge extends StatelessWidget {
  final TrafficAlert alert;

  const SeparationBridgeBadge({super.key, required this.alert});

  @override
  Widget build(BuildContext context) {
    // Dark text on the solid level colour: >= 5.4:1 for every level.
    const style =
        TextStyle(color: OrecchinoTheme.ground, fontSize: 11, fontWeight: FontWeight.bold, fontFamily: 'monospace');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: trafficColor(alert.level),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.sync_alt, size: 11, color: OrecchinoTheme.ground),
          const SizedBox(width: 4),
          Text(trafficKm(alert.horizM), style: style),
          const SizedBox(width: 4),
          Text(alert.vertM == null ? '· height unknown' : '· Δ ${trafficVert(alert.vertM)}', style: style),
        ],
      ),
    );
  }
}

class TrafficDetailCard extends StatelessWidget {
  final TrafficAircraft aircraft;
  final TrafficAlert? alert;
  final int nowMs;
  final VoidCallback? onClose;

  const TrafficDetailCard({super.key, required this.aircraft, this.alert, required this.nowMs, this.onClose});

  @override
  Widget build(BuildContext context) {
    final al = alert;
    final levelColor = al == null ? OrecchinoTheme.muted : trafficColor(al.level);
    final ageS = aircraft.ageS(nowMs);
    final emergencySquawk = const [7500, 7600, 7700].contains(aircraft.squawk);
    final altFt = aircraft.altBaroM == null ? null : (aircraft.altBaroM! / TrafficRules.ftToM + 0.5).floor();
    final kt = aircraft.gsMps == null ? null : (aircraft.gsMps! / TrafficRules.ktToMps + 0.5).floor();

    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: OrecchinoTheme.surface,
        border: Border.all(color: levelColor, width: 1.5),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (al != null)
                      Text(al.text,
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.bold, color: levelColor, fontFamily: 'monospace')),
                    Text(aircraft.name,
                        style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'monospace',
                            color: OrecchinoTheme.text)),
                    Text([aircraft.type, aircraft.hex.toUpperCase()].where((s) => s.isNotEmpty).join(' · '),
                        style: const TextStyle(fontSize: 11, color: OrecchinoTheme.muted, fontFamily: 'monospace')),
                  ],
                ),
              ),
              IconButton(tooltip: 'Close', icon: const Icon(Icons.close, size: 20, color: OrecchinoTheme.muted), onPressed: onClose),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1, color: OrecchinoTheme.border),
          const SizedBox(height: 12),
          if (al != null)
            Row(
              children: [
                Expanded(
                  child: _metricTile(
                    al.kind.isPair ? 'FROM DRONE ${TrafficRules.droneLabel(al.droneId)}' : 'FROM HERE',
                    trafficKm(al.horizM),
                    al.cpaS == null ? '' : 'closest in ${(al.cpaS! + 0.5).floor()} s',
                  ),
                ),
                if (al.kind.isPair)
                  Expanded(
                    child: _metricTile('VERTICAL', trafficVert(al.vertM), '',
                        valueColor: al.vertM == null ? OrecchinoTheme.amber : null),
                  ),
              ],
            ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _metricTile('ALTITUDE', altFt == null ? '--' : '$altFt ft', '')),
              Expanded(child: _metricTile('SPEED', kt == null ? '--' : '$kt kt', '')),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 6,
            children: [
              if (aircraft.squawk > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: emergencySquawk ? OrecchinoTheme.danger.withValues(alpha: 0.2) : OrecchinoTheme.surfaceHigh,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: emergencySquawk ? OrecchinoTheme.danger : OrecchinoTheme.subtle),
                  ),
                  child: Text(
                    'SQUAWK ${aircraft.squawk.toString().padLeft(4, '0')}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: emergencySquawk ? OrecchinoTheme.danger : OrecchinoTheme.muted,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              Text(
                TrafficRules.ageWords(ageS),
                style: TextStyle(
                  fontSize: 11,
                  color: ageS > 15 ? OrecchinoTheme.amber : OrecchinoTheme.subtle,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text('Positions as reported, not a prediction. Not every aircraft broadcasts ADS-B.',
              style: TextStyle(fontSize: 11, color: OrecchinoTheme.muted)),
        ],
      ),
    );
  }

  Widget _metricTile(String label, String value, String subvalue, {Color? valueColor}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                fontSize: 11, fontWeight: FontWeight.w600, color: OrecchinoTheme.muted, fontFamily: 'monospace')),
        const SizedBox(height: 2),
        Text(value,
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: valueColor ?? OrecchinoTheme.text,
                fontFamily: 'monospace')),
        if (subvalue.isNotEmpty)
          Text(subvalue, style: const TextStyle(fontSize: 11, color: OrecchinoTheme.subtle, fontFamily: 'monospace')),
      ],
    );
  }
}
