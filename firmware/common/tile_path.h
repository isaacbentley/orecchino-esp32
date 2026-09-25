// What the tile store accepts from a host, kept free of LittleFS and mbedTLS
// so the host tests can pin it. The fs_* commands arrive over USB and BLE,
// so a path is a filesystem write/remove request from outside: it must
// never leave /tiles.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <stdint.h>
#include <stddef.h>
#include <string.h>

#define TILE_PATH_MAX    72            // "/tiles/22/4194303/4194303.png" is 29
#define TILE_FILE_MAX    (256u * 1024u) // a 256 px PNG is ~5-40 KB; refuse anything absurd
#define TILE_JPEG_MAX    (64u * 1024u)  // a JPEG past this cannot be decoded on the boards and
                                       // leaves an undrawable hole (the T5's own fetch caps the
                                       // same: net_fetch.h NET_TILE_MAX_BYTES)
#define TILE_FS_MARGIN   16384u        // block granularity + metadata
#define TILE_SOURCE_MARK "/tiles/.src"  // the basemap mark (below): never removed by a host

/// n decimal digits (1..max) at *p; advances p past them.
static inline bool tile_digits(const char** p, int max) {
  int n = 0;
  while (**p >= '0' && **p <= '9') { (*p)++; n++; }
  return n >= 1 && n <= max;
}

/// Exactly "/tiles/<z>/<x>/<y>.jpg" or ".png", all numbers decimal: what
/// fs_begin may create. z is at most 2 digits, x and y at most 7 (zoom 22
/// is 4194303 at most). JPEG is the basemap now (Esri World Dark Gray);
/// PNG stays for the SenseCAP's bundled CARTO pack.
static inline bool tile_path_ok(const char* path) {
  if (!path || strlen(path) >= TILE_PATH_MAX || strncmp(path, "/tiles/", 7) != 0) return false;
  const char* p = path + 7;
  if (!tile_digits(&p, 2) || *p++ != '/') return false;
  if (!tile_digits(&p, 7) || *p++ != '/') return false;
  if (!tile_digits(&p, 7)) return false;
  return strcmp(p, ".jpg") == 0 || strcmp(p, ".png") == 0;
}

/// What fs_rm may remove: anything inside /tiles, so the host can prune a
/// stray file (a .DS_Store packed by an old image) it saw in fs_ls, but
/// never a path that climbs out: plain names only, no "." or ".." parts,
/// no empty parts. Nor the basemap mark: without it the T5 wipes every tile
/// at its next boot (tile_store_check_source).
static inline bool tile_rm_path_ok(const char* path) {
  if (!path || strlen(path) >= TILE_PATH_MAX || strncmp(path, "/tiles/", 7) != 0) return false;
  if (strcmp(path, TILE_SOURCE_MARK) == 0) return false;
  const char* part = path + 7;
  for (const char* p = part;; p++) {
    char c = *p;
    if (c == '/' || c == 0) {
      size_t len = (size_t)(p - part);
      if (len == 0) return false;
      if (len == 1 && part[0] == '.') return false;
      if (len == 2 && part[0] == '.' && part[1] == '.') return false;
      if (c == 0) return true;
      part = p + 1;
    } else if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                 c == '.' || c == '_' || c == '-')) {
      return false;
    }
  }
}

/// The most a file at `path` may hold: TILE_JPEG_MAX for a .jpg tile, else
/// TILE_FILE_MAX.
static inline uint64_t tile_file_max(const char* path) {
  size_t n = path ? strlen(path) : 0;
  return n >= 4 && strcmp(path + n - 4, ".jpg") == 0 ? TILE_JPEG_MAX : TILE_FILE_MAX;
}

/// Bytes an fs_begin must find free before writing a file of `size`, or 0
/// when the file is refused outright (too big for its kind, or larger than
/// the whole filesystem: evicting everything would still not fit it).
static inline uint64_t tile_bytes_needed(uint64_t size, uint64_t fs_total, uint64_t max = TILE_FILE_MAX) {
  if (size == 0 || size > max) return 0;
  uint64_t need = size + TILE_FS_MARGIN;
  return need <= fs_total ? need : 0;
}

// ---------------------------------------------------------------------------
// The basemap and its marker.
//
// Tiles come from Esri's World Dark Gray Canvas (no key): JPEG base tiles,
// fetched as z/y/x (note the order) and stored as /tiles/z/x/y.jpg. CARTO's
// dark_all now answers every tile without an API key with a 200 OK "API KEY
// REQUIRED" placeholder PNG, so .png tiles a T5 fetched itself are junk:
// the T5 wipes /tiles once when TILE_SOURCE_MARK does not hold
// TILE_SOURCE_ID (tile_store_check_source). The SenseCAP's bundled .png
// pack is genuine and is never wiped.
#define TILE_SOURCE_ID    "esri-dg1"
#define TILE_BASE_URL     "https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Dark_Gray_Base/MapServer/tile/%d/%d/%d"   // z, y, x
#define TILE_ATTRIBUTION  "Esri, HERE, Garmin, (c) OpenStreetMap contributors"

enum { TILE_FMT_NONE = 0, TILE_FMT_JPEG = 1, TILE_FMT_PNG = 2 };

/// What the first bytes of a tile say it is: JPEG (FF D8 FF), PNG (the
/// 8-byte signature), or neither (an HTML/XML error page, a truncated file).
static inline int tile_sniff(const uint8_t* b, size_t n) {
  static const uint8_t png[8] = { 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
  if (n >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return TILE_FMT_JPEG;
  if (n >= 8 && memcmp(b, png, 8) == 0) return TILE_FMT_PNG;
  return TILE_FMT_NONE;
}
