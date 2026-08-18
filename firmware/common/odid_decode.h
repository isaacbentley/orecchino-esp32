// ASTM F3411 / Open Drone ID broadcast message decoder.
// Pure C, no Arduino dependencies: shared by both firmware targets and
// compiled host-side by tests/odid_test.c. Messages are 25 bytes; header
// byte is (message type << 4) | protocol version.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

// Page 0 holds 17 auth bytes, pages 1..15 hold 23 each; the wire Length
// field is a uint8, so 255 is the practical ceiling.
#define ODID_AUTH_MAX_BYTES 255

// Decoded state for one UAS, filled from whichever messages were received.
typedef struct {
  bool    has_basic[2];
  uint8_t id_type[2], ua_type[2];
  char    uas_id[2][41];

  bool    has_loc;
  uint8_t status, height_ref;
  float   dir, speed, vspeed;
  double  lat, lon;
  float   alt_baro, alt_geo, height;
  uint8_t h_acc, v_acc, baro_acc, spd_acc, ts_acc;
  float   ts;

  bool    has_self;
  uint8_t self_type;
  char    self_desc[24];

  bool    has_sys;
  uint8_t op_loc_type, class_type;
  double  op_lat, op_lon;
  uint16_t area_count;
  float   area_radius, area_ceiling, area_floor;
  uint8_t cat_eu, class_eu;
  float   op_alt;
  uint32_t sys_ts;   // seconds since 2019-01-01 00:00 UTC

  bool    has_op;
  uint8_t op_id_type;
  char    op_id[21];

  // Authentication (message type 2). Pages may arrive together in a pack or
  // spread across frames, so the assembled state carries a bitmap of which
  // pages have been seen; a signature can only be checked once complete.
  // The signature covers the Basic ID message as it appeared on the wire,
  // so keep those bytes verbatim.
  bool     has_basic_raw;
  uint8_t  basic_raw[25];

  bool     has_auth;
  uint8_t  auth_type;
  uint8_t  auth_last_page;
  uint8_t  auth_len;          // total bytes claimed by page 0
  uint32_t auth_ts;
  uint16_t auth_pages_seen;   // bit N set = page N received
  uint8_t  auth_data[ODID_AUTH_MAX_BYTES];
} OdidUas;

/// True once every page from 0..auth_last_page has arrived.
static inline bool odid_auth_complete(const OdidUas* u) {
  if (!u->has_auth || !(u->auth_pages_seen & 1)) return false;
  uint16_t want = (uint16_t)((1u << (u->auth_last_page + 1)) - 1);
  return (u->auth_pages_seen & want) == want;
}

