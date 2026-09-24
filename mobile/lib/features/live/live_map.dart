// live_map.dart — the Live screen's Map mode: the same scene on a stylised
// street map. Esri's World Dark Gray Canvas raster tiles (base and labels;
// no key; "Esri, HERE, Garmin, © OpenStreetMap contributors", always on
// screen, opening its full text) by default, or any {z}/{x}/{y} template
// with its own key and attribution (Detectors > Settings > Map tiles; CARTO
// Dark Matter now answers "API KEY REQUIRED" tiles without one), tinted to
// the night-sky palette, over a plain dark grid that is all there is when
// the tiles cannot load (and the map says so). Without your position yet it
// centres on the last one saved, else a drone, and says "Finding your
// position". Tiles are cached on the phone (flutter_map's built-in cache,
// 50 MB cap) so an area seen before still draws offline; nothing is fetched
// in bulk.
//
// On it: you and the range rings of the selected range; each drone a
// glowing mark with its heading and a short trail; its operator a ground
// pin joined to it by a dotted line; and, Remote ID first, an aircraft only
// while an alert names it, with its track ahead and the bridge to its drone.
// Labels keep clear of each other; every mark is a 44 pt target with the
// same words as its card. Drag, pinch and twist; follow me and fit all.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' show LatLng;

import '../../core/geo.dart';
import '../../core/traffic/traffic_rules.dart';
import '../../ui/canvas_text.dart';
import '../../ui/glass.dart';
import '../../ui/theme/theme.dart';
import '../../ui/traffic_widgets.dart';
import 'live_items.dart';
import 'sky_painter.dart';

/// Where the map's tiles come from.
class MapTileSource {
  final String id; // 'esri' | 'custom'
  final String url; // {z}/{x}/{y} (or {z}/{y}/{x}) template, https
  final String? labelsUrl; // a transparent labels layer over it
  final String attribution; // always on screen
  final String detail; // the attribution sheet's words
  final int maxNativeZoom;

  const MapTileSource({
    required this.id,
    required this.url,
    this.labelsUrl,
    required this.attribution,
    required this.detail,
    this.maxNativeZoom = 19,
  });

  /// A template the phone may fetch: https, with {z}, {x} and {y}.
  static bool validTemplate(String u) =>
      u.startsWith('https://') && u.contains('{z}') && u.contains('{x}') && u.contains('{y}');
}

/// Tile sources, provider and cache (tests turn the cache off, or give their
/// own provider: the cache needs the file system, tiles the network).
abstract final class MapTiles {
  static const esriDarkGray = MapTileSource(
    id: 'esri',
    url: 'https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Dark_Gray_Base/MapServer/tile/{z}/{y}/{x}',
    labelsUrl:
        'https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Dark_Gray_Reference/MapServer/tile/{z}/{y}/{x}',
    attribution: 'Esri, HERE, Garmin, © OpenStreetMap contributors',
    detail: 'Basemap: Esri World Dark Gray Canvas (server.arcgisonline.com). Sources: Esri, HERE, Garmin, '
        '© OpenStreetMap contributors (openstreetmap.org/copyright), and the GIS user community.',
    maxNativeZoom: 16,
  );

  /// A template of the person's own (with its key), and its attribution.
  static MapTileSource custom(String url, String attribution) => MapTileSource(
        id: 'custom',
        url: url,
        attribution: attribution.trim().isEmpty ? 'Map tiles: see the provider\'s terms' : attribution.trim(),
        detail: 'Map tiles from ${Uri.tryParse(url)?.host ?? url}. ${attribution.trim()}',
      );

  static const userAgent = 'Orecchino/1.0 (dev.bentley.orecchino.mobile; Remote ID monitor)';
  static const cacheBytes = 50 * 1024 * 1024;
  static bool caching = true;
  static TileProvider Function()? providerOverride;

  /// The night-sky tint: black becomes the app's deep navy, the greys lean
  /// blue-teal.
  static const ColorFilter tint = ColorFilter.matrix(<double>[
    0.62, 0, 0, 0, 4, //
    0, 0.80, 0.05, 0, 9,
    0, 0.05, 1.00, 0, 22,
    0, 0, 0, 1, 0,
  ]);

  /// The Flat tint: the mockups' map, near-black with neutral grey roads
  /// (#0D1418 ground, #1C2A30 streets).
  static const ColorFilter flatTint = ColorFilter.matrix(<double>[
    0.66, 0, 0, 0, 8, //
    0, 0.74, 0.04, 0, 12,
    0, 0.04, 0.80, 0, 14,
    0, 0, 0, 1, 0,
  ]);

