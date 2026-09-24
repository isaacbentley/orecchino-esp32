#include "ui_tembed.h"
#include "board_tembed.h"
#include "soc/gpio_struct.h"
#include "ring.h"
#include "cc1101_sweep.h"
#include "../common/ui_common.h"
#include "../common/solar.h"
#include <time.h>
#include "esp_sleep.h"
#include <Arduino_GFX_Library.h>
#include <Adafruit_GFX.h>  // for its Fonts/ (GFXfont layout is shared)
#include <Fonts/FreeSansBold9pt7b.h>
#include <Fonts/FreeSansBold12pt7b.h>

// From the receiver core (rx_core.h, in the sketch's translation unit).
void rx_log_flush();
void rx_log_clear_all();                              // clear, save now, tell every host
void rx_log_stats(int* held, uint32_t* oldest_age_s);

#define W 320
#define H 170
#define TOP 21
#define LIST_W 186
#define ROW_H 29
#define ROWS 5

static Arduino_DataBus* s_bus;
static Arduino_GFX*     s_gfx;
static Arduino_Canvas*  s_cv;

enum View : uint8_t { V_SCOPE, V_DETAIL, V_SPECTRUM, V_TX, V_MENU };
static View     s_view = V_SCOPE;
static uint8_t  s_mode = UI_MODE_RX;
static bool     s_night_mode = false;
static uint32_t s_last_solar_eval = 0;
static int      s_tx_sel = 0;     // row in the TX list (0 master, 1 emg, 2 rate, 3+ paths)
static int      s_menu_sel = 0;
// Menu rows: 0 Receiver, 1 Test beacon, 2 Brightness, 3 Clear history,
// 4 Power off, 5 Back. Five fit on screen; the list scrolls to the choice.
#define MENU_N       6
#define MENU_CLEAR   3
#define MENU_POWER   4
#define MENU_BACK    5
static bool     s_clear_ask = false;   // the "clear history?" step is showing
static int      s_clear_sel = 0;       // 0 CANCEL (the default), 1 CLEAR
static uint32_t s_cleared_ms = 0;      // when the menu cleared the history...
static bool     s_cleared = false;     // ..."history cleared" shows for 5 s after (wrap-safe)
static int      s_sel = 0;        // selected row (index into the ordered list)
static UiSel    s_selid = {-1, 0}; // ...and the aircraft on it, which survives re-sorting
static int      s_scroll = 0;
static int      s_order[TRK_MAX]; // track indices: danger, live, history; by arrival within
static int      s_n = 0;
static uint32_t s_now;
static bool     s_ble_ok = true;
static int      s_batt = -1;
static const uint8_t BL_LEVELS[] = { 255, 110, 64 };   // lowest step must still read as ON
static uint8_t  s_bl = 0;
static uint32_t s_bl_toast_until = 0;
static bool     s_dirty = true;
static volatile bool s_flush_input = false;
static uint32_t s_last_input = 0;   // idle dimming: a battery handheld should not
static bool     s_dimmed = false;   // burn its backlight on an empty sky

// ---- encoder (mathertel TWO03 latch mode for T-Embed rotary encoder)
static volatile int32_t s_enc_pos = 0;
static volatile int32_t s_raw_pos = 0;
static volatile int8_t  s_old_state = -1;

static inline void enc_step() {
  int sig1 = gpio_get_level((gpio_num_t)PIN_ENC_A);
  int sig2 = gpio_get_level((gpio_num_t)PIN_ENC_B);
  int8_t thisState = (sig1 & 1) | ((sig2 & 1) << 1);
  if (s_old_state < 0) {
    s_old_state = thisState;
    return;
  }
  if (s_old_state != thisState) {
    static const int8_t KNOBDIR[16] = {
      0, -1, 1, 0,
      1, 0, 0, -1,
      -1, 0, 0, 1,
      0, 1, -1, 0
    };
    s_raw_pos += KNOBDIR[thisState | (s_old_state << 2)];
    if (thisState == 0 || thisState == 3) {
      s_enc_pos = s_raw_pos >> 1;
    }
    s_old_state = thisState;
  }
}

static void IRAM_ATTR enc_isr() {
  enc_step();
}

// ---- spectrum feeds
#define N_CH 13
static volatile bool    s_spec_on = false;
static volatile int32_t s_wsum[N_CH + 1];
static volatile uint16_t s_wcnt[N_CH + 1];
static volatile uint8_t s_dwell = 0;
static float  s_a24[N_CH];
static int8_t s_swp[CC_SWEEP_BINS];
static float  s_pk[CC_SWEEP_BINS];
static int    s_cursor = 0, s_mark = 64;
static bool   s_cc_ok = false;

void ui_feed_wifi(uint8_t chan, int8_t rssi) {
  if (!s_spec_on || chan < 1 || chan > N_CH) return;
  s_wsum[chan] += rssi;
  s_wcnt[chan] += 1;
}
void ui_set_wifi_channel(uint8_t chan) { s_dwell = chan; }
bool ui_spectrum_active() { return s_spec_on; }

// ---- ordering: danger first, then live contacts, then history (shared
// with every board); the selection follows its aircraft, not its row.
static void build_order() {
  ui_order_build(s_order, &s_n, s_now);
  int row = ui_sel_row(&s_selid, s_order, s_n);
  if (row < 0) {                            // gone, or nothing chosen yet
    row = 0;
    ui_sel_set(&s_selid, s_n ? s_order[0] : -1);
  }
  s_sel = row;
  if (s_sel < s_scroll) s_scroll = s_sel;
  if (s_sel >= s_scroll + ROWS) s_scroll = s_sel - ROWS + 1;
}

