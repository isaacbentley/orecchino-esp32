// Host tests for firmware/common/tile_plan.h: the circle of map tiles a
// board keeps, whether it fits the flash, how it shrinks, what may be
// evicted, and a sync run that stops at the reserve.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
#include "tile_plan.h"
#include <algorithm>
#include <map>
#include <vector>

static int g_fails = 0;
#define CHECK(c, name) do { if (c) printf("ok   %s\n", name); else { printf("FAIL %s\n", name); g_fails++; } } while (0)

static const uint64_t T5_FS = 0xCF0000;       // 13.6 MB LittleFS
static const uint64_t SENSECAP_FS = 0x5E0000;  // 6.0 MB

static uint32_t plan_tiles(double lat, double lon, double r) {
  uint32_t n = 0;
  for (int z = TILE_PLAN_ZMIN; z <= TILE_PLAN_ZMAX; z++) n += tile_circle_count(lat, lon, r, z);
  return n;
}

static std::vector<TileOnDisk> disk_of(const std::vector<uint64_t>& keys, uint32_t bytes) {
  std::vector<TileOnDisk> d;
  for (uint64_t k : keys) d.push_back({k, bytes});
  std::sort(d.begin(), d.end(), [](const TileOnDisk& a, const TileOnDisk& b) { return a.key < b.key; });
  return d;
}

static void test_circle() {
  int z;
  int32_t x, y;
  tile_key_split(tile_key(15, 5241, 12665), &z, &x, &y);
  CHECK(z == 15 && x == 5241 && y == 12665, "key: packs and unpacks");
  tile_of(37.7749, -122.4194, 15, &x, &y);
  CHECK(x == 5241 && y == 12665, "tile_of matches TileSync.swift's deg2tile");
  // The circle against the square: fewer tiles, and every tile whose centre
  // is within the radius is in.
  double lat = 37.8, lon = -122.4, r = 3000;
  uint32_t circle = 0, square = 0;
  bool centres_in = true;
  for (int zz = 12; zz <= 15; zz++) {
    TileBox b = tile_circle_box(lat, lon, r, zz);
    square += (uint32_t)((b.x1 - b.x0 + 1) * (b.y1 - b.y0 + 1));
    circle += tile_circle_count(lat, lon, r, zz);
    for (int32_t tx = b.x0; tx <= b.x1; tx++)
      for (int32_t ty = b.y0; ty <= b.y1; ty++) {
        double clat = tile_lat_of(ty + 0.5, zz), clon = tile_lon_of(tx + 0.5, zz);
        if (tile_dist_m(lat, lon, clat, clon) <= r && !tile_in_circle(lat, lon, r, zz, tx, ty)) centres_in = false;
      }
  }
  char name[120];
  snprintf(name, sizeof(name), "circle: 3 km at 37.8N, z12-15: %u tiles (the square: %u)", circle, square);
  CHECK(circle < square && circle >= 60 && circle <= 110, name);
  CHECK(centres_in, "circle: every tile centred inside the radius is in");
  CHECK(tile_circle_count(lat, lon, 3000, 15) > tile_circle_count(lat, lon, 3000, 12), "circle: more tiles at higher zoom");
  // Latitude: tiles shrink on the ground toward the poles, so the same
  // radius needs more of them.
  uint32_t eq = plan_tiles(0.5, 10.0, 3000), mid = plan_tiles(37.8, -122.4, 3000), hi = plan_tiles(69.6, 18.9, 3000);
  snprintf(name, sizeof(name), "latitude: 3 km needs %u tiles at 0.5N, %u at 37.8N, %u at 69.6N", eq, mid, hi);
  CHECK(eq < mid && mid < hi && hi < 10 * eq, name);
  CHECK(plan_tiles(84.0, 0.0, 3000) > 0, "latitude: 84N still plans (box clamped)");
  uint32_t t6 = plan_tiles(37.8, -122.4, 6000), t8 = plan_tiles(37.8, -122.4, 8000), t10 = plan_tiles(37.8, -122.4, 10000);
  snprintf(name, sizeof(name), "sizes at 37.8N: 6 km %u, 8 km %u, 10 km %u tiles", t6, t8, t10);
  CHECK(t6 < t8 && t8 < t10 && t10 < 700, name);
  // The walk visits exactly the plan's tiles, once each.
  TilePlan p;
  tile_plan_make(&p, lat, lon, 3000, T5_FS, 0, NULL, 0);
  std::vector<uint64_t> seen;
  z = 0;
  while (tile_plan_next(&p, &z, &x, &y)) {
    seen.push_back(tile_key(z, x, y));
    if (!tile_in_circle(lat, lon, 3000, z, x, y)) { seen.clear(); break; }
  }
  std::vector<uint64_t> s2 = seen;
  std::sort(s2.begin(), s2.end());
  CHECK(seen.size() == p.total && std::adjacent_find(s2.begin(), s2.end()) == s2.end(), "walk: every plan tile once");
}

