// orecchino_sensecap — Remote ID console on the SenseCAP Indicator.
// Target: Seeed SenseCAP Indicator D1 series (ESP32-S3 + 480x480 touch LCD)
//
// The radios, decoder, track table and JSON feed are the shared core
// (firmware/common/rx_core.h). This sketch adds what the Indicator has:
// a touch map/list console (display.cpp), offline map tiles pushed by the
// desktop app over the same serial line, the RP2040-driven buzzer, and a
// spectrum view that borrows the radios (spectrum.cpp).
#include <Arduino.h>
#define FW_BOARD "sensecap-indicator"
#define ORECCHINO_BOARD_HOOKS
#include "../common/rx_core.h"
#include "../common/tile_store.h"
#include "display.h"
#include "spectrum.h"

// -------------------------------------------------------------- core hooks

// Spectrum view: every frame's energy counts; RID parsing stays MGMT-only.
void rx_hook_wifi_frame(uint8_t chan, int8_t rssi) { spectrum_feed_wifi(chan, rssi); }
// While the analyzer owns the radios, C-UAS pauses entirely.
bool rx_hook_paused() { return spectrum_active(); }

// -------------------------------------------------- RP2040 link (buzzer)
// The Indicator's second MCU owns the buzzer (and sensors). Seeed's stock
// RP2040 firmware speaks COBS-framed packets on the S3<->RP2040 UART:
// TX=19 RX=20 @115200, PKT_TYPE_CMD_BEEP_ON=0xA1 with uint32 on-time ms.

static size_t cobs_encode_buf(const uint8_t* in, size_t len, uint8_t* out) {
  size_t wi = 1, code_i = 0;
  uint8_t code = 1;
  for (size_t ri = 0; ri < len; ri++) {
    uint8_t b = in[ri];
    if (b == 0) {
      out[code_i] = code;
      code_i = wi++;
      code = 1;
    } else {
      out[wi++] = b;
      if (++code == 0xFF) {
        out[code_i] = code;
        code_i = wi++;
        code = 1;
      }
    }
  }
  out[code_i] = code;
  return wi;
}

static void rp2040_cmd(uint8_t type, uint32_t val) {
  uint8_t raw[5] = { type };
  memcpy(raw + 1, &val, 4);
  uint8_t enc[12];
  size_t n = cobs_encode_buf(raw, 5, enc);
  enc[n++] = 0x00;
  Serial1.write(enc, n);
}

static uint8_t  s_beeps_left = 0;
static uint32_t s_next_beep_ms = 0;

static void beep_pattern(uint8_t n) { s_beeps_left = n; }

static void beep_tick(uint32_t now) {
  if (s_beeps_left && (int32_t)(now - s_next_beep_ms) >= 0) {
    rp2040_cmd(0xA1 /* BEEP_ON */, 90);
    s_beeps_left--;
    s_next_beep_ms = now + 220;
  }
}


void rx_hook_track(Track*, bool, bool tfr_entered) {
  if (tfr_entered) beep_pattern(3);  // three short: TFR incursion
}

// Tile store: the shared implementation, with eviction scored from where
// the map is looking.
bool rx_hook_host_line(const char* cmd, char* line, uint32_t now) {
  return tile_store_host_line(cmd, line, now);
}

// ------------------------------------------------------------------ sketch

void setup() {
  Serial.begin(460800);  // real UART via CH340 — 4x faster tile sync
  Serial1.begin(115200, SERIAL_8N1, 20 /* RX */, 19 /* TX */);  // RP2040 link
  uint32_t t0 = millis();
  while (!Serial && millis() - t0 < 3000) delay(10);

  tile_store_begin(display_map_center);
  bool disp = display_begin();
  rx_begin(disp ? ",\"display\":true" : ",\"display\":false");
}

void loop() {
  uint32_t now = millis();

  // Spectrum view: the core stops hopping while paused, so sweep ch 1-13
  // evenly here. 110 ms dwell: just past the ~102 ms AP beacon interval,
  // so even a quiet channel shows its beacons; a full pass every ~1.4 s.
  static uint32_t last_spec_hop = 0;
  static uint8_t spec_ch = 13;
  if (spectrum_active() && now - last_spec_hop >= 110) {
    last_spec_hop = now;
    spec_ch = (uint8_t)(spec_ch % 13) + 1;
    rx_set_channel(spec_ch);
    spectrum_set_wifi_channel(spec_ch);
  }

  rx_tick(now);
  display_tick(now);
  beep_tick(now);

  // During a tile sync the map pauses; show transfer progress instead of a
  // frozen frame.
  static bool was_syncing = false;
  if (tile_store_busy(now)) {
    was_syncing = true;
    display_sync_status(tile_store_files_done());
  } else if (was_syncing) {
    was_syncing = false;
    tile_store_reset_count();
    display_force_redraw();
  }

  static uint32_t last_draw = 0;
  if (now - last_draw >= 1000 && !tile_store_busy(now)) {
    last_draw = now;
    RxStats rs;
    rx_stats(&rs);
    DisplayStats st = { rs.wifi_frames, rs.ble_advs, rs.rid, rs.dropped,
                        rs.channel, rs.ble_ok, rs.ble_ext, rs.heap };
    display_render(g_tracks, TRK_MAX, st, now);
  }
  delay(5);
}
