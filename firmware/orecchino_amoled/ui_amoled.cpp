#include "ui_amoled.h"
#include "board_amoled.h"
#include "../common/ui_common.h"
#include <Wire.h>
#include <Arduino_GFX_Library.h>
#include <Adafruit_GFX.h>  // for its Fonts/ (GFXfont layout is shared)
#include <Fonts/FreeSansBold9pt7b.h>
#include <Fonts/FreeSansBold12pt7b.h>
#include <Fonts/FreeSansBold18pt7b.h>

#define W LCD_W
#define H LCD_H
#define TOP_H 64
#define CARD_Y 70
#define CARD_H 82
#define CARD_P 90
#define CARDS  4
#define BOT_Y  424
#define BRIGHT 200
#define DIM    40

static Arduino_DataBus* s_bus;
// Two board revisions ship under the same product name: an older one with a
// SH8601 controller and FT3168 touch (I2C 0x38), a newer one with a CO5300
// controller and CST816 touch (0x15). Both panel drivers derive from
// Arduino_OLED (virtual setBrightness), so one base pointer serves either;
// the touch chip that answers on I2C tells us which revision — and so which
// panel driver to build — since the QSPI panel has no address to probe.
static Arduino_OLED*    s_panel;         // the AMOLED controller (brightness, flush target)
// All drawing goes to an 8-bit palette canvas and reaches the panel as one
// full-width bitmap per frame. These QSPI AMOLED controllers drop writes at
// odd column addresses, so per-pixel glyph drawing straight to the panel
// loses text (shapes survive because they are bulk even-aligned windows);
// a canvas sidesteps that entirely, and 165 KB fits the C6 without PSRAM.
static Arduino_GFX*     s_gfx;
static uint8_t          s_tp_addr = 0;   // 0x38 FT3168 / 0x15 CST816, 0 = none
enum View : uint8_t { V_LIST, V_DETAIL, V_SPECTRUM };
static View s_view = V_LIST;
static int  s_sel = 0, s_scroll = 0, s_n = 0, s_order[TRK_MAX];
static uint32_t s_now, s_last_touch = 0;
static bool s_ble_ok = true;
static int  s_batt = -1;
static bool s_dirty = true;
static uint32_t s_card_sig[CARDS], s_top_sig = 0, s_bot_sig = 0;
static uint8_t s_bright = BRIGHT;

// ---- spectrum (2.4 GHz only: the C6 has no sub-GHz radio)
#define N_CH 13
#define WF_ROWS 36
static volatile bool s_spec = false;
static volatile int32_t s_wsum[N_CH + 1];
static volatile uint16_t s_wcnt[N_CH + 1];
static volatile uint8_t s_dwell = 0;
static float   s_a24[N_CH];
static uint8_t s_wf[WF_ROWS][13];
static int     s_wf_head = 0;
void ui_feed_wifi(uint8_t chan, int8_t rssi) { if (s_spec && chan >= 1 && chan <= N_CH) { s_wsum[chan] += rssi; s_wcnt[chan]++; } }
void ui_set_wifi_channel(uint8_t chan) { s_dwell = chan; }
bool ui_spectrum_active() { return s_spec; }

// ---- helpers
static void txt(const GFXfont* f, int x, int y, uint16_t c, const char* s) {
  s_gfx->setFont(f); s_gfx->setTextSize(1); s_gfx->setTextColor(c);
  s_gfx->setCursor(x, y); s_gfx->print(s);
}
static int txt_w(const GFXfont* f, const char* s) {
  int16_t x, y; uint16_t w, h;
  s_gfx->setFont(f); s_gfx->setTextSize(1);
  s_gfx->getTextBounds(s, 0, 0, &x, &y, &w, &h);
  return w;
}
static void meter(int x, int y, int w, int rssi, uint16_t col) {
  s_gfx->fillRect(x, y, w, 4, C_METER);
  s_gfx->fillRect(x, y, (int)(w * ui_rssi01(rssi)), 4, col);
}
static uint16_t heat(uint8_t v) {  // 0..255 -> black-blue-cyan-yellow-white
  v &= 0xF8;                        // 32 steps: an indexed canvas has 256 slots
  if (v < 64)  return RGB565(0, 0, v * 2);
  if (v < 128) return RGB565(0, (v - 64) * 4, 128 + (v - 64) * 2);
  if (v < 192) return RGB565((v - 128) * 4, 255, 255 - (v - 128) * 4);
  return RGB565(255, 255, (v - 192) * 4);
}