static void test_budget_and_shrink() {
  double lat = 37.8, lon = -122.4;
  char name[160], line[120];
  // Empty T5: the 3 km default fits, estimated at 12 KB a tile.
  TilePlan p;
  tile_plan_make(&p, lat, lon, 3000, T5_FS, 64 * 1024, NULL, 0);
  snprintf(name, sizeof(name), "T5 default: %u tiles, %.1f MB est., fits, not shrunk", p.total, p.need_bytes / 1048576.0);
  CHECK(p.fits && !p.shrunk && p.avg_bytes == TILE_PLAN_DEFAULT_BYTES && p.missing == p.total, name);
  tile_plan_describe(&p, line, sizeof(line));
  printf("     %s\n", line);
  CHECK(!strncmp(line, "Map: 3 km z12-15; ", 18), "describe: one radius for every zoom");
  // SenseCAP (6.0 MB): 10 km does not fit; z15 shrinks first, lower zooms keep 10 km.
  tile_plan_make(&p, lat, lon, 10000, SENSECAP_FS, 200 * 1024, NULL, 0);
  tile_plan_describe(&p, line, sizeof(line));
  printf("     %s\n", line);
  snprintf(name, sizeof(name), "SenseCAP 10 km: shrunk to fit (z15 %.2f km), z12-13 kept at 10 km", p.radius_m[3] / 1000);
  CHECK(p.fits && p.shrunk && p.radius_m[3] < 10000 && p.radius_m[0] == 10000 && p.radius_m[1] == 10000, name);
  CHECK(p.radius_m[2] == 10000 || p.radius_m[3] < 0, "shrink: z14 only shrinks once z15 is gone");
  CHECK(strstr(line, "10 km z12-") != NULL, "describe: groups the full-radius zooms");
  // The setting's top: the largest radius whose whole circle fits.
  double tmax = tile_plan_max_radius_m(lat, lon, T5_FS - TILE_PLAN_RESERVE, 11 * 1024);
  double smax = tile_plan_max_radius_m(lat, lon, SENSECAP_FS - TILE_PLAN_RESERVE, 11 * 1024);
  snprintf(name, sizeof(name), "max radius at 11 KB/tile: T5 %.2f km, SenseCAP %.2f km", tmax / 1000, smax / 1000);
  CHECK(smax < tmax && smax >= 6000 && smax < 10000 && tmax > 10000, name);
  uint32_t at = plan_tiles(lat, lon, smax), over = plan_tiles(lat, lon, smax + TILE_PLAN_STEP_M);
  CHECK((uint64_t)at * 11 * 1024 <= SENSECAP_FS - TILE_PLAN_RESERVE &&
        (uint64_t)over * 11 * 1024 > SENSECAP_FS - TILE_PLAN_RESERVE, "max radius: the next step would not fit");
  // Average from what is on flash (>= 20 tiles): used bytes / tiles.
  std::vector<uint64_t> keys;
  for (int i = 0; i < 30; i++) keys.push_back(tile_key(15, 5241 + i, 12665));
  auto d = disk_of(keys, 9000);
  tile_plan_make(&p, lat, lon, 3000, T5_FS, 30 * 9000 + 30 * 1000, d.data(), (uint32_t)d.size());
  CHECK(p.avg_bytes == 10000, "estimate: this board's used bytes / tiles once 20 exist");
  tile_plan_make(&p, lat, lon, 3000, T5_FS, 10 * 9000, d.data(), 10);
  CHECK(p.avg_bytes == TILE_PLAN_DEFAULT_BYTES, "estimate: 12 KB below 20 tiles");
}

