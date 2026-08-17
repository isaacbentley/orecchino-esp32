// Hidden spectrum-analyzer easter egg: hold the side button 10 s to enter,
// short-press to leave. v0 renders synthetic data (UI mock) — the SX1262
// sweep and 2.4 GHz packet-energy feeds plug into spectrum_tick later.
#pragma once
#include <Arduino.h>

class Arduino_Canvas;

/// Reset sim + palette state on mode entry.
void spectrum_reset(uint32_t now);
/// Advance the sim and redraw. Self-throttled (~12 fps); flushes the canvas.
void spectrum_tick(Arduino_Canvas* cv, uint32_t now);
