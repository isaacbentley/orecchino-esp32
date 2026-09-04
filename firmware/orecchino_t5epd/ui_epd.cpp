#include "ui_epd.h"
#include "board_t5.h"
#include "sx1262_sweep.h"
#include "t5_periph.h"
#include "../common/ui_common.h"
#include <epdiy.h>
#include <LittleFS.h>
#include <Preferences.h>
#include <PNGdec.h>
#include <Adafruit_GFX.h>  // for its Fonts/ (GFXfont layout is shared)
#include <Fonts/FreeSansBold9pt7b.h>
#include <Fonts/FreeSansBold12pt7b.h>
#include <Fonts/FreeSansBold18pt7b.h>
#include <Fonts/FreeSansBold24pt7b.h>

#define W 960
#define H 540
#define BLACK 0x00
#define WHITE 0xFF
#define GREY  0x60
#define LIGHT 0xC8
#define ROW_H 46
#define ROWS  8
#define TABLE_X 20
#define TABLE_W 540
#define PLOT_CX 760
#define PLOT_CY 275
#define PLOT_R  145
// Waveform LUT selection follows the panel temperature (TPS65185 sensor).
#define TEMP_C  ((int)epd_ambient_temperature())

static EpdiyHighlevelState s_hl;
static uint8_t* s_fb;
static bool s_ok = false;
static uint32_t s_now;
static bool s_ble_ok = true;
static int  s_batt = -1;
static int  s_sel = 0, s_n = 0, s_order[TRK_MAX];
static bool s_spec = false, s_sx_ok = false;
static bool s_map = false;        // table (false) or map (true) board
static bool s_map_touched = false; // first-use guidance
static int  s_cam_z = 13;         // map camera: zoom and centre in world px
static double s_cam_wx = 0, s_cam_wy = 0;
static bool s_cam_valid = false;
static bool s_cam_manual = false; // touched: auto-follow suspended
static uint32_t s_cam_manual_ms = 0;
static int  s_sync_files = -1;
static uint32_t s_last_full = 0;
static int s_partials = 0;
static uint32_t s_sig_prev = 0;
static UiAlert s_alert_prev = UI_QUIET;
static uint8_t s_mode = UI_MODE_RX;
static bool s_confirm_switch = false;
static uint8_t s_target_mode = UI_MODE_RX;

uint8_t ui_get_mode() { return s_mode; }

static const char* uas_tail(const char* s, size_t max_len = 8) {
  if (!s || !*s) return "?";
  size_t len = strlen(s);
  if (len <= max_len) return s;
  return s + (len - max_len);
}

// ---- GFXfont blitter onto the epdiy framebuffer
static int glyph_run(const GFXfont* f, const char* s, int x, int y, uint8_t color, bool draw) {
  int x0 = x;
  for (; *s; s++) {
    uint8_t c = (uint8_t)*s;
    if (c < f->first || c > f->last) continue;
    const GFXglyph* g = &f->glyph[c - f->first];
    if (draw) {
      const uint8_t* bm = f->bitmap + g->bitmapOffset;
      uint16_t bit = 0;
      for (int yy = 0; yy < g->height; yy++)
        for (int xx = 0; xx < g->width; xx++, bit++)
          if (bm[bit >> 3] & (0x80 >> (bit & 7)))
            epd_draw_pixel(x + g->xOffset + xx, y + g->yOffset + yy, color, s_fb);
    }
    x += g->xAdvance;
  }
  return x - x0;
}
static void text(const GFXfont* f, const char* s, int x, int y, uint8_t color = BLACK) { glyph_run(f, s, x, y, color, true); }
static int  text_w(const GFXfont* f, const char* s) { return glyph_run(f, s, 0, 0, 0, false); }
static void text_r(const GFXfont* f, const char* s, int xr, int y, uint8_t color = BLACK) { text(f, s, xr - text_w(f, s), y, color); }
static void rect(int x, int y, int w, int h, uint8_t c) { EpdRect r = {x, y, w, h}; epd_fill_rect(r, c, s_fb); }
static void box(int x, int y, int w, int h, uint8_t c) { EpdRect r = {x, y, w, h}; epd_draw_rect(r, c, s_fb); }

// ---- spectrum feeds
#define N_CH 13
#define N_BIN 128
static volatile int32_t  s_wsum[N_CH + 1];
static volatile uint16_t s_wcnt[N_CH + 1];
static volatile uint8_t  s_dwell = 0;
static float  s_a24[N_CH];
static int8_t s_swp[N_BIN];
static float  s_pk[N_BIN];
static int    s_cursor = 0;
void ui_feed_wifi(uint8_t chan, int8_t rssi) { if (s_spec && chan >= 1 && chan <= N_CH) { s_wsum[chan] += rssi; s_wcnt[chan]++; } }
void ui_set_wifi_channel(uint8_t chan) { s_dwell = chan; }
bool ui_spectrum_active() { return s_spec; }

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
  if (s_sel >= s_n) s_sel = s_n ? s_n - 1 : 0;
}

// Content signature: anything that should move ink. Coarse on the noisy
// fields (RSSI, position) so the panel is not refreshing on every frame.
// Content signature: anything that should move ink. Coarse on the noisy
// fields (RSSI, position) so the panel is not refreshing on every frame.
static uint32_t signature() {
  uint32_t h = 2166136261u;
  auto mix = [&](uint32_t v) { h ^= v; h *= 16777619u; };
  mix(s_mode);
  mix(s_confirm_switch);
  if (s_mode == UI_MODE_TX) {
    mix(txui_running());
    mix(txui_emergency());
    int n = txui_count();
    for (int i = 0; i < n; i++) {
      mix(txui_enabled(i));
      mix(txui_sent(i) / 25);
    }
    mix(s_batt / 5);
    return h;
  }
  for (int k = 0; k < s_n; k++) {
    const Track* t = &g_tracks[s_order[k]];
    for (const char* p = t->uas; *p; p++) mix((uint8_t)*p);
    mix(t->rssi / 10); mix(isnan(t->height) ? 0xFFFF : (int)t->height / 10);
    mix((uint32_t)(int32_t)(t->lat * 1e3)); mix((uint32_t)(int32_t)(t->lon * 1e3));
    mix(t->status); mix(t->auth_state); mix(t->in_tfr); mix(ui_stale(t, s_now));
  }
  mix(s_n); mix(s_sel); mix(g_seen_count / 100); mix(s_batt / 5); mix(s_ble_ok); mix(g_home_set);
  mix(s_map); mix(s_map_touched); mix((uint32_t)(int32_t)(g_home_lat * 1e3)); mix((uint32_t)(int32_t)(g_home_lon * 1e3));
  mix(periph_gps_detected()); mix(periph_gps_fix()); mix(periph_gps_sats()); mix(s_cam_manual); mix(s_cam_z); mix((uint32_t)s_cam_wx); mix((uint32_t)s_cam_wy);
  mix(periph_bl_is_active());
  return h;
}

