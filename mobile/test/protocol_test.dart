// protocol_test.dart — Unit tests for line codec, message models and commands
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:orecchino_mobile/core/protocol/commands.dart';
import 'package:orecchino_mobile/core/protocol/line_codec.dart';
import 'package:orecchino_mobile/core/protocol/messages.dart';

void main() {
  group('LineCodec', () {
    test('Splits single complete line', () {
      final codec = LineCodec();
      final lines = codec.feed(utf8.encode('{"type":"hb","up":100}\n'));
      expect(lines, ['{"type":"hb","up":100}']);
    });

    test('Buffers partial chunks across MTU boundary', () {
      final codec = LineCodec();
      final p1 = codec.feed(utf8.encode('{"type":"rid",'));
      expect(p1, isEmpty);

      final p2 = codec.feed(utf8.encode('"mac":"AA:BB:CC"}\n'));
      expect(p2, ['{"type":"rid","mac":"AA:BB:CC"}']);
    });

    test('Splits multiple lines in single chunk', () {
      final codec = LineCodec();
      final lines = codec.feed(utf8.encode('line1\nline2\r\nline3\n'));
      expect(lines, ['line1', 'line2', 'line3']);
    });

    test('A UTF-8 sequence split across notifications survives', () {
      final codec = LineCodec();
      final bytes = utf8.encode('{"desc":"Überflug ✈ 测试"}\n');
      // Every split point, including inside the 2-, 3- and 3-byte sequences.
      for (var cut = 1; cut < bytes.length; cut++) {
        codec.clear();
        final a = codec.feed(bytes.sublist(0, cut));
        final b = codec.feed(bytes.sublist(cut));
        expect([...a, ...b], ['{"desc":"Überflug ✈ 测试"}'], reason: 'cut at $cut');
      }
    });

    test('One byte at a time (MTU 23 worst case)', () {
      final codec = LineCodec();
      final out = <String>[];
      for (final b in utf8.encode('{"a":"é"}\r\n\n{"b":2}\n')) {
        out.addAll(codec.feed([b]));
      }
      expect(out, ['{"a":"é"}', '{"b":2}']);
    });

    test('An over-long line is dropped whole, and the next line is fine', () {
      final codec = LineCodec(maxLineBytes: 64);
      final long = 'x' * 200;
      final out = <String>[];
      // Arrives in 20-byte slices with no newline for a while.
      final bytes = utf8.encode('$long\n{"ok":1}\n');
      for (var i = 0; i < bytes.length; i += 20) {
        out.addAll(codec.feed(bytes.sublist(i, i + 20 > bytes.length ? bytes.length : i + 20)));
      }
      expect(out, ['{"ok":1}']);
      expect(codec.droppedLines, 1);
    });

    test('A line of exactly the cap is kept', () {
      final codec = LineCodec(maxLineBytes: 10);
      expect(codec.feed(utf8.encode('0123456789\n')), ['0123456789']);
      expect(codec.feed(utf8.encode('0123456789A\n')), isEmpty);
      expect(codec.droppedLines, 1);
    });

    test('Commands: one line, capped at the board\'s 1,600 bytes', () {
      expect(utf8.decode(LineCodec.encodeCommand('{"cmd":"feed","on":true}')), '{"cmd":"feed","on":true}\n');
      expect(() => LineCodec.encodeCommand('a\nb'), throwsArgumentError);
      expect(LineCodec.encodeCommand('x' * 1599).length, 1600);
      expect(() => LineCodec.encodeCommand('x' * 1600), throwsArgumentError);
    });
  });

  group('HostMessage parsing', () {
    test('Heartbeat message parses all fields', () {
      const json =
          '{"type":"hb","up":34103,"wifi_frames":117,"ble_advs":4674,"rid":1,"dropped":0,"ch":6,"ble":true,"ble_ext":true,"ble_drop":2}';
      final msg = HostMessage.parse(json);
      expect(msg, isA<HeartbeatMessage>());
      final hb = msg as HeartbeatMessage;
      expect(hb.uptimeMs, 34103);
      expect(hb.wifiFrames, 117);
      expect(hb.bleAdvs, 4674);
      expect(hb.ridCount, 1);
      expect(hb.dropped, 0);
      expect(hb.channel, 6);
      expect(hb.bleActive, true);
      expect(hb.bleExtActive, true);
      expect(hb.bleDrops, 2);
    });

    test('RidMessage preserves missing fields as null', () {
      const json =
          '{"type":"rid","src":"ble","mac":"AA:BB:CC:DD:EE:FF","rssi":-61,"phy":"coded","basic_id":[{"id_type":1,"ua_type":2,"uas_id":"1581F204C68D9A11"}],"loc":{"status":2,"lat":37.8039,"lon":-122.464,"alt_geo":100.0,"height":60.0,"height_ref":0,"speed":5.0,"dir":90}}';
      final msg = HostMessage.parse(json);
      expect(msg, isA<RidMessage>());
      final rid = msg as RidMessage;
      expect(rid.src, 'ble');
      expect(rid.mac, 'AA:BB:CC:DD:EE:FF');
      expect(rid.rssi, -61);
      expect(rid.phy, 'coded');
      expect(rid.primaryUasId, '1581F204C68D9A11');
      expect(rid.loc?.vspeed, isNull); // vspeed omitted -> must be null, never 0
      expect(rid.loc?.altBaro, isNull);
      expect(rid.loc?.speed, 5.0);
    });

    test('LogRecordMessage with seq and null coordinates', () {
      const json =
          '{"type":"log","seq":42,"uas_id":"UAS999","mac":"11:22:33:44:55:66","first_utc":1700000000,"last_utc":1700000060,"dur_s":60,"peak_rssi":-55,"auth_state":1,"tfr":false,"emerg":true,"msgs":15}';
      final msg = HostMessage.parse(json);
      expect(msg, isA<LogRecordMessage>());
      final log = msg as LogRecordMessage;
      expect(log.seq, 42);
      expect(log.uasId, 'UAS999');
      expect(log.mac, '11:22:33:44:55:66');
      expect(log.emergency, true);
      expect(log.lat, isNull);
      expect(log.lon, isNull);
    });

    test('Firmware rid line: unknown markers become null', () {
      // As rx_core.h format_rid writes it: ODID -1000 altitudes, speed -1
      // (raw 255), dir -1, ts -1, a 0,0 "no fix" position.
      const json = '{"type":"rid","src":"wifi","mac":"D4:88:55:AA:BB:CC","rssi":-74,"ch":6,"proto":2,'
          '"basic_id":[{"id_type":1,"ua_type":2,"uas_id":"1581F999E412A002"}],'
          '"loc":{"status":3,"lat":0.0000000,"lon":0.0000000,"alt_geo":-1000.0,"alt_baro":-1000.0,'
          '"height":-1000.0,"height_ref":0,"speed":-1.00,"dir":-1,"ts":-1.0},'
          '"system":{"op_lat":0.0000000,"op_lon":0.0000000,"op_alt":-1000.0,"op_loc_type":0,"area_count":1,"ts":0},'
          '"self_id":{"desc_type":0,"desc":"survey"},"op_id":{"id_type":0,"id":"FIN87astrdge12k8"},'
          '"auth":{"type":1,"len":90,"pages":5,"state":"invalid"}}';
      final rid = HostMessage.parse(json) as RidMessage;
      final l = rid.loc!;
      expect(l.lat, isNull);
      expect(l.lon, isNull);
      expect(l.altGeo, isNull);
      expect(l.altBaro, isNull);
      expect(l.height, isNull);
      expect(l.heightRef, 0);
      expect(l.speed, isNull);
      expect(l.dir, isNull);
      expect(l.timestamp, isNull);
      expect(l.vspeed, isNull);
      expect(rid.system!.operatorLat, isNull);
      expect(rid.system!.operatorAltGeo, isNull);
      expect(rid.emergency, isTrue); // status 3
      expect(rid.authState, AuthState.invalid);
      expect(rid.selfId!.text, 'survey');
      expect(rid.operatorId!.opId, 'FIN87astrdge12k8');
      expect(rid.channel, 6);
    });

    test('Firmware rid line: real values are kept', () {
      const json = '{"type":"rid","src":"ble","mac":"AA:BB:CC:DD:EE:FF","rssi":-61,'
          '"loc":{"status":2,"lat":37.8039000,"lon":-122.4640000,"alt_geo":120.0,"alt_baro":110.5,'
          '"height":0.0,"height_ref":1,"speed":0.00,"dir":0,"ts":12.5,"vspeed":-0.50}}';
      final l = (HostMessage.parse(json) as RidMessage).loc!;
      expect(l.lat, 37.8039);
      expect(l.altGeo, 120.0);
      expect(l.height, 0.0); // zero is a value, not unknown
      expect(l.speed, 0.0);
      expect(l.dir, 0.0);
      expect(l.vspeed, -0.5);
    });

    test('Firmware log records: ended and live', () {
      final ended = HostMessage.parse(
          '{"type":"log","seq":17,"i":17,"active":false,"uas":"1581F2","mac":"11:22:33:44:55:66",'
          '"srcs":1,"fmts":1,"ua_type":2,"first":1700000000,"last":1700000060,"dur":60,"lat":37.80390,"lon":-122.46400,'
          '"max_h":118,"peak_rssi":-55,"auth_state":"test_key","tfr":true,"emerg":false,"msgs":15}') as LogRecordMessage;
      expect(ended.seq, 17);
      expect(ended.active, isFalse);
      expect(ended.uasId, '1581F2');
      expect(ended.firstUtc, 1700000000);
      expect(ended.durationS, 60);
      expect(ended.maxHeightM, 118);
      expect(ended.authState, AuthState.testKey);
      expect(AuthState.words(ended.authState), 'TEST KEY');
      expect(ended.tfrEver, isTrue);

      final live = HostMessage.parse(
              '{"type":"log","seq":null,"i":null,"active":true,"uas":"","mac":"AA:AA:AA:AA:AA:AA",'
              '"first":1700000000,"last":1700000100,"dur":100,"peak_rssi":-60,"auth_state":"none","tfr":false,"emerg":false,"msgs":3}')
          as LogRecordMessage;
      expect(live.seq, isNull);
      expect(live.active, isTrue);
      expect(live.uasId, isNull);
      expect(live.contactKey, 'AA:AA:AA:AA:AA:AA');
      expect(live.lat, isNull);
    });

    test('log_done carries total, next, oldest and live', () {
      final d = HostMessage.parse('{"type":"log_done","n":40,"live":2,"total":52,"clock":true,"next":52,"oldest":12}')
          as LogDoneMessage;
      expect(d.count, 40);
      expect(d.live, 2);
      expect(d.total, 52);
      expect(d.nextSeq, 52);
      expect(d.oldestSeq, 12);
      expect(d.clock, isTrue);
    });

    test('Device info characteristic', () {
      final info = DeviceInfoMessage.fromBytes(utf8.encode(
          '{"fw":"orecchino","ver":"0.6.0","board":"lilygo-t5-epaper-s3-pro","caps":["log","log_since","tfr","wifi","tiles"],"proto":1}'))!;
      expect(info.isOrecchino, isTrue);
      expect(info.has('wifi'), isTrue);
      expect(info.has('traffic'), isFalse);
      expect(DeviceInfoMessage.fromBytes(utf8.encode('{"fw":"other","proto":1}'))!.isOrecchino, isFalse);
      expect(DeviceInfoMessage.fromBytes(utf8.encode('{"fw":"orecchino"}'))!.isOrecchino, isFalse); // no proto
      expect(DeviceInfoMessage.fromBytes([0xff, 0x00]), isNull);
    });

    test('Wi-Fi replies (net_sync.h)', () {
      final n = HostMessage.parse('{"type":"wifi_net","ssid":"Home","rssi":-58,"secure":true,"saved":true,"ch":6}')
          as WifiNetMessage;
      expect(n.saved, isTrue);
      expect(n.channel, 6);
      final d = HostMessage.parse('{"type":"wifi_scan_done","n":0,"err":"scan failed"}') as WifiScanDoneMessage;
      expect(d.error, 'scan failed');
      final st = HostMessage.parse('{"type":"wifi_status","state":"failed","mode":"sync","every_min":15,'
              '"reason":"wrong password","scanning":false,"syncing":false,"clock":true,"tfr_n":0,"ac_n":0,"saved":["Home"]}')
          as WifiStatusMessage;
      expect(st.state, 'failed');
      expect(st.reason, 'wrong password');
      expect(st.mode, 'sync');
      expect(st.saved, ['Home']);
      final e =
          HostMessage.parse('{"type":"wifi_err","cmd":"wifi_join","reason":"needs a bonded link"}') as WifiErrorMessage;
      expect(e.command, 'wifi_join');
      expect(st.pausedByPhone, isFalse);
      expect(st.adsbKm, isNull);
      // A board that is paused by the phone and has a map plan.
      final p = HostMessage.parse('{"type":"wifi_status","state":"idle","mode":"sync","every_min":15,'
          '"adsb_km":10,"tile_km":3,"tile_max_km":14.75,"paused":"phone","saved":[]}') as WifiStatusMessage;
      expect(p.pausedByPhone, isTrue);
      expect((p.adsbKm, p.tileKm, p.tileMaxKm), (10, 3, 14.75));
      final net = HostMessage.parse('{"type":"net","state":"synced","ok":["adsb","tiles"],"failed":[],'
          '"adsb_km":10.0,"map":"Map: 3 km z12-15; 0.8 MB of 11.9 MB","map_tiles":360,"map_have":360,'
          '"tile_max_km":14.75,"storage_full":false}') as NetStatusMessage;
      expect(net.state, 'synced');
      expect(net.map, 'Map: 3 km z12-15; 0.8 MB of 11.9 MB');
      expect(
          (HostMessage.parse('{"type":"net","state":"paused","reason":"phone"}') as NetStatusMessage).reason, 'phone');
      expect(jsonDecode(HostCommands.wifiConfig(adsbKm: 12)), {'cmd': 'wifi_config', 'adsb_km': 12});
      expect(jsonDecode(HostCommands.wifiConfig(adsbKm: 12, tileKm: 4)),
          {'cmd': 'wifi_config', 'adsb_km': 12, 'tile_km': 4});
    });

    test('LogDoneMessage parses next and oldest', () {
      const json = '{"type":"log_done","n":50,"next":101,"oldest":1}';
      final msg = HostMessage.parse(json);
      expect(msg, isA<LogDoneMessage>());
      final done = msg as LogDoneMessage;
      expect(done.count, 50);
      expect(done.nextSeq, 101);
      expect(done.oldestSeq, 1);
    });
  });

  group('HostCommands builders', () {
    test('setTime builds correct json', () {
      final cmd = HostCommands.setTime(1710000000);
      expect(cmd, '{"cmd":"set_time","utc":1710000000}');
    });

    test('setHome includes accuracy and source', () {
      final cmd = HostCommands.setHome(lat: 37.77, lon: -122.41, accuracyM: 5.5, source: 'phone');
      final map = jsonDecode(cmd) as Map<String, dynamic>;
      expect(map['cmd'], 'set_home');
      expect(map['lat'], 37.77);
      expect(map['lon'], -122.41);
      expect(map['acc'], 5.5);
      expect(map['src'], 'phone');
    });

    test('wifiJoin: open network, saved password', () {
      expect(jsonDecode(HostCommands.wifiJoin(ssid: 'Cafe', psk: '')), {'cmd': 'wifi_join', 'ssid': 'Cafe', 'psk': ''});
      expect(jsonDecode(HostCommands.wifiJoin(ssid: 'Home')), {'cmd': 'wifi_join', 'ssid': 'Home'});
    });

    test('logGet with since and afterUtc', () {
      final cmd = HostCommands.logGet(since: 150, afterUtc: 1705000000);
      final map = jsonDecode(cmd) as Map<String, dynamic>;
      expect(map['cmd'], 'log_get');
      expect(map['since'], 150);
      expect(map['after_utc'], 1705000000);
    });
  });
}
