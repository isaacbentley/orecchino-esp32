// traffic_widgets.dart — the words every traffic surface shares (the action
// first, then the geometry behind it), the separation bridge's numbers and
// the aircraft card. Fed by the rules in core/traffic/traffic_rules.dart;
// every widget reads the same words to a screen reader. Aircraft appear
// only while an alert names them (a drone pair, or low traffic).
// Words: never "collision", "safe", "clear" (but the rules' "KEEP CLEAR
// OF"), "conflict resolved" or "TCAS".
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import '../core/traffic/traffic_rules.dart';
import '../core/traffic/traffic_words.dart';
import 'glass.dart';
import 'theme/theme.dart';

export '../core/traffic/traffic_words.dart';

Color trafficColor(TrafficLevel? level) => OrecchinoColors.level(level);

/// '1.1 km'
String trafficKm(double? m) => m == null ? '--' : '${TrafficRules.kmText(m)} km';

/// '+90 m', or 'height unknown'
String trafficVert(double? m) {
  if (m == null) return 'height unknown';
  final v = (m + 0.5).floor();
  return v >= 0 ? '+$v m' : '$v m';
}

/// Low traffic (an aircraft in UAS airspace), not a drone pair.
bool trafficIsLow(TrafficAlert a) => !a.kind.isPair;

/// '240 m above ground', 'height unknown' (low traffic: the height is above
/// the ground, not relative to a drone).
String trafficAgl(double? m) => m == null ? 'height unknown' : '${trafficAglM(m)} m above ground';

/// The detail line under a traffic alert: '0.4 km · +85 m · ADS-B 3 s old'
/// (low traffic: '2.4 km · 240 m above ground · ADS-B 3 s old').
String trafficDetail(TrafficAlert a) =>
    '${trafficKm(a.horizM)} · ${trafficIsLow(a) ? trafficAgl(a.vertM) : trafficVert(a.vertM)} · '
    '${TrafficRules.ageWords(a.ageS)}';

/// Floats on a separation bridge: that pair's own numbers.
class SeparationBridgeBadge extends StatelessWidget {
  final TrafficAlert alert;

  const SeparationBridgeBadge({super.key, required this.alert});

  // Dark text on the solid level colour: >= 8:1 for every level.
  static final TextStyle _style =
      OrecchinoType.label.copyWith(color: OrecchinoColors.void0, fontWeight: FontWeight.w700, fontSize: 12);

  static String _vertText(TrafficAlert a) => a.vertM == null
      ? 'height unknown'
      : (trafficIsLow(a) ? '${trafficAglM(a.vertM!)} m AGL' : 'Δ ${trafficVert(a.vertM)}');

  /// The badge's size at [scaler], so the sky can keep its labels clear.
  static Size measure(TrafficAlert alert, TextScaler scaler) {
    double w = 9 * 2 + 13, h = 0;
    for (final s in [trafficKm(alert.horizM), _vertText(alert)]) {
      final tp =
          TextPainter(text: TextSpan(text: s, style: _style), textDirection: TextDirection.ltr, textScaler: scaler)
            ..layout();
      w += tp.width;
      h = h > tp.height ? h : tp.height;
      tp.dispose();
    }
    return Size(w, h + 8);
  }

  @override
  Widget build(BuildContext context) {
    final color = OrecchinoColors.level(alert.level, none: OrecchinoColors.caution);
    final style = _style;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
        boxShadow: Look.flat ? null : [BoxShadow(color: color.withValues(alpha: 0.45), blurRadius: 14)],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(trafficKm(alert.horizM), style: style),
          Container(
            width: 1,
            height: 12,
            margin: const EdgeInsets.symmetric(horizontal: 6),
            color: OrecchinoColors.void0.withValues(alpha: 0.4),
          ),
          Text(_vertText(alert), style: style),
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
    final levelColor = al == null ? OrecchinoColors.aircraft : trafficColor(al.level);
    final ageS = aircraft.ageS(nowMs);
    final emergencySquawk = const [7500, 7600, 7700].contains(aircraft.squawk);
    final altFt = aircraft.altBaroM == null ? null : (aircraft.altBaroM! / TrafficRules.ftToM + 0.5).floor();
    final kt = aircraft.gsMps == null ? null : (aircraft.gsMps! / TrafficRules.ktToMps + 0.5).floor();

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 8, 16),
      decoration: BoxDecoration(
        color: OrecchinoColors.raised.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(OrecchinoTheme.radius),
        border: Border.all(color: levelColor.withValues(alpha: 0.7), width: 1.2),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (al != null) ...[
                      Text(trafficAction(al), style: OrecchinoType.alert.copyWith(color: levelColor)),
                      if (trafficGeometry(al).isNotEmpty)
                        Text(trafficGeometry(al), style: OrecchinoType.label.copyWith(color: OrecchinoColors.ink)),
                      const SizedBox(height: 2),
                      Text(al.text, style: OrecchinoType.caption),
                      const SizedBox(height: 8),
                    ],
                    Text(aircraft.name, style: OrecchinoType.title.copyWith(fontSize: 26)),
                    const SizedBox(height: 2),
                    Text(
                      [aircraft.type, aircraft.hex.toUpperCase()].where((s) => s.isNotEmpty).join(' · '),
                      style: OrecchinoType.id.copyWith(color: OrecchinoColors.inkMuted),
                    ),
                  ],
                ),
              ),
              if (onClose != null)
                IconButton(tooltip: 'Close', icon: const Icon(Icons.close_rounded, size: 22), onPressed: onClose),
            ],
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: MetricGrid(
              children: [
                if (al != null)
                  _Metric(
                    al.droneId.isNotEmpty ? 'FROM DRONE ${TrafficRules.droneLabel(al.droneId)}' : 'FROM YOU',
                    trafficKm(al.horizM),
                    al.cpaS == null ? null : 'closest in ${(al.cpaS! + 0.5).floor()} s',
                  ),
                if (al != null)
                  _Metric(
                      trafficIsLow(al) ? 'ABOVE GROUND' : 'VERTICAL',
                      trafficIsLow(al)
                          ? (al.vertM == null ? 'unknown' : '${trafficAglM(al.vertM!)} m')
                          : trafficVert(al.vertM),
                      null,
                      valueColor: al.vertM == null ? OrecchinoColors.caution : null),
                _Metric('ALTITUDE', altFt == null ? '--' : '$altFt ft', null),
                _Metric('SPEED', kt == null ? '--' : '$kt kt', null),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (aircraft.squawk > 0)
                Tag('SQUAWK ${aircraft.squawk.toString().padLeft(4, '0')}',
                    color: emergencySquawk ? OrecchinoColors.warning : OrecchinoColors.inkMuted),
              Tag(TrafficRules.ageWords(ageS), color: ageS > 15 ? OrecchinoColors.caution : OrecchinoColors.inkMuted),
            ],
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Text('Positions as reported, not a prediction. Not every aircraft broadcasts ADS-B.',
                style: OrecchinoType.caption),
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  final String? sub;
  final Color? valueColor;

  const _Metric(this.label, this.value, this.sub, {this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(OrecchinoTheme.radiusSmall),
        border: Border.all(color: OrecchinoColors.line),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: OrecchinoType.eyebrow),
          const SizedBox(height: 4),
          Text(value, style: OrecchinoType.metric.copyWith(color: valueColor)),
          if (sub != null) Text(sub!, style: OrecchinoType.caption),
        ],
      ),
    );
  }
}
