// drone_details.dart — every field a drone's Remote ID broadcast carries, in
// words, grouped for the details sheet: Identity, Position, Motion,
// Operator, System, Signal, Authentication, Alerts. Pure (no widgets), so
// the tests can check each field.
//
// Sources: a live contact (every field of the firmware's rid lines,
// firmware/common/rx_core.h format_rid, kept by contact_tracker.dart), or
// a History record (what the match log keeps: format_log_rec). A field
// that was not broadcast, or that the line does not carry, reads "not
// reported": never a made-up value and never the firmware's unknown
// markers (messages.dart turns those into null). Names follow ASTM F3411 /
// ASD-STAN prEN 4709-002 and the Mac app (app/Sources/Orecchino).
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import '../../core/geo.dart';
import '../../core/live/contact_tracker.dart';
import '../../core/live/sensors.dart';
import '../../core/protocol/messages.dart';
import '../../core/traffic/traffic_rules.dart';
import '../../core/traffic/traffic_words.dart';
import '../../core/uas_models.dart';
import '../../data/db.dart';

const notReported = 'not reported';

/// How a value is drawn: plain, or in an alert colour (the words say it too).
enum DetailTone { plain, ok, caution, warning, muted }

class DetailRow {
  final String label;
  final String? value; // null: not reported
  final String? secondary; // a smaller second line
  final String? copy; // text for the copy button
  final DetailTone tone;
  final bool mono; // numbers and identifiers

  const DetailRow(this.label, this.value, {this.secondary, this.copy, this.tone = DetailTone.plain, this.mono = false});

  bool get reported => value != null && value!.isNotEmpty;
  String get shown => reported ? value! : notReported;

  /// What a screen reader says for the row.
  String get semantics => [label, shown, if (secondary != null) secondary!].join(', ');
}

class DetailSection {
  final String title;
  final List<DetailRow> rows;
  const DetailSection(this.title, this.rows);
}

/// Everything the sheet shows for one drone.
class DroneDetails {
  final String title; // 'D9A11'
  final String? fullId; // the UAS ID, else the MAC
  final String? model; // 'DJI Mini 4 Pro' or the maker
  final List<String> alerts; // alert words for the header, most urgent first
  final DetailTone alertTone;
  final List<DetailSection> sections;
  final List<double> rssiSeries; // for the Signal section's sparkline
  final bool live;

  /// The sensors that heard it (live: in the last minute).
  final List<SensorChip> sensors;

  const DroneDetails({
    required this.title,
    required this.fullId,
    required this.model,
    required this.alerts,
    required this.alertTone,
    required this.sections,
    this.rssiSeries = const [],
    required this.live,
    this.sensors = const [],
  });

  DetailSection? section(String title) => sections.where((s) => s.title == title).firstOrNull;
  DetailRow? row(String section, String label) =>
      this.section(section)?.rows.where((r) => r.label == label).firstOrNull;
}

/// ODID names (F3411-22a).
abstract final class RidWords {
  static const _uaTypes = [
    'Unknown', 'Aeroplane', 'Multirotor', 'Gyroplane', 'Hybrid lift', 'Ornithopter', 'Glider', 'Kite', //
    'Free balloon', 'Captive balloon', 'Airship', 'Parachute', 'Rocket', 'Tethered', 'Ground obstacle', 'Other',
  ];
  static const _idTypes = [
    'None',
    'Serial number (CTA-2063-A)',
    'CAA registration',
    'UTM UUID',
    'Specific session ID',
  ];
  static const _statuses = ['Undeclared', 'On ground', 'Airborne', 'Emergency reported', 'Remote ID system failure'];

  static String? uaType(int? i) => i == null ? null : (i >= 0 && i < _uaTypes.length ? _uaTypes[i] : 'Type $i');
  static String? idType(int? i) => i == null ? null : (i >= 0 && i < _idTypes.length ? _idTypes[i] : 'Type $i');
  static String? status(int? i) => i == null ? null : (i >= 0 && i < _statuses.length ? _statuses[i] : 'Status $i');

