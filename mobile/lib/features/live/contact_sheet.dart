// contact_sheet.dart — the Live screen's glass sheet, drones only (Remote ID
// first). Peeking, it shows the drone count, the nearest drone and the
// conflict-watch status chip; pulled up, the selected contact's card and a
// card per drone (source badges, its alert's action first, height, age, and
// a sparkline of its signal). Aircraft never get a row or a count: they are
// on the sky, and in the capsule, only while an alert names them. Each card
// reads the same words as its mark on the sky.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import '../../core/geo.dart';
import '../../core/traffic/traffic_rules.dart';
import '../../ui/contact_glyph.dart';
import '../../ui/glass.dart';
import '../../ui/measure_height.dart';
import '../../ui/sensor_chips.dart';
import '../../ui/sparkline.dart';
import '../../ui/theme/theme.dart';
import '../../ui/traffic_widgets.dart';
import 'live_items.dart';

Color contactColor(LiveContactItem c) {
  if (c.alertWords.contains('EMERGENCY REPORTED')) {
    return OrecchinoColors.warning;
  }
  final base = OrecchinoColors.level(
    c.alertLevel,
    none: c.isAircraft ? OrecchinoColors.aircraft : OrecchinoColors.aqua,
  );
  return base;
}

String _plural(int n, String one, String many) => '$n ${n == 1 ? one : many}';

/// '2 drones' (aircraft are never counted).
String contactCounts(List<LiveContactItem> items) =>
    _plural(items.where((c) => c.isDrone).length, 'drone', 'drones');

/// The conflict-watch status as a chip: on (aqua), stale (caution) or off.
class ConflictWatchChip extends StatelessWidget {
  final String summary; // TrafficRules.summary, or why the watch is off

  const ConflictWatchChip({super.key, required this.summary});

  @override
  Widget build(BuildContext context) {
    final on = summary.startsWith('conflict watch on');
    final stale = summary.startsWith('TRAFFIC DATA STALE');
    final color = on ? OrecchinoColors.aqua : (stale ? OrecchinoColors.caution : OrecchinoColors.inkMuted);
    return Semantics(
      label: summary,
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 5, 12, 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(OrecchinoTheme.pill),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(on ? Icons.shield_outlined : Icons.shield_moon_outlined, size: 14, color: color),
          const SizedBox(width: 6),
          Flexible(
            child:
                Text(summary, style: OrecchinoType.caption.copyWith(color: stale ? color : OrecchinoColors.inkMuted)),
          ),
        ]),
      ),
    );
  }
}

class ContactSheet extends StatelessWidget {
  final ScrollController scrollController;
  final List<LiveContactItem> contacts;
  final double? headingDeg;
  final String? selectedId;
  final ValueChanged<String> onSelect;
  final VoidCallback onToggle;
  final Widget? detail;
  final String emptyText;

  /// The conflict-watch status (TrafficRules.summary), shown as a chip.
  final String? conflictWatch;
  final ContactHistory history;
  final double bottomInset;

  /// A long press on a card opens the drone's full details.
  final ValueChanged<String>? onDetails;

  /// The peek part's height (handle, counts, nearest, traffic line), so the
  /// sheet can rest showing exactly that.
  final ValueChanged<double>? onPeekHeight;

  /// A side panel (landscape, tablets) rather than a bottom sheet: no drag
  /// handle, rounded all round, and [header] (the view controls) on top.
  final bool panel;
  final Widget? header;

  const ContactSheet({
    super.key,
    required this.scrollController,
    required this.contacts,
    required this.headingDeg,
    required this.selectedId,
    required this.onSelect,
    required this.onToggle,
    required this.detail,
    required this.emptyText,
    required this.conflictWatch,
    required this.history,
    required this.bottomInset,
    this.onPeekHeight,
    this.panel = false,
    this.header,
    this.onDetails,
  });

