// NMEA from the T5's GPS, parsed into what the board may apply: a fix only
// when the receiver says it has one (GGA quality > 0, RMC status A), and
// the time and date only from a sentence that carries a fix. A module still
// searching keeps sending sentences with a placeholder date
// ("$GPRMC,000000.00,V,,,,,,,060180,,,N*..": 6 January 1980, read as 2080
// by a two-digit year), which would otherwise set the clock every second
// and override SNTP. Pure functions on plain C strings, so
// tests/t5_gps_test.cpp checks them on the host.
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <ctype.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct NmeaMsg {
  char   kind[4];      // "GGA", "RMC", or the other three letters
  bool   fix;          // the receiver reports a fix and a usable position
  int    quality;      // GGA fix quality (0 none)
  int    sats;         // GGA satellites in use
  double lat, lon;     // NAN without a fix
  bool   has_elev;     // GGA with a fix and an altitude
  float  elev_m;       // height above the WGS-84 ellipsoid (MSL + geoid separation)
  bool   has_time;     // UTC time of day, only with a fix
  int    h, mi, s;
  bool   has_date;     // RMC date, only with a fix
  int    d, mo, yr;
};

/// A sentence starting "$", with its checksum right when it has one.
static inline bool nmea_valid(const char* s) {
  if (!s || s[0] != '$' || strlen(s) < 9) return false;
  const char* star = strchr(s, '*');
  if (star) {
    if (!star[1] || !star[2]) return false;   // a cut checksum: the sentence is cut too
    uint8_t csum = 0;
    for (const char* p = s + 1; p < star; p++) csum ^= (uint8_t)*p;
    char hex[3];
    snprintf(hex, sizeof(hex), "%02X", csum);
    return (toupper((unsigned char)star[1]) == hex[0] && toupper((unsigned char)star[2]) == hex[1]);
  }
  return (strncmp(s + 3, "GGA", 3) == 0 || strncmp(s + 3, "RMC", 3) == 0 ||
          strncmp(s + 3, "GSA", 3) == 0 || strncmp(s + 3, "GSV", 3) == 0);
}

/// "3748.2345" + "N" -> 37.80; NAN for an empty field.
static inline double nmea_coord(const char* f, const char* hemi) {
  if (!f[0]) return NAN;
  double v = atof(f);
  int deg = (int)(v / 100);
  double m = v - deg * 100;
  double d = deg + m / 60.0;
  if (hemi[0] == 'S' || hemi[0] == 'W') d = -d;
  return d;
}

static inline bool nmea_two(const char* p, int* out) {
  if (!isdigit((unsigned char)p[0]) || !isdigit((unsigned char)p[1])) return false;
  *out = (p[0] - '0') * 10 + (p[1] - '0');
  return true;
}

/// Parse one sentence. False when it is not valid NMEA. The fix, time and
/// date fields are set only when the sentence vouches for them.
static inline bool nmea_parse(const char* s, NmeaMsg* m) {
  memset(m, 0, sizeof(*m));
  m->lat = m->lon = NAN; m->elev_m = NAN;
  if (!nmea_valid(s)) return false;
  memcpy(m->kind, s + 3, 3); m->kind[3] = 0;

  char f[16][16] = {{0}};
  int fi = 0, fc = 0;
  for (const char* p = s; *p && fi < 16; p++) {
    if (*p == ',' || *p == '*') { f[fi][fc] = 0; fi++; fc = 0; if (*p == '*') break; }
    else if (fc < 15) f[fi][fc++] = *p;
  }
  bool gga = !strcmp(m->kind, "GGA"), rmc = !strcmp(m->kind, "RMC");
  if (!gga && !rmc) return true;

  // The receiver's own word on whether it has a fix.
  bool claims = gga ? atoi(f[6]) > 0 : f[2][0] == 'A';
  if (gga) { m->quality = atoi(f[6]); m->sats = atoi(f[7]); }
  if (claims) {
    double lat = gga ? nmea_coord(f[2], f[3]) : nmea_coord(f[3], f[4]);
    double lon = gga ? nmea_coord(f[4], f[5]) : nmea_coord(f[5], f[6]);
    if (!isnan(lat) && !isnan(lon) && (lat != 0 || lon != 0)) { m->fix = true; m->lat = lat; m->lon = lon; }
  }
  if (!m->fix) return true;   // no fix: no position, no time, no date
  if (gga) {
    // f[9] altitude above MSL, f[11] geoid separation (both metres).
    if (f[9][0] && f[11][0]) { m->has_elev = true; m->elev_m = (float)(atof(f[9]) + atof(f[11])); }
    else if (f[9][0]) { m->has_elev = true; m->elev_m = (float)atof(f[9]); }   // MSL: well inside the rules' margins
  }
  if (strlen(f[1]) >= 6 && nmea_two(f[1], &m->h) && nmea_two(f[1] + 2, &m->mi) && nmea_two(f[1] + 4, &m->s))
    m->has_time = true;
  if (rmc && strlen(f[9]) >= 6) {
    int yy;
    if (nmea_two(f[9], &m->d) && nmea_two(f[9] + 2, &m->mo) && nmea_two(f[9] + 4, &yy)) { m->yr = 2000 + yy; m->has_date = true; }
  }
  return true;
}

/// A year the clock may be set to: from 2024 (this project's first
/// release) to twenty years past the firmware's build, which catches the
/// placeholder dates a receiver invents (1980 read as 2080, or 2000)
/// without a board running old firmware refusing the real date.
static inline bool nmea_year_plausible(int yr, int build_year) {
  return yr >= 2024 && yr <= build_year + 20;
}
