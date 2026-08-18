// ASTM F3411 / Open Drone ID message *encoder* — the inverse of
// odid_decode.h. Used by the TX test beacon (firmware/orecchino_tx) and by
// the host tests, which round-trip encode->decode to pin the wire format.
//
// Everything here builds a TEST payload by design: the caller supplies the
// ID, and orecchino_tx fixes it to an obviously-synthetic serial so a test
// beacon can never be mistaken for a real aircraft.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#define ODID_MSG_SIZE 25

// Live state a beacon transmits; mirrors the fields the receivers show.
typedef struct {
  const char* uas_id;      // serial number (CTA-2063-A style)
  uint8_t     ua_type;     // 2 = multirotor
  uint8_t     status;      // 0 undeclared, 1 ground, 2 airborne, 3 emergency
  double      lat, lon;
  float       alt_geo_m;   // WGS-84 altitude
  float       height_m;    // AGL, above takeoff
  float       speed_ms;    // horizontal
  float       vspeed_ms;   // + up; NAN -> transmit the "unknown" marker
  float       dir_deg;     // 0..359 true
  float       ts_s;        // seconds since the hour (0..3600)
  const char* self_desc;   // free text
  double      op_lat, op_lon;
  float       op_alt_m;
  const char* op_id;       // operator registration
} OdidTxState;

static inline void odid_put_u16(uint8_t* p, uint16_t v) {
  p[0] = (uint8_t)(v & 0xFF);
  p[1] = (uint8_t)(v >> 8);
}
static inline void odid_put_i32(uint8_t* p, int32_t v) {
  uint32_t u = (uint32_t)v;
  p[0] = (uint8_t)(u & 0xFF);
  p[1] = (uint8_t)((u >> 8) & 0xFF);
  p[2] = (uint8_t)((u >> 16) & 0xFF);
  p[3] = (uint8_t)((u >> 24) & 0xFF);
}
static inline void odid_put_u32(uint8_t* p, uint32_t v) {
  p[0] = (uint8_t)(v & 0xFF);
  p[1] = (uint8_t)((v >> 8) & 0xFF);
  p[2] = (uint8_t)((v >> 16) & 0xFF);
  p[3] = (uint8_t)((v >> 24) & 0xFF);
}
// Altitude encoding: 0.5 m steps with a -1000 m offset; 0 means unknown.
static inline uint16_t odid_enc_alt(float m) {
  if (isnan(m)) return 0;
  float v = (m + 1000.0f) * 2.0f;
  if (v < 0) v = 0;
  if (v > 65535.0f) v = 65535.0f;
  return (uint16_t)(v + 0.5f);
}
static inline void odid_put_text(uint8_t* p, const char* s, size_t n) {
  memset(p, 0, n);
  if (!s) return;
  size_t l = strlen(s);
  if (l > n) l = n;
  memcpy(p, s, l);
}

// --- individual messages (25 B each, protocol version 2) -------------------

static inline void odid_build_basic_id(uint8_t* m, const OdidTxState* s) {
  memset(m, 0, ODID_MSG_SIZE);
  m[0] = 0x02;                                   // Basic ID, v2
  m[1] = (uint8_t)((1 << 4) | (s->ua_type & 0x0F));  // ID type 1 = serial
  odid_put_text(m + 2, s->uas_id, 20);
}

