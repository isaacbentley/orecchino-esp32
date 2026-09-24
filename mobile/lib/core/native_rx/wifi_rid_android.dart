// wifi_rid_android.dart — the phone's own Wi-Fi Remote ID receiver, over
// the Android plugin in android/app/src/main/kotlin/.../WifiRidPlugin.kt
// (MethodChannel "orecchino/wifi_rid", EventChannel
// "orecchino/wifi_rid/events"). The plugin hands over raw payloads and this
// side does all the parsing, with the firmware's rules (odid_transport.dart):
//
//   * NAN: a passive Wi-Fi Aware subscribe to "org.opendroneid.remoteid"
//     (service ID 88 69 19 9D 92 09, as tx_core.h build_nan publishes it).
//     Each discovery delivers the service info, [counter][message pack].
//     Android does not reveal the peer's MAC or RSSI, so the observation's
//     address is "nan-<peer handle>" and its RSSI is null. Needs Android 8+
//     and a Wi-Fi Aware chipset (FEATURE_WIFI_AWARE), NEARBY_WIFI_DEVICES on
//     Android 13+, fine location before that.
//   * Beacon: the system's Wi-Fi scan results, whose information elements
//     (ScanResult.getInformationElements, Android 11+) include the vendor
//     element FA:0B:BC / 90:3A:E6 type 0x0D. Android lets a foreground app
//     start four scans every two minutes, so the plugin asks every 30 s and
//     also reads results other apps' scans produce: SLOW, seconds old, fine
//     for noticing a drone and never for tracking one. Needs fine location
//     (scan results are location data) and location services on.
//
// iOS has no API for either: [WifiRidAndroid.capabilities] reports
// unsupported without calling the channel.
//
// Event maps from the plugin:
//   {"kind":"nan", "data":bytes, "peer":int, "ts":ms}
//   {"kind":"beacon", "ie":bytes (vendor element body: OUI, type, counter,
//    payload), "bssid":"aa:bb:..", "ssid":str, "rssi":int, "freq":MHz,
//    "ts":ms (when the scan saw it)}
//   {"kind":"status", "path":"nan"|"beacon", "state":str, "message":str?}
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../odid/odid_transport.dart';
import 'rid_observation.dart';

/// The platform side, behind an interface so tests can fake it.
abstract class WifiRidPlatform {
  Future<Map<String, Object?>> capabilities();

  /// Ask for the runtime permissions the Wi-Fi paths need; returns the
  /// grant per permission name.
  Future<Map<String, Object?>> requestPermissions();

  /// Start the paths asked for; returns a state per path ("started",
  /// "waiting", "permission", "unsupported: <why>").
  Future<Map<String, Object?>> start({required bool nan, required bool beacon, required int beaconIntervalMs});
  Future<void> stop();
  Stream<Map<Object?, Object?>> get events;
}

class MethodChannelWifiRid implements WifiRidPlatform {
  static const MethodChannel method = MethodChannel('orecchino/wifi_rid');
  static const EventChannel eventChannel = EventChannel('orecchino/wifi_rid/events');

  const MethodChannelWifiRid();

  static Map<String, Object?> _map(Object? v) =>
      v is Map ? {for (final e in v.entries) e.key.toString(): e.value} : const <String, Object?>{};

  @override
  Future<Map<String, Object?>> capabilities() async => _map(await method.invokeMethod<Object?>('capabilities'));

  @override
  Future<Map<String, Object?>> requestPermissions() async => _map(await method.invokeMethod<Object?>('requestPermissions'));

  @override
  Future<Map<String, Object?>> start({required bool nan, required bool beacon, required int beaconIntervalMs}) async =>
      _map(await method.invokeMethod<Object?>('start', {'nan': nan, 'beacon': beacon, 'beaconIntervalMs': beaconIntervalMs}));

  @override
  Future<void> stop() => method.invokeMethod<void>('stop');

  @override
  Stream<Map<Object?, Object?>> get events =>
      eventChannel.receiveBroadcastStream().where((e) => e is Map).map((e) => e as Map<Object?, Object?>);
}

/// What the phone's Wi-Fi can do for Remote ID.
class WifiRidCapabilities {
  /// Android at all (false on iOS: no API for NAN or beacon elements).
  final bool platformSupported;
  final int? sdk;

