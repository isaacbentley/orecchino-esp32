// live_view.dart — "the sky is the interface": a full-bleed 3D sky of every
// contact on its height stem, glass controls floating over it, the alert
// capsule at the top and the contacts in a sheet at the bottom.
//
// Heading-up from the compass (north-up, and said so, without one). Drag to
// rotate and tilt the view, pinch for range (1 / 3 / 5 km), double-tap to
// reset; the 3D / 2D button lays the sky flat into a top-down radar. Every
// mark has a screen-reader node that reads the same words as its card, and
// is a 44 pt tap target. Alerts are words, never colour alone.
//
// Wide screens (landscape, tablets) put the contacts in a side panel with
// the view controls on top, and the sky fills the rest. The compass plugin
// reports where the top of the screen points in any orientation, so
// heading-up holds when the phone is turned.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';

import '../../app/app_controller.dart';
import '../../core/alerts/alert_policy.dart';
import '../../core/geo.dart';
import '../../core/traffic/traffic_rules.dart';
import '../../ui/glass.dart';
import '../../ui/measure_height.dart';
import '../../ui/theme/theme.dart';
import '../../ui/traffic_widgets.dart';
import 'alert_capsule.dart';
import 'contact_sheet.dart';
import 'live_items.dart';
import 'sky_painter.dart';
import 'sky_projection.dart';
import 'sky_scene.dart';

export 'live_items.dart';

class LiveView extends StatefulWidget {
  final AppController app;

  const LiveView({super.key, required this.app});

  @override
  State<LiveView> createState() => _LiveViewState();
}

class _LiveViewState extends State<LiveView> with TickerProviderStateMixin {
  static const _ranges = [1000.0, 3000.0, 5000.0];
  static const _snapSizes = [0.5];

  double _rangeM = 3000.0;
  bool _is3D = true;
  double _userYaw = 0;
  String? _selectedId;

  // The camera tilt; only the sky listens to it (an AnimatedBuilder), so a
  // tilt spring does not rebuild the whole screen.
  late final AnimationController _tilt = AnimationController.unbounded(vsync: this, value: SkyCamera.defaultTiltDeg);
  final ScrollController _panelScroll = ScrollController();

  // Double-tap to reset, seen by a Listener (outside the gesture arena) so
  // a tap on a mark is not held back waiting to see if it is a double tap.
  Offset? _downAt;
  int _downMs = 0;
  double _moved = 0;
  int _lastTapMs = 0;
  Offset? _lastTapAt;
  late final Ticker _ticker = createTicker(_onTick);
  final ValueNotifier<double> _clock = ValueNotifier<double>(0);
  final DraggableScrollableController _sheet = DraggableScrollableController();

  double _pinchBase = 1;
  double? _headerH;
  double? _peekH;

  double _sheetSize = 0;

  @override
  void initState() {
    super.initState();
    // The sky re-fits above the sheet as it is pulled up.
    _sheet.addListener(_onSheet);
    widget.app.showRequest.addListener(_onShow);
    _selectedId = _takeShowRequest() ?? _selectedId;
    // The cards' sparklines: sampled as the app updates, not while building.
    widget.app.addListener(_recordHistory);
    _recordHistory();
  }

  void _recordHistory() {
    final app = widget.app;
    ContactHistory.of(app).record(buildLiveItems(app), app.nowMs());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = Motion.reduced(context);
    if (!reduced && !_ticker.isActive) _ticker.start();
    if (reduced && _ticker.isActive) _ticker.stop();
  }

