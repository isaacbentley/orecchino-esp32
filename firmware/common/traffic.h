// traffic.h — ADS-B conflict watch: manned aircraft near the drones we hear.
//
// The UI is Remote ID first; ADS-B is used only for conflict detection and
// resolution between the drones a receiver hears and manned aircraft. The
// reference implementation of docs/plans/mobile-app-and-t5-wifi.md §8 as
// narrowed by that decision. Ported line for line to app/Sources/Orecchino/
// TrafficRules.swift and mobile/lib/core/traffic/traffic_rules.dart; all
// three are tested against every file in tests/vectors/traffic/*.json.
// Change one, change all three and the vectors. Pure C/C++ (libc + libm
// only): no Arduino, host-testable.
//
// ---------------------------------------------------------------------------
// THE RULES. Drone x aircraft pairs (a live drone and a fresh aircraft), and
// LOW: an airborne aircraft in UAS airspace (one alert per aircraft).
//
//   level     kind        condition                                  words
//   WARNING   NEAR        horizontal <= 1000 m and |vertical| <=     TRAFFIC NEAR DRONE <id>
//                         150 m, or vertical unknown and
//                         horizontal <= 1000 m
//   WARNING   CONVERGING  both velocities known, closest point of    TRAFFIC CONVERGING WITH <id>, <n> S
//                         approach in (0, 60] s, miss distance
//                         < 500 m and |vertical at CPA| <= 150 m
//                         (or vertical unknown)
//   CAUTION   NEAR        as NEAR, the aircraft reported on the      TRAFFIC NEAR DRONE <id>,
//                         ground (see below)                         AIRCRAFT ON GROUND
//   CAUTION   LOW         fresh airborne aircraft within 3 km        LOW TRAFFIC <brg> <dist>
//                         (horizontally) of the observer or of any
//                         live drone, below 460 m (1,500 ft) above
//                         ground, or with that height unknown
//
// LOW (UAS airspace intrusion), the choices:
// - Ground: the observer's elevation (geometric) when known; else, among the
//   live drones reporting both alt_geo_m and height_m (height above take-off
//   or ground), the lowest alt_geo_m minus its height_m; else unknown.
// - Aircraft height: alt_geom_m, else alt_baro_m (then `approx`, words
//   ", APPROX." / "ABOUT"), else unknown. vert_m = aircraft height - ground
//   (height above ground, NaN unknown). Unknown -> raised with
//   ", HEIGHT UNKNOWN" (never silent), except: with the ground unknown and
//   the aircraft's own height known, only when that height is below
//   TRAFFIC_LOW_UNKNOWN_GROUND_MAX_M (3,500 m MSL). UAS airspace is at most
//   460 m above ground, and ground rarely lies above ~3,000 m where drones
//   fly, so an aircraft at or above 3,500 m MSL cannot be in it; without
//   this bound every airliner overhead would read "LOW TRAFFIC, HEIGHT
//   UNKNOWN" whenever the ground is unknown. With the aircraft's height
//   itself unknown it is always raised.
// - One alert per aircraft (keyed by hex, drone_id is the anchor's). Anchor:
//   the observer when the aircraft is within 3 km of it (from_observer,
//   drone_id ""), else the nearest live drone within 3 km (drone_id). horiz_m
//   and bearing_deg are from the anchor; cpa_s is NaN; vert_rel is ABOVE
//   when vert_m is known, else UNKNOWN.
// - Aircraft on the ground never raise LOW (an existing LOW clears 20 s
//   after landing, reading ", AIRCRAFT ON GROUND" meanwhile).
// - A warning (NEAR/CONVERGING, airborne) for the same aircraft supersedes
//   its LOW: the LOW is kept by the hysteresis but not shown.
// - Hysteresis: kept while the condition holds (freshness and staleness
//   aside), removed 20 s after it stops holding.
// - Words: text "LOW TRAFFIC <brg> <dist>" (<dist> as in the resolution
//   geometry below) + ", AIRCRAFT ON GROUND" / ", HEIGHT UNKNOWN" /
//   ", APPROX."; action "BE READY TO LAND DRONES"; resolution the action,
//   "; ", then "AIRCRAFT <v> M ABOVE GROUND" (ABOUT <v> when approx; "NEAR
//   GROUND LEVEL", approx or not, when <v> <= 0) / "AIRCRAFT HEIGHT UNKNOWN" / "AIRCRAFT ON
//   GROUND", then ", <dist> <brg>". e.g. "BE READY TO LAND DRONES; AIRCRAFT
//   240 M ABOVE GROUND, 2.4 KM W".
// There is no emergency-squawk rule. The observer (traffic_evaluate's
// overload with a TrafficObserver, traffic_tick's g_traffic_observer) only
// feeds LOW and what traffic_ingest keeps.
//
// RESOLUTION. Every alert carries a resolution advisory for the drone,
// grounded in 14 CFR 107.37(a): a small unmanned aircraft must yield the
// right of way to all aircraft and may not pass over, under or ahead of one
// unless well clear. `action` is the short instruction, `resolution` the
// action plus the geometry that justifies it ("; " between them):
//
//   aircraft          vert_rel   action
//   LOW (any)         -          BE READY TO LAND DRONES (see LOW above)
//   on the ground     any        KEEP CLEAR OF AIRCRAFT ON GROUND
//   more than 30 m    BELOW      GIVE WAY: MOVE <away>, THEN LAND <id>
//   below the drone              (descending would close on it; <away> is
//                                the 8-point direction opposite the aircraft)
//   above, level      ABOVE,     GIVE WAY: DESCEND AND LAND <id>
//   (within 30 m) or  LEVEL,
//   height unknown    UNKNOWN
//
//   geometry: "AIRCRAFT <v> M ABOVE" / "AIRCRAFT <v> M BELOW" / "AIRCRAFT
//   LEVEL WITHIN 30 M" / "AIRCRAFT HEIGHT UNKNOWN" / "AIRCRAFT ON GROUND",
//   then ", <h> <brg>" from the drone to the aircraft (<h> = "<n> M" to the
//   nearest 10 m under 1 km, else "<d.d> KM"), then ", CLOSEST IN <n> S"
//   whenever a closest approach in (0, 60] s is known. e.g. "GIVE WAY:
//   DESCEND AND LAND D9A03; AIRCRAFT 90 M ABOVE, 800 M NE, CLOSEST IN 24 S". vert_rel uses the current vertical (not at CPA);
//   <v> = floor(|vertical| + 0.5). The words advise; they never claim the
//   drone is out of danger.
//
// Aircraft on the ground (readsb/adsb.lol "alt_baro":"ground"; wire "gnd":1)
// are common near airfields (taxiing, parked) and are not airborne traffic:
//   - CONVERGING is not computed for them (no closest-approach projection);
//   - NEAR a live drone is still raised, as a CAUTION (not a warning) with
//     the words ", AIRCRAFT ON GROUND": a drone within 1 km of an aircraft on
//     an apron or taxiway is worth showing, but it must not flash, notify like
//     a warning, or push airborne warnings out of the alert list.
//
// CONFLICT WATCH STATUS (traffic_summary), the only status line; it never
// counts aircraft:
//   CONFLICT WATCH OFF: no ADS-B source
//   TRAFFIC DATA STALE, data 45 s old
//   conflict watch on, no ADS-B conflicts, data 6 s old
//   conflict watch on, 2 ADS-B conflicts, data 6 s old   (pair alerts shown, held included)
//   conflict watch on, 1 low aircraft, 1 ADS-B conflict, data 6 s old
//   (LOW alerts shown count as "low aircraft"; nothing else is counted)
//
// Definitions and the choices made where §8 leaves room:
// - Fresh aircraft: position age < 30 s. Present: age <= 60 s (older ones are
//   ignored entirely, as if dropped). A drone is "live" when the caller says
//   so (heard within 60 s with a position, §8.2); a drone without a finite
//   position never pairs.
// - Stale data: the ADS-B set is older than 30 s (data_age_s > 30), or its
//   age is unknown. Then NO new alert is raised; existing alerts are kept by
//   the hysteresis below with their last numbers and `held` set, and the
//   status says `TRAFFIC DATA STALE`; alerts show `ADS-B <n> s old`
//   (traffic_age_words). No source at all (have_data false): nothing is
//   raised and the status says `CONFLICT WATCH OFF`.
// - Vertical: aircraft alt_geom_m minus drone alt_geo_m, both above the
//   WGS-84 ellipsoid. Never barometric, never the drone's height above
//   take-off. Either missing -> vertical unknown: the alert is RAISED with
//   the words `HEIGHT UNKNOWN`, never dropped. Callers pass NaN for unknown;
//   the ODID/firmware marker -1000 (anything <= -999) is also read as unknown.
// - Converging: flat-earth relative position r (aircraft minus drone,
//   east/north metres) and relative velocity w = v_aircraft - v_drone
//   (ground speed/track, speed/heading). t = -(r.w)/|w|^2 when |w|^2 > 1e-9;
//   miss = |r + w t|. Vertical at CPA = vertical + aircraft vs_mps * t (vs
//   unknown -> 0; the drone's vertical rate is not used). If NEAR and
//   CONVERGING both hold, the pair shows NEAR (cpa_s is still filled in).
// - Hysteresis (wall clock, never evaluation counts): an alert, once raised,
//   is kept while its raise condition holds OR while it is "in hold"; it is
//   removed when it has been out of hold continuously for >= 20 s. In hold =
//   both present, horizontal <= 1300 m and (vertical unknown or |vertical|
//   <= 200 m) — "beyond 1.3 km or 200 m" releases. NEAR stays NEAR while in
//   hold even if only CONVERGING is raised; outside hold a raised CONVERGING
//   replaces NEAR. A pair missing from this evaluation is out of hold and
//   keeps its last numbers and words; a held pair still present gets its
//   words and resolution rebuilt from the current numbers (a held
//   CONVERGING with no CPA now reads "TRAFFIC CONVERGING WITH <id>" without
//   seconds).
// - Ordering: level desc, kind (NEAR, CONVERGING, LOW), horiz_m asc, drone
//   id, hex (byte order). At most TRAFFIC_MAX_ALERTS; when full, a new alert
//   replaces the last in that order only if it ranks before it. Candidates
//   are visited drones x aircraft (pairs), then aircraft (LOW), in array
//   order.
// - Text: drone <id> is a readable tail of the drone's id (the same tail the
//   T5 marks show): a "uas:"/"mac:" prefix is dropped; a MAC (12 hex digits,
//   or six hex pairs joined by ':' or '-') reads "MAC " + its last three
//   bytes ("3C71BF4CC5A2" -> "MAC 4C:C5:A2"); else the id when <= 8
//   characters, else its last 5 grown past any leading non-alphanumeric
//   ("1581F20000D9A03" -> "D9A03", "DRONE-B-9A01" -> "B-9A01", never
//   "-9A01"). <n> S = floor(cpa_s + 0.5). Distances in km with one decimal
//   = floor(m / 100 + 0.5) tenths. Bearing words are the 8-point compass,
//   floor((deg + 22.5) / 45) mod 8. Suffixes: ", AIRCRAFT ON GROUND" (wins
//   over the next) or ", HEIGHT UNKNOWN".
// - Words: never "collision", "safe", "clear" (other than the instruction
//   "KEEP CLEAR OF"), "conflict resolved" or "TCAS". "conflict watch" and
//   "ADS-B conflicts" are the user's terms. Absence is only ever "no ADS-B
//   conflicts" with the data age: not every aircraft broadcasts ADS-B.
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
//        evaluates g_traffic_ac against the drones into g_traffic_result,
//        carrying g_traffic_state.
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
#define TRAFFIC_ACTION_LEN     48
#define TRAFFIC_RES_LEN       128

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
#define TRAFFIC_LEVEL_BAND_M   30.0   // |vertical| <= 30 m: aircraft level with the drone
#define TRAFFIC_LOW_R_M      3000.0   // LOW: within 3 km of the observer or a live drone
#define TRAFFIC_LOW_AGL_M     460.0   // LOW: below 460 m (1,500 ft) above ground
#define TRAFFIC_LOW_UNKNOWN_GROUND_MAX_M 3500.0  // LOW, ground unknown: aircraft below 3,500 m MSL
#define TRAFFIC_KEEP_R_M    30000.0   // ingest: within 30 km of the observer
#define TRAFFIC_SOURCE_LOST_S 600.0   // traffic_tick: no set for 10 min = no source

