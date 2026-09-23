// traffic.h — ADS-B traffic alerts: manned aircraft near the drones we hear.
//
// The reference implementation of docs/plans/mobile-app-and-t5-wifi.md §8.
// Ported line for line to app/Sources/Orecchino/TrafficRules.swift and
// mobile/lib/core/traffic/traffic_rules.dart; all three are tested against
// every file in tests/vectors/traffic/*.json. Change one, change all three
// and the vectors. Pure C/C++ (libc + libm only): no Arduino, host-testable.
//
// ---------------------------------------------------------------------------
// THE RULES (§8.2). Pairs are drone x aircraft; the observer is the board,
// phone or Mac showing the alert.
//
//   level     kind        condition                                  words
//   WARNING   NEAR        live drone + fresh aircraft, horizontal    TRAFFIC NEAR DRONE <id>
//                         <= 1000 m and |vertical| <= 150 m, or
//                         vertical unknown and horizontal <= 1000 m
//   WARNING   CONVERGING  live drone + fresh aircraft, both          TRAFFIC CONVERGING WITH <id>, <n> S
//                         velocities known, closest point of
//                         approach in (0, 60] s, miss distance
//                         < 500 m and |vertical at CPA| <= 150 m
//                         (or vertical unknown)
//   CAUTION   LOW         fresh aircraft <= 3000 m from the          LOW TRAFFIC <brg> <d.d> KM
//                         observer and below observer elevation
//                         + 460 m (1,500 ft)
//   ADVISORY  EMERGENCY   squawk 7500 / 7600 / 7700 or emergency     HIJACK / RADIO FAILURE /
//                         flag, <= 30 km from the observer           EMERGENCY + callsign
//
// Aircraft on the ground (readsb/adsb.lol "alt_baro":"ground"; wire "gnd":1)
// are common near airfields (taxiing, parked) and are not airborne traffic:
//   - they never raise LOW (an existing LOW clears 20 s after landing);
//   - CONVERGING is not computed for them (no closest-approach projection);
//   - NEAR a live drone is still raised, as a CAUTION (not a warning) with
//     the words ", AIRCRAFT ON GROUND": a drone within 1 km of an aircraft on
//     an apron or taxiway is worth showing, but it must not flash, notify like
//     a warning, or push airborne warnings out of the alert list;
//   - EMERGENCY is still raised (a 7700 after landing is still reported);
//   - they are not counted in near_count (the "N airborne aircraft within
//     3 km" count) but in ground_count; they stay in aircraft_count and on
//     maps and lists. With none airborne and some on the ground within 3 km
//     the summary says "no airborne ADS-B traffic reported within 3 km".
//
// Definitions and the choices made where §8 leaves room:
// - near_count: fresh airborne aircraft within 3 km of the observer (of any
//   drone with a position when the observer position is unknown);
//   ground_count: the same for aircraft on the ground.
// - Fresh aircraft: position age < 30 s. Present: age <= 60 s (older ones are
//   ignored entirely, as if dropped). A drone is "live" when the caller says
//   so (heard within 60 s with a position, §8.2); a drone without a finite
//   position never pairs.
// - Stale data: the ADS-B set is older than 30 s (data_age_s > 30), or its
//   age is unknown. Then NO new alert is raised; existing alerts are kept by
//   the hysteresis below with their last numbers and `held` set, and surfaces
//   show `TRAFFIC DATA STALE` (traffic_summary) and `ADS-B <n> s old`
//   (traffic_age_words) instead of a count. No source at all (have_data
//   false): nothing is raised either, and the summary says `no ADS-B source`.
// - Vertical (pairs): aircraft alt_geom_m minus drone alt_geo_m, both above
//   the WGS-84 ellipsoid. Never barometric, never the drone's height above
//   take-off. Either missing -> vertical unknown: the alert is RAISED with
//   the words `HEIGHT UNKNOWN`, never dropped. Callers pass NaN for unknown;
//   the ODID/firmware marker -1000 (anything <= -999) is also read as unknown.
// - Converging: flat-earth relative position r (aircraft minus drone,
//   east/north metres) and relative velocity w = v_aircraft - v_drone
//   (ground speed/track, speed/heading). t = -(r.w)/|w|^2 when |w|^2 > 1e-9;
//   miss = |r + w t|. Vertical at CPA = vertical + aircraft vs_mps * t (vs
//   unknown -> 0; the drone's vertical rate is not used). If NEAR and
//   CONVERGING both hold, the pair shows NEAR (cpa_s is still filled in).
// - LOW: aircraft height = alt_geom_m, else alt_baro_m (then `approx`), else
//   unknown (raised with `HEIGHT UNKNOWN`). Threshold = observer elev_m + 460
//   m, or 460 m above sea level when elev_m is unknown (then `approx`). Needs
//   the observer position. vert_m = aircraft height - elev_m (NaN unknown).
//   observer elev_m should be the ellipsoid height; MSL is acceptable (the
//   geoid separation is far inside the 460 m margin).
// - EMERGENCY distance is from the observer; with no observer position, from
//   the nearest drone with a position; with neither, unknown (raised: the
//   aircraft set is already a 30 km query). vert_m is always NaN.
// - Hysteresis (wall clock, never evaluation counts): an alert, once raised,
//   is kept while its raise condition holds OR while it is "in hold"; it is
//   removed when it has been out of hold continuously for >= 20 s.
//     pairs:     in hold = both present, horizontal <= 1300 m and (vertical
//                unknown or |vertical| <= 200 m) — "beyond 1.3 km or 200 m"
//                releases. NEAR stays NEAR while in hold even if only
//                CONVERGING is raised; outside hold a raised CONVERGING
//                replaces NEAR.
//     LOW/EMERG: in hold = the geometric condition without the freshness
//                and staleness requirements (aircraft still present).
//   A pair or aircraft missing from this evaluation is out of hold and keeps
//   its last numbers and words; a held pair still present gets its words
//   rebuilt from the current numbers (a held CONVERGING with no CPA now
//   reads "TRAFFIC CONVERGING WITH <id>" without seconds).
// - Ordering: level desc, kind (NEAR, CONVERGING, LOW, EMERGENCY), horiz_m
//   asc (NaN last), drone id, hex (byte order). At most TRAFFIC_MAX_ALERTS;
//   when full, a new alert replaces the last in that order only if it ranks
//   before it. Candidates are visited drones x aircraft (pairs), then
//   aircraft (LOW), then aircraft (EMERGENCY), in array order.
// - Text: drone <id> is a readable tail of the drone's id (the same tail the
//   T5 marks show): a "uas:"/"mac:" prefix is dropped; a MAC (12 hex digits,
//   or six hex pairs joined by ':' or '-') reads "MAC " + its last three
//   bytes ("3C71BF4CC5A2" -> "MAC 4C:C5:A2"); else the id when <= 8
//   characters, else its last 5 grown past any leading non-alphanumeric
//   ("1581F20000D9A03" -> "D9A03", "DRONE-B-9A01" -> "B-9A01", never
//   "-9A01"). <n> S = floor(cpa_s + 0.5). Distances in km with one decimal
//   = floor(m / 100 + 0.5) tenths. Bearing words are the 8-point compass,
//   floor((deg + 22.5) / 45) mod 8. Callsign, else the hex in capitals.
//   Suffixes: ", AIRCRAFT ON GROUND" (wins over the next; on
//   a LOW only while it is held after landing), ", HEIGHT UNKNOWN", or (LOW
//   only) ", APPROX.".
// - Words: never "collision", "conflict", "safe", "clear" or "TCAS". The most
//   any surface says about absence is `no ADS-B traffic reported within 3 km`
//   with the data age.
// - Distances: flat earth at the mean latitude with the longitude difference
//   wrapped into [-180, 180] (antimeridian), R = 6371000 m; good to well
//   under 1% out to the 30 km horizon.
//
// ---------------------------------------------------------------------------
// THE `traffic` HOST LINES (§8.1). Sent to any receiver by the Mac or phone
// app over USB or BLE, one JSON object per line (keep each line under the
// 1,600-byte host buffer: at most 6 aircraft per line), nearest first:
//
//   {"cmd":"traffic","t":1727000000,"age_s":2,"ac":[
//     {"hex":"a1b2c3","cs":"UAL123","ty":"B738","lat":37.8,"lon":-122.4,
//      "altg_m":820,"altb_ft":2650,"gs_kt":180,"trk":270,"vr_fpm":-640,
//      "sq":"7700","em":1,"age_s":3},
//     {"hex":"a0ad1d","cs":"UAL1668","lat":37.62,"lon":-122.39,"gnd":1,
//      "gs_kt":0,"sq":"7222","age_s":24}, ...]}
//   ... more traffic lines with the same "t" ...
//   {"cmd":"traffic_done","n":14,"age_s":2}
//
//   t       unix seconds of the data set (0/absent: unknown). A traffic line
//           whose t differs from the set being received starts a new set
//           (the rest of a set whose done was lost is discarded).
//   age_s   top level, optional: how old the set is (s since the sender
//           fetched it). On traffic_done it wins over the traffic lines'.
//           Absent: 0. Present but not a finite number >= 0 (e.g. null):
//           the set is treated as stale.
//   n       on traffic_done: aircraft the sender sent; a mismatch with what
//           arrived sets g_traffic_partial (the set is still used).
//   ac[]    hex (required, <= 6 hex digits, stored lower case), cs (callsign,
//           trimmed, <= 8), ty (type, <= 4), lat/lon (required), altg_m
//           (geometric altitude, m, WGS-84 ellipsoid), altb_ft (pressure
//           altitude, ft), gs_kt (ground speed, kt), trk (track, deg true),
//           vr_fpm (vertical rate, ft/min), sq (squawk, "7700" or 7700), em
//           (emergency flag, 0/1/true/false), gnd (on the ground, 0/1/true/
//           false; "altb_ft":"ground" means the same), age_s (position age, s;
//           required: an aircraft with no finite age, or older than 60 s, is
//           dropped). Any other field is unknown when absent or null.
//   traffic_done with no traffic lines before it installs an EMPTY set: the
//   sender says "fresh data, no aircraft". Send it every 10 s while you
//   have data, including when the set is empty.
//
// On receipt of traffic_done the set replaces the live one atomically
// (traffic_ingest): aircraft older than 60 s dropped, those more than 30 km
// from g_traffic_observer (when known) dropped, nearest first, at most
// TRAFFIC_MAX_AIRCRAFT.
//
// ---------------------------------------------------------------------------
// FIRMWARE CONTRACT
//   bool traffic_host_line(const char* line, uint32_t now_ms)
//        true when the line was a traffic/traffic_done command (handled).
//   void traffic_ingest(const TrafficAircraft* ac, int n, uint32_t data_ms,
//                       uint32_t now_ms)
//        for a board's own fetch (T5 Wi-Fi): installs a complete set; data_ms
//        is the local millis() the data refers to. `ac` must not be
//        g_traffic_ac.
//   void traffic_tick(const TrafficDrone* d, int nd, uint32_t now_ms)
//        evaluates g_traffic_ac against g_traffic_observer into
//        g_traffic_result, carrying g_traffic_state.
//   void traffic_evaluate(...) the pure rule function (any caller-owned
//        state and result).
// All g_traffic_* are touched from the loop task only; a fetch task must hand
// its set to the loop (or hold the board's lock) before traffic_ingest.
// RAM: ~2.9 KB per aircraft set (two: live + staging) + the state and the
// result; on the device all four are allocated in PSRAM when fitted.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <math.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#if defined(ESP_PLATFORM) && defined(__cplusplus)
#include "ext_ram.h"   // ext_new: the big g_traffic_* tables go to PSRAM
#endif

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#define TRAFFIC_MAX_AIRCRAFT   32
#define TRAFFIC_MAX_ALERTS     16
#define TRAFFIC_ID_LEN         41     // drone id, like Track.uas
#define TRAFFIC_TEXT_LEN       64

