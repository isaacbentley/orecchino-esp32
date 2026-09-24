// history_view.dart — every synced record on a timeline. An activity ribbon
// across the last 6 h / 24 h / 7 d (alerts marked) that you scrub; the
// record under the cursor, or the one tapped, replays on a mini sky dome;
// below, the records grouped by day on glass cards, alerts in words (LIVE,
// EMERGENCY REPORTED, IN TFR, ID SIGNATURE INVALID, TEST KEY).
//
// Records keep one position and the highest height (rx_core.h emit_log),
// so the replay shows that position and the climb to that height over the
// record's duration, not a flown track.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/geo.dart';
import '../../core/protocol/messages.dart';
import '../../core/traffic/traffic_rules.dart';
import '../../data/db.dart';
import '../../ui/contact_glyph.dart';
import '../../ui/glass.dart';
import '../../ui/theme/theme.dart';
import '../live/sky_painter.dart';
import '../live/sky_projection.dart';
import 'history_timeline.dart';

List<String> recordWords(DetectionEntry d) => [
      if (d.active) 'LIVE',
      if (d.emerg) 'EMERGENCY REPORTED',
      if (d.tfr) 'IN TFR',
      if (AuthState.words(d.authState) != null) AuthState.words(d.authState)!,
    ];

bool recordAlert(DetectionEntry d) => d.emerg || d.tfr || d.authState == AuthState.invalid;

String _key(DetectionEntry d) => '${d.detectorId}|${d.rowKey}';

class HistoryView extends StatefulWidget {
  final AppDatabase db;

  /// For the phone's position (the replay's centre); optional.
  final AppController? app;

  const HistoryView({super.key, required this.db, this.app});

