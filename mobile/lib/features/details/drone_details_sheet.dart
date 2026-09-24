// drone_details_sheet.dart — the full technical details of one drone, as a
// glass sheet over the current screen. Opened from the selected drone's
// card on Live (a sky mark or a contact card), from Find's target, and from
// a History record. A live contact's sheet follows the app as it updates;
// a record's is fixed. Sections from drone_details.dart; every row is one
// screen-reader node with the same words; coordinates and IDs can be
// copied. A readable width on tablets and phones on their side.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../app/app_controller.dart';
import '../../core/live/sensors.dart';
import '../../data/db.dart';
import '../../ui/contact_glyph.dart';
import '../../ui/glass.dart';
import '../../ui/sensor_chips.dart';
import '../../ui/sparkline.dart';
import '../../ui/theme/theme.dart';
import '../live/live_items.dart';
import 'drone_details.dart';

Color detailColor(DetailTone t) => switch (t) {
      DetailTone.ok => OrecchinoColors.ok,
      DetailTone.caution => OrecchinoColors.caution,
      DetailTone.warning => OrecchinoColors.warning,
      DetailTone.muted => OrecchinoColors.inkMuted,
      DetailTone.plain => OrecchinoColors.ink,
    };

class DroneDetailsSheet extends StatefulWidget {
  /// Builds the details (again on every app update for a live drone);
  /// null when the drone is no longer held.
  final DroneDetails? Function() details;
  final Listenable? listenable;
  final bool simulated;

  const DroneDetailsSheet({super.key, required this.details, this.listenable, this.simulated = false});

  /// The details of a live drone, following the app.
  static Future<void> showLive(BuildContext context, AppController app, String key) => _show(
        context,
        DroneDetailsSheet(
          listenable: app,
          simulated: app.isSimulated,
          details: () => liveDetailsFor(app, key),
        ),
      );

  /// The details of a History record.
  static Future<void> showRecord(BuildContext context, DetectionEntry d, {AppController? app}) async {
    final det = app == null ? null : await app.db.getDetector(d.detectorId);
    if (!context.mounted) return;
    await _show(
      context,
      DroneDetailsSheet(
        simulated: d.detectorId == 'simulated',
        details: () => recordDroneDetails(d, observer: app?.observer, detectorName: det?.name),
      ),
    );
  }

  static Future<void> _show(BuildContext context, Widget sheet) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        barrierColor: const Color(0x99020409),
        builder: (_) => FractionallySizedBox(
          heightFactor: 0.94,
          child: Glass(
            blur: 32,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
            child: sheet,
          ),
        ),
      );

  @override
  State<DroneDetailsSheet> createState() => _DroneDetailsSheetState();
}

/// A live drone's details from the app: its alerts, the conflict watch and
/// its signal history.
DroneDetails? liveDetailsFor(AppController app, String key) {
  final c = app.tracker[key];
  if (c == null) return null;
  return liveDroneDetails(
    c,
    nowMs: app.nowMs(),
    observer: app.observer,
    alerts: [
      for (final a in app.traffic.result.alerts)
        if (a.droneId == key) a
    ],
    conflictWatch: app.settings.adsb ? app.traffic.result.summary : null,
    rssiSeries: ContactHistory.of(app).series(key),
  );
}

class _DroneDetailsSheetState extends State<DroneDetailsSheet> {
  String? _copied;

  Future<void> _copy(DetailRow r) async {
    await Clipboard.setData(ClipboardData(text: r.copy!));
    if (!mounted) return;
    setState(() => _copied = r.label);
    unawaited(SemanticsService.sendAnnouncement(View.of(context), '${r.label} copied', Directionality.of(context)));
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (mounted && _copied == r.label) setState(() => _copied = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.listenable;
    return l == null ? _body(context) : ListenableBuilder(listenable: l, builder: (context, _) => _body(context));
  }

  Widget _body(BuildContext context) {
    final d = widget.details();
    return SafeArea(
      top: false,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 24),
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 5,
                  margin: const EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(color: OrecchinoColors.lineBright, borderRadius: BorderRadius.circular(3)),
                ),
              ),
              if (d == null) ..._gone(context) else ..._content(d),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _gone(BuildContext context) => [
        Row(children: [
          Expanded(child: Semantics(header: true, child: Text('Drone details', style: OrecchinoType.heading))),
          _close(context),
        ]),
        const SizedBox(height: 24),
        Text('This drone is no longer heard (contacts are removed 10 minutes after the last message).',
            style: OrecchinoType.body.copyWith(color: OrecchinoColors.inkMuted)),
      ];