#define TRAFFIC_FRESH_S        30.0   // position age < 30 s: fresh
#define TRAFFIC_PRESENT_S      60.0   // position age <= 60 s: kept
#define TRAFFIC_STALE_S        30.0   // data age > 30 s: stale
#define TRAFFIC_NEAR_H_M     1000.0
#define TRAFFIC_NEAR_V_M      150.0
#define TRAFFIC_CPA_MAX_S      60.0
#define TRAFFIC_CPA_MISS_M    500.0
#define TRAFFIC_HOLD_H_M     1300.0
#define TRAFFIC_HOLD_V_M      200.0
#define TRAFFIC_CLEAR_MS     20000u
#define TRAFFIC_LOW_R_M      3000.0
#define TRAFFIC_LOW_ABOVE_M   460.0
#define TRAFFIC_EMERG_R_M   30000.0
#define TRAFFIC_KEEP_R_M    30000.0   // ingest: within 30 km of the observer
#define TRAFFIC_COUNT_R_M    3000.0   // near_count radius
#define TRAFFIC_SOURCE_LOST_S 600.0   // traffic_tick: no set for 10 min = no source

#define TRAFFIC_EARTH_R_M  6371000.0
#define TRAFFIC_DEG        (M_PI / 180.0)
#define TRAFFIC_FT_TO_M    0.3048
#define TRAFFIC_KT_TO_MPS  (1852.0 / 3600.0)

typedef enum {
  TRAFFIC_NONE     = 0,
  TRAFFIC_ADVISORY = 1,
  TRAFFIC_CAUTION  = 2,
  TRAFFIC_WARNING  = 3
} TrafficLevel;

typedef enum {
  TRAFFIC_KIND_NEAR       = 0,
  TRAFFIC_KIND_CONVERGING = 1,
  TRAFFIC_KIND_LOW        = 2,
  TRAFFIC_KIND_EMERGENCY  = 3
} TrafficKind;

// One aircraft as reported by ADS-B. NaN = unknown for every double except
// lat/lon (required). squawk is the four octal digits read as a decimal
// number (7700), 0 when unknown.
typedef struct {
  char     hex[7];        // ICAO 24-bit address, lower-case hex
  char     callsign[9];
  char     type[5];       // ICAO type designator, e.g. B738
  double   lat, lon;
  double   alt_geom_m;    // geometric altitude, WGS-84 ellipsoid
  double   alt_baro_m;    // pressure altitude (shown, never compared with drones)
  double   gs_mps;        // ground speed
  double   track_deg;     // true track
  double   vs_mps;        // vertical rate, + climbing
  uint16_t squawk;
  bool     emergency;
  bool     on_ground;     // reported on the ground (taxiing, parked)
  uint32_t seen_ms;       // local millis() of the position
} TrafficAircraft;

