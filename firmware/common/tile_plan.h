// tile_plan.h — which map tiles a board should hold, and whether they fit.
//
// A tile sync (the T5's own Wi-Fi fetch; the Mac app's push can mirror this)
// plans before it downloads anything:
//   1. The area is a CIRCLE around the centre, per zoom (12-15): a tile is
//      in when the nearest point of its box is within that zoom's radius.
//   2. Tiles already on the board are counted (a sorted list of what is on
//      flash: key + on-flash bytes, built by walking /tiles).
//   3. The missing ones are estimated at this board's measured average
//      on-flash tile size (used bytes / tiles, once >= 20 tiles exist), else
//      12 KB. Esri World Dark Gray JPEGs measured over San Francisco: 5.8 KB
//      at z12 (mostly water), 8.5 KB z13, 14.9 KB z14, 19.5 KB z15, i.e.
//      8-20 KB in 4 KB LittleFS blocks; z15 is ~2/3 of a plan, so a city
//      averages well over 7 KB, a rural area under. 12 KB stays the
//      starting guess; a board's own average replaces it after 20 tiles.
//   4. The budget is free space minus a 1 MB reserve, plus the tiles on
//      flash OUTSIDE the plan (they may be evicted to make room; a tile
//      inside the plan never is). A board already under the reserve owes
//      the difference: it comes out of the evictable tiles first.
//   5. If the missing tiles do not fit, the zoom-15 radius shrinks first
//      (250 m steps, then dropped), then z14, then z13, then z12, until
//      they do. Lower zooms keep the full radius as long as possible.
// tile_sync_run() then fetches the plan's missing tiles through the
// caller's ops, evicting outside tiles first when it must, and stops when
// free space would fall under the reserve.
//
// Pure C++ (libc/libm): tests/tile_plan_test.cpp runs all of it on a host.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <math.h>

#define TILE_PLAN_ZMIN          12
#define TILE_PLAN_ZMAX          15
#define TILE_PLAN_NZ            (TILE_PLAN_ZMAX - TILE_PLAN_ZMIN + 1)
#define TILE_PLAN_RESERVE       (1024u * 1024u)   // never fill LittleFS past this
#define TILE_PLAN_DEFAULT_BYTES 12288u            // on-flash estimate before 20 tiles exist
#define TILE_PLAN_MIN_SAMPLE    20
#define TILE_PLAN_STEP_M        250.0             // shrink step
#define TILE_PLAN_MAX_RADIUS_M  30000.0           // the most a setting can ask for
#define TILE_PLAN_EARTH_R_M     6371000.0
#define TILE_PLAN_DEG           (3.14159265358979323846 / 180.0)

// ---------------------------------------------------------------------------
// Tiles and keys

/// One tile as a sortable key: z (6 bits), x and y (22 bits each).
static inline uint64_t tile_key(int z, int32_t x, int32_t y) {
  return ((uint64_t)(uint32_t)z << 44) | ((uint64_t)(uint32_t)x << 22) | (uint64_t)(uint32_t)y;
}
static inline void tile_key_split(uint64_t k, int* z, int32_t* x, int32_t* y) {
  *z = (int)(k >> 44);
  *x = (int32_t)((k >> 22) & 0x3FFFFF);
  *y = (int32_t)(k & 0x3FFFFF);
}

static inline double tile_lon_of(double x, int z) { return x / (double)(1L << z) * 360.0 - 180.0; }
static inline double tile_lat_of(double y, int z) {
  double n = 3.14159265358979323846 * (1.0 - 2.0 * y / (double)(1L << z));
  return atan(sinh(n)) / TILE_PLAN_DEG;
}

static inline void tile_of(double lat, double lon, int z, int32_t* x, int32_t* y) {
  double n = (double)(1L << z);
  double rad = lat * TILE_PLAN_DEG;
  double fx = (lon + 180.0) / 360.0 * n;
  double fy = (1.0 - log(tan(rad) + 1.0 / cos(rad)) / 3.14159265358979323846) / 2.0 * n;
  int32_t lim = (int32_t)(1L << z) - 1;
  *x = (int32_t)fx;
  *y = (int32_t)fy;
  if (*x < 0) *x = 0;
  if (*x > lim) *x = lim;
  if (*y < 0) *y = 0;
  if (*y > lim) *y = lim;
}

