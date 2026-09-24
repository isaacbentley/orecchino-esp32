// wifi_setup_sheet.dart — T5 Wi-Fi setup over BLE (plan §4.3, commands and
// replies in firmware/common/net_sync.h "HOST COMMANDS").
//
// One subscription for the life of the sheet (initState -> dispose), so a
// rebuild never adds a listener and a swipe-dismiss never leaks one. The
// mode chips show the board's reported mode; every step has a state the
// person can see: scanning, no networks, scan failed, connecting, connected,
// failed with the board's reason, and a refused command; "Wi-Fi paused:
// phone connected" while this phone's link holds the board's automatic
// windows ("paused":"phone"). Below the networks, the board's ADS-B radius
// and map area (wifi_config) with its storage plan, when the firmware
// reports them. Drawn on glass to match the rest of the app.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/link/detector_link.dart';
import '../../core/protocol/commands.dart';
import '../../core/protocol/messages.dart';
import '../../ui/glass.dart';
import '../../ui/theme/theme.dart';

enum WifiScanState { scanning, done, failed }

class WifiSetupSheet extends StatefulWidget {
  final DetectorLink link;
  final Duration scanTimeout;

  /// The board's last map plan, if a "net" line already carried one.
  final String? mapPlan;

  const WifiSetupSheet({super.key, required this.link, this.scanTimeout = const Duration(seconds: 20), this.mapPlan});

  static Future<void> show(BuildContext context, DetectorLink link, {String? mapPlan}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: const Color(0x99020409),
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.85,
        child: Glass(
          blur: 32,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
          child: WifiSetupSheet(link: link, mapPlan: mapPlan),
        ),
      ),
    );
  }

  @override
  State<WifiSetupSheet> createState() => WifiSetupSheetState();
}

class WifiSetupSheetState extends State<WifiSetupSheet> {
  StreamSubscription<HostMessage>? _sub;
  Timer? _scanTimer;
  final List<WifiNetMessage> _nets = [];
  WifiScanState _scan = WifiScanState.scanning;
  String? _scanError;
  WifiStatusMessage? _status;
  String? _joining; // ssid while a join we asked for runs
  String? _error; // a refused command or a failed send
  String? _pendingMode;
  bool? _paused; // from wifi_status "paused", then the "net" paused / resumed lines
  String? _mapPlan;
  double? _adsbKm, _tileKm; // while a slider is dragged or its command is on the way

  /// For tests: the networks shown.
  List<WifiNetMessage> get networks => List.unmodifiable(_nets);

  @override
  void initState() {
    super.initState();
    _mapPlan = widget.mapPlan;
    _sub = widget.link.messages.listen(_onMessage);
    _send(HostCommands.wifiStatus());
    _startScan();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _sub = null;
    _scanTimer?.cancel();
    super.dispose();
  }

  Future<void> _send(String cmd) async {
    try {
      await widget.link.send(cmd);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not send to the detector: $e');
    }
  }

  void _startScan() {
    setState(() {
      _nets.clear();
      _scan = WifiScanState.scanning;
      _scanError = null;
    });
    _scanTimer?.cancel();
    _scanTimer = Timer(widget.scanTimeout, () {
      if (mounted && _scan == WifiScanState.scanning) {
        setState(() {
          _scan = WifiScanState.failed;
          _scanError = 'The detector did not answer the scan';
        });
      }
    });
    _send(HostCommands.wifiScan());
  }

  void _onMessage(HostMessage msg) {
    if (!mounted) return;
    setState(() {
      if (msg is WifiNetMessage) {
        if (msg.ssid.isNotEmpty) {
          _nets.removeWhere((n) => n.ssid == msg.ssid);
          _nets.add(msg);
        }
      } else if (msg is WifiScanDoneMessage) {
        _scanTimer?.cancel();
        _scan = msg.error == null ? WifiScanState.done : WifiScanState.failed;
        _scanError = msg.error;
      } else if (msg is WifiStatusMessage) {
        _status = msg;
        _pendingMode = null;
        _paused = msg.pausedByPhone;
        _adsbKm = _tileKm = null;
        if (_joining != null && (msg.state == 'connected' || msg.state == 'failed')) _joining = null;
      } else if (msg is NetStatusMessage) {
        if (msg.state == 'paused') _paused = true;
        if (msg.state == 'resumed') _paused = false;
        if (msg.map != null && msg.map!.isNotEmpty) _mapPlan = msg.map;
      } else if (msg is WifiErrorMessage) {
        _error = '${msg.command}: ${msg.reason}';
        _joining = null;
        _pendingMode = null;
        if (msg.command == 'wifi_config') _adsbKm = _tileKm = null;
        if (msg.command == 'wifi_scan' && _scan == WifiScanState.scanning) {
          _scan = WifiScanState.failed;
          _scanError = msg.reason;
        }
      }
    });
  }

