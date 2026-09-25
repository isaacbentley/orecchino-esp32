// net_fetch.h — the T5's HTTPS jobs for net_sync.h, on a worker task:
// SNTP, FAA TFRs, adsb.lol aircraft and Esri World Dark Gray map tiles.
//
// Include in the sketch only, after rx_core.h, tile_store.h and net_sync.h
// (it installs TFRs into rx_core's table and writes tiles like tile_store).
// net_fetch_ops() fills NetOps.jobs_*.
//
// How each job uses memory and time (the loop never waits on any of it):
//   TIME   one SNTP query over UDP (pool.ntp.org, then time.google.com),
//          2 s timeout each. No TLS.
//   TFR    GET the WFS layer with a bbox 200 km around home (a few KB; the
//          whole US feed is 110 KB), streamed through NetJsonSplit: one
//          GeoJSON feature at a time in a 16 KB PSRAM buffer; the nearest
//          TFR_MAX polygons, each fitted to TFR_PTS_MAX points (net_poly_fit,
//          never inside the true outline). Installed under RX_LOCK by
//          jobs_poll on the loop, replacing the table only when the whole
//          answer parsed. 30 s deadline, 1 MB cap.
//   ADS-B  GET adsb.lol around home, 10 km by default (5-30, whole NM
//          rounded up: 6 NM), widened around live drones more than 3 km out
//          so each has 9 km (net_adsb_area, <= 30 km); a few KB. Streamed
//          one aircraft object at a time; the nearest 64 within the radius
//          kept in PSRAM, handed to traffic_ingest() on the loop (it keeps
//          32). 15 s deadline, 512 KB cap.
//   TILES  plan first (tile_plan.h): the circle of z12-15 tiles around home
//          (3 km by default), counted against what /tiles holds and the flash
//          (1 MB reserve; tiles outside the plan may be evicted), shrunk z15
//          first until it fits. Then only missing tiles, at most 4 requests
//          a second, each streamed to /tiles/fetch.part (JPEG signature
//          checked, NET_TILE_MAX_BYTES cap: 64 KB, what the screens decode)
//          and renamed into place as z/x/y.jpg; it stops before free space
//          falls under the reserve. At most `tile_budget` new tiles per
//          window (8 automatically, all for UPDATE MAP). Needs an
//          internal-RAM task stack (flash writes).
//   Every HTTPS request first checks the internal heap: a TLS session
//   takes ~52 KB of it (measured on the T5: heap_int 76,648 -> heap_tls
//   24,320 with the session open; 68,732 -> 18,196), mbedTLS's record
//   buffers and the socket. Under NET_TLS_MIN_FREE free (65 KB: that plus
//   ~13 KB for the Wi-Fi/BT drivers' RX buffers) or NET_TLS_MIN_BLOCK
//   largest block, the job fails with "low memory (..)". The numbers are
//   reported in the "synced" status line (heap_int, heap_blk, heap_tls).
//   An HTTP 429 is reported with its Retry-After (NetJobResult
//   rate_limited / retry_after_s); net_sync.h holds the job that long.
//   A cancel (a phone connecting, a new CONNECT, mode OFF) is checked
//   between jobs, in every HTTPS read, between the tile job's listing,
//   planning and downloads, and on every plan tile walked; a job it cuts
//   short (or never starts) is reported in `cancelled`, not `failed`.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#if defined(ESP_PLATFORM)

#include <stdarg.h>
#include <esp_http_client.h>
#include <esp_crt_bundle.h>
#include <esp_heap_caps.h>
#include <esp_random.h>
#include <lwip/sockets.h>
#include <lwip/netdb.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <freertos/idf_additions.h>
#include <LittleFS.h>
#include "ext_ram.h"
#include "net_sync.h"
#include "net_parse.h"