static void build_order() {
  s_n = 0;
  for (int i = 0; i < TRK_MAX; i++) if (g_tracks[i].used) s_order[s_n++] = i;
  auto rank = [](const Track* t) {
    return (ui_danger(t, s_now) ? 0 : ui_stale(t, s_now) ? 2 : 1) * 1000000000ULL + (uint64_t)(s_now - t->last_ms);
  };
  for (int a = 1; a < s_n; a++) {
    int v = s_order[a], b = a - 1;
    while (b >= 0 && rank(&g_tracks[s_order[b]]) > rank(&g_tracks[v])) { s_order[b + 1] = s_order[b]; b--; }
    s_order[b + 1] = v;
  }
  int max_scroll = s_n > CARDS ? s_n - CARDS : 0;
  if (s_scroll > max_scroll) s_scroll = max_scroll;
  if (s_scroll < 0) s_scroll = 0;
  if (s_sel >= s_n) s_sel = s_n ? s_n - 1 : 0;
}

static uint32_t track_sig(const Track* t) {
  uint32_t h = 2166136261u;
  auto mix = [&](uint32_t v) { h ^= v; h *= 16777619u; };
  for (const char* p = t->uas; *p; p++) mix((uint8_t)*p);
  mix(t->rssi); mix(isnan(t->height) ? 0xFFFF : (int)t->height);
  mix(isnan(t->speed) ? 0xFFFF : (int)(t->speed * 10));
  mix((uint32_t)(int32_t)(t->lat * 1e5)); mix((uint32_t)(int32_t)(t->lon * 1e5));
  mix(t->status); mix(t->auth_state); mix(t->in_tfr); mix(ui_stale(t, s_now));
  mix((s_now - t->last_ms) / 1000); mix(t->src_mask); mix(g_home_set);
  return h;
}

static void draw_top(const UiSummary& sm, const char* title) {
  uint32_t sig = sm.alert * 7919 + sm.tracked * 131 + g_seen_count * 17 + s_batt + (s_ble_ok ? 1 : 0) + (title ? 3 : 0);
  if (sig == s_top_sig && !s_dirty) return;
  s_top_sig = sig;
  uint16_t bg = sm.alert == UI_EMERGENCY ? RGB565(0x6E, 0x14, 0x14) : sm.alert == UI_CONTACT ? C_AMBER : C_BG;
  uint16_t fg = sm.alert == UI_EMERGENCY ? RGB565(0xFF, 0xE2, 0xE2) : sm.alert == UI_CONTACT ? RGB565(0x1A, 0x12, 0x02) : C_TEXT;
  uint16_t mut = sm.alert == UI_EMERGENCY ? RGB565(0xD8, 0x9A, 0x9A) : sm.alert == UI_CONTACT ? RGB565(0x5E, 0x48, 0x10) : C_MUTED;
  s_gfx->fillRect(0, 0, W, TOP_H, bg);
  char b[40];
  if (title) snprintf(b, sizeof(b), "%.20s", title); else ui_headline(b, sizeof(b), &sm);
  txt(&FreeSansBold12pt7b, 18, 30, fg, b);
  int x = 12;
  if (g_seen_count) { snprintf(b, sizeof(b), "%lu seen", (unsigned long)g_seen_count); txt(&FreeSansBold9pt7b, x, 54, mut, b); x += txt_w(&FreeSansBold9pt7b, b) + 16; }
  if (s_batt >= 0) { snprintf(b, sizeof(b), "%d%%", s_batt); txt(&FreeSansBold9pt7b, x, 54, s_batt <= 15 ? C_DANGER : mut, b); }
  s_gfx->fillCircle(W - SAFE_X - 4, 26, 6, s_ble_ok ? (sm.active ? RGB565(0x1E, 0x64, 0x28) : C_OK) : C_DANGER);  // clear of the corner
  if (!s_ble_ok) txt(&FreeSansBold9pt7b, W - SAFE_X - 60, 54, C_DANGER, "RX FLT");
}

