// live_view.dart — Heading-up tactical live radar and contact list
//
// Every mark on the radar has a screen-reader node that reads the same words
// as its list row, and is a 44 pt tap target. Alerts are words, never colour
// alone. Distances in m / km; missing data is blank, never zero.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../app/app_controller.dart';
import '../../core/alerts/alert_policy.dart';
import '../../core/geo.dart';
import '../../core/live/contact_tracker.dart';
import '../../core/traffic/traffic_rules.dart';
import '../../ui/theme.dart';
import '../../ui/traffic_widgets.dart';
import 'live_radar_painter.dart';

class LiveContactItem {
  final String id;
  final String label;
  final String? sublabel;
  final double? distanceM; // from the phone; null when unknown
  final double? bearingDeg;
  final double? heightM;
  final String? heightRef; // 'above T/O' | 'AGL' | 'ft' (aircraft) | null
  final double? speedMps;
  final double? trackDeg;
  final bool isAircraft;
  final bool? closing; // null: unknown
  final double? rangeRateMps;
  final double ageSeconds;
  final bool stale;
  final List<String> alertWords;
  final TrafficLevel alertLevel;
  final TrafficAlert? alert; // the most urgent traffic alert naming it
  final TrafficAircraft? aircraft;
  final List<(double, double)> ghost;

  const LiveContactItem({
    required this.id,
    required this.label,
    this.sublabel,
    this.distanceM,
    this.bearingDeg,
    this.heightM,
    this.heightRef,
    this.speedMps,
    this.trackDeg,
    required this.isAircraft,
    this.closing,
    this.rangeRateMps,
    required this.ageSeconds,
    this.stale = false,
    this.alertWords = const [],
    this.alertLevel = TrafficLevel.none,
    this.alert,
    this.aircraft,
    this.ghost = const [],
  });

  bool get isClosing => closing == true;

  /// '350 m', or 'range unknown'.
  String get rangeText => distanceM == null ? 'range unknown' : Geo.rangeText(distanceM!);

  /// 'closing 4.2 m/s', 'opening', or null when unknown.
  String? get trendText {
    if (closing == true) return 'closing ${rangeRateMps!.abs().toStringAsFixed(1)} m/s';
    if (closing == false) return 'opening';
    return null;
  }

  String? get heightText {
    if (heightM == null) return null;
    if (isAircraft) return '${_thousands(heightM!.round())} ft';
    return '${heightM!.round()} m${heightRef == null ? '' : ' $heightRef'}';
  }

  /// What a screen reader says for the mark and the row (the same words).
  String semantics({double? headingDeg}) {
    final parts = <String>[
      isAircraft ? 'Aircraft $label' : 'Drone $label',
      ...alertWords,
      if (alert != null) alert!.text,
      rangeText,
      if (bearingDeg != null)
        headingDeg != null ? Geo.clockWords(bearingDeg!, headingDeg) : 'bearing ${bearingDeg!.round()} degrees',
      if (heightText != null) heightText!,
      if (trendText != null) trendText!,
      stale ? 'stale, heard ${ageSeconds.round()} seconds ago' : 'heard ${ageSeconds.round()} seconds ago',
    ];
    return parts.join(', ');
  }
}