#ifndef NET_TLS_MIN_FREE
#define NET_TLS_MIN_FREE  (65u * 1024u)   // a session takes ~52 KB (measured) + ~13 KB for the radios
#endif
#ifndef NET_TLS_MIN_BLOCK
#define NET_TLS_MIN_BLOCK (18u * 1024u)
#endif
// The screens decode a tile of at most TILE_JPG_MAX (64 KB: ui_epd.cpp,
// display.cpp); a bigger one would be stored, counted present and never
// drawn, so the fetch refuses it too. Esri dark-grey tiles run <= 20 KB.
#define NET_TILE_MAX_BYTES (64u * 1024u)
#define NET_ADSB_STAGE    64
#define NET_OBJ_BUF       (16 * 1024)
#define NET_IO_BUF        2048
#define NET_URL_MAX       384
#define NET_TILE_TMP      "/tiles/fetch.part"
#define NET_TILE_GAP_MS   250u      // at most 4 tile requests a second
#define NET_TILE_DISK_MAX 4096      // tiles listed from flash (13.6 MB / ~11 KB is ~1,200)
#define NET_DRONES_MAX    16
#define NET_FETCH_STACK   8192
#ifndef NET_FETCH_STACK_PSRAM
#define NET_FETCH_STACK_PSRAM 1     // 0: always an internal-RAM stack (if TLS misbehaves on a PSRAM stack)
#endif
#define NET_USER_AGENT    "orecchino/" FW_VERSION " (T5 Remote ID receiver; offline map, <= 4 tiles/s)"

typedef struct {
  TaskHandle_t task;
  bool         psram_stack;
  volatile bool done, cancel;
  NetJobReq    req;
  NetJobResult res;
  double       lat, lon;
  bool         home;
  // staging, PSRAM
  TrafficAircraft* ac;
  double*      ac_d;
  int          ac_n;
  bool         ac_ok;
  uint32_t     ac_ms;
  NetPoly*     tfr;
  double*      tfr_d;
  int          tfr_n;
  bool         tfr_ok;
  NetRing*     ring;
  char*        obj;
  uint8_t*     io;
  char*        url;
  TileOnDisk*  disk;            // what /tiles holds (sorted)
  uint32_t*    victims;
  NetArea      adsb;            // where to ask adsb.lol this time
  uint32_t     tile_last_ms;    // rate limit
  int          http_status;     // of the last request (0: none / no answer)
  uint32_t     retry_after_s;   // its Retry-After, seconds (0: none)
} NetFetch;

static NetFetch s_nf;

static void net_fetch_err(const char* job, const char* fmt, ...) __attribute__((format(printf, 2, 3)));
static void net_fetch_err(const char* job, const char* fmt, ...) {
  if (s_nf.res.err[0]) return;   // the first one tells the story
  char msg[48];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(msg, sizeof(msg), fmt, ap);
  va_end(ap);
  snprintf(s_nf.res.err, sizeof(s_nf.res.err), "%s: %s", job, msg);
}

/// A job that did not finish: cut short by a cancel (no failure: reported
/// under "cancelled", no back-off), else failed.
static void net_job_stop(uint32_t bit, const char* job) {
  if (s_nf.cancel) {
    s_nf.res.cancelled |= bit;
    net_fetch_err(job, "cancelled");
  } else {
    s_nf.res.failed |= bit;
  }
}

/// After a failed request: was it an HTTP 429? Then the job is reported
/// rate limited with the first Retry-After seen (net_sync.h holds it).
static void net_job_rate_limited(uint32_t bit) {
  if (s_nf.http_status != 429) return;
  s_nf.res.rate_limited |= bit;
  if (s_nf.retry_after_s > s_nf.res.retry_after_s) s_nf.res.retry_after_s = s_nf.retry_after_s;   // the longest wait asked for
}

/// Enough internal RAM for a TLS session? Records the first measurement.
static bool net_heap_ok(const char* job) {
  size_t f = heap_caps_get_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
  size_t b = heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
  if (!s_nf.res.heap_free) { s_nf.res.heap_free = (uint32_t)f; s_nf.res.heap_block = (uint32_t)b; }
  if (f >= NET_TLS_MIN_FREE && b >= NET_TLS_MIN_BLOCK) return true;
  net_fetch_err(job, "low memory (%u KB, block %u KB)", (unsigned)(f / 1024), (unsigned)(b / 1024));
  return false;
}

typedef bool (*NetBodyFn)(void* ctx, const uint8_t* data, size_t n);