  @override
  Widget build(BuildContext context) {
    // Drones only, in a stable order (as first heard): cards never jump
    // under a finger when an alert starts or stops. The capsule leads with
    // the alert, and each card carries its own alert's action.
    final sorted = [
      for (final c in contacts)
        if (c.isDrone) c
    ];
    return Glass(
      borderRadius: panel ? BorderRadius.circular(26) : const BorderRadius.vertical(top: Radius.circular(30)),
      blur: 30,
      // The list ends above the tab bar: nothing scrolls beneath it.
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: CustomScrollView(
          controller: scrollController,
          slivers: [
            SliverToBoxAdapter(
              child: onPeekHeight == null
                  ? _peek(context, sorted)
                  : MeasureHeight(onHeight: onPeekHeight!, child: _peek(context, sorted)),
            ),
            if (detail != null)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                sliver: SliverToBoxAdapter(child: detail),
              ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              sliver: SliverToBoxAdapter(child: Eyebrow('Drones (${sorted.length})')),
            ),
            if (sorted.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Center(
                      child: Text(emptyText, style: OrecchinoType.body.copyWith(color: OrecchinoColors.inkMuted))),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                sliver: SliverList.separated(
                  itemCount: sorted.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) => ContactCard(
                    item: sorted[i],
                    headingDeg: headingDeg,
                    selected: sorted[i].id == selectedId,
                    series: history.series(sorted[i].id),
                    onTap: () => onSelect(sorted[i].id),
                    onLongPress: onDetails == null ? null : () => onDetails!(sorted[i].id),
                  ),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 16)),
          ],
        ),
      ),
    );
  }

  Widget _peek(BuildContext context, List<LiveContactItem> sorted) {
    final drones = sorted.length;
    final nearest = sorted.where((c) => c.distanceM != null).toList()
      ..sort((a, b) => a.distanceM!.compareTo(b.distanceM!));
    final n = nearest.firstOrNull;
    final h = headingDeg;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (panel) ...[
          const SizedBox(height: 14),
          if (header != null) Padding(padding: const EdgeInsets.fromLTRB(14, 0, 14, 12), child: header),
        ] else
          Semantics(
            button: true,
            label: 'Drones sheet, ${contactCounts(contacts)}, show or hide',
            excludeSemantics: true,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onToggle,
              // A 44 pt target; the bar itself stays slim.
              child: SizedBox(
                height: OrecchinoTheme.minTarget,
                child: Center(
                  child: Container(
                    width: 40,
                    height: 5,
                    decoration:
                        BoxDecoration(color: OrecchinoColors.lineBright, borderRadius: BorderRadius.circular(3)),
                  ),
                ),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Wrap(
            spacing: 20,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              _count(drones, drones == 1 ? 'drone' : 'drones', OrecchinoColors.aqua, false),
              if (n != null)
                Semantics(
                  label: 'Nearest drone: ${n.label}, ${n.rangeText}'
                      '${n.bearingDeg != null && h != null ? ', ${Geo.clockWords(n.bearingDeg!, h)}' : ''}',
                  excludeSemantics: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('NEAREST', style: OrecchinoType.eyebrow),
                      const SizedBox(height: 2),
                      Text.rich(TextSpan(children: [
                        TextSpan(text: n.label, style: OrecchinoType.bodyStrong),
                        TextSpan(
                          text:
                              '  ${n.rangeText}${n.bearingDeg != null && h != null ? ' · ${Geo.clockWords(n.bearingDeg!, h)}' : ''}',
                          style: OrecchinoType.label.copyWith(color: OrecchinoColors.ink),
                        ),
                      ])),
                    ],
                  ),
                ),
            ],
          ),
        ),
        if (conflictWatch != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Align(alignment: Alignment.centerLeft, child: ConflictWatchChip(summary: conflictWatch!)),
          ),
      ],
    );
  }

  Widget _count(int n, String label, Color color, bool aircraft) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        ContactGlyph(aircraft: aircraft, color: color, size: 30),
        const SizedBox(width: 8),
        Text('$n', style: OrecchinoType.title.copyWith(fontSize: 28, fontFeatures: OrecchinoType.tabular)),
        const SizedBox(width: 5),
        Flexible(
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(label, style: OrecchinoType.label),
          ),
        ),
      ],
    );
  }
}