typedef struct {
  char   id[TRAFFIC_ID_LEN];  // stable id (UAS id, else MAC); text uses its last 5
  double lat, lon;            // NaN: no position (never pairs)
  double alt_geo_m;           // ODID geodetic altitude (WGS-84), NaN unknown
  double speed_mps;           // NaN unknown
  double heading_deg;         // NaN unknown
  bool   live;                // heard within 60 s with a position
} TrafficDrone;

typedef struct {
  double lat, lon;            // NaN unknown
  double elev_m;              // NaN unknown
} TrafficObserver;

typedef struct {
  uint8_t level;              // TrafficLevel
  uint8_t kind;               // TrafficKind
  bool    held;               // kept by hysteresis; the raise condition is false now
  bool    height_unknown;
  bool    approx;             // LOW: elevation unknown or barometric height used
  bool    on_ground;          // the aircraft is reported on the ground
  int16_t drone_index;        // index into this evaluation's drones[], -1 none
  int16_t ac_index;           // index into this evaluation's aircraft[], -1 gone
  char    drone_id[TRAFFIC_ID_LEN];  // "" for LOW / EMERGENCY
  char    hex[7];
  char    callsign[9];
  double  horiz_m;            // drone-aircraft (pairs) or observer-aircraft
  double  vert_m;             // aircraft minus drone (pairs), minus elevation (LOW); NaN
  double  bearing_deg;        // from the drone (pairs) / observer to the aircraft
  double  cpa_s;              // closest approach in (0, 60] s, else NaN
  double  cpa_m;              // miss distance at cpa_s, else NaN
  double  age_s;              // aircraft position age
  char    text[TRAFFIC_TEXT_LEN];
} TrafficAlert;

typedef struct {
  TrafficAlert a;
  uint32_t seen_ms;           // aircraft position time, for age_s
  uint32_t out_since_ms;
  bool     out;               // out of hold since out_since_ms
  bool     used;
  bool     visited;           // scratch
} TrafficEntry;

// Caller-owned hysteresis memory; zero-initialise (or traffic_state_reset).
typedef struct {
  TrafficEntry e[TRAFFIC_MAX_ALERTS];
} TrafficState;

typedef struct {
  TrafficAlert alerts[TRAFFIC_MAX_ALERTS];
  uint8_t n;
  uint8_t highest;            // TrafficLevel of alerts[0], NONE when n == 0
  bool    have_data;
  bool    stale;
  double  data_age_s;         // NaN without data
  uint8_t near_count;         // fresh airborne aircraft within 3 km of the observer
  uint8_t ground_count;       // fresh aircraft on the ground within 3 km (not in near_count)
  uint8_t aircraft_count;     // aircraft present (<= 60 s)
} TrafficResult;

// ---------------------------------------------------------------------------
// Small helpers

// snprintf for words that are cut when they do not fit their field (alert
// text, a screen line). The cut is intended, so the text goes through
// vsnprintf, where the compiler's truncation check does not second-guess it.
static inline void traffic_textf(char* out, size_t n, const char* fmt, ...)
    __attribute__((format(printf, 3, 4)));
static inline void traffic_textf(char* out, size_t n, const char* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(out, n, fmt, ap);
  va_end(ap);
}

static inline bool traffic_known(double v) { return isfinite(v); }
static inline bool traffic_alt_known(double v) { return isfinite(v) && v > -999.0; }

static inline const char* traffic_level_name(uint8_t l) {
  switch (l) {
    case TRAFFIC_WARNING:  return "warning";
    case TRAFFIC_CAUTION:  return "caution";
    case TRAFFIC_ADVISORY: return "advisory";
    default:               return "none";
  }
}

static inline const char* traffic_kind_name(uint8_t k) {
  switch (k) {
    case TRAFFIC_KIND_NEAR:       return "near";
    case TRAFFIC_KIND_CONVERGING: return "converging";
    case TRAFFIC_KIND_LOW:        return "low";
    default:                      return "emergency";
  }
}

// East/north offset in metres from point 1 to point 2 (flat earth, wrapped).
static inline void traffic_offset_m(double lat1, double lon1, double lat2, double lon2,
                                    double* dx, double* dy) {
  double dlon = lon2 - lon1;
  if (dlon > 180.0) dlon -= 360.0;
  else if (dlon < -180.0) dlon += 360.0;
  double mlat = (lat1 + lat2) * 0.5 * TRAFFIC_DEG;
  *dx = dlon * TRAFFIC_DEG * cos(mlat) * TRAFFIC_EARTH_R_M;
  *dy = (lat2 - lat1) * TRAFFIC_DEG * TRAFFIC_EARTH_R_M;
}

static inline double traffic_distance_m(double lat1, double lon1, double lat2, double lon2) {
  double dx, dy;
  traffic_offset_m(lat1, lon1, lat2, lon2, &dx, &dy);
  return sqrt(dx * dx + dy * dy);
}

static inline double traffic_bearing_of(double dx, double dy) {
  double b = atan2(dx, dy) / TRAFFIC_DEG;
  if (b < 0.0) b += 360.0;
  if (b >= 360.0) b -= 360.0;
  return b;
}

static inline const char* traffic_compass8(double deg) {
  static const char* const names[8] = {"N", "NE", "E", "SE", "S", "SW", "W", "NW"};
  int i = (int)floor((deg + 22.5) / 45.0) % 8;
  if (i < 0) i += 8;
  return names[i];
}

// Position age in seconds (never negative; wraps like millis()).
static inline double traffic_age_s(uint32_t seen_ms, uint32_t now_ms) {
  int32_t d = (int32_t)(now_ms - seen_ms);
  if (d < 0) d = 0;
  return d / 1000.0;
}

static inline bool traffic_hexc(char c) {
  return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}
static inline bool traffic_alnum(char c) {
  return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}
static inline char traffic_upper(char c) { return (c >= 'a' && c <= 'z') ? (char)(c - 32) : c; }

// Readable drone id for the words (see the header comment).
static inline void traffic_drone_label(const char* id, char* out, size_t n) {
  if (!strncmp(id, "uas:", 4) || !strncmp(id, "mac:", 4)) id += 4;
  size_t len = strlen(id);
  const char* b = NULL;                      // the last three bytes' digits
  if (len == 12) {
    bool ok = true;
    for (size_t i = 0; i < 12 && ok; i++) ok = traffic_hexc(id[i]);
    if (ok) b = id + 6;
  } else if (len == 17) {
    bool ok = true;
    for (size_t i = 0; i < 17 && ok; i++)
      ok = (i % 3 == 2) ? (id[i] == ':' || id[i] == '-') && id[i] == id[2] : traffic_hexc(id[i]);
    if (ok) b = id + 9;
  }
  if (b) {
    int step = len == 12 ? 2 : 3;
    snprintf(out, n, "MAC %c%c:%c%c:%c%c", traffic_upper(b[0]), traffic_upper(b[1]),
             traffic_upper(b[step]), traffic_upper(b[step + 1]),
             traffic_upper(b[2 * step]), traffic_upper(b[2 * step + 1]));
    return;
  }
  if (len <= 8) { snprintf(out, n, "%s", id); return; }
  size_t tail = 5;
  while (tail < len && !traffic_alnum(id[len - tail])) tail++;
  snprintf(out, n, "%s", id + len - tail);
}