  /// The tint of the active look.
  static ColorFilter get currentTint => Look.flat ? flatTint : tint;

  static TileProvider provider() =>
      providerOverride?.call() ??
      NetworkTileProvider(
        // Mutable: the tile layer adds its own entries.
        headers: {'User-Agent': userAgent},
        cachingProvider: caching
            ? BuiltInMapCachingProvider.getOrCreateInstance(maxCacheSize: cacheBytes)
            : const DisabledMapCachingProvider(),
      );
}

/// A zoom at which [rangeM] is about 0.42 of the viewport's shorter side.
double zoomForRange(double rangeM, double lat, Size viewport) {
  final px = math.max(80.0, 0.42 * math.min(viewport.width, viewport.height));
  final mpp = rangeM / px;
  return (math.log(156543.03392 * math.cos(lat * math.pi / 180) / mpp) / math.ln2).clamp(3.0, 19.0);
}

LatLng _dest(double lat, double lon, double brgDeg, double m) {
  final r = brgDeg * math.pi / 180;
  return LatLng(lat + m * math.cos(r) / 111320.0, lon + m * math.sin(r) / (111320.0 * math.cos(lat * math.pi / 180)));
}

class LiveMap extends StatefulWidget {
  final List<LiveContactItem> items;
  final List<SkyBridge> bridges;
  final ContactHistory history;
  final String? selectedId;
  final double? observerLat, observerLon;
  final double? headingDeg;
  final double rangeM;

  /// The part of the screen not under the header and the sheet.
  final Rect viewport;
  final ValueChanged<String> onSelect;

  /// Where the tiles come from.
  final MapTileSource source;

  /// The last position this phone saved, for a centre before a fix.
  final double? fallbackLat, fallbackLon;

  const LiveMap({
    this.source = MapTiles.esriDarkGray,
    this.fallbackLat,
    this.fallbackLon,
    super.key,
    required this.items,
    required this.bridges,
    required this.history,
    required this.selectedId,
    required this.observerLat,
    required this.observerLon,
    required this.headingDeg,
    required this.rangeM,
    required this.viewport,
    required this.onSelect,
  });

  @override
  State<LiveMap> createState() => LiveMapState();
}

class LiveMapState extends State<LiveMap> {
  final MapController _map = MapController();
  late final TileProvider _tiles = MapTiles.provider();
  bool _ready = false;
  bool _follow = true;
  int _errors = 0;
  int _lastErrorMs = 0, _lastOkMs = 0;
  Size _size = Size.zero;

  /// Tiles failed and none has loaded since: the grid is all there is.
  bool get offline => _errors >= 2 && _lastErrorMs > _lastOkMs;

  /// Tiles have drawn (for the tests and the status words).
  bool get tilesShown => _lastOkMs > 0 && !offline;
  bool _hadYou = false;

  LatLng? get _you => widget.observerLat == null || widget.observerLon == null
      ? null
      : LatLng(widget.observerLat!, widget.observerLon!);

  LatLng? get _saved => widget.fallbackLat == null || widget.fallbackLon == null
      ? null
      : LatLng(widget.fallbackLat!, widget.fallbackLon!);

  LatLng? get _firstDrone {
    for (final c in widget.items) {
      if (c.isDrone && c.lat != null && c.lon != null) return LatLng(c.lat!, c.lon!);
    }
    return null;
  }

  /// The centre: you; before a fix, your last saved position, else a drone;
  /// with none of those, the middle of the contiguous US at a country's zoom
  /// (and the map says why).
  LatLng get _home => _you ?? _saved ?? _firstDrone ?? const LatLng(39.5, -98.35);
  bool get _nowhere => _you == null && _saved == null && _firstDrone == null;

  double _zoomFor(LatLng c) => _nowhere ? 3.5 : zoomForRange(widget.rangeM, c.latitude, widget.viewport.size);

  /// What the map says about itself, or null when all is well.
  String? get status {
    if (offline) return 'Map tiles unavailable: showing a plain grid';
    if (_you == null) {
      if (_saved != null) return 'Finding your position… (centred on your last one)';
      if (_firstDrone != null) return 'Finding your position… (centred on a drone)';
      return 'Finding your position…';
    }
    return null;
  }