  @override
  State<HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends State<HistoryView> {
  String _filter = '';
  bool _onlyAlerts = false;
  int _windowH = 24;

  /// Moves the ribbon's cursor to a record picked from the list.
  int? _focusUtc;
  String? _selectedKey;

  /// A record's replay sheet is up: the inline card waits (one replay at a
  /// time), then plays the same record when the sheet closes.
  bool _sheetOpen = false;
  late final Stream<List<DetectionEntry>> _records = widget.db.watchDetections();

  /// A record from the list replays in a sheet over the list, which stays
  /// where it was (the ribbon's cursor moves to it too).
  void _openRecord(DetectionEntry d) {
    setState(() {
      _selectedKey = _key(d);
      _sheetOpen = true;
      if (d.lastUtc > 0) _focusUtc = d.lastUtc;
    });
    final o = widget.app?.observer;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Glass(
              blur: 30,
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: SingleChildScrollView(
                child: _Replay(
                  key: ValueKey('sheet:${_key(d)}'),
                  record: d,
                  obsLat: o?.lat,
                  obsLon: o?.lon,
                  simulated: widget.app?.isSimulated ?? false,
                  onClose: () => Navigator.of(ctx).maybePop(),
                ),
              ),
            ),
          ),
        ),
      ),
    ).whenComplete(() {
      if (mounted) setState(() => _sheetOpen = false);
    });
  }

  /// The ribbon's cursor landed on a record: replay it inline. Only a new
  /// record rebuilds the screen; moving the cursor redraws just the ribbon.
  void _scrubbedTo(String? key) {
    if (key != null && key != _selectedKey) setState(() => _selectedKey = key);
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Material(
      type: MaterialType.transparency,
      child: StreamBuilder<List<DetectionEntry>>(
        stream: _records,
        builder: (context, snapshot) {
          var list = snapshot.data ?? const <DetectionEntry>[];
          if (_onlyAlerts) list = list.where(recordAlert).toList();
          if (_filter.isNotEmpty) {
            list = list
                .where((d) =>
                    (d.uasId != null && d.uasId!.toLowerCase().contains(_filter)) ||
                    d.mac.toLowerCase().contains(_filter))
                .toList();
          }
          final selected = list.where((d) => _key(d) == _selectedKey).firstOrNull;
          final groups = HistoryTimeline.groupByDay([for (final d in list) d.lastUtc], DateTime.now());
          final alertCount = list.where(recordAlert).length;
          // Readable width on tablets and phones on their side; clear of the
          // notch / Dynamic Island on either side.
          final side = math.max(16.0, (mq.size.width - mq.padding.left - mq.padding.right - 720) / 2);
          final hPad = EdgeInsets.only(left: mq.padding.left + side, right: mq.padding.right + side);
          return CustomScrollView(
            slivers: [
              SliverSafeArea(
                bottom: false,
                left: false,
                right: false,
                sliver: SliverPadding(
                  padding: hPad.add(const EdgeInsets.only(top: 12)),
                  sliver: SliverList.list(children: [
                    _header(list.length, alertCount),
                    const SizedBox(height: 14),
                    TextField(
                      style: OrecchinoType.id.copyWith(fontSize: 14),
                      decoration: const InputDecoration(
                        hintText: 'Search UAS ID or MAC',
                        prefixIcon: Icon(Icons.search_rounded, size: 20),
                      ),
                      onChanged: (val) => setState(() => _filter = val.trim().toLowerCase()),
                    ),
                    const SizedBox(height: 14),
                    _Timeline(
                      list: list,
                      windowH: _windowH,
                      focusUtc: _focusUtc,
                      onWindow: (v) => setState(() => _windowH = v),
                      onRecord: _scrubbedTo,
                    ),
                    const SizedBox(height: 12),
                    _replay(_sheetOpen ? null : selected),
                  ]),
                ),
              ),
              if (!snapshot.hasData)
                const SliverToBoxAdapter(
                    child: Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())))
              else if (list.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(40),
                    child: Center(
                      child: Text('No history records',
                          style: OrecchinoType.body.copyWith(color: OrecchinoColors.inkMuted)),
                    ),
                  ),
                )
              else
                for (final (day, idx) in groups)
                  SliverPadding(
                    padding: hPad,
                    sliver: SliverList.list(children: [
                      const SizedBox(height: 10),
                      Eyebrow(day, trailing: Text('${idx.length}', style: OrecchinoType.caption)),
                      for (final i in idx)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _RecordCard(
                            record: list[i],
                            selected: _key(list[i]) == _selectedKey,
                            onTap: () => _openRecord(list[i]),
                          ),
                        ),
                    ]),
                  ),
              SliverToBoxAdapter(child: SizedBox(height: mq.padding.bottom + 24)),
            ],
          );
        },
      ),
    );
  }

  Widget _header(int n, int alerts) {
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.end,
      spacing: 12,
      runSpacing: 10,
      children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          const Text('FLIGHT LOG', style: OrecchinoType.eyebrow),
          const SizedBox(height: 2),
          Semantics(header: true, child: const Text('History', style: OrecchinoType.title)),
          const SizedBox(height: 2),
          Text('$n record${n == 1 ? '' : 's'} · $alerts with alerts', style: OrecchinoType.label),
        ]),
        GlassButton(
          semanticLabel: _onlyAlerts ? 'Show all records' : 'Show alerts only',
          selected: _onlyAlerts,
          wash: _onlyAlerts ? OrecchinoColors.caution : null,
          onTap: () => setState(() => _onlyAlerts = !_onlyAlerts),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.warning_amber_rounded,
                size: 18, color: _onlyAlerts ? OrecchinoColors.caution : OrecchinoColors.inkMuted),
            const SizedBox(width: 6),
            Text('Alerts only',
                style: OrecchinoType.label.copyWith(
                    color: _onlyAlerts ? OrecchinoColors.caution : OrecchinoColors.ink, fontWeight: FontWeight.w600)),
          ]),
        ),
      ],
    );
  }

  Widget _replay(DetectionEntry? d) {
    final o = widget.app?.observer;
    return Glass(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: d == null
          ? const Row(children: [
              Icon(Icons.play_circle_outline_rounded, color: OrecchinoColors.inkSubtle, size: 28),
              SizedBox(width: 12),
              Expanded(
                child: Text('Scrub the ribbon or pick a record to replay it on the sky.', style: OrecchinoType.label),
              ),
            ])
          : _Replay(
              key: ValueKey(_key(d)),
              record: d,
              obsLat: o?.lat,
              obsLon: o?.lon,
              simulated: widget.app?.isSimulated ?? false,
            ),
    );
  }
}

