// detectors_view.dart — pairing, pinned detectors, sync, T5 Wi-Fi setup and
// the app's settings (plan §5.3 Detectors).
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/ble/ble_service.dart';
import '../../core/ble/simulated_detector.dart';
import '../../data/db.dart';
import '../../ui/theme.dart';
import 'wifi_setup_sheet.dart';

class DetectorsView extends StatefulWidget {
  final AppController app;

  const DetectorsView({super.key, required this.app});

  @override
  State<DetectorsView> createState() => _DetectorsViewState();
}

class _DetectorsViewState extends State<DetectorsView> {
  late final Stream<List<DetectorEntry>> _detectors = widget.app.db.watchAllDetectors();

  AppController get app => widget.app;

  static const _h = TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: OrecchinoTheme.muted, letterSpacing: 1);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('DETECTORS')),
      body: StreamBuilder<List<DetectorEntry>>(
        stream: _detectors,
        builder: (context, snap) {
          final pinned = (snap.data ?? const <DetectorEntry>[]).where((d) => d.bonded).toList();
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (app.isSimulated) ...[
                _simCard(context),
              ] else ...[
                for (final d in pinned) _detectorCard(context, d),
                const SizedBox(height: 16),
                _pairSection(context, pinned),
              ],
              const SizedBox(height: 24),
              const Text('SETTINGS', style: _h),
              _toggle('ADS-B traffic from adsb.lol',
                  'Sends your approximate area (about 1 km) every 10 s while the app is open', 'adsb', app.settings.adsb),
              _toggle('Notifications', 'Traffic near drones, emergencies, invalid ID signatures', 'notifications',
                  app.settings.notifications),
              _toggle('Haptics', 'Three short pulses for traffic, one for drone alerts', 'haptics', app.settings.haptics),
              _toggle('Spoken traffic callouts', 'Uses the system voice', 'spoken', app.settings.spoken),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Mute alerts for 10 minutes'),
                subtitle: Text(
                  app.policy.isMuted(app.nowMs()) ? 'Muted: alerts still show on screen' : 'Notifications, sound and haptics',
                  style: const TextStyle(fontSize: 12, color: OrecchinoTheme.muted),
                ),
                trailing: TextButton(onPressed: app.muteAlerts, child: const Text('MUTE')),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Demo detector (SIMULATED)'),
                subtitle: const Text('Made-up drones and aircraft, for trying the app without hardware',
                    style: TextStyle(fontSize: 12, color: OrecchinoTheme.muted)),
                value: app.isSimulated,
                onChanged: app.setDemo,
              ),
              const SizedBox(height: 8),
              const Text(
                'Drone and operator positions stay on this phone; nothing is uploaded. ADS-B requests go to '
                'adsb.lol with your approximate area.',
                style: TextStyle(fontSize: 12, color: OrecchinoTheme.muted),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _toggle(String title, String subtitle, String key, bool value) => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(title),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 12, color: OrecchinoTheme.muted)),
        value: value,
        onChanged: (v) => app.setSetting(key, v),
      );

  Widget _card({required Widget child, bool active = false}) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: OrecchinoTheme.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: active ? OrecchinoTheme.accent : OrecchinoTheme.border),
        ),
        child: child,
      );

  Widget _simCard(BuildContext context) {
    return _card(
      active: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('SIMULATED DETECTOR', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        const Text('Demo mode: nothing here is real', style: TextStyle(fontSize: 12, color: OrecchinoTheme.amber)),
        const SizedBox(height: 8),
        _syncLine(),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          OutlinedButton(onPressed: app.syncNow, child: const Text('SYNC')),
          if (SimulatedDetector.info.has('wifi'))
            OutlinedButton(onPressed: () => WifiSetupSheet.show(context, app.link), child: const Text('WI-FI')),
        ]),
      ]),
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
        : Text(text, style: TextStyle(fontSize: 13, color: p.error != null ? OrecchinoTheme.amber : OrecchinoTheme.muted));
  }

  Widget _detectorCard(BuildContext context, DetectorEntry d) {
    final ble = app.ble;
    final isThis = ble.peerId == d.id || app.connectedDetectorId == d.id;
    final ready = app.connectedDetectorId == d.id && app.detectorReady;
    final String state;
    Color stateColor = OrecchinoTheme.muted;
    if (ready) {
      state = 'Connected';
      stateColor = OrecchinoTheme.ok;
    } else if (isThis) {
      state = switch (ble.state) {
        BleLinkState.connecting => 'Connecting…',
        BleLinkState.verifying => 'Checking it is an Orecchino…',
        BleLinkState.pairing => 'Pairing: enter the passkey the detector shows',
        BleLinkState.failed => 'Failed: ${ble.error ?? 'unknown'}',
        _ => 'Not connected${ble.error == null ? '' : ' (${ble.error})'}',
      };
      if (ble.state == BleLinkState.failed) stateColor = OrecchinoTheme.danger;
    } else {
      state = 'Not connected';
    }
    final caps = d.caps.split(',');
    final lastSync = d.lastSyncUtc == null
        ? 'never synced'
        : 'last sync ${DateTime.fromMillisecondsSinceEpoch(d.lastSyncUtc! * 1000).toLocal().toString().substring(0, 16)}';
    return _card(
      active: ready,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(d.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        Text('${d.board} · firmware ${d.ver}', style: const TextStyle(fontSize: 12, color: OrecchinoTheme.muted)),
        const SizedBox(height: 4),
        Semantics(liveRegion: true, child: Text(state, style: TextStyle(fontSize: 13, color: stateColor))),
        Text('History: $lastSync, next record ${d.lastSyncSeq}',
            style: const TextStyle(fontSize: 12, color: OrecchinoTheme.muted)),
        if (d.historyGap)
          const Text('Some history rotated out on the detector before this phone synced',
              style: TextStyle(fontSize: 12, color: OrecchinoTheme.amber)),
        if (ready) _syncLine(),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 4, children: [
          if (ready) ...[
            OutlinedButton(onPressed: app.sync.isSyncing ? null : app.syncNow, child: const Text('SYNC')),
            if (caps.contains('wifi'))
              OutlinedButton(onPressed: () => WifiSetupSheet.show(context, app.link), child: const Text('WI-FI')),
            TextButton(onPressed: app.disconnect, child: const Text('DISCONNECT')),
          ] else
            OutlinedButton(
              onPressed: isThis && ble.state.index > BleLinkState.scanning.index && ble.state != BleLinkState.failed
                  ? null
                  : () => app.connectPinned(d.id),
              child: const Text('CONNECT'),
            ),
          TextButton(
            onPressed: () => _confirmForget(context, d),
            child: const Text('FORGET', style: TextStyle(color: OrecchinoTheme.danger)),
          ),
        ]),
      ]),
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
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('CANCEL')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('FORGET')),
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
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('PAIR A DETECTOR', style: _h),
      const SizedBox(height: 6),
      const Text(
        'Turn the detector on and keep it close. When you tap Pair, the detector shows a 6-digit passkey '
        '(Orecchino detectors use 123456) and the phone asks for it: type it within 10 seconds, or the detector '
        'hangs up. After that the app reconnects by itself and gives the detector the time and your position.',
        style: TextStyle(fontSize: 13, color: OrecchinoTheme.muted),
      ),
      const SizedBox(height: 8),
      Row(children: [
        FilledButton.icon(
          onPressed: scanning || busy ? null : ble.startScan,
          icon: const Icon(Icons.bluetooth_searching),
          label: Text(scanning ? 'SCANNING…' : 'SCAN'),
        ),
        if (scanning) ...[
          const SizedBox(width: 8),
          TextButton(onPressed: ble.stopScan, child: const Text('STOP')),
        ],
      ]),
      if (ble.state == BleLinkState.failed && !pinnedIds.contains(ble.peerId))
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(ble.error ?? 'Failed', style: const TextStyle(color: OrecchinoTheme.danger, fontSize: 13)),
        ),
      if (busy && !pinnedIds.contains(ble.peerId))
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Semantics(
            liveRegion: true,
            child: Text(
              ble.state == BleLinkState.pairing ? 'Enter the passkey the detector shows' : 'Connecting…',
              style: const TextStyle(color: OrecchinoTheme.accent, fontSize: 13),
            ),
          ),
        ),
      for (final h in hits)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.sensors, color: OrecchinoTheme.accent),
          title: Text(h.name.isEmpty ? 'Unnamed detector' : h.name),
          subtitle: Text('signal ${h.rssi} dBm', style: const TextStyle(fontSize: 12, color: OrecchinoTheme.muted)),
          trailing: OutlinedButton(onPressed: busy ? null : () => _pair(context, h.id, h.name), child: const Text('PAIR')),
        ),
      if (!scanning && hits.isEmpty && ble.scanHits.isNotEmpty)
        const Text('Only detectors already paired are in range', style: TextStyle(fontSize: 13, color: OrecchinoTheme.muted)),
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
