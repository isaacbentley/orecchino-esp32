// orecchino_t5epd — Remote ID tactical board on the LilyGO T5 E-Paper S3 Pro.
// Target: ESP32-S3R8 (esp32:esp32:esp32s3, 16 MB flash, OPI PSRAM, USB CDC)
//
// The radios, decoder, track table and JSON feed are the shared core
// (firmware/common/rx_core.h). This sketch adds the 4.7" e-paper board
// (ui_epd.cpp, on the vendored epdiy driver) with an offline map view fed
// by the desktop app's tile sync, and an SX1262 sub-GHz sweep for the
// spectrum view. USB still speaks the
// JSON line protocol.
#include <Arduino.h>
#define FW_BOARD "lilygo-t5-epaper-s3-pro"
#define ORECCHINO_BOARD_HOOKS
#include "../common/rx_core.h"
#include "../common/tile_store.h"
#include "board_t5.h"
#include "ui_epd.h"
#include "t5_periph.h"

void rx_hook_wifi_frame(uint8_t chan, int8_t rssi) { ui_feed_wifi(chan, rssi); }
bool rx_hook_paused() { return ui_spectrum_active(); }
bool rx_hook_host_line(const char* cmd, char* line, uint32_t now) {
  if (!strcmp(cmd, "reboot")) { ESP.restart(); return true; }
  return tile_store_host_line(cmd, line, now);
}
void rx_hook_track(Track*, bool, bool) {}

static int batt_pct() { return periph_batt_pct(); }

void setup() {
  // Host lines run to 1.6 KB (TFR polygons, tile chunks) and land in one
  // USB burst; the default CDC ring buffer cannot hold one whole line.
  Serial.setRxBufferSize(4096);
  Serial.begin(115200);
  uint32_t t0 = millis();
  while (!Serial && millis() - t0 < 2000) delay(10);
  Serial.println("\n[ORECCHINO] LilyGO T5 E-Paper S3 Pro starting...");
  tile_store_begin(ui_map_center);
  periph_touch_reset();
  bool disp = ui_begin();
  Serial.printf("[ORECCHINO] E-Paper display init %s\n", disp ? "OK" : "FAILED (continuing headless)");
  periph_begin();   // after epdiy owns the I2C bus
  rx_begin(disp ? ",\"display\":true" : ",\"display\":false");
}

void loop() {
  uint32_t now = millis();
  static uint32_t last_spec_hop = 0;
  static uint8_t spec_ch = 13;
  if (ui_spectrum_active() && now - last_spec_hop >= 110) {
    last_spec_hop = now;
    spec_ch = (uint8_t)(spec_ch % 13) + 1;
    rx_set_channel(spec_ch);
    ui_set_wifi_channel(spec_ch);
  }
  rx_tick(now);
  periph_tick(now);
  static int batt = -1;
  static uint32_t last_batt = 0;
  if (now - last_batt >= 10000 || last_batt == 0) { last_batt = now; batt = batt_pct(); }
  RxStats st;
  rx_stats(&st);
  bool syncing = tile_store_busy(now);
  static bool was_syncing = false;
  if (was_syncing && !syncing) tile_store_reset_count();
  was_syncing = syncing;
  ui_tick(now, st.ble_ok, batt, syncing ? (int)tile_store_files_done() : -1);
  delay(3);
}