#define TRAFFIC_EARTH_R_M  6371000.0
#define TRAFFIC_DEG        (M_PI / 180.0)
#define TRAFFIC_FT_TO_M    0.3048
#define TRAFFIC_KT_TO_MPS  (1852.0 / 3600.0)

// (1 was the removed ADVISORY level; the others keep their values.)
typedef enum {
  TRAFFIC_NONE     = 0,
  TRAFFIC_CAUTION  = 2,
  TRAFFIC_WARNING  = 3
} TrafficLevel;

typedef enum {
  TRAFFIC_KIND_NEAR       = 0,
  TRAFFIC_KIND_CONVERGING = 1,
  TRAFFIC_KIND_LOW        = 2    // an airborne aircraft in UAS airspace (one per aircraft)
} TrafficKind;

// Where the aircraft is relative to the drone (current vertical).
typedef enum {
  TRAFFIC_VERT_UNKNOWN = 0,   // either height unknown
  TRAFFIC_VERT_ABOVE   = 1,   // more than 30 m above the drone
  TRAFFIC_VERT_LEVEL   = 2,   // within 30 m
  TRAFFIC_VERT_BELOW   = 3    // more than 30 m below the drone
} TrafficVert;

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
  double height_m;            // height above take-off/ground (LOW's ground), NaN unknown;
                              // zero-initialised drones read 0: set NaN when unknown
} TrafficDrone;