/// GET url over HTTPS (the compiled-in Mozilla root bundle), streaming the
/// body to fn in NET_IO_BUF pieces. False (with an error in words) on any
/// failure, a non-200 answer, more than max_bytes, or the deadline.
static bool net_http_get(const char* job, const char* url, NetBodyFn fn, void* ctx,
                         uint32_t max_bytes, uint32_t deadline_ms) {
  esp_http_client_config_t cfg = {};
  cfg.url = url;
  cfg.timeout_ms = 8000;
  cfg.crt_bundle_attach = esp_crt_bundle_attach;
  cfg.user_agent = NET_USER_AGENT;
  cfg.buffer_size = 1536;      // response headers (the FAA's Set-Cookie echoes the URL)
  cfg.buffer_size_tx = 768;
  cfg.disable_auto_redirect = true;
  s_nf.http_status = 0;        // before any early return: a failed init is not last time's 429
  s_nf.retry_after_s = 0;
  esp_http_client_handle_t c = esp_http_client_init(&cfg);
  if (!c) { net_fetch_err(job, "no memory"); return false; }
  bool ok = false;
  uint32_t t0 = millis();
  esp_err_t e = esp_http_client_open(c, 0);
  if (e != ESP_OK) {
    net_fetch_err(job, "connect failed (%s)", esp_err_to_name(e));
  } else {
    int64_t len = esp_http_client_fetch_headers(c);
    int status = esp_http_client_get_status_code(c);
    s_nf.http_status = status;
    if (!s_nf.res.heap_tls) s_nf.res.heap_tls = (uint32_t)heap_caps_get_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    if (status == 429) {   // too many requests: the server says how long to wait
      char* ra = nullptr;
      if (esp_http_client_get_header(c, "Retry-After", &ra) == ESP_OK && ra) s_nf.retry_after_s = net_retry_after_s(ra);
      net_fetch_err(job, "HTTP 429");
    } else if (status != 200) {
      net_fetch_err(job, "HTTP %d", status);
    } else if (len > (int64_t)max_bytes) {
      net_fetch_err(job, "answer too large");
    } else {
      uint32_t total = 0;
      for (;;) {
        if (s_nf.cancel) { net_fetch_err(job, "cancelled"); break; }
        if (millis() - t0 > deadline_ms) { net_fetch_err(job, "timed out"); break; }
        int r = esp_http_client_read(c, (char*)s_nf.io, NET_IO_BUF);
        if (r < 0) { net_fetch_err(job, "read failed"); break; }
        if (r == 0) {
          ok = esp_http_client_is_complete_data_received(c) ||
               (len < 0 && !esp_http_client_is_chunked_response(c));
          if (!ok) net_fetch_err(job, "answer cut short");
          break;
        }
        total += (uint32_t)r;
        if (total > max_bytes) { net_fetch_err(job, "answer too large"); break; }
        if (!fn(ctx, s_nf.io, (size_t)r)) { net_fetch_err(job, "bad data"); break; }
      }
    }
  }
  esp_http_client_close(c);
  esp_http_client_cleanup(c);
  return ok;
}

static bool net_split_sink(void* ctx, const uint8_t* data, size_t n) {
  net_split_feed((NetJsonSplit*)ctx, (const char*)data, n);
  return true;
}

// -- TIME

static bool net_sntp_query(const char* host, uint32_t* utc, uint32_t* at_ms) {
  struct addrinfo hints;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_DGRAM;
  struct addrinfo* ai = nullptr;
  if (getaddrinfo(host, "123", &hints, &ai) != 0 || !ai) return false;
  bool ok = false;
  int s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
  if (s >= 0) {
    struct timeval tv = { 2, 0 };
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    uint8_t pkt[48], in[68];
    uint32_t txs = esp_random(), txf = esp_random();
    net_ntp_request(pkt, txs, txf);
    uint32_t t0 = millis();
    if (sendto(s, pkt, sizeof(pkt), 0, ai->ai_addr, ai->ai_addrlen) == (int)sizeof(pkt)) {
      while (!ok && millis() - t0 < 2500 && !s_nf.cancel) {
        int n = recv(s, in, sizeof(in), 0);
        if (n <= 0) break;
        uint16_t ms = 0;
        if (net_ntp_parse(in, (size_t)n, txs, txf, utc, &ms)) {
          uint32_t rtt = millis() - t0;
          *at_ms = millis() - ms - rtt / 2;   // *utc was true this long ago
          ok = true;
        }
      }
    }
    close(s);
  }
  freeaddrinfo(ai);
  return ok;
}

static void net_job_time() {
  uint32_t utc = 0, at = 0;
  if (net_sntp_query("pool.ntp.org", &utc, &at) ||
      (!s_nf.cancel && net_sntp_query("time.google.com", &utc, &at))) {
    s_nf.res.utc = utc;
    s_nf.res.utc_at_ms = at;
    s_nf.res.ok |= NET_JOB_TIME;
  } else {
    net_job_stop(NET_JOB_TIME, "CLOCK");
    net_fetch_err("CLOCK", "no SNTP answer");
  }
}