// Send only the rows that changed since the last frame. The SPI link, not
// the CPU, is what a frame costs here (320x170 at 16 bits over 40 MHz SPI is
// ~22 ms), and most redraws change a clock digit and a meter. Rows are
// compared against a copy of what the panel shows, in 10-row bands, and runs
// of changed bands go out as one transfer.
static uint16_t* s_shown = nullptr;
static uint32_t  s_rows_sent = 0;   // for the host render check
static void present() {
  uint16_t* fb = s_cv->getFramebuffer();
  if (!s_shown) s_shown = (uint16_t*)ps_malloc((size_t)W * H * 2);
  if (!s_shown) { s_cv->flush(); return; }   // no spare memory: whole frames
  static bool primed = false;
  const int BAND = 10;
  for (int y = 0; y < H;) {
    int bh = min(BAND, H - y);
    size_t off = (size_t)y * W;
    if (primed && !memcmp(fb + off, s_shown + off, (size_t)bh * W * 2)) { y += bh; continue; }
    int y1 = y + bh;
    while (y1 < H) {
      int b2 = min(BAND, H - y1);
      if (primed && !memcmp(fb + (size_t)y1 * W, s_shown + (size_t)y1 * W, (size_t)b2 * W * 2)) break;
      y1 += b2;
    }
    s_gfx->draw16bitRGBBitmap(0, y, fb + off, W, y1 - y);
    memcpy(s_shown + off, fb + off, (size_t)(y1 - y) * W * 2);
    s_rows_sent += (uint32_t)(y1 - y);
    y = y1;
  }
  primed = true;
}

static void small(int x, int y, uint16_t c, const char* s) {
  s_cv->setFont(nullptr); s_cv->setTextSize(1); s_cv->setTextColor(c);
  s_cv->setCursor(x, y); s_cv->print(s);
}
static void bold(int x, int y, uint16_t c, const char* s, const GFXfont* f = &FreeSansBold9pt7b) {
  s_cv->setFont(f); s_cv->setTextSize(1); s_cv->setTextColor(c);
  s_cv->setCursor(x, y); s_cv->print(s);
  s_cv->setFont(nullptr);
}
/// Width in pixels of `s` in `f` (nullptr: the 6 px classic font).
static int text_px(const char* s, const GFXfont* f) {
  if (!f) return (int)strlen(s) * 6;
  int w = 0;
  for (; *s; s++) {
    uint8_t c = (uint8_t)*s;
    if (c >= f->first && c <= f->last) w += f->glyph[c - f->first].xAdvance;
  }
  return w;
}
/// Shorten `b` in place, ending in "..", until it fits `maxw` pixels.
static void fit(char* b, size_t cap, int maxw, const GFXfont* f) {
  if (text_px(b, f) <= maxw) return;
  for (size_t n = strlen(b); n > 0; n--) {
    b[n - 1] = 0;
    if (strlen(b) + 3 > cap) continue;
    strcat(b, "..");
    if (text_px(b, f) <= maxw) return;
    b[strlen(b) - 2] = 0;
  }
}
/// Small north-up compass: a ring with an N tick and a needle on `brg`.
static void needle(int cx, int cy, int r, double brg, uint16_t col) {
  s_cv->drawCircle(cx, cy, r, C_EDGE);
  s_cv->drawFastVLine(cx, cy - r - 3, 3, C_MUTED);   // north
  double a = brg * M_PI / 180.0;
  int x = cx + (int)lround(sin(a) * (r - 2)), y = cy - (int)lround(cos(a) * (r - 2));
  s_cv->drawLine(cx, cy, x, y, col);
  s_cv->fillCircle(x, y, 2, col);
  s_cv->fillCircle(cx, cy, 1, C_MUTED);
}

static void draw_top(const UiSummary& sm, const char* title) {
  uint16_t bg = sm.alert == UI_EMERGENCY ? RGB565(0x6E, 0x14, 0x14)
              : sm.alert == UI_CONTACT ? C_AMBER : C_BAR;
  uint16_t fg = sm.alert == UI_EMERGENCY ? RGB565(0xFF, 0xE2, 0xE2)
              : sm.alert == UI_CONTACT ? RGB565(0x1A, 0x12, 0x02) : C_TEXT;
  uint16_t mut = sm.alert == UI_EMERGENCY ? RGB565(0xD8, 0x9A, 0x9A)
               : sm.alert == UI_CONTACT ? RGB565(0x5E, 0x48, 0x10) : C_MUTED;
  s_cv->fillRect(0, 0, W, TOP, bg);
  char b[48];
  // right cluster first (seen, battery, RX dot), so the title knows its room
  int x = W - 12;
  s_cv->fillCircle(x, 10, 4, s_ble_ok ? (sm.active ? RGB565(0x1E, 0x64, 0x28) : C_OK) : C_DANGER);
  x -= 10;
  if (s_batt >= 0) {
    snprintf(b, sizeof(b), "%d%%", s_batt);
    x -= strlen(b) * 6; small(x, 7, s_batt <= 15 ? C_DANGER : mut, b); x -= 8;
  }
  char head[48];
  if (title) snprintf(head, sizeof(head), "%s", title); else ui_headline(head, sizeof(head), &sm);
  // "N seen" is the first thing to give way: an alert headline is worth more
  if (g_seen_count) {
    snprintf(b, sizeof(b), "%lu seen", (unsigned long)g_seen_count);
    int sx = x - (int)strlen(b) * 6;
    if (text_px(head, &FreeSansBold9pt7b) <= sx - 6 - 8) { small(sx, 7, mut, b); x = sx; }
  }
  fit(head, sizeof(head), x - 6 - 8, &FreeSansBold9pt7b);
  bold(6, 15, fg, head);
}

static void draw_meter(int x, int y, int w, int rssi, uint16_t col) {
  s_cv->fillRect(x, y, w, 3, C_METER);
  s_cv->fillRect(x, y, (int)(w * ui_rssi01(rssi)), 3, col);
}

static void draw_bl_toast() {
  if (s_now >= s_bl_toast_until) return;
  const char* lvl = s_bl == 0 ? "BRT 100%" : s_bl == 1 ? "BRT 43%" : "BRT 25%";
  int tw = 86, th = 22;
  int tx = (W - tw) / 2, ty = 28;
  s_cv->fillRoundRect(tx, ty, tw, th, 5, RGB565(0x06, 0x24, 0x22));
  s_cv->drawRoundRect(tx, ty, tw, th, 5, C_ACCENT);
  bold(tx + 8, ty + 15, C_ACCENT, lvl);
}

