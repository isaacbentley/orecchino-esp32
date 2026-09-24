// detectors_view.dart — pairing, pinned detectors, sync, T5 Wi-Fi setup and
// the app's settings (plan §5.3 Detectors). Each detector is a glass card
// with a breathing connection light, its signal when the phone can hear it,
// and its capabilities as chips.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/ble/ble_service.dart';
import '../../core/ble/simulated_detector.dart';
import '../../core/native_rx/native_rx_service.dart';
import '../../core/power/power_policy.dart';
import '../../core/traffic/adsb_source.dart';
import '../../data/db.dart';
import '../../ui/glass.dart';
import '../../ui/theme/theme.dart';
import '../history/clear_history_sheet.dart';
import '../live/live_map.dart' show MapTileSource;
import 'wifi_setup_sheet.dart';

IconData _capIcon(String cap) => switch (cap) {
      'log' || 'log_since' => Icons.history_rounded,
      'tfr' => Icons.block_rounded,
      'wifi' => Icons.wifi_rounded,
      'traffic' => Icons.flight_rounded,
      _ => Icons.memory_rounded,
    };

class DetectorsView extends StatefulWidget {
  final AppController app;

  const DetectorsView({super.key, required this.app});

  @override
  State<DetectorsView> createState() => _DetectorsViewState();
}

class _DetectorsViewState extends State<DetectorsView> {
  late final Stream<List<DetectorEntry>> _detectors = widget.app.db.watchAllDetectors();

