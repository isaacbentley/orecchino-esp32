// net_parse.h — the T5's Wi-Fi fetches, minus the radio: streaming JSON
// splitting, the adsb.lol and FAA TFR answers, SNTP packets, tile lists and
// small JSON helpers for the wifi_* host commands.
//
// Pure C++ (libc + libm + traffic.h), so tests/net_test.cpp runs every
// function here on the host against saved answers (tests/vectors/net/).
// The HTTP side that feeds it lives in net_fetch.h (device only).
//
// Sources (the same ones the Mac app uses):
//   TFRs   FAA GeoServer WFS, TFRService.swift's URL plus a bbox around home.
//          Verified 2026-09-23: the bbox must be lon0,lat0,lon1,lat1,EPSG:4326
//          (the plan's lat-first order returns an ORA-13200 error page).
//   ADS-B  https://api.adsb.lol/v2/point/<lat>/<lon>/<radius NM>. Verified
//          2026-09-23: the radius is in nautical miles (17 NM returned
//          aircraft out to 31.2 km); 82 aircraft around SFO = 35 KB at 17 NM,
//          a few KB at the default 6 NM (10 km).
//   Tiles  Esri World Dark Gray Canvas base (JPEG, no key; z/y/x in the URL),
//          TileSync.swift's source, stored as /tiles/z/x/y.jpg. CARTO dark_all
//          now needs a key and answers placeholders without one.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "traffic.h"
#include "tile_plan.h"
#include "tile_path.h"

#ifndef NET_TFR_URL
#define NET_TFR_URL "https://tfr.faa.gov/geoserver/TFR/ows?service=WFS&version=1.1.0" \
                    "&request=GetFeature&typeName=TFR:V_TFR_LOC&outputFormat=application/json"
#endif
#ifndef NET_ADSB_URL
#define NET_ADSB_URL "https://api.adsb.lol/v2/point/%.4f/%.4f/%d"   // lat, lon, radius NM
#endif
#ifndef NET_TILE_URL
#define NET_TILE_URL TILE_BASE_URL   // tile_path.h: Esri World Dark Gray, z/y/x
#endif
#define NET_TFR_RADIUS_KM  200     // TFRs within this of home (the Mac's 200 km)
// ADS-B is only for drone-aircraft conflicts (NEAR within 1 km, CONVERGING
// within 60 s), so the query is small: 10 km around home by default
// (5-30 km, NVS). A live drone more than 3 km out moves the centre to the
// middle of home and the drones and widens the radius until every live
// drone has 9 km around it, up to 30 km (net_adsb_area).
#define NET_ADSB_KM_DEFAULT   10
#define NET_ADSB_KM_MIN       5
#define NET_ADSB_KM_MAX       30
#define NET_ADSB_DRONE_FAR_M  3000.0   // a drone this far from home moves the centre
#define NET_ADSB_DRONE_COVER_M 9000.0  // ...and gets this much around it
// Map tiles: 3 km around home by default, zooms 12-15 (tile_plan.h). The
// setting runs from 1 km to what fits this board's flash (the plan's max
// radius; 30 km before a plan exists), and a sync shrinks the plan to fit.
#define NET_TILE_KM_DEFAULT   3
#define NET_TILE_KM_MIN       1
#define NET_TILE_KM_MAX       30

// ---------------------------------------------------------------------------
// JSON: small, allocation-free helpers

static inline const char* net_json_ws(const char* p) {
  while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;
  return p;
}