/// The activity ribbon: records binned across the window, with a cursor
/// you scrub. It keeps the cursor itself, so a scrub redraws only this card;
/// the screen hears about it only when the record under the cursor changes.
class _Timeline extends StatefulWidget {
  final List<DetectionEntry> list;
  final int windowH;
  final int? focusUtc;
  final ValueChanged<int> onWindow;
  final ValueChanged<String?> onRecord;

  const _Timeline({
    required this.list,
    required this.windowH,
    required this.focusUtc,
    required this.onWindow,
    required this.onRecord,
  });

  @override
  State<_Timeline> createState() => _TimelineState();
}

class _TimelineState extends State<_Timeline> {
  int? _cursorUtc;

  @override
  void didUpdateWidget(_Timeline old) {
    super.didUpdateWidget(old);
    if (widget.focusUtc != old.focusUtc && widget.focusUtc != null) _cursorUtc = widget.focusUtc;
  }

  @override
  Widget build(BuildContext context) {
    final list = widget.list;
    final windowH = widget.windowH;
    final nowUtc = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final end = nowUtc;
    final start = end - windowH * 3600;
    final nBins = windowH == 6 ? 36 : (windowH == 24 ? 48 : 56);
    final spans = [for (final d in list) (first: d.firstUtc, last: d.lastUtc, alert: recordAlert(d))];
    final bins = HistoryTimeline.bins(spans, start, end, nBins);
    final cursor = _cursorUtc?.clamp(start, end);
    final binW = (end - start) / nBins;

    void scrubTo(double fx) {
      final utc = (start + (end - start) * fx.clamp(0.0, 1.0)).round();
      final i = HistoryTimeline.recordAt(spans, utc, snapS: (binW * 1.5).round());
      setState(() => _cursorUtc = utc);
      if (i != null) widget.onRecord(_key(list[i]));
    }

    String wordsAt(int? utc) {
      if (utc == null) return 'Drag across the ribbon to scrub';
      final n = spans.where((s) => s.first <= utc && s.last >= utc).length;
      return '${HistoryTimeline.clock(utc)} · $n record${n == 1 ? '' : 's'} in the air';
    }

    final cursorWords = wordsAt(cursor);
    final up = ((cursor ?? start) + binW).round().clamp(start, end);
    final down = ((cursor ?? end) - binW).round().clamp(start, end);
    return Glass(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            const Text('ACTIVITY', style: OrecchinoType.eyebrow),
            GlassSegmented<int>(
              options: const [(6, '6 h', 'Last 6 hours'), (24, '24 h', 'Last 24 hours'), (168, '7 d', 'Last 7 days')],
              value: windowH,
              onChanged: widget.onWindow,
            ),
          ],
        ),
        const SizedBox(height: 10),
        Semantics(
          slider: true,
          label: 'Activity timeline, last ${windowH == 168 ? '7 days' : '$windowH hours'}',
          value: cursorWords,
          increasedValue: wordsAt(up),
          decreasedValue: wordsAt(down),
          onIncrease: () => scrubTo((up - start) / (end - start)),
          onDecrease: () => scrubTo((down - start) / (end - start)),
          child: LayoutBuilder(builder: (context, box) {
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => scrubTo(d.localPosition.dx / box.maxWidth),
              // The cursor follows from the first touch of a drag, not from
              // where the drag was recognised.
              onHorizontalDragStart: (d) => scrubTo(d.localPosition.dx / box.maxWidth),
              onHorizontalDragUpdate: (d) => scrubTo(d.localPosition.dx / box.maxWidth),
              child: SizedBox(
                height: 76,
                child: CustomPaint(
                  painter: _RibbonPainter(
                    bins: bins,
                    cursorFrac: cursor == null ? null : (cursor - start) / (end - start),
                  ),
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 6),
        ExcludeSemantics(
          child: Row(children: [
            for (var i = 0; i <= 4; i++) ...[
              if (i > 0) const Spacer(),
              Text(
                windowH == 168
                    ? HistoryTimeline.dayLabel(start + (end - start) * i ~/ 4, DateTime.now()).split(' ').first
                    : HistoryTimeline.clock(start + (end - start) * i ~/ 4),
                style: OrecchinoType.idSmall.copyWith(fontSize: 10),
              ),
            ],
          ]),
        ),
        const SizedBox(height: 8),
        // Spoken as it changes while scrubbing.
        Semantics(
          liveRegion: true,
          child: Text(cursorWords, style: OrecchinoType.label.copyWith(color: OrecchinoColors.ink)),
        ),
      ]),
    );
  }
}

