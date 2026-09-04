// Bare-metal SX1262 RSSI sweep for the spectrum view — no RadioLib, just
// the five commands a swept analyzer needs (standby / set frequency / RX /
// read instantaneous RSSI, plus one-time init). Control lines on GPIO,
// DIO2 as RF switch, TCXO on DIO3 with a crystal fallback.
#pragma once
#include <Arduino.h>

#define SX_SWEEP_LO_HZ 850000000UL
#define SX_SWEEP_HI_HZ 930000000UL

/// One-time bring-up (idempotent; latches failure). False = no/dead radio.
bool sx1262_sweep_begin();
/// Retune the sweep span (defaults to the full 850-930 MHz). Picks the
/// widest GFSK RX bandwidth that fits the resulting bin width, down to
/// 4.8 kHz — resolution scales freely with span at constant sweep time.
void sx1262_sweep_set_span(uint32_t lo_hz, uint32_t hi_hz, int n_bins);
/// Advance the sweep: measure `steps` bins starting at *cursor (wrapping at
/// n), writing raw dBm (clamped to -127..0) into bins[] — scaling to display
/// units is the caller's job, so the view can auto-range. ~1.4 ms per step,
/// dominated by expander I2C — call in small chunks from the UI tick.
void sx1262_sweep_chunk(int8_t* bins, int n, int* cursor, int steps);
/// Park the radio in standby when leaving the spectrum view.
void sx1262_sweep_stop();