static void draw_scope() {
  s_cv->fillScreen(C_BG);
  UiSummary sm; ui_summarize(&sm, s_now);
  draw_top(sm, nullptr);
  if (!s_n) {
    bold(W / 2 - 52, 100, C_MUTED, "SCANNING", &FreeSansBold12pt7b);
    // a slow sweep line so the strip reads as alive
    int sx = (s_now / 12) % W;
    s_cv->drawFastVLine(sx, TOP + 2, H - TOP - 2, RGB565(0x14, 0x3A, 0x36));
    draw_bl_toast();
    present();
    return;
  }
  // list pane
  for (int r = 0; r < ROWS; r++) {
    int k = s_scroll + r;
    if (k >= s_n) break;
    const Track* t = &g_tracks[s_order[k]];
    int y = TOP + 2 + r * ROW_H;
    bool stale = ui_stale(t, s_now), danger = ui_danger(t, s_now), sel = k == s_sel;
    uint16_t col = stale ? C_MUTED : danger ? C_DANGER : TRACK_COLORS[s_order[k] % N_TRACK_COLORS];
    if (sel) {
      s_cv->fillRoundRect(2, y, LIST_W - 4, ROW_H - 2, 4, C_BAR);
      s_cv->drawRoundRect(2, y, LIST_W - 4, ROW_H - 2, 4, danger ? C_DANGER : C_ACCENT);
    } else if (danger) {
      s_cv->drawRoundRect(2, y, LIST_W - 4, ROW_H - 2, 4, C_DANGER);
    }
    s_cv->fillRect(6, y + 5, 3, ROW_H - 12, col);
    const char* badge = track_auth_badge(t->auth_state);
    int id_right = LIST_W - 8;
    if (badge[0]) {
      int bw = (int)strlen(badge) * 6 + 5, bx = LIST_W - 7 - bw;
      s_cv->fillRoundRect(bx, y + 3, bw, 11, 3, sel ? C_BG : C_BAR);
      small(bx + 3, y + 5, ui_auth_color(t->auth_state), badge);
      id_right = bx - 4;
    }
    char id[24];
    if (t->uas[0]) {
      int tail = ui_unique_tail(s_order, s_n, k, 4);
      for (int chars = 16; chars >= tail + 2; chars--) {
        ui_short_id(id, sizeof(id), t->uas, tail, chars);
        if (text_px(id, &FreeSansBold9pt7b) <= id_right - 14) break;
      }
    } else {
      snprintf(id, sizeof(id), "MAC ..%02X%02X", t->mac[4], t->mac[5]);   // no ID yet: its address
    }
    bold(14, y + 13, stale ? C_MUTED : C_TEXT, id);
    char b[32], hb[8] = "--";
    if (!isnan(t->height)) snprintf(hb, sizeof(hb), "%dm", (int)t->height);
    snprintf(b, sizeof(b), "h %-5s %4ddBm %s%s%s%s", hb, t->rssi,
             (t->src_mask & 1) ? "W" : "", (t->src_mask & 2) ? "N" : "",
             (t->src_mask & 4) ? "B" : "", t->in_tfr ? " TFR!" : "");
    small(14, y + 18, t->in_tfr && !stale ? C_DANGER : C_MUTED, b);
  }
  if (s_n > ROWS) {  // scrollbar
    int h = (H - TOP - 4) * ROWS / s_n, y0 = TOP + 2 + (H - TOP - 4) * s_scroll / s_n;
    s_cv->fillRect(LIST_W - 2, TOP + 2, 2, H - TOP - 4, C_METER);
    s_cv->fillRect(LIST_W - 2, y0, 2, h, C_MUTED);
  }
  // detail pane: signal, then where it is from here (compass needle, range,
  // closing or opening), height and speed, then the flags
  s_cv->drawFastVLine(LIST_W + 1, TOP + 2, H - TOP - 2, C_EDGE);
  const int slot = s_order[s_sel];
  const Track* t = &g_tracks[slot];
  int x = LIST_W + 8, y = TOP + 6;
  bool stale = ui_stale(t, s_now);
  uint16_t col = stale ? C_MUTED : ui_danger(t, s_now) ? C_DANGER : TRACK_COLORS[slot % N_TRACK_COLORS];
  draw_meter(x, y, W - x - 8, t->rssi, col); y += 8;
  char b[40], hb[10] = "--", sb[12] = "--";
  if (!isnan(t->height)) snprintf(hb, sizeof(hb), "%dm", (int)t->height);
  if (!isnan(t->speed))  snprintf(sb, sizeof(sb), "%.1fm/s", t->speed);
  snprintf(b, sizeof(b), "%d dBm  %s", t->rssi, ui_status_name(t->status));
  small(x, y, t->status == 3 ? C_DANGER : C_MUTED, b); y += 12;
  if (t->has_pos && g_home_set) {
    double brg = ui_bearing(g_home_lat, g_home_lon, t->lat, t->lon);
    needle(x + 13, y + 14, 13, brg, stale ? C_MUTED : col);
    char r[10]; ui_fmt_range(r, sizeof(r), ui_dist_m(g_home_lat, g_home_lon, t->lat, t->lon));
    bold(x + 32, y + 12, C_TEXT, r);
    snprintf(b, sizeof(b), "brg %03d", (int)brg); small(x + 32, y + 17, C_MUTED, b);
    y += 32;
    float rate;
    if (ui_range_rate(slot, t, s_now, &rate)) {
      ui_rate_text(b, sizeof(b), rate); fit(b, sizeof(b), W - x - 4, nullptr);
      small(x, y, rate < -0.5f ? C_AMBER : C_MUTED, b);
    }
    y += 11;
  } else if (t->has_pos) {
    small(x, y, C_MUTED, "no home fix"); y += 10;
    snprintf(b, sizeof(b), "%.5f", t->lat); small(x, y, C_MUTED, b); y += 9;
    snprintf(b, sizeof(b), "%.5f", t->lon); small(x, y, C_MUTED, b); y += 11;
  } else { small(x, y, C_MUTED, "no position"); y += 11; }
  snprintf(b, sizeof(b), "h %s  v %s", hb, sb); fit(b, sizeof(b), W - x - 4, nullptr);
  small(x, y, C_MUTED, b); y += 11;
  if (t->auth_state && y < H - 20) {
    snprintf(b, sizeof(b), "%s", ui_auth_text(t->auth_state)); fit(b, sizeof(b), W - x - 4, nullptr);
    small(x, y, ui_auth_color(t->auth_state), b); y += 11;
  }
  if (t->in_tfr && y < H - 20) {
    snprintf(b, sizeof(b), "IN TFR %s", t->tfr_id); fit(b, sizeof(b), W - x - 4, nullptr);
    small(x, y, C_DANGER, b); y += 11;
  }
  snprintf(b, sizeof(b), "src %s%s%s  %us ago", (t->src_mask & 1) ? "W" : "",
           (t->src_mask & 2) ? "N" : "", (t->src_mask & 4) ? "B" : "",
           (unsigned)((s_now - t->last_ms) / 1000));
  small(x, H - 10, C_MUTED, b);
  draw_bl_toast();
  present();
}