  Widget _close(BuildContext context) => IconButton(
        tooltip: 'Close',
        icon: const Icon(Icons.close_rounded),
        onPressed: () => Navigator.of(context).maybePop(),
      );

  List<Widget> _content(DroneDetails d) {
    final tone = detailColor(d.alertTone);
    final color = d.alerts.isEmpty || d.alertTone == DetailTone.muted ? OrecchinoColors.aqua : tone;
    return [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: ContactGlyph(aircraft: false, color: color, size: 40),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Semantics(
              header: true,
              label: 'Drone ${d.title} details${d.model == null ? '' : ', ${d.model}'}',
              excludeSemantics: true,
              child: Text(d.title, style: OrecchinoType.title.copyWith(fontSize: 28)),
            ),
            if (d.fullId != null && d.fullId != d.title)
              Text(d.fullId!, style: OrecchinoType.id.copyWith(color: OrecchinoColors.inkMuted)),
            if (d.model != null) Text(d.model!, style: OrecchinoType.label.copyWith(color: OrecchinoColors.ink)),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: [
              Tag(d.live ? 'LIVE' : 'HISTORY RECORD', color: d.live ? OrecchinoColors.aqua : OrecchinoColors.inkMuted),
              if (widget.simulated) Tag('SIMULATED', color: OrecchinoColors.caution),
            ]),
            if (d.sensors.isNotEmpty) ...[
              const SizedBox(height: 6),
              Semantics(label: sensorWords(d.sensors), child: SensorChips(d.sensors, withRssi: true)),
            ],
          ]),
        ),
        _close(context),
      ]),
      if (d.alerts.isNotEmpty) ...[
        const SizedBox(height: 12),
        Semantics(
          liveRegion: true,
          label: 'Alerts: ${d.alerts.join(', ')}',
          excludeSemantics: true,
          child: Wrap(spacing: 6, runSpacing: 6, children: [
            for (final a in d.alerts)
              Tag(a, color: a == 'TEST KEY' ? OrecchinoColors.inkMuted : tone, filled: a != 'TEST KEY'),
          ]),
        ),
      ],
      const SizedBox(height: 6),
      for (final s in d.sections) ...[
        Eyebrow(s.title),
        Glass(
          padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
          child: Column(children: [
            for (var i = 0; i < s.rows.length; i++) ...[
              if (i > 0) Divider(height: 1, color: OrecchinoColors.line),
              _row(s.rows[i]),
              if (s.title == 'Signal' && s.rows[i].label == 'Signal now' && d.rssiSeries.length > 1)
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 0, 8, 10),
                  child: Sparkline(values: d.rssiSeries, height: 34),
                ),
            ],
          ]),
        ),
      ],
      const SizedBox(height: 14),
      Text(
        'As broadcast by the drone and heard by the detector: nothing here is verified except the ID '
        'signature verdict, and "not reported" means the broadcast (or the detector\'s line) did not carry it.',
        style: OrecchinoType.caption,
      ),
    ];
  }

  Widget _row(DetailRow r) {
    final valueStyle = (r.mono ? OrecchinoType.idSmall.copyWith(fontSize: 14) : OrecchinoType.bodyStrong)
        .copyWith(color: r.reported ? detailColor(r.tone) : OrecchinoColors.inkSubtle);
    final value = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(r.shown,
          style:
              r.reported ? valueStyle : valueStyle.copyWith(fontStyle: FontStyle.italic, fontWeight: FontWeight.w400)),
      if (r.secondary != null) Text(r.secondary!, style: OrecchinoType.caption),
    ]);
    final label = Text(r.label, style: OrecchinoType.label);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: Row(children: [
        Expanded(
          child: Semantics(
            container: true,
            label: r.semantics,
            excludeSemantics: true,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 9),
              // Side by side when there is room; stacked on a narrow width or
              // at large text sizes.
              child: LayoutBuilder(builder: (context, box) {
                final scale = MediaQuery.textScalerOf(context).scale(1);
                if (box.maxWidth < 330 * scale) {
                  return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [label, const SizedBox(height: 2), value]);
                }
                return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: box.maxWidth * 0.38, child: label),
                  const SizedBox(width: 10),
                  Expanded(child: value),
                ]);
              }),
            ),
          ),
        ),
        if (r.copy != null)
          IconButton(
            tooltip: 'Copy ${r.label}',
            icon: Icon(_copied == r.label ? Icons.check_rounded : Icons.copy_rounded,
                size: 18, color: _copied == r.label ? OrecchinoColors.ok : OrecchinoColors.inkMuted),
            onPressed: () => _copy(r),
          )
        else
          const SizedBox(width: 8),
      ]),
    );
  }
}