static void draw_bottom(const UiSummary& sm, const char* hint) {
  uint32_t sig = sm.newest_age_s + (hint ? strlen(hint) * 31 : 0);
  if (sig == s_bot_sig && !s_dirty) return;
  s_bot_sig = sig;
  s_gfx->fillRect(0, BOT_Y, W, H - BOT_Y, C_BAR);
  char b[40];
  if (sm.newest_age_s == UINT32_MAX) snprintf(b, sizeof(b), "SCANNING");
  else snprintf(b, sizeof(b), "LAST RX %lus", (unsigned long)sm.newest_age_s);
  txt(&FreeSansBold9pt7b, SAFE_X, BOT_Y + 17, C_MUTED, b);
  if (hint) txt(&FreeSansBold9pt7b, W - SAFE_X - txt_w(&FreeSansBold9pt7b, hint), BOT_Y + 17, C_MUTED, hint);
}

static void draw_card(int slot, const Track* t) {
  int y = CARD_Y + slot * CARD_P;
  uint32_t sig = t ? track_sig(t) ^ (uint32_t)(s_order[s_scroll + slot] * 977) : 0;
  if (sig == s_card_sig[slot] && !s_dirty) return;
  s_card_sig[slot] = sig;
  s_gfx->startWrite();
  if (!t) { s_gfx->fillRect(0, y, W, CARD_P, C_BG); s_gfx->endWrite(); return; }
  bool stale = ui_stale(t, s_now), danger = ui_danger(t, s_now);
  uint16_t col = stale ? C_MUTED : danger ? C_DANGER : TRACK_COLORS[s_order[s_scroll + slot] % N_TRACK_COLORS];
  s_gfx->fillRect(0, y, W, CARD_P, C_BG);
  s_gfx->fillRoundRect(8, y, W - 16, CARD_H, 10, C_BAR);
  s_gfx->drawRoundRect(8, y, W - 16, CARD_H, 10, danger ? C_DANGER : C_EDGE);
  s_gfx->fillRect(8, y + 10, 4, CARD_H - 20, col);
  char id[20];
  snprintf(id, sizeof(id), "%.16s", t->uas[0] ? t->uas : "(no id)");
  txt(&FreeSansBold12pt7b, 22, y + 26, stale ? C_MUTED : C_TEXT, id);
  const char* badge = track_auth_badge(t->auth_state);
  if (badge[0]) {
    int bx = W - 60;
    s_gfx->fillRoundRect(bx, y + 10, 44, 20, 5, C_BG);
    s_gfx->drawRoundRect(bx, y + 10, 44, 20, 5, ui_auth_color(t->auth_state));
    txt(&FreeSansBold9pt7b, bx + 6, y + 25, ui_auth_color(t->auth_state),
        badge);
  }
  meter(22, y + 34, W - 50, t->rssi, col);
  char b[48], hb[10] = "--", sb[12] = "--";
  if (!isnan(t->height)) snprintf(hb, sizeof(hb), "%dm", (int)t->height);
  if (!isnan(t->speed))  snprintf(sb, sizeof(sb), "%.1fm/s", t->speed);
  snprintf(b, sizeof(b), "%d dBm   h %s   v %s", t->rssi, hb, sb);
  txt(&FreeSansBold9pt7b, 22, y + 56, C_MUTED, b);
  if (g_home_set && t->has_pos) {
    char r[10]; ui_fmt_range(r, sizeof(r), ui_dist_m(g_home_lat, g_home_lon, t->lat, t->lon));
    snprintf(b, sizeof(b), "%s  brg %03d", r, (int)ui_bearing(g_home_lat, g_home_lon, t->lat, t->lon));
  } else snprintf(b, sizeof(b), "%s", ui_status_name(t->status));
  txt(&FreeSansBold9pt7b, 22, y + 74, t->in_tfr && !stale ? C_DANGER : C_TEXT, b);
  snprintf(b, sizeof(b), "%s%s%s  %us", (t->src_mask & 1) ? "W" : "", (t->src_mask & 2) ? "N" : "",
           (t->src_mask & 4) ? "B" : "", (unsigned)((s_now - t->last_ms) / 1000));
  txt(&FreeSansBold9pt7b, W - 24 - txt_w(&FreeSansBold9pt7b, b), y + 74, C_MUTED, b);
  if (t->in_tfr) txt(&FreeSansBold9pt7b, W - 100, y + 56, C_DANGER, "TFR!");
  s_gfx->endWrite();
}

