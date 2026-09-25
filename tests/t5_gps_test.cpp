// The T5's NMEA parser (firmware/orecchino_t5epd/t5_nmea.h) on the host:
// a module still searching for satellites sends sentences with no fix and
// a placeholder date, and none of that may reach the position or the
// clock; a sentence with a fix gives both; a bad checksum gives nothing.
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
#include "t5_nmea.h"

static int g_fails = 0;
static void check(bool ok, const char* what) {
  printf("%s %s\n", ok ? "ok  " : "FAIL", what);
  if (!ok) g_fails++;
}
/// The sentence with its checksum filled in, so the fixtures read as the
/// module sends them.
static const char* with_sum(const char* body) {
  static char s[128];
  uint8_t c = 0;
  for (const char* p = body + 1; *p; p++) c ^= (uint8_t)*p;
  snprintf(s, sizeof(s), "%s*%02X", body, c);
  return s;
}

int main() {
  NmeaMsg m;
  // Searching: RMC status V with the 1980 placeholder date (read as 2080
  // by a two-digit year). No fix, no time, no date.
  check(nmea_parse(with_sum("$GPRMC,000000.00,V,,,,,,,060180,,,N"), &m) && !strcmp(m.kind, "RMC") &&
        !m.fix && !m.has_time && !m.has_date && isnan(m.lat),
        "RMC without a fix (V, 060180): no position, no time, no date");
  // Searching: GGA quality 0 with a time of day. No fix, no time.
  check(nmea_parse(with_sum("$GPGGA,123519.00,,,,,0,00,99.99,,,,,,"), &m) && !strcmp(m.kind, "GGA") &&
        !m.fix && !m.has_time && m.quality == 0 && m.sats == 0,
        "GGA quality 0: no position, no time");
  // A fix: RMC status A gives the position, the time and the date.
  check(nmea_parse(with_sum("$GPRMC,182430.00,A,3748.2340,N,12227.8400,W,0.12,0.00,210926,,,A"), &m) &&
        m.fix && fabs(m.lat - 37.8039) < 0.0001 && fabs(m.lon + 122.4640) < 0.0001 &&
        m.has_time && m.h == 18 && m.mi == 24 && m.s == 30 &&
        m.has_date && m.d == 21 && m.mo == 9 && m.yr == 2026,
        "RMC with a fix (A): position 37.8039,-122.4640, 18:24:30, 2026-09-21");
  // A fix: GGA quality 1 gives the position, the satellites, the height
  // above the ellipsoid (MSL + geoid separation) and the time of day, never a date.
  check(nmea_parse(with_sum("$GPGGA,182431.00,3748.2340,N,12227.8400,W,1,09,0.9,72.5,M,-31.2,M,,"), &m) &&
        m.fix && m.quality == 1 && m.sats == 9 && fabs(m.lat - 37.8039) < 0.0001 &&
        m.has_elev && fabs(m.elev_m - 41.3f) < 0.01f &&
        m.has_time && m.h == 18 && m.mi == 24 && m.s == 31 && !m.has_date,
        "GGA quality 1: position, 9 satellites, 41.3 m above the ellipsoid, 18:24:31, no date");
  // Status A but an empty position: still no fix, so no time either.
  check(nmea_parse(with_sum("$GPRMC,182430.00,A,,,,,0.12,0.00,210926,,,A"), &m) && !m.fix && !m.has_time && !m.has_date,
        "RMC status A without a position: nothing applied");
  // A corrupted sentence is not a sentence.
  check(!nmea_parse("$GPRMC,182430.00,A,3748.2340,N,12227.8400,W,0.12,0.00,210926,,,A*00", &m),
        "a wrong checksum is rejected");
  check(!nmea_parse("GPRMC,182430.00,A", &m) && !nmea_parse("", &m), "a line without '$' is rejected");
  // Other sentences are valid but carry nothing the board applies.
  check(nmea_parse(with_sum("$GPGSV,3,1,11,03,03,111,00,04,15,270,00,06,01,010,00,13,06,292,00"), &m) &&
        !strcmp(m.kind, "GSV") && !m.fix && !m.has_time, "GSV: heard, nothing applied");
  // A checksum cut short is a sentence cut short: not valid, whatever the
  // prefix says.
  check(!nmea_valid("$GPGGA,182430.00,3748.2345,N,12225.1234,W,1,08,0.9,12.3,M,,M,,*5") &&
        !nmea_valid("$GPRMC,182430.00,A,3748.2345,N,12225.1234,W,0.12,0.00,210926,,,A*"),
        "a sentence whose checksum is cut is refused");
  // The clock's year gate: the build year and twenty years after it pass
  // (a board keeps running old firmware); the placeholders (2080 from
  // 060180, 2000 from 010100) and anything before the project's first
  // release do not.
  check(nmea_year_plausible(2026, 2026) && nmea_year_plausible(2046, 2026) && nmea_year_plausible(2024, 2026),
        "years up to the build year + 20 may set the clock");
  check(!nmea_year_plausible(2080, 2026) && !nmea_year_plausible(2047, 2026) && !nmea_year_plausible(2000, 2026) &&
        !nmea_year_plausible(2023, 2026),
        "2080, 2047, 2000 and 2023 may not");

  if (g_fails) printf("%d FAILED\n", g_fails); else printf("all T5 GPS checks passed\n");
  return g_fails ? 1 : 0;
}