  /// The chipset has Wi-Fi Aware (FEATURE_WIFI_AWARE, Android 8+).
  final bool awareSupported;

  /// Wi-Fi Aware usable right now (Wi-Fi on, not taken by a hotspot).
  final bool awareAvailable;

  /// Beacon information elements readable (Android 11+).
  final bool beaconElements;

  /// How often the plugin asks for a Wi-Fi scan.
  final int beaconIntervalMs;
  final bool? nearbyWifiPermission;
  final bool? fineLocationPermission;
  final bool? locationEnabled;
  final bool? wifiEnabled;

  /// From the Android Bluetooth adapter (the plugin reports them too).
  final bool? leCodedPhy;
  final bool? leExtendedAdvertising;
  final int? leMaxAdvertisingDataLength;

  /// Why a path is unavailable, in words, when it is.
  final String? reason;

  const WifiRidCapabilities({
    required this.platformSupported,
    this.sdk,
    this.awareSupported = false,
    this.awareAvailable = false,
    this.beaconElements = false,
    this.beaconIntervalMs = 30000,
    this.nearbyWifiPermission,
    this.fineLocationPermission,
    this.locationEnabled,
    this.wifiEnabled,
    this.leCodedPhy,
    this.leExtendedAdvertising,
    this.leMaxAdvertisingDataLength,
    this.reason,
  });

  const WifiRidCapabilities.unsupported(String why)
      : this(platformSupported: false, reason: why);

  factory WifiRidCapabilities.fromMap(Map<String, Object?> m) {
    bool? b(String k) => m[k] is bool ? m[k]! as bool : null;
    int? i(String k) => m[k] is int ? m[k]! as int : null;
    return WifiRidCapabilities(
      platformSupported: true,
      sdk: i('sdk'),
      awareSupported: b('awareFeature') ?? false,
      awareAvailable: b('awareAvailable') ?? false,
      beaconElements: b('beaconIe') ?? false,
      beaconIntervalMs: i('beaconIntervalMs') ?? 30000,
      nearbyWifiPermission: b('nearbyWifiPermission'),
      fineLocationPermission: b('fineLocationPermission'),
      locationEnabled: b('locationEnabled'),
      wifiEnabled: b('wifiEnabled'),
      leCodedPhy: b('leCodedPhy'),
      leExtendedAdvertising: b('leExtendedAdvertising'),
      leMaxAdvertisingDataLength: i('leMaxAdvDataLength'),
      reason: m['reason'] is String ? m['reason']! as String : null,
    );
  }
}

/// A path's state change reported by the plugin.
class WifiRidStatus {
  final String path; // "nan" | "beacon"
  final String state;
  final String? message;
  const WifiRidStatus(this.path, this.state, [this.message]);
  @override
  String toString() => message == null ? '$path: $state' : '$path: $state ($message)';
}

/// 2.4 / 5 / 6 GHz centre frequency (MHz) -> channel number, or null.
int? wifiChannel(int? mhz) {
  if (mhz == null) return null;
  if (mhz == 2484) return 14;
  if (mhz >= 2412 && mhz <= 2472) return (mhz - 2407) ~/ 5;
  if (mhz >= 5160 && mhz <= 5885) return (mhz - 5000) ~/ 5;
  if (mhz >= 5955 && mhz <= 7115) return (mhz - 5950) ~/ 5;
  return null;
}

class WifiRidAndroid {
  final WifiRidPlatform platform;
  final bool isAndroid;
  final NativeRidDecoder decoder;

  /// Beacon results older than this when delivered are dropped: a cached
  /// scan result is not a drone that is there now.
  final Duration maxBeaconAge;
  final int beaconIntervalMs;
  final DateTime Function() _now;

  WifiRidAndroid({
    WifiRidPlatform? platform,
    bool? isAndroid,
    NativeRidDecoder? decoder,
    this.maxBeaconAge = const Duration(seconds: 30),
    this.beaconIntervalMs = 30000,
    DateTime Function()? now,
  })  : platform = platform ?? const MethodChannelWifiRid(),
        isAndroid = isAndroid ?? Platform.isAndroid,
        decoder = decoder ?? NativeRidDecoder(),
        _now = now ?? DateTime.now;

