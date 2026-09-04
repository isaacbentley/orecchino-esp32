// Bare-metal CC1101 RSSI sweep for the spectrum view — the handful of
// register writes and strobes a swept analyzer needs, no RadioLib. The
// T-Embed routes the antenna through a band switch (SW0/SW1), so the sweep
// walks the chip's three tuning ranges — 300-348, 387-464 and 779-928 MHz —
// flipping the path as it crosses each.
#pragma once
#include <Arduino.h>

/// One-time bring-up (idempotent; latches failure). False = no/dead radio.
bool cc1101_sweep_begin();
/// Number of bins the full sweep uses.
#define CC_SWEEP_BINS 128
/// Frequency (Hz) of bin i, for the axis and readout.
uint32_t cc1101_bin_hz(int i);
/// Advance `steps` bins from *cursor, writing dBm into bins[] (max-held
/// double read per bin, ~1 ms each with the auto-cal retune).
void cc1101_sweep_chunk(int8_t* bins, int* cursor, int steps);
/// Park the radio in IDLE when leaving the spectrum view.
void cc1101_sweep_stop();
