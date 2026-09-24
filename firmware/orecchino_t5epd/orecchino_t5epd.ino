// orecchino_t5epd — Remote ID tactical board on the LilyGO T5 E-Paper S3 Pro.
// Target: ESP32-S3R8 (esp32:esp32:esp32s3, 16 MB flash, OPI PSRAM, USB CDC)
//
// The radios, decoder, track table and JSON feed are the shared core
// (firmware/common/rx_core.h). This sketch adds the 4.7" e-paper board
// (ui_epd.cpp, on the vendored epdiy driver) with an offline map view fed
// by the desktop app's tile sync or the board's own Wi-Fi, an SX1262
// sub-GHz sweep for the spectrum view, and Wi-Fi sync windows for the
// clock, TFRs, ADS-B traffic and map tiles (net_sync.h, net_fetch.h).
// USB and BLE speak the JSON line protocol.
#include <Arduino.h>
#include <Preferences.h>
#define FW_BOARD "lilygo-t5-epaper-s3-pro"
#define ORECCHINO_BOARD_HOOKS
#define ORECCHINO_TRAFFIC            // the host's traffic lines feed the board's alerts
#define RX_CAPS_BOARD ",\"tiles\",\"wifi\""   // BLE Device Info: what else this board handles
#define RX_SERIAL_DRAIN 1           // e-paper refreshes stall the loop: drain USB on a task (rx_core.h)
#include "../common/rx_core.h"
#include "../common/tx_core.h"
#include "../common/tile_store.h"
#include "../common/net_sync.h"
#include "../common/net_fetch.h"
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
bool        txui_slow() { return tx_slow(); }
void        txui_set_slow(bool on) { tx_set_slow(on); }

void board_switch_mode(uint8_t mode) {
  rx_log_flush();   // the restart would lose records not yet saved
  Preferences p; p.begin("orecchino", false);
  p.putUChar("mode", mode); p.end();
  delay(50);
  ESP.restart();
}

// ---- Wi-Fi (net_sync.h + net_fetch.h): the ops the state machine drives.
static_assert(SRC_SERIAL == 0 && SRC_BLE_BONDED == 1 && SRC_ALL == NET_DST_ALL,
              "net_sync.h numbers the transports like host_link.h");
static void t5_net_emit(uint8_t dst, const char* line, size_t n) {
  host_write_to((HostSrc)dst, (const uint8_t*)line, n);   // NET_DST_ALL == SRC_ALL
}
// An SNTP answer sets what set_time sets: the system clock, the RTC chip
// and the match log's clock.
static void t5_net_set_utc(uint32_t utc) {
  periph_set_utc_time_host((time_t)utc);   // settimeofday + RTC
  RX_LOCK(); log_set_utc(utc, millis()); RX_UNLOCK();
}
static void t5_net_begin(bool station) {
  NetOps ops = {};
  if (station) {
    net_esp_wifi_ops(&ops);
    net_fetch_ops(&ops);
    ops.set_utc = t5_net_set_utc;
    ops.phone_connected = ble_link_peer_secure;   // a paired phone pauses automatic Wi-Fi
  } else {
    ops.load = net_esp_load;   // beacon mode: show the settings, never join or scan
  }
  ops.emit = t5_net_emit;
  net_sync_init(&ops);
}

// The host protocol here is the app's: set_time plus the shared tile store
// and the wifi_* commands (set_home and the TFR commands are handled in
// rx_core before this hook). Replies go to the host that asked.
bool rx_hook_host_line(const char* cmd, char* line, uint32_t now, HostSrc src) {
  if (!strcmp(cmd, "set_time")) {
    uint32_t utc = 0;
    if (!json_field_utc(line, &utc)) {   // missing, 0, negative, before 2024: refuse
      if (strstr(line, "\"utc\""))
        host_print_to(src, "{\"type\":\"time\",\"set\":false,\"rtc\":null,\"err\":\"bad utc\"}\n");
      return true;
    }
    time_t epoch = (time_t)utc;
    bool set = periph_set_utc_time_host(epoch);
    // Answer with what the RTC chip holds, read back after the write:
    // the time that survives a reset. null when there is no chip, the
    // write failed, or the chip flags its time as lost, so a host can say
    // so rather than trust the running clock, which a reset discards.
    char rtc[24];
    if (set && periph_rtc_iso(rtc, sizeof(rtc)))
      host_printf_to(src, "{\"type\":\"time\",\"utc\":%lu,\"set\":true,\"rtc\":\"%s\"}\n", (unsigned long)epoch, rtc);
    else
      host_printf_to(src, "{\"type\":\"time\",\"utc\":%lu,\"set\":%s,\"rtc\":null}\n",
                     (unsigned long)epoch, set ? "true" : "false");
    return true;
  }
  if (net_host_line(cmd, line, (uint8_t)src)) return true;   // wifi_* (net_sync.h)
  return tile_store_host_line(cmd, line, now, src);
}
void rx_hook_track(Track*, bool, bool) {}   // the board re-reads the table on its own cadence

static int batt_pct() { return periph_batt_pct(); }

void setup() {
  // Host lines run to 1.6 KB (TFR polygons, tile chunks) and a push is
  // several of them in one USB burst. The CDC queue only has to hold what
  // arrives between two passes of rx_core's drain task (RX_SERIAL_DRAIN,
  // every millisecond, into PSRAM): 2 KB, and every KB of internal RAM
  // counts on this board.
  Serial.setRxBufferSize(2048);
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
    // Once per basemap change: this board's .png tiles came from CARTO,
    // which now serves "API KEY REQUIRED" placeholders; the map is Esri JPEG.
    uint32_t gone = tile_store_check_source(true);
    if (gone) Serial.printf("[ORECCHINO] tiles: removed %lu entries from the old basemap (now %s)\n",
                            (unsigned long)gone, TILE_SOURCE_ID);
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
    t5_net_begin(false);
  } else {
    char extra[64];
    snprintf(extra, sizeof(extra), ",\"display\":%s,\"vcom\":%u,\"mode\":\"rx\"", disp ? "true" : "false", (unsigned)vcom);
    rx_begin(extra);
    t5_net_begin(true);
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
            rx_hook_host_line(cmd, s_tx_buf, now, SRC_SERIAL);
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
    net_tick(now);   // answers wifi_* and the Wi-Fi screens; no station in beacon mode
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
  net_tick(now);
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

