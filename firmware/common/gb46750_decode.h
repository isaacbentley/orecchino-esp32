// GB 46750-2025 -- China's 2025 broadcast Remote ID standard -- as it rides
// the same Wi-Fi vendor element as ASTM F3411 (OUI FA:0B:BC, type 0x0D,
// one counter byte) on DJI's 2026 firmware. Included by odid_decode.h,
// which owns OdidUas and the byte readers; not for direct inclusion.
//
// Packet: data type 0xFF, a version byte (bits 7..5 = 1 for V1.x), the
// content length, an item bitmap of three or more bytes (seven items per
// byte from bit 7 down, bit 0 set = another bitmap byte follows), then
// the present items in ascending order at fixed lengths. Coordinates are
// longitude before latitude, int32 in 1e-7 degrees; altitudes are uint16
// in 0.5 m steps offset by 1000 m, the relative altitude by 9000 m.
// The layout and the reference capture come from the Light RID Scanner
// project (GPL-3.0); see THIRD_PARTY.md. A decoded packet lands in the
// same OdidUas the ASTM decoder fills, so the tracker, the JSON line and
// every screen treat both formats alike.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#define GB46750_ITEM_COUNT 21
static const uint8_t GB46750_ITEM_LEN[GB46750_ITEM_COUNT + 1] = {
  // 1 serial, 2 registration mark, 3 category, 4 class, 5 remote-station
  // position type, 6 remote-station lon|lat, 7 its altitude, 8 aircraft
  // lon|lat, 9 track, 10 ground speed, 11 relative altitude, 12 vertical
  // speed, 13 geodetic altitude, 14 barometric altitude, 15 status,
  // 16 coordinate system, 17-19 accuracies, 20 Unix ms timestamp, 21 its accuracy
  0, 20, 8, 1, 1, 1, 8, 2, 8, 2, 2, 2, 1, 2, 2, 1, 1, 1, 1, 1, 6, 1
};

/// True for a payload that starts with a GB 46750 packet header rather
/// than an ODID message: 0xFF can never head an ODID pack (protocol
/// versions stop at 2), so the two formats cannot be confused.
static inline bool gb46750_looks_like(const uint8_t* d, int len) {
  return len >= 6 && d[0] == 0xFF && ((d[1] >> 5) & 0x07) == 1;
}

static inline bool gb46750_coord(const uint8_t* p, double* lat, double* lon) {
  int32_t lo = odid_rd_i32(p), la = odid_rd_i32(p + 4);
  if (lo == -1 || la == -1 || lo == INT32_MAX || la == INT32_MAX ||
      lo == INT32_MIN || la == INT32_MIN)
    return false;                                  // encoder sentinels
  *lat = la * 1e-7;
  *lon = lo * 1e-7;
  return odid_coord_plausible(*lat, *lon);
}

/// Decode one GB 46750 packet. The caller has zeroed `u`.
static inline bool gb46750_decode(const uint8_t* d, int len, OdidUas* u) {
  if (!gb46750_looks_like(d, len)) return false;
  int content_len = d[2];
  uint32_t present = 0;
  int pos = 3, nbytes = 0;
  bool terminated = false;
  while (pos < len) {                    // every bitmap byte is consumed, however many
    uint8_t f = d[pos++];
    if (nbytes < 5)                      // items beyond 32 have no known length anyway
      for (int b = 0; b < 7; b++)
        if ((f & (0x80 >> b)) && nbytes * 7 + b < 32) present |= 1u << (nbytes * 7 + b);
    nbytes++;
    if (nbytes >= 3 && !(f & 0x01)) { terminated = true; break; }
  }
  if (!terminated) return false;
  int end = pos + content_len;
  if (end > len) end = len;
  const uint8_t* c = d + pos;
  int clen = end - pos, off = 0;
  bool any = false;
  u->gb46750 = true;
  u->height_ref = 0;                     // relative altitude is above the take-off point
  u->dir = -1; u->speed = -1; u->vspeed = -999; u->ts = -1;   // ODID's "unknown" markers
  u->alt_geo = u->alt_baro = u->height = u->op_alt = -1000;
  for (int item = 1; item <= GB46750_ITEM_COUNT; item++) {
    if (!(present & (1u << (item - 1)))) continue;
    int n = GB46750_ITEM_LEN[item];
    if (off + n > clen) break;           // truncated: keep what arrived
    const uint8_t* p = c + off;
    off += n;
    switch (item) {
      case 1:
        odid_copy_text(u->uas_id[0], sizeof(u->uas_id[0]), p, 20);
        if (u->uas_id[0][0]) { u->has_basic[0] = true; u->id_type[0] = 1; any = true; }
        break;
      case 2: {                          // all zeros means "not registered"
        char r[9]; odid_copy_text(r, sizeof(r), p, 8);
        bool blank = true;
        for (const char* q = r; *q; q++) if (*q != '0') blank = false;
        if (!blank) { u->has_basic[1] = true; u->id_type[1] = 2; memcpy(u->uas_id[1], r, sizeof(r)); }
        break; }
      case 5: u->op_loc_type = p[0] ? 1 : 0; break;   // 1 = live remote station, 0 = take-off point
      case 6: { double la, lo;
        if (gb46750_coord(p, &la, &lo)) { u->has_sys = true; u->op_lat = la; u->op_lon = lo; any = true; }
        break; }
      case 7: if (odid_rd_u16(p)) u->op_alt = odid_decode_alt(odid_rd_u16(p)); break;
      case 8: { double la, lo;
        if (gb46750_coord(p, &la, &lo)) { u->has_loc = true; u->lat = la; u->lon = lo; any = true; }
        break; }
      case 9:  if (odid_rd_u16(p) != 0xFFFF) u->dir = odid_rd_u16(p) * 0.1f; break;
      case 10: if (odid_rd_u16(p) != 0xFFFF) u->speed = odid_rd_u16(p) * 0.1f; break;
      case 11: if (odid_rd_u16(p)) u->height = odid_rd_u16(p) * 0.5f - 9000.0f; break;
      case 12: if (p[0] != 0xFF) u->vspeed = ((p[0] & 0x80) ? -1.0f : 1.0f) * (float)(p[0] & 0x7F) * 0.5f; break;
      case 13: if (odid_rd_u16(p)) u->alt_geo = odid_decode_alt(odid_rd_u16(p)); break;
      case 14: if (odid_rd_u16(p)) u->alt_baro = odid_decode_alt(odid_rd_u16(p)); break;
      case 15: u->status = p[0] == 5 ? 3 : p[0]; break;   // 5 = RID failure in an emergency: the emergency is what matters
      case 17: u->h_acc = p[0]; break;
      case 18: u->v_acc = p[0]; break;
      case 19: u->spd_acc = p[0]; break;
      case 20: {                         // Unix milliseconds
        uint64_t ms = 0;
        for (int i = 5; i >= 0; i--) ms = (ms << 8) | p[i];
        uint64_t s = ms / 1000;
        if (s) {
          u->ts = (float)(s % 3600);                       // seconds into the hour, as ODID shows it
          if (s > 1546300800ULL) u->sys_ts = (uint32_t)(s - 1546300800ULL);   // since 2019-01-01, as ODID counts it
        }
        break; }
      case 21: u->ts_acc = p[0]; break;
      default: break;                    // 3 category, 4 class, 16 coordinate system: not shown anywhere
    }
  }
  return any;
}