class ContactCard extends StatelessWidget {
  final LiveContactItem item;
  final double? headingDeg;
  final bool selected;
  final List<double> series;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const ContactCard({
    super.key,
    required this.item,
    required this.headingDeg,
    required this.selected,
    required this.series,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final c = item;
    final color = contactColor(c);
    final al = c.alert;
    final words = [...c.alertWords, if (al != null) al.text];
    final h = headingDeg;
    final where = [
      if (c.bearingDeg != null) h != null ? Geo.clockWords(c.bearingDeg!, h) : '${c.bearingDeg!.round()}°',
    ];
    final meta = [
      if (c.operatorLine != null) c.operatorLine!,
      if (c.heightText != null) c.heightText!,
      if (c.trendText != null) c.trendText!,
      c.stale ? 'STALE ${c.ageSeconds.round()} s' : 'heard ${c.ageSeconds.round()} s ago',
    ];
    final spark = c.rssi == null ? null : 'signal ${c.rssi} dBm';
    return MergeSemantics(
      child: Semantics(
        label: c.semantics(headingDeg: h),
        excludeSemantics: true,
        button: true,
        selected: selected,
        onLongPressHint: onLongPress == null ? null : 'All details',
        child: AnimatedContainer(
          duration: Motion.of(context, Motion.base),
          curve: Motion.standard,
          decoration: BoxDecoration(
            color: selected ? color.withValues(alpha: 0.10) : Colors.white.withValues(alpha: 0.035),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected
                  ? color.withValues(alpha: 0.7)
                  : (c.alerting ? color.withValues(alpha: 0.45) : OrecchinoColors.line),
              width: selected ? 1.4 : 1,
            ),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onTap,
            onLongPress: onLongPress,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Opacity(opacity: c.stale ? 0.5 : 1, child: ContactGlyph(aircraft: c.isAircraft, color: color)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(c.label, style: OrecchinoType.heading.copyWith(fontSize: 17)),
                            // What to do first, then why (the rules' words).
                            if (al != null) ...[
                              const SizedBox(height: 4),
                              Text(trafficAction(al), style: OrecchinoType.alert.copyWith(color: color, fontSize: 14)),
                              if (trafficGeometry(al).isNotEmpty)
                                Text(trafficGeometry(al),
                                    style: OrecchinoType.caption.copyWith(color: OrecchinoColors.ink)),
                            ],
                            const SizedBox(height: 4),
                            Wrap(spacing: 6, runSpacing: 4, children: [
                              if (c.isDrone) SensorChips(c.sensors) else for (final s in c.sources) Tag(s),
                              if (c.sublabel != null && c.isAircraft && c.sublabel != 'ADS-B')
                                Tag(c.sublabel!.replaceFirst('ADS-B ', '')),
                              for (final w in words) Tag(w, color: color, filled: true),
                            ]),
                            const SizedBox(height: 6),
                            Text(meta.join(' · '),
                                style: OrecchinoType.caption
                                    .copyWith(color: c.isClosing ? OrecchinoColors.caution : OrecchinoColors.inkMuted)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 132),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(c.rangeText, textAlign: TextAlign.end, style: OrecchinoType.metric),
                            if (where.isNotEmpty)
                              Text(where.first, textAlign: TextAlign.end, style: OrecchinoType.caption),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (spark != null && series.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(
                          flex: 3, child: Sparkline(values: series, color: color.withValues(alpha: c.stale ? 0.5 : 1))),
                      const SizedBox(width: 10),
                      Flexible(flex: 2, child: Text(spark, textAlign: TextAlign.end, style: OrecchinoType.caption)),
                    ]),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The selected drone, in full.
class DroneDetailCard extends StatelessWidget {
  final LiveContactItem item;
  final double? headingDeg;
  final List<double> series;
  final VoidCallback onClose;

  /// Opens the full details sheet (every field the broadcast carries).
  final VoidCallback? onDetails;

  const DroneDetailCard(
      {super.key, required this.item, this.headingDeg, required this.series, required this.onClose, this.onDetails});

  @override
  Widget build(BuildContext context) {
    final c = item;
    final color = contactColor(c);
    final h = headingDeg;
    final al = c.alert;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 8, 16),
      decoration: BoxDecoration(
        color: OrecchinoColors.raised.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(OrecchinoTheme.radius),
        border: Border.all(color: color.withValues(alpha: 0.7), width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // The action first, then the geometry, then the rules' words.
                if (al != null) ...[
                  Text(trafficAction(al), style: OrecchinoType.alert.copyWith(color: color)),
                  if (trafficGeometry(al).isNotEmpty)
                    Text(trafficGeometry(al), style: OrecchinoType.label.copyWith(color: OrecchinoColors.ink)),
                  Text('${al.text} · ${TrafficRules.ageWords(al.ageS)}', style: OrecchinoType.caption),
                ],
                for (final w in c.alertWords) Text(w, style: OrecchinoType.alert.copyWith(color: color)),
                if (al != null || c.alertWords.isNotEmpty) const SizedBox(height: 6),
                Text(c.label, style: OrecchinoType.title.copyWith(fontSize: 26)),
                const SizedBox(height: 2),
                Text('Drone', style: OrecchinoType.id.copyWith(color: OrecchinoColors.inkMuted)),
                if (c.sensors.isNotEmpty)
                  Padding(padding: const EdgeInsets.only(top: 4), child: SensorChips(c.sensors, withRssi: true)),
                if (c.operatorLine != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(c.operatorLine!, style: OrecchinoType.caption.copyWith(color: OrecchinoColors.ink)),
                  ),
              ]),
            ),
            IconButton(tooltip: 'Close', icon: const Icon(Icons.close_rounded, size: 22), onPressed: onClose),
          ]),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: MetricGrid(children: [
              _tile(
                  'RANGE',
                  c.rangeText,
                  c.bearingDeg == null
                      ? null
                      : (h != null ? Geo.clockWords(c.bearingDeg!, h) : 'bearing ${c.bearingDeg!.round()}°')),
              _tile('HEIGHT', c.heightM == null ? 'unknown' : '${c.heightM!.round()} m',
                  c.heightM == null ? null : c.heightRef),
              _tile('SPEED', c.speedMps == null ? 'unknown' : '${c.speedMps!.toStringAsFixed(1)} m/s', c.trendText),
              _tile('HEARD', '${c.ageSeconds.round()} s ago', c.stale ? 'stale' : null),
            ]),
          ),
          if (series.length > 1) ...[
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Row(children: [
                Expanded(flex: 3, child: Sparkline(values: series, color: color, height: 36)),
                const SizedBox(width: 10),
                Flexible(
                  flex: 2,
                  child: Text(c.rssi == null ? 'signal' : 'signal ${c.rssi} dBm',
                      textAlign: TextAlign.end, style: OrecchinoType.caption),
                ),
              ]),
            ),
          ],
          if (onDetails != null) ...[
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: onDetails,
                  icon: const Icon(Icons.info_outline_rounded, size: 18),
                  label: const Text('All details'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, OrecchinoTheme.minTarget),
                    foregroundColor: OrecchinoColors.aqua,
                    side: BorderSide(color: OrecchinoColors.aqua.withValues(alpha: 0.5)),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _tile(String label, String value, String? sub) => Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(OrecchinoTheme.radiusSmall),
          border: Border.all(color: OrecchinoColors.line),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: OrecchinoType.eyebrow),
          const SizedBox(height: 4),
          Text(value, style: OrecchinoType.metric),
          if (sub != null) Text(sub, style: OrecchinoType.caption),
        ]),
      );
}

/// Traffic level of the whole scene: the worst alert anywhere.
TrafficLevel sceneLevel(List<LiveContactItem> items, TrafficLevel traffic) {
  var level = traffic;
  for (final c in items) {
    if (c.stale) continue;
    if (c.alertLevel.index > level.index) level = c.alertLevel;
  }
  return level;
}