/// Flat-earth distance (fine at these ranges).
static inline double tile_dist_m(double lat1, double lon1, double lat2, double lon2) {
  double dlon = lon2 - lon1;
  if (dlon > 180) dlon -= 360;
  else if (dlon < -180) dlon += 360;
  double dx = dlon * TILE_PLAN_DEG * cos((lat1 + lat2) * 0.5 * TILE_PLAN_DEG) * TILE_PLAN_EARTH_R_M;
  double dy = (lat2 - lat1) * TILE_PLAN_DEG * TILE_PLAN_EARTH_R_M;
  return sqrt(dx * dx + dy * dy);
}

/// Does tile (z, x, y) touch the circle (lat, lon, r)? r < 0: nothing does.
static inline bool tile_in_circle(double lat, double lon, double r, int z, int32_t x, int32_t y) {
  if (r < 0) return false;
  double w = tile_lon_of(x, z), e = tile_lon_of(x + 1, z);
  double n = tile_lat_of(y, z), s = tile_lat_of(y + 1, z);
  double plat = lat < s ? s : (lat > n ? n : lat);
  double plon = lon < w ? w : (lon > e ? e : lon);
  return tile_dist_m(lat, lon, plat, plon) <= r;
}

typedef struct { int32_t x0, y0, x1, y1; } TileBox;

/// The tile rows/columns the circle can touch at zoom z.
static inline TileBox tile_circle_box(double lat, double lon, double r, int z) {
  if (r < 0) r = 0;
  double dlat = r / (TILE_PLAN_EARTH_R_M * TILE_PLAN_DEG);
  double c = cos(lat * TILE_PLAN_DEG);
  double dlon = r / (TILE_PLAN_EARTH_R_M * TILE_PLAN_DEG * (c < 0.02 ? 0.02 : c));
  double n = lat + dlat, s = lat - dlat;
  if (n > 85.0) n = 85.0;
  if (s < -85.0) s = -85.0;
  TileBox b;
  tile_of(n, lon - dlon, z, &b.x0, &b.y0);
  tile_of(s, lon + dlon, z, &b.x1, &b.y1);
  return b;
}

/// Tiles inside the circle at zoom z.
static inline uint32_t tile_circle_count(double lat, double lon, double r, int z) {
  if (r < 0) return 0;
  TileBox b = tile_circle_box(lat, lon, r, z);
  uint32_t n = 0;
  for (int32_t x = b.x0; x <= b.x1; x++)
    for (int32_t y = b.y0; y <= b.y1; y++)
      if (tile_in_circle(lat, lon, r, z, x, y)) n++;
  return n;
}

// ---------------------------------------------------------------------------
// What is on flash: sorted by key

typedef struct {
  uint64_t key;
  uint32_t bytes;   // on-flash size (file size; LittleFS rounds to blocks)
} TileOnDisk;

static inline int tile_disk_cmp(const void* a, const void* b) {
  uint64_t x = ((const TileOnDisk*)a)->key, y = ((const TileOnDisk*)b)->key;
  return x < y ? -1 : (x > y ? 1 : 0);
}

/// Index of key in the sorted list, or -1.
static inline long tile_disk_find(const TileOnDisk* d, uint32_t n, uint64_t key) {
  uint32_t lo = 0, hi = n;
  while (lo < hi) {
    uint32_t mid = lo + (hi - lo) / 2;
    if (d[mid].key < key) lo = mid + 1;
    else hi = mid;
  }
  return (lo < n && d[lo].key == key) ? (long)lo : -1;
}

// ---------------------------------------------------------------------------
// The plan

typedef struct {
  double   lat, lon;
  double   radius_m[TILE_PLAN_NZ];   // per zoom (index z - 12); < 0: zoom dropped
  double   want_m;                   // the radius asked for
  uint32_t tiles[TILE_PLAN_NZ];      // in the plan, per zoom
  uint32_t have[TILE_PLAN_NZ];       // of those, on flash
  uint32_t total, present, missing;
  uint32_t avg_bytes;                // estimate per missing tile
  uint32_t disk_tiles;               // tiles on flash (all areas)
  uint64_t disk_tile_bytes;          // their bytes
  uint64_t fs_total, fs_used, fs_free;
  uint64_t capacity;                 // what maps may use: total - reserve - non-tile files
  uint64_t evictable;                // bytes of tiles on flash outside the plan
  uint64_t budget;                   // free + evictable - reserve (>= 0)
  uint64_t need_bytes;               // missing * avg
  uint64_t plan_bytes;               // the whole plan on flash: present (real) + missing (est)
  bool     fits, shrunk;
} TilePlan;