static void draw_list() {
  UiSummary sm; ui_summarize(&sm, s_now);
  draw_top(sm, nullptr);
  if (!s_n) {
    static uint32_t last_ring = 0;
    static bool cleared = false;
    if (s_dirty || !cleared) { s_gfx->fillRect(0, TOP_H, W, BOT_Y - TOP_H, C_BG); cleared = true; for (auto& c : s_card_sig) c = 1; }
    if (s_now - last_ring >= 50) {  // breathing ring
      last_ring = s_now;
      float ph = 0.5f + 0.5f * sinf(s_now * 2 * PI / 3000.0f);
      int r = 60 + (int)(30 * ph);
      s_gfx->fillRect(W / 2 - 100, 240 - 100, 200, 200, C_BG);
      s_gfx->drawCircle(W / 2, 240, r, RGB565(0x14, 0x3A, 0x36));
      s_gfx->drawCircle(W / 2, 240, r - 12, RGB565(0x0E, 0x28, 0x26));
      txt(&FreeSansBold18pt7b, W / 2 - txt_w(&FreeSansBold18pt7b, "SCANNING") / 2, 250, C_MUTED, "SCANNING");
    }
  } else {
    for (int slot = 0; slot < CARDS; slot++) {
      int k = s_scroll + slot;
      draw_card(slot, k < s_n ? &g_tracks[s_order[k]] : nullptr);
    }
  }
  draw_bottom(sm, s_n > CARDS ? "scroll" : nullptr);
  s_dirty = false;
}

