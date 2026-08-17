// SenseCAP Indicator 480x480 drone console. Implementation in display.cpp;
// compiles to no-ops until ORECCHINO_DISPLAY is enabled with the panel
// bring-up (Arduino_GFX + ST7701 RGB + IO expander).
#pragma once
#include <Arduino.h>
#include "tracker.h"

// Operator location pushed by the host app (defined in the sketch); used
// for ranging readouts and as the map's default center.
extern bool   g_home_set;
extern double g_home_lat, g_home_lon;
/// Unique drones tracked since power-on (defined in the sketch).
extern uint32_t g_seen_count;

struct DisplayStats {
  uint32_t wifi_frames, ble_advs, rid, dropped;
  uint8_t  channel;
  bool     ble_ok;
  bool     ble_ext;
  uint32_t heap;
};

bool display_begin();
void display_render(const Track* tracks, int max_tracks, const DisplayStats& st,
                    uint32_t now);
/// Call every loop pass: polls touch (pan/pinch/tap) and the side button
/// (short press toggles map/list; a 10 s hold opens the spectrum view).
void display_tick(uint32_t now);
/// Current map view center (for storage eviction scoring). False if the
/// display is disabled.
bool display_map_center(double* lat, double* lon);
/// Show transfer progress while the host is pushing tiles.
void display_sync_status(uint32_t files_done);
/// Force a full repaint on the next render (e.g. after a sync ends).
void display_force_redraw();
