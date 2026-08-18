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
#define ODID_PACK_MAX_MESSAGES 9   // a pack may never carry more

// Live state a beacon transmits; mirrors the fields the receivers show.
typedef struct {
  const char* uas_id;      // serial number (CTA-2063-A style)
  const char* caa_id;      // optional second Basic ID (CAA registration)
  uint8_t     proto_ver;   // 0/1 = F3411-19, 2 = F3411-22
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

// Header byte: message type in the high nibble, protocol version in the low.
static inline uint8_t odid_hdr(uint8_t type, const OdidTxState* s) {
  return (uint8_t)((type << 4) | (s->proto_ver & 0x0F));
}

static inline void odid_build_basic_id(uint8_t* m, const OdidTxState* s) {
  memset(m, 0, ODID_MSG_SIZE);
  m[0] = odid_hdr(0, s);
  m[1] = (uint8_t)((1 << 4) | (s->ua_type & 0x0F));  // ID type 1 = serial
  odid_put_text(m + 2, s->uas_id, 20);
}

// Second Basic ID carrying a CAA registration number (ID type 2). The spec
// allows two Basic IDs — one serial, one registration — and receivers are
// supposed to keep both.
static inline void odid_build_basic_id_caa(uint8_t* m, const OdidTxState* s) {
  memset(m, 0, ODID_MSG_SIZE);
  m[0] = odid_hdr(0, s);
  m[1] = (uint8_t)((2 << 4) | (s->ua_type & 0x0F));  // ID type 2 = CAA reg
  odid_put_text(m + 2, s->caa_id ? s->caa_id : "", 20);
}

// Authentication message (type 2), paginated. Page 0 carries the page
// count, total length and timestamp, then 17 bytes of data; pages 1..15
// carry 23 bytes each. Most transmitters skip Auth entirely, so this is
// the message that finds out whether a receiver handles it — or chokes.
#define ODID_AUTH_PAGE0_DATA 17
#define ODID_AUTH_PAGEN_DATA 23

static inline int odid_auth_pages(int data_len) {
  if (data_len <= ODID_AUTH_PAGE0_DATA) return 1;
  return 1 + (data_len - ODID_AUTH_PAGE0_DATA + ODID_AUTH_PAGEN_DATA - 1) /
                 ODID_AUTH_PAGEN_DATA;
}

static inline void odid_build_auth_page(uint8_t* m, const OdidTxState* s,
                                        uint8_t auth_type, int page,
                                        const uint8_t* data, int data_len,
                                        uint32_t timestamp) {
  memset(m, 0, ODID_MSG_SIZE);
  m[0] = odid_hdr(2, s);
  m[1] = (uint8_t)(((auth_type & 0x0F) << 4) | (page & 0x0F));
  if (page == 0) {
    // Byte 2 is LastPageIndex — the index of the final page, not the count.
    // Byte 3 is the TOTAL auth length across all pages, and it is a uint8,
    // so 255 is the real ceiling even though 16 pages could hold 362.
    m[2] = (uint8_t)(odid_auth_pages(data_len) - 1);
    m[3] = (uint8_t)(data_len > 255 ? 255 : data_len);
    odid_put_u32(m + 4, timestamp);
    int n = data_len < ODID_AUTH_PAGE0_DATA ? data_len : ODID_AUTH_PAGE0_DATA;
    if (data && n > 0) memcpy(m + 8, data, n);
  } else {
    int off = ODID_AUTH_PAGE0_DATA + (page - 1) * ODID_AUTH_PAGEN_DATA;
    int n = data_len - off;
    if (n > ODID_AUTH_PAGEN_DATA) n = ODID_AUTH_PAGEN_DATA;
    if (data && n > 0) memcpy(m + 2, data + off, n);
  }
}

static inline void odid_build_location(uint8_t* m, const OdidTxState* s) {
  memset(m, 0, ODID_MSG_SIZE);
  m[0] = odid_hdr(1, s);

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
  m[0] = odid_hdr(3, s);
  m[1] = 0;     // text description
  odid_put_text(m + 2, s->self_desc, 23);
}

static inline void odid_build_system(uint8_t* m, const OdidTxState* s,
                                     uint32_t sys_ts) {
  memset(m, 0, ODID_MSG_SIZE);
  m[0] = odid_hdr(4, s);
  m[1] = 0x01;  // classification none, operator location = takeoff/dynamic
  odid_put_i32(m + 2, (int32_t)(s->op_lat * 1e7));
  odid_put_i32(m + 6, (int32_t)(s->op_lon * 1e7));
  odid_put_u16(m + 10, 1);   // area count
  m[12] = 0;                 // area radius
  odid_put_u16(m + 13, 0);   // ceiling unknown
  odid_put_u16(m + 15, 0);   // floor unknown
  m[17] = 0;                 // EU category/class undeclared
  odid_put_u16(m + 18, odid_enc_alt(s->op_alt_m));
  // The System timestamp field only exists in F3411-22a (protocol v2);
  // under v0/v1 those bytes are reserved and must stay zero.
  odid_put_u32(m + 20, s->proto_ver >= 2 ? sys_ts : 0);
}

static inline void odid_build_operator_id(uint8_t* m, const OdidTxState* s) {
  memset(m, 0, ODID_MSG_SIZE);
  m[0] = odid_hdr(5, s);
  m[1] = 0;     // operator ID type
  odid_put_text(m + 2, s->op_id, 20);
}

/// Build the 5-message pack (Basic ID, Location, Self ID, System, Operator).
/// Writes 3 + 5*25 = 128 bytes; returns the length.
static inline int odid_build_pack(uint8_t* out, const OdidTxState* s,
                                  uint32_t sys_ts) {
  int n = 0;
  out[1] = ODID_MSG_SIZE;
  odid_build_basic_id(out + 3 + (n++) * ODID_MSG_SIZE, s);
  if (s->caa_id && s->caa_id[0])
    odid_build_basic_id_caa(out + 3 + (n++) * ODID_MSG_SIZE, s);
  odid_build_location(out + 3 + (n++) * ODID_MSG_SIZE, s);
  odid_build_self_id(out + 3 + (n++) * ODID_MSG_SIZE, s);
  odid_build_system(out + 3 + (n++) * ODID_MSG_SIZE, s, sys_ts);
  odid_build_operator_id(out + 3 + (n++) * ODID_MSG_SIZE, s);
  out[0] = odid_hdr(0xF, s);
  out[2] = (uint8_t)n;
  return 3 + n * ODID_MSG_SIZE;
}

/// Build one message of the rotating single-message sequence (for the
/// receivers that only ever see one message per advertisement).
/// Returns 25; `idx` selects Basic/Location/SelfID/System/OperatorID.
static inline int odid_build_single(uint8_t* out, const OdidTxState* s,
                                    uint32_t sys_ts, int idx) {
  switch (idx % 5) {
    case 0: odid_build_basic_id(out, s); break;
    case 1: odid_build_location(out, s); break;
    case 2: odid_build_self_id(out, s); break;
    case 3: odid_build_system(out, s, sys_ts); break;
    default: odid_build_operator_id(out, s); break;
  }
  return ODID_MSG_SIZE;
}
