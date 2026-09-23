// Offline map tile store, shared by every board with a map view.
//
// Orecchino.app pushes CARTO raster tiles over the same serial line the JSON
// feed uses: base64 chunks in JSON lines, acked one at a time, CRC32 per
// file, writes confined to /tiles on LittleFS. The store manages its own
// space — when a write needs room it drops the least valuable tile (highest
// zoom first, then farthest from where the map is looking) and the renderer
// tolerates the hole. Header-only; the sketch's rx_hook_host_line() hands
// "fs_*" commands to tile_store_host_line(), which answers the host that
// sent them (USB or BLE). Paths are checked by tile_path.h: nothing is
// written or removed outside /tiles.
#pragma once
#include <Arduino.h>
#include <LittleFS.h>
#include "host_link.h"
#include "ext_ram.h"
#include "tile_path.h"
#include "mbedtls/base64.h"
#include "esp_rom_crc.h"

/// Where the map is looking, for eviction scoring. Return false if unknown.
typedef bool (*TileCenterFn)(double* lat, double* lon);
static TileCenterFn s_ts_center_fn = nullptr;
static File     s_ts_file;
static uint32_t s_ts_crc = 0;
static uint32_t s_ts_last_ms = 0;
static uint32_t s_ts_files_done = 0;
static uint32_t s_ts_left = 0;          // bytes the open file may still take

static inline void tile_store_begin(TileCenterFn center) {
  // Format-on-fail: a virgin device self-provisions — the app's tile sync
  // fills an empty filesystem, no esptool image needed.
  LittleFS.begin(true, "/littlefs", 10, "littlefs");
  s_ts_center_fn = center;
}
/// True while a sync is in progress (a map should show progress, not a
/// half-written frame).
static inline bool tile_store_busy(uint32_t now) { return now - s_ts_last_ms < 2000; }
static inline uint32_t tile_store_files_done() { return s_ts_files_done; }
static inline void tile_store_reset_count() { s_ts_files_done = 0; }

static inline void ts_world_px(double lat, double lon, int z, double* wx, double* wy) {
  double n = 256.0 * (double)(1L << z);
  *wx = (lon + 180.0) / 360.0 * n;
  double rad = lat * M_PI / 180.0;
  *wy = (1.0 - log(tan(rad) + 1.0 / cos(rad)) / M_PI) / 2.0 * n;
}

/// Remove one tile, then its /tiles/z/x and /tiles/z directories if that
/// left them empty.
static inline void ts_remove_pruned(const char* victim) {
  LittleFS.remove(victim);
  // Prune empty parent directory /tiles/z/x and /tiles/z
  char parent[TILE_PATH_MAX];
  strncpy(parent, victim, sizeof(parent) - 1);
  parent[sizeof(parent) - 1] = 0;
  char* slash = strrchr(parent, '/');
  if (slash && slash != parent) {
    *slash = '\0';
    LittleFS.rmdir(parent);
    char* z_slash = strrchr(parent, '/');
    if (z_slash && z_slash != parent) {
      *z_slash = '\0';
      LittleFS.rmdir(parent);
    }
  }
}