static inline void traffic_ac_name(const TrafficAircraft* a, char* out, size_t n) {
  if (a->callsign[0]) { snprintf(out, n, "%s", a->callsign); return; }
  size_t i = 0;
  for (; a->hex[i] && i + 1 < n; i++) {
    char c = a->hex[i];
    out[i] = (c >= 'a' && c <= 'z') ? (char)(c - 32) : c;
  }
  out[i] = 0;
}

// "ADS-B 6 s old"
static inline void traffic_age_words(double age_s, char* out, size_t n) {
  snprintf(out, n, "ADS-B %ld s old", (long)floor(age_s + 0.5));
}

static inline void traffic_km_text(double m, char* out, size_t n) {
  long t = (long)floor(m / 100.0 + 0.5);
  snprintf(out, n, "%ld.%ld", t / 10, t % 10);
}

// ---------------------------------------------------------------------------
// Evaluation

static inline int traffic_alert_cmp(const TrafficAlert* a, const TrafficAlert* b) {
  if (a->level != b->level) return a->level > b->level ? -1 : 1;
  if (a->kind != b->kind) return a->kind < b->kind ? -1 : 1;
  bool an = isnan(a->horiz_m), bn = isnan(b->horiz_m);
  if (an != bn) return an ? 1 : -1;
  if (!an && a->horiz_m != b->horiz_m) return a->horiz_m < b->horiz_m ? -1 : 1;
  int c = strcmp(a->drone_id, b->drone_id);
  if (c) return c < 0 ? -1 : 1;
  c = strcmp(a->hex, b->hex);
  return c < 0 ? -1 : (c > 0 ? 1 : 0);
}

static inline void traffic_state_reset(TrafficState* s) { memset(s, 0, sizeof(*s)); }

static inline TrafficEntry* traffic_find(TrafficState* s, uint8_t fam, const char* drone_id,
                                         const char* hex) {
  for (int i = 0; i < TRAFFIC_MAX_ALERTS; i++) {
    TrafficEntry* e = &s->e[i];
    if (!e->used || strcmp(e->a.hex, hex)) continue;
    if (fam == 0 && e->a.kind <= TRAFFIC_KIND_CONVERGING && !strcmp(e->a.drone_id, drone_id)) return e;
    if (fam != 0 && e->a.kind == fam) return e;
  }
  return NULL;
}

// A free slot, or the slot of the last-ranked alert when `cand` ranks before it.
static inline TrafficEntry* traffic_slot(TrafficState* s, const TrafficAlert* cand) {
  TrafficEntry* worst = NULL;
  for (int i = 0; i < TRAFFIC_MAX_ALERTS; i++) {
    TrafficEntry* e = &s->e[i];
    if (!e->used) return e;
    if (!worst || traffic_alert_cmp(&e->a, &worst->a) > 0) worst = e;
  }
  if (worst && traffic_alert_cmp(cand, &worst->a) < 0) return worst;
  return NULL;
}

static inline void traffic_pair_text(TrafficAlert* a, uint8_t kind) {
  char id[TRAFFIC_ID_LEN];
  traffic_drone_label(a->drone_id, id, sizeof(id));
  const char* hu = a->on_ground ? ", AIRCRAFT ON GROUND"
                 : a->height_unknown ? ", HEIGHT UNKNOWN" : "";
  if (kind == TRAFFIC_KIND_NEAR)
    traffic_textf(a->text, sizeof(a->text), "TRAFFIC NEAR DRONE %s%s", id, hu);
  else if (isnan(a->cpa_s))
    traffic_textf(a->text, sizeof(a->text), "TRAFFIC CONVERGING WITH %s%s", id, hu);
  else
    traffic_textf(a->text, sizeof(a->text), "TRAFFIC CONVERGING WITH %s, %ld S%s", id,
                  (long)floor(a->cpa_s + 0.5), hu);
}

// A pair with an aircraft on the ground is a caution, not a warning.
static inline uint8_t traffic_kind_level(uint8_t kind, bool on_ground) {
  return kind <= TRAFFIC_KIND_CONVERGING ? (on_ground ? TRAFFIC_CAUTION : TRAFFIC_WARNING)
       : (kind == TRAFFIC_KIND_LOW ? TRAFFIC_CAUTION : TRAFFIC_ADVISORY);
}

// Raise or refresh the entry for `cand` (fam 0: a pair, else the kind).
// raw: the raise condition holds now (cand->kind is what it raises); hold: in
// hold. A pair keeps NEAR while in hold even when only CONVERGING is raised.
// Pair words are rebuilt from the current numbers for the kind kept.
static inline void traffic_apply(TrafficState* s, uint8_t fam, const TrafficAlert* cand,
                                 bool raw, bool hold, uint32_t seen_ms, uint32_t now_ms) {
  TrafficEntry* e = traffic_find(s, fam, cand->drone_id, cand->hex);
  uint8_t kind = cand->kind;
  if (e) {
    if (!raw) kind = e->a.kind;
    else if (fam == 0 && e->a.kind == TRAFFIC_KIND_NEAR && hold) kind = TRAFFIC_KIND_NEAR;
  } else {
    if (!raw) return;
    e = traffic_slot(s, cand);
    if (!e) return;
    memset(e, 0, sizeof(*e));
    e->used = true;
  }
  e->visited = true;
  e->seen_ms = seen_ms;
  e->a = *cand;
  e->a.kind = kind;
  e->a.level = traffic_kind_level(kind, e->a.on_ground);
  e->a.held = !raw;
  if (fam == 0) traffic_pair_text(&e->a, kind);
  if (raw || hold) {
    e->out = false;
  } else if (!e->out) {
    e->out = true;
    e->out_since_ms = now_ms;
  }
}