  AppController get app => widget.app;
  double? _radiusKm; // while the radius slider is dragged

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Material(
      type: MaterialType.transparency,
      child: StreamBuilder<List<DetectorEntry>>(
        stream: _detectors,
        builder: (context, snap) {
          final pinned = (snap.data ?? const <DetectorEntry>[]).where((d) => d.bonded).toList();
          final connected = app.detectorReady ? 1 : 0;
          return MediaQuery.removePadding(
            // The list is already clear of the side insets: a ListTile must not add them again.
            context: context,
            removeLeft: true,
            removeRight: true,
            child: ListView(
              // Readable width on tablets and phones on their side, clear of the
              // notch / Dynamic Island on either side.
              padding: EdgeInsets.fromLTRB(
                mq.padding.left + math.max(16.0, (mq.size.width - mq.padding.horizontal - 720) / 2),
                mq.padding.top + 12,
                mq.padding.right + math.max(16.0, (mq.size.width - mq.padding.horizontal - 720) / 2),
                mq.padding.bottom + 24,
              ),
              children: [
                Text('LINK', style: OrecchinoType.eyebrow),
                const SizedBox(height: 2),
                Semantics(header: true, child: Text('Detectors', style: OrecchinoType.title)),
                const SizedBox(height: 2),
                Text(
                  app.isSimulated
                      ? 'Demo detector on'
                      : '${pinned.length} paired · ${connected == 1 ? 'connected' : 'not connected'}',
                  style: OrecchinoType.label,
                ),
                const SizedBox(height: 16),
                if (app.isSimulated) ...[
                  _simCard(context),
                ] else ...[
                  for (final d in pinned) _detectorCard(context, d),
                  const SizedBox(height: 8),
                  _pairSection(context, pinned),
                ],
                const SizedBox(height: 18),
                const Eyebrow('Settings'),
                Glass(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                  child: Column(children: [
                    _phoneRx(),
                    _divider(),
                    _power(),
                    _divider(),
                    _theme(),
                    _divider(),
                    _background(),
                    _divider(),
                    _toggle(
                        'ADS-B conflict watch (adsb.lol)',
                        'Aircraft near your drones, and low aircraft. Sends an approximate area (about 1 km) '
                            'every 10 s while drones are about or a detector takes traffic, otherwise every '
                            'minute; none without your position',
                        'adsb',
                        app.settings.adsb),
                    if (app.settings.adsb) _radius(),
                    _divider(),
                    _mapTiles(context),
                    _divider(),
                    _toggle('Notifications', 'Traffic near drones, low traffic, emergencies, invalid ID signatures',
                        'notifications', app.settings.notifications),
                    _divider(),
                    _toggle('Haptics', 'Three short pulses for traffic, one for drone alerts', 'haptics',
                        app.settings.haptics),
                    _divider(),
                    _toggle('Spoken traffic callouts', 'Uses the system voice', 'spoken', app.settings.spoken),
                    _divider(),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Row(children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('Mute alerts for 10 minutes', style: OrecchinoType.bodyStrong),
                            const SizedBox(height: 2),
                            Text(
                              app.policy.isMuted(app.nowMs())
                                  ? 'Muted: alerts still show on screen'
                                  : 'Notifications, sound and haptics',
                              style: OrecchinoType.caption,
                            ),
                          ]),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(onPressed: app.muteAlerts, child: const Text('Mute')),
                      ]),
                    ),
                    _divider(),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('Demo detector (SIMULATED)', style: OrecchinoType.bodyStrong),
                      subtitle: Text(
                          'Made-up drones, and aircraft that come near them, for trying the app '
                          'without hardware',
                          style: OrecchinoType.caption),
                      value: app.isSimulated,
                      onChanged: app.setDemo,
                    ),
                  ]),
                ),
                const SizedBox(height: 12),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(Icons.lock_outline_rounded, size: 16, color: OrecchinoColors.inkSubtle),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Drone and operator positions stay on this phone; nothing is uploaded. ADS-B requests go to '
                      'adsb.lol with your approximate area.',
                      style: OrecchinoType.caption,
                    ),
                  ),
                ]),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _divider() => Divider(height: 1, color: OrecchinoColors.line);

  static String powerWords(PowerMode m) => switch (m) {
        PowerMode.full => 'The smoothest sky and the fastest scans on every screen; ADS-B every 10 s. '
            'Uses the most battery.',
        PowerMode.balanced => 'Scans hardest on Live and Find, lighter elsewhere and in the background; a '
            'slower sky; ADS-B every 10 s while drones are about, otherwise every minute.',
        PowerMode.saver => 'A still sky without blur. This phone listens only on Live and Find, never in the '
            'background, and not on Wi-Fi; ADS-B only while drones are about. A detector still alerts.',
      };

  /// Sky / Flat.
  Widget _theme() {
    final look = app.settings.look;
    final saverHint = app.settings.powerMode == PowerMode.saver && look == AppLook.sky;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Theme', style: OrecchinoType.bodyStrong),
        const SizedBox(height: 8),
        GlassSegmented<AppLook>(
          options: [for (final l in AppLook.values) (l, l.label, '${l.label} theme')],
          value: look,
          onChanged: app.setLook,
        ),
        const SizedBox(height: 6),
        Text(
          look == AppLook.sky
              ? 'The night sky: a living aurora behind frosted glass, and a 3D sky of the drones.'
              : 'Flat panels and a top-down radar, as in the design mockups; nothing moves that '
                  'does not need to.',
          style: OrecchinoType.caption,
        ),
        if (saverHint)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('With Saver, Flat is the natural choice: no aurora or blur to draw.',
                style: OrecchinoType.caption.copyWith(color: OrecchinoColors.aqua)),
          ),
      ]),
    );
  }

  /// Full / Balanced / Saver.
  Widget _power() {
    final mode = app.settings.powerMode;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Power', style: OrecchinoType.bodyStrong),
        const SizedBox(height: 8),
        GlassSegmented<PowerMode>(
          options: [for (final m in PowerMode.values) (m, m.label, '${m.label} power mode')],
          value: mode,
          onChanged: app.setPowerMode,
        ),
        const SizedBox(height: 6),
        Text(powerWords(mode), style: OrecchinoType.caption),
      ]),
    );
  }

  /// What happens with the app in the background: Android's "Watch in the
  /// background" service, or on iPhone what iOS allows, in plain words.
  Widget _background() {
    final w = app.watch;
    if (w != null && w.supported) {
      final err = w.error;
      return SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text('Watch in the background', style: OrecchinoType.bodyStrong),
        subtitle: Text(
          app.settings.watchInBackground
              ? (app.watchRunning
                  ? 'On: ${app.watchText()}. The notification has Open, Pause 1 h and Stop.'
                  : (err != null ? 'Could not start: $err' : 'On: starts when the app is open'))
              : 'Keeps the detector link, this phone\'s receiver and the alerts running with the app closed, '
                  'with a notification saying so. Off: they stop soon after you leave the app.',
          style: OrecchinoType.caption,
        ),
        value: app.settings.watchInBackground,
        onChanged: app.setWatchInBackground,
      );
    }
    final ios = app.nativeRx?.isIOS ?? Theme.of(context).platform == TargetPlatform.iOS;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('In the background', style: OrecchinoType.bodyStrong),
        const SizedBox(height: 2),
        Text(
          ios
              ? 'In the background your iPhone stays connected to your detector and alerts you. This iPhone\'s '
                  'own receiver works only while Orecchino is open. Without a detector there are no background '
                  'alerts. If you swipe Orecchino away, it stops until you open it again.'
              : 'Watching stops soon after you leave the app.',
          style: OrecchinoType.caption,
        ),
      ]),
    );
  }

  /// "Use this phone as a detector", and what this phone can hear.
  Widget _phoneRx() {
    final rx = app.nativeRx;
    final caps = rx?.capabilities;
    String yn(CapState s) => switch (s) { CapState.yes => 'yes', CapState.no => 'no', CapState.unknown => 'unknown' };
    final lines = <String>[
      if (rx == null) 'Not available on this device',
      if (caps != null && rx!.isIOS) 'Bluetooth 4 only, while the app is open',
      if (caps != null && !rx!.isIOS) ...[
        'Bluetooth 4: ${yn(caps.ble4)} · Bluetooth 5: ${yn(caps.ble5Extended)} · long range: ${yn(caps.codedPhy)}',
        'Wi-Fi NAN: ${yn(caps.nan)}${caps.nanReason == null ? '' : ' (${caps.nanReason})'}',
        'Wi-Fi beacons: ${caps.beacon == CapState.yes ? 'slow (every ${caps.beaconIntervalS ?? 30} s)' : yn(caps.beacon)}'
            '${caps.beaconReason == null ? '' : ' (${caps.beaconReason})'}',
      ],
      if (rx != null && rx.running && rx.pathStates.isNotEmpty)
        'Now: ${[for (final e in rx.pathStates.entries) '${e.key} ${e.value}'].join(', ')}',
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text('Use this phone as a detector', style: OrecchinoType.bodyStrong),
        subtitle: Text('Hears Remote ID itself, alongside any detector; its drones go into History as '
            '"This phone"', style: OrecchinoType.caption),
        value: rx != null && app.settings.phoneRx,
        onChanged: rx == null ? null : app.setPhoneRx,
      ),
      if (lines.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Semantics(
            label: 'This phone can hear: ${lines.join('. ')}',
            excludeSemantics: true,
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(Icons.smartphone_rounded, size: 16, color: OrecchinoColors.aqua),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final l in lines) Text(l, style: OrecchinoType.caption),
                ]),
              ),
            ]),
          ),
        ),
    ]);
  }

  /// Where the Live map's tiles come from: Esri's dark canvas (no key), or
  /// a template of the person's own with its key and attribution.
  Widget _mapTiles(BuildContext context) {
    final custom = app.settings.mapUrl.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Map tiles', style: OrecchinoType.bodyStrong),
            const SizedBox(height: 2),
            Text(
              custom
                  ? 'Your own: ${Uri.tryParse(app.settings.mapUrl)?.host ?? app.settings.mapUrl}'
                  : 'Esri World Dark Gray Canvas (no key). CARTO Dark Matter now needs an API key: '
                      'add its template with your key here.',
              style: OrecchinoType.caption,
            ),
          ]),
        ),
        const SizedBox(width: 8),
        OutlinedButton(onPressed: () => _editMapTiles(context), child: const Text('Change')),
      ]),
    );
  }

  Future<void> _editMapTiles(BuildContext context) async {
    final url = TextEditingController(text: app.settings.mapUrl);
    final attrib = TextEditingController(text: app.settings.mapAttribution);
    String? error;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Map tiles'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: url,
                autocorrect: false,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: 'Tile URL template (https, {z} {x} {y})',
                  hintText: 'https://…/{z}/{x}/{y}.png?api_key=…',
                  errorText: error,
                ),
              ),
              TextField(
                controller: attrib,
                decoration: const InputDecoration(labelText: 'Attribution shown on the map'),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, 'default'), child: const Text('USE DEFAULT')),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('CANCEL')),
            TextButton(
              onPressed: () {
                if (!MapTileSource.validTemplate(url.text.trim())) {
                  set(() => error = 'Needs https:// and {z}, {x} and {y}');
                  return;
                }
                Navigator.pop(ctx, 'save');
              },
              child: const Text('SAVE'),
            ),
          ],
        ),
      ),
    );
    if (result == 'default') await app.setMapTiles('', '');
    if (result == 'save') await app.setMapTiles(url.text, attrib.text);
    url.dispose();
    attrib.dispose();
  }

  /// The ADS-B query radius, 5-30 km around the phone.
  Widget _radius() {
    final km = _radiusKm ?? app.settings.adsbRadiusKm.toDouble();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('ADS-B radius', style: OrecchinoType.bodyStrong)),
          Text('${km.round()} km', style: OrecchinoType.bodyStrong.copyWith(color: OrecchinoColors.aqua)),
        ]),
        Slider(
          value: km,
          min: AdsbArea.minKm.toDouble(),
          max: AdsbArea.maxKm.toDouble(),
          divisions: AdsbArea.maxKm - AdsbArea.minKm,
          label: '${km.round()} km',
          semanticFormatterCallback: (v) => 'ADS-B radius ${v.round()} kilometres',
          onChanged: (v) => setState(() => _radiusKm = v),
          onChangeEnd: (v) {
            setState(() => _radiusKm = null);
            app.setAdsbRadiusKm(v.round());
          },
        ),
        Text(
          'Around the phone. A live drone more than 3 km away widens it so each drone has 9 km, up to 30 km. '
          'Aircraft outside it are dropped.',
          style: OrecchinoType.caption,
        ),
      ]),
    );
  }

  Widget _toggle(String title, String subtitle, String key, bool value) => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(title, style: OrecchinoType.bodyStrong),
        subtitle: Text(subtitle, style: OrecchinoType.caption),
        value: value,
        onChanged: (v) => app.setSetting(key, v),
      );

  Widget _deviceCard({
    required String name,
    required String subtitle,
    required Color light,
    required bool active,
    required bool busy,
    required Widget status,
    int? rssi,
    required List<String> caps,
    required List<Widget> body,
    required List<Widget> actions,
    Color? edge,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Glass(
        edge: edge,
        wash: active ? light : null,
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            BreathingDot(color: light, active: active || busy, busy: busy, size: 12),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, style: OrecchinoType.heading),
                const SizedBox(height: 2),
                Text(subtitle, style: OrecchinoType.idSmall),
                const SizedBox(height: 6),
                status,
              ]),
            ),
            if (rssi != null)
              Semantics(
                label: 'signal $rssi dBm',
                excludeSemantics: true,
                child: Column(children: [
                  SignalBars(level: SignalBars.fromRssi(rssi), color: light),
                  const SizedBox(height: 4),
                  Text('$rssi dBm', style: OrecchinoType.caption.copyWith(fontSize: 11)),
                ]),
              ),
          ]),
          if (caps.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final c in caps) Tag(c.toUpperCase(), icon: _capIcon(c), color: OrecchinoColors.inkMuted),
            ]),
          ],
          ...body,
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: actions),
        ]),
      ),
    );
  }

  Widget _simCard(BuildContext context) {
    return _deviceCard(
      name: 'SIMULATED DETECTOR',
      subtitle: '${SimulatedDetector.info.board} · firmware ${SimulatedDetector.info.version}',
      light: OrecchinoColors.ok,
      active: true,
      busy: false,
      edge: OrecchinoColors.ok.withValues(alpha: 0.45),
      status: Text('Demo mode: nothing here is real',
          style: OrecchinoType.label.copyWith(color: OrecchinoColors.caution, fontWeight: FontWeight.w600)),
      caps: SimulatedDetector.info.capabilities,
      body: [
        const SizedBox(height: 8),
        _syncLine(),
      ],
      actions: [
        FilledButton.icon(
            onPressed: app.syncNow, icon: const Icon(Icons.sync_rounded, size: 18), label: const Text('Sync')),
        if (SimulatedDetector.info.has('wifi'))
          OutlinedButton.icon(
            onPressed: () => WifiSetupSheet.show(context, app.link, mapPlan: app.mapPlan),
            icon: const Icon(Icons.wifi_rounded, size: 18),
            label: const Text('Wi-Fi'),
          ),
        OutlinedButton.icon(
          onPressed: () => ClearHistorySheet.show(context, app),
          icon: const Icon(Icons.delete_sweep_rounded, size: 18),
          label: const Text('Clear history…'),
          style: OutlinedButton.styleFrom(foregroundColor: OrecchinoColors.warning),
        ),
      ],
    );
  }

  Widget _syncLine() {
    final p = app.syncProgress;
    final String text;
    if (p.isSyncing) {
      text = 'Syncing history: ${p.recordsSynced} records';
    } else if (p.error != null) {
      text = 'Last sync: ${p.error}';
    } else if (p.recordsSynced > 0 || p.liveContacts > 0) {
      text = 'Synced ${p.recordsSynced} new records, ${p.liveContacts} still in range'
          '${p.logCleared ? ' (the detector\'s log was cleared)' : ''}';
    } else {
      text = '';
    }
    return text.isEmpty
        ? const SizedBox.shrink()
        : Row(children: [
            Icon(p.isSyncing ? Icons.downloading_rounded : Icons.check_circle_outline_rounded,
                size: 16, color: p.error != null ? OrecchinoColors.caution : OrecchinoColors.inkMuted),
            const SizedBox(width: 6),
            Expanded(
              child: Text(text,
                  style: OrecchinoType.label
                      .copyWith(color: p.error != null ? OrecchinoColors.caution : OrecchinoColors.inkMuted)),
            ),
          ]);
  }

  Widget _detectorCard(BuildContext context, DetectorEntry d) {
    final ble = app.ble;
    final isThis = ble.peerId == d.id || app.connectedDetectorId == d.id;
    final ready = app.connectedDetectorId == d.id && app.detectorReady;
    final busy = isThis &&
        (ble.state == BleLinkState.connecting ||
            ble.state == BleLinkState.verifying ||
            ble.state == BleLinkState.pairing);
    final String state;
    Color stateColor = OrecchinoColors.inkMuted;
    if (ready) {
      state = 'Connected';
      stateColor = OrecchinoColors.ok;
    } else if (ble.waitingFor == d.id) {
      // A pending connect: no scanning, Bluetooth connects when it is near.
      state = 'Waiting for it to come in range';
    } else if (isThis) {
      state = switch (ble.state) {
        BleLinkState.connecting => 'Connecting…',
        BleLinkState.verifying => 'Checking it is an Orecchino…',
        BleLinkState.pairing => 'Pairing: enter the passkey the detector shows',
        BleLinkState.failed => 'Failed: ${ble.error ?? 'unknown'}',
        _ => 'Not connected${ble.error == null ? '' : ' (${ble.error})'}',
      };
      if (ble.state == BleLinkState.failed) stateColor = OrecchinoColors.warning;
      if (busy) stateColor = OrecchinoColors.aqua;
    } else {
      state = 'Not connected';
    }
    final caps = d.caps.split(',').where((c) => c.isNotEmpty).toList();
    final hit = ble.scanHits.where((h) => h.id == d.id).firstOrNull;
    final lastSync = d.lastSyncUtc == null
        ? 'never synced'
        : 'last sync ${DateTime.fromMillisecondsSinceEpoch(d.lastSyncUtc! * 1000).toLocal().toString().substring(0, 16)}';
    return _deviceCard(
      name: d.name,
      subtitle: '${d.board} · firmware ${d.ver}',
      light: ready ? OrecchinoColors.ok : (busy ? OrecchinoColors.aqua : stateColor),
      active: ready,
      busy: busy,
      edge: ready ? OrecchinoColors.ok.withValues(alpha: 0.45) : null,
      rssi: hit?.rssi,
      status: Semantics(
        liveRegion: true,
        child: Text(state, style: OrecchinoType.label.copyWith(color: stateColor, fontWeight: FontWeight.w600)),
      ),
      caps: caps,
      body: [
        const SizedBox(height: 10),
        Text('History: $lastSync, next record ${d.lastSyncSeq}', style: OrecchinoType.caption),
        if (d.historyGap)
          Text('Some history rotated out on the detector before this phone synced',
              style: OrecchinoType.caption.copyWith(color: OrecchinoColors.caution)),
        if (ready) ...[const SizedBox(height: 6), _syncLine()],
      ],
      actions: [
        if (ready) ...[
          FilledButton.icon(
            onPressed: app.sync.isSyncing ? null : app.syncNow,
            icon: const Icon(Icons.sync_rounded, size: 18),
            label: const Text('Sync'),
          ),
          if (caps.contains('wifi'))
            OutlinedButton.icon(
              onPressed: () => WifiSetupSheet.show(context, app.link, mapPlan: app.mapPlan),
              icon: const Icon(Icons.wifi_rounded, size: 18),
              label: const Text('Wi-Fi'),
            ),
          OutlinedButton.icon(
            onPressed: () => ClearHistorySheet.show(context, app),
            icon: const Icon(Icons.delete_sweep_rounded, size: 18),
            label: const Text('Clear history…'),
            style: OutlinedButton.styleFrom(foregroundColor: OrecchinoColors.warning),
          ),
          TextButton(onPressed: app.disconnect, child: const Text('Disconnect')),
        ] else
          FilledButton(
            onPressed: isThis && ble.state.index > BleLinkState.scanning.index && ble.state != BleLinkState.failed
                ? null
                : () => app.connectPinned(d.id),
            child: const Text('Connect'),
          ),
        TextButton(
          onPressed: () => _confirmForget(context, d),
          style: TextButton.styleFrom(foregroundColor: OrecchinoColors.warning),
          child: const Text('Forget'),
        ),
      ],
    );
  }

  Future<void> _confirmForget(BuildContext context, DetectorEntry d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Forget ${d.name}?'),
        content: const Text('The app stops connecting to it and giving it your position. Its history stays on '
            'this phone. On iPhone, also remove it in Settings > Bluetooth.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: OrecchinoColors.warning),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (ok == true) await app.forget(d.id);
  }

  Widget _pairSection(BuildContext context, List<DetectorEntry> pinned) {
    final ble = app.ble;
    final pinnedIds = pinned.map((d) => d.id).toSet();
    final hits = ble.scanHits.where((h) => !pinnedIds.contains(h.id)).toList();
    final scanning = ble.state == BleLinkState.scanning;
    final busy = ble.state == BleLinkState.connecting ||
        ble.state == BleLinkState.verifying ||
        ble.state == BleLinkState.pairing;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Eyebrow('Pair a detector'),
      Glass(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(
            'Turn the detector on and keep it close. When you tap Pair, the detector shows a 6-digit passkey '
            '(Orecchino detectors use 123456) and the phone asks for it: type it within 10 seconds, or the detector '
            'hangs up. After that the app reconnects by itself and gives the detector the time and your position.',
            style: OrecchinoType.label,
          ),
          const SizedBox(height: 12),
          Row(children: [
            FilledButton.icon(
              onPressed: scanning || busy ? null : ble.startScan,
              icon: scanning
                  ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.bluetooth_searching_rounded, size: 18),
              label: Text(scanning ? 'Scanning…' : 'Scan'),
            ),
            if (scanning) ...[
              const SizedBox(width: 8),
              TextButton(onPressed: ble.stopScan, child: const Text('Stop')),
            ],
          ]),
          if (ble.state == BleLinkState.failed && !pinnedIds.contains(ble.peerId))
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(ble.error ?? 'Failed', style: OrecchinoType.label.copyWith(color: OrecchinoColors.warning)),
            ),
          if (busy && !pinnedIds.contains(ble.peerId))
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  ble.state == BleLinkState.pairing ? 'Enter the passkey the detector shows' : 'Connecting…',
                  style: OrecchinoType.label.copyWith(color: OrecchinoColors.aqua),
                ),
              ),
            ),
          for (final h in hits)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Container(
                padding: const EdgeInsets.fromLTRB(4, 6, 6, 6),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: OrecchinoColors.line),
                ),
                child: Row(children: [
                  BreathingDot(color: OrecchinoColors.aqua, size: 9),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(h.name.isEmpty ? 'Unnamed detector' : h.name, style: OrecchinoType.bodyStrong),
                      Row(children: [
                        SignalBars(level: SignalBars.fromRssi(h.rssi), height: 11),
                        const SizedBox(width: 6),
                        Text('signal ${h.rssi} dBm', style: OrecchinoType.caption),
                      ]),
                    ]),
                  ),
                  OutlinedButton(
                      onPressed: busy ? null : () => _pair(context, h.id, h.name), child: const Text('Pair')),
                ]),
              ),
            ),
          if (!scanning && hits.isEmpty && ble.scanHits.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('Only detectors already paired are in range', style: OrecchinoType.label),
            ),
        ]),
      ),
    ]);
  }

  Future<void> _pair(BuildContext context, String id, String name) async {
    final ok = await app.pair(id, name);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? 'Paired with ${name.isEmpty ? 'the detector' : name}' : 'Pairing failed: ${app.ble.error}'),
    ));
  }
}
