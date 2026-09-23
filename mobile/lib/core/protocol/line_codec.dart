// line_codec.dart — Line framing over BLE NUS notifications
//
// The TX characteristic carries the serial byte stream in MTU-sized slices,
// so a slice can end in the middle of a line and in the middle of a UTF-8
// sequence. Bytes are buffered and split on 0x0A; a line is decoded only
// once it is complete. A line longer than [maxLineBytes] is dropped whole
// (and counted), never delivered truncated.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

class LineCodec {
  /// Longest line accepted from a board. The firmware's longest host line
  /// is 1,600 bytes (BLE_LINE_MAX); leave room for growth.
  static const int defaultMaxLineBytes = 4096;

  /// Longest command the firmware assembles (BLE_LINE_MAX, 1,600 bytes
  /// including the newline): longer ones are dropped by the board.
  static const int maxCommandBytes = 1600;

  final int maxLineBytes;
  final BytesBuilder _buf = BytesBuilder(copy: false);
  bool _overlong = false;
  int _dropped = 0;

  LineCodec({this.maxLineBytes = defaultMaxLineBytes});

  /// Lines dropped because they were longer than [maxLineBytes].
  int get droppedLines => _dropped;

  /// Feeds incoming bytes; returns the lines completed by them, without the
  /// trailing "\r\n" and skipping empty lines.
  List<String> feed(List<int> bytes) {
    final lines = <String>[];
    var start = 0;
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] != 0x0A) continue;
      _append(bytes, start, i);
      start = i + 1;
      if (_overlong) {
        _dropped++;
      } else {
        final line = _takeLine();
        if (line != null) lines.add(line);
      }
      _buf.clear();
      _overlong = false;
    }
    _append(bytes, start, bytes.length);
    return lines;
  }

  void _append(List<int> bytes, int start, int end) {
    if (start >= end || _overlong) return;
    if (_buf.length + (end - start) > maxLineBytes) {
      _overlong = true; // drop the whole line, up to its newline
      _buf.clear();
      return;
    }
    _buf.add(bytes is Uint8List ? Uint8List.sublistView(bytes, start, end) : bytes.sublist(start, end));
  }

  String? _takeLine() {
    final raw = _buf.toBytes();
    var end = raw.length;
    if (end > 0 && raw[end - 1] == 0x0D) end--;
    if (end == 0) return null;
    final s = utf8.decode(Uint8List.sublistView(raw, 0, end), allowMalformed: true).trim();
    return s.isEmpty ? null : s;
  }

  /// Encodes one command line as UTF-8 ending in "\n". Throws
  /// [ArgumentError] for a command the board would drop (too long) or one
  /// with an embedded newline (it would become two commands).
  static Uint8List encodeCommand(String cmd) {
    final trimmed = cmd.trim();
    if (trimmed.contains('\n') || trimmed.contains('\r')) {
      throw ArgumentError.value(cmd, 'cmd', 'a command is one line');
    }
    final bytes = utf8.encode('$trimmed\n');
    if (bytes.length > maxCommandBytes) {
      throw ArgumentError.value(bytes.length, 'cmd', 'longer than $maxCommandBytes bytes');
    }
    return Uint8List.fromList(bytes);
  }

  void clear() {
    _buf.clear();
    _overlong = false;
  }
}
