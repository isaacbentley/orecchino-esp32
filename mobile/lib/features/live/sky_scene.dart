// sky_scene.dart — the painted sky plus what sits on it as widgets: one
// screen-reader node and 44 pt tap target per mark (the same words as its
// card), and the separation numbers floating on each bridge.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/geo.dart';
import '../../core/traffic/traffic_rules.dart';

import '../../ui/traffic_widgets.dart';
import 'live_items.dart';
import 'sky_painter.dart';
import 'sky_projection.dart';

class SkyScene extends StatelessWidget {
  /// Where each bridge's numbers float, and the space they take: the first
  /// point along the bridge (middle first) clear of the badges already
  /// placed and of the marks. If a crowded sky has no room, the most urgent
  /// pair (the rules list alerts most urgent first) keeps its numbers; the
  /// others are still on their cards and read by the screen reader.
  List<(SkyBridge, Rect)> _badgeSpots(Map<String, Offset> tops, TextScaler scaler) {
    final spots = <(SkyBridge, Rect)>[];
    for (final b in bridges) {
      final p1 = tops[b.droneId], p2 = tops[b.aircraftId];
      if (p1 == null || p2 == null) continue;
      final size = SeparationBridgeBadge.measure(b.alert, scaler);
      Rect? best;
      // Along the bridge first, then just above or below its middle, then
      // clear above both marks.
      final mid = Offset.lerp(p1, p2, 0.5)!;
      final lift = size.height + 14;
      final centres = [
        for (final t in const [0.5, 0.3, 0.7, 0.15, 0.85]) Offset.lerp(p1, p2, t)!,
        mid - Offset(0, lift),
        mid + Offset(0, lift),
        Offset(mid.dx, (p1.dy < p2.dy ? p1.dy : p2.dy) - lift - 8),
      ];
      for (final centre in centres) {
        final r = Rect.fromCenter(center: centre, width: size.width, height: size.height);
        final clearOfBadges = spots.every((s) => !s.$2.inflate(4).overlaps(r));
        final clearOfMarks = tops.values.every((m) => !r.overlaps(Rect.fromCircle(center: m, radius: 16)));
        if (clearOfBadges && clearOfMarks) {
          best = r;
          break;
        }
      }
      if (best == null && spots.isNotEmpty) continue;
      spots.add((b, best ?? Rect.fromCenter(center: centres.last, width: size.width, height: size.height)));
    }
    return spots;
  }

  final SkyCamera camera;
  final List<SkyContact> marks;
  final List<SkyBridge> bridges;
  final Map<String, LiveContactItem> items;
  final String? selectedId;
  final double? headingDeg;
  final bool showFacing;
  final ValueListenable<double>? clock;
  final String semanticLabel;
  final ValueChanged<String> onSelect;

  const SkyScene({
    super.key,
    required this.camera,
    required this.marks,
    required this.bridges,
    required this.items,
    required this.selectedId,
    required this.headingDeg,
    required this.showFacing,
    required this.clock,
    required this.semanticLabel,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3);
    final tops = <String, Offset>{};
    final beyond = <String>{};
    for (final m in marks) {
      final p = camera.place(m.distanceM, m.bearingDeg, heightM: m.isOperator ? 0 : m.heightM);
      if (p == null) continue;
      tops[m.id] = p.point.offset;
      if (p.beyond) beyond.add(m.id);
    }
    final you = camera.groundAt(0, 0);
    if (you != null) tops[SkyBridge.you] = you.offset;
    final badges = _badgeSpots(tops, scaler);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: Semantics(
            label: semanticLabel,
            // Two layers: the base (ground, stems, labels) repaints only when
            // the data or the camera change; the live layer (sweep, glowing
            // marks, pulses) every frame while motion is on.
            child: Stack(fit: StackFit.expand, children: [
              RepaintBoundary(
                child: CustomPaint(
                  painter: SkyPainter(
                    layer: SkyLayer.base,
                    camera: camera,
                    contacts: marks,
                    bridges: bridges,
                    selectedId: selectedId,
                    showFacing: showFacing,
                    textScaler: scaler,
                    reserved: [for (final (_, r) in badges) r],
                    // Left and right: the notch and, on a phone on its side,
                    // the tab rail (main.dart puts it in the padding).
                    labelInsets: EdgeInsets.only(
                        left: MediaQuery.paddingOf(context).left, right: MediaQuery.paddingOf(context).right),
                  ),
                ),
              ),
              RepaintBoundary(
                child: CustomPaint(
                  painter: SkyPainter(
                    layer: SkyLayer.live,
                    camera: camera,
                    contacts: marks,
                    bridges: bridges,
                    selectedId: selectedId,
                    showFacing: showFacing,
                    clock: clock,
                  ),
                ),
              ),
            ]),
          ),
        ),
        for (final (b, r) in badges)
          Positioned(
            left: r.center.dx,
            top: r.center.dy,
            child: FractionalTranslation(
              translation: const Offset(-0.5, -0.5),
              // A label on the graphic: the cards and the screen reader
              // carry the same numbers at full size.
              child: ExcludeSemantics(
                child: MediaQuery.withClampedTextScaling(
                  maxScaleFactor: 1.3,
                  child: SeparationBridgeBadge(alert: b.alert),
                ),
              ),
            ),
          ),
        for (final m in marks)
          if (tops[m.id] != null && items[m.id] != null)
            Positioned(
              left: tops[m.id]!.dx - 22,
              top: tops[m.id]!.dy - 22,
              width: 44,
              height: 44,
              child: Semantics(
                button: true,
                selected: selectedId == m.id,
                label: beyond.contains(m.id)
                    ? '${items[m.id]!.semantics(headingDeg: headingDeg)}, beyond ${Geo.rangeText(camera.rangeM)}, '
                        '${Geo.rangeText(m.distanceM)} ${TrafficRules.compass8(m.bearingDeg)}, shown on the edge'
                    : items[m.id]!.semantics(headingDeg: headingDeg),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onSelect(m.id),
                ),
              ),
            ),
      ],
    );
  }
}
