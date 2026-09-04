// Shared UI vocabulary for every board with a screen: the palette, the
// contact/emergency bar state, range and RSSI helpers. Each board lays its
// own screen out — a 4.7" e-paper board and a 1.9" strip with a knob are
// different instruments — but they agree on what the colours mean.
#pragma once
#include <Arduino.h>
#include <math.h>
#include "tracker.h"

extern bool     g_home_set;
extern double   g_home_lat, g_home_lon;
extern uint32_t g_seen_count;

// A "contact" means heard within the last minute (RID transmits at 1-3 Hz);
// anything older is history and renders freshness-grey until it expires.
#define UI_ACTIVE_MS 60000UL

#define RGB565(r, g, b) ((uint16_t)((((r) & 0xF8) << 8) | (((g) & 0xFC) << 3) | ((b) >> 3)))
static const uint16_t C_BG     = RGB565(0x07, 0x09, 0x0E);
static const uint16_t C_TEXT   = RGB565(0xE2, 0xE8, 0xF0);
static const uint16_t C_MUTED  = RGB565(0x8A, 0x99, 0xAD);
static const uint16_t C_ACCENT = RGB565(0x35, 0xD0, 0xBA);
static const uint16_t C_DANGER = RGB565(0xE0, 0x5A, 0x5A);
static const uint16_t C_OK     = RGB565(0x5E, 0xCB, 0x7A);
static const uint16_t C_AMBER  = RGB565(0xE0, 0xA8, 0x3A);
static const uint16_t C_BAR    = RGB565(0x10, 0x14, 0x1C);
static const uint16_t C_EDGE   = RGB565(0x1C, 0x22, 0x2C);
static const uint16_t C_METER  = RGB565(0x20, 0x26, 0x30);
static const uint16_t TRACK_COLORS[] = {
  RGB565(0x00, 0xB4, 0xD8), RGB565(0xFF, 0x9D, 0x6F), RGB565(0xB7, 0x8B, 0xFF),
  RGB565(0x6F, 0xB6, 0xFF), RGB565(0xE0, 0xA8, 0x3A), RGB565(0x7F, 0xD6, 0xA0),
};
#define N_TRACK_COLORS (sizeof(TRACK_COLORS) / sizeof(TRACK_COLORS[0]))

/// RSSI → 0…1 over a practical Remote ID window (−95 … −35 dBm)
static inline double ui_rssi01(int rssi) {
  double v = (rssi + 95) / 60.0;
  return v < 0 ? 0 : (v > 1 ? 1 : v);
}

static inline double ui_dist_m(double la1, double lo1, double la2, double lo2) {
  double dla = (la2 - la1) * M_PI / 180, dlo = (lo2 - lo1) * M_PI / 180;
  double a = sin(dla / 2) * sin(dla / 2) +
             cos(la1 * M_PI / 180) * cos(la2 * M_PI / 180) *
             sin(dlo / 2) * sin(dlo / 2);
  return 12742000.0 * asin(sqrt(a));
}

/// Initial bearing from (la1,lo1) to (la2,lo2), degrees true 0..360.
static inline double ui_bearing(double la1, double lo1, double la2, double lo2) {
  double p1 = la1 * M_PI / 180, p2 = la2 * M_PI / 180;
  double dl = (lo2 - lo1) * M_PI / 180;
  double y = sin(dl) * cos(p2);
  double x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl);
  double b = atan2(y, x) * 180 / M_PI;
  return b < 0 ? b + 360 : b;
}

static inline void ui_fmt_range(char* out, size_t n, double m) {
  if (m >= 1000) snprintf(out, n, "%.1fkm", m / 1000);
  else snprintf(out, n, "%dm", (int)m);
}

static inline bool ui_stale(const Track* t, uint32_t now) {
  return now - t->last_ms > UI_ACTIVE_MS;
}
/// Loud state: emergency, TFR incursion, or a forged identity — and
/// current. History never shouts.
static inline bool ui_danger(const Track* t, uint32_t now) {
  return (t->status == 3 || t->in_tfr || t->auth_state == 4) && !ui_stale(t, now);
}

// Bar state: dark = quiet sky, amber = active contact, red = emergency.
enum UiAlert : uint8_t { UI_QUIET = 0, UI_CONTACT = 1, UI_EMERGENCY = 2 };

struct UiSummary {
  int     tracked;    // rows in the table
  int     active;     // heard within UI_ACTIVE_MS
  bool    emergency;  // any active emergency status
  bool    danger;     // any active TFR / bad-auth / emergency
  UiAlert alert;
  uint32_t newest_age_s;  // UINT32_MAX when nothing tracked
};

static inline void ui_summarize(UiSummary* s, uint32_t now) {
  memset(s, 0, sizeof(*s));
  s->newest_age_s = UINT32_MAX;
  for (int i = 0; i < TRK_MAX; i++) {
    const Track* t = &g_tracks[i];
    if (!t->used) continue;
    s->tracked++;
    uint32_t age = (now - t->last_ms) / 1000;
    if (age < s->newest_age_s) s->newest_age_s = age;
    if (ui_stale(t, now)) continue;
    s->active++;
    if (t->status == 3) s->emergency = true;
    if (ui_danger(t, now)) s->danger = true;
  }
  s->alert = s->emergency ? UI_EMERGENCY : (s->active ? UI_CONTACT : UI_QUIET);
}

/// Header wording shared by every board, so the SenseCAP and a handheld
/// say the same thing about the same sky.
static inline void ui_headline(char* b, size_t n, const UiSummary* s) {
  if (s->emergency)
    snprintf(b, n, "EMERGENCY  %d CONTACT%s", s->tracked, s->tracked == 1 ? "" : "S");
  else if (s->active > 0)
    snprintf(b, n, "%d CONTACT%s", s->tracked, s->tracked == 1 ? "" : "S");
  else if (s->tracked > 0)
    snprintf(b, n, "%d TRACKED", s->tracked);
  else
    snprintf(b, n, "NO CONTACTS");
}

static inline const char* ui_status_name(uint8_t st) {
  return st == 2 ? "airborne" : st == 1 ? "on ground"
       : st == 3 ? "EMERGENCY" : "unknown";
}
static inline const char* ui_auth_text(uint8_t st) {
  return st == 3 ? "ID sig: valid"
       : st == 4 ? "ID SIG INVALID"
       : st == 2 ? "ID sig: untrusted"
       : st == 1 ? "ID sig: partial" : "";
}
static inline uint16_t ui_auth_color(uint8_t st) {
  return st == 3 ? C_OK : st == 4 ? C_DANGER : st == 2 ? C_AMBER : C_MUTED;
}
