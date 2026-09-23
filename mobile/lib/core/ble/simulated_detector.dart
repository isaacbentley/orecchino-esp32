// simulated_detector.dart — the hardware-free demo detector. It speaks the
// same host lines as the firmware (rx_core.h), answers log_get with the
// real sync protocol (ended records by seq, live contacts with "seq":null,
// log_done next/total/oldest), and the wifi_* commands. It also makes up
// one aircraft for the demo's ADS-B layer. Everything it shows is labelled
// SIMULATED by the screens.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import '../link/detector_link.dart';
import '../protocol/messages.dart';
import '../traffic/traffic_rules.dart';

class SimulatedDetector implements DetectorLink {
  final _messageController = StreamController<HostMessage>.broadcast();
  @override
  Stream<HostMessage> get messages => _messageController.stream;

  Timer? _timer;
  double _angle = 0;
  bool _running = false;
  bool _feedOn = true;
  String _wifiMode = 'sync';
  final List<String> _savedNets = ['Hangar-Secure'];

  /// Ended records held, seq 0..total-1 (the oldest have "rotated out").
  int _total = 12;
  final int _oldest = 2;

  // Where the demo happens: Crissy Field, San Francisco. The phone's
  // position in demo mode (and only in demo mode).
  static const double centerLat = 37.8039;
  static const double centerLon = -122.4640;

  static const info = DeviceInfoMessage(
    board: 'simulated',
    firmware: 'orecchino',
    version: '0.7.0-sim',
    capabilities: ['log', 'log_since', 'tfr', 'wifi', 'traffic'],
    proto: 1,
  );

  @override
  bool get isReady => _running;