  Offset get _offset => widget.viewport.center - _size.center(Offset.zero);

  @override
  void didUpdateWidget(LiveMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget;
    if (!_ready) return;
    if (old.rangeM != widget.rangeM || (_follow && old.viewport != widget.viewport)) {
      _followMe();
    } else if (_you != null && !_hadYou) {
      // The first fix: go there at the range's zoom.
      _followMe();
    } else if (_follow && (old.observerLat != widget.observerLat || old.observerLon != widget.observerLon)) {
      _map.move(_home, _map.camera.zoom, offset: _offset);
    }
    if (_you != null) _hadYou = true;
  }

  @override
  void dispose() {
    _map.dispose();
    super.dispose();
  }

  void _followMe() {
    if (!_ready) return;
    setState(() => _follow = true);
    final c = _home;
    _map.move(c, _zoomFor(c), offset: _offset);
  }

  void _fitAll() {
    if (!_ready) return;
    final pts = <LatLng>[
      if (_you != null) _you!,
      for (final c in widget.items)
        if (c.lat != null && c.lon != null) LatLng(c.lat!, c.lon!),
    ];
    if (pts.isEmpty) return;
    setState(() => _follow = false);
    final v = widget.viewport;
    final pad = EdgeInsets.fromLTRB(
        v.left + 48, v.top + 48, _size.width - v.right + 48, math.max(48, _size.height - v.bottom + 48));
    if (pts.length == 1) {
      _map.move(pts.first, 16, offset: _offset);
    } else {
      _map.fitCamera(CameraFit.coordinates(coordinates: pts, padding: pad, maxZoom: 17));
    }
  }

  void _tileError(Object error) {
    final was = offline;
    if (_errors < 3) debugPrint('map tile failed: $error');
    _errors++;
    _lastErrorMs = DateTime.now().millisecondsSinceEpoch;
    if (offline != was) _redraw();
  }

  void _tileOk() {
    final was = offline;
    _lastOkMs = DateTime.now().millisecondsSinceEpoch;
    if (offline != was) _redraw();
  }

  bool _redrawQueued = false;