static void draw_header(const UiSummary& sm, const char* title) {
  bool loud = sm.alert == UI_EMERGENCY;
  rect(0, 0, W, 70, loud ? BLACK : WHITE);
  if (!loud) rect(0, 68, W, 2, BLACK);
  uint8_t fg = loud ? WHITE : BLACK, mut = loud ? LIGHT : GREY;
  char b[48];
  if (title) snprintf(b, sizeof(b), "%s", title); else ui_headline(b, sizeof(b), &sm);
  text(&FreeSansBold18pt7b, b, TABLE_X, 48, fg);

  // View Switcher Tabs (when not in spectrum) - always visible
  if (!title) {
    const int bx = 248, by = 12, bw = 240, bh = 46;
    uint8_t border_col = loud ? WHITE : BLACK;
    // Outer crisp 2px border around the segmented control
    box(bx, by, bw, bh, border_col);
    box(bx + 1, by + 1, bw - 2, bh - 2, border_col);
    // Vertical 2px dividers between TABLE, MAP, and TX
    rect(bx + 80 - 1, by, 2, bh, border_col);
    rect(bx + 160 - 1, by, 2, bh, border_col);

    // Tab 1: TABLE (bx .. bx + 80)
    int tw_table = text_w(&FreeSansBold12pt7b, "TABLE");
    int tx_table = bx + (80 - tw_table) / 2;
    if (!s_map) {
      rect(bx + 2, by + 2, 77, bh - 4, loud ? WHITE : BLACK);
      text(&FreeSansBold12pt7b, "TABLE", tx_table, 41, loud ? BLACK : WHITE);
    } else {
      rect(bx + 2, by + 2, 77, bh - 4, loud ? BLACK : WHITE);
      text(&FreeSansBold12pt7b, "TABLE", tx_table, 41, loud ? WHITE : BLACK);
    }

    // Tab 2: MAP (bx + 80 .. bx + 160)
    int tw_map = text_w(&FreeSansBold12pt7b, "MAP");
    int tx_map = bx + 80 + (80 - tw_map) / 2;
    if (s_map) {
      rect(bx + 80 + 1, by + 2, 78, bh - 4, loud ? WHITE : BLACK);
      text(&FreeSansBold12pt7b, "MAP", tx_map, 41, loud ? BLACK : WHITE);
    } else {
      rect(bx + 80 + 1, by + 2, 78, bh - 4, loud ? BLACK : WHITE);
      text(&FreeSansBold12pt7b, "MAP", tx_map, 41, loud ? WHITE : BLACK);
    }

    // Tab 3: TX (bx + 160 .. bx + 240)
    int tw_tx = text_w(&FreeSansBold12pt7b, "TX");
    int tx_tx = bx + 160 + (80 - tw_tx) / 2;
    rect(bx + 160 + 1, by + 2, 78, bh - 4, loud ? BLACK : WHITE);
    text(&FreeSansBold12pt7b, "TX", tx_tx, 41, loud ? WHITE : BLACK);
  }

  int xr = W - 20;
  snprintf(b, sizeof(b), s_ble_ok ? "RX OK" : "RX FAULT");
  text_r(&FreeSansBold12pt7b, b, xr, 44, loud ? WHITE : (s_ble_ok ? BLACK : BLACK)); xr -= text_w(&FreeSansBold12pt7b, b) + 16;
  if (s_batt >= 0) { snprintf(b, sizeof(b), "%d%%", s_batt); text_r(&FreeSansBold12pt7b, b, xr, 44, loud ? WHITE : BLACK); xr -= text_w(&FreeSansBold12pt7b, b) + 16; }
  if (periph_bl_is_active()) {
    snprintf(b, sizeof(b), "[BL]");
    text_r(&FreeSansBold12pt7b, b, xr, 44, loud ? WHITE : BLACK);
    xr -= text_w(&FreeSansBold12pt7b, b) + 16;
  }
  if (periph_gps_fix()) snprintf(b, sizeof(b), "GPS %d", periph_gps_sats());
  else if (periph_gps_detected()) snprintf(b, sizeof(b), "GPS SEARCH");
  else snprintf(b, sizeof(b), g_home_set ? "APP POS" : "NO POS");
  text_r(&FreeSansBold12pt7b, b, xr, 44, loud ? WHITE : BLACK); xr -= text_w(&FreeSansBold12pt7b, b) + 16;
  if (g_seen_count) { snprintf(b, sizeof(b), "%lu seen", (unsigned long)g_seen_count); text_r(&FreeSansBold9pt7b, b, xr, 43, loud ? WHITE : BLACK); }
}

static void draw_footer(const UiSummary& sm, const char* hint) {
  rect(0, 496, W, 44, WHITE);
  rect(0, 496, W, 2, BLACK);
  char b[64];
  if (sm.newest_age_s == UINT32_MAX) snprintf(b, sizeof(b), "SCANNING");
  else if (sm.newest_age_s < 10) snprintf(b, sizeof(b), "ACTIVE RX");
  else if (sm.newest_age_s < 60) snprintf(b, sizeof(b), "RX <1m");
  else snprintf(b, sizeof(b), "RX %lum ago", (unsigned long)(sm.newest_age_s / 60));

  if (!s_map && s_n > ROWS) {
    char extra[24];
    snprintf(extra, sizeof(extra), "  •  +%d more", s_n - ROWS);
    strncat(b, extra, sizeof(b) - strlen(b) - 1);
  }

  text(&FreeSansBold9pt7b, b, TABLE_X, 524, BLACK);
  text_r(&FreeSansBold9pt7b, hint, W - 20, 524, BLACK);
}

