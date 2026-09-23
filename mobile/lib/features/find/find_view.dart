// find_view.dart — Point-and-find compass arrow navigation view
//
// The arrow points at the chosen contact (a drone, or in Traffic mode an
// aircraft) as the phone turns: bearing minus heading. Without the phone's
// position or a compass there is no arrow, and the screen says why.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../app/app_controller.dart';
import '../../core/geo.dart';
import '../../ui/theme.dart';
import '../live/live_view.dart';

class FindView extends StatefulWidget {
  final AppController app;

  const FindView({super.key, required this.app});

  @override
  State<FindView> createState() => _FindViewState();
}

class _FindViewState extends State<FindView> {
  String? _targetId;

  @override
  Widget build(BuildContext context) {
    final contacts = buildLiveItems(widget.app);
    final heading = widget.app.headingDeg;
    LiveContactItem? target;
    if (contacts.isNotEmpty) {
      target = contacts.where((c) => c.id == _targetId).firstOrNull ?? contacts.first;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('POINT & FIND'),
        actions: [
          if (contacts.isNotEmpty)
            PopupMenuButton<String>(
              tooltip: 'Choose what to find',
              icon: const Icon(Icons.swap_horiz, color: OrecchinoTheme.accent),
              onSelected: (id) => setState(() => _targetId = id),
              itemBuilder: (context) => [
                for (final c in contacts)
                  PopupMenuItem(
                    value: c.id,
                    child: Text('${c.isAircraft ? 'Aircraft' : 'Drone'} ${c.label} · ${c.rangeText}'),
                  ),
              ],
            ),
        ],
      ),
      body: SafeArea(
        child: target == null
            ? const Center(
                child: Text('No contacts yet', style: TextStyle(color: OrecchinoTheme.muted, fontSize: 15)),
              )
            : _find(target, heading),
      ),
    );
  }

  Widget _find(LiveContactItem target, double? heading) {
    final canPoint = target.bearingDeg != null && heading != null;
    final why = target.bearingDeg == null
        ? (widget.app.observer == null ? 'Your position is unknown: no direction' : 'No position reported by the target')
        : (heading == null ? 'No compass on this phone: bearing ${target.bearingDeg!.round()}° true' : null);
    final color = target.isClosing ? OrecchinoTheme.amber : OrecchinoTheme.accent;
    final clock = canPoint ? Geo.clockWords(target.bearingDeg!, heading) : null;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        children: [
          Text(
            '${target.isAircraft ? 'AIRCRAFT' : 'DRONE'} ${target.label}',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: OrecchinoTheme.text),
          ),
          if (target.sublabel != null)
            Text(target.sublabel!, style: const TextStyle(fontSize: 13, color: OrecchinoTheme.muted)),
          for (final w in [...target.alertWords, if (target.alert != null) target.alert!.text])
            Text(w, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: OrecchinoTheme.danger)),
          if (target.trendText != null) ...[
            const SizedBox(height: 6),
            Text(target.trendText!.toUpperCase(),
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color)),
          ],
          const SizedBox(height: 24),
          if (canPoint)
            Semantics(
              label: 'Arrow pointing to ${target.label}, $clock',
              child: Transform.rotate(
                angle: (target.bearingDeg! - heading) * math.pi / 180.0,
                child: SizedBox(
                  width: 220,
                  height: 220,
                  child: CustomPaint(painter: _FindArrowPainter(color: color)),
                ),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 60),
              child: Text(why ?? '', textAlign: TextAlign.center, style: const TextStyle(color: OrecchinoTheme.muted)),
            ),
          const SizedBox(height: 24),
          Text(
            target.rangeText,
            style: const TextStyle(fontSize: 34, fontWeight: FontWeight.bold, color: OrecchinoTheme.text),
          ),
          const SizedBox(height: 4),
          Text(
            [
              if (clock != null) clock,
              if (target.bearingDeg != null) 'bearing ${target.bearingDeg!.round()}°',
              'height ${target.heightText ?? 'unknown'}',
              'heard ${target.ageSeconds.round()} s ago',
            ].join(' · '),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: OrecchinoTheme.muted),
          ),
        ],
      ),
    );
  }
}

class _FindArrowPainter extends CustomPainter {
  final Color color;

  const _FindArrowPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width / 2;

    final path = Path()
      ..moveTo(cx, cy - r)
      ..lineTo(cx + r * 0.45, cy + r * 0.6)
      ..lineTo(cx, cy + r * 0.25)
      ..lineTo(cx - r * 0.45, cy + r * 0.6)
      ..close();

    canvas.drawPath(
        path,
        Paint()
          ..color = color.withValues(alpha: 0.25)
          ..style = PaintingStyle.fill);
    canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.5);
  }

  @override
  bool shouldRepaint(covariant _FindArrowPainter old) => old.color != color;
}