  /// The offline notice changed: redraw after this frame (tile callbacks
  /// can come while building).
  void _redraw() {
    if (_redrawQueued) return;
    _redrawQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _redrawQueued = false;
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _showAttribution() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: OrecchinoColors.raised,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Semantics(header: true, child: Text('Map attribution', style: OrecchinoType.heading)),
            const SizedBox(height: 10),
            Text(widget.source.detail, style: OrecchinoType.body),
            const SizedBox(height: 8),
            Text('Tiles you have seen are kept on this phone (up to 50 MB) so the map still draws offline.',
                style: OrecchinoType.caption),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final home = _home;
    final src = widget.source;
    final status = this.status;
    return LayoutBuilder(builder: (context, box) {
      _size = box.biggest;
      final v = widget.viewport;
      // Flat: the mockups' rule-coloured rings.
      final ringColor = Look.flat ? OrecchinoColors.line : OrecchinoColors.aqua.withValues(alpha: 0.35);
      return Stack(children: [
        Positioned.fill(
          child: FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: home,
              initialZoom: _nowhere ? 3.5 : zoomForRange(widget.rangeM, home.latitude, v.size),
              backgroundColor: OrecchinoColors.void0,
              minZoom: 3,
              maxZoom: 19,
              interactionOptions: const InteractionOptions(flags: InteractiveFlag.all),
              onMapReady: () {
                _ready = true;
                _hadYou = _you != null;
                _map.move(home, _map.camera.zoom, offset: _offset);
              },
              onPositionChanged: (_, hasGesture) {
                if (hasGesture && _follow) setState(() => _follow = false);
              },
            ),
            children: [
              // The plain grid first: all there is when no tile loads.
              _Grid(center: home),
              ColorFiltered(
                colorFilter: MapTiles.currentTint,
                child: TileLayer(
                  key: ValueKey(src.url),
                  urlTemplate: src.url,
                  userAgentPackageName: 'dev.bentley.orecchino.mobile',
                  tileProvider: _tiles,
                  maxNativeZoom: src.maxNativeZoom,
                  errorTileCallback: (tile, error, stack) => _tileError(error),
                  tileBuilder: (context, child, tile) {
                    if (tile.readyToDisplay && !tile.loadError) _tileOk();
                    return child;
                  },
                ),
              ),
              if (src.labelsUrl != null)
                ColorFiltered(
                  colorFilter: MapTiles.currentTint,
                  child: TileLayer(
                    key: ValueKey(src.labelsUrl),
                    urlTemplate: src.labelsUrl,
                    userAgentPackageName: 'dev.bentley.orecchino.mobile',
                    tileProvider: _tiles,
                    maxNativeZoom: src.maxNativeZoom,
                  ),
                ),
              if (_you != null)
                CircleLayer(circles: [
                  for (final f in ringFractions(widget.rangeM))
                    CircleMarker(
                      point: _you!,
                      radius: widget.rangeM * f,
                      useRadiusInMeter: true,
                      color: Colors.transparent,
                      borderColor: f == 1
                          ? (Look.flat ? OrecchinoColors.lineBright : OrecchinoColors.aqua.withValues(alpha: 0.6))
                          : ringColor,
                      borderStrokeWidth: f == 1 ? 1.6 : 1,
                    ),
                ]),
              _Marks(
                items: widget.items,
                bridges: widget.bridges,
                history: widget.history,
                you: _you,
                headingDeg: widget.headingDeg,
                selectedId: widget.selectedId,
                onSelect: widget.onSelect,
              ),
            ],
          ),
        ),
        // What the map says about itself: tiles unavailable (the marks stay
        // on the grid), or still finding your position.
        if (status != null)
          Positioned(
            left: v.left + 12,
            right: _size.width - v.right + 12,
            top: v.top + 8,
            child: Center(
              child: Semantics(
                liveRegion: true,
                child: Glass(
                  borderRadius: BorderRadius.circular(OrecchinoTheme.pill),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Text(status,
                      style: OrecchinoType.caption.copyWith(color: OrecchinoColors.caution, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
          ),
        // Follow me and fit all, bottom right of the free area, above the
        // attribution line.
        Positioned(
          right: _size.width - v.right + 12,
          bottom: _size.height - v.bottom + 12 + OrecchinoTheme.minTarget,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            GlassButton(
              semanticLabel: _follow ? 'Following your position' : 'Follow your position',
              selected: _follow,
              onTap: _followMe,
              padding: const EdgeInsets.all(10),
              child: Icon(_follow ? Icons.my_location_rounded : Icons.location_searching_rounded,
                  size: 22, color: _follow ? OrecchinoColors.aqua : OrecchinoColors.ink),
            ),
            const SizedBox(height: 8),
            GlassButton(
              semanticLabel: 'Fit every drone on the map',
              onTap: _fitAll,
              padding: const EdgeInsets.all(10),
              child: Icon(Icons.fit_screen_rounded, size: 22, color: OrecchinoColors.ink),
            ),
          ]),
        ),
        // The attribution: always visible, opens its full text.
        Positioned(
          left: v.left + 8,
          bottom: _size.height - v.bottom + 8,
          child: Semantics(
            button: true,
            label: 'Map data ${src.attribution}, show attribution',
            excludeSemantics: true,
            child: GestureDetector(
              onTap: _showAttribution,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: OrecchinoTheme.minTarget),
                child: Align(
                  alignment: Alignment.bottomLeft,
                  widthFactor: 1,
                  heightFactor: 1,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: OrecchinoColors.void0.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(src.attribution,
                        style: OrecchinoType.caption.copyWith(fontSize: 11, color: OrecchinoColors.inkMuted)),
                  ),
                ),
              ),
            ),
          ),
        ),
      ]);
    });
  }
}

/// A plain dark grid around [center] (0.01° steps): what the map is made
/// of when no tile loads, so the marks still have a reference.
class _Grid extends StatelessWidget {
  final LatLng center;
  const _Grid({required this.center});

  @override
  Widget build(BuildContext context) {
    const step = 0.01, n = 40;
    final lat0 = (center.latitude / step).round() * step, lon0 = (center.longitude / step).round() * step;
    final color = OrecchinoColors.line.withValues(alpha: 0.55);
    return PolylineLayer(polylines: [
      for (var i = -n; i <= n; i++) ...[
        Polyline(points: [LatLng(lat0 + i * step, lon0 - n * step), LatLng(lat0 + i * step, lon0 + n * step)],
            color: color, strokeWidth: 0.6),
        Polyline(points: [LatLng(lat0 - n * step, lon0 + i * step), LatLng(lat0 + n * step, lon0 + i * step)],
            color: color, strokeWidth: 0.6),
      ],
    ]);
  }
}

