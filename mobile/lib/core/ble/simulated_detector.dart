// simulated_detector.dart — the hardware-free demo detector. It speaks the
// same host lines as the firmware (rx_core.h), answers log_get with the
// real sync protocol (ended records by seq, live contacts with "seq":null,
// log_done next/total/oldest), and the wifi_* commands (including a board's
// "paused":"phone", ADS-B radius and map plan). It also makes up two
// aircraft for the demo's conflict watch: one that comes near a drone, one
// low crossing. Everything it shows is labelled SIMULATED by the screens.
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
  int _adsbKm = 10, _tileKm = 3;
  static const double _tileMaxKm = 14.75;

  /// Ended records held, seq 0..total-1 (the oldest have "rotated out").
  int _total = 12;
  int _oldest = 2;

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
    _line(mapLine()); // as after the board's last sync
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

  /// The demo's stand-in for the phone's own receiver: some of the demo's
  /// drones heard by "this phone" too, so the sensor chips have both.
  final _phoneController = StreamController<RidMessage>.broadcast();
  Stream<RidMessage> get phoneFrames => _phoneController.stream;
  int _ticks = 0;

  void _phone(Map<String, dynamic> json, String src, int rssi) {
    final copy = Map<String, dynamic>.from(json)
      ..['src'] = src
      ..['rssi'] = rssi
      ..remove('phy')
      ..remove('ch');
    final m = HostMessage.parse(jsonEncode(copy));
    if (m is RidMessage && !_phoneController.isClosed) _phoneController.add(m);
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
      case 'log_clear':
        // As the firmware: the records go, the seqs start again, and every
        // app hears log_cleared.
        _total = 0;
        _oldest = 0;
        Timer(const Duration(milliseconds: 300), () => _line({'type': 'log_cleared'}));
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
            _line({
              'type': 'wifi_status',
              'state': 'failed',
              'ssid': ssid,
              'reason': 'wrong password',
              'mode': _wifiMode
            });
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
      case 'wifi_config':
        final a = c['adsb_km'], t = c['tile_km'];
        if (a is! num && t is! num) {
          _line({'type': 'wifi_err', 'cmd': 'wifi_config', 'reason': 'nothing to set'});
          return;
        }
        if (a is num) _adsbKm = a.round().clamp(5, 30);
        if (t is num) _tileKm = t.round().clamp(1, _tileMaxKm.floor());
        _status();
      case 'wifi_status':
        _status();
        _line(mapLine());
    }
  }

  /// The board's last "synced" line, as a T5 broadcasts it after a sync.
  Map<String, dynamic> mapLine() => {
        'type': 'net',
        'state': 'synced',
        'ok': ['time', 'tfr', 'adsb', 'tiles'],
        'failed': <String>[],
        'adsb_km': _adsbKm.toDouble(),
        'map': 'Map: $_tileKm km z12-15; ${(0.09 * _tileKm * _tileKm).toStringAsFixed(1)} MB of 11.9 MB',
        'map_tiles': 40 * _tileKm * _tileKm,
        'map_have': 40 * _tileKm * _tileKm,
        'tile_max_km': _tileMaxKm,
      };

  // The demo phone is connected over an encrypted link, so the board pauses
  // its automatic Wi-Fi windows, as a real T5 does.
  void _status() => _line({
        'type': 'wifi_status',
        'state': _wifiMode == 'off' ? 'off' : 'idle',
        'mode': _wifiMode,
        'every_min': 15,
        'adsb_km': _adsbKm,
        'tile_km': _tileKm,
        'tile_max_km': _tileMaxKm,
        if (_wifiMode != 'off') 'paused': 'phone',
        'saved': _savedNets,
      });

  void _tick() {
    if (!_running) return;
    _ticks++;
    _angle += 0.05;
    _emit(HeartbeatMessage(
      uptimeMs: DateTime.now().millisecondsSinceEpoch,
      wifiFrames: 450,
      bleAdvs: 1200,
      ridCount: 3,
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
    final d1 = <String, dynamic>{
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
      'self_id': {'desc_type': 0, 'desc': 'Survey flight'},
      // The operator at the take-off point, 350 m south-west of the circle's
      // centre (as format_rid writes the System message).
      'system': {
        'op_lat': centerLat - 0.0022,
        'op_lon': centerLon - 0.0029,
        'op_alt': 21.5,
        'op_loc_type': 0,
        'area_count': 1,
        'ts': _sysTs(),
      },
      'op_id': {'id_type': 0, 'id': 'PILOT-US-48201'},
      'auth': {'type': 1, 'len': 90, 'pages': 5, 'state': 'id_valid'},
    };
    _line(d1);
    // This phone hears it too (phone-ble4), as the demo's own phone receiver.
    _phone(d1, 'phone-ble4', -81);

    // Drone 2: hovering, speed and direction unknown (firmware markers).
    final d2 = <String, dynamic>{
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
      // Its operator far away (2.6 km south-east): live GNSS, unusual but
      // possible, and worth seeing.
      'system': {
        'op_lat': centerLat - 0.019,
        'op_lon': centerLon + 0.021,
        'op_alt': 18.0,
        'op_loc_type': 1,
        'area_count': 1,
        'ts': _sysTs(),
      },
    };
    _line(d2);
    // This phone hears it too (phone-ble5), as the demo's own phone receiver.
    if (_ticks % 2 == 0) _phone(d2, 'phone-ble5', -88);

    // Drone 3: beyond the 3 km range (4.3 km north-east), on the ring's edge.
    _line({
      'type': 'rid',
      'src': 'ble',
      'mac': 'C1:22:33:44:55:66',
      'rssi': -91,
      'phy': 'coded',
      'proto': 2,
      'basic_id': [
        {'id_type': 1, 'ua_type': 2, 'uas_id': '1581F6Z9C7B3F4E1'}
      ],
      'loc': {
        'status': 2,
        'lat': centerLat + 0.0275,
        'lon': centerLon + 0.0345,
        'alt_geo': 90.0,
        'alt_baro': 75.5,
        'height': 80.0,
        'height_ref': 0,
        'speed': 6.5,
        'dir': 200.0,
        'ts': (DateTime.now().toUtc().minute * 60 + DateTime.now().toUtc().second).toDouble(),
        'vspeed': -0.5,
      },
      'system': {
        'op_lat': centerLat + 0.0262,
        'op_lon': centerLon + 0.0338,
        'op_alt': 12.0,
        'op_loc_type': 1,
        'area_count': 1,
        'ts': _sysTs(),
      },
      'op_id': {'id_type': 0, 'id': 'FIN87astrdge12k8'},
    });
  }

  /// ODID system time: seconds since 2019-01-01 00:00 UTC.
  static int _sysTs() => DateTime.now().toUtc().difference(DateTime.utc(2019)).inSeconds;

  /// Made-up aircraft for the demo, on a 6-minute cycle: a Cessna that
  /// passes drone 1 low and slow (low traffic as it comes within 3 km, then
  /// traffic near drone 1), and three minutes later a helicopter crossing
  /// 2 km north of you below 460 m (low traffic only). Quiet in between.
  List<TrafficAircraft> demoAircraft(int nowMs) {
    final t = (nowMs ~/ 1000) % 360;
    double centred(int c) => (((t - c + 180) % 360) - 180).toDouble(); // seconds from the pass's middle
    (double, double) along(double metres, double trk, double northM) {
      final r = trk * math.pi / 180;
      final lat = centerLat + (northM + metres * math.cos(r)) / 111320.0;
      final lon = centerLon + (metres * math.sin(r)) / (111320.0 * math.cos(centerLat * math.pi / 180));
      return (lat, lon);
    }

    const cTrk = 250.0, hTrk = 90.0;
    final (cLat, cLon) = along(centred(120) * 60.0, cTrk, 110); // 60 m/s
    final (hLat, hLon) = along(centred(300) * 45.0, hTrk, 2000); // 45 m/s
    return [
      TrafficAircraft(
        hex: 'a1b2c3',
        callsign: 'N123SIM',
        type: 'C172',
        lat: cLat,
        lon: cLon,
        altGeomM: 200,
        altBaroM: 185,
        gsMps: 60,
        trackDeg: cTrk,
        vsMps: -2.5,
        seenMs: nowMs - 2000,
      ),
      TrafficAircraft(
        hex: 'a7c0de',
        callsign: 'N911SIM',
        type: 'EC35',
        lat: hLat,
        lon: hLon,
        altGeomM: 300,
        altBaroM: 290,
        gsMps: 45,
        trackDeg: hTrk,
        vsMps: 0,
        seenMs: nowMs - 1500,
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
    // The three drones in the air now: live, no seq yet.
    for (final (id, mac, auth) in const [
      ('1581F204C68D9A11', 'E2:01:23:45:67:89', 'id_valid'),
      ('1581F999E412A002', 'D4:88:55:AA:BB:CC', 'none'),
      ('1581F6Z9C7B3F4E1', 'C1:22:33:44:55:66', 'none'),
    ]) {
      _line({
        'type': 'log',
        'seq': null,
        'i': null,
        'active': true,
        'uas': id,
        'mac': mac,
        'srcs': mac.startsWith('D4') ? 1 : 4,
        'fmts': 1,
        'ua_type': 2,
        'first': now - 300,
        'last': now,
        'dur': 300,
        'peak_rssi': -66,
        'auth_state': auth,
        'tfr': false,
        'emerg': false,
        'msgs': 300,
      });
    }
    _line({
      'type': 'log_done',
      'n': _total - _oldest,
      'live': 3,
      'total': _total,
      'clock': true,
      'next': _total,
      'oldest': _oldest,
    });
  }

  void dispose() {
    stop();
    _messageController.close();
    _phoneController.close();
  }
}
