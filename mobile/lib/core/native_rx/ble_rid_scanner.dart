// ble_rid_scanner.dart — the phone's own Bluetooth Remote ID receiver: a
// continuous lease on the shared scan (ble_scan_coordinator.dart) filtered
// to ASTM Remote ID (service data UUID 0xFFFA, and the draft-era
// manufacturer layout 0x0200), each advertisement decoded by lib/core/odid
// into a [RidObservation].
//
// Source per advertisement:
//   * the platform reports the coded PHY          -> phone-coded
//   * the platform reports a legacy advertisement -> phone-ble4 (phy 1m)
//   * the platform reports an extended one        -> phone-ble5
//   * unknown (flutter_blue_plus): a payload longer than one message (a
//     pack: it cannot fit a 31-byte legacy advertisement) -> phone-ble5,
//     else phone-ble4. A single message sent in an extended advertisement
//     is therefore counted as BLE4.
// flutter_blue_plus 1.36 scans every PHY with extended advertising on
// Android (androidLegacy: false), so coded-PHY broadcasts ARE received on
// phones whose controller supports it; it just does not say which PHY a
// result came on, so they are reported as phone-ble5. Telling them apart
// needs ScanResult.getSecondaryPhy()/isLegacy(), which only a native scan
// exposes (the Wi-Fi plugin could grow one; see wifi_rid_android.dart).
//
// iOS: foreground only. CoreBluetooth delivers duplicate advertisements
// only to a foreground app (AllowDuplicates is ignored in the background),
// and a background scan must name the service UUIDs it wants while Remote
// ID broadcasts carry 0xFFFA only as service data, which such a filter
// does not match. In the background the receiver hears nothing, or at best
// one advertisement per transmitter. The MAC is hidden: [RidObservation.mac]
// is the CoreBluetooth peripheral UUID, so fusion must key on the UAS ID.
// Extended advertising reception depends on the iPhone and is not
// reported; the coded PHY is not received.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import '../odid/odid_transport.dart';
import 'ble_scan_coordinator.dart';
import 'rid_observation.dart';

class BleRidScanner {
  final BleScanCoordinator coordinator;
  final NativeRidDecoder decoder;

  /// The filter the lease asks for. [BleScanFilter.detectorAndRid] by
  /// default, so the picker coming and going never restarts this scan.
  final BleScanFilter filter;

  BleRidScanner(this.coordinator, {NativeRidDecoder? decoder, BleScanFilter? filter})
      : decoder = decoder ?? NativeRidDecoder(),
        filter = filter ?? BleScanFilter.detectorAndRid;

  final _out = StreamController<RidObservation>.broadcast();
  BleScanLease? _lease;
  StreamSubscription<BleAdvert>? _sub;

  int advertsSeen = 0;
  int framesDecoded = 0;
  int decodeFailures = 0;

  Stream<RidObservation> get observations => _out.stream;
  bool get running => _lease?.active ?? false;

  /// Start listening; throws when the scan cannot start (Bluetooth off,
  /// permission denied), leaving the scanner stopped.
  Future<void> start() async {
    if (running) return;
    _sub ??= coordinator.adverts.listen(onAdvert);
    try {
      _lease = await coordinator.acquire('remote-id', filter);
    } catch (_) {
      await _sub?.cancel();
      _sub = null;
      rethrow;
    }
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    final l = _lease;
    _lease = null;
    await l?.release();
  }

  /// One advertisement from the shared scan (public for tests).
  void onAdvert(BleAdvert a) {
    final frames = extract(a);
    if (frames.isEmpty) return;
    advertsSeen++;
    for (final f in frames) {
      final src = sourceOf(a, f);
      final obs = decoder.decode(
        source: src,
        mac: a.id,
        frame: f,
        at: a.at,
        rssi: a.rssi,
        phy: a.phy ?? (src == NativeRidSource.ble4 ? '1m' : null),
      );
      if (obs == null) {
        decodeFailures++;
        continue;
      }
      framesDecoded++;
      if (!_out.isClosed) _out.add(obs);
    }
  }

  /// The ODID frames an advertisement carries (service data 0xFFFA or
  /// manufacturer data 0x0200).
  static List<OdidFrame> extract(BleAdvert a) {
    final out = <OdidFrame>[];
    final sd = a.serviceData[odidBleUuid128];
    if (sd != null) {
      final f = OdidBle.fromServiceData(sd);
      if (f != null) out.add(f);
    }
    final md = a.manufacturerData[odidDraftCompanyId];
    if (md != null) {
      final f = OdidBle.fromManufacturerData(odidDraftCompanyId, md);
      if (f != null) out.add(f);
    }
    return out;
  }

  static NativeRidSource sourceOf(BleAdvert a, OdidFrame f) {
    if (a.phy == 'coded') return NativeRidSource.coded;
    if (a.legacy == true) return NativeRidSource.ble4;
    if (a.legacy == false) return NativeRidSource.ble5;
    return f.payload.length > odidMessageBytes ? NativeRidSource.ble5 : NativeRidSource.ble4;
  }

  static const int odidMessageBytes = 25;

  Future<void> dispose() async {
    await stop();
    await _out.close();
  }
}