/// The marks, in screen space from the map's camera: drawn by one painter
/// (so their labels can keep clear of each other), with a 44 pt target and
/// its words over each.
class _Marks extends StatelessWidget {
  final List<LiveContactItem> items;
  final List<SkyBridge> bridges;
  final ContactHistory history;
  final LatLng? you;
  final double? headingDeg;
  final String? selectedId;
  final ValueChanged<String> onSelect;

  const _Marks({
    required this.items,
    required this.bridges,
    required this.history,
    required this.you,
    required this.headingDeg,
    required this.selectedId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final cam = MapCamera.of(context);
    final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3);
    Offset at(double lat, double lon) => cam.latLngToScreenOffset(LatLng(lat, lon));
    final marks = <MapMark>[];
    final pos = <String, Offset>{};
    for (final c in items) {
      if (c.lat == null || c.lon == null) continue;
      final p = at(c.lat!, c.lon!);
      pos[c.id] = p;
      // A direction on screen: from here toward 30 m along the true bearing.
      double? screenAngle(double? brg) {
        if (brg == null) return null;
        final q = _dest(c.lat!, c.lon!, brg, 30);
        final d = cam.latLngToScreenOffset(q) - p;
        return math.atan2(d.dy, d.dx);
      }

      final ghost = <Offset>[];
      if (c.isAircraft && c.speedMps != null && c.trackDeg != null) {
        for (final t in const [15, 30, 45, 60]) {
          final q = _dest(c.lat!, c.lon!, c.trackDeg!, c.speedMps! * t);
          ghost.add(cam.latLngToScreenOffset(q));
        }
      }
      marks.add(MapMark(
        item: c,
        at: p,
        angle: screenAngle(c.trackDeg),
        trail: c.isDrone ? [for (final (la, lo) in history.trail(c.id)) at(la, lo)] : const [],
        ghost: ghost,
      ));
    }
    for (final m in marks) {
      final link = m.item.isOperator ? pos[m.item.ofDrone] : null;
      if (link != null) m.linkTo = link;
    }
    final youAt = you == null ? null : cam.latLngToScreenOffset(you!);
    Offset? anchor(SkyBridge b) => b.droneId == SkyBridge.you ? youAt : pos[b.droneId];
    final pairs = <(SkyBridge, Offset, Offset)>[
      for (final b in bridges)
        if (anchor(b) case final a?)
          if (pos[b.aircraftId] case final z?) (b, a, z),
    ];
    return Stack(clipBehavior: Clip.none, children: [
      Positioned.fill(
        child: IgnorePointer(
          child: CustomPaint(
            painter: MapMarksPainter(marks: marks, pairs: pairs, you: youAt, selectedId: selectedId, scaler: scaler),
          ),
        ),
      ),
      for (final (b, a, z) in pairs)
        Positioned(
          left: (a.dx + z.dx) / 2,
          top: (a.dy + z.dy) / 2,
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
      for (final m in marks)
        Positioned(
          left: m.at.dx - 22,
          top: m.at.dy - 22,
          width: 44,
          height: 44,
          child: Semantics(
            button: true,
            selected: selectedId == m.item.id,
            label: m.item.semantics(headingDeg: headingDeg),
            child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => onSelect(m.item.id)),
          ),
        ),
    ]);
  }
}

/// One mark on the map, in screen space.
class MapMark {
  final LiveContactItem item;
  final Offset at;
  final double? angle; // its heading / track on screen, radians
  final List<Offset> trail; // oldest first
  final List<Offset> ghost; // an aircraft's positions ahead
  Offset? linkTo; // an operator's drone

  MapMark({required this.item, required this.at, this.angle, this.trail = const [], this.ghost = const []});

  Color get color {
    final c = item;
    if (c.alertWords.contains('EMERGENCY REPORTED')) return OrecchinoColors.warning;
    final base = OrecchinoColors.level(c.alertLevel,
        none: c.isAircraft ? OrecchinoColors.aircraft : OrecchinoColors.aqua);
    return c.stale ? base.withValues(alpha: 0.45) : base;
  }
}

class MapMarksPainter extends CustomPainter {
  final List<MapMark> marks;
  final List<(SkyBridge, Offset, Offset)> pairs;
  final Offset? you;
  final String? selectedId;
  final TextScaler scaler;

  MapMarksPainter({
    required this.marks,
    required this.pairs,
    required this.you,
    required this.selectedId,
    required this.scaler,
  });