class _RibbonPainter extends CustomPainter {
  final List<TimelineBin> bins;
  final double? cursorFrac;

  _RibbonPainter({required this.bins, required this.cursorFrac});

  @override
  void paint(Canvas canvas, Size size) {
    final n = bins.length;
    final w = size.width / n;
    final maxC = bins.fold<int>(1, (m, b) => math.max(m, b.count));
    final base = size.height - 4;
    // Baseline and faint hour grid.
    canvas.drawLine(Offset(0, base + 0.5), Offset(size.width, base + 0.5), Paint()..color = OrecchinoColors.line);
    for (var i = 0; i <= 4; i++) {
      final x = size.width * i / 4;
      canvas.drawLine(Offset(x, 4), Offset(x, base), Paint()..color = OrecchinoColors.line.withValues(alpha: 0.5));
    }
    for (var i = 0; i < n; i++) {
      final b = bins[i];
      final x = i * w + w * 0.18;
      final bw = w * 0.64;
      if (b.count == 0) {
        canvas.drawRRect(RRect.fromLTRBR(x, base - 3, x + bw, base, const Radius.circular(1.5)),
            Paint()..color = OrecchinoColors.lineBright.withValues(alpha: 0.5));
        continue;
      }
      final k = b.count / maxC;
      final h = 10 + (base - 16) * k;
      final color = b.alert ? OrecchinoColors.caution : OrecchinoColors.aqua;
      final r = RRect.fromLTRBR(x, base - h, x + bw, base, Radius.circular(bw / 2));
      canvas.drawRRect(
          r,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [color.withValues(alpha: 0.45 + 0.5 * k), color.withValues(alpha: 0.12)],
            ).createShader(r.outerRect));
      if (b.alert) {
        canvas.drawCircle(Offset(x + bw / 2, base - h - 5), 2.2, Paint()..color = OrecchinoColors.caution);
      }
    }
    // Now, at the right edge.
    canvas.drawCircle(Offset(size.width - 2, base), 3, Paint()..color = OrecchinoColors.aqua);
    final c = cursorFrac;
    if (c != null) {
      final x = size.width * c;
      canvas.drawLine(
          Offset(x, 0),
          Offset(x, base + 3),
          Paint()
            ..strokeWidth = 2
            ..color = OrecchinoColors.ink);
      canvas.drawCircle(Offset(x, 4), 5, Paint()..color = OrecchinoColors.ink);
      canvas.drawCircle(Offset(x, 4), 9, Paint()..color = OrecchinoColors.ink.withValues(alpha: 0.18));
    }
  }

  @override
  bool shouldRepaint(_RibbonPainter old) =>
      old.cursorFrac != cursorFrac ||
      old.bins.length != bins.length ||
      !Iterable<int>.generate(bins.length)
          .every((i) => old.bins[i].count == bins[i].count && old.bins[i].alert == bins[i].alert);
}

class _Replay extends StatefulWidget {
  final DetectionEntry record;
  final double? obsLat, obsLon;

  /// The phone's position is the demo's made-up one: no distance or bearing
  /// is printed from it.
  final bool simulated;

  /// Shown as a sheet over the list: a close button.
  final VoidCallback? onClose;