// -- TFR

static void net_job_tfr() {
  if (!s_nf.home) { s_nf.res.skipped |= NET_JOB_TFR; return; }   // reported once (net_fetch_task)
  if (!net_heap_ok("TFR")) { s_nf.res.failed |= NET_JOB_TFR; return; }
  net_url_tfr(s_nf.url, NET_URL_MAX, s_nf.lat, s_nf.lon);
  NetTfrSet set;
  memset(&set, 0, sizeof(set));
  set.poly = s_nf.tfr;
  set.dist = s_nf.tfr_d;
  set.cap = TFR_MAX;
  set.max_pts = TFR_PTS_MAX;
  set.lat = s_nf.lat;
  set.lon = s_nf.lon;
  set.radius_m = NET_TFR_RADIUS_KM * 1000.0;
  set.ring = s_nf.ring;
  NetJsonSplit sp;
  net_split_init(&sp, "features", s_nf.obj, NET_OBJ_BUF, net_tfr_on_obj, &set);
  bool ok = net_http_get("TFR", s_nf.url, net_split_sink, &sp, 1024u * 1024u, 30000);
  if (ok && !sp.complete) { ok = false; net_fetch_err("TFR", "unexpected answer"); }
  if (!ok) { net_job_stop(NET_JOB_TFR, "TFR"); net_job_rate_limited(NET_JOB_TFR); return; }
  s_nf.tfr_n = set.n;
  s_nf.tfr_ok = true;
  s_nf.res.tfr_n = (uint16_t)set.n;
  s_nf.res.ok |= NET_JOB_TFR;
}

// -- ADS-B

static void net_job_adsb() {
  if (!s_nf.home) { s_nf.res.skipped |= NET_JOB_ADSB; return; }
  if (!net_heap_ok("ADS-B")) { s_nf.res.failed |= NET_JOB_ADSB; return; }
  const NetArea* a = &s_nf.adsb;
  s_nf.res.adsb_lat = a->lat;
  s_nf.res.adsb_lon = a->lon;
  s_nf.res.adsb_radius_m = a->radius_m;
  net_url_adsb(s_nf.url, NET_URL_MAX, a->lat, a->lon, a->radius_m);
  NetAdsbSet set;
  memset(&set, 0, sizeof(set));
  set.ac = s_nf.ac;
  set.dist = s_nf.ac_d;
  set.cap = NET_ADSB_STAGE;
  set.lat = a->lat;
  set.lon = a->lon;
  set.max_m = a->radius_m;   // the answer's NM rounding asks a little wider: trim it
  set.now_ms = millis();
  NetJsonSplit sp;
  net_split_init(&sp, "ac", s_nf.obj, NET_OBJ_BUF, net_adsb_on_obj, &set);
  bool ok = net_http_get("ADS-B", s_nf.url, net_split_sink, &sp, 512u * 1024u, 15000);
  if (ok && !sp.complete) { ok = false; net_fetch_err("ADS-B", "unexpected answer"); }
  if (!ok) { net_job_stop(NET_JOB_ADSB, "ADS-B"); net_job_rate_limited(NET_JOB_ADSB); return; }
  s_nf.ac_n = set.n;
  s_nf.ac_ms = set.now_ms;
  s_nf.ac_ok = true;
  s_nf.res.ac_n = (uint16_t)set.n;
  s_nf.res.ok |= NET_JOB_ADSB;
}

// -- TILES

typedef struct {
  File     f;
  uint32_t n;
  bool     jpeg;       // the first bytes were a JPEG's (FF D8 FF)
  uint8_t  head[3];
} NetTileSink;

// Tiles must be JPEG: anything else (an error page, a placeholder PNG) is
// refused at its first bytes and never stored.
static bool net_tile_sink(void* ctx, const uint8_t* data, size_t n) {
  NetTileSink* t = (NetTileSink*)ctx;
  for (size_t i = 0; i < n && t->n + i < sizeof(t->head); i++) t->head[t->n + i] = data[i];
  if (t->n + n >= sizeof(t->head) && !t->jpeg) {
    if (tile_sniff(t->head, sizeof(t->head)) != TILE_FMT_JPEG) return false;
    t->jpeg = true;
  }
  if (t->f.write(data, n) != n) return false;
  t->n += (uint32_t)n;
  return true;
}

