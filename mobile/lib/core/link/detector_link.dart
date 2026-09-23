// detector_link.dart — what the app needs from a detector, whichever it is
// (a paired board over BLE, or the simulated demo detector).
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import '../protocol/messages.dart';

/// Thrown by [DetectorLink.send] when there is no verified link: a command
/// is never dropped silently.
class LinkNotReady implements Exception {
  final String message;
  const LinkNotReady([this.message = 'no detector connected']);
  @override
  String toString() => message;
}

abstract class DetectorLink {
  /// Every host line the detector sends, parsed.
  Stream<HostMessage> get messages;

  /// True while commands can be sent (BLE: connected, verified, encrypted).
  bool get isReady;

  /// Send one command line. Throws [LinkNotReady] when not [isReady], and
  /// the transport's error when the write fails.
  Future<void> send(String command);
}