static inline bool tile_plan_contains(const TilePlan* p, int z, int32_t x, int32_t y) {
  if (z < TILE_PLAN_ZMIN || z > TILE_PLAN_ZMAX) return false;
  return tile_in_circle(p->lat, p->lon, p->radius_m[z - TILE_PLAN_ZMIN], z, x, y);
}

/// Recount the plan against what is on flash.
static inline void tile_plan_eval(TilePlan* p, const TileOnDisk* d, uint32_t n) {
  p->total = 0;
  for (int i = 0; i < TILE_PLAN_NZ; i++) {
    p->tiles[i] = tile_circle_count(p->lat, p->lon, p->radius_m[i], TILE_PLAN_ZMIN + i);
    p->have[i] = 0;
    p->total += p->tiles[i];
  }
  uint64_t in_bytes = 0;
  p->evictable = 0;
  p->present = 0;
  for (uint32_t k = 0; k < n; k++) {
    int z;
    int32_t x, y;
    tile_key_split(d[k].key, &z, &x, &y);
    if (tile_plan_contains(p, z, x, y)) {
      p->have[z - TILE_PLAN_ZMIN]++;
      p->present++;
      in_bytes += d[k].bytes;
    } else {
      p->evictable += d[k].bytes;
    }
  }
  p->missing = p->total > p->present ? p->total - p->present : 0;
  p->need_bytes = (uint64_t)p->missing * p->avg_bytes;
  p->plan_bytes = in_bytes + p->need_bytes;
  uint64_t avail = p->fs_free + p->evictable;   // under the reserve: the deficit comes off the evictable
  p->budget = avail > TILE_PLAN_RESERVE ? avail - TILE_PLAN_RESERVE : 0;
  p->fits = p->need_bytes <= p->budget;
}

/// Plan the circle of radius want_m around (lat, lon), shrinking it (z15
/// first) until it fits. d: the tiles on flash, sorted by key (n of them,
/// their bytes summed as tile bytes); fs_total/fs_used: the filesystem.
static inline void tile_plan_make(TilePlan* p, double lat, double lon, double want_m, uint64_t fs_total,
                                  uint64_t fs_used, const TileOnDisk* d, uint32_t n) {
  memset(p, 0, sizeof(*p));
  p->lat = lat;
  p->lon = lon;
  p->want_m = want_m;
  p->fs_total = fs_total;
  p->fs_used = fs_used;
  p->fs_free = fs_total > fs_used ? fs_total - fs_used : 0;
  p->disk_tiles = n;
  for (uint32_t k = 0; k < n; k++) p->disk_tile_bytes += d[k].bytes;
  uint64_t other = fs_used > p->disk_tile_bytes ? fs_used - p->disk_tile_bytes : 0;
  p->capacity = fs_total > TILE_PLAN_RESERVE + other ? fs_total - TILE_PLAN_RESERVE - other : 0;
  p->avg_bytes = n >= TILE_PLAN_MIN_SAMPLE ? (uint32_t)(fs_used / n) : TILE_PLAN_DEFAULT_BYTES;
  if (p->avg_bytes < 1024) p->avg_bytes = 1024;
  for (int i = 0; i < TILE_PLAN_NZ; i++) p->radius_m[i] = want_m;
  tile_plan_eval(p, d, n);
  for (int i = TILE_PLAN_NZ - 1; i >= 0 && !p->fits; i--) {
    while (!p->fits && p->radius_m[i] >= 0) {
      p->radius_m[i] = p->radius_m[i] > TILE_PLAN_STEP_M ? p->radius_m[i] - TILE_PLAN_STEP_M
                                                          : (p->radius_m[i] > 0 ? 0 : -1);
      p->shrunk = true;
      tile_plan_eval(p, d, n);
    }
  }
}

/// The largest radius (250 m steps, up to 30 km) whose whole z12-15 circle
/// fits in `capacity` bytes at `avg_bytes` a tile: the top of the setting.
static inline double tile_plan_max_radius_m(double lat, double lon, uint64_t capacity, uint32_t avg_bytes) {
  if (!avg_bytes) avg_bytes = TILE_PLAN_DEFAULT_BYTES;
  double best = 0;
  double lo = 0, hi = TILE_PLAN_MAX_RADIUS_M;
  while (hi - lo > TILE_PLAN_STEP_M / 2) {
    double mid = floor((lo + hi) / 2 / TILE_PLAN_STEP_M + 0.5) * TILE_PLAN_STEP_M;
    if (mid <= lo || mid >= hi) break;
    uint64_t t = 0;
    for (int z = TILE_PLAN_ZMIN; z <= TILE_PLAN_ZMAX; z++) t += tile_circle_count(lat, lon, mid, z);
    if (t * avg_bytes <= capacity) { best = mid; lo = mid; }
    else hi = mid;
  }
  uint64_t t = 0;
  for (int z = TILE_PLAN_ZMIN; z <= TILE_PLAN_ZMAX; z++) t += tile_circle_count(lat, lon, hi, z);
  if (t * avg_bytes <= capacity) best = hi;
  return best;
}