static void draw_detail() {
  s_cv->fillScreen(C_BG);
  UiSummary sm; ui_summarize(&sm, s_now);
  if (!s_n) {
    draw_top(sm, "DETAIL");
    bold(14, 55, C_MUTED, "NO CONTACTS", &FreeSansBold12pt7b);
    small(14, 85, C_TEXT, "Listening...");
    small(14, 105, C_MUTED, "Click: scope");
    small(14, 120, C_MUTED, "Hold: menu");
    draw_bl_toast();
    present();
    return;
  }
  const int slot = s_order[s_sel];
  const Track* t = &g_tracks[slot];
  draw_top(sm, t->uas[0] ? t->uas : "(no id)");
  bool danger = ui_danger(t, s_now);
  char b[48];
  // the big numbers: range + bearing if we know where we are, else height
  if (g_home_set && t->has_pos) {
    char r[10]; ui_fmt_range(r, sizeof(r), ui_dist_m(g_home_lat, g_home_lon, t->lat, t->lon));
    snprintf(b, sizeof(b), "%s", r);
    bold(8, 58, C_TEXT, b, &FreeSansBold12pt7b);
    double brg = ui_bearing(g_home_lat, g_home_lon, t->lat, t->lon);
    snprintf(b, sizeof(b), "%03d", (int)brg);
    bold(120, 58, C_ACCENT, b, &FreeSansBold12pt7b);
    small(120, 62, C_MUTED, "bearing");
    small(8, 62, C_MUTED, "range");
    needle(196, 46, 17, brg, danger ? C_DANGER : C_ACCENT);
    float rate;
    if (ui_range_rate(slot, t, s_now, &rate)) {
      bold(224, 44, rate < -0.5f ? C_AMBER : C_TEXT,
           rate < -0.5f ? "closing" : rate > 0.5f ? "opening" : "holding");
      if (fabsf(rate) > 0.5f) { snprintf(b, sizeof(b), "%.1f m/s", fabsf(rate)); small(224, 50, C_MUTED, b); }
    }
  } else {
    snprintf(b, sizeof(b), "%s", ui_status_name(t->status));
    bold(8, 58, t->status == 3 ? C_DANGER : C_TEXT, b, &FreeSansBold12pt7b);
  }
  // rssi meter, wide
  draw_meter(8, 74, 160, t->rssi, danger ? C_DANGER : C_ACCENT);
  snprintf(b, sizeof(b), "%d dBm (peak %d)", t->rssi, t->peak_rssi); small(176, 71, C_MUTED, b);
  char hb[10] = "--", sb[12] = "--";
  if (!isnan(t->height)) snprintf(hb, sizeof(hb), "%dm", (int)t->height);
  if (!isnan(t->speed))  snprintf(sb, sizeof(sb), "%.1fm/s", t->speed);
  snprintf(b, sizeof(b), "height %s   speed %s   %s", hb, sb, ui_status_name(t->status));
  small(8, 86, C_MUTED, b);
  if (t->has_pos) { snprintf(b, sizeof(b), "pos %.6f, %.6f", t->lat, t->lon); small(8, 98, C_MUTED, b); }
  if (t->auth_state) small(8, 110, ui_auth_color(t->auth_state), ui_auth_text(t->auth_state));
  if (t->in_tfr) { snprintf(b, sizeof(b), "INSIDE TFR %s", t->tfr_id); small(8, 122, C_DANGER, b); }
  snprintf(b, sizeof(b), "mac %02X:%02X:%02X:%02X:%02X:%02X  src %s%s%s  msgs %u",
           t->mac[0], t->mac[1], t->mac[2], t->mac[3], t->mac[4], t->mac[5],
           (t->src_mask & 1) ? "W" : "", (t->src_mask & 2) ? "N" : "",
           (t->src_mask & 4) ? "B" : "", t->msgs);
  small(8, 138, C_MUTED, b);
  snprintf(b, sizeof(b), "%us ago | side key or click: back", (unsigned)((s_now - t->last_ms) / 1000));
  small(8, 156, C_MUTED, b);
  draw_bl_toast();
  present();
}

// ---- spectrum: 2.4 GHz bars up top, CC1101 sweep below, encoder cursor
static void spectrum_enter() {
  memset((void*)s_wsum, 0, sizeof(s_wsum)); memset((void*)s_wcnt, 0, sizeof(s_wcnt));
  memset(s_a24, 0, sizeof(s_a24));
  for (int i = 0; i < CC_SWEEP_BINS; i++) { s_swp[i] = -127; s_pk[i] = -127; }
  s_cc_ok = cc1101_sweep_begin();
  s_spec_on = true;
}
static void spectrum_leave() { s_spec_on = false; cc1101_sweep_stop(); }