  void _onSheet() {
    if (!mounted || !_sheet.isAttached || (_sheet.size - _sheetSize).abs() <= 0.004) return;
    // The sheet can report a new size while the tree is building (when its
    // extent is replaced); re-fit after that frame instead of during it.
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _onSheet());
      return;
    }
    setState(() => _sheetSize = _sheet.size);
  }

  void _onTick(Duration elapsed) => _clock.value = elapsed.inMicroseconds / 1e6;

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
    widget.app.removeListener(_recordHistory);
    _panelScroll.dispose();
    _tilt.dispose();
    _ticker.dispose();
    _clock.dispose();
    _sheet.dispose();
    super.dispose();
  }

  void _onShow() {
    final id = _takeShowRequest();
    if (id != null) _select(id);
  }

  void _select(String? id, {bool openSheet = true}) {
    setState(() => _selectedId = id);
    if (openSheet && id != null && _sheet.isAttached && _sheet.size < 0.45) {
      // animateTo needs a non-zero duration: with reduce motion, jump.
      if (Motion.reduced(context)) {
        _sheet.jumpTo(0.5);
      } else {
        _sheet.animateTo(0.5, duration: Motion.morph, curve: Motion.emphasized).ignore();
      }
    }
    if (id != null && _panelScroll.hasClients && _panelScroll.offset > 0) {
      // The panel shows the selected contact's card at its top.
      if (Motion.reduced(context)) {
        _panelScroll.jumpTo(0);
      } else {
        _panelScroll.animateTo(0, duration: Motion.morph, curve: Motion.emphasized).ignore();
      }
    }
  }

  void _toggleSheet() {
    if (!_sheet.isAttached) return;
    final open = _sheet.size > 0.4;
    final target = open ? _peekFraction : 0.5;
    if (Motion.reduced(context)) {
      _sheet.jumpTo(target);
    } else {
      _sheet.animateTo(target, duration: Motion.morph, curve: Motion.emphasized).ignore();
    }
  }

  double _peekFraction = 0.2;

  void _tiltTo(double deg) {
    if (Motion.reduced(context)) {
      _tilt.value = deg;
    } else {
      _tilt.animateWith(SpringSimulation(Motion.softSpring, _tilt.value, deg, 0));
    }
  }

  void _setView(bool is3D) {
    setState(() => _is3D = is3D);
    _tiltTo(is3D ? SkyCamera.defaultTiltDeg : 0);
  }

  void _resetView() {
    setState(() {
      _userYaw = 0;
      _rangeM = 3000;
    });
    _tiltTo(_is3D ? SkyCamera.defaultTiltDeg : 0);
  }

  void _stepRange(int dir) {
    final i = _ranges.indexOf(_rangeM);
    final j = (i + dir).clamp(0, _ranges.length - 1);
    if (j != i) setState(() => _rangeM = _ranges[j]);
  }

  void _onScaleStart(ScaleStartDetails d) {
    _pinchBase = 1;
    _tilt.stop();
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (d.pointerCount >= 2) {
      final rel = d.scale / _pinchBase;
      if (rel > 1.3) {
        _stepRange(-1); // spread: closer in
        _pinchBase = d.scale;
      } else if (rel < 0.77) {
        _stepRange(1);
        _pinchBase = d.scale;
      }
      return;
    }
    final delta = d.focalPointDelta;
    final t = (_tilt.value - delta.dy * 0.3).clamp(0.0, SkyCamera.maxTiltDeg);
    _tilt.value = t; // the sky's AnimatedBuilder redraws
    setState(() {
      _userYaw = (_userYaw - delta.dx * 0.35) % 360;
      _is3D = t > 4;
    });
  }

  void _pointerDown(PointerDownEvent e) {
    _downAt = e.localPosition;
    _downMs = e.timeStamp.inMilliseconds;
    _moved = 0;
  }

  void _pointerMove(PointerMoveEvent e) => _moved += e.delta.distance;

  void _pointerUp(PointerUpEvent e) {
    final at = _downAt;
    if (at == null) return;
    final ms = e.timeStamp.inMilliseconds;
    if (_moved > 18 || ms - _downMs > 250) return; // a drag or a hold
    final last = _lastTapAt;
    if (last != null && ms - _lastTapMs < 300 && (last - at).distance < 40) {
      _lastTapAt = null;
      _resetView();
    } else {
      _lastTapAt = at;
      _lastTapMs = ms;
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final now = app.nowMs();
    final contacts = buildLiveItems(app);
    final history = ContactHistory.of(app);
    final heading = app.headingDeg;
    final result = app.traffic.result;
    final topAlert = result.alerts.isEmpty ? null : result.alerts.first;
    final topAircraft = topAlert == null ? null : app.traffic.byHex(topAlert.hex);
    final o = app.observer;
    final droneAlert = contacts.where((c) => !c.isAircraft && c.alertWords.isNotEmpty && !c.stale).firstOrNull;
    final byId = {for (final c in contacts) c.id: c};
    final selected = byId[_selectedId];

    final bridges = <SkyBridge>[
      for (final a in result.alerts)
        if (a.kind.isPair && a.droneId.isNotEmpty) SkyBridge(droneId: a.droneId, aircraftId: 'ac:${a.hex}', alert: a),
    ];
    final marks = <SkyContact>[
      for (final c in contacts)
        if (c.distanceM != null && c.bearingDeg != null)
          SkyContact(
            id: c.id,
            label: c.label,
            heightLabel: c.heightText == null ? null : (c.isAircraft ? c.heightText : '${c.heightM!.round()} m'),
            distanceM: c.distanceM!,
            bearingDeg: c.bearingDeg!,
            heightM: math.max(0, c.heightMetres ?? 0),
            heightKnown: c.heightMetres != null,
            trackDeg: c.trackDeg,
            isAircraft: c.isAircraft,
            stale: c.stale,
            level: c.alertLevel,
            alerting: c.alerting && !c.stale,
            ghost: c.ghost,
          ),
    ];
    final inRange = marks.where((m) => m.distanceM <= _rangeM).length;
    final beyond = marks.length - inRange;
    final notices = <(String, Color)>[
      if (app.isSimulated) ('SIMULATED detector and position', OrecchinoColors.caution),
      if (!app.isSimulated && app.location.problem != null) (app.location.problem!, OrecchinoColors.caution),
      if (app.settings.adsb && app.adsbError != null) (app.adsbError!, OrecchinoColors.caution),
    ];
    final ageS = result.dataAgeS;
    final idleDetail = app.settings.adsb && result.haveData && ageS != null ? TrafficRules.ageWords(ageS) : null;
    final idleText = contacts.isEmpty
        ? (app.detectorReady ? 'Listening · no drone heard yet' : 'No detector connected')
        : contactCounts(contacts);

    final Widget? detail = selected == null
        ? null
        : selected.isAircraft && selected.aircraft != null
            ? TrafficDetailCard(
                aircraft: selected.aircraft!,
                alert: selected.alert,
                nowMs: now,
                onClose: () => _select(null),
              )
            : DroneDetailCard(
                item: selected,
                headingDeg: heading,
                series: history.series(selected.id),
                onClose: () => _select(null),
              );

    final mq = MediaQuery.of(context);
    final ts = mq.textScaler.scale(1);
    final pad = mq.padding;

    Widget capsule() => AlertCapsule(
          traffic: topAlert,
          trafficAircraft: topAircraft,
          trafficExtra: AlertWords.clockFromPhone(topAircraft, o?.lat, o?.lon, heading),
          droneAlert: droneAlert,
          idleText: idleText,
          idleDetail: idleDetail,
          nowMs: now,
          // The capsule opens its own card: mark the contact on the sky, but
          // leave the sheet where it is.
          onSelect: (id) => _select(id, openSheet: false),
        );

    Widget status({bool center = false}) => Wrap(
          alignment: center ? WrapAlignment.center : WrapAlignment.start,
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _headingChip(heading),
            for (final (text, color) in notices)
              Glass(
                borderRadius: BorderRadius.circular(999),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                child: Text(text, style: OrecchinoType.caption.copyWith(color: color, fontWeight: FontWeight.w600)),
              ),
          ],
        );

    Widget contactsView({required ScrollController scroll, required bool panel, required double bottomInset}) =>
        ContactSheet(
          scrollController: scroll,
          contacts: contacts,
          headingDeg: heading,
          selectedId: _selectedId,
          onSelect: _select,
          onToggle: _toggleSheet,
          detail: detail,
          emptyText: app.detectorReady ? 'No drone heard yet' : 'No detector connected',
          trafficSummary: app.settings.adsb ? result.summary : null,
          history: history,
          bottomInset: bottomInset,
          panel: panel,
          // Wide: the panel carries the view controls and the status, so the
          // sky keeps the whole height beside it.
          header: panel
              ? Column(mainAxisSize: MainAxisSize.min, children: [
                  _controls(),
                  const SizedBox(height: 8),
                  status(center: true),
                ])
              : null,
          onPeekHeight: panel
              ? null
              : (v) {
                  // Never more than the large-text peek: the rest is one drag away.
                  final cap = 136 + 40 * (ts - 1).clamp(0.0, 1.0) + 24;
                  final next = v.clamp(0.0, cap) + 6;
                  if (mounted && (next - (_peekH ?? -1)).abs() > 1) setState(() => _peekH = next);
                },
        );

    Widget sky(Rect viewport, Size size) => Listener(
          onPointerDown: _pointerDown,
          onPointerMove: _pointerMove,
          onPointerUp: _pointerUp,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            child: AnimatedBuilder(
              animation: _tilt,
              builder: (context, _) {
                final camera = SkyCamera.fit(
                  size: size,
                  viewport: viewport,
                  tiltDeg: _tilt.value.clamp(0.0, SkyCamera.maxTiltDeg),
                  yawDeg: (heading ?? 0) + _userYaw,
                  rangeM: _rangeM,
                );
                final rotated = _userYaw.abs() > 0.5 && (360 - _userYaw).abs() > 0.5;
                return SkyScene(
                  camera: camera,
                  marks: marks,
                  bridges: bridges,
                  items: byId,
                  selectedId: _selectedId,
                  headingDeg: heading,
                  showFacing: heading != null,
                  clock: _ticker.isActive ? _clock : null,
                  semanticLabel: 'Sky view, ${_is3D ? '3D' : 'flat'}, '
                      '${heading == null ? 'north up' : 'heading up'}${rotated ? ', rotated' : ''}, '
                      '${Geo.rangeText(_rangeM)} range, $inRange marks'
                      '${beyond > 0 ? ', $beyond beyond range' : ''}',
                  onSelect: _select,
                );
              },
            ),
          ),
        );

    return Material(
      type: MaterialType.transparency,
      child: LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth, h = box.maxHeight;
        final headerCap = h * (ts > 1.4 ? 0.44 : 0.62);

        // The header over the sky: the capsule (and, on narrow screens, the
        // controls and status). It scrolls within itself when it outgrows its
        // space; a fade marks the cut edge (an overlay, not a mask: a mask
        // layer would cut the glass off from the sky it blurs).
        Widget header({required double left, required double right, required List<Widget> children}) => Positioned(
              left: left,
              right: right,
              top: 0,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: headerCap),
                child: Stack(clipBehavior: Clip.none, children: [
                  SingleChildScrollView(
                    physics: const ClampingScrollPhysics(),
                    padding: EdgeInsets.fromLTRB(12, pad.top + 8, 12, 16),
                    child: MeasureHeight(
                      onHeight: (v) {
                        final full = v + pad.top + 24;
                        if (mounted && (full - (_headerH ?? -1)).abs() > 1) setState(() => _headerH = full);
                      },
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
                    ),
                  ),
                  if ((_headerH ?? 0) > headerCap + 1)
                    const Positioned(
                      left: 0,
                      right: 0,
                      bottom: -30,
                      height: 86,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Color(0x0004060C), Color(0xD904060C), Color(0x0004060C)],
                              stops: [0, 0.65, 1],
                            ),
                          ),
                        ),
                      ),
                    ),
                ]),
              ),
            );

        if (w >= 700) {
          // Wide: sky on the left, contacts in a side panel on the right.
          final panelW = (w * 0.36).clamp(320.0, 420.0);
          final skyRight = w - pad.right - 12 - panelW - 12;
          final topReserve = math.min(headerCap, _headerH ?? pad.top + 70);
          final viewport =
              Rect.fromLTRB(pad.left, topReserve, skyRight, math.max(topReserve + 150, h - pad.bottom - 12));
          return Stack(children: [
            Positioned.fill(child: sky(viewport, Size(w, h))),
            header(left: pad.left, right: w - skyRight, children: [
              // A readable line length on a tablet, not the full sky width.
              Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 620), child: capsule())),
            ]),
            Positioned(
              right: pad.right + 12,
              top: pad.top + 12,
              bottom: pad.bottom + 12,
              width: panelW,
              child: contactsView(scroll: _panelScroll, panel: true, bottomInset: 0),
            ),
          ]);
        }

        final navInset = pad.bottom;
        final peekPx = navInset + (_peekH ?? 136 + 40 * (ts - 1).clamp(0.0, 1.0));
        _peekFraction = (peekPx / h).clamp(0.12, 0.45);
        // The sky starts below the header as it is actually laid out (it
        // grows with an alert, notices and large text), never under it.
        final topReserve = math.min(headerCap, _headerH ?? pad.top + 150 + (notices.isEmpty ? 0 : 40) * ts);
        final sheetPx = math.max(peekPx, _sheetSize * h);
        final viewport = Rect.fromLTRB(pad.left, topReserve, w - pad.right, math.max(topReserve + 170, h - sheetPx));
        return Stack(children: [
          Positioned.fill(child: sky(viewport, Size(w, h))),
          header(left: pad.left, right: pad.right, children: [
            Center(child: capsule()),
            const SizedBox(height: 10),
            _controls(),
            const SizedBox(height: 8),
            // Status: where the view points, and anything the person should
            // know about the data.
            status(),
          ]),
          Positioned.fill(
            child: DraggableScrollableSheet(
              controller: _sheet,
              initialChildSize: _peekFraction,
              minChildSize: _peekFraction,
              maxChildSize: 0.9,
              snap: true,
              // A constant list: the sheet compares snap sizes by identity and
              // re-snaps whenever they change, which would fight every drag.
              snapSizes: _snapSizes,
              snapAnimationDuration: Motion.reduced(context) ? null : Motion.morph,
              builder: (context, scroll) => contactsView(scroll: scroll, panel: false, bottomInset: navInset),
            ),
          ),
        ]);
      }),
    );
  }

  /// Where the view points, and the reset button: "HDG 042°", or without a
  /// compass "No compass · north up" (no separate notice).
  Widget _headingChip(double? heading) {
    final rotated = _userYaw.abs() > 0.5 && (360 - _userYaw).abs() > 0.5;
    final hdgText = heading == null ? 'No compass · north up' : 'HDG ${heading.round().toString().padLeft(3, '0')}°';
    return GlassButton(
      semanticLabel: '${heading == null ? 'North up, no compass' : 'Heading ${heading.round()} degrees'}'
          '${rotated ? ', view rotated' : ''}, reset view',
      onTap: _resetView,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Transform.rotate(
          angle: -(_userYaw + (heading ?? 0)) * math.pi / 180,
          child: const Icon(Icons.navigation_rounded, size: 16, color: OrecchinoColors.aqua),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(hdgText,
              style: OrecchinoType.label.copyWith(color: OrecchinoColors.ink, fontWeight: FontWeight.w700)),
        ),
      ]),
    );
  }

  /// The view controls, one row: 3D / 2D and the range.
  Widget _controls() {
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: [
        GlassButton(
          semanticLabel: _is3D ? '3D sky view, switch to flat view' : 'Flat top-down view, switch to 3D sky view',
          onTap: () => _setView(!_is3D),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(_is3D ? Icons.view_in_ar_rounded : Icons.radar_rounded, size: 16, color: OrecchinoColors.aqua),
            const SizedBox(width: 6),
            Text(_is3D ? '3D' : '2D',
                style: OrecchinoType.label.copyWith(color: OrecchinoColors.ink, fontWeight: FontWeight.w700)),
          ]),
        ),
        GlassSegmented<double>(
          options: const [
            (1000.0, '1 km', '1 km range'),
            (3000.0, '3 km', '3 km range'),
            (5000.0, '5 km', '5 km range')
          ],
          value: _rangeM,
          onChanged: (v) => setState(() => _rangeM = v),
        ),
      ],
    );
  }
}
