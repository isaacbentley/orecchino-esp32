// orecchino_amoled — pocket Remote ID receiver on the Waveshare
// ESP32-C6-Touch-AMOLED-1.8.
// Target: ESP32-C6 (esp32:esp32:esp32c6, 16 MB flash, no PSRAM, USB CDC)
//
// The radios, decoder, track table and JSON feed are the shared core
// (firmware/common/rx_core.h) — the same code that runs on the S3 and C3
// boards, built for the C6's single RISC-V core. This sketch adds the
// 1.8" AMOLED touch console (ui_amoled.cpp) and the AXP2101 battery
// readout. USB still speaks the JSON line protocol.
#include <Arduino.h>
#include <Wire.h>
#define FW_BOARD "waveshare-c6-amoled-1.8"
#define ORECCHINO_BOARD_HOOKS
#include "../common/rx_core.h"
#include "board_amoled.h"
#include "ui_amoled.h"

void rx_hook_wifi_frame(uint8_t chan, int8_t rssi) { ui_feed_wifi(chan, rssi); }
bool rx_hook_paused() { return ui_spectrum_active(); }
bool rx_hook_host_line(const char* cmd, char*, uint32_t) {
  if (strncmp(cmd, "fs_", 3) != 0) return false;
  Serial.println("{\"type\":\"fs_err\",\"msg\":\"no tile store on this board\"}");
  return true;   // no map here: decline the sync instead of letting it time out
}
void rx_hook_track(Track*, bool, bool) {}

// AXP2101: battery percentage register 0xA4, -1 if the PMU is not answering.
static int batt_pct() {
  Wire.beginTransmission(AXP2101_ADDR);
  Wire.write(0xA4);
  if (Wire.endTransmission(false) != 0) return -1;
  if (Wire.requestFrom((int)AXP2101_ADDR, 1) != 1) return -1;
  int v = Wire.read() & 0x7F;
  return v > 100 ? 100 : v;
}

void setup() {
  // Host lines run to 1.6 KB (TFR polygons, tile chunks) and land in one
  // USB burst; the default CDC ring buffer cannot hold one whole line.
  Serial.setRxBufferSize(4096);
  Serial.begin(115200);
  uint32_t t0 = millis();
  while (!Serial && millis() - t0 < 2000) delay(10);
  Wire.begin(PIN_I2C_SDA, PIN_I2C_SCL);
  bool disp = ui_begin();
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
  static int batt = -1;
  static uint32_t last_batt = 0;
  if (now - last_batt >= 10000 || last_batt == 0) { last_batt = now; batt = batt_pct(); }
  RxStats st;
  rx_stats(&st);
  ui_tick(now, st.ble_ok, batt);
  delay(3);
}