static void draw_spectrum() {
  s_cv->fillScreen(C_BG);
  UiSummary sm = {}; sm.alert = UI_QUIET;
  draw_top(sm, s_cc_ok ? "SPECTRUM" : "SPECTRUM (2.4G)");
  // 2.4 GHz: fold the accumulators, decay quiet channels
  for (int c = 1; c <= 13; c++) {
    uint16_t cnt = s_wcnt[c];
    int32_t sum = s_wsum[c];
    s_wcnt[c] = 0;
    s_wsum[c] = 0;
    if (cnt) {
      float lvl = (float)sum / cnt;
      s_a24[c - 1] = s_a24[c - 1] * 0.5f + lvl * 0.5f;
    } else if (c == s_dwell) s_a24[c - 1] = s_a24[c - 1] * 0.8f - 115 * 0.2f;
    else s_a24[c - 1] -= 0.5f;
    if (s_a24[c - 1] < -115) s_a24[c - 1] = -115;
  }
  const int A_Y = TOP + 4, A_H = 34, BW = 20;
  small(4, A_Y, C_MUTED, "2.4G");
  for (int c = 0; c < 13; c++) {
    float v = (s_a24[c] + 115) / 70.0f; v = v < 0 ? 0 : v > 1 ? 1 : v;
    int h = (int)(A_H * v), x = 34 + c * BW;
    s_cv->fillRect(x, A_Y + A_H - h, BW - 3, h, c + 1 == s_dwell ? C_ACCENT : RGB565(0x2A, 0x7A, 0x9A));
  }
  // sub-GHz trace
  const int B_Y0 = TOP + 44, B_H = 90, X0 = 34, PW = W - X0 - 4;
  s_cv->drawFastHLine(X0, B_Y0 + B_H, PW, C_EDGE);
  small(4, B_Y0 + 2, C_MUTED, "sub");
  small(4, B_Y0 + 11, C_MUTED, "GHz");
  // auto-range around the sweep's floor
  int lo = 0, hi = -127;
  for (int i = 0; i < CC_SWEEP_BINS; i++) { if (s_swp[i] < lo) lo = s_swp[i]; if (s_swp[i] > hi) hi = s_swp[i]; }
  int top = hi + 6, bot = lo - 2; if (top - bot < 30) top = bot + 30;
  int px = -1, py = -1;
  for (int i = 0; i < CC_SWEEP_BINS; i++) {
    int x = X0 + i * PW / CC_SWEEP_BINS;
    float vp = (float)(s_pk[i] - bot) / (top - bot); vp = vp < 0 ? 0 : vp > 1 ? 1 : vp;
    s_cv->drawPixel(x, B_Y0 + B_H - (int)(B_H * vp), RGB565(0x8A, 0x5A, 0x2A));
    float v = (float)(s_swp[i] - bot) / (top - bot); v = v < 0 ? 0 : v > 1 ? 1 : v;
    int y = B_Y0 + B_H - (int)(B_H * v);
    if (px >= 0) s_cv->drawLine(px, py, x, y, C_ACCENT);
    px = x; py = y;
  }
  // band markers along the axis
  struct M { uint32_t hz; const char* l; } MK[] = { {315000000, "315"}, {433920000, "433"}, {868000000, "868"}, {915000000, "915"} };
  for (auto& m : MK) {
    int best = 0; uint32_t bd = UINT32_MAX;
    for (int i = 0; i < CC_SWEEP_BINS; i++) { uint32_t d = (uint32_t)labs((long)cc1101_bin_hz(i) - (long)m.hz); if (d < bd) { bd = d; best = i; } }
    int x = X0 + best * PW / CC_SWEEP_BINS;
    s_cv->drawFastVLine(x, B_Y0 + B_H - 3, 3, C_MUTED);
    int lx = x - 8; if (lx > W - 19) lx = W - 19; if (lx < 0) lx = 0;
    small(lx, B_Y0 + B_H + 2, C_MUTED, m.l);
  }
  // cursor readout
  int cx = X0 + s_mark * PW / CC_SWEEP_BINS;
  s_cv->drawFastVLine(cx, B_Y0, B_H, RGB565(0x50, 0x58, 0x66));
  char b[32];
  snprintf(b, sizeof(b), "%.2f MHz  %d dBm", cc1101_bin_hz(s_mark) / 1e6, s_swp[s_mark]);
  small(W - 6 - strlen(b) * 6, B_Y0 + 2, C_TEXT, b);
  draw_bl_toast();
  present();
}


// ---- test-beacon view: the ten transmit variants, each a toggle
/// Keep the TX list's row on a row (0 master, 1 emergency, 2 rate, 3+
/// paths): on every turn, so a click in the same pass never acts on a row
/// that is not there.
static void tx_sel_clamp() {
  int total = txui_count() + 3;
  if (s_tx_sel >= total) s_tx_sel = total - 1;
  if (s_tx_sel < 0) s_tx_sel = 0;
}

static void draw_tx() {
  s_cv->fillScreen(C_BG);
  bool running = txui_running();
  int n = txui_count();
  // top band: running state, in the alert palette so "on air" is unmistakable
  uint16_t bg = running ? C_AMBER : C_BAR, fg = running ? RGB565(0x1A,0x12,0x02) : C_TEXT;
  s_cv->fillRect(0, 0, W, TOP, bg);
  bold(6, 15, fg, running ? "TEST BEACON  ON AIR" : "TEST BEACON  STOPPED");
  char hd[20]; int on = 0; for (int i = 0; i < n; i++) if (txui_enabled(i)) on++;
  snprintf(hd, sizeof(hd), "%d/%d on", on, n);
  small(W - 6 - strlen(hd) * 6, 7, running ? RGB565(0x5E,0x48,0x10) : C_MUTED, hd);

  const int ROWS_TX = 5, RH = 24, y0 = TOP + 2;   // leaves a band for the hint
  int total = n + 3;                       // master + emergency + rate + paths
  tx_sel_clamp();
  static int scroll = 0;
  if (s_tx_sel < scroll) scroll = s_tx_sel;
  if (s_tx_sel >= scroll + ROWS_TX) scroll = s_tx_sel - ROWS_TX + 1;

  for (int r = 0; r < ROWS_TX; r++) {
    int row = scroll + r;
    if (row >= total) break;
    int y = y0 + r * RH;
    bool sel = row == s_tx_sel;
    if (sel) { s_cv->fillRoundRect(2, y, W - 4, RH - 2, 4, C_BAR); s_cv->drawRoundRect(2, y, W - 4, RH - 2, 4, C_ACCENT); }
    if (row <= 1) {                        // master transmit, emergency flag
      bool on = row == 0 ? running : txui_emergency();
      uint16_t hue = row == 0 ? C_OK : C_DANGER;
      bold(10, y + 16, on ? hue : C_MUTED, row == 0 ? "TRANSMIT" : "EMERGENCY FLAG");
      s_cv->fillRoundRect(W - 44, y + 4, 34, 15, 4, on ? (row == 0 ? RGB565(0x12,0x3A,0x20) : RGB565(0x4A,0x14,0x14)) : C_BAR);
      s_cv->drawRoundRect(W - 44, y + 4, 34, 15, 4, on ? hue : C_EDGE);
      small(W - 39, y + 8, on ? hue : C_MUTED, on ? "ON" : "off");
    } else if (row == 2) {                 // rate: spec (Remote ID rates) or slow (5 s)
      bool slow = txui_slow();
      bold(10, y + 16, slow ? C_AMBER : C_TEXT, "RATE");
      small(60, y + 9, C_MUTED, slow ? "each path every 5 s" : "Remote ID rates");
      s_cv->fillRoundRect(W - 44, y + 4, 34, 15, 4, slow ? RGB565(0x4A,0x36,0x0C) : C_BAR);
      s_cv->drawRoundRect(W - 44, y + 4, 34, 15, 4, slow ? C_AMBER : C_EDGE);
      small(W - 39, y + 8, slow ? C_AMBER : C_TEXT, slow ? "SLOW" : "SPEC");
    } else {
      int i = row - 3;
      bool on = txui_enabled(i);
      uint16_t col = on ? (running ? C_OK : C_TEXT) : C_MUTED;
      // the variant's name (what tells the ten apart), its carrier, sent count
      char v[16]; snprintf(v, sizeof(v), "%s", ui_tx_variant(txui_id(i)));
      fit(v, sizeof(v), 92, &FreeSansBold9pt7b);
      bold(10, y + 16, on ? C_TEXT : C_MUTED, v);
      small(108, y + 9, col, txui_carrier(i));
      char c[12]; snprintf(c, sizeof(c), "%lu", (unsigned long)txui_sent(i));
      small(W - 52 - (int)strlen(c) * 6, y + 9, C_MUTED, c);
      // on/off pill
      s_cv->fillRoundRect(W - 44, y + 4, 34, 15, 4, on ? RGB565(0x12,0x3A,0x20) : C_BAR);
      s_cv->drawRoundRect(W - 44, y + 4, 34, 15, 4, on ? C_OK : C_EDGE);
      s_cv->setTextColor(on ? C_OK : C_MUTED); s_cv->setCursor(W - 39, y + 8);
      s_cv->print(on ? "ON" : "off");
    }
  }
  if (total > ROWS_TX) {
    int span = ROWS_TX * RH, h = span * ROWS_TX / total, sy = y0 + span * scroll / total;
    s_cv->fillRect(W - 2, y0, 2, span, C_METER); s_cv->fillRect(W - 2, sy, 2, h, C_MUTED);
  }
  draw_bl_toast();
  s_cv->drawFastHLine(0, H - 14, W, C_EDGE);
  small(6, H - 10, C_MUTED, "turn: pick  click: on/off  hold: menu");
  present();
}