/// Drop the least valuable tiles -- highest zoom first, then farthest from
/// where the map is looking -- until `needed` bytes are free. One tree walk
/// collects the TS_VICTIMS worst, so a big file does not cost a walk per
/// tile removed. False when the store has nothing left to drop.
#define TS_VICTIMS 8
static inline bool ts_evict(uint64_t needed) {
  while (LittleFS.totalBytes() - LittleFS.usedBytes() < needed) {
    double clat, clon;
    bool has_center = s_ts_center_fn && s_ts_center_fn(&clat, &clon);
    char victim[TS_VICTIMS][TILE_PATH_MAX];
    double score_of[TS_VICTIMS];
    int nv = 0;
    File root = LittleFS.open("/tiles");
    if (!root) return false;
    for (File zd = root.openNextFile(); zd; zd = root.openNextFile()) {
      if (!zd.isDirectory()) continue;
      int z = atoi(zd.name());
      double cwx = 0, cwy = 0;
      if (has_center) ts_world_px(clat, clon, z, &cwx, &cwy);
      for (File xd = zd.openNextFile(); xd; xd = zd.openNextFile()) {
        if (!xd.isDirectory()) continue;
        long x = atol(xd.name());
        for (File f = xd.openNextFile(); f; f = xd.openNextFile()) {
          if (f.isDirectory()) continue;
          long y = atol(f.name());
          double score = (double)z * 1e12;
          if (has_center) {
            double dx = ((double)x + 0.5) * 256 - cwx;
            double dy = ((double)y + 0.5) * 256 - cwy;
            score += dx * dx + dy * dy;
          } else {
            score += (double)x + (double)y;
          }
          // Keep the TS_VICTIMS highest scores, sorted high to low.
          if (nv == TS_VICTIMS && score <= score_of[nv - 1]) continue;
          int k = nv < TS_VICTIMS ? nv++ : TS_VICTIMS - 1;
          while (k > 0 && score_of[k - 1] < score) {
            score_of[k] = score_of[k - 1];
            memcpy(victim[k], victim[k - 1], TILE_PATH_MAX);
            k--;
          }
          score_of[k] = score;
          const char* p = f.path();
          if (p && p[0] == '/') {
            strncpy(victim[k], p, TILE_PATH_MAX - 1);
            victim[k][TILE_PATH_MAX - 1] = 0;
          } else {
            snprintf(victim[k], TILE_PATH_MAX, "/tiles/%d/%ld/%s", z, x, f.name());
          }
        }
      }
    }
    if (nv == 0) return false;
    size_t before = LittleFS.usedBytes();
    for (int k = 0; k < nv && LittleFS.totalBytes() - LittleFS.usedBytes() < needed; k++)
      ts_remove_pruned(victim[k]);
    if (LittleFS.usedBytes() >= before) return false;   // nothing would go: give up, don't spin
  }
  return true;
}

static inline bool ts_field_str(const char* line, const char* key, char* out, size_t n) {
  char pat[24];
  snprintf(pat, sizeof(pat), "\"%s\":\"", key);
  const char* p = strstr(line, pat);
  if (!p) return false;
  p += strlen(pat);
  size_t o = 0;
  while (*p && *p != '"' && o + 1 < n) out[o++] = *p++;
  out[o] = 0;
  return *p == '"';
}
static inline bool ts_field_u32(const char* line, const char* key, uint32_t* out) {
  char pat[24];
  snprintf(pat, sizeof(pat), "\"%s\":", key);
  const char* p = strstr(line, pat);
  if (!p) return false;
  *out = strtoul(p + strlen(pat), nullptr, 10);
  return true;
}
static inline void ts_mkdirs(const char* path) {
  char tmp[TILE_PATH_MAX];
  strncpy(tmp, path, sizeof(tmp) - 1);
  tmp[sizeof(tmp) - 1] = 0;
  for (char* p = tmp + 1; *p; p++) {
    if (*p == '/') { *p = 0; LittleFS.mkdir(tmp); *p = '/'; }
  }
}
static inline void ts_ls_walk(File dir, uint32_t* n, HostSrc src) {
  for (File f = dir.openNextFile(); f; f = dir.openNextFile()) {
    if (f.isDirectory()) ts_ls_walk(f, n, src);
    else {
      host_printf_to(src, "{\"type\":\"fs_f\",\"p\":\"%s\",\"s\":%u}\n", f.path(), (unsigned)f.size());
      (*n)++;
    }
  }
}