static void draw_detail() {
  if (!s_n) { s_view = V_LIST; s_dirty = true; return; }
  const Track* t = &g_tracks[s_order[s_sel]];
  uint32_t sig = track_sig(t);
  static uint32_t prev = 0;
  if (sig == prev && !s_dirty) return;
  prev = sig;
  UiSummary sm; ui_summarize(&sm, s_now);
  draw_top(sm, t->uas[0] ? t->uas : "(no id)");
  s_gfx->startWrite();
  s_gfx->fillRect(0, TOP_H, W, BOT_Y - TOP_H, C_BG);
  bool danger = ui_danger(t, s_now);
  char b[64];
  int y = 120;
  if (g_home_set && t->has_pos) {
    char r[10]; ui_fmt_range(r, sizeof(r), ui_dist_m(g_home_lat, g_home_lon, t->lat, t->lon));
    txt(&FreeSansBold18pt7b, 16, y, C_TEXT, r);
    snprintf(b, sizeof(b), "%03d", (int)ui_bearing(g_home_lat, g_home_lon, t->lat, t->lon));
    txt(&FreeSansBold18pt7b, 200, y, C_ACCENT, b);
    txt(&FreeSansBold9pt7b, 16, y + 20, C_MUTED, "range");
    txt(&FreeSansBold9pt7b, 200, y + 20, C_MUTED, "bearing");
  } else {
    txt(&FreeSansBold18pt7b, 16, y, t->status == 3 ? C_DANGER : C_TEXT, ui_status_name(t->status));
  }
  y += 44;
  meter(16, y, W - 32, t->rssi, danger ? C_DANGER : C_ACCENT); y += 22;
  snprintf(b, sizeof(b), "%d dBm  (peak %d)", t->rssi, t->peak_rssi); txt(&FreeSansBold9pt7b, 16, y, C_MUTED, b); y += 26;
  char hb[10] = "--", sb[12] = "--";
  if (!isnan(t->height)) snprintf(hb, sizeof(hb), "%d m", (int)t->height);
  if (!isnan(t->speed))  snprintf(sb, sizeof(sb), "%.1f m/s", t->speed);
  snprintf(b, sizeof(b), "height %s   speed %s", hb, sb); txt(&FreeSansBold9pt7b, 16, y, C_TEXT, b); y += 22;
  snprintf(b, sizeof(b), "status %s", ui_status_name(t->status)); txt(&FreeSansBold9pt7b, 16, y, t->status == 3 ? C_DANGER : C_TEXT, b); y += 22;
  if (t->has_pos) {
    snprintf(b, sizeof(b), "%.6f, %.6f", t->lat, t->lon); txt(&FreeSansBold9pt7b, 16, y, C_MUTED, b); y += 22;
  }
  if (t->auth_state) { txt(&FreeSansBold9pt7b, 16, y, ui_auth_color(t->auth_state), ui_auth_text(t->auth_state)); y += 22; }
  if (t->in_tfr) { snprintf(b, sizeof(b), "INSIDE TFR %s", t->tfr_id); txt(&FreeSansBold9pt7b, 16, y, C_DANGER, b); y += 22; }
  snprintf(b, sizeof(b), "%02X:%02X:%02X:%02X:%02X:%02X", t->mac[0], t->mac[1], t->mac[2], t->mac[3], t->mac[4], t->mac[5]);
  txt(&FreeSansBold9pt7b, 16, y, C_MUTED, b); y += 22;
  snprintf(b, sizeof(b), "src %s%s%s   msgs %u   %us ago", (t->src_mask & 1) ? "W" : "", (t->src_mask & 2) ? "N" : "",
           (t->src_mask & 4) ? "B" : "", t->msgs, (unsigned)((s_now - t->last_ms) / 1000));
  txt(&FreeSansBold9pt7b, 16, y, C_MUTED, b);
  s_gfx->endWrite();
  draw_bottom(sm, "tap: back");
  s_dirty = false;
}

static void draw_spectrum() {
  UiSummary sm = {}; sm.alert = UI_QUIET; sm.newest_age_s = UINT32_MAX;
  draw_top(sm, "2.4 GHz SPECTRUM");
  txt(&FreeSansBold9pt7b, 12, 54, C_MUTED, "Wi-Fi only");
  for (int c = 1; c <= 13; c++) {
    uint16_t cnt = s_wcnt[c];
    int32_t sum = s_wsum[c];
    s_wcnt[c] = 0;
    s_wsum[c] = 0;
    if (cnt) s_a24[c - 1] = s_a24[c - 1] * 0.5f + ((float)sum / cnt) * 0.5f;
    else if (c == s_dwell) s_a24[c - 1] = s_a24[c - 1] * 0.8f - 115 * 0.2f;
    else s_a24[c - 1] -= 0.5f;
    if (s_a24[c - 1] < -115) s_a24[c - 1] = -115;
  }
  // bars
  const int BW = 26, X0 = 15, BASE = 230, BH = 140;
  s_gfx->startWrite();
  for (int c = 0; c < 13; c++) {
    float v = (s_a24[c] + 115) / 70.0f; v = v < 0 ? 0 : v > 1 ? 1 : v;
    int h = (int)(BH * v), x = X0 + c * BW;
    s_gfx->fillRect(x, BASE - BH, BW - 3, BH - h, C_BG);
    s_gfx->fillRect(x, BASE - h, BW - 3, h, c + 1 == s_dwell ? C_ACCENT : RGB565(0x2A, 0x7A, 0x9A));
  }
  // waterfall: one row per frame, newest at the top
  s_wf_head = (s_wf_head + WF_ROWS - 1) % WF_ROWS;
  for (int c = 0; c < 13; c++) { float v = (s_a24[c] + 115) / 70.0f; v = v < 0 ? 0 : v > 1 ? 1 : v; s_wf[s_wf_head][c] = (uint8_t)(255 * v); }
  for (int r = 0; r < WF_ROWS; r++) {
    const uint8_t* row = s_wf[(s_wf_head + r) % WF_ROWS];
    for (int c = 0; c < 13; c++) s_gfx->fillRect(X0 + c * BW, BASE + 12 + r * 4, BW - 3, 4, heat(row[c]));
  }
  s_gfx->endWrite();
  for (int c = 0; c < 13; c += 2) { char b[4]; snprintf(b, sizeof(b), "%d", c + 1); txt(&FreeSansBold9pt7b, X0 + c * BW + 4, BASE + 12 + WF_ROWS * 4 + 18, C_MUTED, b); }
  draw_bottom(sm, "tap: back");
  s_dirty = false;
}