void tembed_power_off() {
  rx_log_flush();   // the match log saves every 10 min; don't lose the rest
  s_cv->fillScreen(C_BG);
  bold(W / 2 - 45, H / 2 - 8, C_TEXT, "POWER OFF");
  small(W / 2 - 65, H / 2 + 14, C_MUTED, "Side button to wake");
  present();
  delay(500);

  ring_off();
  ledcWrite(PIN_LCD_BL, 0);

  // Cut peripheral power rail (CC1101 + LED ring)
  pinMode(PIN_PWR_EN, OUTPUT);
  digitalWrite(PIN_PWR_EN, LOW);

  // Configure wakeups on side key (GPIO 6) and encoder push (GPIO 0)
  esp_sleep_enable_ext0_wakeup((gpio_num_t)PIN_USER_KEY, 0);
  esp_sleep_enable_ext1_wakeup((1ULL << PIN_USER_KEY) | (1ULL << PIN_ENC_KEY), ESP_EXT1_WAKEUP_ANY_LOW);

  esp_deep_sleep_start();
}

// ---- mode menu (from either mode; hold the knob to open)
// Rows of MENU_RH: a 9 pt name above a 6 px subtitle, both inside the
// selection box (y .. y + MENU_RH - 2), clear of its top and bottom edges.
#define MENU_RH 29
#define MENU_Y(i) (TOP + 2 + (i) * MENU_RH)
/// The saved drone history in brief: "48 records, oldest 2 h ago".
static void history_words(char* b, size_t n) {
  if (s_mode != UI_MODE_RX) { snprintf(b, n, "in receiver mode"); return; }
  if (s_cleared && s_now - s_cleared_ms < 5000) { snprintf(b, n, "history cleared"); return; }
  int held = 0; uint32_t age = UINT32_MAX;
  rx_log_stats(&held, &age);
  if (!held) { snprintf(b, n, "no saved drone records"); return; }
  if (age == UINT32_MAX) snprintf(b, n, "%d records", held);
  else if (age < 3600) snprintf(b, n, "%d records, oldest %lu min ago", held, (unsigned long)(age / 60));
  else if (age < 172800) snprintf(b, n, "%d records, oldest %lu h ago", held, (unsigned long)(age / 3600));
  else snprintf(b, n, "%d records, oldest %lu days ago", held, (unsigned long)(age / 86400));
}
/// The confirmation: CANCEL is the default, the knob picks, a click acts,
/// the side key backs out.
static void draw_clear_ask() {
  s_cv->fillScreen(C_BG);
  s_cv->fillRect(0, 0, W, TOP, C_BAR);
  bold(6, 15, C_DANGER, "CLEAR HISTORY?");
  int held = 0; uint32_t age; rx_log_stats(&held, &age);
  char b[48]; snprintf(b, sizeof(b), "Clear the %d saved drone record%s?", held, held == 1 ? "" : "s");
  bold(12, 50, C_TEXT, b);
  small(12, 62, C_MUTED, "This can't be undone. Connected apps are told.");
  const char* lbl[2] = { "CANCEL", "CLEAR" };
  for (int i = 0; i < 2; i++) {
    int x = i ? W / 2 + 8 : 12, w = W / 2 - 20, y = 92, h = 40;
    bool sel = i == s_clear_sel;
    uint16_t edge = i ? C_DANGER : C_ACCENT;
    if (sel) s_cv->fillRoundRect(x, y, w, h, 6, i ? C_DANGER : RGB565(0x06, 0x24, 0x22));
    s_cv->drawRoundRect(x, y, w, h, 6, edge);
    int tw = text_px(lbl[i], &FreeSansBold9pt7b);
    bold(x + (w - tw) / 2, y + 26, sel ? C_TEXT : C_MUTED, lbl[i]);
  }
  small(12, H - 10, C_MUTED, "turn: choose  click: do it  side key: back");
  present();
}
static void draw_menu() {
  if (s_clear_ask) { draw_clear_ask(); return; }
  s_cv->fillScreen(C_BG);
  s_cv->fillRect(0, 0, W, TOP, C_BAR);
  bold(6, 15, C_TEXT, "MENU");
  char bl[24]; snprintf(bl, sizeof(bl), "Brightness  %s", s_bl == 0 ? "100%" : s_bl == 1 ? "43%" : "25%");
  char hist[48]; history_words(hist, sizeof(hist));
  const char* names[MENU_N] = { "Receiver", "Test beacon (TX)", bl, "Clear history", "Power Off", "Back" };
  const char* subs[MENU_N]  = { "listen for Remote ID", "transmit test signals", "click to cycle", hist,
                                "deep sleep (side btn wakes)", "return to the screen" };
  int first = s_menu_sel > 4 ? s_menu_sel - 4 : 0;   // five rows on screen, the choice among them
  char pos[24]; snprintf(pos, sizeof(pos), "%d/%d", s_menu_sel + 1, MENU_N);
  small(W - 6 - 6 * (int)strlen(pos), 7, C_MUTED, pos);
  for (int r = 0; r < 5; r++) {
    int i = first + r, y = MENU_Y(r);
    bool sel = i == s_menu_sel, cur = i < 2 && i == s_mode;
    if (sel) { s_cv->fillRoundRect(6, y, W - 12, MENU_RH - 1, 5, C_BAR); s_cv->drawRoundRect(6, y, W - 12, MENU_RH - 1, 5, C_ACCENT); }
    bold(18, y + 14, sel ? C_TEXT : C_MUTED, names[i]);
    small(18, y + 19, C_MUTED, subs[i]);
    if (cur) small(W - 62, y + 8, C_OK, "current");
  }
  draw_bl_toast();
  present();
}

