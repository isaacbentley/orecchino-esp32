// wifi_setup_sheet.dart — T5 Wi-Fi setup over BLE (plan §4.3, commands and
// replies in firmware/common/net_sync.h "HOST COMMANDS").
//
// One subscription for the life of the sheet (initState -> dispose), so a
// rebuild never adds a listener and a swipe-dismiss never leaks one. The
// mode chips show the board's reported mode; every step has a state the
// person can see: scanning, no networks, scan failed, connecting, connected,
// failed with the board's reason, and a refused command.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/link/detector_link.dart';
import '../../core/protocol/commands.dart';
import '../../core/protocol/messages.dart';
import '../../ui/theme.dart';

enum WifiScanState { scanning, done, failed }

class WifiSetupSheet extends StatefulWidget {
  final DetectorLink link;
  final Duration scanTimeout;

  const WifiSetupSheet({super.key, required this.link, this.scanTimeout = const Duration(seconds: 20)});

  static Future<void> show(BuildContext context, DetectorLink link) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: OrecchinoTheme.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => FractionallySizedBox(heightFactor: 0.85, child: WifiSetupSheet(link: link)),
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

  /// For tests: the networks shown.
  List<WifiNetMessage> get networks => List.unmodifiable(_nets);

  @override
  void initState() {
    super.initState();
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
        if (_joining != null && (msg.state == 'connected' || msg.state == 'failed')) _joining = null;
      } else if (msg is WifiErrorMessage) {
        _error = '${msg.command}: ${msg.reason}';
        _joining = null;
        _pendingMode = null;
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
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('T5 WI-FI',
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: OrecchinoTheme.text)),
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ],
            ),
            _statusLine(st),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(_error!, style: const TextStyle(color: OrecchinoTheme.danger, fontSize: 13)),
              ),
            const SizedBox(height: 12),
            const Text('MODE', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: OrecchinoTheme.muted)),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 6, children: [
              _modeChip('sync', 'Sync every ${st?.everyMin ?? 15} min', mode),
              _modeChip('stay', 'Stay connected', mode),
              _modeChip('off', 'Off', mode),
            ]),
            const SizedBox(height: 4),
            const Text(
              'Remote ID Wi-Fi pauses while the board scans or syncs; in Stay connected it hears only the '
              'access point\'s channel. BLE Remote ID is unaffected.',
              style: TextStyle(fontSize: 12, color: OrecchinoTheme.muted),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Expanded(
                  child: Text('NETWORKS',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: OrecchinoTheme.muted)),
                ),
                if (_scan == WifiScanState.scanning)
                  const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, semanticsLabel: 'Scanning'))
                else
                  TextButton(onPressed: _startScan, child: const Text('SCAN AGAIN')),
              ],
            ),
            Expanded(child: _list(saved)),
          ],
        ),
      ),
    );
  }

  Widget _statusLine(WifiStatusMessage? st) {
    String text;
    Color color = OrecchinoTheme.muted;
    if (_joining != null) {
      text = 'Connecting to $_joining…';
    } else if (st == null) {
      text = 'Asking the detector…';
    } else {
      switch (st.state) {
        case 'connected':
          text = 'Connected to ${st.ssid ?? 'network'}${st.channel == null ? '' : ' (ch ${st.channel})'}'
              '${st.ip == null ? '' : ' · ${st.ip}'}';
          color = OrecchinoTheme.ok;
        case 'connecting':
          text = 'Connecting to ${st.ssid ?? 'network'}…';
        case 'failed':
          text = 'Could not connect${st.reason == null ? '' : ': ${st.reason}'}';
          color = OrecchinoTheme.danger;
        case 'off':
          text = 'Wi-Fi off';
        default:
          text = st.reason == null ? 'Not connected' : 'Not connected (last: ${st.reason})';
      }
    }
    return Semantics(
      liveRegion: true,
      child: Text(text, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: color)),
    );
  }

  Widget _list(List<String> saved) {
    final children = <Widget>[];
    for (final s in saved) {
      if (_nets.any((n) => n.ssid == s)) continue; // shown in the scan list
      children.add(_savedTile(s));
    }
    for (final n in _nets) {
      children.add(_netTile(n, saved.contains(n.ssid) || n.saved));
    }
    if (_scan == WifiScanState.done && _nets.isEmpty) {
      children.add(const Padding(
        padding: EdgeInsets.all(16),
        child: Text('No networks found', style: TextStyle(color: OrecchinoTheme.muted)),
      ));
    }
    if (_scan == WifiScanState.failed) {
      children.add(Padding(
        padding: const EdgeInsets.all(16),
        child: Text('Scan failed: ${_scanError ?? 'no answer'}', style: const TextStyle(color: OrecchinoTheme.danger)),
      ));
    }
    children.add(ListTile(
      leading: const Icon(Icons.add, color: OrecchinoTheme.accent),
      title: const Text('Other network…'),
      onTap: () => _askPassword(null, secure: true),
    ));
    return ListView(children: children);
  }

  Widget _netTile(WifiNetMessage n, bool isSaved) {
    final bars = n.rssi == null ? 0 : (n.rssi! >= -55 ? 4 : n.rssi! >= -65 ? 3 : n.rssi! >= -75 ? 2 : 1);
    final detail = [
      if (isSaved) 'saved',
      n.secure ? 'secured' : 'open',
      if (n.rssi != null) 'signal $bars of 4',
    ].join(' · ');
    return ListTile(
      leading: Icon(n.secure ? Icons.wifi_lock : Icons.wifi, color: OrecchinoTheme.accent),
      title: Text(n.ssid, style: const TextStyle(fontWeight: FontWeight.bold)),
      subtitle: Text(detail, style: const TextStyle(fontSize: 12, color: OrecchinoTheme.muted)),
      onTap: _joining != null
          ? null
          : () => isSaved ? _savedActions(n.ssid) : (n.secure ? _askPassword(n.ssid, secure: true) : _join(n.ssid, '')),
    );
  }

  Widget _savedTile(String ssid) => ListTile(
        leading: const Icon(Icons.bookmark, color: OrecchinoTheme.muted),
        title: Text(ssid),
        subtitle: const Text('saved, not in range', style: TextStyle(fontSize: 12, color: OrecchinoTheme.muted)),
        onTap: _joining != null ? null : () => _savedActions(ssid),
      );

  void _savedActions(String ssid) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: OrecchinoTheme.surfaceHigh,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(ssid, style: const TextStyle(fontWeight: FontWeight.bold))),
          ListTile(
            leading: const Icon(Icons.wifi),
            title: const Text('CONNECT'),
            onTap: () {
              Navigator.pop(ctx);
              _join(ssid, null);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: OrecchinoTheme.danger),
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
        backgroundColor: OrecchinoTheme.surface,
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
      selectedColor: OrecchinoTheme.accent.withValues(alpha: 0.25),
      labelStyle: TextStyle(color: active ? OrecchinoTheme.accent : OrecchinoTheme.text, fontSize: 13),
    );
  }
}
