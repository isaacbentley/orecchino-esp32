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
import '../../data/db.dart';
import '../../ui/glass.dart';
import '../../ui/theme/theme.dart';
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
          return ListView(
            // Readable width on tablets and phones on their side, clear of the
            // notch / Dynamic Island on either side.
            padding: EdgeInsets.fromLTRB(
              mq.padding.left + math.max(16.0, (mq.size.width - mq.padding.horizontal - 720) / 2),
              mq.padding.top + 12,
              mq.padding.right + math.max(16.0, (mq.size.width - mq.padding.horizontal - 720) / 2),
              mq.padding.bottom + 24,
            ),
            children: [
              const Text('LINK', style: OrecchinoType.eyebrow),
              const SizedBox(height: 2),
              Semantics(header: true, child: const Text('Detectors', style: OrecchinoType.title)),
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
                  _toggle(
                      'ADS-B traffic from adsb.lol',
                      'Sends your approximate area (about 1 km) every 10 s while the app is open',
                      'adsb',
                      app.settings.adsb),
                  _divider(),
                  _toggle('Notifications', 'Traffic near drones, emergencies, invalid ID signatures', 'notifications',
                      app.settings.notifications),
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
                          const Text('Mute alerts for 10 minutes', style: OrecchinoType.bodyStrong),
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
                    title: const Text('Demo detector (SIMULATED)', style: OrecchinoType.bodyStrong),
                    subtitle: const Text('Made-up drones and aircraft, for trying the app without hardware',
                        style: OrecchinoType.caption),
                    value: app.isSimulated,
                    onChanged: app.setDemo,
                  ),
                ]),
              ),
              const SizedBox(height: 12),
              const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: EdgeInsets.only(top: 1),
                  child: Icon(Icons.lock_outline_rounded, size: 16, color: OrecchinoColors.inkSubtle),
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Drone and operator positions stay on this phone; nothing is uploaded. ADS-B requests go to '
                    'adsb.lol with your approximate area.',
                    style: OrecchinoType.caption,
                  ),
                ),
              ]),
            ],
          );
        },
      ),
    );
  }

  Widget _divider() => const Divider(height: 1, color: OrecchinoColors.line);

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
            onPressed: () => WifiSetupSheet.show(context, app.link),
            icon: const Icon(Icons.wifi_rounded, size: 18),
            label: const Text('Wi-Fi'),
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
              onPressed: () => WifiSetupSheet.show(context, app.link),
              icon: const Icon(Icons.wifi_rounded, size: 18),
              label: const Text('Wi-Fi'),
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
          const Text(
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
                  const BreathingDot(color: OrecchinoColors.aqua, size: 9),
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
            const Padding(
              padding: EdgeInsets.only(top: 8),
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