  void start() {
    stop();
    _running = true;
    _emit(info);
    _timer = Timer.periodic(const Duration(milliseconds: 1000), (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _running = false;
  }

  void _emit(HostMessage m) {
    if (!_messageController.isClosed) _messageController.add(m);
  }

  void _line(Map<String, dynamic> json) {
    final m = HostMessage.parse(jsonEncode(json));
    if (m != null) _emit(m);
  }

  @override
  Future<void> send(String command) async {
    if (!_running) throw const LinkNotReady('the demo detector is off');
    handleCommand(command);
  }

  void handleCommand(String jsonCmd) {
    Map<String, dynamic> c;
    try {
      c = jsonDecode(jsonCmd) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (c['cmd']) {
      case 'feed':
        _feedOn = c['on'] == true;
        _line({'type': 'feed_status', 'src': 1, 'on': _feedOn});
      case 'log_get':
        _streamHistory((c['since'] as num?)?.toInt() ?? 0);
      case 'wifi_scan':
        Timer(const Duration(milliseconds: 900), () {
          _line({'type': 'wifi_net', 'ssid': 'Hangar-Secure', 'rssi': -58, 'secure': true, 'saved': true});
          _line({'type': 'wifi_net', 'ssid': 'Airfield-Guest', 'rssi': -62, 'secure': false});
          _line({'type': 'wifi_scan_done', 'n': 2});
        });
      case 'wifi_join':
        final ssid = c['ssid'] as String? ?? '';
        _line({'type': 'wifi_status', 'state': 'connecting', 'ssid': ssid, 'mode': _wifiMode});
        Timer(const Duration(seconds: 2), () {
          final psk = c['psk'] as String? ?? '';
          if (ssid == 'Hangar-Secure' && psk.length < 8) {
            _line({'type': 'wifi_status', 'state': 'failed', 'ssid': ssid, 'reason': 'wrong password', 'mode': _wifiMode});
          } else {
            if (!_savedNets.contains(ssid)) _savedNets.add(ssid);
            _line({
              'type': 'wifi_status',
              'state': 'connected',
              'ssid': ssid,
              'ip': '192.168.4.23',
              'ch': 6,
              'mode': _wifiMode,
              'saved': _savedNets,
            });
          }
        });
      case 'wifi_forget':
        _savedNets.remove(c['ssid']);
        _status();
      case 'wifi_mode':
        final m = c['mode'];
        if (m is String && const ['off', 'sync', 'stay'].contains(m)) _wifiMode = m;
        _status();
      case 'wifi_status':
        _status();
    }
  }

  void _status() => _line({
        'type': 'wifi_status',
        'state': _wifiMode == 'off' ? 'off' : 'idle',
        'mode': _wifiMode,
        'every_min': 15,
        'saved': _savedNets,
      });

  void _tick() {
    if (!_running) return;
    _angle += 0.05;
    _emit(HeartbeatMessage(
      uptimeMs: DateTime.now().millisecondsSinceEpoch,
      wifiFrames: 450,
      bleAdvs: 1200,
      ridCount: 2,
      dropped: 0,
      channel: 6,
      bleActive: true,
      bleExtActive: true,
    ));
    if (!_feedOn) return;

    // Drone 1: circling at 100 m above take-off, signed ID.
    final d1Lat = centerLat + 0.005 * math.cos(_angle);
    final d1Lon = centerLon + 0.006 * math.sin(_angle);
    final d1Track = ((_angle * 180 / math.pi) + 90) % 360;
    _line({
      'type': 'rid',
      'src': 'ble',
      'mac': 'E2:01:23:45:67:89',
      'rssi': -68,
      'phy': 'coded',
      'proto': 2,
      'basic_id': [
        {'id_type': 1, 'ua_type': 2, 'uas_id': '1581F204C68D9A11'}
      ],
      'loc': {
        'status': 2,
        'lat': d1Lat,
        'lon': d1Lon,
        'alt_geo': 120.0,
        'alt_baro': -1000.0,
        'height': 100.0,
        'height_ref': 0,
        'speed': 12.0,
        'dir': d1Track,
        'ts': 12.5,
        'vspeed': 0.2,
      },
      'op_id': {'id_type': 0, 'id': 'PILOT-US-48201'},
      'auth': {'type': 1, 'len': 90, 'pages': 5, 'state': 'id_valid'},
    });

    // Drone 2: hovering, speed and direction unknown (firmware markers).
    _line({
      'type': 'rid',
      'src': 'wifi',
      'mac': 'D4:88:55:AA:BB:CC',
      'rssi': -74,
      'ch': 6,
      'proto': 2,
      'basic_id': [
        {'id_type': 1, 'ua_type': 2, 'uas_id': '1581F999E412A002'}
      ],
      'loc': {
        'status': 2,
        'lat': centerLat - 0.003,
        'lon': centerLon + 0.004,
        'alt_geo': 60.0,
        'alt_baro': -1000.0,
        'height': 50.0,
        'height_ref': 1,
        'speed': -1,
        'dir': -1,
        'ts': -1,
      },
    });
  }

  /// A made-up aircraft for the demo: passes drone 1 low and slow.
  List<TrafficAircraft> demoAircraft(int nowMs) {
    final t = (nowMs ~/ 1000) % 240; // one pass every 4 minutes
    final along = (t - 120) * 60.0; // metres along its track, 60 m/s
    const trk = 250.0;
    final lat = centerLat + 0.001 + (along * math.cos(trk * math.pi / 180)) / 111320.0;
    final lon = centerLon + (along * math.sin(trk * math.pi / 180)) / (111320.0 * math.cos(centerLat * math.pi / 180));
    return [
      TrafficAircraft(
        hex: 'a1b2c3',
        callsign: 'N123SIM',
        type: 'C172',
        lat: lat,
        lon: lon,
        altGeomM: 200,
        altBaroM: 185,
        gsMps: 60,
        trackDeg: trk,
        vsMps: -2.5,
        seenMs: nowMs - 2000,
      ),
    ];
  }

  void _streamHistory(int since) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (_running) _total++; // a contact ended since the last ask
    final from = math.max(since, _oldest);
    for (var s = from; s < _total; s++) {
      _line({
        'type': 'log',
        'seq': s,
        'i': s,
        'active': false,
        'uas': '1581F204C68D9A${(10 + s % 90).toString()}',
        'mac': 'E2:01:23:45:67:${(s % 100).toString().padLeft(2, '0')}',
        'srcs': 1,
        'fmts': 1,
        'ua_type': 2,
        'first': now - 3600 * (_total - s),
        'last': now - 3600 * (_total - s) + 600,
        'dur': 600,
        'lat': centerLat + 0.002 * (s % 5),
        'lon': centerLon - 0.002 * (s % 5),
        'max_h': 118,
        'peak_rssi': -65 + s % 7,
        'auth_state': s % 4 == 0 ? 'id_valid' : 'none',
        'tfr': false,
        'emerg': s % 9 == 0,
        'msgs': 150,
      });
    }
    // The two drones in the air now: live, no seq yet.
    for (final id in ['1581F204C68D9A11', '1581F999E412A002']) {
      _line({
        'type': 'log',
        'seq': null,
        'i': null,
        'active': true,
        'uas': id,
        'mac': id.endsWith('11') ? 'E2:01:23:45:67:89' : 'D4:88:55:AA:BB:CC',
        'first': now - 300,
        'last': now,
        'dur': 300,
        'peak_rssi': -66,
        'auth_state': id.endsWith('11') ? 'id_valid' : 'none',
        'tfr': false,
        'emerg': false,
        'msgs': 300,
      });
    }
    _line({
      'type': 'log_done',
      'n': _total - _oldest,
      'live': 2,
      'total': _total,
      'clock': true,
      'next': _total,
      'oldest': _oldest,
    });
  }

  void dispose() {
    stop();
    _messageController.close();
  }
}
