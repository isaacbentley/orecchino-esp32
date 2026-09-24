// rid_observation.dart — one Remote ID frame the phone heard itself, and
// the decoder the phone's receive paths share (ble_rid_scanner.dart,
// wifi_rid_android.dart) to turn a transport frame into one.
//
// An observation carries the decoded fields twice: as the firmware's
// OdidUas (every field, unknown markers intact) and as the app's RidMessage
// (rid_line.dart builds the line a detector would have sent, and
// messages.dart parses it), so the live tracker can take it exactly as it
// takes a detector's line.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import '../odid/odid.dart';
import '../protocol/messages.dart';

/// The phone's own receive paths. [wire] is the RidMessage "src".
enum NativeRidSource {
  /// Bluetooth legacy advertising (one 25-byte message per advertisement).
  ble4('phone-ble4'),

  /// Bluetooth 5 extended advertising on the 1M PHY (a message pack), or
  /// on a PHY the platform does not report.
  ble5('phone-ble5'),

  /// Bluetooth 5 extended advertising on the coded (long range) PHY. Only
  /// when the platform reports the PHY; flutter_blue_plus does not (see
  /// ble_rid_scanner.dart), so today coded-PHY frames arrive as [ble5].
  coded('phone-coded'),

  /// Wi-Fi NAN (Wi-Fi Aware) service discovery, Android only.
  nan('phone-nan'),

  /// Wi-Fi beacon vendor element from the system's scan results, Android
  /// only: throttled by the platform to one scan every ~30 s ([slow]).
  beacon('phone-beacon');

  final String wire;
  const NativeRidSource(this.wire);

  bool get isBle => this == ble4 || this == ble5 || this == coded;
  bool get isWifi => this == nan || this == beacon;

  /// A path whose updates arrive at scan-throttle pace, not per broadcast.
  bool get slow => this == beacon;

  static NativeRidSource? fromWire(String s) {
    for (final v in values) {
      if (v.wire == s) return v;
    }
    return null;
  }
}

class RidObservation {
  final NativeRidSource source;

  /// Transmitter address: Android BLE and beacons a MAC ("AA:BB:..."), iOS
  /// BLE the CoreBluetooth peripheral UUID (iOS hides MACs), NAN
  /// "nan-<peer handle>" (Android hides the NAN peer's MAC).
  final String mac;
  final int? rssi;

  /// When the frame was received (beacons: when the platform's scan saw
  /// it, which may be seconds before it was delivered).
  final DateTime at;

  /// The transmitter's message counter.
  final int counter;
  final OdidUas uas;
  final RidMessage message;

  /// False for the same frame from the same path within a second (the
  /// firmware reports such a repeat once).
  final bool fresh;

  const RidObservation({
    required this.source,
    required this.mac,
    required this.at,
    required this.counter,
    required this.uas,
    required this.message,
    this.rssi,
    this.fresh = true,
  });

  bool get slow => source.slow;
  String? get uasId => message.primaryUasId;
}

/// Frame -> observation, with per-transmitter state (auth pages, the SSID
/// check, repeat suppression) shared by every path that feeds it.
class NativeRidDecoder {
  final RidLineBuilder lines;
  int decoded = 0;
  int failed = 0;

  NativeRidDecoder({RidLineBuilder? lines}) : lines = lines ?? RidLineBuilder();

  RidObservation? decode({
    required NativeRidSource source,
    required String mac,
    required OdidFrame frame,
    required DateTime at,
    int? rssi,
    int? channel,
    String? phy,
    String? ssid,
  }) {
    final line = lines.build(
      RidFrameIn(
        src: source.wire,
        mac: mac,
        payload: frame.payload,
        rssi: rssi,
        channel: channel,
        phy: phy,
        ssid: ssid,
      ),
      at.millisecondsSinceEpoch,
    );
    if (line == null) {
      failed++;
      return null;
    }
    decoded++;
    return RidObservation(
      source: source,
      mac: mac,
      rssi: rssi,
      at: at,
      counter: frame.counter,
      uas: line.uas,
      message: RidMessage.fromJson(line.json),
      fresh: line.fresh,
    );
  }
}