  final List<Rect> _placed = [];

  @override
  void paint(Canvas canvas, Size size) {
    // Trails and links under everything.
    for (final m in marks) {
      if (m.trail.length > 1) {
        for (var i = 1; i < m.trail.length; i++) {
          final k = i / m.trail.length;
          canvas.drawLine(
              m.trail[i - 1],
              m.trail[i],
              Paint()
                ..strokeWidth = 1 + 2 * k
                ..strokeCap = StrokeCap.round
                ..color = m.color.withValues(alpha: 0.10 + 0.45 * k));
        }
        canvas.drawLine(m.trail.last, m.at, Paint()..strokeWidth = 3..color = m.color.withValues(alpha: 0.55));
      }
      if (m.linkTo != null) _dotted(canvas, m.at, m.linkTo!, m.color.withValues(alpha: 0.6));
      if (m.ghost.isNotEmpty) {
        var prev = m.at;
        for (var i = 0; i < m.ghost.length; i++) {
          _dotted(canvas, prev, m.ghost[i], m.color.withValues(alpha: 0.5 - 0.08 * i));
          canvas.drawCircle(m.ghost[i], 2.5, Paint()..color = m.color.withValues(alpha: 0.7 - 0.12 * i));
          prev = m.ghost[i];
        }
      }
    }
    for (final (b, a, z) in pairs) {
      final color = OrecchinoColors.level(b.alert.level, none: OrecchinoColors.caution);
      canvas.drawLine(a, z,
          Paint()
            ..strokeWidth = 10
            ..strokeCap = StrokeCap.round
            ..color = color.withValues(alpha: Look.flat ? 0.28 : 0.16)
            ..maskFilter = Look.flat ? null : const MaskFilter.blur(BlurStyle.normal, 3));
      _dotted(canvas, a, z, color, width: 2, dash: 7, gap: 4);
    }
    if (you != null) {
      canvas.drawCircle(you!, 14, Paint()..color = OrecchinoColors.aqua.withValues(alpha: 0.14));
      canvas.drawCircle(you!, 6, Paint()..color = OrecchinoColors.ink);
      canvas.drawCircle(
          you!,
          6,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = OrecchinoColors.aqua);
    }
    for (final m in marks) {
      if (m.item.isOperator) {
        _pin(canvas, m);
      } else if (m.item.isAircraft) {
        _chevron(canvas, m);
      } else {
        _orb(canvas, m);
      }
      if (m.item.id == selectedId) _reticle(canvas, m.at);
    }
    // Labels: the selected first, then drones and aircraft, then operators.
    _placed
      ..clear()
      ..addAll([for (final m in marks) Rect.fromCircle(center: m.at, radius: 11)])
      ..addAll([if (you != null) Rect.fromCircle(center: you!, radius: 10)])
      ..addAll([for (final (_, a, z) in pairs) Rect.fromCenter(center: (a + z) / 2, width: 120, height: 26)]);
    final order = [...marks]..sort((a, b) {
        int rank(MapMark m) => m.item.id == selectedId ? 0 : (m.item.isOperator ? 2 : 1);
        return rank(a).compareTo(rank(b));
      });
    for (final m in order) {
      _label(canvas, m);
    }
  }

  void _dotted(Canvas canvas, Offset a, Offset b, Color color, {double width = 1.3, double dash = 3, double gap = 5}) {
    final d = b - a;
    final len = d.distance;
    if (len < 2) return;
    final u = d / len;
    final p = Paint()
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..color = color;
    for (var x = 0.0; x < len; x += dash + gap) {
      canvas.drawLine(a + u * x, a + u * math.min(len, x + dash), p);
    }
  }

  void _orb(Canvas canvas, MapMark m) {
    final c = m.color;
    if (!Look.flat) {
      canvas.drawCircle(
          m.at,
          20,
          Paint()
            ..shader = RadialGradient(colors: [c.withValues(alpha: 0.55), c.withValues(alpha: 0)])
                .createShader(Rect.fromCircle(center: m.at, radius: 20)));
    }
    canvas.drawCircle(m.at, 6.5, Paint()..color = c);
    if (!Look.flat) canvas.drawCircle(m.at + const Offset(-2, -2), 2, Paint()..color = OrecchinoColors.ink);
    if (m.angle != null) {
      final dir = Offset(math.cos(m.angle!), math.sin(m.angle!));
      canvas.drawLine(m.at + dir * 9, m.at + dir * 18,
          Paint()
            ..strokeWidth = 2.2
            ..strokeCap = StrokeCap.round
            ..color = c);
    }
  }

