// Match log: one record per contact the receiver has lost (expired from the
// track table or evicted to make room), kept in NVS so it survives a reset
// and a power cycle, for the desktop app to read back over serial.
//
// Records are fixed-size and live in a ring of LOG_MAX; the oldest drops
// out first. Saving to flash is debounced (log_due, from the loop): a busy
// sky ends many contacts in a burst and NVS should see one write, not one per
// contact -- at most one a minute, so a power cut can lose the last minute.
// Header-only, included once by rx_core.h.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <Arduino.h>
#include <Preferences.h>
#include <limits.h>

#define LOG_MAX      48
#define LOG_SAVE_MS  60000   // at most one 3 KB NVS write a minute
#define LOG_VERSION  1

struct LogRec {
  char     uas[24];      // UAS ID, truncated; empty when only a MAC was heard
  uint8_t  mac[6];       // the contact's most recent address
  uint8_t  src_mask;     // bit0 wifi beacon, bit1 NAN, bit2 BLE
  uint8_t  fmt;          // bit0 ASTM F3411, bit1 GB 46750-2025
  uint32_t first_utc;    // UTC seconds; 0 when the clock was never set
  uint32_t last_utc;
  uint32_t dur_s;        // first heard to last heard
  int32_t  lat_e5;       // last position, 1e-5 degrees; INT32_MIN when none
  int32_t  lon_e5;
  int16_t  max_height;   // metres; INT16_MIN when never reported
  int8_t   peak_rssi;
  uint8_t  auth_state;   // OdidAuthState at the end
  uint8_t  flags;        // bit0 was in a TFR, bit1 reported an emergency
  uint8_t  ua_type;      // ODID UA type, 0 unknown
  uint16_t msgs;         // decoded messages attributed to the contact
};

static LogRec   s_log[LOG_MAX];
static uint8_t  s_log_head = 0;    // next slot to write
static uint8_t  s_log_n    = 0;    // records held
static uint32_t s_log_total = 0;   // records ever written (numbering for the host)
static bool     s_log_dirty = false;
static uint32_t s_log_dirty_ms = 0;

// Wall clock: UTC seconds at millis() == 0, learned from the host's
// set_time (or a board RTC). 0 until then, and records say so.
static uint32_t s_utc_at_boot = 0;
static inline void log_set_utc(uint32_t utc_now, uint32_t now_ms) {
  if (utc_now > now_ms / 1000) s_utc_at_boot = utc_now - now_ms / 1000;
}
static inline uint32_t log_utc(uint32_t ms) {
  return s_utc_at_boot ? s_utc_at_boot + ms / 1000 : 0;
}

static inline void log_load() {
  Preferences p;
  if (!p.begin("orlog", true)) return;
  if (p.getUChar("ver", 0) == LOG_VERSION &&
      p.getBytesLength("recs") == sizeof(s_log)) {
    p.getBytes("recs", s_log, sizeof(s_log));
    s_log_head  = p.getUChar("head", 0) % LOG_MAX;
    s_log_n     = p.getUChar("n", 0);
    s_log_total = p.getULong("total", 0);
    if (s_log_n > LOG_MAX) s_log_n = LOG_MAX;
  }
  p.end();
}

/// The flash side of a save. Takes a copy so the caller can snapshot the
/// ring under its lock and let the slow NVS write happen outside it.
struct LogImage { LogRec recs[LOG_MAX]; uint8_t head, n; uint32_t total; };

static inline void log_snapshot(LogImage* img) {
  memcpy(img->recs, s_log, sizeof(s_log));
  img->head = s_log_head;
  img->n = s_log_n;
  img->total = s_log_total;
  s_log_dirty = false;
}

static inline void log_write(const LogImage* img) {
  Preferences p;
  if (!p.begin("orlog", false)) return;
  p.putUChar("ver", LOG_VERSION);
  p.putBytes("recs", img->recs, sizeof(img->recs));
  p.putUChar("head", img->head);
  p.putUChar("n", img->n);
  p.putULong("total", img->total);
  p.end();
}

static inline void log_clear() {
  memset(s_log, 0, sizeof(s_log));
  s_log_head = 0;
  s_log_n = 0;
  s_log_total = 0;
  s_log_dirty = true;
  s_log_dirty_ms = 0;   // due at the next log_due()
}

/// Summarise a contact into a record (also used for live contacts when the
/// host reads the log, so both come out in the same shape).
static inline void log_fill(LogRec* r, const Track* t) {
  memset(r, 0, sizeof(*r));
  strncpy(r->uas, t->uas, sizeof(r->uas) - 1);
  memcpy(r->mac, t->mac, 6);
  r->src_mask   = t->src_mask;
  r->fmt        = t->fmt;
  r->first_utc  = log_utc(t->first_ms);
  r->last_utc   = log_utc(t->last_ms);
  r->dur_s      = (t->last_ms - t->first_ms) / 1000;
  r->lat_e5     = t->has_pos ? (int32_t)lround(t->lat * 1e5) : INT32_MIN;
  r->lon_e5     = t->has_pos ? (int32_t)lround(t->lon * 1e5) : INT32_MIN;
  r->max_height = isnan(t->max_height) ? INT16_MIN
                : (int16_t)constrain(lroundf(t->max_height), -32000, 32000);
  r->peak_rssi  = t->peak_rssi;
  r->auth_state = t->auth_state;
  r->flags      = (t->tfr_ever ? 1 : 0) | (t->emerg_ever ? 2 : 0);
  r->ua_type    = t->ua_type;
  r->msgs       = t->msgs;
}

/// Record a contact that has ended. Called with the track table locked.
static inline void log_add(const Track* t, uint32_t now_ms) {
  log_fill(&s_log[s_log_head], t);
  s_log_head = (s_log_head + 1) % LOG_MAX;
  if (s_log_n < LOG_MAX) s_log_n++;
  s_log_total++;
  if (!s_log_dirty) s_log_dirty_ms = now_ms ? now_ms : 1;
  s_log_dirty = true;
}

/// True when pending records have settled long enough to write.
static inline bool log_due(uint32_t now_ms) {
  return s_log_dirty && (s_log_dirty_ms == 0 || now_ms - s_log_dirty_ms >= LOG_SAVE_MS);
}

/// The i-th held record, oldest first.
static inline const LogRec* log_at(int i) {
  int start = (s_log_head + LOG_MAX - s_log_n) % LOG_MAX;
  return &s_log[(start + i) % LOG_MAX];
}
