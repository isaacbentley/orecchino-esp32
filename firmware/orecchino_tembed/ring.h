// The 8-LED WS2812 ring, driven straight from the RMT peripheral — no
// library. It is the handheld's peripheral-vision channel: off when the sky
// is quiet (and the battery matters), a slow amber breath while a contact is
// live, a hard red pulse for an emergency / TFR incursion / forged ID. The
// number of lit LEDs follows the strongest contact's RSSI, so the ring reads
// as a signal meter from across the room.
#pragma once
#include <Arduino.h>

void ring_begin();
/// alert: 0 quiet, 1 contact, 2 danger. level: 0..1 strongest RSSI.
void ring_tick(uint32_t now, uint8_t alert, float level);
void ring_off();
/// Attenuate brightness for dark rooms / solar night mode
void ring_set_dim(bool dim);