  const _Replay({super.key, required this.record, this.obsLat, this.obsLon, this.simulated = false, this.onClose});

  @override
  State<_Replay> createState() => _ReplayState();
}

class _ReplayState extends State<_Replay> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: Motion.replay);
  final ValueNotifier<double> _clock = ValueNotifier<double>(0);

  @override
  void initState() {
    super.initState();
    _c.addListener(() => _clock.value = _c.value * 4);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _play();
  }

  void _play() {
    if (Motion.reduced(context)) {
      _c.value = 1;
    } else {
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.record;
    final words = recordWords(d);
    final havePos = d.lat != null && d.lon != null && Geo.validCoord(d.lat, d.lon);
    final haveObs = widget.obsLat != null && widget.obsLon != null;
    double dist = 0, brg = 0;
    if (havePos && haveObs) {
      dist = Geo.distanceM(widget.obsLat!, widget.obsLon!, d.lat!, d.lon!);
      brg = Geo.bearingDeg(widget.obsLat!, widget.obsLon!, d.lat!, d.lon!);
    }
    final range =
        [500.0, 1000.0, 3000.0, 5000.0, 10000.0].firstWhere((r) => r >= dist * 1.25, orElse: () => dist * 1.25);
    final color = d.emerg ? OrecchinoColors.warning : (recordAlert(d) ? OrecchinoColors.caution : OrecchinoColors.aqua);
    // Words only for what is known: no distance from an unknown or made-up
    // position, and no bearing where there is no distance to have one.
    final String where;
    if (!havePos) {
      where = 'No position in this record';
    } else if (!haveObs) {
      where = 'Your position is unknown: shown at the centre';
    } else if (widget.simulated) {
      where = 'Shown around the SIMULATED position';
    } else if (dist < 1) {
      where = 'Where you are now';
    } else {
      where = '${Geo.rangeText(dist)} from you, bearing ${brg.round()}°';
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        const Expanded(child: Text('REPLAY', style: OrecchinoType.eyebrow)),
        IconButton(
          tooltip: 'Replay again',
          icon: const Icon(Icons.replay_rounded, size: 20),
          onPressed: _play,
        ),
        if (widget.onClose != null)
          IconButton(tooltip: 'Close', icon: const Icon(Icons.close_rounded, size: 22), onPressed: widget.onClose),
      ]),
      Semantics(
        label:
            'Replay of ${d.uasId ?? d.mac}: $where, highest ${d.maxH == null ? 'height unknown' : '${d.maxH!.round()} m'}',
        child: SizedBox(
          height: 200,
          // Sized once; only the painter's inputs change as the replay runs.
          // The viewport is chosen so the tilted dome (about 0.9 of the ring
          // radius above and below its centre) stays inside the box, clear
          // of the progress bar under it.
          child: ClipRect(child: LayoutBuilder(builder: (context, box) {
            final size = Size(box.maxWidth, box.maxHeight);
            return AnimatedBuilder(
              animation: _c,
              builder: (context, _) {
                final p = Curves.easeOutCubic.transform(_c.value);
                final cam = SkyCamera.fit(
                  size: size,
                  viewport: Rect.fromLTWH(0, -size.height * 0.12, size.width, size.height * 1.18),
                  tiltDeg: 58,
                  yawDeg: -25 + 50 * p,
                  rangeM: range,
                );
                return CustomPaint(
                  size: size,
                  painter: SkyPainter(
                    camera: cam,
                    compact: true,
                    showFacing: false,
                    clock: _c.isAnimating ? _clock : null,
                    contacts: [
                      if (havePos)
                        SkyContact(
                          id: 'r',
                          label: '',
                          distanceM: dist,
                          bearingDeg: brg,
                          heightM: (d.maxH ?? 0) * p,
                          heightKnown: d.maxH != null,
                          isAircraft: false,
                          level: d.emerg ? TrafficLevel.warning : TrafficLevel.none,
                          alerting: recordAlert(d),
                        ),
                    ],
                  ),
                );
              },
            );
          })),
        ),
      ),
      const SizedBox(height: 8),
      AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = d.firstUtc > 0 ? d.firstUtc + ((d.lastUtc - d.firstUtc) * _c.value).round() : d.lastUtc;
          return Row(children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: _c.value,
                  minHeight: 4,
                  backgroundColor: OrecchinoColors.line,
                  color: color,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(HistoryTimeline.clock(t), style: OrecchinoType.label.copyWith(color: OrecchinoColors.ink)),
          ]);
        },
      ),
      const SizedBox(height: 10),
      Text(d.uasId ?? d.mac, style: OrecchinoType.id.copyWith(fontSize: 15)),
      const SizedBox(height: 4),
      Text(
        '${HistoryTimeline.clock(d.firstUtc)}–${HistoryTimeline.clock(d.lastUtc)} · ${HistoryTimeline.duration(d.durS)}'
        ' · ${d.maxH == null ? 'height unknown' : 'max ${d.maxH!.round()} m'}',
        style: OrecchinoType.label,
      ),
      Text(where, style: OrecchinoType.caption),
      if (words.isNotEmpty) ...[
        const SizedBox(height: 8),
        Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final w in words) Tag(w, color: _wordColor(w), filled: w != 'LIVE')]),
      ],
    ]);
  }
}

