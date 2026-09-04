// T-Embed console: a 320x170 landscape strip driven by a rotary encoder.
//
// The handheld does two jobs, chosen from a boot menu and remembered across
// power cycles: RECEIVER, and a Remote ID TEST BEACON for bench-checking
// other receivers. Hold the knob for a second from either mode to reopen the
// menu; picking the other mode saves it and reboots (the two modes bring up
// the radios differently, so a clean restart is safer than a live switch).
//
// Receiver: the contact list on the left, the selected contact's live detail
// on the right — a thumb on the knob walks the sky without losing the
// numbers. Click for a full-screen contact (big range and bearing), click to
// return. Side key steps the backlight; hold it for a CC1101 spectrum sweep.
// The LED ring mirrors the alert state.
//
// Test beacon: a list of the ten transmit variants (five air interfaces plus
// five format variants); turn to a row, click to switch that variant on or
// off, so you can test exactly one path or all of them. Top rows toggle the
// master transmit and the emergency flag. The ring glows while transmitting.
#pragma once
#include <Arduino.h>

enum UiMode : uint8_t { UI_MODE_RX = 0, UI_MODE_TX = 1 };

/// Bring up the panel in the given mode (does not touch the radios).
bool ui_begin(uint8_t mode);
/// Call once the radios are up: forgets any knob movement made while the
/// boot was busy, so the UI does not jump when it starts responding.
void ui_flush_input();
/// Input, ring, spectrum sweep. Call every loop pass.
void ui_tick(uint32_t now, bool ble_ok, int batt_pct);
/// RX only — true while the spectrum view owns the radios.
bool ui_spectrum_active();
/// RX feeds from the sketch's core hooks (Wi-Fi task context).
void ui_feed_wifi(uint8_t chan, int8_t rssi);
void ui_set_wifi_channel(uint8_t chan);

// ---- provided BY THE SKETCH (the sole includer of tx_core.h, so the
// transmit enable-mask has exactly one definition; the UI reaches it here).
int         txui_count();
const char* txui_id(int i);
const char* txui_carrier(int i);
bool        txui_enabled(int i);
void        txui_set_enabled(int i, bool on);
uint32_t    txui_sent(int i);
bool        txui_running();
void        txui_set_running(bool on);
bool        txui_emergency();
void        txui_set_emergency(bool on);
/// Persist `mode` as the boot mode and reboot into it.
void        board_switch_mode(uint8_t mode);