// ---- input + render loop
bool ui_begin(uint8_t mode) {
  s_mode = mode;
  s_view = mode == UI_MODE_TX ? V_TX : V_SCOPE;
  pinMode(PIN_ENC_A, INPUT_PULLUP); pinMode(PIN_ENC_B, INPUT_PULLUP);
  pinMode(PIN_ENC_KEY, INPUT_PULLUP); pinMode(PIN_USER_KEY, INPUT_PULLUP);
  int sig1 = gpio_get_level((gpio_num_t)PIN_ENC_A);
  int sig2 = gpio_get_level((gpio_num_t)PIN_ENC_B);
  s_old_state = (sig1 & 1) | ((sig2 & 1) << 1);
  s_raw_pos = 0;
  s_enc_pos = 0;
  attachInterrupt(PIN_ENC_A, enc_isr, CHANGE);
  attachInterrupt(PIN_ENC_B, enc_isr, CHANGE);

  s_bus = new Arduino_ESP32SPI(PIN_LCD_DC, PIN_LCD_CS, PIN_SPI_SCK, PIN_SPI_MOSI, PIN_SPI_MISO, HSPI);
  s_gfx = new Arduino_ST7789(s_bus, PIN_LCD_RST, 3 /* landscape, USB on the left */, true /* IPS */,
                             170, 320, 35, 0, 35, 0);
  if (!s_gfx->begin(40000000)) return false;
  s_cv = new Arduino_Canvas(W, H, s_gfx);
  if (!s_cv->begin()) return false;
  s_cv->fillScreen(C_BG);
  present();
  ledcAttach(PIN_LCD_BL, 5000, 8);
  ledcWrite(PIN_LCD_BL, BL_LEVELS[s_bl]);
  s_last_input = millis();
  s_cv->fillScreen(C_BG);
  bold(W / 2 - 66, 74, C_TEXT, "ORECCHINO", &FreeSansBold12pt7b);
  small(W / 2 - 60, 96, C_MUTED, mode == UI_MODE_TX ? "starting test beacon" : "starting radios");
  present();
  ring_begin();
  return true;
}

