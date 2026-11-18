// fakes.dart — a fake BLE transport and peer for the BLE service and app
// controller tests.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';

import 'package:orecchino_mobile/core/ble/ble_transport.dart';

const t5Info = '{"fw":"orecchino","ver":"0.6.0","board":"lilygo-t5-epaper-s3-pro","caps":["log","log_since","tfr","wifi","tiles"],"proto":1}';

class FakePeer implements BlePeer {
  @override
  final String id;
  String info;
  bool hasNus = true, hasInfo = true;
  bool refuseSubscribe = false;
  Completer<void>? holdPair; // pairing waits on this when set
  @override
  int mtu = 23;

  /// What [requestMtu] negotiates (247 by default; Android grants 517).
  int mtuGranted = 247;
  final List<int> mtuAsked = [];
  final List<List<int>> writes = [];
  final _down = Completer<void>();
  void Function(List<int>)? onBytes;
  bool disconnectedByUs = false;
  bool paired = false;

  FakePeer(this.id, {this.info = t5Info});

  /// The radio link goes down (the board dropped us, or out of range).
  void drop() {
    if (!_down.isCompleted) _down.complete();
  }

  void notify(String s) => onBytes?.call(utf8.encode(s));

  bool get isDown => _down.isCompleted;

  /// Every command line written so far.
  List<String> get lines => utf8.decode(writes.expand((w) => w).toList()).split('\n')..removeLast();

  @override
  Future<void> get disconnected => _down.future;
  @override
  Future<void> requestMtu(int m) async {
    mtuAsked.add(m);
    mtu = mtuGranted;
  }

  @override
  Future<BlePeerServices> discover() async => BlePeerServices(hasNus: hasNus, hasInfo: hasInfo);
  @override
  Future<List<int>> readInfo() async => utf8.encode(info);
  @override
  Future<void> pair() async {
    if (holdPair != null) await holdPair!.future;
    paired = true;
  }

  @override
  Future<void> subscribe(void Function(List<int>) cb) async {
    if (refuseSubscribe) throw StateError('insufficient encryption');
    onBytes = cb;
  }

  @override
  Future<void> write(List<int> bytes) async {
    if (_down.isCompleted) throw StateError('disconnected');
    writes.add(bytes);
  }

  @override
  Future<void> disconnect() async {
    disconnectedByUs = true;
    drop();
  }
}

class FakeTransport implements BleTransport {
  final Map<String, FakePeer> peers = {};
  final _scan = StreamController<List<BleScanHit>>.broadcast();
  Error? connectError;
  int connects = 0;

  @override
  Stream<List<BleScanHit>> get scanResults => _scan.stream;
  void hits(List<BleScanHit> h) => _scan.add(h);
  @override
  Future<void> startScan({Duration timeout = const Duration(seconds: 10)}) async {}
  @override
  Future<void> stopScan() async {}
  /// Pending connects (the detector comes into range later): off unless
  /// a test turns it on; [arrive] completes a waiting one.
  @override
  bool pendingConnect = false;
  final List<bool> pendingAsked = [];
  final Map<String, Completer<void>> waiting = {};
  final List<String> cancelled = [];

  @override
  Future<BlePeer> connect(String id, {Duration timeout = const Duration(seconds: 15), bool pending = false}) async {
    connects++;
    pendingAsked.add(pending);
    if (connectError != null) throw connectError!;
    if (pending && !peers.containsKey(id)) {
      final w = waiting[id] = Completer<void>();
      await w.future;
    }
    return peers[id]!;
  }

  /// The detector [id] comes into range: a pending connect completes.
  void arrive(String id, FakePeer peer) {
    peers[id] = peer;
    waiting.remove(id)?.complete();
  }

  @override
  Future<void> cancelConnect(String id) async {
    cancelled.add(id);
    final w = waiting.remove(id);
    if (w != null) w.completeError(StateError('cancelled'));
  }

  @override
  Future<void> forgetBond(String id) async {}
}