  void _chevron(Canvas canvas, MapMark m) {
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.9
      ..strokeJoin = StrokeJoin.round
      ..color = m.color;
    canvas.save();
    canvas.translate(m.at.dx, m.at.dy);
    canvas.rotate(m.angle ?? -math.pi / 2);
    canvas.drawPath(
        Path()
          ..moveTo(12, 0)
          ..lineTo(-8, 8)
          ..lineTo(-3, 0)
          ..lineTo(-8, -8)
          ..close(),
        stroke);
    canvas.restore();
  }

  void _pin(Canvas canvas, MapMark m) {
    final c = m.color;
    final tip = m.at;
    final head = tip - const Offset(0, 13);
    const r = 5.5;
    final pin = Path()
      ..moveTo(tip.dx, tip.dy)
      ..quadraticBezierTo(head.dx - r * 1.1, head.dy + r * 0.9, head.dx - r, head.dy)
      ..arcToPoint(Offset(head.dx + r, head.dy), radius: const Radius.circular(r))
      ..quadraticBezierTo(head.dx + r * 1.1, head.dy + r * 0.9, tip.dx, tip.dy)
      ..close();
    canvas.drawPath(pin, Paint()..color = OrecchinoColors.void0.withValues(alpha: 0.8));
    canvas.drawPath(
        pin,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = c);
    canvas.drawCircle(head, 2, Paint()..color = c);
  }

  void _reticle(Canvas canvas, Offset p) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..color = OrecchinoColors.ink;
    const r = 20.0, arm = 7.0;
    for (final (sx, sy) in const [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)]) {
      final c = p + Offset(sx * r, sy * r);
      canvas.drawLine(c, c + Offset(-sx * arm, 0), paint);
      canvas.drawLine(c, c + Offset(0, -sy * arm), paint);
    }
  }

  void _label(Canvas canvas, MapMark m) {
    final c = m.item;
    final main = TextStyle(
      fontFamily: OrecchinoType.display,
      fontSize: c.isOperator ? 11 : 12.5,
      fontWeight: FontWeight.w600,
      color: c.isOperator ? m.color : (c.stale ? OrecchinoColors.inkSubtle : OrecchinoColors.ink),
    );
    final sub = TextStyle(
      fontFamily: OrecchinoType.text,
      fontSize: 10.5,
      fontWeight: FontWeight.w500,
      fontFeatures: OrecchinoType.tabular,
      color: OrecchinoColors.inkMuted,
    );
    final text = c.label;
    final second = c.isOperator
        ? null
        : (c.isAircraft ? c.heightText : (c.heightM == null ? null : '${c.heightM!.round()} m'));
    final ms = CanvasText.measure(text, main, scaler);
    final ss = second == null ? Size.zero : CanvasText.measure(second, sub, scaler);
    final w = math.max(ms.width, ss.width), h = ms.height + ss.height;
    bool free(Rect r) => !_placed.any((o) => o.overlaps(r));
    Offset? spot;
    for (var dy = 0.0; dy <= 2 * h && spot == null; dy += h * 0.5) {
      for (final base in [m.at + Offset(16, -10 + dy), m.at + Offset(-16 - w, -10 + dy)]) {
        if (free(base & Size(w, h))) {
          spot = base;
          break;
        }
      }
    }
    if (spot == null && c.id == selectedId) spot = m.at + const Offset(16, -10);
    if (spot == null) return;
    _placed.add((spot & Size(w, h)).inflate(2));
    CanvasText.paint(canvas, text, spot, main, scaler: scaler);
    if (second != null) CanvasText.paint(canvas, second, spot + Offset(0, ms.height), sub, scaler: scaler);
  }

  @override
  bool shouldRepaint(MapMarksPainter old) => true;
}

/// Words for the map: a range ring's label, for tests and the screen reader.
String mapRangeWords(double rangeM) => 'Map, ${Geo.rangeText(rangeM)} range rings';

/// Used by the tests: the alerting aircraft the map will draw (only those an
/// alert names; UAS first).
List<LiveContactItem> mapAircraft(List<LiveContactItem> items) =>
    [for (final c in items) if (c.isAircraft && c.alert != null && c.alert!.level != TrafficLevel.none) c];