static void test_eviction() {
  double lat = 37.8, lon = -122.4;
  // A full-ish SenseCAP holding an old area 40 km away plus part of the new one.
  std::vector<uint64_t> keys;
  int32_t x, y;
  for (int zz = 12; zz <= 15; zz++) {
    tile_of(39.5, -122.4, zz, &x, &y);    // 190 km north: outside the plan
    for (int i = 0; i < 60; i++) keys.push_back(tile_key(zz, x + i % 10, y + i / 10));
  }
  tile_of(lat, lon, 15, &x, &y);
  std::vector<uint64_t> inside = { tile_key(15, x, y), tile_key(15, x + 1, y), tile_key(14, x / 2, y / 2) };
  for (uint64_t k : inside) keys.push_back(k);
  auto d = disk_of(keys, 11 * 1024);
  uint64_t used = (uint64_t)d.size() * 11 * 1024;
  uint64_t fs = used + TILE_PLAN_RESERVE + 200 * 1024;   // only 200 KB free past the reserve
  TilePlan p;
  tile_plan_make(&p, lat, lon, 3000, fs, used, d.data(), (uint32_t)d.size());
  CHECK(p.present == 3 && p.evictable == (uint64_t)(d.size() - 3) * 11 * 1024, "evict: outside tiles counted as evictable");
  CHECK(p.fits && !p.shrunk, "evict: the plan fits by evicting the old area");
  std::vector<uint32_t> v(d.size());
  uint64_t freed = 0;
  uint32_t nv = tile_plan_victims(&p, d.data(), (uint32_t)d.size(), UINT64_MAX, v.data(), (uint32_t)v.size(), &freed);
  bool none_inside = true, zoom_order = true;
  int last_z = 99;
  for (uint32_t i = 0; i < nv; i++) {
    int z;
    int32_t tx, ty;
    tile_key_split(d[v[i]].key, &z, &tx, &ty);
    if (tile_plan_contains(&p, z, tx, ty)) none_inside = false;
    if (z > last_z) zoom_order = false;
    last_z = z;
  }
  CHECK(nv == d.size() - 3 && none_inside, "evict: never a tile inside the plan, even asked for everything");
  CHECK(zoom_order, "evict: highest zoom first");
  nv = tile_plan_victims(&p, d.data(), (uint32_t)d.size(), 50 * 1024, v.data(), (uint32_t)v.size(), &freed);
  CHECK(nv == 5 && freed >= 50 * 1024, "evict: only as many as the shortfall needs");
}

// A fake filesystem + network for tile_sync_run.
struct FakeFs {
  uint64_t total = 0, used = 0;
  std::map<uint64_t, uint32_t> files;
  uint32_t tile_bytes = 11 * 1024;
  int fetches = 0, fail_every = 0, removes = 0;
  bool cancel_after = false;
  int cancel_at = -1;
  int walked = 0, cancel_walk = -1;   // progress calls; cancel once this many were walked
};
static uint64_t ff_free(void* c) { FakeFs* f = (FakeFs*)c; return f->total - f->used; }
static int ff_fetch(void* c, int z, int32_t x, int32_t y, uint32_t* bytes) {
  FakeFs* f = (FakeFs*)c;
  f->fetches++;
  if (f->fail_every && f->fetches % f->fail_every == 0) return 0;
  f->files[tile_key(z, x, y)] = f->tile_bytes;
  f->used += f->tile_bytes;
  *bytes = f->tile_bytes;
  return 1;
}
static bool ff_remove(void* c, uint64_t k) {
  FakeFs* f = (FakeFs*)c;
  auto it = f->files.find(k);
  if (it == f->files.end()) return false;
  f->used -= it->second;
  f->files.erase(it);
  f->removes++;
  return true;
}
static bool ff_cancel(void* c) {
  FakeFs* f = (FakeFs*)c;
  return (f->cancel_at >= 0 && f->fetches >= f->cancel_at) || (f->cancel_walk >= 0 && f->walked >= f->cancel_walk);
}
static void ff_progress(void* c, uint32_t, uint32_t) { ((FakeFs*)c)->walked++; }