static void draw_table() {
  const int y0 = 80;
  const GFXfont* f9 = &FreeSansBold9pt7b;
  bool has_gps = periph_gps_detected();
  bool has_pos = has_gps || g_home_set;
  struct Col { const char* l; int x; };
  if (has_gps) {
    Col cols[] = {
      {"ID", 28}, {"RSSI", 226}, {"HGT", 286}, {"SPD", 346}, {"RANGE", 406}, {"BRG", 466}, {"AUTH", 512}
    };
    for (auto& c : cols) text(f9, c.l, c.x, y0 + 16, BLACK);
  } else if (has_pos) {
    Col cols[] = {
      {"ID", 28}, {"RSSI", 235}, {"HGT", 300}, {"SPD", 365}, {"RANGE", 430}, {"AUTH", 510}
    };
    for (auto& c : cols) text(f9, c.l, c.x, y0 + 16, BLACK);
  } else {
    Col cols[] = {
      {"ID", 28}, {"RSSI", 260}, {"HGT", 335}, {"SPD", 410}, {"AUTH", 495}
    };
    for (auto& c : cols) text(f9, c.l, c.x, y0 + 16, BLACK);
  }
  rect(TABLE_X, y0 + 22, TABLE_W, 2, BLACK);
  rect(565, 76, 1, 416, LIGHT);  // vertical divider between table and right board

  for (int k = 0; k < ROWS && k < s_n; k++) {
    const Track* t = &g_tracks[s_order[k]];
    int y = y0 + 24 + k * ROW_H;
    bool stale = ui_stale(t, s_now), danger = ui_danger(t, s_now), sel = (k == s_sel);
    uint8_t ink = sel ? WHITE : (stale ? GREY : BLACK);

    if (sel) {
      // Invert selected row: solid black background with verdict
      rect(TABLE_X, y, TABLE_W, ROW_H - 2, BLACK);
    } else {
      rect(TABLE_X + 8, y + ROW_H - 2, TABLE_W - 8, 1, LIGHT);
    }
    if (danger && !sel) box(TABLE_X + 8, y - 2, TABLE_W - 8, ROW_H - 2, BLACK);

    int bx = has_gps ? 226 : (has_pos ? 235 : 260);
    int bw = has_gps ? 42 : (has_pos ? 45 : 50);
    int max_id_w = bx - (TABLE_X + 8) - 10;

    // Line 1: ID string with pixel-width truncation to guarantee it never overflows into RSSI
    char id_b[32];
    const char* src_id = t->uas[0] ? t->uas : "(no id)";
    strncpy(id_b, src_id, sizeof(id_b) - 1);
    id_b[sizeof(id_b) - 1] = 0;
    if (text_w(&FreeSansBold12pt7b, id_b) > max_id_w) {
      int len = strlen(id_b);
      while (len > 2) {
        id_b[len - 1] = 0;
        char temp[32];
        snprintf(temp, sizeof(temp), "%s..", id_b);
        if (text_w(&FreeSansBold12pt7b, temp) <= max_id_w) {
          strcpy(id_b, temp);
          break;
        }
        len--;
      }
    }
    text(&FreeSansBold12pt7b, id_b, TABLE_X + 8, y + 20, ink);

    // Line 2: Verdict on selected row, or alert status on unselected
    if (sel) {
      char v[64];
      uint32_t age_s = (s_now - t->last_ms) / 1000;
      char age_buf[16];
      if (age_s < 10) snprintf(age_buf, sizeof(age_buf), "now");
      else if (age_s < 60) snprintf(age_buf, sizeof(age_buf), "%lus", (unsigned long)age_s);
      else snprintf(age_buf, sizeof(age_buf), "%lum", (unsigned long)(age_s / 60));

      snprintf(v, sizeof(v), "%s%s  %s  %s%s%s  %s",
               t->in_tfr ? "IN TFR • " : "",
               ui_status_name(t->status),
               ui_auth_text(t->auth_state),
               (t->src_mask & 1) ? "W" : "", (t->src_mask & 2) ? "N" : "", (t->src_mask & 4) ? "B" : "",
               age_buf);
      if (text_w(f9, v) > max_id_w) {
        int vlen = strlen(v);
        while (vlen > 2) {
          v[vlen - 1] = 0;
          char vtemp[64];
          snprintf(vtemp, sizeof(vtemp), "%s..", v);
          if (text_w(f9, vtemp) <= max_id_w) {
            strcpy(v, vtemp);
            break;
          }
          vlen--;
        }
      }
      text(f9, v, TABLE_X + 8, y + 36, WHITE);
    } else {
      if (t->in_tfr) text(f9, "IN TFR", TABLE_X + 8, y + 36, BLACK);
      else if (t->status == 3) text(f9, "EMERGENCY", TABLE_X + 8, y + 36, BLACK);
    }

    // rssi bar
    box(bx, y + 6, bw, 8, ink);
    rect(bx, y + 6, (int)(bw * ui_rssi01(t->rssi)), 8, ink);
    char rb[16]; snprintf(rb, sizeof(rb), "%d", t->rssi); text(f9, rb, bx, y + 34, ink);

    int hgt_x = has_gps ? 286 : (has_pos ? 300 : 335);
    if (!isnan(t->height)) { char hb[16]; snprintf(hb, sizeof(hb), "%dm", (int)t->height); text(f9, hb, hgt_x, y + 20, ink); }

    int spd_x = has_gps ? 346 : (has_pos ? 365 : 410);
    if (!isnan(t->speed))  { char sb[16]; snprintf(sb, sizeof(sb), "%.0f", t->speed);       text(f9, sb, spd_x, y + 20, ink); }

    if (has_pos && t->has_pos) {
      int rng_x = has_gps ? 406 : 430;
      char r[10]; ui_fmt_range(r, sizeof(r), ui_dist_m(g_home_lat, g_home_lon, t->lat, t->lon));
      text(f9, r, rng_x, y + 20, ink);
      if (has_gps) {
        char bb[16]; snprintf(bb, sizeof(bb), "%03d", (int)ui_bearing(g_home_lat, g_home_lon, t->lat, t->lon));
        text(f9, bb, 466, y + 20, ink);
      }
    }
    if (t->auth_state) {
      const char* a = t->auth_state == 3 ? "OK" : t->auth_state == 4 ? "BAD"
                    : t->auth_state == 2 ? "?" : "...";       // column is headed AUTH
      int auth_x = has_gps ? 512 : (has_pos ? 510 : 495);
      if (!sel && t->auth_state == 4) {
        rect(auth_x - 4, y + 4, 34, 18, BLACK);
        text(f9, a, auth_x, y + 17, WHITE);
      } else {
        text(f9, a, auth_x, y + 20, ink);
      }
    }
  if (!s_n) {
    int tw_scan = text_w(&FreeSansBold18pt7b, "SCANNING");
    text(&FreeSansBold18pt7b, "SCANNING", TABLE_X + (TABLE_W - tw_scan) / 2, y0 + 180, BLACK);
  }
}

static double nice_scale(double m) {
  static const double S[] = { 100, 250, 500, 1000, 2000, 5000, 10000 };
  for (double s : S) if (m <= s) return s;
  return 20000;
}

static void draw_plot() {
  if (g_home_set) {
    double far = 0;
    for (int k = 0; k < s_n; k++) {
      const Track* t = &g_tracks[s_order[k]];
      if (t->has_pos) { double d = ui_dist_m(g_home_lat, g_home_lon, t->lat, t->lon); if (d > far) far = d; }
    }
    double scale = nice_scale(far > 0 ? far * 1.1 : 500);
    for (int i = 1; i <= 3; i++) epd_draw_circle(PLOT_CX, PLOT_CY, PLOT_R * i / 3, i == 3 ? BLACK : GREY, s_fb);
    epd_draw_line(PLOT_CX, PLOT_CY - PLOT_R, PLOT_CX, PLOT_CY + PLOT_R, LIGHT, s_fb);
    epd_draw_line(PLOT_CX - PLOT_R, PLOT_CY, PLOT_CX + PLOT_R, PLOT_CY, LIGHT, s_fb);
    text(&FreeSansBold9pt7b, "N", PLOT_CX - 6, PLOT_CY - PLOT_R - 8, BLACK);
    // Range rings at 1/3, 2/3, and full scale
    for (int i = 1; i <= 3; i++) {
      char rb[16];
      double rd = scale * i / 3.0;
      if (rd >= 1000) snprintf(rb, sizeof(rb), "%.1fkm", rd / 1000.0);
      else snprintf(rb, sizeof(rb), "%.0fm", rd);
      int ry = PLOT_CY + (PLOT_R * i / 3);
      text(&FreeSansBold9pt7b, rb, PLOT_CX + 6, ry - 3, GREY);
    }
    epd_fill_circle(PLOT_CX, PLOT_CY, 4, BLACK, s_fb);

    for (int k = 0; k < s_n; k++) {
      const Track* t = &g_tracks[s_order[k]];
      if (!t->has_pos) continue;
      double d = ui_dist_m(g_home_lat, g_home_lon, t->lat, t->lon);
      double br = ui_bearing(g_home_lat, g_home_lon, t->lat, t->lon) * M_PI / 180;
      int px = PLOT_CX + (int)(sin(br) * d / scale * PLOT_R);
      int py = PLOT_CY - (int)(cos(br) * d / scale * PLOT_R);
      bool stale = ui_stale(t, s_now), danger = ui_danger(t, s_now);
      if (danger) epd_draw_circle(px, py, 12, BLACK, s_fb);
      epd_fill_circle(px, py, k == s_sel ? 8 : 6, stale ? GREY : BLACK, s_fb);
      if (!isnan(t->heading)) {
        double hr = t->heading * M_PI / 180;
        epd_draw_line(px, py, px + (int)(sin(hr) * 18), py - (int)(cos(hr) * 18), BLACK, s_fb);
      }
      char b[16];
      snprintf(b, sizeof(b), "%s", uas_tail(t->uas, 8));
      int tw = text_w(&FreeSansBold9pt7b, b);
      int box_w = tw + 6;
      int bx = px + 8;
      if (bx + box_w > W - 8) bx = px - 8 - box_w;
      if (bx < 568) bx = 568;
      rect(bx, py - 18, box_w, 16, WHITE);
      box(bx, py - 18, box_w, 16, stale ? GREY : BLACK);
      text(&FreeSansBold9pt7b, b, bx + 3, py - 6, stale ? GREY : BLACK);
    }
  } else {
    // No operator fix: Signal Strength Ladder (no circles underneath!)
    text(&FreeSansBold12pt7b, "PROXIMITY (RSSI)", PLOT_CX - PLOT_R, 106, BLACK);
    text(&FreeSansBold9pt7b, "NO OPERATOR FIX  •  TAP FOR MAP", PLOT_CX - PLOT_R, 126, BLACK);
    int y = 144;
    for (int k = 0; k < s_n && k < 7; k++) {
      const Track* t = &g_tracks[s_order[k]];
      bool sel = k == s_sel;
      if (sel) {
        rect(PLOT_CX - PLOT_R - 4, y, 6, 38, BLACK);
        box(PLOT_CX - PLOT_R + 4, y, PLOT_R * 2 - 4, 38, BLACK);
      }
      char b[32];
      snprintf(b, sizeof(b), "%.14s", t->uas[0] ? t->uas : "(no id)");
      text(&FreeSansBold9pt7b, b, PLOT_CX - PLOT_R + 10, y + 16, BLACK);
      snprintf(b, sizeof(b), "%d dBm", t->rssi);
      text_r(&FreeSansBold9pt7b, b, PLOT_CX + PLOT_R - 4, y + 16, BLACK);

      int bw = PLOT_R * 2 - 14;
      box(PLOT_CX - PLOT_R + 10, y + 22, bw, 10, BLACK);
      int fill = (int)(bw * ui_rssi01(t->rssi));
      if (fill > 0) rect(PLOT_CX - PLOT_R + 10, y + 22, fill, 10, ui_stale(t, s_now) ? GREY : BLACK);
      y += 46;
    }
    if (!s_n) {
      int tw1 = text_w(&FreeSansBold12pt7b, "WAITING FOR SIGNALS");
      text(&FreeSansBold12pt7b, "WAITING FOR SIGNALS", PLOT_CX - tw1 / 2, 260, BLACK);
      int tw2 = text_w(&FreeSansBold9pt7b, "Listening on BLE, Wi-Fi Beacon & NAN");
      text(&FreeSansBold9pt7b, "Listening on BLE, Wi-Fi Beacon & NAN", PLOT_CX - tw2 / 2, 290, GREY);
    }
  }
}


// ---- offline map: tiles from the shared store, inverted into greys
#define MAP_Y0   72
#define MAP_H    426
#define MAP_CX   (W / 2)
#define MAP_CY   (MAP_Y0 + MAP_H / 2)
#define TILE_ZMIN 11
#define TILE_ZMAX 15
static PNG  s_png;
static File s_pngFile;
static int  s_blit_x, s_blit_y;             // screen origin of the tile being decoded

static void world_px(double lat, double lon, int z, double* wx, double* wy) {
  double n = 256.0 * (double)(1L << z);
  *wx = (lon + 180.0) / 360.0 * n;
  double rad = lat * M_PI / 180.0;
  *wy = (1.0 - log(tan(rad) + 1.0 / cos(rad)) / M_PI) / 2.0 * n;
}
static void px_world(double wx, double wy, int z, double* lat, double* lon) {
  double n = 256.0 * (double)(1L << z);
  *lon = wx / n * 360.0 - 180.0;
  double y = M_PI * (1.0 - 2.0 * wy / n);
  *lat = atan(sinh(y)) * 180.0 / M_PI;
}
bool ui_map_center(double* lat, double* lon) {
  if (!s_cam_valid) { if (!g_home_set) return false; *lat = g_home_lat; *lon = g_home_lon; return true; }
  px_world(s_cam_wx, s_cam_wy, s_cam_z, lat, lon);
  return true;
}

// Frame the operator and every live, positioned contact: the deepest zoom
// at which they all fit with a margin. One point alone gets a 2 km window.
static void map_camera() {
  if (s_cam_manual) return;
  double lats[TRK_MAX + 1], lons[TRK_MAX + 1]; int n = 0;
  if (g_home_set) { lats[n] = g_home_lat; lons[n] = g_home_lon; n++; }
  for (int k = 0; k < s_n; k++) {
    const Track* t = &g_tracks[s_order[k]];
    if (t->has_pos && !ui_stale(t, s_now)) { lats[n] = t->lat; lons[n] = t->lon; n++; }
  }
  if (!n) {
    if (s_cam_valid) return;
    lats[0] = 37.7749; lons[0] = -122.4194; n = 1;   // nothing known yet
  }
  for (int z = TILE_ZMAX; z >= TILE_ZMIN; z--) {
    double x0 = 1e18, x1 = -1e18, y0 = 1e18, y1 = -1e18;
    for (int i = 0; i < n; i++) {
      double wx, wy; world_px(lats[i], lons[i], z, &wx, &wy);
      if (wx < x0) x0 = wx; if (wx > x1) x1 = wx; if (wy < y0) y0 = wy; if (wy > y1) y1 = wy;
    }
    bool fits = (x1 - x0) < W - 120 && (y1 - y0) < MAP_H - 100;
    if ((fits && (n > 1 || z == 14)) || z == TILE_ZMIN) {
      s_cam_z = z; s_cam_wx = (x0 + x1) / 2; s_cam_wy = (y0 + y1) / 2; s_cam_valid = true;
      return;
    }
  }
}

static void* pngOpenCb(const char* fn, int32_t* size) {
  s_pngFile = LittleFS.open(fn, "r");
  if (!s_pngFile) return nullptr;
  *size = s_pngFile.size();
  return &s_pngFile;
}
static void pngCloseCb(void*) { if (s_pngFile) s_pngFile.close(); }
static int32_t pngReadCb(PNGFILE*, uint8_t* buf, int32_t len) { return s_pngFile.read(buf, len); }
static int32_t pngSeekCb(PNGFILE*, int32_t pos) { return s_pngFile.seek(pos) ? pos : -1; }
static int pngDrawCb(PNGDRAW* d) {
  static uint16_t line[256];
  if (d->iWidth > (int)(sizeof(line) / sizeof(line[0]))) return 0;
  int y = s_blit_y + d->y;
  if (y < MAP_Y0 || y >= MAP_Y0 + MAP_H) return 1;
  s_png.getLineAsRGB565(d, line, PNG_RGB565_LITTLE_ENDIAN, 0xffffffff);
  for (int i = 0; i < d->iWidth; i++) {
    int x = s_blit_x + i;
    if (x < 0 || x >= W) continue;
    uint16_t c = line[i];
    int r = (c >> 11) << 3, g = ((c >> 5) & 0x3F) << 2, b = (c & 0x1F) << 3;
    int luma = (r * 77 + g * 150 + b * 29) >> 8;
    // dark_all inverted: background near white, roads mid-grey, labels dark.
    // A gentle gamma keeps faint roads from vanishing on the panel.
    int g16 = 255 - luma; g16 = g16 < 40 ? g16 : 40 + (g16 - 40) * 215 / 215;
    epd_draw_pixel(x, y, (uint8_t)(g16 & 0xF0), s_fb);
  }
  return 1;
}

static void draw_map() {
  map_camera();
  // tiles covering the window
  double left = s_cam_wx - W / 2.0, top = s_cam_wy - MAP_H / 2.0;
  long tx0 = (long)floor(left / 256), ty0 = (long)floor(top / 256);
  long tx1 = (long)floor((left + W) / 256), ty1 = (long)floor((top + MAP_H) / 256);
  long tmax = (1L << s_cam_z) - 1;
  int tiles_drawn = 0;
  for (long ty = ty0; ty <= ty1; ty++) {
    for (long tx = tx0; tx <= tx1; tx++) {
      s_blit_x = (int)(tx * 256 - left);
      s_blit_y = MAP_Y0 + (int)(ty * 256 - top);
      if (tx >= 0 && ty >= 0 && tx <= tmax && ty <= tmax) {
        char path[48];
        snprintf(path, sizeof(path), "/tiles/%d/%ld/%ld.png", s_cam_z, tx, ty);
        if (s_png.open(path, pngOpenCb, pngCloseCb, pngReadCb, pngSeekCb, pngDrawCb) == PNG_SUCCESS) {
          if (s_png.getWidth() <= 256) {
            s_png.decode(nullptr, 0);
            tiles_drawn++;
          }
          s_png.close();
        }
      }
    }
  }

  // If raster tiles are missing, draw a crisp tactical navigation basemap grid:
  if (!tiles_drawn) {
    // 1. Light coordinate grid lines
    for (int gx = 64; gx < W; gx += 128) {
      epd_draw_line(gx, MAP_Y0, gx, MAP_Y0 + MAP_H, LIGHT, s_fb);
    }
    for (int gy = MAP_Y0 + 64; gy < MAP_Y0 + MAP_H; gy += 100) {
      epd_draw_line(0, gy, W, gy, LIGHT, s_fb);
    }
    // 2. Concentric range rings from center of viewport
    int cx = MAP_CX, cy = MAP_CY;
    epd_draw_circle(cx, cy, 80, LIGHT, s_fb);
    epd_draw_circle(cx, cy, 160, LIGHT, s_fb);
    epd_draw_circle(cx, cy, 240, LIGHT, s_fb);
    epd_draw_line(cx - 240, cy, cx + 240, cy, GREY, s_fb);
    epd_draw_line(cx, cy - 180, cx, cy + 180, GREY, s_fb);
    text(&FreeSansBold9pt7b, "N", cx - 5, cy - 190, BLACK);
    text(&FreeSansBold9pt7b, "S", cx - 4, cy + 200, GREY);
    text(&FreeSansBold9pt7b, "W", cx - 258, cy + 4, GREY);
    text(&FreeSansBold9pt7b, "E", cx + 246, cy + 4, GREY);

    // Pill badge: Tactical basemap
    rect(20, MAP_Y0 + 8, 220, 28, WHITE);
    box(20, MAP_Y0 + 8, 220, 28, BLACK);
    box(21, MAP_Y0 + 9, 218, 26, BLACK);
    text(&FreeSansBold9pt7b, "TACTICAL GRID", 32, MAP_Y0 + 26, BLACK);

    if (!s_n && !g_home_set) {
      rect(cx - 160, cy - 28, 320, 56, WHITE);
      box(cx - 160, cy - 28, 320, 56, BLACK);
      text(&FreeSansBold12pt7b, "TACTICAL MAP ACTIVE", cx - 110, cy - 4, BLACK);
      text(&FreeSansBold9pt7b, "Sync CARTO tiles via Orecchino app", cx - 120, cy + 18, GREY);
    }
  } else {
    // Raster tiles present
    rect(20, MAP_Y0 + 8, 130, 28, WHITE);
    box(20, MAP_Y0 + 8, 130, 28, BLACK);
    box(21, MAP_Y0 + 9, 128, 26, BLACK);
    char b[32]; snprintf(b, sizeof(b), "MAP  Z%d", s_cam_z);
    text(&FreeSansBold9pt7b, b, 30, MAP_Y0 + 26, BLACK);
  }

  // overlay: home, contacts, scale, north
  if (g_home_set) {
    double wx, wy; world_px(g_home_lat, g_home_lon, s_cam_z, &wx, &wy);
    int x = (int)(wx - left), y = MAP_Y0 + (int)(wy - top);
    if (x >= 0 && x < W && y >= MAP_Y0 && y < MAP_Y0 + MAP_H) {
      epd_fill_circle(x, y, 5, BLACK, s_fb);
      epd_draw_circle(x, y, 10, BLACK, s_fb);
      rect(x + 12, y - 12, 48, 16, WHITE);
      text(&FreeSansBold9pt7b, "HOME", x + 14, y, BLACK);
    }
  }

  char b[32];
  for (int k = 0; k < s_n; k++) {
    const Track* t = &g_tracks[s_order[k]];
    if (!t->has_pos) continue;
    double wx, wy; world_px(t->lat, t->lon, s_cam_z, &wx, &wy);
    int x = (int)(wx - left), y = MAP_Y0 + (int)(wy - top);
    if (x < 0 || x >= W || y < MAP_Y0 || y >= MAP_Y0 + MAP_H) continue;
    bool stale = ui_stale(t, s_now), danger = ui_danger(t, s_now);
    epd_fill_circle(x, y, danger ? 15 : 11, WHITE, s_fb);
    if (danger) epd_draw_circle(x, y, 13, BLACK, s_fb);
    epd_fill_circle(x, y, k == s_sel ? 8 : 6, stale ? GREY : BLACK, s_fb);
    if (!isnan(t->heading)) {
      double hr = t->heading * M_PI / 180;
      epd_draw_line(x, y, x + (int)(sin(hr) * 20), y - (int)(cos(hr) * 20), BLACK, s_fb);
    }
    snprintf(b, sizeof(b), "%s", uas_tail(t->uas, 8));
    int tw = text_w(&FreeSansBold9pt7b, b);
    int box_w = tw + 8;
    int bx = x + 10;
    if (bx + box_w > W - 8) bx = x - 10 - box_w;
    if (bx < 8) bx = 8;
    int by = y - 20;
    if (by < MAP_Y0 + 4) by = y + 10;
    rect(bx, by, box_w, 18, WHITE);
    box(bx, by, box_w, 18, stale ? GREY : BLACK);
    text(&FreeSansBold9pt7b, b, bx + 4, by + 14, stale ? GREY : BLACK);
  }

  // scale bar: 100 px in metres at this zoom and latitude
  double clat, clon; px_world(s_cam_wx, s_cam_wy, s_cam_z, &clat, &clon);
  double m_per_px = 156543.03 * cos(clat * M_PI / 180) / (double)(1L << s_cam_z);
  double bar_m = m_per_px * 100;
  if (bar_m >= 1000) snprintf(b, sizeof(b), "%.1f km", bar_m / 1000); else snprintf(b, sizeof(b), "%d m", (int)bar_m);
  rect(20, MAP_Y0 + MAP_H - 32, 160, 26, WHITE);
  box(20, MAP_Y0 + MAP_H - 32, 160, 26, BLACK);
  box(21, MAP_Y0 + MAP_H - 31, 158, 24, BLACK);
  rect(28, MAP_Y0 + MAP_H - 16, 80, 4, BLACK);
  text(&FreeSansBold9pt7b, b, 114, MAP_Y0 + MAP_H - 14, BLACK);

  // Compass Rose top-right
  rect(W - 48, MAP_Y0 + 8, 36, 36, WHITE);
  box(W - 48, MAP_Y0 + 8, 36, 36, BLACK);
  box(W - 47, MAP_Y0 + 9, 34, 34, BLACK);
  text(&FreeSansBold12pt7b, "N", W - 38, MAP_Y0 + 32, BLACK);

  // touch zoom boxes, right edge
  for (int i = 0; i < 2; i++) {
    int by = MAP_Y0 + 56 + i * 54;
    rect(W - 54, by, 44, 44, WHITE);
    box(W - 54, by, 44, 44, BLACK);
    box(W - 53, by + 1, 42, 42, BLACK);
    text(&FreeSansBold18pt7b, i ? "-" : "+", W - 40, by + 32, BLACK);
  }
  if (s_cam_manual) {
    int pw = 140, ph = 26;
    int px = 20, py = MAP_Y0 + 8;
    rect(px, py, pw, ph, WHITE);
    box(px, py, pw, ph, BLACK);
    text(&FreeSansBold9pt7b, "MANUAL PAN", px + 10, py + 18, BLACK);
  }

  UiSummary sm; ui_summarize(&sm, s_now);
  draw_header(sm, nullptr);
  draw_footer(sm, !s_map_touched ? "tap marker: select · tap: recentre · drag: pan" : "tap or button: table · hold: spectrum");
}

static void refresh(bool force_full) {
  // E-Paper Best Practice: Full DC-balanced GC16 refresh on view changes,
  // alert state transitions, or periodically every 12 partial cycles / 3 minutes
  // to eliminate residual charge and ghosting.
  // In spectrum mode, suppress rapid 12-cycle GC16 flashes to protect the panel and avoid
  // jarring visual disruptions; full wipes occur on view entry and exit.
  bool full = force_full || (!s_spec && (s_partials >= 12 || (s_now - s_last_full > 180000UL)))
                         || (s_spec && (s_now - s_last_full > 300000UL));
  epd_poweron();
  epd_hl_update_screen(&s_hl, full ? MODE_GC16 : MODE_GL16, TEMP_C);
  epd_poweroff();
  if (full) { s_partials = 0; s_last_full = s_now; } else s_partials++;
}

static void draw_switch_modal() {
  int mw = 580, mh = 260;
  int mx = (W - mw) / 2, my = (H - mh) / 2;
  // White card with thick multi-stroke border
  rect(mx, my, mw, mh, WHITE);
  box(mx, my, mw, mh, BLACK);
  box(mx + 1, my + 1, mw - 2, mh - 2, BLACK);
  box(mx + 3, my + 3, mw - 6, mh - 6, BLACK);

  const char* title = (s_target_mode == UI_MODE_TX) ? "SWITCH TO TEST BEACON?" : "SWITCH TO RECEIVER?";
  int tw = text_w(&FreeSansBold18pt7b, title);
  text(&FreeSansBold18pt7b, title, mx + (mw - tw) / 2, my + 48, BLACK);

  const char* l1 = (s_target_mode == UI_MODE_TX) ?
    "The board will reboot into Test Beacon mode." :
    "The board will reboot into Remote ID Receiver mode.";
  const char* l2 = (s_target_mode == UI_MODE_TX) ?
    "Radios will reinitialize to transmit test signals on 2.4 GHz." :
    "Radios will listen for Remote ID broadcasts on BLE and Wi-Fi.";

  text(&FreeSansBold9pt7b, l1, mx + (mw - text_w(&FreeSansBold9pt7b, l1)) / 2, my + 92, BLACK);
  text(&FreeSansBold9pt7b, l2, mx + (mw - text_w(&FreeSansBold9pt7b, l2)) / 2, my + 118, GREY);

  int bw = 220, bh = 54, by = my + 164;
  int bx_ok = mx + 45;
  int bx_can = mx + mw - 45 - bw;

  // OK button (solid black)
  rect(bx_ok, by, bw, bh, BLACK);
  const char* ok_txt = (s_target_mode == UI_MODE_TX) ? "REBOOT TO TX" : "REBOOT TO RX";
  text(&FreeSansBold12pt7b, ok_txt, bx_ok + (bw - text_w(&FreeSansBold12pt7b, ok_txt)) / 2, by + 35, WHITE);

  // Cancel button (outline)
  box(bx_can, by, bw, bh, BLACK);
  box(bx_can + 1, by + 1, bw - 2, bh - 2, BLACK);
  text(&FreeSansBold12pt7b, "CANCEL", bx_can + (bw - text_w(&FreeSansBold12pt7b, "CANCEL")) / 2, by + 35, BLACK);
}

static void draw_tx() {
  bool running = txui_running();
  rect(0, 0, W, 70, running ? BLACK : WHITE);
  if (!running) rect(0, 68, W, 2, BLACK);
  uint8_t fg = running ? WHITE : BLACK, mut = running ? WHITE : BLACK;

  // Headline
  text(&FreeSansBold18pt7b, running ? "TEST BEACON  ON AIR" : "TEST BEACON  PAUSED", TABLE_X, 48, fg);

  // Status tally
  int n = txui_count();
  int on = 0;
  uint32_t total_sent = 0;
  for (int i = 0; i < n; i++) {
    if (txui_enabled(i)) on++;
    total_sent += txui_sent(i);
  }
  char st_b[48];
  snprintf(st_b, sizeof(st_b), "%d/%d ACTIVE  •  %lu PKTS", on, n, (unsigned long)total_sent);
  text(&FreeSansBold9pt7b, st_b, 410, 45, mut);

  // Battery, backlight, and RX mode button on right
  int xr = W - 170;
  if (s_batt >= 0) {
    char bb[16]; snprintf(bb, sizeof(bb), "%d%%", s_batt);
    text_r(&FreeSansBold12pt7b, bb, xr, 44, mut);
    xr -= text_w(&FreeSansBold12pt7b, bb) + 16;
  }
  if (periph_bl_is_active()) {
    text_r(&FreeSansBold12pt7b, "[BL]", xr, 44, fg);
  }

  // [ RX MODE ] button
  const int rx_btn_w = 130, rx_btn_h = 46, rx_btn_x = W - 150, rx_btn_y = 12;
  box(rx_btn_x, rx_btn_y, rx_btn_w, rx_btn_h, fg);
  box(rx_btn_x + 1, rx_btn_y + 1, rx_btn_w - 2, rx_btn_h - 2, fg);
  int tw_rx = text_w(&FreeSansBold12pt7b, "RX MODE");
  text(&FreeSansBold12pt7b, "RX MODE", rx_btn_x + (rx_btn_w - tw_rx) / 2, 41, fg);

  // Master Controls Row (y: 78..138)
  rect(TABLE_X, 138, W - TABLE_X * 2, 2, BLACK);

  // Button 1: Transmit [ON / OFF]
  int tx_w = 210, tx_h = 46, tx_x = 20, tx_y = 82;
  if (running) {
    rect(tx_x, tx_y, tx_w, tx_h, BLACK);
    const char* lbl = "TRANSMIT [ON]";
    text(&FreeSansBold12pt7b, lbl, tx_x + (tx_w - text_w(&FreeSansBold12pt7b, lbl)) / 2, tx_y + 30, WHITE);
  } else {
    box(tx_x, tx_y, tx_w, tx_h, BLACK);
    box(tx_x + 1, tx_y + 1, tx_w - 2, tx_h - 2, BLACK);
    const char* lbl = "TRANSMIT [OFF]";
    text(&FreeSansBold12pt7b, lbl, tx_x + (tx_w - text_w(&FreeSansBold12pt7b, lbl)) / 2, tx_y + 30, BLACK);
  }

  // Button 2: Emergency [ON / OFF]
  bool em = txui_emergency();
  int em_w = 230, em_h = 46, em_x = 245, em_y = 82;
  if (em) {
    rect(em_x, em_y, em_w, em_h, BLACK);
    const char* lbl = "EMERGENCY [ON]";
    text(&FreeSansBold12pt7b, lbl, em_x + (em_w - text_w(&FreeSansBold12pt7b, lbl)) / 2, em_y + 30, WHITE);
  } else {
    box(em_x, em_y, em_w, em_h, BLACK);
    box(em_x + 1, em_y + 1, em_w - 2, em_h - 2, BLACK);
    const char* lbl = "EMERGENCY [OFF]";
    text(&FreeSansBold12pt7b, lbl, em_x + (em_w - text_w(&FreeSansBold12pt7b, lbl)) / 2, em_y + 30, BLACK);
  }

  // Button 3: [ ALL ON ]
  int aon_w = 115, aon_h = 46, aon_x = 490, aon_y = 82;
  box(aon_x, aon_y, aon_w, aon_h, BLACK);
  box(aon_x + 1, aon_y + 1, aon_w - 2, aon_h - 2, BLACK);
  text(&FreeSansBold12pt7b, "ALL ON", aon_x + (aon_w - text_w(&FreeSansBold12pt7b, "ALL ON")) / 2, aon_y + 30, BLACK);

  // Button 4: [ ALL OFF ]
  int aoff_w = 120, aoff_h = 46, aoff_x = 620, aoff_y = 82;
  box(aoff_x, aoff_y, aoff_w, aoff_h, BLACK);
  box(aoff_x + 1, aoff_y + 1, aoff_w - 2, aoff_h - 2, BLACK);
  text(&FreeSansBold12pt7b, "ALL OFF", aoff_x + (aoff_w - text_w(&FreeSansBold12pt7b, "ALL OFF")) / 2, aoff_y + 30, BLACK);

  // Band label on right
  text(&FreeSansBold9pt7b, "CH 6  •  2.4 GHz", 765, 102, BLACK);
  text(&FreeSansBold9pt7b, "TEST BENCH RADIATOR", 765, 120, BLACK);

  // 10 Transmit Paths Grid (y: 146..488)
  const int card_w = 450, card_h = 58, row_pitch = 68;
  const GFXfont* f9 = &FreeSansBold9pt7b;
  const GFXfont* f12 = &FreeSansBold12pt7b;

  for (int col = 0; col < 2; col++) {
    int x0 = col == 0 ? 20 : 490;
    for (int r = 0; r < 5; r++) {
      int i = col * 5 + r;
      if (i >= n) break;
      int y = 146 + r * row_pitch;
      bool path_on = txui_enabled(i);

      // Card outer box: crisp 1px black outline, active gets 2px bold frame
      box(x0, y, card_w, card_h, BLACK);
      if (path_on) box(x0 + 1, y + 1, card_w - 2, card_h - 2, BLACK);

      // Left toggle pill: [ ON ] / [ OFF ]
      int pw = 58, ph = 38, px = x0 + 10, py = y + 10;
      if (path_on) {
        rect(px, py, pw, ph, BLACK);
        text(f12, "ON", px + (pw - text_w(f12, "ON")) / 2, py + 26, WHITE);
      } else {
        box(px, py, pw, ph, BLACK);
        text(f12, "OFF", px + (pw - text_w(f12, "OFF")) / 2, py + 26, BLACK);
      }

      // Carrier badge: inverted black fill (active) or 1px outline box with black text (disabled)
      const char* carr = txui_carrier(i);
      int cw = text_w(f9, carr) + 12;
      int cx = x0 + 78, cy = y + 10;
      if (path_on) {
        rect(cx, cy, cw, 18, BLACK);
        text(f9, carr, cx + 6, cy + 14, WHITE);
      } else {
        box(cx, cy, cw, 18, BLACK);
        text(f9, carr, cx + 6, cy + 14, BLACK);
      }

      // Packet count on right
      char cb[20];
      snprintf(cb, sizeof(cb), "%lu pkts", (unsigned long)txui_sent(i));
      int cnt_w = text_w(f9, cb);

      // UAS ID with pixel-width truncation to prevent collision with packet counter
      int id_x = cx + cw + 10;
      int max_id_w = (x0 + card_w - 14 - cnt_w - 10) - id_x;
      if (max_id_w < 50) max_id_w = 50;

      char id_b[32];
      const char* raw_id = txui_id(i);
      strncpy(id_b, raw_id ? raw_id : "", sizeof(id_b) - 1);
      id_b[sizeof(id_b) - 1] = 0;
      if (text_w(f12, id_b) > max_id_w) {
        int len = strlen(id_b);
        while (len > 2) {
          id_b[len - 1] = 0;
          char temp[32];
          snprintf(temp, sizeof(temp), "%s..", id_b);
          if (text_w(f12, temp) <= max_id_w) {
            strcpy(id_b, temp);
            break;
          }
          len--;
        }
      }
      text(f12, id_b, id_x, y + 26, BLACK);

      // Subtitle (self desc)
      text(f9, txui_desc(i), cx, y + 46, BLACK);

      text_r(f9, cb, x0 + card_w - 12, y + 34, BLACK);
    }
  }

  // Footer (y: 496..540)
  rect(0, 496, W, 44, WHITE);
  rect(0, 496, W, 2, BLACK);
  text(f9, running ? "TRANSMITTING TEST BURSTS · DO NOT RADIATE NEAR LIVE AIRSPACE" :
                     "TRANSMIT PAUSED · CONFIGURE PATHS AND TAP [TRANSMIT] TO RADIATE",
       TABLE_X, 524, BLACK);
  text_r(f9, "tap card to toggle · hold BOOT: rx mode", W - 20, 524, BLACK);
}

static void draw_board(bool force_full) {
  epd_hl_set_all_white(&s_hl);
  if (s_mode == UI_MODE_TX) {
    draw_tx();
    if (s_confirm_switch) draw_switch_modal();
    refresh(force_full);
    return;
  }
  UiSummary sm; ui_summarize(&sm, s_now);
  if (s_map) {
    draw_map();
    if (s_confirm_switch) draw_switch_modal();
    refresh(force_full);
    s_alert_prev = sm.alert;
    return;
  }
  draw_header(sm, nullptr);
  draw_table();
  draw_plot();
  draw_footer(sm, "tap a row · button: next contact · hold: spectrum");
  if (s_confirm_switch) draw_switch_modal();
  refresh(force_full || sm.alert != s_alert_prev);
  s_alert_prev = sm.alert;
}

static void draw_spectrum() {
  epd_hl_set_all_white(&s_hl);
  UiSummary sm = {}; sm.alert = UI_QUIET; sm.newest_age_s = UINT32_MAX;
  draw_header(sm, s_sx_ok ? "SPECTRUM  850-930 MHz" : "SPECTRUM (2.4G)");
  // 2.4 GHz bars
  for (int c = 1; c <= 13; c++) {
    uint16_t cnt = s_wcnt[c];
    int32_t sum = s_wsum[c];
    s_wcnt[c] = 0;
    s_wsum[c] = 0;
    if (cnt) s_a24[c - 1] = s_a24[c - 1] * 0.5f + ((float)sum / cnt) * 0.5f;
    else s_a24[c - 1] -= 1.0f;
    if (s_a24[c - 1] < -115) s_a24[c - 1] = -115;
  }
  text(&FreeSansBold9pt7b, "2.4 GHz CHANNELS", 20, 100, BLACK);
  for (int c = 0; c < 13; c++) {
    float v = (s_a24[c] + 115) / 70.0f; v = v < 0 ? 0 : v > 1 ? 1 : v;
    int h = (int)(80 * v), x = 20 + c * 70;
    // Channel meter frame (height 80px, base at y=200)
    box(x, 120, 56, 80, GREY);
    if (h > 0) {
      rect(x + 2, 200 - h, 52, h, BLACK);
    }
    char b[4]; snprintf(b, sizeof(b), "%d", c + 1);
    int tw_c = text_w(&FreeSansBold9pt7b, b);
    text(&FreeSansBold9pt7b, b, x + (56 - tw_c) / 2, 220, BLACK);
  }
  // sub-GHz trace
  int lo = 0, hi = -127;
  for (int i = 0; i < N_BIN; i++) { if (s_swp[i] < lo) lo = s_swp[i]; if (s_swp[i] > hi) hi = s_swp[i]; }
  int top = hi + 6, bot = lo - 2; if (top - bot < 30) top = bot + 30;
  const int X0 = 20, PW = 920, Y0 = 250, PH = 220;
  box(X0, Y0, PW, PH, BLACK);
  box(X0 + 1, Y0 + 1, PW - 2, PH - 2, BLACK);
  int px = -1, py = -1;
  for (int i = 0; i < N_BIN; i++) {
    int x = X0 + i * PW / N_BIN;
    float v = (float)(s_swp[i] - bot) / (top - bot); v = v < 0 ? 0 : v > 1 ? 1 : v;
    int y = Y0 + PH - (int)(PH * v);
    float vp = (float)(s_pk[i] - bot) / (top - bot); vp = vp < 0 ? 0 : vp > 1 ? 1 : vp;
    int y_pk = Y0 + PH - (int)(PH * vp);
    epd_draw_pixel(x, y_pk, BLACK, s_fb);
    if (y_pk > Y0 + 1) epd_draw_pixel(x, y_pk - 1, BLACK, s_fb);
    if (px >= 0) epd_draw_line(px, py, x, y, BLACK, s_fb);
    px = x; py = y;
  }
  char b[32];
  snprintf(b, sizeof(b), "%d dBm", top); text(&FreeSansBold9pt7b, b, X0 + 6, Y0 + 18, BLACK);
  snprintf(b, sizeof(b), "%d dBm", bot); text(&FreeSansBold9pt7b, b, X0 + 6, Y0 + PH - 8, BLACK);
  struct FreqMark { int freq; const char* label; } FREQS[] = {
    { 850, "850" }, { 868, "868" }, { 890, "890" }, { 915, "915" }, { 930, "930" }
  };
  for (const auto& fm : FREQS) {
    int fx = X0 + (fm.freq - 850) * PW / 80;
    // Tick mark inside the plot box
    epd_draw_line(fx, Y0 + PH - 6, fx, Y0 + PH, BLACK, s_fb);
    // Light grid line through the spectrum box
    if (fx > X0 && fx < X0 + PW) {
      for (int gy = Y0 + 4; gy < Y0 + PH - 6; gy += 6) {
        epd_draw_pixel(fx, gy, LIGHT, s_fb);
      }
    }
    int tw = text_w(&FreeSansBold9pt7b, fm.label);
    int lx = fx - tw / 2;
    if (lx < X0) lx = X0;
    if (lx + tw > X0 + PW) lx = X0 + PW - tw;
    text(&FreeSansBold9pt7b, fm.label, lx, Y0 + PH + 18, BLACK);
  }
  draw_footer(sm, "tap or button: back");
  refresh(false);
}

#define DEFAULT_VCOM 1560
static uint16_t s_vcom = DEFAULT_VCOM;

uint16_t ui_get_vcom() {
  Preferences p;
  p.begin("orecchino", true);
  uint16_t val = p.getUShort("vcom", DEFAULT_VCOM);
  p.end();
  return val;
}

bool ui_set_vcom(uint16_t vcom) {
  // Panel VCOM voltage bounds: -0.5V to -3.0V (500 to 3000 mV)
  if (vcom < 500 || vcom > 3000) return false;
  Preferences p;
  p.begin("orecchino", false);
  p.putUShort("vcom", vcom);
  p.end();
  s_vcom = vcom;
  if (s_ok) {
    epd_set_vcom(s_vcom);
    if (s_spec) {
      draw_spectrum();
      refresh(true);
    } else {
      draw_board(true);
    }
  }
  return true;
}

bool ui_begin(uint8_t mode) {
  s_mode = mode;
  pinMode(PIN_BOOT_BTN, INPUT_PULLUP);
  // The 1 K LUT trades a little refresh time for ~60 KB of internal RAM,
  // which the radio stacks need more than the panel does.
  epd_init(&epd_board_v7, &ED047TC1, EPD_LUT_1K);
  s_vcom = ui_get_vcom();
  epd_set_vcom(s_vcom);
  s_hl = epd_hl_init(EPD_BUILTIN_WAVEFORM);
  epd_set_rotation(EPD_ROT_LANDSCAPE);
  s_fb = epd_hl_get_framebuffer(&s_hl);
  if (!s_fb) return false;
  // Boot: wipe whatever the panel was left holding (e-paper keeps the last
  // image through power-off — often another firmware's), then a splash with
  // a clean full refresh so the panel visibly comes alive before the radios.
  epd_poweron();
  epd_clear();
  epd_hl_set_all_white(&s_hl);
  int w_ore = text_w(&FreeSansBold24pt7b, "ORECCHINO");
  text(&FreeSansBold24pt7b, "ORECCHINO", (W - w_ore) / 2, 250, BLACK);
  const char* sub = (s_mode == UI_MODE_TX) ? "Remote ID test beacon  -  starting transmitter" : "Remote ID receiver  -  starting radios";
  int w_sub = text_w(&FreeSansBold12pt7b, sub);
  text(&FreeSansBold12pt7b, sub, (W - w_sub) / 2, 300, BLACK);
  epd_hl_update_screen(&s_hl, MODE_GC16, TEMP_C);
  epd_poweroff();
  s_ok = true;
  s_now = millis();
  s_last_full = s_now;
  build_order();
  draw_board(true);
  s_sig_prev = signature();
  return true;
}

void ui_tick(uint32_t now, bool ble_ok, int batt_pct, int sync_files) {
  if (!s_ok) return;
  s_now = now; s_ble_ok = ble_ok; s_batt = batt_pct;
  bool syncing = sync_files >= 0;
  static bool was_syncing = false;
  if (syncing != was_syncing) { was_syncing = syncing; if (!syncing) { s_sig_prev = 0; } }

  // BOOT button: tap = next contact, hold 1.5 s = spectrum in/out
  static bool was = false; static uint32_t down = 0; static bool fired = false;
  bool k = digitalRead(PIN_BOOT_BTN) == LOW;
  bool tap = false, hold = false;
  if (k && !was) { down = now; fired = false; }
  if (k && !fired && now - down > 1500) { fired = true; hold = true; }
  if (!k && was && !fired && now - down > 30) tap = true;
  was = k;

  // Capacitive round home button below display
  if (periph_home_key() && !s_spec) {
    if (s_mode == UI_MODE_TX) {
      txui_set_running(!txui_running());
      s_sig_prev = 0;
      draw_board(false);
      return;
    }
    s_map = !s_map;
    s_sig_prev = 0;
    draw_board(true);
    return;
  }

  // touch: tap or drag-release (a slow panel wants whole gestures)
  static bool t_was = false; static int tx0 = 0, ty0 = 0, txl = 0, tyl = 0;
  static uint32_t t_poll = 0;
  int tap_x = -1, tap_y = -1, drag_dx = 0, drag_dy = 0;
  if (now - t_poll >= 30) {
    t_poll = now;
    int rx, ry;
    bool t = periph_touch(&rx, &ry);
    if (t) {
      int mx, my; periph_touch_range(&mx, &my);
      int sx, sy;
      if (mx && my && mx < my) { sx = (int)((long)ry * W / my); sy = (int)((long)(mx - rx) * H / mx); }  // portrait-native panel
      else if (mx && my)       { sx = (int)((long)rx * W / mx); sy = (int)((long)ry * H / my); }
      else                     { sx = rx; sy = ry; }
      if (sx < 0) sx = 0; else if (sx >= W) sx = W - 1;
      if (sy < 0) sy = 0; else if (sy >= H) sy = H - 1;
      if (!t_was) { tx0 = sx; ty0 = sy; Serial.printf("{\"type\":\"touch\",\"raw\":[%d,%d],\"xy\":[%d,%d]}\n", rx, ry, sx, sy); }
      txl = sx; tyl = sy;
    } else if (t_was) {
      if (abs(txl - tx0) < 25 && abs(tyl - ty0) < 25) { tap_x = tx0; tap_y = ty0; }
      else { drag_dx = txl - tx0; drag_dy = tyl - ty0; }
    }
    t_was = t;
  }

  // Confirmation Modal Touch Routing
  if (s_confirm_switch) {
    if (tap_x >= 0) {
      int mw = 580, mh = 260;
      int mx = (W - mw) / 2, my = (H - mh) / 2;
      int bw = 220, bh = 54, by = my + 164;
      int bx_ok = mx + 45;
      int bx_can = mx + mw - 45 - bw;
      if (tap_y >= by && tap_y <= by + bh) {
        if (tap_x >= bx_ok && tap_x <= bx_ok + bw) {
          board_switch_mode(s_target_mode);
          return;
        } else if (tap_x >= bx_can && tap_x <= bx_can + bw) {
          s_confirm_switch = false;
          s_sig_prev = 0;
          draw_board(false);
          return;
        }
      } else if (tap_x < mx || tap_x > mx + mw || tap_y < my || tap_y > my + mh) {
        // Tapped outside modal -> dismiss
        s_confirm_switch = false;
        s_sig_prev = 0;
        draw_board(false);
        return;
      }
    }
    return;
  }

  // ===================== TX MODE UI & INPUT =====================
  if (s_mode == UI_MODE_TX) {
    if (hold) {
      // Holding BOOT button reboots to RX mode
      board_switch_mode(UI_MODE_RX);
      return;
    }
    if (tap) {
      // Tap BOOT button toggles transmit
      txui_set_running(!txui_running());
      s_sig_prev = 0;
      draw_board(false);
      return;
    }
    if (tap_x >= 0) {
      // Top bar [ RX MODE ] button
      if (tap_y <= 70 && tap_x >= W - 160) {
        s_confirm_switch = true;
        s_target_mode = UI_MODE_RX;
        s_sig_prev = 0;
        draw_board(false);
        return;
      }
      // Master Controls Row (y: 78..138)
      if (tap_y >= 78 && tap_y <= 138) {
        if (tap_x >= 20 && tap_x <= 235) {
          txui_set_running(!txui_running());
          s_sig_prev = 0;
          draw_board(false);
          return;
        } else if (tap_x >= 245 && tap_x <= 480) {
          txui_set_emergency(!txui_emergency());
          s_sig_prev = 0;
          draw_board(false);
          return;
        } else if (tap_x >= 490 && tap_x <= 610) {
          for (int i = 0; i < txui_count(); i++) txui_set_enabled(i, true);
          s_sig_prev = 0;
          draw_board(false);
          return;
        } else if (tap_x >= 620 && tap_x <= 745) {
          for (int i = 0; i < txui_count(); i++) txui_set_enabled(i, false);
          s_sig_prev = 0;
          draw_board(false);
          return;
        }
      }
      // 10 Path cards (y: 146..488)
      if (tap_y >= 146 && tap_y <= 488) {
        int r = (tap_y - 146) / 68;
        if (r >= 0 && r < 5) {
          if (tap_x >= 20 && tap_x <= 470) {
            int i = r;
            if (i < txui_count()) {
              txui_set_enabled(i, !txui_enabled(i));
              s_sig_prev = 0;
              draw_board(false);
              return;
            }
          } else if (tap_x >= 490 && tap_x <= 940) {
            int i = r + 5;
            if (i < txui_count()) {
              txui_set_enabled(i, !txui_enabled(i));
              s_sig_prev = 0;
              draw_board(false);
              return;
            }
          }
        }
      }
    }
    // Background refresh budget in TX mode (refresh stats/packet counts every ~5s)
    static uint32_t last_tx_check = 0;
    if (now - last_tx_check >= 4000) {
      last_tx_check = now;
      uint32_t sig = signature();
      if (sig != s_sig_prev || now - s_last_full > 300000UL) {
        s_sig_prev = sig;
        draw_board(false);
      }
    }
    return;
  }

  // ===================== RX MODE UI & INPUT =====================
  if (tap_x >= 0 && !s_spec) {
    // Top bar view switcher tabs & backlight toggle:
    if (tap_y <= 72) {
      if (tap_x >= 248 && tap_x < 328) {
        if (s_map) { s_map = false; s_sig_prev = 0; draw_board(true); return; }
      } else if (tap_x >= 328 && tap_x < 408) {
        if (!s_map) { s_map = true; s_sig_prev = 0; draw_board(true); return; }
      } else if (tap_x >= 408 && tap_x <= 495) {
        s_confirm_switch = true;
        s_target_mode = UI_MODE_TX;
        s_sig_prev = 0;
        draw_board(false);
        return;
      } else if (tap_x >= 680 && tap_x <= 780) {
        // Tap on backlight badge toggles mode (AUTO -> ON -> OFF)
        BlMode m = periph_bl_get_mode();
        periph_bl_set_mode(m == BL_AUTO ? BL_ON : m == BL_ON ? BL_OFF : BL_AUTO);
        s_sig_prev = 0;
        draw_board(false);
        return;
      }
    }
    if (!s_map) {
      if (tap_y >= 104 && tap_y < 104 + ROWS * ROW_H && tap_x < TABLE_X + TABLE_W) {          // a table row
        int k = (tap_y - 104) / ROW_H;
        if (k < s_n) { s_sel = k; s_sig_prev = 0; }
      } else if (tap_x > 560 && tap_y > 70 && tap_y < 496) {        // the plot: go to the map
        s_map = true; s_sig_prev = 0; draw_board(true); return;
      }
    } else {
      s_map_touched = true;
      if (tap_x >= W - 56 && tap_y >= MAP_Y0 + 56 && tap_y < MAP_Y0 + 56 + 110) {   // zoom boxes
        int dz = tap_y < MAP_Y0 + 56 + 54 ? 1 : -1;
        int nz = s_cam_z + dz;
        if (nz >= TILE_ZMIN && nz <= TILE_ZMAX) {
          double f = dz > 0 ? 2.0 : 0.5;
          s_cam_wx *= f; s_cam_wy *= f; s_cam_z = nz; s_cam_manual = true; s_cam_manual_ms = now; s_sig_prev = 0;
        }
      } else if (s_cam_manual && tap_x >= 20 && tap_x <= 310 && tap_y >= MAP_Y0 + 8 && tap_y <= MAP_Y0 + 36) {
        s_cam_manual = false; s_sig_prev = 0;
      } else {
        // a marker near the tap selects it; anywhere else re-centres there
        double left = s_cam_wx - W / 2.0, top = s_cam_wy - MAP_H / 2.0;
        int hit = -1;
        for (int k = 0; k < s_n; k++) {
          const Track* t = &g_tracks[s_order[k]];
          if (!t->has_pos) continue;
          double wx, wy; world_px(t->lat, t->lon, s_cam_z, &wx, &wy);
          int x = (int)(wx - left), y = MAP_Y0 + (int)(wy - top);
          if (abs(x - tap_x) < 28 && abs(y - tap_y) < 28) { hit = k; break; }
        }
        if (hit >= 0) s_sel = hit;
        else { s_cam_wx = left + tap_x; s_cam_wy = top + (tap_y - MAP_Y0); s_cam_manual = true; s_cam_manual_ms = now; }
        s_sig_prev = 0;
      }
    }
  }
  if ((drag_dx || drag_dy) && s_map && !s_spec) {
    s_map_touched = true;
    s_cam_wx -= drag_dx; s_cam_wy -= drag_dy; s_cam_manual = true; s_cam_manual_ms = now; s_sig_prev = 0;
  }
  if (s_cam_manual && now - s_cam_manual_ms > 120000) { s_cam_manual = false; s_sig_prev = 0; }

  static uint32_t s_spec_start = 0;
  if (hold) {
    s_spec = !s_spec;
    if (s_spec) {
      s_spec_start = now;
      memset((void*)s_wsum, 0, sizeof(s_wsum)); memset((void*)s_wcnt, 0, sizeof(s_wcnt));
      for (int i = 0; i < N_BIN; i++) { s_swp[i] = -127; s_pk[i] = -127; }
      s_sx_ok = sx1262_sweep_begin();
      if (s_sx_ok) sx1262_sweep_set_span(SX_SWEEP_LO_HZ, SX_SWEEP_HI_HZ, N_BIN);
      draw_spectrum();
      refresh(true);
      return;
    } else {
      sx1262_sweep_stop();
      draw_board(true);
      s_sig_prev = signature();
      return;
    }
  }
  if (s_spec) {
    if (tap || tap_x >= 0) { s_spec = false; sx1262_sweep_stop(); draw_board(true); s_sig_prev = signature(); return; }
    if (s_sx_ok) sx1262_sweep_chunk(s_swp, N_BIN, &s_cursor, 32);
    for (int i = 0; i < N_BIN; i++) s_pk[i] = s_swp[i] > s_pk[i] ? s_swp[i] : s_pk[i] - 0.02f;
    static uint32_t last = 0;
    // Refresh budget: 1.5 s for the first 2 minutes, then drop to 5.0 s to protect the panel
    uint32_t spec_interval = (now - s_spec_start < 120000UL) ? 1500 : 5000;
    if (now - last >= spec_interval) { last = now; draw_spectrum(); }
    return;
  }

  // tap: step through the contacts on the table, then over to the map,
  // then back to the table's first row.
  if (tap) {
    if (s_map && s_cam_manual) { s_cam_manual = false; }
    else if (s_map) { s_map = false; s_sel = 0; draw_board(true); return; }
    else if (s_n > 1 && s_sel < s_n - 1) s_sel++;
    else { s_map = true; draw_board(true); return; }
  }
  if (syncing) {
    static uint32_t last_prog = 0;
    if (now - last_prog >= 5000) {          // progress line, sparingly
      last_prog = now;
      rect(0, 496, W, 44, WHITE);
      char b[48]; snprintf(b, sizeof(b), "SYNCING MAP TILES  %d received", sync_files);
      text(&FreeSansBold9pt7b, b, TABLE_X, 524, BLACK);
      EpdRect r = {0, 496, W, 44};
      epd_poweron(); epd_hl_update_area(&s_hl, MODE_GL16, TEMP_C, r); epd_poweroff();
    }
    return;
  }
  static uint32_t last_check = 0;
  if (tap || now - last_check >= 3000) {
    last_check = now;
    build_order();
    uint32_t sig = signature();
    if (sig != s_sig_prev || now - s_last_full > 300000UL) {
      s_sig_prev = sig;
      draw_board(false);
    }
  }
}