  static String? heightRef(int? r) => switch (r) { 0 => 'above take-off', 1 => 'above ground', _ => null };

  /// Horizontal accuracy (F3411 table: code -> "< x").
  static String? hAcc(int? c) => switch (c) {
        null || 0 => null,
        1 => '< 18.5 km',
        2 => '< 7.4 km',
        3 => '< 3.7 km',
        4 => '< 1.9 km',
        5 => '< 926 m',
        6 => '< 556 m',
        7 => '< 185 m',
        8 => '< 93 m',
        9 => '< 30 m',
        10 => '< 10 m',
        11 => '< 3 m',
        12 => '< 1 m',
        _ => 'code $c',
      };

  /// Vertical and barometric accuracy.
  static String? vAcc(int? c) => switch (c) {
        null || 0 => null,
        1 => '< 150 m',
        2 => '< 45 m',
        3 => '< 25 m',
        4 => '< 10 m',
        5 => '< 3 m',
        6 => '< 1 m',
        _ => 'code $c',
      };

  static String? speedAcc(int? c) => switch (c) {
        null || 0 => null,
        1 => '< 10 m/s',
        2 => '< 3 m/s',
        3 => '< 1 m/s',
        4 => '< 0.3 m/s',
        _ => 'code $c',
      };

  /// Timestamp accuracy: code x 0.1 s.
  static String? tsAcc(int? c) => c == null || c == 0 ? null : '< ${(c / 10).toStringAsFixed(1)} s';

  static String? opLocType(int? t) => switch (t) {
        0 => 'Take-off location',
        1 => 'Live (operator GNSS)',
        2 => 'Fixed location',
        null => null,
        _ => 'Type $t',
      };

  static String? opIdType(int? t) => t == null ? null : (t == 0 ? 'Operator ID' : 'Type $t');

  static String? selfIdType(int? t) => switch (t) {
        0 => 'Text description',
        1 => 'Emergency description',
        2 => 'Extended status',
        null => null,
        _ => 'Type $t',
      };

  static String? authType(int? t) => switch (t) {
        0 => 'None',
        1 => 'UAS ID signature',
        2 => 'Operator ID signature',
        3 => 'Message set signature',
        4 => 'Network Remote ID',
        5 => 'Specific authentication',
        null => null,
        _ => 'Type $t',
      };

  /// The signature verdict, phrased so it cannot be read as "the position
  /// is true" (the Mac's authLabel).
  static String? authVerdict(String? s) => switch (s) {
        AuthState.idValid => 'ID signature valid (the position is not signed)',
        AuthState.invalid => 'ID SIGNATURE INVALID',
        AuthState.partial => 'Pages incomplete: not checked yet',
        AuthState.unknownKey => 'Signed, key not trusted',
        AuthState.testKey => 'TEST KEY: proves nothing',
        AuthState.none => 'Not signed',
        null => null,
        _ => s,
      };

  /// Classification: "EU · Specific · C2" (class codes 1-7 are C0-C6);
  /// an undeclared category or class is said so.
  static String? classification(int? type, int? cat, int? cls) {
    if (type == null) return null;
    if (type == 0) return 'Undeclared';
    if (type != 1) return 'Type $type';
    final c = switch (cat) {
      1 => 'Open',
      2 => 'Specific',
      3 => 'Certified',
      null || 0 => 'category undeclared',
      _ => 'category $cat',
    };
    final k = cls == null || cls == 0 ? 'class undeclared' : (cls <= 7 ? 'C${cls - 1}' : 'class code $cls');
    return 'EU · $c · $k';
  }

  /// The TFR a contact is in, as a row value: "IN TFR 6/3221".
  static String inTfr(String? id) => id == null || id.isEmpty ? 'IN TFR' : 'IN TFR $id';

  /// "ASTM F3411 v2", "GB 46750-2025".
  static String? protocol(int? proto, String? fmt) {
    if (fmt == 'gb46750') return 'GB 46750-2025';
    if (proto == null) return null;
    return 'ASTM F3411 / ASD-STAN, protocol v$proto';
  }

  /// '107° ESE'
  static String bearing(double b) => '${b.round() % 360}° ${compass16(b)}';

