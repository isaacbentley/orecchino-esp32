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
#define TILE_FS_MARGIN   16384u        // block granularity + metadata

/// n decimal digits (1..max) at *p; advances p past them.
static inline bool tile_digits(const char** p, int max) {
  int n = 0;
  while (**p >= '0' && **p <= '9') { (*p)++; n++; }
  return n >= 1 && n <= max;
}

/// Exactly "/tiles/<z>/<x>/<y>.png", all numbers decimal: what fs_begin
/// may create. z is at most 2 digits, x and y at most 7 (zoom 22 is
/// 4194303 at most).
static inline bool tile_path_ok(const char* path) {
  if (!path || strlen(path) >= TILE_PATH_MAX || strncmp(path, "/tiles/", 7) != 0) return false;
  const char* p = path + 7;
  if (!tile_digits(&p, 2) || *p++ != '/') return false;
  if (!tile_digits(&p, 7) || *p++ != '/') return false;
  if (!tile_digits(&p, 7)) return false;
  return strcmp(p, ".png") == 0;
}

/// What fs_rm may remove: anything inside /tiles, so the host can prune a
/// stray file (a .DS_Store packed by an old image) it saw in fs_ls, but
/// never a path that climbs out: plain names only, no "." or ".." parts,
/// no empty parts.
static inline bool tile_rm_path_ok(const char* path) {
  if (!path || strlen(path) >= TILE_PATH_MAX || strncmp(path, "/tiles/", 7) != 0) return false;
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

/// Bytes an fs_begin must find free before writing a file of `size`, or 0
/// when the file is refused outright (too big, or larger than the whole
/// filesystem: evicting everything would still not fit it).
static inline uint64_t tile_bytes_needed(uint64_t size, uint64_t fs_total) {
  if (size == 0 || size > TILE_FILE_MAX) return 0;
  uint64_t need = size + TILE_FS_MARGIN;
  return need <= fs_total ? need : 0;
}