typedef struct {
  double lat, lon;            // NaN unknown
  double elev_m;              // NaN unknown
} TrafficObserver;

typedef struct {
  uint8_t level;              // TrafficLevel
  uint8_t kind;               // TrafficKind
  uint8_t vert_rel;           // TrafficVert: the aircraft above / level / below the drone
  bool    held;               // kept by hysteresis; the raise condition is false now
  bool    height_unknown;
  bool    on_ground;          // the aircraft is reported on the ground
  int16_t drone_index;        // index into this evaluation's drones[], -1 gone
  int16_t ac_index;           // index into this evaluation's aircraft[], -1 gone
  char    drone_id[TRAFFIC_ID_LEN];
  char    hex[7];
  char    callsign[9];
  double  horiz_m;            // drone to aircraft
  double  vert_m;             // aircraft minus drone; NaN unknown
  double  bearing_deg;        // from the drone to the aircraft
  double  cpa_s;              // closest approach in (0, 60] s, else NaN
  double  cpa_m;              // miss distance at cpa_s, else NaN
  double  age_s;              // aircraft position age
  char    text[TRAFFIC_TEXT_LEN];          // "TRAFFIC NEAR DRONE D9A03"
  char    action[TRAFFIC_ACTION_LEN];      // "GIVE WAY: DESCEND AND LAND D9A03"
  char    resolution[TRAFFIC_RES_LEN];     // action + "; " + the geometry
  bool    approx;             // LOW: barometric aircraft height used
  bool    from_observer;      // LOW: horiz_m/bearing_deg are from the observer (drone_id "")
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
  uint8_t aircraft_count;     // aircraft present (<= 60 s); never shown as a count of threats
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
    default:               return "none";
  }
}