// ---- touch (FT3168, FocalTech register layout)
static bool touch_read(int* x, int* y) {
  if (!s_tp_addr) return false;
  Wire.beginTransmission(s_tp_addr);
  Wire.write(0x02);                      // FT3168 and CST816 share this layout
  if (Wire.endTransmission(false) != 0) return false;
  if (Wire.requestFrom((int)s_tp_addr, 5) != 5) return false;
  uint8_t r[5];
  for (auto& v : r) v = Wire.read();
  if ((r[0] & 0x0F) == 0) return false;
  *x = ((r[1] & 0x0F) << 8) | r[2];
  *y = ((r[3] & 0x0F) << 8) | r[4];
  return true;
}

static void iox_write(uint8_t reg, uint8_t v) {
  Wire.beginTransmission(TCA9554_ADDR); Wire.write(reg); Wire.write(v); Wire.endTransmission();
}

static bool i2c_present(uint8_t a) {
  Wire.beginTransmission(a);
  return Wire.endTransmission() == 0;
}

bool ui_begin() {
  pinMode(PIN_BOOT_BTN, INPUT_PULLUP);
  pinMode(PIN_TP_INT, INPUT_PULLUP);
  // Which revision? The touch chip that answers decides panel + touch driver.
  bool co5300 = !i2c_present(0x38);           // no FT3168 -> newer CO5300 rev
  s_tp_addr = i2c_present(0x38) ? 0x38 : i2c_present(0x15) ? 0x15 : 0;
  // TCA9554: P4 = display power, P5 = touch power. This board has no panel
  // reset line — power-cycling P4 IS the reset — so pulse low, then hold high
  // and wait 500 ms for the controller to come up before any QSPI init (a
  // shorter wait leaves the panel dark because init runs before it is ready).
  iox_write(0x03, (uint8_t)~((1 << IOX_LCD_PWR) | (1 << IOX_TP_PWR)));  // P4/P5 output
  iox_write(0x01, 0x00);                                               // power off
  delay(60);
  iox_write(0x01, (1 << IOX_LCD_PWR) | (1 << IOX_TP_PWR));             // power on
  delay(500);
  s_bus = new Arduino_ESP32QSPI(PIN_LCD_CS, PIN_LCD_SCK, PIN_LCD_D0, PIN_LCD_D1, PIN_LCD_D2, PIN_LCD_D3);
  // Pick the panel driver from the detected revision. CO5300 needs a 16-px
  // column offset; SH8601 starts at 0.
  if (co5300) s_panel = new Arduino_CO5300(s_bus, GFX_NOT_DEFINED, 0, LCD_W, LCD_H, 16, 0, 0, 0);
  else        s_panel = new Arduino_SH8601(s_bus, GFX_NOT_DEFINED, 0, LCD_W, LCD_H);
  // The canvas's begin() initialises its output (the panel + QSPI bus) itself;
  // calling the panel's begin() as well re-inits the SPI bus and aborts.
  Arduino_Canvas_Indexed* cv = new Arduino_Canvas_Indexed(LCD_W, LCD_H, s_panel);
  if (!cv->begin()) return false;      // panel init + the 165 KB framebuffer
  s_gfx = cv;
  s_panel->setBrightness(0);           // dark while the first frame is painted
  s_gfx->fillScreen(C_BG);
  s_gfx->flush();
  s_panel->setBrightness(255);
  s_last_touch = millis();
  Serial.printf("{\"type\":\"panel\",\"driver\":\"%s\",\"touch\":\"0x%02X\"}\n",
                co5300 ? "co5300" : "sh8601", s_tp_addr);
  return true;
}