/// Handle one "fs_*" host command, replying to `src`. Returns false for
/// anything else.
static inline bool tile_store_host_line(const char* cmd, char* line, uint32_t now, HostSrc src) {
  if (strncmp(cmd, "fs_", 3) != 0) return false;
  s_ts_last_ms = now;
  if (!strcmp(cmd, "fs_ls")) {
    uint32_t n = 0;
    File root = LittleFS.open("/tiles");
    if (root) ts_ls_walk(root, &n, src);
    host_printf_to(src, "{\"type\":\"fs_ls_done\",\"n\":%u}\n", (unsigned)n);
  } else if (!strcmp(cmd, "fs_begin")) {
    char path[TILE_PATH_MAX];
    if (!ts_field_str(line, "p", path, sizeof(path)) || !tile_path_ok(path)) {
      host_print_to(src, "{\"type\":\"fs_err\",\"msg\":\"bad path\"}\n");
      return true;
    }
    if (s_ts_file) {
      // Still open: an upload that never reached fs_end. Its partial file
      // must not stay behind looking like a tile (the Wi-Fi fetch only
      // fills tiles that are missing).
      char stale[TILE_PATH_MAX];
      strncpy(stale, s_ts_file.path(), sizeof(stale) - 1);
      stale[sizeof(stale) - 1] = 0;
      s_ts_file.close();
      LittleFS.remove(stale);
    }
    uint32_t size = 0;
    ts_field_u32(line, "size", &size);
    uint64_t needed = tile_bytes_needed(size, LittleFS.totalBytes());
    if (!needed) {
      host_print_to(src, "{\"type\":\"fs_err\",\"msg\":\"bad size\"}\n");
      return true;
    }
    if (!ts_evict(needed)) {
      host_print_to(src, "{\"type\":\"fs_err\",\"msg\":\"full\"}\n");
      return true;
    }
    ts_mkdirs(path);
    s_ts_file = LittleFS.open(path, "w");
    s_ts_crc = 0;
    s_ts_left = size;
    if (!s_ts_file) {
      host_print_to(src, "{\"type\":\"fs_err\",\"msg\":\"open failed\"}\n");
      return true;
    }
    host_print_to(src, "{\"type\":\"ack\",\"q\":0}\n");
  } else if (!strcmp(cmd, "fs_data")) {
    uint32_t seq = 0;
    ts_field_u32(line, "q", &seq);
    const char* p = strstr(line, "\"b64\":\"");
    if (!s_ts_file || !p) {
      host_print_to(src, "{\"type\":\"fs_err\",\"msg\":\"no file/data\"}\n");
      return true;
    }
    p += 7;
    const char* e = strchr(p, '"');
    if (!e) return true;
    static uint8_t* raw = (uint8_t*)ext_calloc(1024);
    size_t rawlen = 0;
    if (mbedtls_base64_decode(raw, 1024, &rawlen, (const uint8_t*)p, e - p) != 0) {
      host_print_to(src, "{\"type\":\"fs_err\",\"msg\":\"b64\"}\n");
      return true;
    }
    if (rawlen > s_ts_left) {   // more than fs_begin declared (and made room for)
      char bad[TILE_PATH_MAX];
      strncpy(bad, s_ts_file.path(), sizeof(bad) - 1);
      bad[sizeof(bad) - 1] = 0;
      s_ts_file.close();
      LittleFS.remove(bad);
      host_print_to(src, "{\"type\":\"fs_err\",\"msg\":\"too long\"}\n");
      return true;
    }
    s_ts_left -= rawlen;
    s_ts_file.write(raw, rawlen);
    s_ts_crc = esp_rom_crc32_le(s_ts_crc, raw, rawlen);
    host_printf_to(src, "{\"type\":\"ack\",\"q\":%u}\n", (unsigned)seq);
  } else if (!strcmp(cmd, "fs_end")) {
    uint32_t want = 0;
    ts_field_u32(line, "crc", &want);
    if (!s_ts_file) return true;
    char path[TILE_PATH_MAX];
    strncpy(path, s_ts_file.path(), sizeof(path) - 1);
    path[sizeof(path) - 1] = 0;
    s_ts_file.close();
    if (want == s_ts_crc) {
      s_ts_files_done++;
      host_printf_to(src, "{\"type\":\"fs_ok\",\"p\":\"%s\"}\n", path);
    } else {
      LittleFS.remove(path);
      host_printf_to(src, "{\"type\":\"fs_err\",\"msg\":\"crc\",\"p\":\"%s\"}\n", path);
    }
  } else if (!strcmp(cmd, "fs_rm")) {
    char path[TILE_PATH_MAX];
    if (ts_field_str(line, "p", path, sizeof(path)) && tile_rm_path_ok(path)) {
      LittleFS.remove(path);
      host_printf_to(src, "{\"type\":\"fs_ok\",\"p\":\"%s\"}\n", path);
    } else {
      host_print_to(src, "{\"type\":\"fs_err\",\"msg\":\"bad path\"}\n");
    }
  }
  return true;
}