// The rule function. drones/aircraft may be NULL when their count is 0.
// have_data false: no ADS-B source; data_ms is then ignored.
static inline void traffic_evaluate(const TrafficDrone* drones, int nd,
                                    const TrafficAircraft* ac, int na,
                                    const TrafficObserver* obs,
                                    bool have_data, uint32_t data_ms, uint32_t now_ms,
                                    TrafficState* st, TrafficResult* out) {
  memset(out, 0, sizeof(*out));
  out->have_data = have_data;
  out->data_age_s = have_data ? traffic_age_s(data_ms, now_ms) : NAN;
  out->stale = have_data && !(out->data_age_s <= TRAFFIC_STALE_S);
  const bool can_raise = have_data && !out->stale;
  const bool obs_pos = obs && traffic_known(obs->lat) && traffic_known(obs->lon);
  const bool obs_elev = obs && traffic_alt_known(obs->elev_m);

  for (int k = 0; k < TRAFFIC_MAX_ALERTS; k++) st->e[k].visited = false;

  // Presence and counts.
  for (int j = 0; j < na; j++) {
    const TrafficAircraft* a = &ac[j];
    double age = traffic_age_s(a->seen_ms, now_ms);
    if (age > TRAFFIC_PRESENT_S || !traffic_known(a->lat) || !traffic_known(a->lon)) continue;
    out->aircraft_count++;
    if (!(age < TRAFFIC_FRESH_S)) continue;
    bool near = false;
    if (obs_pos) {
      near = traffic_distance_m(obs->lat, obs->lon, a->lat, a->lon) <= TRAFFIC_COUNT_R_M;
    } else {
      for (int i = 0; i < nd && !near; i++)
        if (traffic_known(drones[i].lat) && traffic_known(drones[i].lon))
          near = traffic_distance_m(drones[i].lat, drones[i].lon, a->lat, a->lon) <= TRAFFIC_COUNT_R_M;
    }
    if (near) { if (a->on_ground) out->ground_count++; else out->near_count++; }
  }

  // Pairs.
  for (int i = 0; i < nd; i++) {
    const TrafficDrone* d = &drones[i];
    if (!traffic_known(d->lat) || !traffic_known(d->lon)) continue;
    for (int j = 0; j < na; j++) {
      const TrafficAircraft* a = &ac[j];
      double age = traffic_age_s(a->seen_ms, now_ms);
      if (age > TRAFFIC_PRESENT_S || !traffic_known(a->lat) || !traffic_known(a->lon)) continue;
      TrafficAlert c;
      memset(&c, 0, sizeof(c));
      snprintf(c.drone_id, sizeof(c.drone_id), "%s", d->id);
      memcpy(c.hex, a->hex, sizeof(c.hex));
      memcpy(c.callsign, a->callsign, sizeof(c.callsign));
      c.drone_index = (int16_t)i;
      c.ac_index = (int16_t)j;
      c.age_s = age;
      c.on_ground = a->on_ground;
      double dx, dy;
      traffic_offset_m(d->lat, d->lon, a->lat, a->lon, &dx, &dy);
      c.horiz_m = sqrt(dx * dx + dy * dy);
      c.bearing_deg = traffic_bearing_of(dx, dy);
      c.vert_m = (traffic_alt_known(a->alt_geom_m) && traffic_alt_known(d->alt_geo_m))
               ? a->alt_geom_m - d->alt_geo_m : NAN;
      c.height_unknown = isnan(c.vert_m);
      c.cpa_s = NAN;
      c.cpa_m = NAN;
      double vcpa = c.vert_m;
      if (!a->on_ground &&
          traffic_known(a->gs_mps) && a->gs_mps >= 0.0 && traffic_known(a->track_deg) &&
          traffic_known(d->speed_mps) && d->speed_mps >= 0.0 && traffic_known(d->heading_deg)) {
        double avx = a->gs_mps * sin(a->track_deg * TRAFFIC_DEG);
        double avy = a->gs_mps * cos(a->track_deg * TRAFFIC_DEG);
        double dvx = d->speed_mps * sin(d->heading_deg * TRAFFIC_DEG);
        double dvy = d->speed_mps * cos(d->heading_deg * TRAFFIC_DEG);
        double wx = avx - dvx, wy = avy - dvy;
        double ww = wx * wx + wy * wy;
        if (ww > 1e-9) {
          double t = -(dx * wx + dy * wy) / ww;
          if (t > 0.0 && t <= TRAFFIC_CPA_MAX_S) {
            double mx = dx + wx * t, my = dy + wy * t;
            c.cpa_s = t;
            c.cpa_m = sqrt(mx * mx + my * my);
            if (!isnan(vcpa) && traffic_known(a->vs_mps)) vcpa = vcpa + a->vs_mps * t;
          }
        }
      }
      bool fresh = age < TRAFFIC_FRESH_S;
      bool eligible = can_raise && d->live && fresh;
      bool near_raw = eligible && c.horiz_m <= TRAFFIC_NEAR_H_M &&
                      (isnan(c.vert_m) || fabs(c.vert_m) <= TRAFFIC_NEAR_V_M);
      bool conv_raw = eligible && !isnan(c.cpa_s) && c.cpa_m < TRAFFIC_CPA_MISS_M &&
                      (isnan(vcpa) || fabs(vcpa) <= TRAFFIC_NEAR_V_M);
      bool hold = c.horiz_m <= TRAFFIC_HOLD_H_M &&
                  (isnan(c.vert_m) || fabs(c.vert_m) <= TRAFFIC_HOLD_V_M);
      c.kind = near_raw ? TRAFFIC_KIND_NEAR : TRAFFIC_KIND_CONVERGING;
      c.level = traffic_kind_level(c.kind, c.on_ground);
      traffic_apply(st, 0, &c, near_raw || conv_raw, hold, a->seen_ms, now_ms);
    }
  }

  // Low traffic near the observer.
  for (int j = 0; j < na && obs_pos; j++) {
    const TrafficAircraft* a = &ac[j];
    double age = traffic_age_s(a->seen_ms, now_ms);
    if (age > TRAFFIC_PRESENT_S || !traffic_known(a->lat) || !traffic_known(a->lon)) continue;
    TrafficAlert c;
    memset(&c, 0, sizeof(c));
    memcpy(c.hex, a->hex, sizeof(c.hex));
    memcpy(c.callsign, a->callsign, sizeof(c.callsign));
    c.drone_index = -1;
    c.ac_index = (int16_t)j;
    c.age_s = age;
    c.level = TRAFFIC_CAUTION;
    c.kind = TRAFFIC_KIND_LOW;
    double dx, dy;
    traffic_offset_m(obs->lat, obs->lon, a->lat, a->lon, &dx, &dy);
    c.horiz_m = sqrt(dx * dx + dy * dy);
    c.bearing_deg = traffic_bearing_of(dx, dy);
    c.cpa_s = NAN;
    c.cpa_m = NAN;
    double h = NAN;
    bool approx = !obs_elev;
    if (traffic_alt_known(a->alt_geom_m)) h = a->alt_geom_m;
    else if (traffic_alt_known(a->alt_baro_m)) { h = a->alt_baro_m; approx = true; }
    double thr = (obs_elev ? obs->elev_m : 0.0) + TRAFFIC_LOW_ABOVE_M;
    c.vert_m = (!isnan(h) && obs_elev) ? h - obs->elev_m : NAN;
    c.height_unknown = isnan(h);
    c.approx = approx && !c.height_unknown;
    c.on_ground = a->on_ground;
    bool cond = !a->on_ground && c.horiz_m <= TRAFFIC_LOW_R_M && (isnan(h) || h < thr);
    char km[16];
    traffic_km_text(c.horiz_m, km, sizeof(km));
    snprintf(c.text, sizeof(c.text), "LOW TRAFFIC %s %s KM%s",
             traffic_compass8(c.bearing_deg), km,
             c.on_ground ? ", AIRCRAFT ON GROUND"
             : c.height_unknown ? ", HEIGHT UNKNOWN" : (c.approx ? ", APPROX." : ""));
    bool raw = can_raise && age < TRAFFIC_FRESH_S && cond;
    traffic_apply(st, TRAFFIC_KIND_LOW, &c, raw, cond, a->seen_ms, now_ms);
  }

  // Emergencies.
  for (int j = 0; j < na; j++) {
    const TrafficAircraft* a = &ac[j];
    double age = traffic_age_s(a->seen_ms, now_ms);
    if (age > TRAFFIC_PRESENT_S || !traffic_known(a->lat) || !traffic_known(a->lon)) continue;
    const char* word = a->squawk == 7500 ? "HIJACK" : a->squawk == 7600 ? "RADIO FAILURE"
                     : (a->squawk == 7700 || a->emergency) ? "EMERGENCY" : NULL;
    if (!word) continue;
    TrafficAlert c;
    memset(&c, 0, sizeof(c));
    memcpy(c.hex, a->hex, sizeof(c.hex));
    memcpy(c.callsign, a->callsign, sizeof(c.callsign));
    c.drone_index = -1;
    c.ac_index = (int16_t)j;
    c.age_s = age;
    c.level = TRAFFIC_ADVISORY;
    c.kind = TRAFFIC_KIND_EMERGENCY;
    c.on_ground = a->on_ground;
    c.horiz_m = NAN;
    c.bearing_deg = NAN;
    c.vert_m = NAN;
    c.cpa_s = NAN;
    c.cpa_m = NAN;
    double dx, dy;
    if (obs_pos) {
      traffic_offset_m(obs->lat, obs->lon, a->lat, a->lon, &dx, &dy);
      c.horiz_m = sqrt(dx * dx + dy * dy);
      c.bearing_deg = traffic_bearing_of(dx, dy);
    } else {
      for (int i = 0; i < nd; i++) {
        const TrafficDrone* d = &drones[i];
        if (!traffic_known(d->lat) || !traffic_known(d->lon)) continue;
        traffic_offset_m(d->lat, d->lon, a->lat, a->lon, &dx, &dy);
        double h = sqrt(dx * dx + dy * dy);
        if (isnan(c.horiz_m) || h < c.horiz_m) { c.horiz_m = h; c.bearing_deg = traffic_bearing_of(dx, dy); }
      }
    }
    char name[16];
    traffic_ac_name(a, name, sizeof(name));
    snprintf(c.text, sizeof(c.text), "%s %s", word, name);
    bool cond = isnan(c.horiz_m) || c.horiz_m <= TRAFFIC_EMERG_R_M;
    bool raw = can_raise && age < TRAFFIC_FRESH_S && cond;
    traffic_apply(st, TRAFFIC_KIND_EMERGENCY, &c, raw, cond, a->seen_ms, now_ms);
  }

  // Entries not seen this time are out of hold; expire after 20 s out.
  for (int k = 0; k < TRAFFIC_MAX_ALERTS; k++) {
    TrafficEntry* e = &st->e[k];
    if (!e->used) continue;
    if (!e->visited) {
      e->a.held = true;
      if (!e->out) { e->out = true; e->out_since_ms = now_ms; }
    }
    if (e->out && (uint32_t)(now_ms - e->out_since_ms) >= TRAFFIC_CLEAR_MS) {
      e->used = false;
      continue;
    }
    // Output, with this evaluation's indices and ages.
    TrafficAlert* o = &out->alerts[out->n++];
    *o = e->a;
    o->age_s = traffic_age_s(e->seen_ms, now_ms);
    o->drone_index = -1;
    o->ac_index = -1;
    for (int i = 0; i < nd && o->drone_id[0]; i++)
      if (!strcmp(drones[i].id, o->drone_id)) { o->drone_index = (int16_t)i; break; }
    for (int j = 0; j < na; j++)
      if (!strcmp(ac[j].hex, o->hex) && traffic_age_s(ac[j].seen_ms, now_ms) <= TRAFFIC_PRESENT_S) {
        o->ac_index = (int16_t)j; break;
      }
  }
  // Insertion sort (stable; keys are unique anyway).
  for (int i = 1; i < out->n; i++) {
    TrafficAlert t = out->alerts[i];
    int j = i - 1;
    while (j >= 0 && traffic_alert_cmp(&out->alerts[j], &t) > 0) {
      out->alerts[j + 1] = out->alerts[j];
      j--;
    }
    out->alerts[j + 1] = t;
  }
  out->highest = out->n ? out->alerts[0].level : (uint8_t)TRAFFIC_NONE;
}

