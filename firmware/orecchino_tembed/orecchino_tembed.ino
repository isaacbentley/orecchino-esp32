// orecchino_tembed — handheld Remote ID tool on the LilyGO T-Embed CC1101.
// Target: ESP32-S3R8 (esp32:esp32:esp32s3, 16 MB flash, OPI PSRAM, USB CDC)
//
// Two jobs, chosen from a boot menu (hold the knob) and remembered in NVS:
//   * RECEIVER — the shared radio core (firmware/common/rx_core.h): Wi-Fi +
//     BLE capture, decode, the track table, the JSON feed. Console on the
//     strip (ui_tembed.cpp), the LED ring as a threat halo, a CC1101 sweep
//     for the spectrum view.
//   * TEST BEACON — the shared transmit core (firmware/common/tx_core.h):
//     ten Remote ID variants across five air interfaces, each independently
//     switchable from the screen, for bench-testing other receivers.
//
// The two modes bring the radios up differently, so switching reboots into
// the other mode rather than reconfiguring live. Both cores are compiled in;
// only the selected one is started.
#include <Arduino.h>
#include <Wire.h>
#include <Preferences.h>
#define FW_BOARD "lilygo-tembed-cc1101"
#define ORECCHINO_BOARD_HOOKS
#include "../common/rx_core.h"
#include "../common/tx_core.h"
#include "../common/bq27220.h"
#include "../common/bq27220_profiles.h"
#include "board_tembed.h"
#include "ui_tembed.h"

static uint8_t g_mode = UI_MODE_RX;
static int batt_pct_cached(uint32_t now);

// ---- receiver hooks (unused in beacon mode; the core just never calls them)
void rx_hook_wifi_frame(uint8_t chan, int8_t rssi) { ui_feed_wifi(chan, rssi); }
bool rx_hook_paused() { return ui_spectrum_active(); }
bool rx_hook_host_line(const char* cmd, char*, uint32_t, HostSrc src) {
  if (strncmp(cmd, "fs_", 3) != 0) return false;
  host_print_to(src, "{\"type\":\"fs_err\",\"msg\":\"no tile store on this board\"}\n");
  return true;   // no map here: decline the sync instead of letting it time out
}
void rx_hook_track(Track*, bool, bool) {}

// ---- transmit interface for the UI (this file is the sole includer of
// tx_core.h, so the enable mask has exactly one definition).
int         txui_count() { return tx_path_count(); }
const char* txui_id(int i) { return tx_path_id(i); }
const char* txui_carrier(int i) { return tx_path_carrier(i); }
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
  delay(30);
  ESP.restart();
}

// ---- BQ27220 fuel gauge (firmware/common/bq27220.h)
static bool gauge_write(uint8_t reg, const uint8_t* data, size_t n) {
  Wire.beginTransmission(BQ27220_ADDR);
  Wire.write(reg);
  Wire.write(data, n);
  return Wire.endTransmission() == 0;
}
static bool gauge_read(uint8_t reg, uint8_t* data, size_t n) {
  Wire.beginTransmission(BQ27220_ADDR);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) return false;
  if (Wire.requestFrom((int)BQ27220_ADDR, (int)n) != (int)n) return false;
  for (size_t i = 0; i < n; i++) data[i] = (uint8_t)Wire.read();
  return true;
}
static void gauge_sleep(uint32_t ms) { delay(ms); }
static const bq27220::Io kGaugeIo = { gauge_write, gauge_read, gauge_sleep };

// Check the gauge against the 1300 mAh cell's profile and rewrite it on any
// difference (~60 ms when it matches, ~5 s the one time it does not).
// Unconfigured, it counts against TI's generic profile and its percentage
// drifts away from the cell.
static void gauge_begin() {
  const size_t n = sizeof(bq27220::kTEmbedProfile) / sizeof(bq27220::kTEmbedProfile[0]);
  bq27220::provision(kGaugeIo, bq27220::kTEmbedProfile, n);
}

// StateOfCharge() in percent, -1 if the gauge does not answer.
static int batt_pct() { return bq27220::soc_pct(kGaugeIo); }

void setup() {
  pinMode(PIN_PWR_EN, OUTPUT);
  digitalWrite(PIN_PWR_EN, HIGH);   // CC1101 + LED ring rail
  // Host lines run to 1.6 KB (TFR polygons, tile chunks) and land in one
  // USB burst; the default CDC ring buffer cannot hold one whole line.
  Serial.setRxBufferSize(4096);
  Serial.begin(115200);
  uint32_t t0 = millis();
  // A connected host enumerates in well under 300 ms; on battery there is
  // no host, and a long wait here is a dead knob after power-on.
  while (!Serial && millis() - t0 < 300) delay(10);
  Wire.begin(PIN_I2C_SDA, PIN_I2C_SCL);
  Wire.setTimeOut(50);   // a sulking gauge must never stall the loop

  Preferences p; p.begin("orecchino", true);
  g_mode = p.getUChar("mode", UI_MODE_RX);
  p.end();
  if (g_mode > UI_MODE_TX) g_mode = UI_MODE_RX;

  bool disp = ui_begin(g_mode);
  gauge_begin();   // after the screen is up: the one-time rewrite takes ~5 s
  if (g_mode == UI_MODE_TX) {
    tx_begin();
  } else {
    rx_begin(disp ? ",\"display\":true,\"mode\":\"rx\"" : ",\"display\":false,\"mode\":\"rx\"");
  }
  ui_flush_input();   // knob counts made during the radio bring-up are noise
}

void loop() {
  uint32_t now = millis();

  if (g_mode == UI_MODE_TX) {
    tx_tick(now);
    ui_tick(now, true, batt_pct_cached(now));
    delay(2);
    return;
  }

  // Spectrum view: the core stops hopping while paused; sweep 1-13 evenly.
  static uint32_t last_spec_hop = 0;
  static uint8_t spec_ch = 13;
  if (ui_spectrum_active() && now - last_spec_hop >= 110) {
    last_spec_hop = now;
    spec_ch = (uint8_t)(spec_ch % 13) + 1;
    rx_set_channel(spec_ch);
    ui_set_wifi_channel(spec_ch);
  }

  rx_tick(now);
  RxStats st;
  rx_stats(&st);
  ui_tick(now, st.ble_ok, batt_pct_cached(now));
  delay(3);
}

// One gauge read every 10 s, shared by both loops.
static int batt_pct_cached(uint32_t now) {
  static int batt = -1;
  static uint32_t last = 0;
  if (last == 0 || now - last >= 10000) { last = now; batt = batt_pct(); }
  return batt;
}
