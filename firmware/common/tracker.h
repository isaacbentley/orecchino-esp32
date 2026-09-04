// On-device track table, shared by every receiver with a screen. Header-only
// so a board sketch gets it by including rx_core.h — Arduino only compiles
// .cpp files that live inside the sketch directory.
//
// Keyed by UAS ID when known, else MAC; LRU-evicted by last_seen when full
// (never clobbers a fixed slot — the classic reference-receiver bug).
#pragma once
#include <Arduino.h>

#define TRK_MAX      16
#define TRK_EXPIRE_MS 600000UL

struct Track {
  bool     used;
  uint8_t  mac[6];
  char     uas[41];
  int8_t   rssi;
  uint8_t  src_mask;    // bit0 wifi, bit1 nan, bit2 ble
  uint8_t  status;      // ODID operational status; 3 = emergency
  bool     has_pos;
  double   lat, lon;
  float    height;      // m AGL, NAN when unknown
  float    speed;       // m/s, NAN when unknown
  float    heading;     // deg true, NAN when unknown
  // Authentication verification, mirroring OdidAuthState:
  // 0 none, 1 partial, 2 unknown key, 3 ID signature valid, 4 invalid.
  uint8_t  auth_state;
  bool     in_tfr;      // position inside a pushed TFR polygon
  char     tfr_id[16];
  uint32_t first_ms, last_ms;
  uint16_t msgs;
  int8_t   peak_rssi;
  float    max_height;   // NAN until known
  bool     tfr_ever;     // entered a TFR at any point in this track's life
};

// One table for the whole program. Defined in rx_core.h (included exactly
// once, by the sketch); a `static` here would hand every source file that
// includes this header its own empty copy — the radio core filling one while
// the screen reads another.
extern Track g_tracks[TRK_MAX];

static inline Track* tracker_upsert(const uint8_t* mac, const char* uas,
                                    uint32_t now, bool* created) {
  if (created) *created = false;
  Track* by_uas = nullptr;
  Track* by_mac = nullptr;
  Track* free_slot = nullptr;
  Track* oldest = nullptr;
  for (int i = 0; i < TRK_MAX; i++) {
    Track* t = &g_tracks[i];
    if (!t->used) {
      if (!free_slot) free_slot = t;
      continue;
    }
    if (uas && uas[0] && strncmp(t->uas, uas, sizeof(t->uas)) == 0) by_uas = t;
    if (memcmp(t->mac, mac, 6) == 0) by_mac = t;
    if (!oldest || t->last_ms < oldest->last_ms) oldest = t;
  }
  // Identity wins over hardware address. Falling back to the MAC is only
  // safe when there is no identity conflict — otherwise two aircraft that
  // share a MAC (randomised addresses, a spoofer, or one transmitter
  // sending several UAS IDs) collapse into a single contact whose ID
  // flip-flops, hiding one of them entirely.
  Track* t = by_uas;
  if (!t && by_mac && (!uas || !uas[0] || !by_mac->uas[0])) t = by_mac;
  if (!t) {
    t = free_slot ? free_slot : oldest;   // LRU eviction, never slot 0 forever
    memset(t, 0, sizeof(*t));
    t->used = true;
    t->first_ms = now;
    t->height = NAN;
    t->speed = NAN;
    t->heading = NAN;
    t->max_height = NAN;
    t->peak_rssi = -127;
    if (created) *created = true;
  }
  memcpy(t->mac, mac, 6);
  if (uas && uas[0]) {
    strncpy(t->uas, uas, sizeof(t->uas) - 1);
    t->uas[sizeof(t->uas) - 1] = 0;
  }
  t->last_ms = now;
  t->msgs++;
  return t;
}

static inline void tracker_expire(uint32_t now) {
  for (int i = 0; i < TRK_MAX; i++) {
    if (g_tracks[i].used && now - g_tracks[i].last_ms > TRK_EXPIRE_MS)
      g_tracks[i].used = false;
  }
}

static inline int tracker_count() {
  int n = 0;
  for (int i = 0; i < TRK_MAX; i++)
    if (g_tracks[i].used) n++;
  return n;
}

/// Short badge for an authentication state. "ID" is deliberate: the
/// signature covers the drone's identity, never its reported position.
static inline const char* track_auth_badge(uint8_t st) {
  // Plain ASCII so every board's font renders it identically; the boards
  // add colour (green / red / amber / grey) — never a different word.
  switch (st) {
    case 3:  return "ID OK";    // signature valid (identity only, never position)
    case 4:  return "ID BAD";   // signature invalid: a security event
    case 1:  return "ID..";     // pages still arriving
    case 2:  return "ID?";      // signed, key not trusted
    default: return "";
  }
}