// tile_plan.h's filesystem and network, on LittleFS and HTTPS.
static uint64_t net_tile_free(void*) {
  uint64_t t = LittleFS.totalBytes(), u = LittleFS.usedBytes();
  return t > u ? t - u : 0;
}
static int net_tile_fetch(void*, int z, int32_t x, int32_t y, uint32_t* bytes) {
  char path[TILE_PATH_MAX];
  snprintf(path, sizeof(path), "/tiles/%d/%ld/%ld.jpg", z, (long)x, (long)y);
  if (!tile_path_ok(path)) return 0;
  if (!net_heap_ok("MAP")) return -1;
  uint32_t since = millis() - s_nf.tile_last_ms;
  if (s_nf.tile_last_ms && since < NET_TILE_GAP_MS) vTaskDelay(pdMS_TO_TICKS(NET_TILE_GAP_MS - since));
  s_nf.tile_last_ms = millis();
  net_url_tile(s_nf.url, NET_URL_MAX, z, x, y);
  NetTileSink t;
  t.f = LittleFS.open(NET_TILE_TMP, "w");
  t.n = 0;
  t.jpeg = false;
  if (!t.f) { net_fetch_err("MAP", "cannot write"); return -1; }
  bool ok = net_http_get("MAP", s_nf.url, net_tile_sink, &t, NET_TILE_MAX_BYTES, 20000);
  t.f.close();
  // Only a whole JPEG is renamed into place: a cancelled or cut download
  // leaves nothing but the temp file, removed here.
  if (ok && t.jpeg) {
    ts_mkdirs(path);
    ok = LittleFS.rename(NET_TILE_TMP, path);
  }
  if (!ok || !t.jpeg) {
    LittleFS.remove(NET_TILE_TMP);
    if (s_nf.http_status == 429) {   // stop now, hold the job (rate limited is also failed)
      net_job_stop(NET_JOB_TILES, "MAP");
      net_job_rate_limited(NET_JOB_TILES);
      return -1;
    }
    return 0;
  }
  *bytes = t.n;
  return 1;
}
static bool net_tile_remove(void*, uint64_t key) {
  int z;
  int32_t x, y;
  tile_key_split(key, &z, &x, &y);
  char path[TILE_PATH_MAX];
  for (int k = 0; k < 2; k++) {   // a key is a tile, whichever format holds it
    snprintf(path, sizeof(path), "/tiles/%d/%ld/%ld.%s", z, (long)x, (long)y, k ? "png" : "jpg");
    if (tile_path_ok(path) && LittleFS.exists(path)) {
      ts_remove_pruned(path);
      return true;
    }
  }
  return false;
}
static bool net_tile_cancelled(void*) { return s_nf.cancel; }
static void net_tile_progress(void*, uint32_t done, uint32_t total) {
  g_net_tiles_done = (uint16_t)(done > 0xFFFF ? 0xFFFF : done);
  g_net_tiles_total = (uint16_t)(total > 0xFFFF ? 0xFFFF : total);
}