// One status line for every surface; never claims absence of traffic.
//   no ADS-B source
//   TRAFFIC DATA STALE, data 45 s old
//   no ADS-B traffic reported within 3 km, data 6 s old
//   no airborne ADS-B traffic reported within 3 km, data 6 s old  (only ground)
//   2 airborne aircraft within 3 km, data 6 s old
static inline void traffic_summary(const TrafficResult* r, char* out, size_t n) {
  if (!r->have_data) { snprintf(out, n, "no ADS-B source"); return; }
  long age = (long)floor(r->data_age_s + 0.5);
  if (r->stale) {
    if (isnan(r->data_age_s)) snprintf(out, n, "TRAFFIC DATA STALE, data age unknown");
    else snprintf(out, n, "TRAFFIC DATA STALE, data %ld s old", age);
  } else if (r->near_count == 0) {
    snprintf(out, n, "no %sADS-B traffic reported within 3 km, data %ld s old",
             r->ground_count ? "airborne " : "", age);
  } else {
    snprintf(out, n, "%u airborne aircraft within 3 km, data %ld s old", (unsigned)r->near_count, age);
  }
}

// The most urgent alert naming this aircraft, or NULL.
static inline const TrafficAlert* traffic_alert_for_hex(const TrafficResult* r, const char* hex) {
  for (int i = 0; i < r->n; i++)
    if (!strcmp(r->alerts[i].hex, hex)) return &r->alerts[i];
  return NULL;
}

// ---------------------------------------------------------------------------
// Ingestion (host lines, or a board's own fetch)

// Minimal JSON reading for the traffic lines: objects of scalars, one array.
static inline const char* traffic_ws(const char* p) {
  while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;
  return p;
}

// Skip a string starting at '"'; copies up to n-1 chars into out (may be NULL).
static inline const char* traffic_str(const char* p, char* out, size_t n) {
  size_t k = 0;
  if (*p != '"') return NULL;
  p++;
  while (*p && *p != '"') {
    char c = *p++;
    if (c == '\\' && *p) {
      c = *p++;
      if (c == 'u') { for (int i = 0; i < 4 && *p; i++) p++; c = '?'; }
      else if (c == 'n' || c == 'r' || c == 't') c = ' ';
    }
    if (out && k + 1 < n) out[k++] = c;
  }
  if (out && n) out[k] = 0;
  return *p == '"' ? p + 1 : NULL;
}

// Skip any value (nested objects/arrays included).
static inline const char* traffic_skip(const char* p) {
  p = traffic_ws(p);
  if (*p == '"') return traffic_str(p, NULL, 0);
  if (*p == '{' || *p == '[') {
    int depth = 0;
    while (*p) {
      if (*p == '"') { p = traffic_str(p, NULL, 0); if (!p) return NULL; continue; }
      if (*p == '{' || *p == '[') depth++;
      else if (*p == '}' || *p == ']') { depth--; if (depth == 0) return p + 1; }
      p++;
    }
    return NULL;
  }
  while (*p && *p != ',' && *p != '}' && *p != ']') p++;
  return p;
}

// Scalar value: number (finite), true/false, null (NaN), or string (its text).
typedef struct {
  bool   present;
  bool   is_str;
  double num;              // NaN for null / non-numbers
  char   str[24];
} TrafficJv;