Color _wordColor(String w) => switch (w) {
      'LIVE' => OrecchinoColors.aqua,
      'EMERGENCY REPORTED' || 'ID SIGNATURE INVALID' => OrecchinoColors.warning,
      'IN TFR' => OrecchinoColors.caution,
      _ => OrecchinoColors.inkMuted,
    };

class _RecordCard extends StatelessWidget {
  final DetectionEntry record;
  final bool selected;
  final VoidCallback onTap;

  const _RecordCard({required this.record, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final d = record;
    final words = recordWords(d);
    final alert = recordAlert(d);
    final color = d.emerg ? OrecchinoColors.warning : (alert ? OrecchinoColors.caution : OrecchinoColors.aqua);
    final time = d.lastUtc == 0
        ? 'no clock'
        : '${HistoryTimeline.clock(d.firstUtc > 0 ? d.firstUtc : d.lastUtc)}–${HistoryTimeline.clock(d.lastUtc)}';
    final detail = [
      d.seq == null ? 'still in range' : 'record ${d.seq}',
      HistoryTimeline.duration(d.durS),
      if (d.peakRssi != null) 'peak ${d.peakRssi}\u00a0dBm',
    ];
    final label = [
      d.uasId ?? d.mac,
      ...words,
      time,
      ...detail,
      d.maxH != null ? 'max ${d.maxH!.round()} m' : 'height unknown',
    ].join(', ');
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: AnimatedContainer(
        duration: Motion.of(context, Motion.base),
        curve: Motion.standard,
        decoration: BoxDecoration(
          color: selected
              ? color.withValues(alpha: 0.10)
              : OrecchinoColors.glassOver(OrecchinoColors.void0).withValues(alpha: 0.75),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: selected ? color.withValues(alpha: 0.7) : OrecchinoColors.glassEdge),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ContactGlyph(aircraft: false, color: color, size: 34),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(d.uasId ?? d.mac, style: OrecchinoType.id.copyWith(fontSize: 14, fontWeight: FontWeight.w600)),
                  if (words.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Wrap(spacing: 6, runSpacing: 4, children: [
                      for (final w in words) Tag(w, color: _wordColor(w), filled: w != 'LIVE'),
                    ]),
                  ],
                  const SizedBox(height: 5),
                  Text(detail.join(' · '), style: OrecchinoType.caption),
                ]),
              ),
              const SizedBox(width: 10),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(time,
                    style: OrecchinoType.label.copyWith(color: OrecchinoColors.ink, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(d.maxH != null ? 'max ${d.maxH!.round()} m' : 'height unknown', style: OrecchinoType.caption),
                if (d.peakRssi != null) ...[
                  const SizedBox(height: 6),
                  SignalBars(level: SignalBars.fromRssi(d.peakRssi), color: color, height: 12),
                ],
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}
