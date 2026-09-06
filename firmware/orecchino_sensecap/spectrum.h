// Hidden spectrum-analyzer easter egg: hold the side button 10 s to enter,
// short-press to leave. Live data: 2.4 GHz packet energy from the Wi-Fi
// sniffer, and an SX1262 RSSI sweep across 850-930 MHz.
#pragma once
#include <Arduino.h>

class Arduino_Canvas;

/// Enter the spectrum view: bring up the SX1262 sweep and open the feeds.
void spectrum_reset(uint32_t now);
/// Leave the spectrum view: close the feeds, park the radio.
void spectrum_stop();
/// Advance sweep + redraw. Self-throttled (~12 fps); flushes the canvas.
void spectrum_tick(Arduino_Canvas* cv, uint32_t now);
/// Tap in the sub-GHz trace: zoom in x4 around that frequency (re-centers
/// at max zoom); tap the [-] header control: zoom back out.
void spectrum_tap(int x, int y);

/// True while the spectrum view is up — the sketch widens the promiscuous
/// filter and sweeps Wi-Fi channels evenly instead of the RID hop pattern.
bool spectrum_active();

// Feed, called from the sketch's promiscuous callback (Wi-Fi task
// context — lock-free accumulators, a no-op while the view is closed).
void spectrum_feed_wifi(uint8_t chan, int8_t rssi);
/// Current promiscuous dwell channel (so a silent channel decays fast).
void spectrum_set_wifi_channel(uint8_t chan);

/// Clear peak hold buffers (both 2.4 GHz and Sub-GHz).
void spectrum_clear_peaks();
/// Toggle sweep freeze/pause.
void spectrum_toggle_pause();
/// Check if sweep is currently paused.
bool spectrum_is_paused();
