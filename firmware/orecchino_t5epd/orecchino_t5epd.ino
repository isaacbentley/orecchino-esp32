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
#include <Preferences.h>
#define FW_BOARD "lilygo-t5-epaper-s3-pro"
#define ORECCHINO_BOARD_HOOKS
#include "../common/rx_core.h"
#include "../common/tile_store.h"
#include "board_t5.h"
#include "ui_epd.h"
#include "t5_periph.h"

void rx_hook_wifi_frame(uint8_t chan, int8_t rssi) { ui_feed_wifi(chan, rssi); }
bool rx_hook_paused() { return ui_spectrum_active(); }
static bool parse_vcom_val(const char* str, uint16_t* out) {
  if (!str) return false;
  while (*str && (*str == ' ' || *str == '=' || *str == ':')) str++;
  if (!*str) return false;
  char* end = nullptr;
  double val = fabs(strtod(str, &end));
  if (end == str) return false;
  if (val >= 0.4 && val <= 3.5) {
    *out = (uint16_t)round(val * 1000.0);
    return true;
  }
  if (val >= 400.0 && val <= 3500.0) {
    *out = (uint16_t)round(val);
    return true;
  }
  return false;
}

bool rx_hook_host_line(const char* cmd, char* line, uint32_t now) {
  if (!strcmp(cmd, "reboot")) { ESP.restart(); return true; }

  // 1. JSON VCOM commands:
  //    {"cmd":"set_vcom","vcom":1560}
  //    {"cmd":"vcom","vcom":-1.56}
  //    {"cmd":"get_vcom"}
  if (!strcmp(cmd, "set_vcom") || !strcmp(cmd, "vcom")) {
    double d = 0;
    if (json_field_dbl(line, "vcom", &d) || json_field_dbl(line, "val", &d)) {
      char s[24]; snprintf(s, sizeof(s), "%f", d);
      uint16_t v = 0;
      if (parse_vcom_val(s, &v) && ui_set_vcom(v)) {
        Serial.printf("{\"type\":\"vcom\",\"vcom\":%u,\"voltage\":\"-%.2fV\",\"saved\":true}\n", (unsigned)v, v / 1000.0);
      } else {
        Serial.printf("{\"type\":\"error\",\"msg\":\"invalid vcom (must be 500..3000 mV)\"}\n");
      }
      return true;
    }
    Serial.printf("{\"type\":\"vcom\",\"vcom\":%u,\"voltage\":\"-%.2fV\"}\n", (unsigned)ui_get_vcom(), ui_get_vcom() / 1000.0);
    return true;
  }
  if (!strcmp(cmd, "get_vcom")) {
    Serial.printf("{\"type\":\"vcom\",\"vcom\":%u,\"voltage\":\"-%.2fV\"}\n", (unsigned)ui_get_vcom(), ui_get_vcom() / 1000.0);
    return true;
  }

  // 2. Plain text serial CLI commands:
  //    "vcom" -> query
  //    "vcom 1560", "vcom -1.56", "vcom=1560", "set_vcom 1560" -> set & save
  if (line) {
    const char* p = line;
    while (*p == ' ') p++;
    if (!strncmp(p, "vcom", 4) || !strncmp(p, "set_vcom", 8)) {
      p += (!strncmp(p, "set_vcom", 8) ? 8 : 4);
      while (*p && (*p == ' ' || *p == '=' || *p == ':')) p++;
      if (*p) {
        uint16_t v = 0;
        if (parse_vcom_val(p, &v) && ui_set_vcom(v)) {
          Serial.printf("{\"type\":\"vcom\",\"vcom\":%u,\"voltage\":\"-%.2fV\",\"saved\":true}\n", (unsigned)v, v / 1000.0);
        } else {
          Serial.printf("{\"type\":\"error\",\"msg\":\"invalid vcom: expected 500..3000 mV (e.g. 1560 or -1.56)\"}\n");
        }
      } else {
        Serial.printf("{\"type\":\"vcom\",\"vcom\":%u,\"voltage\":\"-%.2fV\"}\n", (unsigned)ui_get_vcom(), ui_get_vcom() / 1000.0);
      }
      return true;
    }
  }

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
  uint16_t vcom = ui_get_vcom();
  Serial.printf("[ORECCHINO] E-Paper display init %s (VCOM: %u mV / -%.2fV)\n", disp ? "OK" : "FAILED", (unsigned)vcom, vcom / 1000.0);
  periph_begin();   // after epdiy owns the I2C bus
  char extra[64];
  snprintf(extra, sizeof(extra), ",\"display\":%s,\"vcom\":%u", disp ? "true" : "false", (unsigned)vcom);
  rx_begin(extra);
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