static inline int16_t odid_rd_i16(const uint8_t* p) {
  return (int16_t)(p[0] | (p[1] << 8));
}
static inline uint16_t odid_rd_u16(const uint8_t* p) {
  return (uint16_t)(p[0] | (p[1] << 8));
}
static inline int32_t odid_rd_i32(const uint8_t* p) {
  return (int32_t)((uint32_t)p[0] | ((uint32_t)p[1] << 8) |
                   ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24));
}
static inline uint32_t odid_rd_u32(const uint8_t* p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
         ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static inline float odid_decode_alt(uint16_t raw) {
  return raw * 0.5f - 1000.0f;  // -1000 = unknown
}

// Copy a fixed-width ASCII field, trimming NULs/trailing space, sanitising
// anything that would break a JSON string.
static inline void odid_copy_text(char* dst, size_t dstsz, const uint8_t* src,
                                  size_t n) {
  size_t o = 0;
  for (size_t i = 0; i < n && o + 1 < dstsz; i++) {
    uint8_t c = src[i];
    if (c == 0) break;
    if (c < 0x20 || c > 0x7E || c == '"' || c == '\\') c = '.';
    dst[o++] = (char)c;
  }
  while (o > 0 && dst[o - 1] == ' ') o--;
  dst[o] = 0;
}

static inline void odid_decode_msg(const uint8_t* m, OdidUas* u) {
  uint8_t type = m[0] >> 4;
  switch (type) {
    case 0x0: {  // Basic ID
      int slot = u->has_basic[0] ? 1 : 0;
      if (u->has_basic[0] && u->id_type[0] == (m[1] >> 4)) slot = 0;  // refresh
      u->has_basic[slot] = true;
      u->id_type[slot] = m[1] >> 4;
      u->ua_type[slot] = m[1] & 0x0F;
      if (u->id_type[slot] == 3) {  // UTM UUID: binary, hex-encode
        char* o = u->uas_id[slot];
        for (int i = 0; i < 20; i++) {
          sprintf(o, "%02x", m[2 + i]);
          o += 2;
        }
      } else {
        odid_copy_text(u->uas_id[slot], sizeof(u->uas_id[slot]), m + 2, 20);
      }
      if (slot == 0) {
        memcpy(u->basic_raw, m, 25);
        u->has_basic_raw = true;
      }
      break;
    }
    case 0x1: {  // Location / Vector
      u->has_loc = true;
      u->status     = m[1] >> 4;
      u->height_ref = (m[1] >> 2) & 1;
      uint8_t ew    = (m[1] >> 1) & 1;
      uint8_t mult  = m[1] & 1;
      u->dir    = (m[2] <= 180) ? (float)m[2] + (ew ? 180.0f : 0.0f) : -1.0f;
      u->speed  = (m[3] == 255) ? -1.0f
                : (mult ? m[3] * 0.75f + 63.75f : m[3] * 0.25f);
      // Raw 126 (+63 m/s) is the spec's invalid marker (range is +/-62);
      // -999 sentinel, verified against the reference Wireshark dissector.
      u->vspeed = ((int8_t)m[4] == 126) ? -999.0f : (int8_t)m[4] * 0.5f;
      u->lat = odid_rd_i32(m + 5) * 1e-7;
      u->lon = odid_rd_i32(m + 9) * 1e-7;
      u->alt_baro = odid_decode_alt(odid_rd_u16(m + 13));
      u->alt_geo  = odid_decode_alt(odid_rd_u16(m + 15));
      u->height   = odid_decode_alt(odid_rd_u16(m + 17));
      u->v_acc    = m[19] >> 4;
      u->h_acc    = m[19] & 0x0F;
      u->baro_acc = m[20] >> 4;
      u->spd_acc  = m[20] & 0x0F;
      uint16_t ts = odid_rd_u16(m + 21);
      u->ts     = (ts == 0xFFFF) ? -1.0f : ts * 0.1f;
      u->ts_acc = m[23] & 0x0F;
      break;
    }
    case 0x3: {  // Self ID
      u->has_self  = true;
      u->self_type = m[1];
      odid_copy_text(u->self_desc, sizeof(u->self_desc), m + 2, 23);
      break;
    }
    case 0x4: {  // System
      u->has_sys     = true;
      u->op_loc_type = m[1] & 0x03;
      u->class_type  = (m[1] >> 2) & 0x07;
      u->op_lat = odid_rd_i32(m + 2) * 1e-7;
      u->op_lon = odid_rd_i32(m + 6) * 1e-7;
      u->area_count   = odid_rd_u16(m + 10);
      u->area_radius  = m[12] * 10.0f;
      u->area_ceiling = odid_decode_alt(odid_rd_u16(m + 13));
      u->area_floor   = odid_decode_alt(odid_rd_u16(m + 15));
      u->cat_eu   = m[17] >> 4;
      u->class_eu = m[17] & 0x0F;
      u->op_alt = odid_decode_alt(odid_rd_u16(m + 18));
      u->sys_ts = odid_rd_u32(m + 20);
      break;
    }
    case 0x5: {  // Operator ID
      u->has_op = true;
      u->op_id_type = m[1];
      odid_copy_text(u->op_id, sizeof(u->op_id), m + 2, 20);
      break;
    }
    case 0x2: {  // Authentication
      uint8_t page = m[1] & 0x0F;
      u->has_auth = true;
      u->auth_type = m[1] >> 4;
      if (page == 0) {
        // LastPageIndex arrives straight off the air. The page field is 4
        // bits, so 15 is the highest page that can ever be addressed —
        // clamp, or odid_auth_complete() shifts past the width of its
        // operand on a crafted frame.
        u->auth_last_page = m[2] > 15 ? 15 : m[2];
        u->auth_len = m[3];
        u->auth_ts = odid_rd_u32(m + 4);
        int n = u->auth_len < 17 ? u->auth_len : 17;
        memcpy(u->auth_data, m + 8, n);
      } else if (page <= 15) {
        int off = 17 + (page - 1) * 23;
        int n = 23;
        if (off + n > ODID_AUTH_MAX_BYTES) n = ODID_AUTH_MAX_BYTES - off;
        if (n > 0) memcpy(u->auth_data + off, m + 2, n);
      }
      u->auth_pages_seen |= (uint16_t)(1u << page);
      break;
    }
    default:
      break;  // unknown message types are ignored
  }
}

// Accepts either a single message or a message pack (type 0xF).
static inline bool odid_decode_payload(const uint8_t* d, int len, OdidUas* u) {
  memset(u, 0, sizeof(*u));
  if (len < 25) return false;
  uint8_t type = d[0] >> 4;
  bool any = false;
  if (type == 0xF) {
    if (len < 3 || d[1] != 25) return false;
    int n = d[2];
    if (n > 9) n = 9;
    for (int i = 0; i < n; i++) {
      const uint8_t* m = d + 3 + i * 25;
      if (3 + (i + 1) * 25 > len) break;
      if ((m[0] >> 4) <= 0x5) {
        odid_decode_msg(m, u);
        any = true;
      }
    }
  } else if (type <= 0x5) {
    odid_decode_msg(d, u);
    any = true;
  }
  return any && (u->has_basic[0] || u->has_loc || u->has_sys ||
                 u->has_self || u->has_op);
}
