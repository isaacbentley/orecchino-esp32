// ble_service.dart — scanning, connecting, verifying and pairing a detector
// over the Nordic UART Service (plan §3.1-3.2, firmware ble_link.h).
//
// Connection steps, each reported in [state]:
//   connecting -> (Android) MTU 517 -> discover NUS + Orecchino info service
//   -> verifying: read the device-info characteristic (readable before
//      pairing), require fw "orecchino" and proto >= 1, and when the
//      detector was pinned before, the same board
//   -> pairing: bond (the board shows passkey 123456, the phone asks for it)
//      and subscribe to TX, which the board allows only on an encrypted link
//   -> ready.
// The board drops a peer that has not paired within 10 s of connecting, and
// refuses a pairing that did not use the passkey (Just Works: bond deleted,
// peer dropped), so a failure in the pairing step is reported with the
// passkey to enter ([passkeyHint]), never as a bare error.
//
// A reconnect to a pinned detector can be a pending connect ([connect]
// with pending: true): it waits, with no timeout and no scan, until the
// detector is in range (Android autoConnect, CoreBluetooth's pending
// connect), then verifies and subscribes as any connect does.
//
// Every connection attempt has a generation number; a callback from an
// older attempt (a late disconnect, a slow step) is ignored, so it can never
// tear down a newer link. Commands are written in chunks of min(MTU - 3,
// 512) bytes (a with-response write is capped at 512 by the ATT attribute
// limit, which flutter_blue_plus enforces even when the MTU is 517), one
// command at a time, and [send] throws when there is no ready link.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../link/detector_link.dart';
import '../protocol/line_codec.dart';
import '../protocol/messages.dart';
import 'ble_transport.dart';

enum BleLinkState { idle, scanning, connecting, verifying, pairing, ready, failed }

class BleService extends ChangeNotifier implements DetectorLink {
  final BleTransport transport;
  final Duration connectTimeout;
  final Duration pairTimeout;

  BleService({
    BleTransport? transport,
    this.connectTimeout = const Duration(seconds: 15),
    this.pairTimeout = const Duration(seconds: 60),
  }) : transport = transport ?? FbpTransport();

  BleLinkState _state = BleLinkState.idle;
  String? _error;
  DeviceInfoMessage? _info;
  BlePeer? _peer;
  int _gen = 0;
  bool _disposed = false;
  Future<void> _writeChain = Future.value();
  List<BleScanHit> _hits = const [];
  String? _waitingFor; // a pending connect's device, until it connects
  StreamSubscription<List<BleScanHit>>? _scanSub;

  final LineCodec _codec = LineCodec();
  final _messages = StreamController<HostMessage>.broadcast();

  BleLinkState get state => _state;

  /// Why the last attempt failed or the link dropped, in words.
  String? get error => _error;

  /// The verified device info of the connected detector.
  DeviceInfoMessage? get info => _info;
  String? get connectedId => _state == BleLinkState.ready ? _peer?.id : null;
  String? get peerId => _peer?.id;

  /// A pending connect is waiting for this detector to come into range.
  String? get waitingFor => _waitingFor;
  List<BleScanHit> get scanHits => _hits;
  int get droppedLines => _codec.droppedLines;

  @override
  Stream<HostMessage> get messages => _messages.stream;

  @override
  bool get isReady => _state == BleLinkState.ready && _peer != null;

  void _set(BleLinkState s, {String? error}) {
    if (_disposed) return;
    _state = s;
    _error = error;
    notifyListeners();
  }

  // ---------------------------------------------------------------- scanning

  Future<void> startScan({Duration timeout = const Duration(seconds: 10)}) async {
    if (_state != BleLinkState.idle && _state != BleLinkState.failed) return;
    _hits = const [];
    unawaited(_scanSub?.cancel());
    _scanSub = transport.scanResults.listen((h) {
      _hits = h;
      if (!_disposed) notifyListeners();
    });
    _set(BleLinkState.scanning);
    try {
      await transport.startScan(timeout: timeout);
      // startScan returns at once; the scan ends by itself after [timeout].
      Timer(timeout, () {
        if (_state == BleLinkState.scanning) _set(BleLinkState.idle);
      });
    } catch (e) {
      unawaited(_scanSub?.cancel());
      _set(BleLinkState.failed, error: _words(e));
    }
  }

  Future<void> stopScan() async {
    unawaited(_scanSub?.cancel());
    _scanSub = null;
    try {
      await transport.stopScan();
    } catch (_) {}
    if (_state == BleLinkState.scanning) _set(BleLinkState.idle);
  }

  // -------------------------------------------------------------- connecting