static std::vector<TileOnDisk> disk_now(const FakeFs& f) {
  std::vector<TileOnDisk> d;
  for (auto& kv : f.files) d.push_back({kv.first, kv.second});
  return d;   // std::map iterates in key order
}

static void test_sync_run() {
  double lat = 37.8, lon = -122.4;
  FakeFs f;
  f.total = 0x5E0000;
  f.used = 0;
  TileSyncOps ops = { &f, ff_free, ff_fetch, ff_remove, ff_cancel, NULL };
  std::vector<uint32_t> v(4096);
  TilePlan p;
  auto d = disk_now(f);
  tile_plan_make(&p, lat, lon, 3000, f.total, f.used, d.data(), (uint32_t)d.size());
  TileSyncResult r;
  tile_sync_run(&p, d.data(), (uint32_t)d.size(), 8, &ops, v.data(), (uint32_t)v.size(), &r);
  CHECK(r.fetched == 8 && r.left == p.total - 8 && !r.storage_full, "sync: an automatic run takes its 8 and says what is left");
  d = disk_now(f);
  tile_plan_make(&p, lat, lon, 3000, f.total, f.used, d.data(), (uint32_t)d.size());
  tile_sync_run(&p, d.data(), (uint32_t)d.size(), 0xFFFF, &ops, v.data(), (uint32_t)v.size(), &r);
  CHECK(r.left == 0 && f.files.size() == p.total, "sync: UPDATE MAP completes the plan, skipping what is there");
  // Stop at the reserve: the plan fitted on the estimate, but the tiles come
  // out far bigger than estimated (or something else writes meanwhile).
  FakeFs g;
  g.total = 2 * 1024 * 1024;
  g.tile_bytes = 60 * 1024;
  TileSyncOps gops = { &g, ff_free, ff_fetch, ff_remove, ff_cancel, NULL };
  tile_plan_make(&p, lat, lon, 3000, g.total, g.used, NULL, 0);
  CHECK(p.fits && !p.shrunk, "sync: (the plan fits on the 12 KB estimate)");
  tile_sync_run(&p, NULL, 0, 0xFFFF, &gops, v.data(), (uint32_t)v.size(), &r);
  CHECK(r.storage_full && r.fetched > 0 && g.total - g.used >= TILE_PLAN_RESERVE,
        "sync: stops before free space falls under the reserve");
  CHECK(r.left == p.total - r.fetched, "sync: and reports what is still missing");
  // Evicts outside tiles first when short.
  FakeFs h;
  h.total = 3 * 1024 * 1024;
  int32_t ox, oy;
  tile_of(38.3, -122.4, 15, &ox, &oy);
  for (int i = 0; i < 150; i++) { h.files[tile_key(15, ox + i % 15, oy + i / 15)] = h.tile_bytes; h.used += h.tile_bytes; }
  TileSyncOps hops = { &h, ff_free, ff_fetch, ff_remove, ff_cancel, NULL };
  auto hd = disk_now(h);
  tile_plan_make(&p, lat, lon, 2000, h.total, h.used, hd.data(), (uint32_t)hd.size());
  uint32_t want = p.missing;
  tile_sync_run(&p, hd.data(), (uint32_t)hd.size(), 0xFFFF, &hops, v.data(), (uint32_t)v.size(), &r);
  CHECK(r.evicted > 0 && r.fetched == want && r.left == 0 && h.total - h.used >= TILE_PLAN_RESERVE,
        "sync: evicts outside tiles first, then fetches the whole plan above the reserve");
  // A board already under the reserve (the store's own fs_begin eviction does
  // not keep it): the plan's budget and the eviction both pay the deficit
  // first, so the run fetches the plan instead of stopping at once.
  FakeFs u;
  u.total = 3 * 1024 * 1024;
  for (int i = 0; i < 225; i++) { u.files[tile_key(15, ox + i % 15, oy + i / 15)] = u.tile_bytes; u.used += u.tile_bytes; }
  uint64_t deficit = TILE_PLAN_RESERVE - (u.total - u.used);
  TileSyncOps uops = { &u, ff_free, ff_fetch, ff_remove, ff_cancel, NULL };
  auto ud = disk_now(u);
  tile_plan_make(&p, lat, lon, 2000, u.total, u.used, ud.data(), (uint32_t)ud.size());
  CHECK(u.total - u.used < TILE_PLAN_RESERVE && p.budget == p.evictable - deficit,
        "budget: a board under the reserve owes the deficit out of the evictable tiles");
  want = p.missing;
  tile_sync_run(&p, ud.data(), (uint32_t)ud.size(), 0xFFFF, &uops, v.data(), (uint32_t)v.size(), &r);
  CHECK(p.fits && r.fetched == want && r.left == 0 && !r.storage_full && u.total - u.used >= TILE_PLAN_RESERVE,
        "sync: under the reserve, evicts the deficit too and fetches the whole plan");
  // Failures: three in a row stop; cancel stops.
  FakeFs k;
  k.total = T5_FS;
  k.used = 0;
  k.fail_every = 1;
  TileSyncOps kops = { &k, ff_free, ff_fetch, ff_remove, ff_cancel, NULL };
  tile_plan_make(&p, lat, lon, 3000, k.total, 0, NULL, 0);
  tile_sync_run(&p, NULL, 0, 0xFFFF, &kops, v.data(), (uint32_t)v.size(), &r);
  CHECK(r.stopped && r.failed == 3 && r.fetched == 0, "sync: three failures in a row stop it");
  FakeFs c;
  c.total = 0xCF0000;
  c.cancel_at = 5;
  TileSyncOps cops = { &c, ff_free, ff_fetch, ff_remove, ff_cancel, NULL };
  tile_sync_run(&p, NULL, 0, 0xFFFF, &cops, v.data(), (uint32_t)v.size(), &r);
  CHECK(r.cancelled && r.fetched == 5, "sync: cancel stops at the next tile");
  // Cancelled before it starts (a phone connected while the plan was made):
  // nothing evicted, nothing fetched, the whole shortfall left.
  FakeFs e;
  e.total = 3 * 1024 * 1024;
  for (int i = 0; i < 150; i++) { e.files[tile_key(15, ox + i % 15, oy + i / 15)] = e.tile_bytes; e.used += e.tile_bytes; }
  e.cancel_at = 0;
  TileSyncOps eops = { &e, ff_free, ff_fetch, ff_remove, ff_cancel, NULL };
  auto ed = disk_now(e);
  tile_plan_make(&p, lat, lon, 2000, e.total, e.used, ed.data(), (uint32_t)ed.size());
  tile_sync_run(&p, ed.data(), (uint32_t)ed.size(), 0xFFFF, &eops, v.data(), (uint32_t)v.size(), &r);
  CHECK(r.cancelled && e.removes == 0 && r.evicted == 0 && e.fetches == 0 && r.left == p.missing && p.missing > 0,
        "sync: a cancel before the start evicts nothing");
  // Nothing missing (the hardware case: a complete 3 km area): the walk
  // itself stops at a cancel instead of running through the whole plan.
  d = disk_now(f);
  tile_plan_make(&p, lat, lon, 3000, f.total, f.used, d.data(), (uint32_t)d.size());
  CHECK(p.missing == 0 && p.total > 20, "sync: (the area is complete)");
  f.walked = 0;
  f.cancel_walk = 10;
  TileSyncOps pops = { &f, ff_free, ff_fetch, ff_remove, ff_cancel, ff_progress };
  tile_sync_run(&p, d.data(), (uint32_t)d.size(), 8, &pops, v.data(), (uint32_t)v.size(), &r);
  CHECK(r.cancelled && f.walked == 10 && r.fetched == 0 && r.left == 0, "sync: a cancel mid-walk stops the walk at once");
}

int main(void) {
  test_circle();
  test_budget_and_shrink();
  test_eviction();
  test_sync_run();
  if (g_fails) printf("%d FAILED\n", g_fails); else printf("all tile plan checks passed\n");
  return g_fails ? 1 : 0;
}