  static String compass16(double d) {
    const n = ['N', 'NNE', 'NE', 'ENE', 'E', 'ESE', 'SE', 'SSE', 'S', 'SSW', 'SW', 'WSW', 'W', 'WNW', 'NW', 'NNW'];
    var i = ((d + 11.25) / 22.5).floor() % 16;
    if (i < 0) i += 16;
    return n[i];
  }
}

String _m(double v, {int dp = 0}) => '${v.toStringAsFixed(dp)} m';
String _coord(double lat, double lon, int dp) => '${lat.toStringAsFixed(dp)}, ${lon.toStringAsFixed(dp)}';

/// '2 h 5 min', '3 min 10 s', '12 s'
String durationWords(int seconds) {
  final s = math.max(0, seconds);
  if (s < 60) return '$s s';
  if (s < 3600) return '${s ~/ 60} min ${s % 60} s';
  return '${s ~/ 3600} h ${(s % 3600) ~/ 60} min';
}

/// '2026-09-23 20:15:04 UTC'
String utcWords(DateTime t) {
  final u = t.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${u.year}-${two(u.month)}-${two(u.day)} ${two(u.hour)}:${two(u.minute)}:${two(u.second)} UTC';
}

/// '529 m, 107° ESE' (distance and bearing from a to b).
String _fromTo(double lat1, double lon1, double lat2, double lon2) =>
    '${Geo.rangeText(Geo.distanceM(lat1, lon1, lat2, lon2))}, ${RidWords.bearing(Geo.bearingDeg(lat1, lon1, lat2, lon2))}';

String _sources(Iterable<String> srcs, Map<String, String?> phy, int? channel) {
  final out = <String>[];
  for (final s in srcs.toList()..sort()) {
    switch (s) {
      case 'ble':
        final p = phy['ble'];
        out.add(switch (p) {
          'coded' => 'Bluetooth LE Long Range (coded PHY)',
          '2m' => 'Bluetooth LE (2M PHY)',
          '1m' => 'Bluetooth LE (1M PHY)',
          _ => 'Bluetooth LE',
        });
      case 'wifi':
        out.add('Wi-Fi beacon${channel == null ? '' : ' (ch $channel)'}');
      case 'nan':
        out.add('Wi-Fi NaN');
      case 'phone-ble4':
        out.add('this phone, Bluetooth 4');
      case 'phone-ble5':
        out.add('this phone, Bluetooth 5');
      case 'phone-coded':
        out.add('this phone, Bluetooth 5 long range');
      case 'phone-nan':
        out.add('this phone, Wi-Fi NAN');
      case 'phone-beacon':
        out.add('this phone, Wi-Fi beacons (slow)');
      default:
        out.add(s);
    }
  }
  return out.join(' · ');
}