static inline void odid_build_location(uint8_t* m, const OdidTxState* s) {
  memset(m, 0, ODID_MSG_SIZE);
  m[0] = 0x12;  // Location/Vector, v2

  float dir = s->dir_deg;
  while (dir < 0) dir += 360.0f;
  while (dir >= 360.0f) dir -= 360.0f;
  uint8_t ew = dir >= 180.0f ? 1 : 0;

  // Speeds above 63.75 m/s switch to the coarse 0.75 m/s multiplier.
  uint8_t mult = s->speed_ms > 63.75f ? 1 : 0;
  uint8_t raw_speed;
  if (s->speed_ms < 0 || isnan(s->speed_ms)) {
    raw_speed = 255;  // unknown
  } else if (mult) {
    float v = (s->speed_ms - 63.75f) / 0.75f;
    raw_speed = (uint8_t)(v < 0 ? 0 : (v > 254 ? 254 : v + 0.5f));
  } else {
    float v = s->speed_ms / 0.25f;
    raw_speed = (uint8_t)(v > 254 ? 254 : v + 0.5f);
  }

  m[1] = (uint8_t)(((s->status & 0x0F) << 4) | (ew << 1) | mult);
  m[2] = (uint8_t)(ew ? (dir - 180.0f) : dir);
  m[3] = raw_speed;
  // 126 is the spec's invalid marker (valid range is +/-62 raw).
  m[4] = isnan(s->vspeed_ms) ? 126
                             : (uint8_t)(int8_t)(s->vspeed_ms / 0.5f);
  odid_put_i32(m + 5, (int32_t)(s->lat * 1e7));
  odid_put_i32(m + 9, (int32_t)(s->lon * 1e7));
  odid_put_u16(m + 13, 0);                          // baro alt unknown
  odid_put_u16(m + 15, odid_enc_alt(s->alt_geo_m));
  odid_put_u16(m + 17, odid_enc_alt(s->height_m));
  m[19] = (3 << 4) | 9;   // vertical <25 m, horizontal <30 m
  m[20] = (4 << 4) | 1;   // baro <10 m, speed <10 m/s
  odid_put_u16(m + 21, (uint16_t)(s->ts_s * 10.0f));
  m[23] = 10;             // timestamp accuracy 1.0 s
}

static inline void odid_build_self_id(uint8_t* m, const OdidTxState* s) {
  memset(m, 0, ODID_MSG_SIZE);
  m[0] = 0x32;  // Self ID, v2
  m[1] = 0;     // text description
  odid_put_text(m + 2, s->self_desc, 23);
}

static inline void odid_build_system(uint8_t* m, const OdidTxState* s,
                                     uint32_t sys_ts) {
  memset(m, 0, ODID_MSG_SIZE);
  m[0] = 0x42;  // System, v2
  m[1] = 0x01;  // classification none, operator location = takeoff/dynamic
  odid_put_i32(m + 2, (int32_t)(s->op_lat * 1e7));
  odid_put_i32(m + 6, (int32_t)(s->op_lon * 1e7));
  odid_put_u16(m + 10, 1);   // area count
  m[12] = 0;                 // area radius
  odid_put_u16(m + 13, 0);   // ceiling unknown
  odid_put_u16(m + 15, 0);   // floor unknown
  m[17] = 0;                 // EU category/class undeclared
  odid_put_u16(m + 18, odid_enc_alt(s->op_alt_m));
  odid_put_u32(m + 20, sys_ts);
}

static inline void odid_build_operator_id(uint8_t* m, const OdidTxState* s) {
  memset(m, 0, ODID_MSG_SIZE);
  m[0] = 0x52;  // Operator ID, v2
  m[1] = 0;     // operator ID type
  odid_put_text(m + 2, s->op_id, 20);
}

/// Build the 5-message pack (Basic ID, Location, Self ID, System, Operator).
/// Writes 3 + 5*25 = 128 bytes; returns the length.
static inline int odid_build_pack(uint8_t* out, const OdidTxState* s,
                                  uint32_t sys_ts) {
  out[0] = 0xF2;            // Message Pack, v2
  out[1] = ODID_MSG_SIZE;
  out[2] = 5;
  odid_build_basic_id(out + 3 + 0 * ODID_MSG_SIZE, s);
  odid_build_location(out + 3 + 1 * ODID_MSG_SIZE, s);
  odid_build_self_id(out + 3 + 2 * ODID_MSG_SIZE, s);
  odid_build_system(out + 3 + 3 * ODID_MSG_SIZE, s, sys_ts);
  odid_build_operator_id(out + 3 + 4 * ODID_MSG_SIZE, s);
  return 3 + 5 * ODID_MSG_SIZE;
}