static inline const char* traffic_vert_name(uint8_t v) {
  switch (v) {
    case TRAFFIC_VERT_ABOVE: return "above";
    case TRAFFIC_VERT_LEVEL: return "level";
    case TRAFFIC_VERT_BELOW: return "below";
    default:                 return "unknown";
  }
}

static inline const char* traffic_kind_name(uint8_t k) {
  switch (k) {
    case TRAFFIC_KIND_NEAR:       return "near";
    case TRAFFIC_KIND_CONVERGING: return "converging";
    default:                      return "low";
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

// A pair is keyed by drone and aircraft; LOW by the aircraft alone.
static inline TrafficEntry* traffic_find(TrafficState* s, bool low, const char* drone_id,
                                         const char* hex) {
  for (int i = 0; i < TRAFFIC_MAX_ALERTS; i++) {
    TrafficEntry* e = &s->e[i];
    if (!e->used || strcmp(e->a.hex, hex)) continue;
    if (low ? e->a.kind == TRAFFIC_KIND_LOW
            : (e->a.kind != TRAFFIC_KIND_LOW && !strcmp(e->a.drone_id, drone_id))) return e;
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

// The aircraft above / level / below the drone, from the current vertical.
static inline uint8_t traffic_vert_rel(double vert_m) {
  if (isnan(vert_m)) return TRAFFIC_VERT_UNKNOWN;
  if (vert_m > TRAFFIC_LEVEL_BAND_M) return TRAFFIC_VERT_ABOVE;
  if (vert_m < -TRAFFIC_LEVEL_BAND_M) return TRAFFIC_VERT_BELOW;
  return TRAFFIC_VERT_LEVEL;
}

// The words, the action and the resolution for a pair, from its numbers
// (see RESOLUTION in the header comment).
static inline void traffic_pair_words(TrafficAlert* a, uint8_t kind) {
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

  a->vert_rel = traffic_vert_rel(a->vert_m);
  if (a->on_ground)
    traffic_textf(a->action, sizeof(a->action), "KEEP CLEAR OF AIRCRAFT ON GROUND");
  else if (a->vert_rel == TRAFFIC_VERT_BELOW)
    traffic_textf(a->action, sizeof(a->action), "GIVE WAY: MOVE %s, THEN LAND %s",
                  traffic_compass8(fmod(a->bearing_deg + 180.0, 360.0)), id);
  else
    traffic_textf(a->action, sizeof(a->action), "GIVE WAY: DESCEND AND LAND %s", id);

  char vert[40], km[16], hz[24], cpa[24] = "";
  long v = isnan(a->vert_m) ? 0 : (long)floor(fabs(a->vert_m) + 0.5);
  if (a->on_ground) snprintf(vert, sizeof(vert), "AIRCRAFT ON GROUND");
  else if (a->vert_rel == TRAFFIC_VERT_ABOVE) snprintf(vert, sizeof(vert), "AIRCRAFT %ld M ABOVE", v);
  else if (a->vert_rel == TRAFFIC_VERT_BELOW) snprintf(vert, sizeof(vert), "AIRCRAFT %ld M BELOW", v);
  else if (a->vert_rel == TRAFFIC_VERT_LEVEL) snprintf(vert, sizeof(vert), "AIRCRAFT LEVEL WITHIN 30 M");
  else snprintf(vert, sizeof(vert), "AIRCRAFT HEIGHT UNKNOWN");
  if (a->horiz_m < 1000.0) {
    snprintf(hz, sizeof(hz), "%ld M", (long)floor(a->horiz_m / 10.0 + 0.5) * 10);
  } else {
    traffic_km_text(a->horiz_m, km, sizeof(km));
    snprintf(hz, sizeof(hz), "%s KM", km);
  }
  if (!isnan(a->cpa_s)) snprintf(cpa, sizeof(cpa), ", CLOSEST IN %ld S", (long)floor(a->cpa_s + 0.5));
  traffic_textf(a->resolution, sizeof(a->resolution), "%s; %s, %s %s%s", a->action, vert, hz,
                traffic_compass8(a->bearing_deg), cpa);
}

// A pair with an aircraft on the ground is a caution, not a warning; LOW is
// a caution.
static inline uint8_t traffic_kind_level(uint8_t kind, bool on_ground) {
  if (kind == TRAFFIC_KIND_LOW) return TRAFFIC_CAUTION;
  return on_ground ? TRAFFIC_CAUTION : TRAFFIC_WARNING;
}

// "800 M" to the nearest 10 m under 1 km, else "2.4 KM".
static inline void traffic_dist_text(double m, char* out, size_t n) {
  if (m < 1000.0) {
    snprintf(out, n, "%ld M", (long)floor(m / 10.0 + 0.5) * 10);
  } else {
    char km[16];
    traffic_km_text(m, km, sizeof(km));
    snprintf(out, n, "%s KM", km);
  }
}

// LOW's words from its numbers (see LOW in the header comment).
static inline void traffic_low_words(TrafficAlert* a) {
  char dist[24], vert[48];
  traffic_dist_text(a->horiz_m, dist, sizeof(dist));
  const char* brg = traffic_compass8(a->bearing_deg);
  traffic_textf(a->text, sizeof(a->text), "LOW TRAFFIC %s %s%s", brg, dist,
                a->on_ground ? ", AIRCRAFT ON GROUND"
                : a->height_unknown ? ", HEIGHT UNKNOWN" : (a->approx ? ", APPROX." : ""));
  a->vert_rel = isnan(a->vert_m) ? TRAFFIC_VERT_UNKNOWN : TRAFFIC_VERT_ABOVE;
  traffic_textf(a->action, sizeof(a->action), "BE READY TO LAND DRONES");
  long v = isnan(a->vert_m) ? 0 : (long)floor(a->vert_m + 0.5);
  if (a->on_ground) snprintf(vert, sizeof(vert), "AIRCRAFT ON GROUND");
  else if (a->height_unknown) snprintf(vert, sizeof(vert), "AIRCRAFT HEIGHT UNKNOWN");
  else if (v <= 0) snprintf(vert, sizeof(vert), "AIRCRAFT NEAR GROUND LEVEL");   // "near" is the approximation
  else snprintf(vert, sizeof(vert), "AIRCRAFT %s%ld M ABOVE GROUND", a->approx ? "ABOUT " : "", v);
  traffic_textf(a->resolution, sizeof(a->resolution), "%s; %s, %s %s", a->action, vert, dist, brg);
}

// Raise or refresh the entry for the pair in `cand`. raw: the raise
// condition holds now (cand->kind is what it raises); hold: in hold. NEAR is
// kept while in hold even when only CONVERGING is raised. The words and the
// resolution are rebuilt from the current numbers for the kind kept.
static inline void traffic_apply(TrafficState* s, const TrafficAlert* cand,
                                 bool raw, bool hold, uint32_t seen_ms, uint32_t now_ms) {
  const bool low = cand->kind == TRAFFIC_KIND_LOW;
  TrafficEntry* e = traffic_find(s, low, cand->drone_id, cand->hex);
  uint8_t kind = cand->kind;
  if (e) {
    if (low) kind = TRAFFIC_KIND_LOW;
    else if (!raw) kind = e->a.kind;
    else if (e->a.kind == TRAFFIC_KIND_NEAR && hold) kind = TRAFFIC_KIND_NEAR;
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
  if (low) traffic_low_words(&e->a);
  else traffic_pair_words(&e->a, kind);
  if (raw || hold) {
    e->out = false;
  } else if (!e->out) {
    e->out = true;
    e->out_since_ms = now_ms;
  }
}

// The rule function. drones/aircraft may be NULL when their count is 0.
// have_data false: no ADS-B source; data_ms is then ignored. obs (may be
// NULL) only feeds LOW.
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

  for (int k = 0; k < TRAFFIC_MAX_ALERTS; k++) st->e[k].visited = false;

  for (int j = 0; j < na; j++) {
    const TrafficAircraft* a = &ac[j];
    if (traffic_age_s(a->seen_ms, now_ms) <= TRAFFIC_PRESENT_S &&
        traffic_known(a->lat) && traffic_known(a->lon)) out->aircraft_count++;
  }

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
      traffic_apply(st, &c, near_raw || conv_raw, hold, a->seen_ms, now_ms);
    }
  }

  // LOW: airborne aircraft in UAS airspace.
  const bool obs_pos = obs && traffic_known(obs->lat) && traffic_known(obs->lon);
  double ground = NAN;
  if (obs && traffic_alt_known(obs->elev_m)) {
    ground = obs->elev_m;
  } else {
    double lowest = NAN;
    for (int i = 0; i < nd; i++) {
      const TrafficDrone* d = &drones[i];
      if (!d->live || !traffic_known(d->lat) || !traffic_known(d->lon)) continue;
      if (!traffic_alt_known(d->alt_geo_m) || !traffic_known(d->height_m)) continue;
      if (isnan(lowest) || d->alt_geo_m < lowest) { lowest = d->alt_geo_m; ground = d->alt_geo_m - d->height_m; }
    }
  }
  for (int j = 0; j < na; j++) {
    const TrafficAircraft* a = &ac[j];
    double age = traffic_age_s(a->seen_ms, now_ms);
    if (age > TRAFFIC_PRESENT_S || !traffic_known(a->lat) || !traffic_known(a->lon)) continue;
    // Anchor: the observer within 3 km, else the nearest live drone within
    // 3 km, else (only to keep a held alert's numbers) the observer or the
    // nearest live drone at any distance.
    double dx = NAN, dy = NAN, dist = NAN;
    int anchor = -1;
    bool from_obs = false, within = false;
    if (obs_pos) {
      traffic_offset_m(obs->lat, obs->lon, a->lat, a->lon, &dx, &dy);
      dist = sqrt(dx * dx + dy * dy);
      from_obs = true;
      within = dist <= TRAFFIC_LOW_R_M;
    }
    if (!within) {
      double bd = NAN, bx = 0, by = 0;
      int bi = -1;
      for (int i = 0; i < nd; i++) {
        const TrafficDrone* d = &drones[i];
        if (!d->live || !traffic_known(d->lat) || !traffic_known(d->lon)) continue;
        double ex, ey;
        traffic_offset_m(d->lat, d->lon, a->lat, a->lon, &ex, &ey);
        double h = sqrt(ex * ex + ey * ey);
        if (bi < 0 || h < bd) { bi = i; bd = h; bx = ex; by = ey; }
      }
      if (bi >= 0 && (bd <= TRAFFIC_LOW_R_M || !from_obs)) {
        anchor = bi; dist = bd; dx = bx; dy = by; from_obs = false;
        within = bd <= TRAFFIC_LOW_R_M;
      }
    }
    if (!from_obs && anchor < 0) continue;       // nothing to measure from
    TrafficAlert c;
    memset(&c, 0, sizeof(c));
    if (anchor >= 0) snprintf(c.drone_id, sizeof(c.drone_id), "%s", drones[anchor].id);
    memcpy(c.hex, a->hex, sizeof(c.hex));
    memcpy(c.callsign, a->callsign, sizeof(c.callsign));
    c.drone_index = (int16_t)anchor;
    c.ac_index = (int16_t)j;
    c.age_s = age;
    c.kind = TRAFFIC_KIND_LOW;
    c.level = TRAFFIC_CAUTION;
    c.on_ground = a->on_ground;
    c.from_observer = from_obs;
    c.horiz_m = dist;
    c.bearing_deg = traffic_bearing_of(dx, dy);
    c.cpa_s = NAN;
    c.cpa_m = NAN;
    double h = NAN;
    if (traffic_alt_known(a->alt_geom_m)) h = a->alt_geom_m;
    else if (traffic_alt_known(a->alt_baro_m)) { h = a->alt_baro_m; c.approx = true; }
    c.vert_m = (!isnan(h) && !isnan(ground)) ? h - ground : NAN;
    c.height_unknown = isnan(c.vert_m);
    if (c.height_unknown) c.approx = false;
    bool low = !isnan(c.vert_m) ? c.vert_m < TRAFFIC_LOW_AGL_M
             : (isnan(h) || !isnan(ground) || h < TRAFFIC_LOW_UNKNOWN_GROUND_MAX_M);
    bool cond = !a->on_ground && within && low;
    bool raw = can_raise && age < TRAFFIC_FRESH_S && cond;
    traffic_apply(st, &c, raw, cond, a->seen_ms, now_ms);
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
  // A warning for an aircraft supersedes its LOW (kept, not shown).
  int kept = 0;
  for (int i = 0; i < out->n; i++) {
    bool hide = false;
    if (out->alerts[i].kind == TRAFFIC_KIND_LOW)
      for (int j = 0; j < out->n && !hide; j++)
        hide = out->alerts[j].kind != TRAFFIC_KIND_LOW && out->alerts[j].level == TRAFFIC_WARNING &&
               !strcmp(out->alerts[j].hex, out->alerts[i].hex);
    if (!hide) {
      if (kept != i) out->alerts[kept] = out->alerts[i];
      kept++;
    }
  }
  out->n = (uint8_t)kept;
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

// Pairs only, no observer (LOW then anchors on live drones alone).
static inline void traffic_evaluate(const TrafficDrone* drones, int nd,
                                    const TrafficAircraft* ac, int na,
                                    bool have_data, uint32_t data_ms, uint32_t now_ms,
                                    TrafficState* st, TrafficResult* out) {
  traffic_evaluate(drones, nd, ac, na, (const TrafficObserver*)NULL, have_data, data_ms, now_ms, st, out);
}

// The conflict watch status, the one status line for every surface; it
// never counts aircraft and never claims the airspace is empty.
//   CONFLICT WATCH OFF: no ADS-B source
//   TRAFFIC DATA STALE, data 45 s old
//   conflict watch on, no ADS-B conflicts, data 6 s old
//   conflict watch on, 2 ADS-B conflicts, data 6 s old
static inline void traffic_summary(const TrafficResult* r, char* out, size_t n) {
  if (!r->have_data) { snprintf(out, n, "CONFLICT WATCH OFF: no ADS-B source"); return; }
  long age = (long)floor(r->data_age_s + 0.5);
  if (r->stale) {
    if (isnan(r->data_age_s)) snprintf(out, n, "TRAFFIC DATA STALE, data age unknown");
    else snprintf(out, n, "TRAFFIC DATA STALE, data %ld s old", age);
  } else if (r->n == 0) {
    snprintf(out, n, "conflict watch on, no ADS-B conflicts, data %ld s old", age);
  } else {
    unsigned low = 0, conf = 0;
    for (int i = 0; i < r->n; i++) { if (r->alerts[i].kind == TRAFFIC_KIND_LOW) low++; else conf++; }
    char a[40] = "", b[40] = "";
    if (low) snprintf(a, sizeof(a), "%u low aircraft, ", low);
    if (conf) snprintf(b, sizeof(b), "%u ADS-B conflict%s, ", conf, conf == 1 ? "" : "s");
    snprintf(out, n, "conflict watch on, %s%sdata %ld s old", a, b, age);
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
