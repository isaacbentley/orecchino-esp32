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
#include "../common/tx_core.h"
#include "../common/tile_store.h"
#include "board_t5.h"
#include "ui_epd.h"
#include "t5_periph.h"

static uint8_t g_mode = UI_MODE_RX;

// ---- receiver hooks (unused in beacon mode; the core just never calls them)
void rx_hook_wifi_frame(uint8_t chan, int8_t rssi) { ui_feed_wifi(chan, rssi); }
bool rx_hook_paused() { return ui_spectrum_active(); }

// ---- transmit interface for the UI (this file is the sole includer of tx_core.h)
int         txui_count() { return tx_path_count(); }
const char* txui_id(int i) { return tx_path_id(i); }
const char* txui_carrier(int i) { return tx_path_carrier(i); }
const char* txui_desc(int i) { return tx_path_desc(i); }
bool        txui_enabled(int i) { return tx_enabled(i); }
void        txui_set_enabled(int i, bool on) { tx_set_enabled(i, on); }
uint32_t    txui_sent(int i) { return tx_count(i); }
bool        txui_running() { return tx_running(); }
void        txui_set_running(bool on) { tx_set_running(on); }
bool        txui_emergency() { return tx_emergency(); }
void        txui_set_emergency(bool on) { tx_set_emergency(on); }

void board_switch_mode(uint8_t mode) {
  Preferences p; p.begin("orecchino", false);
  p.putUChar("mode", mode); p.end();
  delay(50);
  ESP.restart();
}

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

  // Mode switching commands:
  if (!strcmp(cmd, "mode") || !strcmp(cmd, "set_mode")) {
    char m[16] = {0};
    if (json_field_str(line, "mode", m, sizeof(m))) {
      if (!strcmp(m, "tx")) {
        Serial.println("{\"type\":\"mode\",\"mode\":\"tx\",\"switching\":true}");
        board_switch_mode(UI_MODE_TX);
      } else {
        Serial.println("{\"type\":\"mode\",\"mode\":\"rx\"}");
      }
      return true;
    }
    Serial.printf("{\"type\":\"mode\",\"mode\":\"%s\"}\n", g_mode == UI_MODE_TX ? "tx" : "rx");
    return true;
  }
  if (!strcmp(cmd, "get_mode")) {
    Serial.printf("{\"type\":\"mode\",\"mode\":\"%s\"}\n", g_mode == UI_MODE_TX ? "tx" : "rx");
    return true;
  }

  // 1. JSON Backlight & VCOM commands:
  if (!strcmp(cmd, "set_bl") || !strcmp(cmd, "bl")) {
    char m[16] = {0};
    if (json_field_str(line, "mode", m, sizeof(m))) {
      if (!strcmp(m, "on")) periph_bl_set_mode(BL_ON);
      else if (!strcmp(m, "off")) periph_bl_set_mode(BL_OFF);
      else periph_bl_set_mode(BL_AUTO);
    }
    double duty = 0;
    if (json_field_dbl(line, "duty", &duty) || json_field_dbl(line, "level", &duty)) {
      if (duty > 0 && duty <= 1.0) duty *= 255.0;
      if (duty >= 0 && duty <= 255) periph_bl_set_duty((uint8_t)duty);
    }
    Serial.printf("{\"type\":\"backlight\",\"mode\":\"%s\",\"active\":%s,\"duty\":%u,\"sundown\":%s,\"sun_elev\":%.1f}\n",
                  periph_bl_get_mode() == BL_AUTO ? "auto" : periph_bl_get_mode() == BL_ON ? "on" : "off",
                  periph_bl_is_active() ? "true" : "false", (unsigned)periph_bl_get_duty(),
                  periph_is_after_sundown() ? "true" : "false", periph_sun_elevation());
    return true;
  }
  if (!strcmp(cmd, "get_bl")) {
    Serial.printf("{\"type\":\"backlight\",\"mode\":\"%s\",\"active\":%s,\"duty\":%u,\"sundown\":%s,\"sun_elev\":%.1f}\n",
                  periph_bl_get_mode() == BL_AUTO ? "auto" : periph_bl_get_mode() == BL_ON ? "on" : "off",
                  periph_bl_is_active() ? "true" : "false", (unsigned)periph_bl_get_duty(),
                  periph_is_after_sundown() ? "true" : "false", periph_sun_elevation());
    return true;
  }
  if (!strcmp(cmd, "set_time") || !strcmp(cmd, "time")) {
    double u = 0;
    if (json_field_dbl(line, "utc", &u)) {
      time_t epoch = (time_t)u;
      struct tm t;
      gmtime_r(&epoch, &t);
      periph_set_utc_time(t.tm_year + 1900, t.tm_mon + 1, t.tm_mday, t.tm_hour, t.tm_min, t.tm_sec);
      Serial.printf("{\"type\":\"time\",\"utc\":%lu,\"set\":true}\n", (unsigned long)epoch);
      return true;
    }
  }

  // JSON VCOM commands:
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
  if (line) {
    const char* p = line;
    while (*p == ' ') p++;
    if (!strncmp(p, "bl", 2) || !strncmp(p, "backlight", 9)) {
      p += (!strncmp(p, "backlight", 9) ? 9 : 2);
      while (*p == ' ') p++;
      if (!strncmp(p, "on", 2)) periph_bl_set_mode(BL_ON);
      else if (!strncmp(p, "off", 3)) periph_bl_set_mode(BL_OFF);
      else if (!strncmp(p, "auto", 4)) periph_bl_set_mode(BL_AUTO);
      else if (*p >= '0' && *p <= '9') {
        int v = atoi(p);
        if (strchr(p, '%')) v = (v * 255) / 100;
        if (v >= 0 && v <= 255) periph_bl_set_duty((uint8_t)v);
      }
      Serial.printf("{\"type\":\"backlight\",\"mode\":\"%s\",\"active\":%s,\"duty\":%u,\"sundown\":%s,\"sun_elev\":%.1f}\n",
                    periph_bl_get_mode() == BL_AUTO ? "auto" : periph_bl_get_mode() == BL_ON ? "on" : "off",
                    periph_bl_is_active() ? "true" : "false", (unsigned)periph_bl_get_duty(),
                    periph_is_after_sundown() ? "true" : "false", periph_sun_elevation());
      return true;
    }
    if (!strncmp(p, "mode", 4)) {
      p += 4;
      while (*p == ' ') p++;
      if (!strncmp(p, "tx", 2)) {
        Serial.println("{\"type\":\"mode\",\"mode\":\"tx\",\"switching\":true}");
        board_switch_mode(UI_MODE_TX);
      } else if (!strncmp(p, "rx", 2)) {
        Serial.println("{\"type\":\"mode\",\"mode\":\"rx\"}");
      } else {
        Serial.printf("{\"type\":\"mode\",\"mode\":\"%s\"}\n", g_mode == UI_MODE_TX ? "tx" : "rx");
      }
      return true;
    }
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

  Preferences p; p.begin("orecchino", true);
  g_mode = p.getUChar("mode", UI_MODE_RX);
  p.end();
  if (g_mode > UI_MODE_TX) g_mode = UI_MODE_RX;

  if (g_mode == UI_MODE_RX) {
    tile_store_begin(ui_map_center);
  }
  periph_touch_reset();
  bool disp = ui_begin(g_mode);
  uint16_t vcom = ui_get_vcom();
  Serial.printf("[ORECCHINO] E-Paper display init %s (VCOM: %u mV / -%.2fV, Mode: %s)\n",
                disp ? "OK" : "FAILED", (unsigned)vcom, vcom / 1000.0,
                g_mode == UI_MODE_TX ? "TX (Test Beacon)" : "RX (Receiver)");
  periph_begin();   // after epdiy owns the I2C bus

  if (g_mode == UI_MODE_TX) {
    tx_begin();
  } else {
    char extra[64];
    snprintf(extra, sizeof(extra), ",\"display\":%s,\"vcom\":%u,\"mode\":\"rx\"", disp ? "true" : "false", (unsigned)vcom);
    rx_begin(extra);
  }
}

