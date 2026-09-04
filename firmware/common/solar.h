// Portable NOAA solar position and sunrise/sunset engine for embedded C/C++.
// Computes true solar elevation angle, sunset/sunrise times, and sundown detection
// directly from GPS/operator coordinates (lat/lon) and UTC time.
#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <math.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#ifdef __cplusplus
extern "C" {
#endif

/// Standard astronomical sundown elevation:
/// Sun disk center at -0.833° (accounts for 16' semidiameter + 34' atmospheric refraction).
#define SOLAR_SUNDOWN_ELEVATION_DEG (-0.833)

/// Calculate day of year (1..366)
static inline int solar_day_of_year(uint16_t year, uint8_t month, uint8_t day) {
  static const int days_before_month[12] = {
    0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334
  };
  if (month < 1) month = 1;
  if (month > 12) month = 12;
  bool leap = (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0));
  int doy = days_before_month[month - 1] + day;
  if (leap && month > 2) doy++;
  return doy;
}

/// Calculate true solar elevation angle in degrees for the given coordinates and UTC time.
/// Returns: elevation in degrees (-90.0 .. +90.0). Positive = above horizon, Negative = below horizon.
static inline double solar_elevation_deg(double lat_deg, double lon_deg,
                                        uint16_t year, uint8_t month, uint8_t day,
                                        uint8_t hour, uint8_t min, uint8_t sec) {
  int doy = solar_day_of_year(year, month, day);
  double utc_hours = (double)hour + ((double)min / 60.0) + ((double)sec / 3600.0);

  // Fractional year in radians
  double gamma = (2.0 * M_PI / 365.0) * ((double)doy - 1.0 + (utc_hours - 12.0) / 24.0);

  // Equation of time in minutes
  double eqtime = 229.18 * (0.000075 +
                            0.001868 * cos(gamma) - 0.032077 * sin(gamma) -
                            0.014615 * cos(2.0 * gamma) - 0.040849 * sin(2.0 * gamma));

  // Solar declination in radians
  double decl = 0.006918 -
                0.399912 * cos(gamma) + 0.070257 * sin(gamma) -
                0.006758 * cos(2.0 * gamma) + 0.000907 * sin(2.0 * gamma) -
                0.002697 * cos(3.0 * gamma) + 0.001480 * sin(3.0 * gamma);

  // Solar time offset in minutes: 4 minutes per degree longitude (East positive)
  double time_offset = eqtime + 4.0 * lon_deg;

  // True solar time in minutes
  double tst = utc_hours * 60.0 + time_offset;
  while (tst < 0.0) tst += 1440.0;
  while (tst >= 1440.0) tst -= 1440.0;

  // Solar hour angle in degrees (-180 .. +180, 0 at solar noon)
  double ha_deg = (tst / 4.0) - 180.0;
  double ha_rad = ha_deg * (M_PI / 180.0);
  double lat_rad = lat_deg * (M_PI / 180.0);

  // Solar zenith angle cosine
  double sin_elev = sin(lat_rad) * sin(decl) + cos(lat_rad) * cos(decl) * cos(ha_rad);
  if (sin_elev > 1.0) sin_elev = 1.0;
  if (sin_elev < -1.0) sin_elev = -1.0;

  double elev_rad = asin(sin_elev);
  return elev_rad * (180.0 / M_PI);
}

/// Returns true if the sun is below the horizon (after sundown / before sunrise).
static inline bool solar_is_after_sundown(double lat_deg, double lon_deg,
                                         uint16_t year, uint8_t month, uint8_t day,
                                         uint8_t hour, uint8_t min, uint8_t sec) {
  double elev = solar_elevation_deg(lat_deg, lon_deg, year, month, day, hour, min, sec);
  return elev <= SOLAR_SUNDOWN_ELEVATION_DEG;
}

/// Approximate sunrise and sunset times in UTC (hours and minutes) for the given day and coordinates.
/// Returns false if polar day (midnight sun) or polar night.
static inline bool solar_sunrise_sunset(double lat_deg, double lon_deg,
                                       uint16_t year, uint8_t month, uint8_t day,
                                       int* rise_hour, int* rise_min,
                                       int* set_hour, int* set_min) {
  int doy = solar_day_of_year(year, month, day);
  double gamma = (2.0 * M_PI / 365.0) * ((double)doy - 1.0);
  double eqtime = 229.18 * (0.000075 +
                            0.001868 * cos(gamma) - 0.032077 * sin(gamma) -
                            0.014615 * cos(2.0 * gamma) - 0.040849 * sin(2.0 * gamma));
  double decl = 0.006918 -
                0.399912 * cos(gamma) + 0.070257 * sin(gamma) -
                0.006758 * cos(2.0 * gamma) + 0.000907 * sin(2.0 * gamma) -
                0.002697 * cos(3.0 * gamma) + 0.001480 * sin(3.0 * gamma);

  double lat_rad = lat_deg * (M_PI / 180.0);
  double zenith_rad = (90.0 - SOLAR_SUNDOWN_ELEVATION_DEG) * (M_PI / 180.0);

  double cos_ha = (cos(zenith_rad) - sin(lat_rad) * sin(decl)) / (cos(lat_rad) * cos(decl));
  if (cos_ha > 1.0 || cos_ha < -1.0) {
    return false; // Polar night (cos_ha > 1) or midnight sun (cos_ha < -1)
  }

  double ha_deg = acos(cos_ha) * (180.0 / M_PI);
  double noon_utc = 720.0 - 4.0 * lon_deg - eqtime;
  double rise_utc = noon_utc - ha_deg * 4.0;
  double set_utc = noon_utc + ha_deg * 4.0;

  while (rise_utc < 0.0) rise_utc += 1440.0;
  while (rise_utc >= 1440.0) rise_utc -= 1440.0;
  while (set_utc < 0.0) set_utc += 1440.0;
  while (set_utc >= 1440.0) set_utc -= 1440.0;

  if (rise_hour) *rise_hour = (int)(rise_utc / 60.0);
  if (rise_min)  *rise_min  = (int)fmod(rise_utc, 60.0);
  if (set_hour)  *set_hour  = (int)(set_utc / 60.0);
  if (set_min)   *set_min   = (int)fmod(set_utc, 60.0);
  return true;
}

#ifdef __cplusplus
}
#endif