static inline const char* traffic_value(const char* p, TrafficJv* v) {
  p = traffic_ws(p);
  v->present = true;
  v->is_str = false;
  v->num = NAN;
  v->str[0] = 0;
  if (*p == '"') { v->is_str = true; return traffic_str(p, v->str, sizeof(v->str)); }
  if (*p == '{' || *p == '[') return traffic_skip(p);
  if (!strncmp(p, "true", 4)) { v->num = 1; return p + 4; }
  if (!strncmp(p, "false", 5)) { v->num = 0; return p + 5; }
  if (!strncmp(p, "null", 4)) return p + 4;
  char* end = NULL;
  double d = strtod(p, &end);
  if (end == p) return traffic_skip(p);
  v->num = isfinite(d) ? d : NAN;
  return end;
}

// Walk an object's members; cb(key, value_start, ctx) returns the end of the
// value it consumed, or NULL to have it skipped. Returns the end of the object.
typedef const char* (*TrafficMemberFn)(const char* key, const char* val, void* ctx);
static inline const char* traffic_object(const char* p, TrafficMemberFn cb, void* ctx) {
  p = traffic_ws(p);
  if (*p != '{') return NULL;
  p = traffic_ws(p + 1);
  if (*p == '}') return p + 1;
  while (*p) {
    char key[16];
    p = traffic_str(traffic_ws(p), key, sizeof(key));
    if (!p) return NULL;
    p = traffic_ws(p);
    if (*p != ':') return NULL;
    p = traffic_ws(p + 1);
    const char* e = cb(key, p, ctx);
    if (!e) e = traffic_skip(p);
    if (!e) return NULL;
    p = traffic_ws(e);
    if (*p == ',') { p++; continue; }
    if (*p == '}') return p + 1;
    return NULL;
  }
  return NULL;
}

typedef struct {
  TrafficAircraft a;
  bool has_hex, has_age;
  bool has_gnd, gnd, baro_ground;   // "gnd" wins over "altb_ft":"ground"
  double age_s;
} TrafficAcParse;

static inline void traffic_copy_trim(char* out, size_t n, const char* s) {
  while (*s == ' ') s++;
  snprintf(out, n, "%s", s);
  size_t l = strlen(out);
  while (l && out[l - 1] == ' ') out[--l] = 0;
}

static inline const char* traffic_ac_member(const char* key, const char* val, void* ctx) {
  TrafficAcParse* p = (TrafficAcParse*)ctx;
  TrafficJv v;
  const char* e = traffic_value(val, &v);
  if (!e) return NULL;
  TrafficAircraft* a = &p->a;
  double n = v.is_str ? NAN : v.num;
  if (!strcmp(key, "hex") && v.is_str) {
    size_t k = 0;
    for (const char* s = v.str; *s && k < 6; s++) {
      char c = *s;
      if (c >= 'A' && c <= 'F') c = (char)(c + 32);
      if ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) a->hex[k++] = c;
      else if (c == '~') continue;           // adsb.lol marks non-ICAO addresses with ~
      else { k = 0; break; }
    }
    a->hex[k] = 0;
    p->has_hex = k > 0;
  }
  else if (!strcmp(key, "cs") && v.is_str) traffic_copy_trim(a->callsign, sizeof(a->callsign), v.str);
  else if (!strcmp(key, "ty") && v.is_str) traffic_copy_trim(a->type, sizeof(a->type), v.str);
  else if (!strcmp(key, "lat")) a->lat = (isfinite(n) && fabs(n) <= 90.0) ? n : NAN;
  else if (!strcmp(key, "lon")) a->lon = (isfinite(n) && fabs(n) <= 180.0) ? n : NAN;
  else if (!strcmp(key, "altg_m")) a->alt_geom_m = n;
  else if (!strcmp(key, "altb_ft")) {
    a->alt_baro_m = n * TRAFFIC_FT_TO_M;
    if (v.is_str && !strcmp(v.str, "ground")) p->baro_ground = true;
  }
  else if (!strcmp(key, "gnd")) {
    p->has_gnd = true;
    p->gnd = v.is_str ? (v.str[0] && strcmp(v.str, "0") && strcmp(v.str, "false")) : (isfinite(n) && n != 0);
  }
  else if (!strcmp(key, "gs_kt")) a->gs_mps = (n >= 0.0) ? n * TRAFFIC_KT_TO_MPS : NAN;
  else if (!strcmp(key, "trk")) a->track_deg = n;
  else if (!strcmp(key, "vr_fpm")) a->vs_mps = n * TRAFFIC_FT_TO_M / 60.0;
  else if (!strcmp(key, "sq")) {
    long q = 0;
    if (v.is_str) {
      const char* s = v.str;
      size_t l = strlen(s);
      bool ok = l > 0 && l <= 4;
      for (size_t i = 0; i < l && ok; i++) ok = s[i] >= '0' && s[i] <= '7';
      q = ok ? strtol(s, NULL, 10) : 0;
    } else if (isfinite(n) && n >= 0 && n <= 7777) {
      q = (long)n;
    }
    a->squawk = (uint16_t)q;
  }
  else if (!strcmp(key, "em")) a->emergency = v.is_str ? (v.str[0] && strcmp(v.str, "none") && strcmp(v.str, "0"))
                                                     : (isfinite(n) && n != 0);
  else if (!strcmp(key, "age_s")) { p->has_age = true; p->age_s = n; }
  return e;
}

// Parse one wire aircraft object at p; false when unusable (no hex, no
// position, no finite age, or older than 60 s). Sets seen_ms from age_s.
static inline bool traffic_parse_aircraft(const char* p, uint32_t now_ms, TrafficAircraft* out,
                                          const char** end) {
  TrafficAcParse st;
  memset(&st, 0, sizeof(st));
  st.a.lat = st.a.lon = NAN;
  st.a.alt_geom_m = st.a.alt_baro_m = st.a.gs_mps = st.a.track_deg = st.a.vs_mps = NAN;
  st.age_s = NAN;
  const char* e = traffic_object(p, traffic_ac_member, &st);
  if (end) *end = e;
  if (!e || !st.has_hex || isnan(st.a.lat) || isnan(st.a.lon)) return false;
  if (!(st.age_s >= 0.0) || st.age_s > TRAFFIC_PRESENT_S) return false;
  st.a.on_ground = st.has_gnd ? st.gnd : st.baro_ground;
  st.a.seen_ms = now_ms - (uint32_t)llround(st.age_s * 1000.0);
  *out = st.a;
  return true;
}

// Live set and board-level state. Loop task only.
//
// On the device the big ones (the two aircraft sets, the hysteresis state
// and the result, ~12 KB) are allocated at start-up in PSRAM when fitted
// (ext_ram.h, like g_tracks): the arrays as pointers, the structs as
// references, so every use reads the same on the device and on the host,
// where they stay plain arrays and structs. Size them with
// TRAFFIC_MAX_AIRCRAFT / sizeof(TrafficState), never sizeof(g_traffic_ac).
#if defined(__cplusplus)
#if defined(ESP_PLATFORM)
inline TrafficAircraft* g_traffic_ac     = ext_new<TrafficAircraft>(TRAFFIC_MAX_AIRCRAFT);
inline TrafficAircraft* g_traffic_stage  = ext_new<TrafficAircraft>(TRAFFIC_MAX_AIRCRAFT);
inline TrafficState&    g_traffic_state  = *ext_new<TrafficState>();
inline TrafficResult&   g_traffic_result = *ext_new<TrafficResult>();
#else
inline TrafficAircraft g_traffic_ac[TRAFFIC_MAX_AIRCRAFT];
inline TrafficAircraft g_traffic_stage[TRAFFIC_MAX_AIRCRAFT];
inline TrafficState    g_traffic_state;
inline TrafficResult   g_traffic_result;
#endif
inline uint8_t         g_traffic_count = 0;
inline bool            g_traffic_have = false;    // a set has been received
inline uint32_t        g_traffic_data_ms = 0;     // local millis() the set refers to
inline uint32_t        g_traffic_rx_ms = 0;       // local millis() it was installed
inline uint32_t        g_traffic_unix_s = 0;      // the set's "t", 0 unknown
inline bool            g_traffic_partial = false; // traffic_done's n did not match
inline uint32_t        g_traffic_seq = 0;         // bumps on every installed set
inline TrafficObserver g_traffic_observer = {NAN, NAN, NAN};  // the board sets this

