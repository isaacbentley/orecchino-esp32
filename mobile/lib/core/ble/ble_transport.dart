// ble_transport.dart — the BLE operations BleService needs, behind an
// interface so the connection state machine can be tested with a fake
// (test/ble_service_test.dart), and the flutter_blue_plus implementation.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class BleUuids {
  static const nusService = '6E400001-B5A3-F393-E0A9-E50E24DCCA9E';
  static const nusRx = '6E400002-B5A3-F393-E0A9-E50E24DCCA9E'; // phone -> board, write
  static const nusTx = '6E400003-B5A3-F393-E0A9-E50E24DCCA9E'; // board -> phone, notify
  static const infoService = '0A1B0001-5E1D-4F0E-9C7B-4F52454343A1';
  static const infoChar = '0A1B0002-5E1D-4F0E-9C7B-4F52454343A1'; // read, JSON
}

class BleScanHit {
  final String id;
  final String name;
  final int rssi;
  const BleScanHit({required this.id, required this.name, required this.rssi});
}

/// What discovery found on a peer.
class BlePeerServices {
  final bool hasNus;
  final bool hasInfo;
  const BlePeerServices({required this.hasNus, required this.hasInfo});
}

/// One connected peer. Every method may throw; the caller tears the link
/// down on any error.
abstract class BlePeer {
  String get id;

  /// Completes once, when a link that was up goes down.
  Future<void> get disconnected;

  /// Current ATT MTU (23 until negotiated).
  int get mtu;

  /// Android: ask for [mtu]. iOS negotiates by itself; a no-op there.
  Future<void> requestMtu(int mtu);

  Future<BlePeerServices> discover();

  /// The device-info characteristic (readable before pairing).
  Future<List<int>> readInfo();

  /// Android: bond now (the system asks for the passkey). iOS pairs on the
  /// first encrypted access instead, which [subscribe] makes.
  Future<void> pair();

  /// Enable notifications on TX. The board requires an encrypted link for
  /// this, so success proves the link is bonded and encrypted.
  Future<void> subscribe(void Function(List<int> bytes) onBytes);

  /// Write to RX with response.
  Future<void> write(List<int> bytes);

  Future<void> disconnect();
}

abstract class BleTransport {
  Stream<List<BleScanHit>> get scanResults;
  Future<void> startScan({Duration timeout});
  Future<void> stopScan();

  /// Connect within [timeout]; or with [pending], wait as long as it takes
  /// for the device to come into range (no timeout, no scanning: Android's
  /// autoConnect, CoreBluetooth's pending connect), cancelled by
  /// [cancelConnect].
  Future<BlePeer> connect(String id, {Duration timeout, bool pending = false});

  /// Whether [connect] can wait ([pending]).
  bool get pendingConnect;

  /// Give up a pending [connect] to [id].
  Future<void> cancelConnect(String id);
  Future<void> forgetBond(String id);
}

// --------------------------------------------------------------------------
// flutter_blue_plus

bool get _android => Platform.isAndroid;

class FbpTransport implements BleTransport {
  @override
  Stream<List<BleScanHit>> get scanResults => FlutterBluePlus.onScanResults.map((list) => [
        for (final r in list)
          BleScanHit(
            id: r.device.remoteId.str,
            name: r.advertisementData.advName.isNotEmpty ? r.advertisementData.advName : r.device.platformName,
            rssi: r.rssi,
          ),
      ]);