  /// Connect, verify and pair. [pinnedBoard]: the board this detector was
  /// pinned as; a different board at the same ID is refused. Returns the
  /// verified info, or null (see [error]).
  Future<DeviceInfoMessage?> connect(String id, {String? pinnedBoard, bool pending = false}) async {
    final gen = ++_gen;
    await _scanSub?.cancel();
    _scanSub = null;
    if (_state == BleLinkState.scanning) {
      try {
        await transport.stopScan();
      } catch (_) {}
    }
    await _teardown();
    if (gen != _gen) return null;
    // A pending connect leaves the link idle (the picker can still scan)
    // until the detector is in range; then it is connecting like any other.
    if (pending) _waitingFor = id;
    _set(pending ? BleLinkState.idle : BleLinkState.connecting);

    BlePeer? peer;
    try {
      try {
        peer = await transport.connect(id, timeout: connectTimeout, pending: pending);
      } finally {
        if (_waitingFor == id && gen == _gen) _waitingFor = null;
      }
      if (pending && gen == _gen) _set(BleLinkState.connecting);
      if (gen != _gen) {
        await peer.disconnect();
        return null;
      }
      _peer = peer;
      final p = peer;
      unawaited(p.disconnected.then((_) => _onDropped(gen, p)));
      // Still this attempt, and the link still up (a drop mid-connect has
      // already reported the failure).
      bool alive() => gen == _gen && identical(_peer, p);

      try {
        await p.requestMtu(517);
      } catch (_) {} // any MTU works, down to 23
      final svc = await p.discover();
      if (!alive()) return null;
      if (!svc.hasNus || !svc.hasInfo) {
        throw const _Refused('not an Orecchino detector (services missing)');
      }

      _set(BleLinkState.verifying);
      final info = DeviceInfoMessage.fromBytes(await p.readInfo());
      if (!alive()) return null;
      if (info == null || !info.isOrecchino) {
        throw const _Refused('not an Orecchino detector (device info)');
      }
      if (pinnedBoard != null && pinnedBoard != 'unknown' && info.board != pinnedBoard) {
        throw _Refused('this is not the $pinnedBoard paired before; forget it and pair again');
      }

      _set(BleLinkState.pairing);
      await p.pair().timeout(pairTimeout);
      if (!alive()) return null;
      _codec.clear();
      await p.subscribe((bytes) => _onBytes(gen, bytes)).timeout(pairTimeout);
      if (!alive()) return null;

      _info = info;
      _set(BleLinkState.ready);
      _messages.add(info);
      return info;
    } catch (e) {
      if (gen != _gen || (peer != null && !identical(_peer, peer))) return null;
      // In the pairing step (bonding, or the subscription the board allows
      // only on a passkey-paired link): say what to do, not just what failed.
      final reason = _state == BleLinkState.pairing ? 'pairing failed (${_words(e)}): $passkeyHint' : _words(e);
      _peer = null;
      _info = null;
      try {
        await peer?.disconnect();
      } catch (_) {}
      _set(BleLinkState.failed, error: reason);
      return null;
    }
  }

  void _onBytes(int gen, List<int> bytes) {
    if (gen != _gen || _disposed) return;
    for (final line in _codec.feed(bytes)) {
      final msg = HostMessage.parse(line);
      if (msg != null) _messages.add(msg);
    }
  }

  void _onDropped(int gen, BlePeer peer) {
    if (gen != _gen || !identical(_peer, peer)) return; // an older link
    _peer = null;
    _info = null;
    _codec.clear();
    // Mid-connect this is a failure (the board drops a peer that does not
    // pair within 10 s); once ready it is a lost link.
    final wasReady = _state == BleLinkState.ready;
    _set(wasReady ? BleLinkState.idle : BleLinkState.failed,
        error: wasReady ? 'connection lost' : 'the detector disconnected before pairing finished: $passkeyHint');
  }

  /// What a failed pairing needs: the board's fixed passkey (README,
  /// firmware/common/ble_link.h). A pairing without it (Just Works) is
  /// refused by the board.
  static const passkeyHint =
      'pair with the passkey 123456 the detector shows (see the README); a pairing without it is refused';

  Future<void> _teardown() async {
    final w = _waitingFor;
    _waitingFor = null;
    if (w != null) {
      try {
        await transport.cancelConnect(w);
      } catch (_) {}
    }
    final p = _peer;
    _peer = null;
    _info = null;
    _codec.clear();
    if (p != null) {
      try {
        await p.disconnect();
      } catch (_) {}
    }
  }

  Future<void> disconnect() async {
    _gen++;
    await _teardown();
    _set(BleLinkState.idle);
  }

  Future<void> forgetBond(String id) async {
    if (_peer?.id == id) await disconnect();
    await transport.forgetBond(id);
  }

  // ---------------------------------------------------------------- commands

  @override
  Future<void> send(String command) {
    if (!isReady) return Future.error(const LinkNotReady());
    final bytes = LineCodec.encodeCommand(command);
    final peer = _peer!;
    final gen = _gen;
    // One command at a time: two commands' chunks must never interleave.
    final done = _writeChain.then((_) async {
      if (gen != _gen || !identical(_peer, peer)) throw const LinkNotReady('connection lost');
      final chunk = maxWrite(peer.mtu);
      for (var off = 0; off < bytes.length; off += chunk) {
        final end = off + chunk < bytes.length ? off + chunk : bytes.length;
        await peer.write(bytes.sublist(off, end));
      }
    });
    _writeChain = done.catchError((_) {});
    return done;
  }

  /// The most a with-response write may carry at [mtu]: MTU - 3, never
  /// more than the 512-byte attribute limit (an Android MTU of 517 gives
  /// 512, not 514), never less than the 20 of the default MTU.
  static int maxWrite(int mtu) => math.min(mtu - 3, 512).clamp(20, 512);

  static String _words(Object e) {
    if (e is _Refused) return e.message;
    if (e is TimeoutException) return 'timed out (was the passkey entered?)';
    if (e is StateError) return e.message;
    final s = e.toString();
    return s.length > 160 ? s.substring(0, 160) : s;
  }

  @override
  void dispose() {
    _disposed = true;
    _gen++;
    _scanSub?.cancel();
    _teardown();
    _messages.close();
    super.dispose();
  }
}

class _Refused implements Exception {
  final String message;
  const _Refused(this.message);
  @override
  String toString() => message;
}