void ui_tick(uint32_t now, bool ble_ok, int batt_pct) {
  s_now = now; s_ble_ok = ble_ok; s_batt = batt_pct;

  // touch: tap vs drag
  static bool t_was = false; static int tx0 = 0, ty0 = 0, ty_last = 0; static bool dragged = false;
  static uint32_t t_last_poll = 0;
  if (now - t_last_poll >= 25) {
    t_last_poll = now;
    int x, y;
    bool t = touch_read(&x, &y);
    if (t && !t_was) { tx0 = x; ty0 = y; ty_last = y; dragged = false; }
    if (t && t_was && s_view == V_LIST && abs(y - ty0) > 16) {
      dragged = true;
      int dr = (ty_last - y) / 36;
      if (dr) { s_scroll += dr; ty_last -= dr * 36; s_dirty = true; }
    }
    if (!t && t_was) {
      s_last_touch = now;
      if (!dragged) {  // tap
        if (s_view == V_SPECTRUM) { s_spec = false; s_view = V_LIST; }
        else if (s_view == V_DETAIL) s_view = V_LIST;
        else if (ty0 >= CARD_Y && ty0 < BOT_Y) {
          int k = s_scroll + (ty0 - CARD_Y) / CARD_P;
          if (k < s_n) { s_sel = k; s_view = V_DETAIL; }
        }
        s_dirty = true;
      } else if (s_view == V_LIST) {
        // Catch quick swipe flick on release
        int dy = ty0 - y;
        if (abs(dy) > 28) {
          s_scroll += (dy > 0 ? 1 : -1);
          s_dirty = true;
        }
      }
    }
    if (t) s_last_touch = now;
    t_was = t;
  }
  // BOOT button: tap = back to the list, hold 1.5 s = spectrum
  static bool k_was = false; static uint32_t k_down = 0; static bool k_fired = false;
  bool k = digitalRead(PIN_BOOT_BTN) == LOW;
  if (k && !k_was) { k_down = now; k_fired = false; }
  if (k && !k_fired && now - k_down > 1500) {
    k_fired = true;
    if (s_view != V_SPECTRUM) {
      memset((void*)s_wsum, 0, sizeof(s_wsum)); memset((void*)s_wcnt, 0, sizeof(s_wcnt));
      memset(s_a24, 0, sizeof(s_a24)); memset(s_wf, 0, sizeof(s_wf));
      s_gfx->fillScreen(C_BG);
      s_spec = true; s_view = V_SPECTRUM;
    } else { s_spec = false; s_view = V_LIST; }
    s_dirty = true; s_last_touch = now;
  }
  if (!k && k_was && !k_fired && now - k_down > 30) { s_view = V_LIST; s_spec = false; s_dirty = true; s_last_touch = now; }
  k_was = k;

  // idle dimming (a live danger keeps the panel bright)
  UiSummary sm; ui_summarize(&sm, now);
  uint8_t want = (now - s_last_touch > 30000 && !sm.danger) ? DIM : BRIGHT;
  if (want != s_bright) { s_bright = want; s_panel->setBrightness(want); }

  static uint32_t last = 0;
  if (s_view == V_SPECTRUM) {
    if (now - last >= 250) { last = now; if (s_dirty) s_gfx->fillScreen(C_BG); draw_spectrum(); s_gfx->flush(); }
    return;
  }
  if (s_dirty || now - last >= 500) {
    last = now;
    build_order();
    if (s_dirty) { s_gfx->fillScreen(C_BG); s_top_sig = s_bot_sig = 0; for (auto& c : s_card_sig) c = 1; }
    if (s_view == V_DETAIL) draw_detail(); else draw_list();
    s_gfx->flush();
  } else if (!s_n && s_view == V_LIST) { draw_list(); s_gfx->flush(); }  // keep the ring breathing
}
