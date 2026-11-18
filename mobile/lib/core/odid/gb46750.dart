// gb46750.dart — GB 46750-2025 (China's 2025 broadcast Remote ID standard)
// as it rides the same Wi-Fi vendor element as ASTM F3411 (OUI FA:0B:BC,
// type 0x0D, one counter byte) on DJI's 2026 firmware. A port of
// firmware/common/gb46750_decode.h; odid_decoder.dart hands it any payload
// whose first byte is 0xFF.
//
// Packet: data type 0xFF, a version byte (bits 7..5 = 1 for V1.x), the
// content length, an item bitmap of three or more bytes (seven items per
// byte from bit 7 down, bit 0 set = another bitmap byte follows), then the
// present items in ascending order at fixed lengths. Coordinates are
// longitude before latitude, int32 in 1e-7 degrees; altitudes are uint16 in
// 0.5 m steps offset by 1000 m, the relative altitude by 9000 m. A decoded
// packet lands in the same OdidUas the ASTM decoder fills.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

import 'odid_decoder.dart';

class Gb46750 {
  const Gb46750._();

  static const int itemCount = 21;

  // 1 serial, 2 registration mark, 3 category, 4 class, 5 remote-station
  // position type, 6 remote-station lon|lat, 7 its altitude, 8 aircraft
  // lon|lat, 9 track, 10 ground speed, 11 relative altitude, 12 vertical
  // speed, 13 geodetic altitude, 14 barometric altitude, 15 status,
  // 16 coordinate system, 17-19 accuracies, 20 Unix ms timestamp, 21 its
  // accuracy.
  static const List<int> itemLen = [0, 20, 8, 1, 1, 1, 8, 2, 8, 2, 2, 2, 1, 2, 2, 1, 1, 1, 1, 1, 6, 1];

  static const int _int32Max = 0x7FFFFFFF;
  static const int _int32Min = -0x80000000;

  /// True for a payload that starts with a GB 46750 packet header rather
  /// than an ODID message: 0xFF can never head an ODID pack (protocol
  /// versions stop at 2), so the two formats cannot be confused.
  static bool looksLike(List<int> d) => d.length >= 6 && (d[0] & 0xFF) == 0xFF && (((d[1] & 0xFF) >> 5) & 0x07) == 1;

  /// (lat, lon) or null for an encoder sentinel or an implausible fix.
  static (double, double)? _coord(List<int> p, int o) {
    final lo = odidRdI32(p, o), la = odidRdI32(p, o + 4);
    if (lo == -1 || la == -1 || lo == _int32Max || la == _int32Max || lo == _int32Min || la == _int32Min) {
      return null; // encoder sentinels
    }
    final lat = la * 1e-7, lon = lo * 1e-7;
    return odidCoordPlausible(lat, lon) ? (lat, lon) : null;
  }

  /// Decode one GB 46750 packet into a fresh [u].
  static bool decode(List<int> d, OdidUas u) {
    if (!looksLike(d)) return false;
    final len = d.length;
    final contentLen = d[2] & 0xFF;
    var present = 0;
    var pos = 3, nbytes = 0;
    var terminated = false;
    while (pos < len) {
      // every bitmap byte is consumed, however many
      final f = d[pos++] & 0xFF;
      if (nbytes < 5) {
        // items beyond 32 have no known length anyway
        for (var b = 0; b < 7; b++) {
          if ((f & (0x80 >> b)) != 0 && nbytes * 7 + b < 32) present |= 1 << (nbytes * 7 + b);
        }
      }
      nbytes++;
      if (nbytes >= 3 && (f & 0x01) == 0) {
        terminated = true;
        break;
      }
    }
    if (!terminated) return false;
    var end = pos + contentLen;
    if (end > len) end = len;
    final c = pos;
    final clen = end - pos;
    var off = 0;
    var any = false;
    u.gb46750 = true;
    u.heightRef = 0; // relative altitude is above the take-off point
    u.dir = -1;
    u.speed = -1;
    u.vspeed = -999;
    u.ts = -1; // ODID's "unknown" markers
    u.altGeo = u.altBaro = u.height = u.opAlt = -1000;
    for (var item = 1; item <= itemCount; item++) {
      if ((present & (1 << (item - 1))) == 0) continue;
      final n = itemLen[item];
      if (off + n > clen) break; // truncated: keep what arrived
      final p = c + off;
      off += n;
      int b(int i) => d[p + i] & 0xFF;
      switch (item) {
        case 1:
          u.uasId[0] = odidCopyText(d, p, 20, maxLen: 40);
          if (u.uasId[0].isNotEmpty) {
            u.hasBasic[0] = true;
            u.idType[0] = 1;
            any = true;
          }
        case 2: // all zeros means "not registered"
          final r = odidCopyText(d, p, 8);
          final blank = r.split('').every((ch) => ch == '0');
          if (!blank) {
            u.hasBasic[1] = true;
            u.idType[1] = 2;
            u.uasId[1] = r;
          }
        case 5:
          u.opLocType = b(0) != 0 ? 1 : 0; // 1 = live remote station, 0 = take-off point
        case 6:
          final ll = _coord(d, p);
          if (ll != null) {
            u.hasSys = true;
            u.opLat = ll.$1;
            u.opLon = ll.$2;
            any = true;
          }
        case 7:
          if (odidRdU16(d, p) != 0) u.opAlt = odidDecodeAlt(odidRdU16(d, p));
        case 8:
          final ll = _coord(d, p);
          if (ll != null) {
            u.hasLoc = true;
            u.lat = ll.$1;
            u.lon = ll.$2;
            any = true;
          }
        case 9:
          if (odidRdU16(d, p) != 0xFFFF) u.dir = odidRdU16(d, p) * 0.1;
        case 10:
          if (odidRdU16(d, p) != 0xFFFF) u.speed = odidRdU16(d, p) * 0.1;
        case 11:
          if (odidRdU16(d, p) != 0) u.height = odidRdU16(d, p) * 0.5 - 9000.0;
        case 12:
          if (b(0) != 0xFF) u.vspeed = ((b(0) & 0x80) != 0 ? -1.0 : 1.0) * (b(0) & 0x7F) * 0.5;
        case 13:
          if (odidRdU16(d, p) != 0) u.altGeo = odidDecodeAlt(odidRdU16(d, p));
        case 14:
          if (odidRdU16(d, p) != 0) u.altBaro = odidDecodeAlt(odidRdU16(d, p));
        case 15:
          // 5 = RID failure in an emergency: the emergency is what matters
          u.status = b(0) == 5 ? 3 : b(0);
        case 17:
          u.hAcc = b(0);
        case 18:
          u.vAcc = b(0);
        case 19:
          u.spdAcc = b(0);
        case 20: // Unix milliseconds, 48 bits
          var ms = 0;
          for (var i = 5; i >= 0; i--) {
            ms = (ms << 8) | b(i);
          }
          final s = ms ~/ 1000;
          if (s != 0) {
            u.ts = (s % 3600).toDouble(); // seconds into the hour, as ODID shows it
            if (s > 1546300800) u.sysTs = (s - 1546300800) & 0xFFFFFFFF; // since 2019-01-01
          }
        case 21:
          u.tsAcc = b(0);
        default:
          break; // 3 category, 4 class, 16 coordinate system: not shown anywhere
      }
    }
    return any;
  }
}