// Staging for a set arriving over several host lines (g_traffic_stage above).
inline uint8_t         g_traffic_stage_n = 0;
inline uint16_t        g_traffic_stage_rx = 0;    // objects received, valid or not
inline bool            g_traffic_stage_open = false;
inline uint32_t        g_traffic_stage_t = 0;
inline double          g_traffic_stage_age = 0;   // feed age from the traffic lines

// Install a complete set (see the header comment for the filtering).
static inline void traffic_ingest(const TrafficAircraft* ac, int n, uint32_t data_ms,
                                  uint32_t now_ms) {
  const TrafficObserver* o = &g_traffic_observer;
  bool pos = traffic_known(o->lat) && traffic_known(o->lon);
  int taken = 0;
  double last_d = -1.0;
  int last_i = -1;
  // Selection by distance (ties by index): O(32 n), no scratch array.
  while (taken < TRAFFIC_MAX_AIRCRAFT) {
    int best = -1;
    double best_d = 0;
    for (int i = 0; i < n; i++) {
      const TrafficAircraft* a = &ac[i];
      if (traffic_age_s(a->seen_ms, now_ms) > TRAFFIC_PRESENT_S ||
          !traffic_known(a->lat) || !traffic_known(a->lon)) continue;
      double d = pos ? traffic_distance_m(o->lat, o->lon, a->lat, a->lon) : 0.0;
      if (pos && d > TRAFFIC_KEEP_R_M) continue;
      if (d < last_d || (d == last_d && i <= last_i)) continue;
      if (best < 0 || d < best_d) { best = i; best_d = d; }
    }
    if (best < 0) break;
    g_traffic_ac[taken++] = ac[best];
    last_d = best_d;
    last_i = best;
  }
  g_traffic_count = (uint8_t)taken;
  g_traffic_have = true;
  g_traffic_data_ms = data_ms;
  g_traffic_rx_ms = now_ms;
  g_traffic_seq++;
}

typedef struct {
  char   cmd[16];
  double t, age_s, n;
  bool   has_age, has_n;
  const char* ac;          // start of the "ac" array
} TrafficLineParse;

static inline const char* traffic_line_member(const char* key, const char* val, void* ctx) {
  TrafficLineParse* p = (TrafficLineParse*)ctx;
  if (!strcmp(key, "ac")) { p->ac = val; return NULL; }
  TrafficJv v;
  const char* e = traffic_value(val, &v);
  if (!e) return NULL;
  if (!strcmp(key, "cmd") && v.is_str) snprintf(p->cmd, sizeof(p->cmd), "%s", v.str);
  else if (!strcmp(key, "t")) p->t = v.num;
  else if (!strcmp(key, "age_s")) { p->has_age = true; p->age_s = v.is_str ? NAN : v.num; }
  else if (!strcmp(key, "n")) { p->has_n = true; p->n = v.num; }
  return e;
}

// data_ms for a feed age in seconds; NaN/negative -> just past stale.
static inline uint32_t traffic_data_ms_for(double age_s, uint32_t now_ms) {
  if (!(age_s >= 0.0)) age_s = TRAFFIC_STALE_S + 1.0;
  if (age_s > 86400.0) age_s = 86400.0;
  return now_ms - (uint32_t)llround(age_s * 1000.0);
}

// Handle {"cmd":"traffic",...} and {"cmd":"traffic_done",...}; true when the
// line was one of them. See the header comment for the protocol.
static inline bool traffic_host_line(const char* line, uint32_t now_ms) {
  if (!line || !strstr(line, "\"traffic")) return false;   // cheap reject
  TrafficLineParse lp;
  memset(&lp, 0, sizeof(lp));
  lp.t = NAN;
  if (!traffic_object(line, traffic_line_member, &lp)) {
    // Malformed: still ours if it plainly names the command.
    return strstr(line, "\"cmd\":\"traffic\"") || strstr(line, "\"cmd\":\"traffic_done\"");
  }
  if (!strcmp(lp.cmd, "traffic")) {
    uint32_t t = (isfinite(lp.t) && lp.t > 0 && lp.t < 4294967295.0) ? (uint32_t)lp.t : 0;
    if (!g_traffic_stage_open || t != g_traffic_stage_t) {
      g_traffic_stage_open = true;
      g_traffic_stage_t = t;
      g_traffic_stage_n = 0;
      g_traffic_stage_rx = 0;
      g_traffic_stage_age = 0;
    }
    if (lp.has_age) g_traffic_stage_age = lp.age_s;
    const char* p = lp.ac ? traffic_ws(lp.ac) : NULL;
    if (p && *p == '[') {
      p = traffic_ws(p + 1);
      while (*p == '{') {
        TrafficAircraft a;
        const char* e = NULL;
        bool ok = traffic_parse_aircraft(p, now_ms, &a, &e);
        if (!e) break;
        if (g_traffic_stage_rx < 0xFFFF) g_traffic_stage_rx++;
        if (ok && g_traffic_stage_n < TRAFFIC_MAX_AIRCRAFT) g_traffic_stage[g_traffic_stage_n++] = a;
        p = traffic_ws(e);
        if (*p == ',') p = traffic_ws(p + 1);
      }
    }
    return true;
  }
  if (!strcmp(lp.cmd, "traffic_done")) {
    double age = lp.has_age ? lp.age_s : (g_traffic_stage_open ? g_traffic_stage_age : 0.0);
    int n = g_traffic_stage_open ? g_traffic_stage_n : 0;
    uint16_t rx = g_traffic_stage_open ? g_traffic_stage_rx : 0;
    g_traffic_partial = lp.has_n && isfinite(lp.n) && (long)lp.n != (long)rx;
    if (g_traffic_stage_open) g_traffic_unix_s = g_traffic_stage_t;
    traffic_ingest(g_traffic_stage, n, traffic_data_ms_for(age, now_ms), now_ms);
    g_traffic_stage_open = false;
    g_traffic_stage_n = 0;
    return true;
  }
  return false;
}

// Evaluate the live set for this board's drones (loop task). A set not
// refreshed for 10 min counts as no source.
static inline void traffic_tick(const TrafficDrone* drones, int nd, uint32_t now_ms) {
  bool have = g_traffic_have &&
              traffic_age_s(g_traffic_rx_ms, now_ms) <= TRAFFIC_SOURCE_LOST_S;
  traffic_evaluate(drones, nd, g_traffic_ac, g_traffic_count, &g_traffic_observer,
                   have, g_traffic_data_ms, now_ms, &g_traffic_state, &g_traffic_result);
}
#endif  // __cplusplus