void loop() {
  uint32_t now = millis();

  if (g_mode == UI_MODE_TX) {
    // Check serial for mode switch or reboot
    while (Serial.available()) {
      int c = Serial.peek();
      if (c == '{' || c == 'm' || c == 'r' || c == 'b') {
        String s = Serial.readStringUntil('\n');
        s.trim();
        if (s.startsWith("bl") || s.startsWith("backlight")) {
          const char* p = s.c_str() + (s.startsWith("backlight") ? 9 : 2);
          while (*p == ' ') p++;
          if (!strncmp(p, "on", 2)) periph_bl_set_mode(BL_ON);
          else if (!strncmp(p, "off", 3)) periph_bl_set_mode(BL_OFF);
          else if (!strncmp(p, "auto", 4)) periph_bl_set_mode(BL_AUTO);
          else if (*p >= '0' && *p <= '9') {
            int v = atoi(p);
            if (strchr(p, '%')) v = (v * 255) / 100;
            if (v >= 0 && v <= 255) periph_bl_set_duty((uint8_t)v);
          }
          Serial.printf("{\"type\":\"backlight\",\"mode\":\"%s\",\"active\":%s,\"duty\":%u,\"sundown\":%s,\"sun_elev\":%.1f}\n",
                        periph_bl_get_mode() == BL_AUTO ? "auto" : periph_bl_get_mode() == BL_ON ? "on" : "off",
                        periph_bl_is_active() ? "true" : "false", (unsigned)periph_bl_get_duty(),
                        periph_is_after_sundown() ? "true" : "false", periph_sun_elevation());
        } else if (s == "mode rx") {
          Serial.println("{\"type\":\"mode\",\"mode\":\"rx\",\"switching\":true}");
          board_switch_mode(UI_MODE_RX);
        } else if (s == "mode tx" || s == "mode") {
          Serial.println("{\"type\":\"mode\",\"mode\":\"tx\"}");
        } else if (s == "reboot") {
          ESP.restart();
        } else if (s.indexOf("\"cmd\":\"mode\"") >= 0 || s.indexOf("\"cmd\":\"set_mode\"") >= 0) {
          if (s.indexOf("\"rx\"") >= 0) {
            Serial.println("{\"type\":\"mode\",\"mode\":\"rx\",\"switching\":true}");
            board_switch_mode(UI_MODE_RX);
          } else {
            Serial.println("{\"type\":\"mode\",\"mode\":\"tx\"}");
          }
        }
      } else {
        break; // regular tx_tick CLI will process
      }
    }
    tx_tick(now);
    periph_tick(now);
    static int batt = -1;
    static uint32_t last_batt = 0;
    if (now - last_batt >= 10000 || last_batt == 0) { last_batt = now; batt = batt_pct(); }
    ui_tick(now, true, batt, -1);
    delay(3);
    return;
  }

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

