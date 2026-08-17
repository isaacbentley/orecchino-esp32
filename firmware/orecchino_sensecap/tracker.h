// Minimal on-device track table for the SenseCAP Indicator's screen.
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
  bool     in_tfr;      // position inside a pushed TFR polygon
  char     tfr_id[16];
  uint32_t first_ms, last_ms;
  uint16_t msgs;
  int8_t   peak_rssi;
  float    max_height;   // NAN until known
  bool     tfr_ever;     // entered a TFR at any point in this track's life
};

extern Track g_tracks[TRK_MAX];

Track* tracker_upsert(const uint8_t* mac, const char* uas, uint32_t now,
                      bool* created);
void tracker_expire(uint32_t now);
int tracker_count();
