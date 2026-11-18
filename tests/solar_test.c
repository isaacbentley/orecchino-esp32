#include <stdio.h>
#include <assert.h>
#include <math.h>
#include "../firmware/common/solar.h"

int main() {
  printf("Running solar calculation tests...\n");

  // Test 1: San Francisco (37.7749 N, -122.4194 W) on Sept 4, 2026
  // Local noon is around 20:00 UTC (13:00 PDT). At noon, sun should be high (~55 deg).
  double elev_noon = solar_elevation_deg(37.7749, -122.4194, 2026, 9, 4, 20, 9, 0);
  printf("SF Sept 4 20:09 UTC elevation: %.2f deg\n", elev_noon);
  assert(elev_noon > 50.0 && elev_noon < 65.0);
  assert(!solar_is_after_sundown(37.7749, -122.4194, 2026, 9, 4, 20, 9, 0));

  // Midnight local time is around 07:00 UTC (midnight PDT). Sun should be deeply negative.
  double elev_mid = solar_elevation_deg(37.7749, -122.4194, 2026, 9, 4, 7, 0, 0);
  printf("SF Sept 4 07:00 UTC (midnight local) elevation: %.2f deg\n", elev_mid);
  assert(elev_mid < -20.0);
  assert(solar_is_after_sundown(37.7749, -122.4194, 2026, 9, 4, 7, 0, 0));

  // Current user time: 2026-09-03 23:01 PDT = 2026-09-04 06:01 UTC
  double elev_now = solar_elevation_deg(37.7749, -122.4194, 2026, 9, 4, 6, 1, 0);
  printf("SF Sept 3 23:01 PDT (06:01 UTC) elevation: %.2f deg (after sundown? %s)\n",
         elev_now, solar_is_after_sundown(37.7749, -122.4194, 2026, 9, 4, 6, 1, 0) ? "YES" : "NO");
  assert(elev_now < -15.0);
  assert(solar_is_after_sundown(37.7749, -122.4194, 2026, 9, 4, 6, 1, 0));

  // Test 2: Sunrise and Sunset times for SF on Sept 4, 2026
  // Expected: sunrise ~13:40 UTC (~06:40 PDT), sunset ~02:37 UTC (+1d) (~19:37 PDT)
  int rh = 0, rm = 0, sh = 0, sm = 0;
  bool ok = solar_sunrise_sunset(37.7749, -122.4194, 2026, 9, 4, &rh, &rm, &sh, &sm);
  assert(ok);
  printf("SF Sept 4 Sunrise UTC: %02d:%02d, Sunset UTC: %02d:%02d\n", rh, rm, sh, sm);
  assert(rh == 13 && rm >= 30 && rm <= 50);
  assert(sh == 2 && sm >= 30 && sm <= 50);

  // Test 3: Greenwich / London (51.48 N, 0.0 W) on Summer Solstice (June 21, 2026)
  double elev_london_noon = solar_elevation_deg(51.48, 0.0, 2026, 6, 21, 12, 0, 0);
  printf("London June 21 12:00 UTC elevation: %.2f deg\n", elev_london_noon);
  // Lat 51.48 N, Decl ~ +23.44 -> elev ~ 90 - 51.48 + 23.44 = ~61.96 deg
  assert(elev_london_noon > 60.0 && elev_london_noon < 64.0);

  // Test 4: Equator on March 20 Equinox at solar noon
  double elev_eq = solar_elevation_deg(0.0, 0.0, 2026, 3, 20, 12, 7, 0);
  printf("Equator March 20 noon elevation: %.2f deg\n", elev_eq);
  assert(elev_eq > 88.0);

  printf("All solar calculation tests passed successfully!\n");
  return 0;
}
