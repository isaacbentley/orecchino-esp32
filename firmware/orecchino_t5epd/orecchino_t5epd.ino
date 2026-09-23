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
void rx_hook_wifi_frame(uint8_t chan, int8_t rssi) {}
bool rx_hook_paused() { return false; }

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

// The host protocol here is the app's: set_time plus the shared tile store
// (set_home and the TFR commands are handled in rx_core before this hook).
bool rx_hook_host_line(const char* cmd, char* line, uint32_t now) {
  if (!strcmp(cmd, "set_time")) {
    double u = 0;
    if (json_field_dbl(line, "utc", &u)) {
      time_t epoch = (time_t)u;
      bool set = periph_set_utc_time_host(epoch);
      // Answer with what the RTC chip holds, read back after the write:
      // the time that survives a reset. null when there is no chip, the
      // write failed, or the chip flags its time as lost, so a host can say
      // so rather than trust the running clock, which a reset discards.
      char rtc[24];
      if (set && periph_rtc_iso(rtc, sizeof(rtc)))
        Serial.printf("{\"type\":\"time\",\"utc\":%lu,\"set\":true,\"rtc\":\"%s\"}\n", (unsigned long)epoch, rtc);
      else
        Serial.printf("{\"type\":\"time\",\"utc\":%lu,\"set\":%s,\"rtc\":null}\n",
                      (unsigned long)epoch, set ? "true" : "false");
    }
    return true;
  }
  return tile_store_host_line(cmd, line, now);
}
void rx_hook_track(Track*, bool, bool) {}   // the board re-reads the table on its own cadence

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
  // LoRa and SD share SPI bus: pull CS lines high immediately to prevent bus contention
  gpio_hold_dis((gpio_num_t)PIN_LORA_RST);
  gpio_deep_sleep_hold_dis();
  pinMode(PIN_LORA_CS, OUTPUT); digitalWrite(PIN_LORA_CS, HIGH);
  pinMode(PIN_SD_CS, OUTPUT);   digitalWrite(PIN_SD_CS, HIGH);

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
    // Read the host lines here, before tx_tick: JSON commands (set_time,
    // tile sync) go to the host hook, plain lines to the beacon console.
    static char s_tx_buf[512];
    static int s_tx_len = 0;
    while (Serial.available()) {
      char c = (char)Serial.read();
      if (c == '\n' || c == '\r') {
        if (s_tx_len > 0) {
          s_tx_buf[s_tx_len] = 0;
          char cmd[16] = {0};
          if (json_field_str(s_tx_buf, "cmd", cmd, sizeof(cmd)))
            rx_hook_host_line(cmd, s_tx_buf, now);
          else
            handle_line(s_tx_buf);   // tx_core console: s, go, stop, e, h, r
          s_tx_len = 0;
        }
      } else if (s_tx_len < (int)sizeof(s_tx_buf) - 1) {
        s_tx_buf[s_tx_len++] = c;
      } else {
        s_tx_len = 0;
      }
    }

    tx_tick(now);
    periph_tick(now);
    static int batt = -1;
    static uint32_t last_batt = 0;
    if (now - last_batt >= 10000 || last_batt == 0) { last_batt = now; batt = batt_pct(); }
    ui_tick(now, true, batt, -1);
    vTaskDelay(1);
    return;
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
  vTaskDelay(1);
}

