// T5 E-Paper console: a 960x540 tactical board you can read in full sun.
//
// Two boards, cycled with the button: the tactical table, and an offline map
// on the same tiles the SenseCAP uses — CARTO's dark style inverted into
// sixteen greys, which reads like a printed street map in daylight. The map
// frames you and every live contact and redraws only when they move.
//
// Table: the contact table — one row per aircraft, ranked danger / active /
// history, the selected row flagged. Right: a range-ring plot centred on the
// operator (rings auto-scale to the farthest contact, headings as ticks) —
// or, with no operator position, contacts as a signal-strength ladder. A
// black header band is the alert bar. E-paper is slow and ghosts, so the
// board redraws only when its content signature changes: fast DU updates for
// routine changes, a clean GC16 every dozen updates, on alert changes, and
// at least every ten minutes.
#pragma once
#include <Arduino.h>

enum UiMode : uint8_t { UI_MODE_RX = 0, UI_MODE_TX = 1 };

bool ui_begin(uint8_t mode = UI_MODE_RX);
uint8_t ui_get_mode();
/// Input (BOOT button, touch, home key), refresh scheduling, spectrum sweep. Call every pass.
/// sync_files: -1 when idle, else files received so far in a running sync.
void ui_tick(uint32_t now, bool ble_ok, int batt_pct, int sync_files);
/// Where the map is looking (tile-eviction scoring). False if unknown.
bool ui_map_center(double* lat, double* lon);
bool ui_spectrum_active();
void ui_feed_wifi(uint8_t chan, int8_t rssi);
void ui_set_wifi_channel(uint8_t chan);
uint16_t ui_get_vcom();
bool     ui_set_vcom(uint16_t vcom);

// Transmit core accessors provided by main sketch
int         txui_count();
const char* txui_id(int i);
const char* txui_carrier(int i);
const char* txui_desc(int i);
bool        txui_enabled(int i);
void        txui_set_enabled(int i, bool on);
uint32_t    txui_sent(int i);
bool        txui_running();
void        txui_set_running(bool on);
bool        txui_emergency();
void        txui_set_emergency(bool on);
void        board_switch_mode(uint8_t mode);