static void net_job_tiles() {
  if (!s_nf.home) { s_nf.res.skipped |= NET_JOB_TILES; return; }
  if (tile_store_busy(millis())) { s_nf.res.skipped |= NET_JOB_TILES; net_fetch_err("MAP", "app tile sync running"); return; }
  LittleFS.remove(NET_TILE_TMP);   // a leftover from a reset mid-download
  ts_mkdirs(NET_TILE_TMP);         // /tiles itself, on a board that never had a map
  // Plan first: what is on flash, what the circle needs, whether it fits
  // (tile_plan.h shrinks z15, then z14... until it does). Listing and
  // planning take seconds on a big store: a cancel is checked after each.
  uint64_t tb = 0;
  uint32_t n = ts_tiles_list(s_nf.disk, NET_TILE_DISK_MAX, &tb);
  if (s_nf.cancel) { net_job_stop(NET_JOB_TILES, "MAP"); return; }
  TilePlan* p = &s_nf.res.plan;
  tile_plan_make(p, s_nf.lat, s_nf.lon, s_nf.req.tile_radius_m, LittleFS.totalBytes(), LittleFS.usedBytes(),
                 s_nf.disk, n);
  s_nf.res.have_plan = true;
  if (s_nf.cancel) { net_job_stop(NET_JOB_TILES, "MAP"); return; }
  s_nf.res.tile_max_m = tile_plan_max_radius_m(s_nf.lat, s_nf.lon, p->capacity, p->avg_bytes);
  g_net_tiles_total = (uint16_t)(p->total > 0xFFFF ? 0xFFFF : p->total);
  g_net_tiles_done = 0;
  g_net_tiles_running = true;
  TileSyncOps ops = { nullptr, net_tile_free, net_tile_fetch, net_tile_remove, net_tile_cancelled, net_tile_progress };
  TileSyncResult r;
  s_nf.tile_last_ms = 0;
  tile_sync_run(p, s_nf.disk, n, s_nf.req.tile_budget, &ops, s_nf.victims, NET_TILE_DISK_MAX, &r);
  s_nf.res.tiles_new = (uint16_t)(r.fetched > 0xFFFF ? 0xFFFF : r.fetched);
  s_nf.res.tiles_left = (uint16_t)(r.left > 0xFFFF ? 0xFFFF : r.left);
  s_nf.res.storage_full = r.storage_full;
  if (r.storage_full) net_fetch_err("MAP", "storage full (1 MB kept free)");
  // Cut short by a cancel: not done, whatever it fetched first (tiles says how many).
  if (r.cancelled) net_job_stop(NET_JOB_TILES, "MAP");
  else if (r.stopped) net_fetch_err("MAP", "download failed");
  if (r.cancelled) return;
  if ((r.stopped && r.fetched == 0) || (r.storage_full && r.fetched == 0)) s_nf.res.failed |= NET_JOB_TILES;
  else s_nf.res.ok |= NET_JOB_TILES;
}

// -- the worker and the ops

static void net_fetch_task(void*) {
  uint32_t j = s_nf.req.jobs;
  // Home from GPS, the app, or the one saved in NVS (rx_core home_load):
  // without any, TFR, ADS-B and tiles are skipped and said so once.
  if (!s_nf.home && (j & (NET_JOB_TFR | NET_JOB_ADSB | NET_JOB_TILES))) {
    s_nf.res.no_position = true;
    snprintf(s_nf.res.err, sizeof(s_nf.res.err), "%s", NET_NO_POSITION_TEXT);
  }
  if ((j & NET_JOB_TIME) && !s_nf.cancel) net_job_time();
  if ((j & NET_JOB_TFR) && !s_nf.cancel) net_job_tfr();
  if ((j & NET_JOB_ADSB) && !s_nf.cancel) net_job_adsb();
  if ((j & NET_JOB_TILES) && !s_nf.cancel) net_job_tiles();
  // Jobs never reached (a cancel) did not fail: they were not run.
  uint32_t seen = s_nf.res.ok | s_nf.res.failed | s_nf.res.skipped | s_nf.res.cancelled;
  if (j & ~seen) { s_nf.res.cancelled |= j & ~seen; net_fetch_err("SYNC", "cancelled"); }
  // No TLS ran (or it never got that far): still report the headroom.
  if (!s_nf.res.heap_free) {
    s_nf.res.heap_free = (uint32_t)heap_caps_get_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    s_nf.res.heap_block = (uint32_t)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
  }
  s_nf.done = true;
  vTaskSuspend(nullptr);   // jobs_poll deletes this task
}

static bool net_fetch_alloc() {
  if (!s_nf.ac) s_nf.ac = ext_new<TrafficAircraft>(NET_ADSB_STAGE);
  if (!s_nf.ac_d) s_nf.ac_d = ext_new<double>(NET_ADSB_STAGE);
  if (!s_nf.tfr) s_nf.tfr = ext_new<NetPoly>(TFR_MAX);
  if (!s_nf.tfr_d) s_nf.tfr_d = ext_new<double>(TFR_MAX);
  if (!s_nf.ring) s_nf.ring = ext_new<NetRing>();
  if (!s_nf.obj) s_nf.obj = (char*)ext_calloc(NET_OBJ_BUF);
  if (!s_nf.io) s_nf.io = (uint8_t*)ext_calloc(NET_IO_BUF);
  if (!s_nf.url) s_nf.url = (char*)ext_calloc(NET_URL_MAX);
  if (!s_nf.disk) s_nf.disk = ext_new<TileOnDisk>(NET_TILE_DISK_MAX);
  if (!s_nf.victims) s_nf.victims = ext_new<uint32_t>(NET_TILE_DISK_MAX);
  return s_nf.ac && s_nf.ac_d && s_nf.tfr && s_nf.tfr_d && s_nf.ring && s_nf.obj && s_nf.io && s_nf.url &&
         s_nf.disk && s_nf.victims;
}