  @override
  Future<void> startScan({Duration timeout = const Duration(seconds: 10)}) async {
    if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
      // Wait briefly for the adapter state to be known (it starts "unknown").
      final s = await FlutterBluePlus.adapterState
          .where((s) => s != BluetoothAdapterState.unknown)
          .first
          .timeout(const Duration(seconds: 3), onTimeout: () => FlutterBluePlus.adapterStateNow);
      if (s != BluetoothAdapterState.on) {
        throw StateError(s == BluetoothAdapterState.unauthorized
            ? 'Bluetooth permission denied'
            : 'Bluetooth is off');
      }
    }
    await FlutterBluePlus.startScan(
      withServices: [Guid(BleUuids.nusService)],
      timeout: timeout,
      // BLUETOOTH_SCAN is declared neverForLocation: no location needed.
      androidUsesFineLocation: false,
      androidCheckLocationServices: false,
    );
  }

  @override
  Future<void> stopScan() => FlutterBluePlus.stopScan();

  @override
  bool get pendingConnect => true;

  // A waiting pending connect per device, so [cancelConnect] ends its wait:
  // otherwise it would complete on the device's next connection (a newer
  // connect's) and the stale attempt would disconnect that link.
  final Map<String, void Function()> _pendingCancel = {};

  @override
  Future<BlePeer> connect(String id,
      {Duration timeout = const Duration(seconds: 15), bool pending = false}) async {
    final device = BluetoothDevice.fromId(id);
    if (pending) {
      // autoConnect: Android's controller connects whenever the detector
      // is in range (low duty, no app scan); iOS connects with no timeout
      // and flutter_blue_plus re-arms it after a drop. mtu must be null.
      final up = Completer<void>();
      up.future.ignore(); // a cancel before the wait below is not an unhandled error
      void cancel() {
        if (!up.isCompleted) up.completeError(StateError('pending connect cancelled'));
      }

      _pendingCancel.remove(id)?.call();
      _pendingCancel[id] = cancel;
      // connectionState replays the current state, so a peripheral that is
      // already connected (iOS state restoration) completes at once.
      final sub = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.connected && !up.isCompleted) up.complete();
      });
      try {
        await device.connect(mtu: null, autoConnect: true);
        await up.future;
      } finally {
        await sub.cancel();
        if (identical(_pendingCancel[id], cancel)) _pendingCancel.remove(id);
      }
      return _FbpPeer(device);
    }
    // mtu: null — the MTU is asked for explicitly after connecting (Android).
    await device.connect(timeout: timeout, mtu: null);
    return _FbpPeer(device);
  }

  @override
  Future<void> cancelConnect(String id) async {
    _pendingCancel.remove(id)?.call();
    try {
      await BluetoothDevice.fromId(id).disconnect();
    } catch (_) {}
  }

  @override
  Future<void> forgetBond(String id) async {
    if (!_android) return; // iOS: Settings > Bluetooth > Forget This Device
    try {
      await BluetoothDevice.fromId(id).removeBond();
    } catch (_) {}
  }
}

class _FbpPeer implements BlePeer {
  final BluetoothDevice device;
  final Completer<void> _down = Completer<void>();
  StreamSubscription<BluetoothConnectionState>? _stateSub;
  StreamSubscription<List<int>>? _txSub;
  BluetoothCharacteristic? _rx, _tx, _info;

  _FbpPeer(this.device) {
    // connectionState replays the current state on listen; only a
    // disconnect after the link was seen up counts, so a stale
    // "disconnected" can never tear down this connection.
    var seenUp = false;
    _stateSub = device.connectionState.listen((s) {
      if (s == BluetoothConnectionState.connected) {
        seenUp = true;
      } else if (s == BluetoothConnectionState.disconnected && seenUp) {
        _finish();
      }
    });
  }

  void _finish() {
    _txSub?.cancel();
    _txSub = null;
    _stateSub?.cancel();
    _stateSub = null;
    if (!_down.isCompleted) _down.complete();
  }

  @override
  String get id => device.remoteId.str;

  @override
  Future<void> get disconnected => _down.future;

  @override
  int get mtu => device.mtuNow;

  @override
  Future<void> requestMtu(int mtu) async {
    if (_android) await device.requestMtu(mtu);
  }

  @override
  Future<BlePeerServices> discover() async {
    final services = await device.discoverServices();
    for (final s in services) {
      if (s.uuid == Guid(BleUuids.nusService)) {
        for (final c in s.characteristics) {
          if (c.uuid == Guid(BleUuids.nusRx)) _rx = c;
          if (c.uuid == Guid(BleUuids.nusTx)) _tx = c;
        }
      } else if (s.uuid == Guid(BleUuids.infoService)) {
        for (final c in s.characteristics) {
          if (c.uuid == Guid(BleUuids.infoChar)) _info = c;
        }
      }
    }
    return BlePeerServices(hasNus: _rx != null && _tx != null, hasInfo: _info != null);
  }

  @override
  Future<List<int>> readInfo() => _info!.read();

  @override
  Future<void> pair() async {
    if (_android) await device.createBond(timeout: 60);
  }

  @override
  Future<void> subscribe(void Function(List<int> bytes) onBytes) async {
    final tx = _tx!;
    _txSub = tx.onValueReceived.listen(onBytes);
    device.cancelWhenDisconnected(_txSub!);
    // Needs encryption: on iOS this is what brings up the passkey prompt.
    final ok = await tx.setNotifyValue(true, timeout: 60);
    if (!ok) throw StateError('the detector refused the subscription');
  }

  @override
  Future<void> write(List<int> bytes) => _rx!.write(bytes, withoutResponse: false);

  @override
  Future<void> disconnect() async {
    try {
      await device.disconnect();
    } finally {
      _finish();
    }
  }
}