/// The next tile of the plan (zoom ascending, then x, then y). Start with
/// *z = 0; false at the end.
static inline bool tile_plan_next(const TilePlan* p, int* z, int32_t* x, int32_t* y) {
  if (*z < TILE_PLAN_ZMIN) { *z = TILE_PLAN_ZMIN; *x = INT32_MIN; }
  for (; *z <= TILE_PLAN_ZMAX; (*z)++, *x = INT32_MIN) {
    double r = p->radius_m[*z - TILE_PLAN_ZMIN];
    if (r < 0) continue;
    TileBox b = tile_circle_box(p->lat, p->lon, r, *z);
    int32_t cx, cy;
    if (*x == INT32_MIN) { cx = b.x0; cy = b.y0; }
    else { cx = *x; cy = *y + 1; }
    for (; cx <= b.x1; cx++, cy = b.y0) {
      for (; cy <= b.y1; cy++) {
        if (tile_in_circle(p->lat, p->lon, r, *z, cx, cy)) { *x = cx; *y = cy; return true; }
      }
    }
  }
  return false;
}

/// Which tiles outside the plan to evict to free `need` bytes: highest zoom
/// first, then farthest from the plan's centre (LittleFS keeps no reliable
/// age here, so distance stands in for "oldest": the map has moved away
/// from it). Never a tile inside the plan. Writes up to max indices into
/// out; returns how many; *freed gets their bytes.
static inline uint32_t tile_plan_victims(const TilePlan* p, const TileOnDisk* d, uint32_t n, uint64_t need,
                                         uint32_t* out, uint32_t max, uint64_t* freed) {
  // Repeated selection in the order (zoom desc, distance desc, index asc):
  // each round takes the best candidate after the previous one. O(n) a victim.
  uint32_t k = 0;
  uint64_t got = 0;
  int pz = 1 << 30;
  double pd = INFINITY;
  long pi = -1;
  while (got < need && k < max) {
    long best = -1;
    int bz = -1;
    double bd = -1;
    for (uint32_t i = 0; i < n; i++) {
      int z;
      int32_t x, y;
      tile_key_split(d[i].key, &z, &x, &y);
      if (tile_plan_contains(p, z, x, y)) continue;
      double dist = tile_dist_m(p->lat, p->lon, tile_lat_of(y + 0.5, z), tile_lon_of(x + 0.5, z));
      // after the previous pick?
      bool after = z < pz || (z == pz && (dist < pd || (dist == pd && (long)i > pi)));
      if (!after) continue;
      if (z > bz || (z == bz && dist > bd)) { best = (long)i; bz = z; bd = dist; }
    }
    if (best < 0) break;
    out[k++] = (uint32_t)best;
    got += d[best].bytes;
    pz = bz; pd = bd; pi = best;
  }
  if (freed) *freed = got;
  return k;
}

/// "Map: 6 km z12-14, 3 km z15; 2.9 MB of 5.0 MB" (ASCII: the panel fonts).
static inline void tile_plan_describe(const TilePlan* p, char* out, size_t n) {
  size_t k = (size_t)snprintf(out, n, "Map:");
  int i = 0;
  bool any = false;
  while (i < TILE_PLAN_NZ && k < n) {
    int j = i;
    while (j + 1 < TILE_PLAN_NZ && p->radius_m[j + 1] == p->radius_m[i]) j++;
    if (p->radius_m[i] >= 0) {
      double km = p->radius_m[i] / 1000.0;
      char r[16];
      if (fabs(km - floor(km + 0.5)) < 0.05) snprintf(r, sizeof(r), "%.0f km", km);
      else snprintf(r, sizeof(r), "%.1f km", km);
      if (j > i) k += (size_t)snprintf(out + k, n - k, "%s %s z%d-%d", any ? "," : "", r, TILE_PLAN_ZMIN + i, TILE_PLAN_ZMIN + j);
      else k += (size_t)snprintf(out + k, n - k, "%s %s z%d", any ? "," : "", r, TILE_PLAN_ZMIN + i);
      any = true;
    }
    i = j + 1;
  }
  if (!any && k < n) k += (size_t)snprintf(out + k, n - k, " none");
  if (k < n)
    snprintf(out + k, n - k, "; %.1f MB of %.1f MB", (double)p->plan_bytes / 1048576.0,
             (double)p->capacity / 1048576.0);
}