/// The details of a live contact. [alerts]: the traffic alerts naming it;
/// [conflictWatch]: the rules' status line (null when ADS-B is off).
DroneDetails liveDroneDetails(
  Contact c, {
  required int nowMs,
  ObserverFix? observer,
  List<TrafficAlert> alerts = const [],
  String? conflictWatch,
  List<double> rssiSeries = const [],
}) {
  final l = c.loc;
  final sys = c.system;
  final id = c.uasId;
  final model = id == null ? null : (UasModels.model(id) ?? UasModels.manufacturer(id));
  final basics = c.basicIds.where((b) => b.uasId.isNotEmpty).toList();
  final primary = basics.where((b) => b.uasId == id).firstOrNull ?? basics.firstOrNull;
  final other = basics.where((b) => b != primary).toList();

  final alertWords = <String>[
    for (final a in alerts) trafficAction(a),
    if (c.emergency) 'EMERGENCY REPORTED',
    if (c.inTfr == true) RidWords.inTfr(c.tfrId),
    if (c.isAuthInvalid) 'ID SIGNATURE INVALID',
    if (c.authState == AuthState.testKey) 'TEST KEY',
  ];
  final tone = c.emergency || alerts.any((a) => a.level == TrafficLevel.warning)
      ? DetailTone.warning
      : (alertWords.isEmpty || alertWords.every((w) => w == 'TEST KEY') ? DetailTone.muted : DetailTone.caution);

  final identity = DetailSection('Identity', [
    DetailRow('UAS ID', id, mono: true, copy: id),
    DetailRow('ID type', RidWords.idType(primary?.idType)),
    for (final b in other) DetailRow('Also broadcast', '${b.uasId} (${RidWords.idType(b.idType)})', mono: true),
    DetailRow('Make and model', model,
        secondary: model == null ? null : 'From the serial number\'s maker code (local table)'),
    DetailRow('UA type', RidWords.uaType(primary?.uaType)),
    DetailRow('Classification', RidWords.classification(sys?.classType, sys?.catEu, sys?.classEu)),
    DetailRow('Operator ID', c.operatorId, mono: true, secondary: RidWords.opIdType(c.opIdType), copy: c.operatorId),
    DetailRow('Self-ID', c.selfDesc, secondary: RidWords.selfIdType(c.selfDescType)),
  ]);

  final posAge = c.posMs == null ? null : ((nowMs - c.posMs!) / 1000).round();
  final position = DetailSection('Position', [
    DetailRow('Status', RidWords.status(l?.status), tone: l?.status == 3 ? DetailTone.warning : DetailTone.plain),
    DetailRow('Latitude, longitude', c.hasPosition ? _coord(c.lat!, c.lon!, 7) : null,
        mono: true, copy: c.hasPosition ? _coord(c.lat!, c.lon!, 7) : null),
    DetailRow(
        'From you',
        c.rangeM == null || c.bearingDeg == null
            ? null
            : '${Geo.rangeText(c.rangeM!)}, ${RidWords.bearing(c.bearingDeg!)}',
        secondary: c.hasPosition && observer == null ? 'Needs this phone\'s position' : null),
    DetailRow('Geodetic altitude', l?.altGeo == null ? null : _m(l!.altGeo!, dp: 1), secondary: 'WGS-84 ellipsoid'),
    DetailRow('Pressure altitude', l?.altBaro == null ? null : _m(l!.altBaro!, dp: 1)),
    DetailRow('Height',
        l?.height == null ? null : '${_m(l!.height!, dp: 1)} ${RidWords.heightRef(l.heightRef) ?? ''}'.trim()),
    DetailRow('Horizontal accuracy', RidWords.hAcc(l?.hAcc)),
    DetailRow('Vertical accuracy', RidWords.vAcc(l?.vAcc)),
    DetailRow('Pressure altitude accuracy', RidWords.vAcc(l?.baroAcc)),
    DetailRow('Speed accuracy', RidWords.speedAcc(l?.spdAcc)),
    DetailRow('Position time', l?.timestamp == null ? null : '${l!.timestamp!.toStringAsFixed(1)} s past the hour',
        secondary: posAge == null ? null : 'Position heard $posAge s ago'),
    DetailRow('Time accuracy', RidWords.tsAcc(l?.tsAcc)),
  ]);

  final vs = l?.vspeed;
  final motion = DetailSection('Motion', [
    DetailRow('Speed', l?.speed == null ? null : '${l!.speed!.toStringAsFixed(1)} m/s',
        secondary: l?.speed == null ? null : '${(l!.speed! * 3.6).toStringAsFixed(0)} km/h over the ground'),
    DetailRow('Vertical speed', vs == null ? null : '${vs >= 0 ? '+' : ''}${vs.toStringAsFixed(1)} m/s',
        secondary: vs == null ? null : (vs > 0.2 ? 'climbing' : (vs < -0.2 ? 'descending' : 'level'))),
    DetailRow('Track', l?.dir == null ? null : RidWords.bearing(l!.dir!),
        secondary: l?.dir == null ? null : 'degrees true'),
    DetailRow(
        'Range trend',
        c.closing == null
            ? null
            : (c.closing! ? 'closing ${c.rangeRateMps!.abs().toStringAsFixed(1)} m/s' : 'opening')),
  ]);

  final hasOp = c.opLat != null && c.opLon != null;
  final operator = DetailSection('Operator', [
    DetailRow('Location', hasOp ? _coord(c.opLat!, c.opLon!, 7) : null,
        mono: true,
        copy: hasOp ? _coord(c.opLat!, c.opLon!, 7) : null,
        secondary: RidWords.opLocType(sys?.operatorLocType)),
    DetailRow('Altitude', sys?.operatorAltGeo == null ? null : _m(sys!.operatorAltGeo!, dp: 1),
        secondary: sys?.operatorAltGeo == null ? null : 'Geodetic (WGS-84)'),
    DetailRow('From the drone', hasOp && c.hasPosition ? _fromTo(c.lat!, c.lon!, c.opLat!, c.opLon!) : null,
        tone: hasOp && c.hasPosition && Geo.distanceM(c.lat!, c.lon!, c.opLat!, c.opLon!) > 15000
            ? DetailTone.caution
            : DetailTone.plain,
        secondary: hasOp && c.hasPosition && Geo.distanceM(c.lat!, c.lon!, c.opLat!, c.opLon!) > 15000
            ? 'Implausibly far from its drone'
            : null),
    DetailRow('From you', hasOp && observer != null ? _fromTo(observer.lat, observer.lon, c.opLat!, c.opLon!) : null),
  ]);

  final system = DetailSection('System', [
    DetailRow('Area count', sys?.areaCount?.toString()),
    DetailRow('Area radius', sys?.areaRadius == null ? null : _m(sys!.areaRadius!)),
    DetailRow('Area ceiling', sys?.areaCeiling == null ? null : _m(sys!.areaCeiling!, dp: 1)),
    DetailRow('Area floor', sys?.areaFloor == null ? null : _m(sys!.areaFloor!, dp: 1)),
    DetailRow('Classification', RidWords.classification(sys?.classType, sys?.catEu, sys?.classEu)),
    DetailRow(
        'System time',
        sys?.timestamp == null || sys!.timestamp! <= 0
            ? null
            : utcWords(DateTime.utc(2019).add(Duration(seconds: sys.timestamp!)))),
  ]);

  final first = DateTime.fromMillisecondsSinceEpoch(c.firstSeenMs);
  final chips = sensorChips(c, nowMs);
  final signal = DetailSection('Signal', [
    DetailRow('Heard by', sensorWords(chips)?.replaceFirst('heard by ', ''),
        secondary: chips.isEmpty ? 'No sensor in the last minute' : null),
    // Each sensor: its own signal and when it last heard the drone.
    for (final h in chips)
      DetailRow(
        h.label.replaceAll(RegExp(r' · \d+ s$'), ''),
        h.rssi == null ? 'heard' : '${h.rssi} dBm',
        mono: h.rssi != null,
        tone: h.fresh ? DetailTone.plain : DetailTone.muted,
        secondary: 'last heard ${h.ageS.round()} s ago${h.phone ? '' : ', via ${h.detector}'}',
      ),
    DetailRow('Transports', c.sources.isEmpty ? null : _sources(c.sources, c.phyBySource, c.channel)),
    DetailRow('Signal now', c.rssi == null ? null : '${c.rssi} dBm', mono: true),
    DetailRow('Peak signal', c.peakRssi == null ? null : '${c.peakRssi} dBm', mono: true),
    DetailRow(c.macs.length > 1 ? 'MAC addresses' : 'MAC address',
        c.macs.isEmpty ? null : (c.macs.toList()..sort()).join('\n'),
        mono: true, secondary: c.macs.length > 1 ? 'Randomised or several radios' : null),
    DetailRow('Wi-Fi SSID', c.ssid,
        mono: true,
        tone: c.ssidIdMatch == false ? DetailTone.caution : DetailTone.plain,
        secondary: c.ssidIdMatch == null
            ? null
            : (c.ssidIdMatch!
                ? 'Names the same serial'
                : 'Names a different serial: the broadcast disagrees with itself')),
    DetailRow('Messages', '${c.msgCount}', mono: true),
    DetailRow('First heard', utcWords(first),
        secondary: '${durationWords(((nowMs - c.firstSeenMs) / 1000).round())} ago'),
    DetailRow('Last heard', '${c.ageS(nowMs).round()} s ago',
        tone: ContactTracker.isStale(c, nowMs) ? DetailTone.caution : DetailTone.plain,
        secondary: ContactTracker.isStale(c, nowMs) ? 'Stale' : null),
    DetailRow('Protocol', RidWords.protocol(c.proto, c.fmt)),
  ]);

  final a = c.auth;
  final auth = DetailSection('Authentication', [
    DetailRow('Verdict', RidWords.authVerdict(c.authState ?? (a == null ? null : AuthState.none)),
        tone: switch (c.authState) {
          AuthState.invalid => DetailTone.warning,
          AuthState.idValid => DetailTone.ok,
          AuthState.testKey => DetailTone.muted,
          _ => DetailTone.plain,
        }),
    DetailRow('Type', RidWords.authType(a?.authType)),
    DetailRow('Pages', a?.pages?.toString()),
    DetailRow('Length', a?.length == null ? null : '${a!.length} bytes'),
    DetailRow('Signed at', a?.signedAt == null ? null : utcWords(a!.signedAt!),
        secondary: a?.signedAt == null ? null : 'The timestamp on the signature\'s first page'),
  ]);

  final alertsSection = DetailSection('Alerts', [
    DetailRow('Emergency', l == null ? null : (c.emergency ? 'EMERGENCY REPORTED' : 'None reported'),
        tone: c.emergency ? DetailTone.warning : DetailTone.plain),
    // A detector with TFRs loaded says whether the drone is inside one.
    DetailRow('In a TFR', c.inTfr == null ? null : (c.inTfr! ? RidWords.inTfr(c.tfrId) : 'No'),
        tone: c.inTfr == true ? DetailTone.caution : DetailTone.plain,
        secondary: c.inTfr == null ? 'No detector with TFRs loaded has placed it' : null),
    DetailRow('ID signature', c.isAuthInvalid ? 'ID SIGNATURE INVALID' : (a == null ? null : 'No problem found'),
        tone: c.isAuthInvalid ? DetailTone.warning : DetailTone.plain),
    if (alerts.isEmpty)
      DetailRow(
          'ADS-B',
          conflictWatch == null || conflictWatch.startsWith('CONFLICT WATCH OFF')
              ? 'Conflict watch off'
              : 'No alert names this drone',
          secondary: conflictWatch)
    else
      for (final t in alerts)
        DetailRow('ADS-B', trafficAction(t),
            tone: t.level == TrafficLevel.warning ? DetailTone.warning : DetailTone.caution,
            secondary: [
              if (trafficGeometry(t).isNotEmpty) trafficGeometry(t),
              t.text,
              TrafficRules.ageWords(t.ageS),
            ].join(' · ')),
  ]);

  return DroneDetails(
    title: TrafficRules.droneLabel(c.label),
    fullId: id ?? (c.macs.isEmpty ? null : c.macs.first),
    model: model,
    alerts: alertWords,
    alertTone: tone,
    sections: [identity, position, motion, operator, system, signal, auth, alertsSection],
    rssiSeries: rssiSeries,
    live: true,
    sensors: chips,
  );
}