  final _out = StreamController<RidObservation>.broadcast();
  final _status = StreamController<WifiRidStatus>.broadcast();
  StreamSubscription<Map<Object?, Object?>>? _sub;
  Map<String, String> _pathStates = const {};

  int nanFrames = 0, beaconFrames = 0, dropped = 0;

  Stream<RidObservation> get observations => _out.stream;
  Stream<WifiRidStatus> get status => _status.stream;
  bool get running => _sub != null;

  /// The state per path from the last [start].
  Map<String, String> get pathStates => _pathStates;

  Future<WifiRidCapabilities> capabilities() async {
    if (!isAndroid) return const WifiRidCapabilities.unsupported('iOS has no Wi-Fi NAN or beacon element API');
    try {
      return WifiRidCapabilities.fromMap(await platform.capabilities());
    } on MissingPluginException {
      return const WifiRidCapabilities.unsupported('the Wi-Fi Remote ID plugin is not registered');
    } on PlatformException catch (e) {
      return WifiRidCapabilities.unsupported(e.message ?? e.code);
    }
  }

  Future<Map<String, Object?>> requestPermissions() async {
    if (!isAndroid) return const {};
    return platform.requestPermissions();
  }

  /// Start the Wi-Fi paths; returns the state per path. On iOS every path
  /// is "unsupported" and nothing is called.
  Future<Map<String, String>> start({bool nan = true, bool beacon = true, int? beaconIntervalMs}) async {
    if (!isAndroid) {
      return _pathStates = {if (nan) 'nan': 'unsupported: iOS', if (beacon) 'beacon': 'unsupported: iOS'};
    }
    _sub ??= platform.events.listen(onEvent, onError: (Object e) => _status.add(WifiRidStatus('plugin', 'error', '$e')));
    try {
      final r = await platform.start(nan: nan, beacon: beacon, beaconIntervalMs: beaconIntervalMs ?? this.beaconIntervalMs);
      _pathStates = {for (final e in r.entries) e.key: '${e.value}'};
    } catch (e) {
      await _sub?.cancel();
      _sub = null;
      rethrow;
    }
    return _pathStates;
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    if (isAndroid) {
      try {
        await platform.stop();
      } on MissingPluginException {
        // nothing was started
      }
    }
  }

  /// One plugin event (public for tests).
  void onEvent(Map<Object?, Object?> e) {
    final kind = e['kind'];
    final ts = e['ts'] is int ? DateTime.fromMillisecondsSinceEpoch(e['ts']! as int) : _now();
    if (kind == 'nan') {
      final data = e['data'];
      final f = data is Uint8List ? OdidWifi.fromNanServiceInfo(data) : null;
      if (f == null) {
        dropped++;
        return;
      }
      nanFrames++;
      _emit(decoder.decode(source: NativeRidSource.nan, mac: 'nan-${e['peer'] ?? '?'}', frame: f, at: ts));
    } else if (kind == 'beacon') {
      final ie = e['ie'];
      final f = ie is Uint8List ? OdidWifi.fromVendorIe(ie) : null;
      if (f == null || _now().difference(ts) > maxBeaconAge) {
        dropped++;
        return;
      }
      beaconFrames++;
      final bssid = e['bssid'] is String ? (e['bssid']! as String).toUpperCase() : '';
      final ssid = e['ssid'] is String ? e['ssid']! as String : null;
      _emit(decoder.decode(
        source: NativeRidSource.beacon,
        mac: bssid,
        frame: f,
        at: ts,
        rssi: e['rssi'] is int ? e['rssi']! as int : null,
        channel: wifiChannel(e['freq'] is int ? e['freq']! as int : null),
        ssid: ssid == null || ssid.isEmpty || ssid == '<unknown ssid>' ? null : ssid,
      ));
    } else if (kind == 'status') {
      final path = e['path'] is String ? e['path']! as String : '?';
      final state = e['state'] is String ? e['state']! as String : '?';
      _pathStates = {..._pathStates, path: state};
      _status.add(WifiRidStatus(path, state, e['message'] is String ? e['message']! as String : null));
    }
  }

  void _emit(RidObservation? o) {
    if (o == null) {
      dropped++;
      return;
    }
    if (!_out.isClosed) _out.add(o);
  }

  Future<void> dispose() async {
    await stop();
    await _out.close();
    await _status.close();
  }
}