void ui_tick(uint32_t now, bool ble_ok, int batt_pct) {
  s_now = now; s_ble_ok = ble_ok; s_batt = batt_pct;

  // encoder detents (1 step per physical click)
  enc_step();
  static int32_t last_pos = 0;
  static uint32_t last_det_ms = 0;
  int32_t pos = s_enc_pos;
  if (s_flush_input) { s_flush_input = false; last_pos = pos; }
  int det = pos - last_pos;
  if (det) {
    s_last_input = now;
    last_pos = pos;
    uint32_t dt = now - last_det_ms;
    last_det_ms = now;
    if (dt < 70 && abs(det) == 1 && s_view != V_MENU) {
      det *= 2; // quick turn acceleration for responsive list navigation
    }
    if (s_view == V_MENU && s_clear_ask) { s_clear_sel = det > 0 ? 1 : 0; }
    else if (s_view == V_MENU) { s_menu_sel = ((s_menu_sel + det) % MENU_N + MENU_N) % MENU_N; }
    else if (s_view == V_TX) { s_tx_sel += det; tx_sel_clamp(); }
    else if (s_view == V_SPECTRUM) s_mark = (s_mark + det + CC_SWEEP_BINS) % CC_SWEEP_BINS;
    else {
      if (s_n > 0) {
        s_sel += det;
        if (s_sel < 0) s_sel = 0;
        if (s_sel >= s_n) s_sel = s_n - 1;
        ui_sel_set(&s_selid, s_order[s_sel]);
      }
    }
    s_dirty = true;
  }
  // encoder key: short click acts on the view; a >800 ms hold opens the menu
  static bool k_was = false; static uint32_t k_down = 0; static bool k_held = false;
  bool k = digitalRead(PIN_ENC_KEY) == LOW;
  if (k && !k_was) { k_down = now; k_held = false; s_last_input = now; }
  if (k && !k_held && now - k_down > 800 && s_view != V_MENU) {   // long hold -> menu
    k_held = true;
    if (s_view == V_SPECTRUM) spectrum_leave();
    s_menu_sel = s_mode; s_clear_ask = false; s_view = V_MENU; s_dirty = true;
  }
  if (!k && k_was && !k_held && now - k_down > 40) {              // short click
    if (s_view == V_MENU && s_clear_ask) {                       // the confirmation
      if (s_clear_sel == 1) {
        rx_log_clear_all();   // under the core's lock; saved now; log_cleared to every host
        s_cleared = true; s_cleared_ms = now;
      }
      s_clear_ask = false;
    } else if (s_view == V_MENU) {
      if (s_menu_sel == MENU_CLEAR) {                            // Clear history: ask first
        if (s_mode == UI_MODE_RX) { s_clear_ask = true; s_clear_sel = 0; }
      } else if (s_menu_sel == 2) {                              // Brightness: cycle
        s_bl = (s_bl + 1) % 3; s_dimmed = false;
        uint8_t bl_val = BL_LEVELS[s_bl];
        if (s_night_mode) bl_val = (uint8_t)(bl_val * 7 / 10);
        ledcWrite(PIN_LCD_BL, bl_val);
        s_bl_toast_until = now + 1200;
      } else if (s_menu_sel == MENU_POWER) {                     // Power Off
        tembed_power_off();
      } else if (s_menu_sel == MENU_BACK || s_menu_sel == s_mode) {  // Back / no change
        s_view = s_mode == UI_MODE_TX ? V_TX : V_SCOPE;
      } else board_switch_mode((uint8_t)s_menu_sel);               // saves + reboots
    } else if (s_view == V_TX) {
      if (s_tx_sel == 0) txui_set_running(!txui_running());
      else if (s_tx_sel == 1) txui_set_emergency(!txui_emergency());
      else if (s_tx_sel == 2) txui_set_slow(!txui_slow());   // saved in NVS
      else txui_set_enabled(s_tx_sel - 3, !txui_enabled(s_tx_sel - 3));
    } else if (s_view == V_SPECTRUM) { spectrum_leave(); s_view = V_SCOPE; }
    else s_view = s_view == V_SCOPE ? V_DETAIL : V_SCOPE;
    s_dirty = true;
  }
  k_was = k;
  // side key: tap = BACK from wherever you are (the board's back button);
  //           hold 1.5 s = spectrum (RX only); hold 3.5 s = power off.
  static bool u_was = false; static uint32_t u_down = 0; static bool u_spec_fired = false; static bool u_off_fired = false;
  bool u = digitalRead(PIN_USER_KEY) == LOW;
  if (u && !u_was) { u_down = now; u_spec_fired = false; u_off_fired = false; s_last_input = now; }
  if (u && !u_spec_fired && now - u_down > 1500) {
    u_spec_fired = true;
    if (s_mode == UI_MODE_RX && s_view != V_SPECTRUM && s_view != V_MENU) {
      spectrum_enter(); s_view = V_SPECTRUM; s_dirty = true;
    }
  }
  if (u && !u_off_fired && now - u_down > 3500) {
    u_off_fired = true;
    tembed_power_off();
  }
  if (!u && u_was && !u_spec_fired && !u_off_fired && now - u_down > 30) {
    if (s_view == V_SPECTRUM) { spectrum_leave(); s_view = V_SCOPE; }
    else if (s_view == V_DETAIL) s_view = V_SCOPE;
    else if (s_view == V_MENU && s_clear_ask) s_clear_ask = false;   // back out of the question
    else if (s_view == V_MENU) s_view = s_mode == UI_MODE_TX ? V_TX : V_SCOPE;
    else if (s_view == V_TX) { s_menu_sel = MENU_BACK; s_view = V_MENU; }   // beacon list -> menu
    s_dirty = true;
  }
  u_was = u;
  if (s_now < s_bl_toast_until) s_dirty = true;

  // ---- Solar ambient night mode evaluation
  if (now - s_last_solar_eval >= 10000 || s_last_solar_eval == 0) {
    s_last_solar_eval = now;
    time_t t_now = time(nullptr);
    if (t_now > 1700000000) {
      struct tm tm_utc;
      gmtime_r(&t_now, &tm_utc);
      // The sun where the app last said we are; San Francisco until it has.
      double lat = g_home_set ? g_home_lat : 37.7749, lon = g_home_set ? g_home_lon : -122.4194;
      double elev = solar_elevation_deg(lat, lon, tm_utc.tm_year + 1900, tm_utc.tm_mon + 1, tm_utc.tm_mday,
                                        tm_utc.tm_hour, tm_utc.tm_min, tm_utc.tm_sec);
      bool night = (elev <= SOLAR_SUNDOWN_ELEVATION_DEG);
      if (night != s_night_mode) {
        s_night_mode = night;
        ring_set_dim(s_night_mode);
        uint8_t bl_val = s_dimmed ? BL_LEVELS[2] : BL_LEVELS[s_bl];
        if (s_night_mode) bl_val = (uint8_t)(bl_val * 7 / 10);
        ledcWrite(PIN_LCD_BL, bl_val);
      }
    }
  }

  // ---- idle dimming (both modes): 60 s without input drops the backlight to
  //      its lowest step (25%, still plainly lit); any input restores it; a
  //      live danger never dims.
  {
    UiSummary sm; ui_summarize(&sm, now);
    bool want_dim = now - s_last_input > 120000 && !sm.danger && s_view != V_SPECTRUM;
    if (want_dim != s_dimmed) {
      s_dimmed = want_dim;
      uint8_t bl_val = want_dim ? BL_LEVELS[2] : BL_LEVELS[s_bl];
      if (s_night_mode) bl_val = (uint8_t)(bl_val * 7 / 10);
      ledcWrite(PIN_LCD_BL, bl_val);
    }
  }

  // ---- TX and MENU render (no radios to service here)
  if (s_view == V_MENU) {
    static uint32_t last = 0;
    if (s_dirty || now - last >= 200) { last = now; s_dirty = false; draw_menu(); }
    ring_off();
    return;
  }
  if (s_view == V_TX) {
    static uint32_t last = 0;
    if (s_dirty || now - last >= 400) { last = now; s_dirty = false; draw_tx(); }
    // ring: amber breath while transmitting, off when stopped
    ring_tick(now, txui_running() ? 1 : 0, 0.6f);
    return;
  }

  if (s_view == V_SPECTRUM) {
    if (s_cc_ok) cc1101_sweep_chunk(s_swp, &s_cursor, 12);   // ~12 ms per pass
    for (int i = 0; i < CC_SWEEP_BINS; i++) s_pk[i] = s_swp[i] > s_pk[i] ? s_swp[i] : s_pk[i] - 0.05f;
    static uint32_t last = 0;
    if (now - last >= 80) { last = now; draw_spectrum(); }
    ring_off();
    return;
  }

  // scope / detail: redraw on input or 2 Hz, whichever first
  static uint32_t last = 0;
  if (s_dirty || now - last >= 500) {
    last = now; s_dirty = false;
    build_order();
    if (s_view == V_DETAIL) draw_detail(); else draw_scope();
  }
  UiSummary sm; ui_summarize(&sm, now);
  float lvl = 0;
  for (int i = 0; i < TRK_MAX; i++)
    if (g_tracks[i].used && !ui_stale(&g_tracks[i], now)) {
      float v = (float)ui_rssi01(g_tracks[i].rssi); if (v > lvl) lvl = v;
    }
  ring_tick(now, sm.danger ? 2 : sm.active ? 1 : 0, lvl);
}

void ui_flush_input() { s_flush_input = true; s_dirty = true; }