  void _join(String ssid, String? psk) {
    setState(() {
      _joining = ssid;
      _error = null;
    });
    _send(HostCommands.wifiJoin(ssid: ssid, psk: psk));
  }

  void _setMode(String mode) {
    setState(() {
      _pendingMode = mode;
      _error = null;
    });
    _send(HostCommands.wifiMode(mode: mode, everyMin: _status?.everyMin ?? 15));
  }

  @override
  Widget build(BuildContext context) {
    final st = _status;
    final mode = _pendingMode ?? st?.mode;
    final saved = st?.saved ?? const <String>[];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 12, 8),
        // One list: the status and mode on top, the networks, then the
        // board's data settings.
        child: Builder(builder: (context) {
          final top = <Widget>[
            Center(
              child: Container(
                width: 40,
                height: 5,
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(color: OrecchinoColors.lineBright, borderRadius: BorderRadius.circular(3)),
              ),
            ),
            Row(
              children: [
                Icon(Icons.wifi_rounded, color: OrecchinoColors.aqua, size: 22),
                const SizedBox(width: 10),
                Expanded(child: Semantics(header: true, child: Text('T5 Wi-Fi', style: OrecchinoType.heading))),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Padding(padding: const EdgeInsets.only(right: 8), child: _statusLine(st)),
            if (_paused == true && st?.state != 'connected' && st?.state != 'connecting' && _joining == null)
              _pausedNote(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8, right: 8),
                child: Text(_error!, style: OrecchinoType.label.copyWith(color: OrecchinoColors.warning)),
              ),
            const SizedBox(height: 14),
            Text('MODE', style: OrecchinoType.eyebrow),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              _modeChip('sync', 'Sync every ${st?.everyMin ?? 15} min', mode),
              _modeChip('stay', 'Stay connected', mode),
              _modeChip('off', 'Off', mode),
            ]),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                'Remote ID Wi-Fi pauses while the board scans or syncs; in Stay connected it hears only the '
                'access point\'s channel. BLE Remote ID is unaffected.',
                style: OrecchinoType.caption,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: Text('NETWORKS', style: OrecchinoType.eyebrow)),
                if (_scan == WifiScanState.scanning)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, semanticsLabel: 'Scanning')),
                  )
                else
                  TextButton(onPressed: _startScan, child: const Text('SCAN AGAIN')),
              ],
            ),
          ];
          return MediaQuery.removePadding(
            // The sheet is already clear of the side insets: a ListTile must not add them again.
            context: context,
            removeLeft: true,
            removeRight: true,
            child: ListView(
              padding: const EdgeInsets.only(right: 8),
              children: [...top, ..._rows(saved), if (st?.adsbKm != null) ..._dataSettings(st!)],
            ),
          );
        }),
      ),
    );
  }

  Widget _pausedNote() => Padding(
        padding: const EdgeInsets.only(top: 8, right: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(Icons.pause_circle_outline_rounded, size: 18, color: OrecchinoColors.caution),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Wi-Fi paused: phone connected',
                  style: OrecchinoType.bodyStrong.copyWith(color: OrecchinoColors.caution)),
              const SizedBox(height: 2),
              Text(
                'The board skips its automatic syncs while this phone is linked (the phone sends the data). '
                'Scan, connect and mode changes still run.',
                style: OrecchinoType.caption,
              ),
            ]),
          ),
        ]),
      );

  /// The board's ADS-B radius and map area (wifi_config), and its storage
  /// plan: only when its wifi_status reports them.
  List<Widget> _dataSettings(WifiStatusMessage st) {
    final maxTile = (st.tileMaxKm != null && st.tileMaxKm! >= 1) ? st.tileMaxKm!.floor().clamp(1, 30) : 30;
    final adsb = (_adsbKm ?? st.adsbKm!.toDouble()).clamp(5.0, 30.0);
    final tile = (_tileKm ?? (st.tileKm ?? 3).toDouble()).clamp(1.0, maxTile.toDouble());
    return [
      const SizedBox(height: 18),
      Text('BOARD DATA', style: OrecchinoType.eyebrow),
      const SizedBox(height: 4),
      _slider(
        title: 'ADS-B radius',
        value: adsb,
        min: 5,
        max: 30,
        caption: 'Around the board\'s home. Only for aircraft near drones: a live drone more than 3 km out '
            'widens it so each has 9 km, up to 30 km.',
        onChanged: (v) => setState(() => _adsbKm = v),
        onDone: (v) => _send(HostCommands.wifiConfig(adsbKm: v.round())),
      ),
      _slider(
        title: 'Map area',
        value: tile,
        min: 1,
        max: maxTile.toDouble(),
        caption: _mapPlan ??
            (st.tileMaxKm == null
                ? 'The storage plan shows after the board\'s next map sync.'
                : 'This board\'s flash holds up to ${st.tileMaxKm!.toStringAsFixed(1)} km of map.'),
        onChanged: (v) => setState(() => _tileKm = v),
        onDone: (v) => _send(HostCommands.wifiConfig(tileKm: v.round())),
      ),
      const SizedBox(height: 8),
    ];
  }

  Widget _slider({
    required String title,
    required double value,
    required double min,
    required double max,
    required String caption,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onDone,
  }) {
    final km = '${value.round()} km';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(title, style: OrecchinoType.bodyStrong)),
          Text(km, style: OrecchinoType.bodyStrong.copyWith(color: OrecchinoColors.aqua)),
        ]),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: max > min ? (max - min).round() : null,
          label: km,
          semanticFormatterCallback: (v) => '$title ${v.round()} kilometres',
          onChanged: max > min ? onChanged : null,
          onChangeEnd: onDone,
        ),
        Text(caption, style: OrecchinoType.caption),
      ]),
    );
  }

  Widget _statusLine(WifiStatusMessage? st) {
    String text;
    Color color = OrecchinoColors.inkMuted;
    var busy = false;
    var on = false;
    if (_joining != null) {
      text = 'Connecting to $_joining…';
      busy = true;
    } else if (st == null) {
      text = 'Asking the detector…';
      busy = true;
    } else {
      switch (st.state) {
        case 'connected':
          text = 'Connected to ${st.ssid ?? 'network'}${st.channel == null ? '' : ' (ch ${st.channel})'}'
              '${st.ip == null ? '' : ' · ${st.ip}'}';
          color = OrecchinoColors.ok;
          on = true;
        case 'connecting':
          text = 'Connecting to ${st.ssid ?? 'network'}…';
          busy = true;
        case 'failed':
          text = 'Could not connect${st.reason == null ? '' : ': ${st.reason}'}';
          color = OrecchinoColors.warning;
        case 'off':
          text = 'Wi-Fi off';
        default:
          text = st.reason == null ? 'Not connected' : 'Not connected (last: ${st.reason})';
      }
    }
    return Row(children: [
      BreathingDot(color: busy ? OrecchinoColors.aqua : color, active: on || busy, busy: busy, size: 8),
      const SizedBox(width: 6),
      Expanded(
        child: Semantics(
          liveRegion: true,
          child: Text(text,
              style: OrecchinoType.bodyStrong
                  .copyWith(color: color == OrecchinoColors.inkMuted ? OrecchinoColors.ink : color)),
        ),
      ),
    ]);
  }

  List<Widget> _rows(List<String> saved) {
    final children = <Widget>[];
    for (final s in saved) {
      if (_nets.any((n) => n.ssid == s)) continue; // shown in the scan list
      children.add(_savedTile(s));
    }
    for (final n in _nets) {
      children.add(_netTile(n, saved.contains(n.ssid) || n.saved));
    }
    if (_scan == WifiScanState.done && _nets.isEmpty) {
      children.add(Padding(
        padding: const EdgeInsets.all(16),
        child: Text('No networks found', style: OrecchinoType.body.copyWith(color: OrecchinoColors.inkMuted)),
      ));
    }
    if (_scan == WifiScanState.failed) {
      children.add(Padding(
        padding: const EdgeInsets.all(16),
        child: Text('Scan failed: ${_scanError ?? 'no answer'}',
            style: OrecchinoType.body.copyWith(color: OrecchinoColors.warning)),
      ));
    }
    children.add(ListTile(
      contentPadding: const EdgeInsets.only(left: 4, right: 8),
      leading: Icon(Icons.add_rounded, color: OrecchinoColors.aqua),
      title: Text('Other network…', style: OrecchinoType.bodyStrong.copyWith(color: OrecchinoColors.aqua)),
      onTap: () => _askPassword(null, secure: true),
    ));
    return children;
  }

  Widget _netTile(WifiNetMessage n, bool isSaved) {
    final bars = n.rssi == null
        ? 0
        : (n.rssi! >= -55
            ? 4
            : n.rssi! >= -65
                ? 3
                : n.rssi! >= -75
                    ? 2
                    : 1);
    final detail = [
      if (isSaved) 'saved',
      n.secure ? 'secured' : 'open',
      if (n.rssi != null) 'signal $bars of 4',
    ].join(' · ');
    return _row(
      leading: SignalBars(level: bars, height: 16),
      title: n.ssid,
      subtitle: detail,
      trailing: n.secure ? Icons.lock_rounded : null,
      onTap: _joining != null
          ? null
          : () => isSaved ? _savedActions(n.ssid) : (n.secure ? _askPassword(n.ssid, secure: true) : _join(n.ssid, '')),
    );
  }

  Widget _savedTile(String ssid) => _row(
        leading: Icon(Icons.bookmark_rounded, color: OrecchinoColors.inkSubtle, size: 20),
        title: ssid,
        subtitle: 'saved, not in range',
        onTap: _joining != null ? null : () => _savedActions(ssid),
      );

  Widget _row(
      {required Widget leading,
      required String title,
      required String subtitle,
      IconData? trailing,
      VoidCallback? onTap}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.white.withValues(alpha: 0.04),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: OrecchinoColors.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(children: [
                SizedBox(width: 26, child: Center(child: leading)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: OrecchinoType.bodyStrong),
                    Text(subtitle, style: OrecchinoType.caption),
                  ]),
                ),
                if (trailing != null) Icon(trailing, size: 16, color: OrecchinoColors.inkSubtle),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  void _savedActions(String ssid) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: OrecchinoColors.raised,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(ssid, style: OrecchinoType.heading)),
          ListTile(
            leading: const Icon(Icons.wifi),
            title: const Text('CONNECT'),
            onTap: () {
              Navigator.pop(ctx);
              _join(ssid, null);
            },
          ),
          ListTile(
            leading: Icon(Icons.delete_outline, color: OrecchinoColors.warning),
            title: const Text('FORGET'),
            onTap: () {
              Navigator.pop(ctx);
              _send(HostCommands.wifiForget(ssid: ssid));
            },
          ),
        ]),
      ),
    );
  }

  Future<void> _askPassword(String? ssid, {required bool secure}) async {
    final ssidCtl = TextEditingController(text: ssid ?? '');
    final pskCtl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ssid == null ? 'Other network' : 'Join $ssid'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          if (ssid == null)
            TextField(controller: ssidCtl, decoration: const InputDecoration(labelText: 'Network name')),
          TextField(
            controller: pskCtl,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'Password (empty for an open network)'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('CANCEL')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('JOIN')),
        ],
      ),
    );
    final name = ssidCtl.text.trim();
    final psk = pskCtl.text;
    ssidCtl.dispose();
    pskCtl.dispose();
    if (ok == true && name.isNotEmpty && mounted) _join(name, psk);
  }

  Widget _modeChip(String mode, String label, String? current) {
    final active = current == mode;
    return ChoiceChip(
      label: Text(label),
      selected: active,
      onSelected: (_) => _setMode(mode),
      showCheckmark: true,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      labelStyle: OrecchinoType.label.copyWith(
        color: active ? OrecchinoColors.aqua : OrecchinoColors.ink,
        fontWeight: active ? FontWeight.w700 : FontWeight.w500,
      ),
      side: BorderSide(color: active ? OrecchinoColors.aqua.withValues(alpha: 0.7) : OrecchinoColors.lineBright),
    );
  }
}