/// The details of a History record: what the match log keeps. Everything
/// else reads "not reported" (the log does not keep it).
DroneDetails recordDroneDetails(DetectionEntry d, {ObserverFix? observer, String? detectorName}) {
  final id = d.uasId;
  final model = id == null ? null : (UasModels.model(id) ?? UasModels.manufacturer(id));
  final hasPos = d.lat != null && d.lon != null;
  final srcs = <String>[
    if ((d.srcs ?? 0) & 1 != 0) 'wifi',
    if ((d.srcs ?? 0) & 2 != 0) 'nan',
    if ((d.srcs ?? 0) & 4 != 0) 'ble',
  ];
  final fmts = d.fmts ?? 0;
  const kept = 'Not kept in the history log';
  final alertWords = <String>[
    if (d.emerg) 'EMERGENCY REPORTED',
    if (d.tfr) RidWords.inTfr(d.tfrId),
    if (d.authState == AuthState.invalid) 'ID SIGNATURE INVALID',
    if (d.authState == AuthState.testKey) 'TEST KEY',
  ];
  return DroneDetails(
    title: TrafficRules.droneLabel(id ?? d.mac),
    fullId: id ?? d.mac,
    model: model,
    alerts: alertWords,
    alertTone: d.emerg || d.authState == AuthState.invalid
        ? DetailTone.warning
        : (d.tfr ? DetailTone.caution : DetailTone.muted),
    live: false,
    sections: [
      DetailSection('Identity', [
        DetailRow('UAS ID', id, mono: true, copy: id),
        DetailRow('Make and model', model),
        DetailRow('UA type', RidWords.uaType(d.uaType)),
        DetailRow('Classification', RidWords.classification(d.classType, d.catEu, d.classEu)),
        const DetailRow('Operator ID', null, secondary: kept),
        const DetailRow('Self-ID', null, secondary: kept),
      ]),
      DetailSection('Position', [
        DetailRow('Latitude, longitude', hasPos ? _coord(d.lat!, d.lon!, 5) : null,
            mono: true,
            copy: hasPos ? _coord(d.lat!, d.lon!, 5) : null,
            secondary: hasPos ? 'One position per record' : null),
        DetailRow('From you', hasPos && observer != null ? _fromTo(observer.lat, observer.lon, d.lat!, d.lon!) : null),
        DetailRow('Highest height', d.maxH == null ? null : _m(d.maxH!)),
        const DetailRow('Altitudes and accuracy', null, secondary: kept),
      ]),
      DetailSection('Signal', [
        DetailRow('Heard by', d.detectorId == 'phone' ? 'This phone' : (detectorName ?? 'A detector'),
            secondary: srcs.isEmpty ? null : _sources(srcs, const {}, null)),
        DetailRow('Peak signal', d.peakRssi == null ? null : '${d.peakRssi} dBm', mono: true),
        DetailRow('MAC address', d.mac.isEmpty ? null : d.mac, mono: true),
        DetailRow('Messages', '${d.msgs}', mono: true),
        DetailRow('First heard', utcWords(DateTime.fromMillisecondsSinceEpoch(d.firstUtc * 1000))),
        DetailRow('Last heard', utcWords(DateTime.fromMillisecondsSinceEpoch(d.lastUtc * 1000)),
            secondary: d.active ? 'Still live' : 'In range ${durationWords(d.durS)}'),
        DetailRow(
            'Protocol',
            [
              if (fmts & 1 != 0) 'ASTM F3411 / ASD-STAN',
              if (fmts & 2 != 0) 'GB 46750-2025',
            ].join(' · ')),
      ]),
      DetailSection('Authentication', [
        DetailRow('Verdict', RidWords.authVerdict(d.authState),
            tone: d.authState == AuthState.invalid ? DetailTone.warning : DetailTone.plain),
      ]),
      DetailSection('Alerts', [
        DetailRow('Emergency', d.emerg ? 'EMERGENCY REPORTED' : 'None reported',
            tone: d.emerg ? DetailTone.warning : DetailTone.plain),
        DetailRow('In a TFR', d.tfr ? RidWords.inTfr(d.tfrId) : 'No',
            tone: d.tfr ? DetailTone.caution : DetailTone.plain,
            secondary: !d.tfr || d.inTfr == null
                ? null
                : (d.inTfr! ? (d.active ? 'Inside it now' : 'Still inside at the end') : 'Had left it by the end')),
        DetailRow('TFR', d.tfr ? d.tfrId : null,
            mono: true,
            secondary: d.tfr && d.tfrId == null ? 'This detector\'s firmware does not send the TFR\'s name' : null),
        // Unsigned (or never checked): nothing to say, as on the live path.
        DetailRow(
            'ID signature',
            d.authState == AuthState.invalid
                ? 'ID SIGNATURE INVALID'
                : (d.authState == AuthState.none ? null : 'No problem found'),
            tone: d.authState == AuthState.invalid ? DetailTone.warning : DetailTone.plain),
      ]),
    ],
  );
}