static inline void net_utf8_put(char* out, size_t n, size_t* k, uint32_t cp, bool* trunc) {
  char b[4];
  int len;
  if (cp < 0x80) { b[0] = (char)cp; len = 1; }
  else if (cp < 0x800) { b[0] = (char)(0xC0 | (cp >> 6)); b[1] = (char)(0x80 | (cp & 0x3F)); len = 2; }
  else if (cp < 0x10000) {
    b[0] = (char)(0xE0 | (cp >> 12)); b[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
    b[2] = (char)(0x80 | (cp & 0x3F)); len = 3;
  } else {
    b[0] = (char)(0xF0 | (cp >> 18)); b[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
    b[2] = (char)(0x80 | ((cp >> 6) & 0x3F)); b[3] = (char)(0x80 | (cp & 0x3F)); len = 4;
  }
  if (out && *k + (size_t)len < n) { memcpy(out + *k, b, (size_t)len); *k += (size_t)len; }
  else *trunc = true;
}

static inline int net_hex4(const char* p, uint32_t* v) {
  uint32_t r = 0;
  for (int i = 0; i < 4; i++) {
    char c = p[i];
    r <<= 4;
    if (c >= '0' && c <= '9') r |= (uint32_t)(c - '0');
    else if (c >= 'a' && c <= 'f') r |= (uint32_t)(c - 'a' + 10);
    else if (c >= 'A' && c <= 'F') r |= (uint32_t)(c - 'A' + 10);
    else return 0;
  }
  *v = r;
  return 1;
}

/// Read the JSON string at p (which must be '"') into out, unescaped (\uXXXX
/// as UTF-8, surrogate pairs joined). Returns the end of the string, or NULL
/// when malformed. *trunc is set when out was too small (out may be NULL).
static inline const char* net_json_str(const char* p, char* out, size_t n, bool* trunc) {
  bool tr = false;
  size_t k = 0;
  if (*p != '"') return NULL;
  p++;
  while (*p && *p != '"') {
    unsigned char c = (unsigned char)*p++;
    if (c == '\\') {
      char e = *p++;
      uint32_t cp;
      switch (e) {
        case '"': cp = '"'; break;
        case '\\': cp = '\\'; break;
        case '/': cp = '/'; break;
        case 'b': cp = 8; break;
        case 'f': cp = 12; break;
        case 'n': cp = 10; break;
        case 'r': cp = 13; break;
        case 't': cp = 9; break;
        case 'u': {
          if (!net_hex4(p, &cp)) return NULL;
          p += 4;
          if (cp >= 0xD800 && cp < 0xDC00 && p[0] == '\\' && p[1] == 'u') {
            uint32_t lo;
            if (net_hex4(p + 2, &lo) && lo >= 0xDC00 && lo < 0xE000) {
              cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
              p += 6;
            }
          }
          break;
        }
        default: return NULL;
      }
      net_utf8_put(out, n, &k, cp, &tr);
    } else {
      if (out && k + 1 < n) out[k++] = (char)c;
      else tr = true;
    }
  }
  if (out && n) out[k] = 0;
  if (trunc) *trunc = tr && out != NULL;
  return *p == '"' ? p + 1 : NULL;
}

/// Skip any JSON value; returns its end or NULL.
static inline const char* net_json_skip(const char* p) {
  p = net_json_ws(p);
  if (*p == '"') return net_json_str(p, NULL, 0, NULL);
  if (*p == '{' || *p == '[') {
    int depth = 0;
    while (*p) {
      if (*p == '"') { p = net_json_str(p, NULL, 0, NULL); if (!p) return NULL; continue; }
      if (*p == '{' || *p == '[') depth++;
      else if (*p == '}' || *p == ']') { if (--depth == 0) return p + 1; }
      p++;
    }
    return NULL;
  }
  const char* s = p;
  while (*p && *p != ',' && *p != '}' && *p != ']' && *p != ' ' && *p != '\r' && *p != '\n') p++;
  return p > s ? p : NULL;
}

/// The value of member `key` of the object at obj (top level of that object
/// only: text inside strings or nested values never matches). NULL if absent.
static inline const char* net_json_find(const char* obj, const char* key) {
  const char* p = net_json_ws(obj);
  if (*p != '{') return NULL;
  p = net_json_ws(p + 1);
  if (*p == '}') return NULL;
  while (*p == '"') {
    char k[24];
    bool tr = false;
    p = net_json_str(p, k, sizeof(k), &tr);
    if (!p) return NULL;
    p = net_json_ws(p);
    if (*p != ':') return NULL;
    p = net_json_ws(p + 1);
    if (!tr && !strcmp(k, key)) return p;
    p = net_json_skip(p);
    if (!p) return NULL;
    p = net_json_ws(p);
    if (*p != ',') return NULL;
    p = net_json_ws(p + 1);
  }
  return NULL;
}

/// String member; false when absent, not a string, or longer than n-1 bytes.
static inline bool net_json_get_str(const char* obj, const char* key, char* out, size_t n) {
  const char* v = net_json_find(obj, key);
  if (!v || *v != '"') return false;
  bool tr = false;
  if (!net_json_str(v, out, n, &tr)) return false;
  return !tr;
}

/// Number member (finite); false when absent or not a number.
static inline bool net_json_get_num(const char* obj, const char* key, double* out) {
  const char* v = net_json_find(obj, key);
  if (!v) return false;
  char* end = NULL;
  double d = strtod(v, &end);
  if (end == v || !isfinite(d)) return false;
  *out = d;
  return true;
}

/// JSON-escape s into out (without quotes). Bytes >= 0x80 pass through
/// (SSIDs are UTF-8 as a rule); control characters become \u00XX. Returns
/// the length written; the output is always terminated.
static inline size_t net_json_esc(char* out, size_t n, const char* s) {
  size_t k = 0;
  if (!n) return 0;
  for (; s && *s; s++) {
    unsigned char c = (unsigned char)*s;
    char tmp[8];
    const char* piece = tmp;
    size_t len;
    if (c == '"' || c == '\\') { tmp[0] = '\\'; tmp[1] = (char)c; len = 2; }
    else if (c < 0x20) { snprintf(tmp, sizeof(tmp), "\\u%04x", c); len = 6; }
    else { tmp[0] = (char)c; len = 1; }
    if (k + len >= n) break;
    memcpy(out + k, piece, len);
    k += len;
  }
  out[k] = 0;
  return k;
}

// ---------------------------------------------------------------------------
// Streaming split: feed an HTTP body in chunks of any size; every element
// object of the array under top-level member `key` ("ac", "features") is
// handed to on_obj as one NUL-terminated string. Objects longer than the
// buffer are skipped and counted, never cut. No full body in RAM: the
// buffer holds one element.

typedef void (*NetObjFn)(void* ctx, const char* obj, size_t n);

typedef struct {
  const char* key;
  char*    buf;           // caller's buffer (PSRAM on the device)
  size_t   cap;
  size_t   len;
  NetObjFn on_obj;
  void*    ctx;
  int      depth;         // {/[ nesting of the document
  bool     in_str, esc;
  bool     str_at_top;    // the current string started at depth 1
  char     last[24];      // the last string seen at depth 1 (a key, when ':' follows)
  uint8_t  last_len;
  bool     last_trunc;
  bool     cur_key_match; // the member being read is `key`
  bool     in_array;      // inside that member's array (depth 2)
  bool     capturing;
  bool     overflow;
  bool     found;         // the array under `key` started...
  bool     complete;      // ...and ended (the body was not cut short)
  uint32_t objects, skipped;
} NetJsonSplit;

static inline void net_split_init(NetJsonSplit* s, const char* key, char* buf, size_t cap,
                                  NetObjFn fn, void* ctx) {
  memset(s, 0, sizeof(*s));
  s->key = key;
  s->buf = buf;
  s->cap = cap;
  s->on_obj = fn;
  s->ctx = ctx;
}

static inline void net_split_feed(NetJsonSplit* s, const char* data, size_t n) {
  for (size_t i = 0; i < n; i++) {
    char c = data[i];
    if (s->capturing) {
      if (s->len + 1 < s->cap) s->buf[s->len++] = c;
      else s->overflow = true;
    }
    if (s->in_str) {
      if (s->esc) { s->esc = false; }
      else if (c == '\\') { s->esc = true; }
      else if (c == '"') { s->in_str = false; }
      else if (s->str_at_top && !s->capturing) {
        if (s->last_len + 1 < sizeof(s->last)) s->last[s->last_len++] = c;
        else s->last_trunc = true;
      }
      continue;
    }
    switch (c) {
      case '"':
        s->in_str = true;
        s->str_at_top = (s->depth == 1);
        if (s->str_at_top) { s->last_len = 0; s->last_trunc = false; }
        break;
      case ':':
        if (s->depth == 1) {
          s->last[s->last_len] = 0;
          s->cur_key_match = !s->last_trunc && !strcmp(s->last, s->key);
        }
        break;
      case ',':
        if (s->depth == 1) s->cur_key_match = false;
        break;
      case '{':
      case '[':
        s->depth++;
        if (c == '[' && s->depth == 2 && s->cur_key_match) { s->in_array = true; s->found = true; }
        else if (c == '{' && s->depth == 3 && s->in_array && !s->capturing) {
          s->capturing = true;
          s->overflow = false;
          s->buf[0] = '{';
          s->len = 1;
        }
        break;
      case '}':
      case ']':
        if (s->capturing && s->depth == 3) {
          s->capturing = false;
          if (s->overflow) s->skipped++;
          else {
            s->buf[s->len] = 0;
            s->objects++;
            if (s->on_obj) s->on_obj(s->ctx, s->buf, s->len);
          }
          s->len = 0;
        }
        if (s->depth == 2 && s->in_array) { s->in_array = false; s->complete = true; }
        if (s->depth > 0) s->depth--;
        break;
      default:
        break;
    }
  }
}

// ---------------------------------------------------------------------------
// adsb.lol aircraft (readsb JSON): hex, flight, t, lat, lon, alt_geom and
// alt_baro (ft; alt_baro may be "ground"), gs (kt), track (deg), geom_rate /
// baro_rate (ft/min), squawk ("7700"), emergency ("none" or a reason),
// seen_pos (s). Converted to traffic.h's units (m, m/s).

typedef struct {
  TrafficAircraft a;
  bool   has_hex;
  double seen_pos;
  double geom_rate, baro_rate;
  double alt_geom_ft, alt_baro_ft;
} NetAdsbParse;

static inline const char* net_adsb_member(const char* key, const char* val, void* ctx) {
  NetAdsbParse* p = (NetAdsbParse*)ctx;
  TrafficJv v;
  const char* e = traffic_value(val, &v);
  if (!e) return NULL;
  double n = v.is_str ? NAN : v.num;
  TrafficAircraft* a = &p->a;
  if (!strcmp(key, "hex") && v.is_str) {
    size_t k = 0;
    for (const char* s = v.str; *s && k < 6; s++) {
      char c = *s;
      if (c == '~') continue;   // non-ICAO (TIS-B) address marker
      if (c >= 'A' && c <= 'F') c = (char)(c + 32);
      if ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) a->hex[k++] = c;
      else { k = 0; break; }
    }
    a->hex[k] = 0;
    p->has_hex = k > 0;
  } else if (!strcmp(key, "flight") && v.is_str) traffic_copy_trim(a->callsign, sizeof(a->callsign), v.str);
  else if (!strcmp(key, "t") && v.is_str) traffic_copy_trim(a->type, sizeof(a->type), v.str);
  else if (!strcmp(key, "lat")) a->lat = (isfinite(n) && fabs(n) <= 90.0) ? n : NAN;
  else if (!strcmp(key, "lon")) a->lon = (isfinite(n) && fabs(n) <= 180.0) ? n : NAN;
  else if (!strcmp(key, "alt_geom")) p->alt_geom_ft = n;
  else if (!strcmp(key, "alt_baro")) p->alt_baro_ft = n;     // "ground" -> NaN
  else if (!strcmp(key, "gs")) a->gs_mps = (n >= 0.0) ? n * TRAFFIC_KT_TO_MPS : NAN;
  else if (!strcmp(key, "track")) a->track_deg = n;
  else if (!strcmp(key, "geom_rate")) p->geom_rate = n;
  else if (!strcmp(key, "baro_rate")) p->baro_rate = n;
  else if (!strcmp(key, "squawk") && v.is_str) {
    const char* s = v.str;
    size_t l = strlen(s);
    bool ok = l > 0 && l <= 4;
    for (size_t i = 0; i < l && ok; i++) ok = s[i] >= '0' && s[i] <= '7';
    a->squawk = ok ? (uint16_t)strtol(s, NULL, 10) : 0;
  } else if (!strcmp(key, "emergency") && v.is_str) {
    a->emergency = v.str[0] && strcmp(v.str, "none") != 0;
  } else if (!strcmp(key, "seen_pos")) p->seen_pos = n;
  return e;
}

/// One adsb.lol aircraft object -> TrafficAircraft (seen_ms from seen_pos,
/// relative to now_ms). False when it has no hex, no position, or a position
/// older than traffic.h keeps (60 s).
static inline bool net_adsb_parse_ac(const char* obj, uint32_t now_ms, TrafficAircraft* out) {
  NetAdsbParse st;
  memset(&st, 0, sizeof(st));
  st.a.lat = st.a.lon = NAN;
  st.a.alt_geom_m = st.a.alt_baro_m = st.a.gs_mps = st.a.track_deg = st.a.vs_mps = NAN;
  st.seen_pos = st.geom_rate = st.baro_rate = st.alt_geom_ft = st.alt_baro_ft = NAN;
  if (!traffic_object(obj, net_adsb_member, &st)) return false;
  if (!st.has_hex || isnan(st.a.lat) || isnan(st.a.lon)) return false;
  if (!(st.seen_pos >= 0.0) || st.seen_pos > TRAFFIC_PRESENT_S) return false;
  st.a.alt_geom_m = isfinite(st.alt_geom_ft) ? st.alt_geom_ft * TRAFFIC_FT_TO_M : NAN;
  st.a.alt_baro_m = isfinite(st.alt_baro_ft) ? st.alt_baro_ft * TRAFFIC_FT_TO_M : NAN;
  double rate = isfinite(st.geom_rate) ? st.geom_rate : st.baro_rate;
  st.a.vs_mps = isfinite(rate) ? rate * TRAFFIC_FT_TO_M / 60.0 : NAN;
  st.a.seen_ms = now_ms - (uint32_t)llround(st.seen_pos * 1000.0);
  *out = st.a;
  return true;
}

/// Where to ask adsb.lol: home and base_m, unless a live drone is more than
/// 3 km from home; then the centre of the box around home and the live
/// drones, and a radius giving every live drone 9 km (at least base_m, at
/// most max_m). drone_lat/lon: live drones with a position.
typedef struct { double lat, lon, radius_m; } NetArea;

static inline NetArea net_adsb_area(double home_lat, double home_lon, const double* drone_lat,
                                    const double* drone_lon, int nd, double base_m, double max_m) {
  NetArea a = { home_lat, home_lon, base_m };
  bool far = false;
  for (int i = 0; i < nd; i++)
    if (traffic_distance_m(home_lat, home_lon, drone_lat[i], drone_lon[i]) > NET_ADSB_DRONE_FAR_M) far = true;
  if (far) {
    // The box in metres east/north of home (antimeridian-safe), its centre.
    double x0 = 0, x1 = 0, y0 = 0, y1 = 0;
    for (int i = 0; i < nd; i++) {
      double dx, dy;
      traffic_offset_m(home_lat, home_lon, drone_lat[i], drone_lon[i], &dx, &dy);
      x0 = fmin(x0, dx); x1 = fmax(x1, dx); y0 = fmin(y0, dy); y1 = fmax(y1, dy);
    }
    double cx = (x0 + x1) / 2, cy = (y0 + y1) / 2;
    a.lat = home_lat + cy / (TRAFFIC_EARTH_R_M * TRAFFIC_DEG);
    double k = cos(home_lat * TRAFFIC_DEG);
    a.lon = home_lon + cx / (TRAFFIC_EARTH_R_M * TRAFFIC_DEG * (k < 0.01 ? 0.01 : k));
    if (a.lon > 180) a.lon -= 360;
    else if (a.lon < -180) a.lon += 360;
    for (int i = 0; i < nd; i++) {
      double need = traffic_distance_m(a.lat, a.lon, drone_lat[i], drone_lon[i]) + NET_ADSB_DRONE_COVER_M;
      if (need > a.radius_m) a.radius_m = need;
    }
  }
  if (a.radius_m > max_m) a.radius_m = max_m;
  return a;
}

/// The adsb.lol radius (whole nautical miles, rounded up) for metres.
static inline int net_adsb_nm(double radius_m) { return (int)ceil(radius_m / 1852.0 - 1e-9); }

/// A bounded set of aircraft that keeps the `cap` nearest to (lat, lon),
/// and none farther than max_m (0: no limit).
typedef struct {
  TrafficAircraft* ac;
  double*  dist;
  int      cap, n;
  double   lat, lon;
  double   max_m;
  uint32_t now_ms;
  uint32_t seen, kept;
} NetAdsbSet;

static inline void net_adsb_on_obj(void* ctx, const char* obj, size_t len) {
  (void)len;
  NetAdsbSet* s = (NetAdsbSet*)ctx;
  TrafficAircraft a;
  s->seen++;
  if (!net_adsb_parse_ac(obj, s->now_ms, &a)) return;
  double d = traffic_distance_m(s->lat, s->lon, a.lat, a.lon);
  if (s->max_m > 0 && d > s->max_m) return;
  int slot = -1;
  if (s->n < s->cap) slot = s->n++;
  else {
    int far = 0;
    for (int i = 1; i < s->n; i++) if (s->dist[i] > s->dist[far]) far = i;
    if (d < s->dist[far]) slot = far;
  }
  if (slot < 0) return;
  s->ac[slot] = a;
  s->dist[slot] = d;
  s->kept++;
}

// ---------------------------------------------------------------------------
// FAA TFR GeoJSON features -> polygons that fit the board's table.
//
// The table holds TFR_PTS_MAX points per polygon (rx_core.h). A ring with
// more is replaced by an outline that is never inside the true boundary:
// its convex hull, then (if still too many points) chords of the hull
// pushed outward until they clear it (net_hull_reduce). A concave TFR grows
// to its hull: the board may warn a little early, never late.

typedef struct {
  char   id[16];      // NOTAM_KEY, cut to 14 like the Mac app's tfr_add
  int    n;
  float  lat[96], lon[96];
} NetPoly;

// Scratch for one ring while it is parsed and reduced.
// (~26 KB: the device keeps it in PSRAM.) The largest FAA ring seen was 88 points.
#define NET_RING_MAX 512
typedef struct {
  double x[NET_RING_MAX], y[NET_RING_MAX];   // lon, lat on input; planar while reducing
  int    idx[NET_RING_MAX];
  double hx[NET_RING_MAX + 2], hy[NET_RING_MAX + 2];   // the hull
  int    n;
  bool   overflow;
} NetRing;

// Parse a ring "[[lon,lat],...]" at p into r (x = lon, y = lat).
static inline const char* net_geo_ring(const char* p, NetRing* r) {
  r->n = 0;
  r->overflow = false;
  p = net_json_ws(p);
  if (*p != '[') return NULL;
  p = net_json_ws(p + 1);
  while (*p == '[') {
    char* end;
    double lon = strtod(p + 1, &end);
    if (end == p + 1) return NULL;
    const char* q = net_json_ws(end);
    if (*q != ',') return NULL;
    double lat = strtod(q + 1, &end);
    if (end == q + 1) return NULL;
    const char* e = net_json_skip(p);   // the whole point array (3-D points too)
    if (!e) return NULL;
    if (isfinite(lat) && isfinite(lon) && fabs(lat) <= 90 && fabs(lon) <= 180) {
      if (r->n < NET_RING_MAX) { r->x[r->n] = lon; r->y[r->n] = lat; r->n++; }
      else r->overflow = true;
    }
    p = net_json_ws(e);
    if (*p == ',') p = net_json_ws(p + 1);
  }
  if (*p != ']') return NULL;
  // GeoJSON rings repeat the first point last.
  if (r->n > 1 && r->x[0] == r->x[r->n - 1] && r->y[0] == r->y[r->n - 1]) r->n--;
  return p + 1;
}

static inline double net_cross(double ox, double oy, double ax, double ay, double bx, double by) {
  return (ax - ox) * (by - oy) - (ay - oy) * (bx - ox);
}

static NetRing* s_net_sort_ring;   // qsort has no context argument
static inline int net_hull_cmp(const void* a, const void* b) {
  int i = *(const int*)a, j = *(const int*)b;
  const NetRing* r = s_net_sort_ring;
  if (r->x[i] != r->x[j]) return r->x[i] < r->x[j] ? -1 : 1;
  if (r->y[i] != r->y[j]) return r->y[i] < r->y[j] ? -1 : 1;
  return 0;
}

/// The bounding box of h points, as 4 points in place (the last resort).
static inline int net_hull_box(double* hx, double* hy, int h) {
  double x0 = hx[0], x1 = hx[0], y0 = hy[0], y1 = hy[0];
  for (int i = 1; i < h; i++) {
    x0 = fmin(x0, hx[i]); x1 = fmax(x1, hx[i]); y0 = fmin(y0, hy[i]); y1 = fmax(y1, hy[i]);
  }
  hx[0] = x0; hy[0] = y0; hx[1] = x1; hy[1] = y0; hx[2] = x1; hy[2] = y1; hx[3] = x0; hy[3] = y1;
  return 4;
}

/// Reduce a convex polygon (counter-clockwise, in place, room for h points)
/// to at most max (>= 4) vertices that enclose it: pick max vertices evenly
/// along the perimeter, push each chord outward, parallel, until every
/// vertex is on its inner side, and intersect neighbouring chords. Every
/// half-plane holds the whole polygon, so their intersection does too. A
/// circle comes out as a near-regular circumscribed polygon (a 24-gon is
/// ~1% outside). Returns the new count. per: scratch for h doubles; w:
/// scratch for 5 * max doubles (kept off the small worker stack).
static inline int net_hull_reduce(double* hx, double* hy, int h, int max, double* per, double* w) {
  double total = 0;
  for (int i = 0; i < h; i++) {
    per[i] = total;
    int j = (i + 1) % h;
    total += hypot(hx[j] - hx[i], hy[j] - hy[i]);
  }
  int sel[96];
  int k = 0;
  for (int j = 0, i = 0; j < max && i < h; j++) {
    double want = total * j / max;
    while (i < h && per[i] < want) i++;
    if (i >= h) break;
    if (k == 0 || sel[k - 1] != i) sel[k++] = i;
    i++;
  }
  // Each chord sel[m] -> sel[m+1] as a line n.p = c, n the outward normal.
  double *nx = w, *ny = w + max, *c = w + 2 * max, *ox = w + 3 * max, *oy = w + 4 * max;
  for (int m = 0; m < k; m++) {
    int a = sel[m], b = sel[(m + 1) % k];
    double dx = hx[b] - hx[a], dy = hy[b] - hy[a];
    double len = hypot(dx, dy);
    if (len <= 0) return net_hull_box(hx, hy, h);
    nx[m] = dy / len;
    ny[m] = -dx / len;
    double cm = nx[m] * hx[a] + ny[m] * hy[a];
    for (int i = 0; i < h; i++) {
      double d = nx[m] * hx[i] + ny[m] * hy[i];
      if (d > cm) cm = d;
    }
    c[m] = cm + 2e-5;   // ~2 m more, so float storage never rounds inside
  }
  for (int m = 0; m < k; m++) {
    int p = (m + k - 1) % k;
    double den = nx[p] * ny[m] - ny[p] * nx[m];     // sin of the turn between the chords
    if (!(den > 1e-12)) return net_hull_box(hx, hy, h);   // not a left turn: give up
    ox[m] = (c[p] * ny[m] - ny[p] * c[m]) / den;
    oy[m] = (nx[p] * c[m] - c[p] * nx[m]) / den;
  }
  for (int m = 0; m < k; m++) { hx[m] = ox[m]; hy[m] = oy[m]; }
  return k;
}

/// Reduce ring r (lon/lat) to at most `max` points, never inside the
/// original, into out. Rings that already fit are copied as they are.
static inline bool net_poly_fit(NetRing* r, int max, NetPoly* out) {
  if (max > 96) max = 96;
  if (r->n < 3 || max < 4) return false;
  if (r->n <= max) {
    for (int i = 0; i < r->n; i++) { out->lat[i] = (float)r->y[i]; out->lon[i] = (float)r->x[i]; }
    out->n = r->n;
    return true;
  }
  // Planar coordinates around the first point (degrees, lon scaled).
  double lat0 = r->y[0], lon0 = r->x[0];
  double k = cos(lat0 * TRAFFIC_DEG);
  if (k < 0.01) k = 0.01;
  for (int i = 0; i < r->n; i++) { r->x[i] = (r->x[i] - lon0) * k; r->y[i] -= lat0; r->idx[i] = i; }
  // Andrew's monotone chain: hull counter-clockwise, collinear points dropped.
  s_net_sort_ring = r;
  qsort(r->idx, (size_t)r->n, sizeof(int), net_hull_cmp);
  double* hx = r->hx;
  double* hy = r->hy;
  int h = 0;
  for (int t = 0; t < r->n; t++) {
    int i = r->idx[t];
    while (h >= 2 && net_cross(hx[h - 2], hy[h - 2], hx[h - 1], hy[h - 1], r->x[i], r->y[i]) <= 0) h--;
    hx[h] = r->x[i]; hy[h] = r->y[i]; h++;
  }
  for (int t = r->n - 2, lo = h + 1; t >= 0; t--) {
    int i = r->idx[t];
    while (h >= lo && net_cross(hx[h - 2], hy[h - 2], hx[h - 1], hy[h - 1], r->x[i], r->y[i]) <= 0) h--;
    hx[h] = r->x[i]; hy[h] = r->y[i]; h++;
  }
  h--;   // the last point repeats the first
  if (h < 3) return false;
  // r->x / r->y are free now that the hull is in hx / hy.
  if (h > max) h = net_hull_reduce(hx, hy, h, max, r->x, r->y);
  for (int i = 0; i < h; i++) {
    out->lat[i] = (float)(hy[i] + lat0);
    out->lon[i] = (float)(hx[i] / k + lon0);
  }
  out->n = h;
  return true;
}

/// Is (lat, lon) inside p? (Same even-odd test as rx_core's poly_contains.)
static inline bool net_poly_contains(const NetPoly* p, double lat, double lon) {
  bool in = false;
  for (int i = 0, j = p->n - 1; i < p->n; j = i++) {
    if (((p->lat[i] > lat) != (p->lat[j] > lat)) &&
        (lon < (double)(p->lon[j] - p->lon[i]) * (lat - p->lat[i]) /
                   (double)(p->lat[j] - p->lat[i]) + p->lon[i]))
      in = !in;
  }
  return in;
}

/// Distance from (lat, lon) to the polygon: 0 inside, else to the nearest vertex.
static inline double net_poly_distance_m(const NetPoly* p, double lat, double lon) {
  if (net_poly_contains(p, lat, lon)) return 0;
  double best = INFINITY;
  for (int i = 0; i < p->n; i++) {
    double d = traffic_distance_m(lat, lon, p->lat[i], p->lon[i]);
    if (d < best) best = d;
  }
  return best;
}

/// The nearest `cap` TFR polygons to home, fitted to `max_pts` points each.
typedef struct {
  NetPoly* poly;
  double*  dist;
  int      cap, n, max_pts;
  double   lat, lon, radius_m;
  NetRing* ring;              // scratch
  uint32_t features, rings, too_big;
} NetTfrSet;

static inline void net_tfr_add_ring(NetTfrSet* s, const char* id) {
  NetRing* r = s->ring;
  s->rings++;
  if (r->overflow) { s->too_big++; return; }
  NetPoly p;
  memset(&p, 0, sizeof(p));
  snprintf(p.id, sizeof(p.id), "%.14s", id);
  if (!net_poly_fit(r, s->max_pts, &p)) return;
  double d = net_poly_distance_m(&p, s->lat, s->lon);
  if (!(d <= s->radius_m)) return;
  int slot = -1;
  if (s->n < s->cap) slot = s->n++;
  else {
    int far = 0;
    for (int i = 1; i < s->n; i++) if (s->dist[i] > s->dist[far]) far = i;
    if (d < s->dist[far]) slot = far;
  }
  if (slot < 0) return;
  s->poly[slot] = p;
  s->dist[slot] = d;
}

/// One GeoJSON Feature (Polygon or MultiPolygon; the outer ring of each).
static inline void net_tfr_on_obj(void* ctx, const char* obj, size_t len) {
  (void)len;
  NetTfrSet* s = (NetTfrSet*)ctx;
  s->features++;
  char id[40] = "TFR";
  const char* props = net_json_find(obj, "properties");
  if (props) net_json_get_str(props, "NOTAM_KEY", id, sizeof(id));
  const char* geo = net_json_find(obj, "geometry");
  if (!geo || *geo != '{') return;
  char type[20] = {0};
  net_json_get_str(geo, "type", type, sizeof(type));
  const char* c = net_json_find(geo, "coordinates");
  if (!c || *c != '[') return;
  if (!strcmp(type, "Polygon")) {
    if (net_geo_ring(net_json_ws(c + 1), s->ring)) net_tfr_add_ring(s, id);
  } else if (!strcmp(type, "MultiPolygon")) {
    const char* p = net_json_ws(c + 1);
    while (*p == '[') {                       // one polygon: [outer, holes...]
      const char* e = net_json_skip(p);
      if (!e) return;
      if (net_geo_ring(net_json_ws(p + 1), s->ring)) net_tfr_add_ring(s, id);
      p = net_json_ws(e);
      if (*p == ',') p = net_json_ws(p + 1);
    }
  }
}

// ---------------------------------------------------------------------------
// SNTP (RFC 4330): one request, one answer. A reply counts only when it is
// a server reply (mode 4), synchronised (LI != 3, stratum 1-15), echoes our
// transmit time, and decodes to a date after 2024: a real sync, not a clock
// that merely looks set.

#define NET_NTP_UNIX_OFFSET 2208988800UL
#define NET_UTC_MIN         1704067200UL   // 2024-01-01

static inline void net_ntp_request(uint8_t pkt[48], uint32_t tx_sec, uint32_t tx_frac) {
  memset(pkt, 0, 48);
  pkt[0] = 0x23;   // LI 0, version 4, mode 3 (client)
  for (int i = 0; i < 4; i++) {
    pkt[40 + i] = (uint8_t)(tx_sec >> (24 - 8 * i));
    pkt[44 + i] = (uint8_t)(tx_frac >> (24 - 8 * i));
  }
}

static inline uint32_t net_be32(const uint8_t* p) {
  return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

static inline bool net_ntp_parse(const uint8_t* p, size_t n, uint32_t tx_sec, uint32_t tx_frac,
                                 uint32_t* unix_s, uint16_t* ms) {
  if (n < 48) return false;
  if ((p[0] & 7) != 4 || (p[0] >> 6) == 3) return false;
  if (p[1] < 1 || p[1] > 15) return false;
  if (net_be32(p + 24) != tx_sec || net_be32(p + 28) != tx_frac) return false;
  uint32_t sec = net_be32(p + 40);
  if (sec == 0) return false;
  uint32_t u = sec - (uint32_t)NET_NTP_UNIX_OFFSET;   // era 0 wraps in 2036: fine as unsigned
  if (u < NET_UTC_MIN) return false;
  *unix_s = u;
  if (ms) *ms = (uint16_t)(((uint64_t)net_be32(p + 44) * 1000) >> 32);
  return true;
}

// ---------------------------------------------------------------------------
// Tiles: which ones, and whether they fit, is tile_plan.h's job.

// ---------------------------------------------------------------------------
// URLs

static inline int net_url_tfr(char* out, size_t n, double lat, double lon) {
  double dlat = NET_TFR_RADIUS_KM / 111.195;
  double c = cos(lat * TRAFFIC_DEG);
  double dlon = NET_TFR_RADIUS_KM / (111.195 * (c < 0.05 ? 0.05 : c));
  double lat0 = fmax(lat - dlat, -90.0), lat1 = fmin(lat + dlat, 90.0);
  double lon0 = fmax(lon - dlon, -180.0), lon1 = fmin(lon + dlon, 180.0);
  return snprintf(out, n, "%s&bbox=%.4f,%.4f,%.4f,%.4f,EPSG:4326", NET_TFR_URL, lon0, lat0, lon1, lat1);
}

static inline int net_url_adsb(char* out, size_t n, double lat, double lon, double radius_m) {
  return snprintf(out, n, NET_ADSB_URL, lat, lon, net_adsb_nm(radius_m));
}

/// Esri's tile URLs are z/y/x (row before column).
static inline int net_url_tile(char* out, size_t n, int z, int32_t x, int32_t y) {
  return snprintf(out, n, NET_TILE_URL, z, (int)y, (int)x);
}