static bool net_fetch_start(const NetJobReq* req) {
  if (s_nf.task || !net_fetch_alloc()) return false;
  RX_LOCK();
  s_nf.home = g_home_set;
  s_nf.lat = g_home_lat;
  s_nf.lon = g_home_lon;
  RX_UNLOCK();
  // ADS-B: around home, or widened around live drones far from it. The
  // screen's copy of the track table is the loop's own (this is the loop).
  double dlat[NET_DRONES_MAX], dlon[NET_DRONES_MAX];
  int nd = 0;
  uint32_t now = millis();
  for (int i = 0; i < TRK_MAX && nd < NET_DRONES_MAX; i++) {
    const Track* t = &g_tracks[i];
    if (!t->used || !t->has_pos || (int32_t)(now - t->last_ms) > 60000) continue;
    if (!(fabs(t->lat) <= 90 && fabs(t->lon) <= 180)) continue;
    dlat[nd] = t->lat;
    dlon[nd] = t->lon;
    nd++;
  }
  s_nf.adsb = net_adsb_area(s_nf.lat, s_nf.lon, dlat, dlon, nd, req->adsb_radius_m, NET_ADSB_KM_MAX * 1000.0);
  memset(&s_nf.res, 0, sizeof(s_nf.res));
  s_nf.req = *req;
  s_nf.done = false;
  s_nf.cancel = false;
  s_nf.ac_ok = s_nf.tfr_ok = false;
  s_nf.ac_n = s_nf.tfr_n = 0;
  // Tiles write flash: that needs a stack in internal RAM. The rest runs on
  // a PSRAM stack, leaving the internal heap to mbedTLS.
  s_nf.psram_stack = NET_FETCH_STACK_PSRAM && !(req->jobs & NET_JOB_TILES);
  BaseType_t ok = pdFAIL;
  if (s_nf.psram_stack && ext_ram_is_psram())
    ok = xTaskCreatePinnedToCoreWithCaps(net_fetch_task, "net_fetch", NET_FETCH_STACK, nullptr, 1, &s_nf.task, 1,
                                         MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  if (ok != pdPASS) {
    s_nf.psram_stack = false;
    ok = xTaskCreatePinnedToCore(net_fetch_task, "net_fetch", NET_FETCH_STACK, nullptr, 1, &s_nf.task, 1);
  }
  if (ok != pdPASS) { s_nf.task = nullptr; return false; }
  return true;
}

// Loop task: when the worker is done, install what it fetched.
static bool net_fetch_poll(NetJobResult* out) {
  if (!s_nf.task || !s_nf.done) return false;
  uint32_t now = millis();
  if (s_nf.tfr_ok) {
    RX_LOCK();
    for (int i = 0; i < s_nf.tfr_n; i++) {
      TfrPoly* d = &s_tfrs[i];
      const NetPoly* p = &s_nf.tfr[i];
      int n = p->n > TFR_PTS_MAX ? TFR_PTS_MAX : p->n;
      d->n = (uint8_t)n;
      memcpy(d->lat, p->lat, sizeof(float) * (size_t)n);
      memcpy(d->lon, p->lon, sizeof(float) * (size_t)n);
      snprintf(d->id, sizeof(d->id), "%s", p->id);
    }
    g_tfr_n = (uint8_t)s_nf.tfr_n;
    g_tfr_loaded = true;
    g_tfr_ms = now;
    RX_UNLOCK();
  }
  if (s_nf.ac_ok) traffic_ingest(s_nf.ac, s_nf.ac_n, s_nf.ac_ms, now);
  if (s_nf.psram_stack) vTaskDeleteWithCaps(s_nf.task);
  else vTaskDelete(s_nf.task);
  s_nf.task = nullptr;
  g_net_tiles_running = false;
  *out = s_nf.res;
  return true;
}

static void net_fetch_cancel() { s_nf.cancel = true; }

static bool net_fetch_have_position() {
  RX_LOCK();
  bool h = g_home_set;
  RX_UNLOCK();
  return h;
}

/// The job ops for net_sync.h.
static inline void net_fetch_ops(NetOps* o) {
  o->jobs_start = net_fetch_start;
  o->jobs_poll = net_fetch_poll;
  o->jobs_cancel = net_fetch_cancel;
  o->have_position = net_fetch_have_position;
}

#endif  // ESP_PLATFORM