String _thousands(int v) {
  final s = v.abs().toString();
  final b = StringBuffer(v < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

/// Live items for the screens: drones from the tracker, aircraft from the
/// ADS-B set, with their alerts.
List<LiveContactItem> buildLiveItems(AppController app) {
  final now = app.nowMs();
  final o = app.observer;
  final result = app.traffic.result;
  final items = <LiveContactItem>[];

  TrafficAlert? droneAlert(String key) {
    for (final a in result.alerts) {
      if (a.droneId == key) return a;
    }
    return null;
  }

  for (final Contact c in app.tracker.contacts) {
    final words = <String>[
      if (c.emergency) 'EMERGENCY REPORTED',
      if (c.isAuthInvalid) 'ID SIGNATURE INVALID',
      if (c.authState == 'test_key') 'TEST KEY',
    ];
    final ta = droneAlert(c.key);
    final level = c.emergency
        ? TrafficLevel.warning
        : (ta?.level ?? (c.isAuthInvalid ? TrafficLevel.caution : TrafficLevel.none));
    items.add(LiveContactItem(
      id: c.key,
      label: TrafficRules.droneLabel(c.label),
      sublabel: c.sources.map((s) => s.toUpperCase()).join('+'),
      distanceM: c.rangeM,
      bearingDeg: c.bearingDeg,
      heightM: c.heightM,
      heightRef: c.heightRefShort,
      speedMps: c.speedMps,
      trackDeg: c.headingDeg,
      isAircraft: false,
      closing: c.closing,
      rangeRateMps: c.rangeRateMps,
      ageSeconds: c.ageS(now),
      stale: ContactTracker.isStale(c, now),
      alertWords: words,
      alertLevel: level,
      alert: ta,
    ));
  }

  for (final a in app.traffic.aircraft) {
    final age = a.ageS(now);
    if (age > TrafficRules.presentS) continue;
    final al = result.alertForHex(a.hex);
    double? dist, brg;
    final ghost = <(double, double)>[];
    if (o != null) {
      dist = Geo.distanceM(o.lat, o.lon, a.lat, a.lon);
      brg = Geo.bearingDeg(o.lat, o.lon, a.lat, a.lon);
      if (a.gsMps != null && a.trackDeg != null) {
        for (final t in const [15, 30, 45, 60]) {
          final d = a.gsMps! * t;
          final r = a.trackDeg! * math.pi / 180;
          final lat = a.lat + d * math.cos(r) / 111320.0;
          final lon = a.lon + d * math.sin(r) / (111320.0 * math.cos(a.lat * math.pi / 180));
          ghost.add((Geo.distanceM(o.lat, o.lon, lat, lon), Geo.bearingDeg(o.lat, o.lon, lat, lon)));
        }
      }
    }
    final ft = a.altBaroM ?? a.altGeomM;
    items.add(LiveContactItem(
      id: 'ac:${a.hex}',
      label: a.name,
      sublabel: a.type.isEmpty ? 'ADS-B' : 'ADS-B ${a.type}',
      distanceM: dist,
      bearingDeg: brg,
      heightM: ft == null ? null : ft / TrafficRules.ftToM,
      heightRef: 'ft',
      speedMps: a.gsMps,
      trackDeg: a.trackDeg,
      isAircraft: true,
      ageSeconds: age,
      stale: age >= TrafficRules.freshS,
      alertWords: [if (a.squawk == 7700 || a.squawk == 7600 || a.squawk == 7500 || a.emergency) 'EMERGENCY SQUAWK'],
      alertLevel: al?.level ?? TrafficLevel.none,
      alert: al,
      aircraft: a,
      ghost: ghost,
    ));
  }
  return items;
}

class LiveView extends StatefulWidget {
  final AppController app;

  const LiveView({super.key, required this.app});

  @override
  State<LiveView> createState() => _LiveViewState();
}

class _LiveViewState extends State<LiveView> {
  double _rangeM = 3000.0;
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    widget.app.showRequest.addListener(_onShow);
    _selectedId = _takeShowRequest() ?? _selectedId;
  }

  /// A notification's Show: the contact to select ('ac:<hex>' or a drone).
  String? _takeShowRequest() {
    final v = widget.app.showRequest.value;
    if (v == null) return null;
    widget.app.showRequest.value = null;
    return RegExp(r'^[0-9a-f]{6}$').hasMatch(v) ? 'ac:$v' : v;
  }

  @override
  void dispose() {
    widget.app.showRequest.removeListener(_onShow);
    super.dispose();
  }

  void _onShow() {
    final id = _takeShowRequest();
    if (id != null) setState(() => _selectedId = id);
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final contacts = buildLiveItems(app);
    final heading = app.headingDeg;
    final result = app.traffic.result;
    final selected = contacts.where((c) => c.id == _selectedId).firstOrNull;
    final topAlert = result.alerts.isEmpty ? null : result.alerts.first;
    final topAircraft = topAlert == null ? null : app.traffic.byHex(topAlert.hex);
    final o = app.observer;
    final droneAlert = contacts.where((c) => !c.isAircraft && c.alertWords.isNotEmpty && !c.stale).firstOrNull;

    final bridges = <RadarBridge>[
      for (final a in result.alerts)
        if (a.kind.isPair && a.droneId.isNotEmpty)
          RadarBridge(droneId: a.droneId, aircraftId: 'ac:${a.hex}', alert: a),
    ];
    final radarContacts = [
      for (final c in contacts)
        if (c.distanceM != null && c.bearingDeg != null)
          RadarContact(
            id: c.id,
            label: c.label,
            distanceM: c.distanceM!,
            bearingDeg: c.bearingDeg!,
            trackDeg: c.trackDeg,
            isAircraft: c.isAircraft,
            stale: c.stale,
            alertLevel: c.alertLevel,
            ghost: c.ghost,
          )
    ];
    final notices = <String>[
      if (app.isSimulated) 'SIMULATED detector and position',
      if (!app.isSimulated && app.location.problem != null) app.location.problem!,
      if (heading == null) 'No compass: north up',
      if (app.settings.adsb) app.adsbError ?? result.summary,
    ];

    // One scrolling column: at large text sizes everything stays reachable
    // instead of being squeezed or clipped.
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(builder: (context, box) {
          final side = math.max(160.0, math.min(box.maxWidth - 16, box.maxHeight * 0.5));
          final size = Size(side, side);
          final geo = RadarGeometry(size, heading ?? 0, _rangeM);
          final byId = {for (final c in contacts) c.id: c};
          return ListView(
            children: [
              if (topAlert != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
                  child: TrafficAlertBanner(
                    alert: topAlert,
                    extra: AlertWords.clockFromPhone(topAircraft, o?.lat, o?.lon, heading),
                    onTap: () => setState(() => _selectedId = 'ac:${topAlert.hex}'),
                  ),
                )
              else if (droneAlert != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
                  child: _DroneAlertBanner(item: droneAlert, onTap: () => setState(() => _selectedId = droneAlert.id)),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  runSpacing: 6,
                  spacing: 12,
                  children: [
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.explore, size: 16, color: OrecchinoTheme.accent),
                      const SizedBox(width: 6),
                      Text(
                        heading == null ? 'NORTH UP' : 'HDG ${heading.round()}°',
                        style: const TextStyle(color: OrecchinoTheme.text, fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                    ]),
                    Wrap(spacing: 6, children: [
                      _rangeButton(1000, '1 km'),
                      _rangeButton(3000, '3 km'),
                      _rangeButton(5000, '5 km'),
                    ]),
                  ],
                ),
              ),
              for (final n in notices)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 1),
                  child: Text(n, style: const TextStyle(fontSize: 12, color: OrecchinoTheme.muted)),
                ),
              const SizedBox(height: 6),
              Center(
                child: SizedBox.fromSize(
                  size: size,
                  child: Stack(clipBehavior: Clip.none, children: [
                    Semantics(
                      label: 'Radar, ${heading == null ? 'north up' : 'heading up'}, '
                          '${Geo.rangeText(_rangeM)} range, ${radarContacts.length} marks',
                      child: CustomPaint(
                        size: size,
                        painter: LiveRadarPainter(
                          headingDeg: heading ?? 0,
                          maxRangeM: _rangeM,
                          contacts: radarContacts,
                          bridges: bridges,
                          selectedId: _selectedId,
                        ),
                      ),
                    ),
                    for (final b in bridges) ..._bridgeLabel(geo, b, byId),
                    // One node per mark: screen-reader words and a tap target.
                    for (final rc in radarContacts) ..._markNode(geo, rc, byId[rc.id]!, heading),
                  ]),
                ),
              ),
              if (selected != null)
                selected.isAircraft && selected.aircraft != null
                    ? TrafficDetailCard(
                        aircraft: selected.aircraft!,
                        alert: selected.alert,
                        nowMs: app.nowMs(),
                        onClose: () => setState(() => _selectedId = null),
                      )
                    : _droneCard(selected),
              Container(
                margin: const EdgeInsets.only(top: 6),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                color: OrecchinoTheme.surfaceHigh,
                child: Row(
                  children: [
                    Expanded(
                      child: Text('CONTACTS (${contacts.length})',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: OrecchinoTheme.muted)),
                    ),
                    const Flexible(
                      child: Text('RANGE / BRG',
                          textAlign: TextAlign.end, style: TextStyle(fontSize: 12, color: OrecchinoTheme.muted)),
                    ),
                  ],
                ),
              ),
              if (contacts.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: Text(
                      app.detectorReady ? 'No drone heard yet' : 'No detector connected',
                      style: const TextStyle(color: OrecchinoTheme.muted),
                    ),
                  ),
                )
              else
                for (final c in contacts) ...[
                  _row(c, heading),
                  const Divider(height: 1, color: OrecchinoTheme.border),
                ],
            ],
          );
        }),
      ),
    );
  }

  List<Widget> _markNode(RadarGeometry geo, RadarContact rc, LiveContactItem item, double? heading) {
    final p = geo.point(rc.distanceM, rc.bearingDeg);
    if (p == null) return const [];
    return [
      Positioned(
        left: p.dx - 22,
        top: p.dy - 22,
        width: 44,
        height: 44,
        child: Semantics(
          button: true,
          selected: _selectedId == rc.id,
          label: item.semantics(headingDeg: heading),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _selectedId = rc.id),
          ),
        ),
      ),
    ];
  }

  List<Widget> _bridgeLabel(RadarGeometry geo, RadarBridge b, Map<String, LiveContactItem> byId) {
    final d = byId[b.droneId], a = byId[b.aircraftId];
    if (d?.distanceM == null || a?.distanceM == null) return const [];
    final p1 = geo.point(d!.distanceM!, d.bearingDeg!), p2 = geo.point(a!.distanceM!, a.bearingDeg!);
    if (p1 == null || p2 == null) return const [];
    final mid = (p1 + p2) / 2;
    // A label on the graphic: centred on the bridge, as wide as it needs, its
    // text allowed to grow a little with the system size (the rows and the
    // screen reader carry the same numbers at full size).
    return [
      Positioned(
        left: mid.dx,
        top: mid.dy,
        child: FractionalTranslation(
          translation: const Offset(-0.5, -0.5),
          child: ExcludeSemantics(
            child: MediaQuery.withClampedTextScaling(
              maxScaleFactor: 1.3,
              child: SeparationBridgeBadge(alert: b.alert),
            ),
          ),
        ),
      ),
    ];
  }

  Widget _row(LiveContactItem c, double? heading) {
    final isSelected = c.id == _selectedId;
    final color = trafficColor(c.alertLevel == TrafficLevel.none ? null : c.alertLevel);
    final words = [...c.alertWords, if (c.alert != null) c.alert!.text];
    final second = [
      if (c.heightText != null) c.heightText!,
      if (c.trendText != null) c.trendText!,
      c.stale ? 'STALE ${c.ageSeconds.round()} s' : 'heard ${c.ageSeconds.round()} s ago',
    ].join(' · ');
    return MergeSemantics(
      child: Semantics(
        label: c.semantics(headingDeg: heading),
        excludeSemantics: true,
        button: true,
        selected: isSelected,
        // A plain row rather than a ListTile: ListTile fixes the trailing
        // slot's height, which clips at large text sizes.
        child: InkWell(
          onTap: () => setState(() => _selectedId = c.id),
          child: Container(
            color: isSelected ? OrecchinoTheme.surfaceHigh : null,
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(
                  c.isAircraft ? Icons.flight : Icons.circle,
                  size: 18,
                  color: c.alertLevel == TrafficLevel.none
                      ? (c.isAircraft ? OrecchinoTheme.muted : OrecchinoTheme.accent)
                      : color,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(c.label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                          if (c.sublabel != null && c.sublabel!.isNotEmpty)
                            Text(c.sublabel!, style: const TextStyle(fontSize: 12, color: OrecchinoTheme.muted)),
                          for (final w in words)
                            Text(w, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color)),
                        ],
                      ),
                      Text(
                        second,
                        style: TextStyle(fontSize: 12, color: c.isClosing ? OrecchinoTheme.amber : OrecchinoTheme.muted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(c.rangeText, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    if (c.bearingDeg != null)
                      Text('${c.bearingDeg!.round()}°', style: const TextStyle(fontSize: 12, color: OrecchinoTheme.muted)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _rangeButton(double range, String label) {
    final active = _rangeM == range;
    return Semantics(
      button: true,
      selected: active,
      label: '$label range',
      excludeSemantics: true,
      child: InkWell(
        onTap: () => setState(() => _rangeM = range),
        child: Container(
          constraints: const BoxConstraints(minHeight: 32, minWidth: 44),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: active ? OrecchinoTheme.accent.withValues(alpha: 0.2) : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: active ? OrecchinoTheme.accent : OrecchinoTheme.subtle),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: active ? OrecchinoTheme.accent : OrecchinoTheme.muted,
            ),
          ),
        ),
      ),
    );
  }

  Widget _droneCard(LiveContactItem c) {
    final lines = <String>[
      ...c.alertWords,
      if (c.alert != null) c.alert!.text,
      'Range ${c.rangeText}${c.bearingDeg == null ? '' : ' · bearing ${c.bearingDeg!.round()}°'}',
      'Height ${c.heightText ?? 'unknown'}',
      if (c.speedMps != null) 'Speed ${c.speedMps!.toStringAsFixed(1)} m/s',
      if (c.trendText != null) c.trendText!,
      c.stale ? 'Stale: heard ${c.ageSeconds.round()} s ago' : 'Heard ${c.ageSeconds.round()} s ago',
    ];
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: OrecchinoTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: OrecchinoTheme.accent, width: 1.5),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(c.label, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close, size: 20),
                onPressed: () => setState(() => _selectedId = null),
              ),
            ],
          ),
          for (final l in lines) Text(l, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }
}

class _DroneAlertBanner extends StatelessWidget {
  final LiveContactItem item;
  final VoidCallback onTap;
  const _DroneAlertBanner({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = item.alertWords.contains('EMERGENCY REPORTED') ? OrecchinoTheme.danger : OrecchinoTheme.amber;
    return Semantics(
      liveRegion: true,
      button: true,
      label: '${item.alertWords.join(', ')}, drone ${item.label}, ${item.rangeText}',
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
          child: Row(children: [
            Icon(Icons.warning_amber_rounded, color: color, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${item.alertWords.join(' · ')}\n${item.label} · ${item.rangeText}',
                style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 13),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
