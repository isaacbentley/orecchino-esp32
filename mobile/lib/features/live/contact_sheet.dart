// contact_sheet.dart — the Live screen's glass sheet. Peeking, it shows the
// counts and the nearest contact; pulled up, the selected contact's card and
// a card per contact (source badges, alert words, height, age, and a
// sparkline of its signal or altitude). Each card reads the same words as
// its mark on the sky.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import '../../core/geo.dart';
import '../../core/traffic/traffic_rules.dart';
import '../../ui/contact_glyph.dart';
import '../../ui/glass.dart';
import '../../ui/measure_height.dart';
import '../../ui/sparkline.dart';
import '../../ui/theme/theme.dart';
import 'live_items.dart';

Color contactColor(LiveContactItem c) {
  if (c.alertWords.contains('EMERGENCY REPORTED') || c.alertWords.contains('EMERGENCY SQUAWK')) {
    return OrecchinoColors.warning;
  }
  final base = OrecchinoColors.level(
    c.alertLevel,
    none: c.isAircraft ? OrecchinoColors.aircraft : OrecchinoColors.aqua,
  );
  return base;
}

String _plural(int n, String one, String many) => '$n ${n == 1 ? one : many}';

/// '2 drones · 1 aircraft'
String contactCounts(List<LiveContactItem> items) {
  final d = items.where((c) => !c.isAircraft).length;
  final a = items.length - d;
  return '${_plural(d, 'drone', 'drones')} · $a aircraft';
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
  final String? trafficSummary;
  final ContactHistory history;
  final double bottomInset;

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
    required this.trafficSummary,
    required this.history,
    required this.bottomInset,
    this.onPeekHeight,
    this.panel = false,
    this.header,
  });

  @override
  Widget build(BuildContext context) {
    // A stable order (drones as first heard, then aircraft): cards never
    // jump under a finger when an alert starts or stops. The capsule leads
    // with the alert, and each card carries its own alert words.
    final sorted = contacts;
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
              sliver: SliverToBoxAdapter(child: Eyebrow('Contacts (${contacts.length})')),
            ),
            if (contacts.isEmpty)
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
    final drones = contacts.where((c) => !c.isAircraft).length;
    final aircraft = contacts.length - drones;
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
            label: 'Contacts sheet, ${contactCounts(contacts)}, show or hide',
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
              _count(aircraft, 'aircraft', OrecchinoColors.aircraft, true),
              if (n != null)
                Semantics(
                  label: 'Nearest: ${n.isAircraft ? 'aircraft' : 'drone'} ${n.label}, ${n.rangeText}'
                      '${n.bearingDeg != null && h != null ? ', ${Geo.clockWords(n.bearingDeg!, h)}' : ''}',
                  excludeSemantics: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('NEAREST', style: OrecchinoType.eyebrow),
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
        if (trafficSummary != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: Row(children: [
              const Icon(Icons.flight_rounded, size: 14, color: OrecchinoColors.inkSubtle),
              const SizedBox(width: 6),
              Expanded(child: Text(trafficSummary!, style: OrecchinoType.caption)),
            ]),
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

  const ContactCard({
    super.key,
    required this.item,
    required this.headingDeg,
    required this.selected,
    required this.series,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = item;
    final color = contactColor(c);
    final words = [...c.alertWords, if (c.alert != null) c.alert!.text];
    final h = headingDeg;
    final where = [
      if (c.bearingDeg != null) h != null ? Geo.clockWords(c.bearingDeg!, h) : '${c.bearingDeg!.round()}°',
    ];
    final meta = [
      if (c.heightText != null) c.heightText!,
      if (c.trendText != null) c.trendText!,
      c.stale ? 'STALE ${c.ageSeconds.round()} s' : 'heard ${c.ageSeconds.round()} s ago',
    ];
    final spark = c.isAircraft
        ? (c.heightText == null ? null : 'altitude ${c.heightText}')
        : (c.rssi == null ? null : 'signal ${c.rssi} dBm');
    return MergeSemantics(
      child: Semantics(
        label: c.semantics(headingDeg: h),
        excludeSemantics: true,
        button: true,
        selected: selected,
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
                            const SizedBox(height: 4),
                            Wrap(spacing: 6, runSpacing: 4, children: [
                              for (final s in c.sources) Tag(s),
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

  const DroneDetailCard({super.key, required this.item, this.headingDeg, required this.series, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final c = item;
    final color = contactColor(c);
    final h = headingDeg;
    final words = [...c.alertWords, if (c.alert != null) c.alert!.text];
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
                for (final w in words) Text(w, style: OrecchinoType.alert.copyWith(color: color)),
                if (words.isNotEmpty) const SizedBox(height: 6),
                Text(c.label, style: OrecchinoType.title.copyWith(fontSize: 26)),
                const SizedBox(height: 2),
                Text('Drone · ${c.sources.join(' + ')}',
                    style: OrecchinoType.id.copyWith(color: OrecchinoColors.inkMuted)),
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