// ---------------------------------------------------------------------------
// Running a sync through the caller's filesystem and network

typedef struct {
  void*    ctx;
  uint64_t (*free_bytes)(void* ctx);                                  // free on the filesystem now
  int      (*fetch)(void* ctx, int z, int32_t x, int32_t y, uint32_t* bytes);  // 1 ok, 0 this tile failed, -1 stop
  bool     (*remove)(void* ctx, uint64_t key);                        // evict one tile
  bool     (*cancelled)(void* ctx);
  void     (*progress)(void* ctx, uint32_t done, uint32_t total);     // plan tiles walked
} TileSyncOps;

typedef struct {
  uint32_t fetched, failed, evicted;
  uint32_t left;           // plan tiles still missing when it stopped (0: complete)
  bool     storage_full;   // stopped at the reserve
  bool     stopped;        // fetch said stop (memory, write error, 3 failures in a row) or cancelled
  bool     cancelled;
} TileSyncResult;

/// Fetch the plan's missing tiles (at most max_new this time), evicting
/// tiles outside the plan first if the space for them is short, and never
/// letting free space fall under the reserve. d/n: the tiles on flash,
/// sorted (evicted entries are not removed from it; they are outside the
/// plan, so the walk never looks them up). victims: scratch for max_victims.
/// A cancel is checked before anything is evicted and on every plan tile
/// walked; it stops at once (left: what the plan still misses).
static inline void tile_sync_run(const TilePlan* p, const TileOnDisk* d, uint32_t n, uint32_t max_new,
                                 const TileSyncOps* ops, uint32_t* victims, uint32_t max_victims,
                                 TileSyncResult* r) {
  memset(r, 0, sizeof(*r));
  if (ops->cancelled && ops->cancelled(ops->ctx)) {   // before evicting anything
    r->cancelled = r->stopped = true;
    r->left = p->missing;
    return;
  }
  uint32_t want = p->missing < max_new ? p->missing : max_new;
  uint64_t need = (uint64_t)want * p->avg_bytes;
  // Evict room for the new tiles over the reserve: on a board already under
  // it, the deficit too (else the walk would stop at the reserve at once).
  uint64_t fr = ops->free_bytes(ops->ctx);
  if (need && need + TILE_PLAN_RESERVE > fr && victims && max_victims) {
    uint64_t freed = 0;
    uint32_t nv = tile_plan_victims(p, d, n, need + TILE_PLAN_RESERVE - fr, victims, max_victims, &freed);
    for (uint32_t i = 0; i < nv; i++)
      if (ops->remove(ops->ctx, d[victims[i]].key)) r->evicted++;
  }
  uint32_t walked = 0, fails = 0;
  uint32_t margin = p->avg_bytes;   // room one more tile needs: the estimate, or the biggest seen
  int z = 0;
  int32_t x = 0, y = 0;
  uint32_t missing_seen = 0;
  bool stop = false;
  while (tile_plan_next(p, &z, &x, &y)) {
    if (ops->cancelled && ops->cancelled(ops->ctx)) { r->cancelled = r->stopped = true; break; }
    walked++;
    if (ops->progress) ops->progress(ops->ctx, walked, p->total);
    if (tile_disk_find(d, n, tile_key(z, x, y)) >= 0) continue;
    missing_seen++;
    if (stop) continue;   // keep counting what is left
    if (r->fetched >= max_new) { stop = true; continue; }
    if (ops->free_bytes(ops->ctx) < (uint64_t)TILE_PLAN_RESERVE + margin) {
      r->storage_full = true;
      stop = true;
      continue;
    }
    uint32_t bytes = 0;
    int got = ops->fetch(ops->ctx, z, x, y, &bytes);
    if (got > 0) {
      r->fetched++;
      fails = 0;
      if (bytes > margin) margin = bytes;
      continue;
    }
    r->failed++;
    if (got < 0 || ++fails >= 3) { r->stopped = true; stop = true; }
  }
  // Cancelled mid-walk: the plan's own count (missing_seen stopped short).
  if (r->cancelled) r->left = p->missing > r->fetched ? p->missing - r->fetched : 0;
  else r->left = missing_seen > r->fetched ? missing_seen - r->fetched : 0;
}
