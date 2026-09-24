// alert_capsule.dart — the floating capsule at the top of the Live screen.
// Idle it is a small glass pill with the counts and the ADS-B data age; with
// a traffic alert it morphs (size, radius and colour wash on a spring) into
// a full-width card with the rule's words, and a tap opens the aircraft's
// card inside it. Alerts are words; the colour only repeats them.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import '../../core/traffic/traffic_rules.dart';
import '../../ui/glass.dart';
import '../../ui/theme/theme.dart';
import '../../ui/traffic_widgets.dart';
import 'live_items.dart';

class AlertCapsule extends StatefulWidget {
  final TrafficAlert? traffic;
  final TrafficAircraft? trafficAircraft;
  final String? trafficExtra; // the clock position from the phone
  final LiveContactItem? droneAlert;
  final String idleText; // '2 drones · 1 aircraft'
  final String? idleDetail; // 'ADS-B 3 s old'
  final int nowMs;
  final ValueChanged<String> onSelect;

  const AlertCapsule({
    super.key,
    this.traffic,
    this.trafficAircraft,
    this.trafficExtra,
    this.droneAlert,
    required this.idleText,
    this.idleDetail,
    required this.nowMs,
    required this.onSelect,
  });

  @override
  State<AlertCapsule> createState() => _AlertCapsuleState();
}

class _AlertCapsuleState extends State<AlertCapsule> {
  bool _open = false;

  @override
  void didUpdateWidget(AlertCapsule old) {
    super.didUpdateWidget(old);
    if (widget.traffic == null) _open = false;
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.traffic;
    final d = widget.droneAlert;
    final Color? wash;
    final Widget content;
    final Object key;
    final tColor = t == null ? null : OrecchinoColors.level(t.level, none: OrecchinoColors.advisory);
    final dColor = d == null
        ? null
        : (d.alertWords.contains('EMERGENCY REPORTED') ? OrecchinoColors.warning : OrecchinoColors.caution);
    if (t != null && d != null) {
      // Both: neither hides the other. The more severe leads and sets the
      // wash; a drone emergency is never pushed out by a traffic alert.
      final droneFirst = _rank(dColor!) >= _rank(tColor!);
      wash = droneFirst ? dColor : tColor;
      key = 'both:${t.id}:${d.id}:$droneFirst';
      final rule = Divider(height: 1, indent: 16, endIndent: 16, color: wash.withValues(alpha: 0.35));
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: droneFirst
            ? [_drone(d, dColor), rule, _traffic(t, tColor)]
            : [_traffic(t, tColor), rule, _drone(d, dColor)],
      );
    } else if (t != null) {
      wash = tColor;
      key = 'traffic:${t.level}:${t.id}';
      content = _traffic(t, tColor!);
    } else if (d != null) {
      wash = dColor;
      key = 'drone:${d.id}';
      content = _drone(d, dColor!);
    } else {
      wash = null;
      key = 'idle';
      content = _idle();
    }
    final alerting = wash != null;
    final dur = Motion.of(context, Motion.morph);
    return AnimatedSize(
      duration: dur,
      curve: Motion.springy,
      alignment: Alignment.topCenter,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: alerting ? 1.0 : 0.0),
        duration: dur,
        curve: Motion.emphasized,
        builder: (context, k, child) => Glass(
          borderRadius: BorderRadius.circular(999 - (999 - OrecchinoTheme.radius) * k.clamp(0.0, 1.0)),
          wash: wash == null ? null : Color.lerp(OrecchinoColors.night, wash, k),
          edge: wash?.withValues(alpha: 0.6 * k),
          shadows: wash != null ? [BoxShadow(color: wash.withValues(alpha: 0.25 * k), blurRadius: 30)] : null,
          child: child!,
        ),
        child: AnimatedSwitcher(
          duration: Motion.of(context, Motion.base),
          switchInCurve: Motion.emphasized,
          switchOutCurve: Motion.exit,
          layoutBuilder: (current, previous) =>
              Stack(alignment: Alignment.topCenter, children: [...previous, if (current != null) current]),
          child: KeyedSubtree(key: ValueKey(key), child: content),
        ),
      ),
    );
  }

  Widget _idle() {
    final detail = widget.idleDetail;
    return Semantics(
      label: [widget.idleText, if (detail != null) detail].join(', '),
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: OrecchinoTheme.minTarget),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 4, 16, 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const BreathingDot(color: OrecchinoColors.aqua, size: 7),
              const SizedBox(width: 2),
              Flexible(
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: widget.idleText, style: OrecchinoType.bodyStrong.copyWith(fontSize: 14)),
                    if (detail != null) TextSpan(text: '  ·  $detail', style: OrecchinoType.label),
                  ]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _traffic(TrafficAlert t, Color color) {
    final lines = [t.text, trafficDetail(t), if (widget.trafficExtra != null) widget.trafficExtra!];
    final ac = widget.trafficAircraft;
    return SizedBox(
      width: double.infinity,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            liveRegion: true,
            button: true,
            expanded: _open,
            label: lines.join(', '),
            excludeSemantics: true,
            child: InkWell(
              borderRadius: BorderRadius.circular(OrecchinoTheme.radius),
              onTap: () {
                setState(() => _open = !_open);
                widget.onSelect('ac:${t.hex}');
              },
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Icon(
                        t.level == TrafficLevel.warning ? Icons.warning_rounded : Icons.flight_rounded,
                        color: color,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(t.text, style: OrecchinoType.alert.copyWith(color: color, fontSize: 15)),
                          const SizedBox(height: 3),
                          // A non-breaking hyphen on screen only, so "ADS-B" never splits.
                          Text(trafficDetail(t).replaceAll('ADS-B', 'ADS\u2011B'),
                              style: OrecchinoType.label.copyWith(color: OrecchinoColors.ink)),
                          if (widget.trafficExtra != null) Text(widget.trafficExtra!, style: OrecchinoType.caption),
                        ],
                      ),
                    ),
                    AnimatedRotation(
                      turns: _open ? 0.5 : 0,
                      duration: Motion.of(context, Motion.base),
                      curve: Motion.standard,
                      child: const Icon(Icons.expand_more_rounded, color: OrecchinoColors.inkMuted),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_open && ac != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: TrafficDetailCard(
                aircraft: ac,
                alert: t,
                nowMs: widget.nowMs,
                onClose: () => setState(() => _open = false),
              ),
            ),
        ],
      ),
    );
  }

  static int _rank(Color c) => c == OrecchinoColors.warning ? 3 : (c == OrecchinoColors.caution ? 2 : 1);

  Widget _drone(LiveContactItem d, Color color) {
    return SizedBox(
      width: double.infinity,
      child: Semantics(
        liveRegion: true,
        button: true,
        label: '${d.alertWords.join(', ')}, drone ${d.label}, ${d.rangeText}',
        excludeSemantics: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(OrecchinoTheme.radius),
          onTap: () => widget.onSelect(d.id),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(children: [
              Icon(Icons.warning_rounded, color: color, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(d.alertWords.join(' · '), style: OrecchinoType.alert.copyWith(color: color, fontSize: 15)),
                    const SizedBox(height: 3),
                    Text('${d.label} · ${d.rangeText}',
                        style: OrecchinoType.label.copyWith(color: OrecchinoColors.ink)),
                  ],
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
