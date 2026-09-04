// Waveshare AMOLED console: a pocket-sized 368x448 portrait touch screen.
//
// A card stack — up to four contacts on screen, drag to scroll, tap for a
// full-screen contact with the big range/bearing numbers. The status band
// is the alert bar. AMOLED pixels cost power only when lit, so the design
// is black-on-black with a breathing ring while scanning, and the panel
// dims after 30 s idle (a danger alert forces it bright). There is no PSRAM
// on the C6 for a canvas, so each region paints straight to the panel's
// GRAM, only when its content changes.
#pragma once
#include <Arduino.h>

bool ui_begin();
void ui_tick(uint32_t now, bool ble_ok, int batt_pct);
bool ui_spectrum_active();
void ui_feed_wifi(uint8_t chan, int8_t rssi);
void ui_set_wifi_channel(uint8_t chan);
