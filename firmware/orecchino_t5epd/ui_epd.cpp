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
#define UI_TARGET_POWER_OFF 0xFF   // s_target_mode: the confirm modal powers off instead of rebooting
static int s_table_page = 0;       // 0 for rows 0..7, 1 for rows 8..15
static bool s_inspector = false;    // Contact detail modal
static bool s_diag = false;         // System diagnostics & hardware calibration screen
static bool s_spec_paused = false;  // Pause spectrum sweep
static int s_spec_cursor_x = -1;   // Touch measurement cursor on spectrum
#define DEFAULT_VCOM 1560
static uint16_t s_vcom = DEFAULT_VCOM;

// 8-pixel aligned bounding boxes for sub-screen updates (eliminates sub-byte boundary artifacts)
static const EpdRect RECT_BODY = { 0, 72, 960, 468 };   // table + plot + footer
static const EpdRect RECT_TABLE  = { 16, 72, 552, 424 };
static const EpdRect RECT_PLOT   = { 568, 72, 392, 424 };
static const EpdRect RECT_MAIN   = { 16, 72, 944, 424 }; // Table + Plot combined
static const EpdRect RECT_MAP    = { 0, 72, 960, 424 };
static const EpdRect RECT_FOOTER = { 0, 496, 960, 44 };

uint8_t ui_get_mode() { return s_mode; }
bool ui_diagnostics_active() { return s_diag; }

static const char* uas_manufacturer(const char* uas) {
  if (!uas || !*uas) return "Unknown";
  if (!strncmp(uas, "1596", 4)) return "DJI Innovations";
  if (!strncmp(uas, "1689", 4)) return "Autel Robotics";
  if (!strncmp(uas, "1585", 4)) return "Parrot";
  if (!strncmp(uas, "1647", 4)) return "Skydio";
  if (!strncmp(uas, "1710", 4)) return "Yuneec";
  if (!strncmp(uas, "1711", 4)) return "Teal Drones";
  if (!strncmp(uas, "1738", 4)) return "Wingtra";
  if (!strncmp(uas, "1198", 4)) return "Freefly Systems";
  return "ASTM Standard RID";
}

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
void ui_feed_wifi(uint8_t chan, int8_t rssi) { if (s_spec && !s_spec_paused && chan >= 1 && chan <= N_CH) { s_wsum[chan] += rssi; s_wcnt[chan]++; } }
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
  if (s_n == 0) s_sel = 0;
  else if (s_sel >= s_n) s_sel = s_n - 1;
  // s_sel == -1 is the "nothing selected" state (map HUD [X]); every
  // s_order[s_sel] read is range-guarded.
  s_table_page = s_sel / ROWS;
}

// Content signature: anything that should move ink. Coarse on the noisy
// fields (RSSI, position) so the panel is not refreshing on every frame.
static uint32_t signature() {
  uint32_t h = 2166136261u;
  auto mix = [&](uint32_t v) { h ^= v; h *= 16777619u; };
  mix(s_mode);
  mix(s_confirm_switch);
  mix(s_inspector);
  mix(s_diag);
  mix(s_spec_paused);
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
  mix(s_n); mix(s_sel); mix(s_table_page); mix(g_seen_count / 100); mix(s_batt / 5); mix(s_ble_ok); mix(g_home_set);
  mix(s_map); mix(s_map_touched); mix((uint32_t)(int32_t)(g_home_lat * 1e3)); mix((uint32_t)(int32_t)(g_home_lon * 1e3));
  mix(periph_gps_detected()); mix(periph_gps_fix()); mix(periph_gps_sats()); mix(s_cam_manual); mix(s_cam_z); mix((uint32_t)s_cam_wx); mix((uint32_t)s_cam_wy);
  return h;
}

static void draw_header(const UiSummary& sm, const char* title) {
  bool loud = sm.alert == UI_EMERGENCY;
  rect(0, 0, W, 70, loud ? BLACK : WHITE);
  if (!loud) rect(0, 68, W, 2, BLACK);
  uint8_t fg = loud ? WHITE : BLACK;
  char b[48];
  if (title) snprintf(b, sizeof(b), "%s", title); else ui_headline(b, sizeof(b), &sm);
  if (!title && sm.tracked == 0) b[0] = 0;  // an empty sky needs no headline

  // The title must stay clear of the view switcher at x=310: step down
  // 18 -> 12 -> 9 pt before trimming, so "EMERGENCY N CONTACTS" stays whole.
  if (b[0]) {
    if (text_w(&FreeSansBold18pt7b, b) <= 280) {
      text(&FreeSansBold18pt7b, b, TABLE_X, 48, fg);
    } else if (text_w(&FreeSansBold12pt7b, b) <= 280) {
      text(&FreeSansBold12pt7b, b, TABLE_X, 44, fg);
    } else {
      if (text_w(&FreeSansBold9pt7b, b) > 280) {
        size_t n = strlen(b);
        while (n > 3 && text_w(&FreeSansBold9pt7b, b) > 265) b[--n] = 0;
        if (n + 2 < sizeof(b)) strcat(b, "..");
      }
      text(&FreeSansBold9pt7b, b, TABLE_X, 42, fg);
    }
  }

  // Persistent Segmented View Switcher: [ TABLE | MAP | SPECTRUM ]
  // (Available whenever in RX mode and not in modal diagnostics)
  if (s_mode != UI_MODE_TX && !s_diag) {
    const int bx = 310, by = 12, bw = 260, bh = 46;
    uint8_t border_col = loud ? WHITE : BLACK;
    box(bx, by, bw, bh, border_col);
    box(bx + 1, by + 1, bw - 2, bh - 2, border_col);
    rect(bx + 76 - 1, by, 2, bh, border_col);
    rect(bx + 148 - 1, by, 2, bh, border_col);

    bool is_table = !s_map && !s_spec;
    bool is_map = s_map && !s_spec;
    bool is_spec = s_spec;

    // Tab 1: TABLE (bx .. bx + 76)
    int tw_table = text_w(&FreeSansBold12pt7b, "TABLE");
    int tx_table = bx + (76 - tw_table) / 2;
    if (is_table) {
      rect(bx + 2, by + 2, 73, bh - 4, loud ? WHITE : BLACK);
      text(&FreeSansBold12pt7b, "TABLE", tx_table, 41, loud ? BLACK : WHITE);
    } else {
      rect(bx + 2, by + 2, 73, bh - 4, loud ? BLACK : WHITE);
      text(&FreeSansBold12pt7b, "TABLE", tx_table, 41, loud ? WHITE : BLACK);
    }

    // Tab 2: MAP (bx + 76 .. bx + 148)
    int tw_map = text_w(&FreeSansBold12pt7b, "MAP");
    int tx_map = bx + 76 + (72 - tw_map) / 2;
    if (is_map) {
      rect(bx + 76 + 1, by + 2, 71, bh - 4, loud ? WHITE : BLACK);
      text(&FreeSansBold12pt7b, "MAP", tx_map, 41, loud ? BLACK : WHITE);
    } else {
      rect(bx + 76 + 1, by + 2, 71, bh - 4, loud ? BLACK : WHITE);
      text(&FreeSansBold12pt7b, "MAP", tx_map, 41, loud ? WHITE : BLACK);
    }

    // Tab 3: SPECTRUM (bx + 148 .. bx + 260)
    int tw_spec = text_w(&FreeSansBold9pt7b, "SPECTRUM");
    int tx_spec = bx + 148 + (112 - tw_spec) / 2;
    if (is_spec) {
      rect(bx + 148 + 1, by + 2, 110, bh - 4, loud ? WHITE : BLACK);
      text(&FreeSansBold9pt7b, "SPECTRUM", tx_spec, 40, loud ? BLACK : WHITE);
    } else {
      rect(bx + 148 + 1, by + 2, 110, bh - 4, loud ? BLACK : WHITE);
      text(&FreeSansBold9pt7b, "SPECTRUM", tx_spec, 40, loud ? WHITE : BLACK);
    }
  }

  // Right-hand status cluster (Right to Left from W - 20)
  int xr = W - 20;
  snprintf(b, sizeof(b), s_ble_ok ? "RX OK" : "RX FAULT");
  text_r(&FreeSansBold12pt7b, b, xr, 44, loud ? WHITE : BLACK);
  xr -= text_w(&FreeSansBold12pt7b, b) + 14;

  if (s_batt >= 0) {
    snprintf(b, sizeof(b), "%d%%", s_batt);
    text_r(&FreeSansBold9pt7b, b, xr, 42, fg);
    xr -= text_w(&FreeSansBold9pt7b, b) + 6;
    // Vector Battery Glyph
    int bw = 26, bh = 14, by = 28;
    int bx = xr - bw - 2;
    box(bx, by, bw, bh, fg);
    rect(bx + bw, by + 4, 3, 6, fg);
    int fill_w = (s_batt * (bw - 4)) / 100;
    if (fill_w > 0) rect(bx + 2, by + 2, fill_w, bh - 4, fg);
    xr = bx - 14;
  }

  // GPS status, then the UTC clock (minutes only: nothing redraws on the
  // second). Each item is drawn only if it fits left of the view switcher
  // (which ends at x=570) instead of printing over the tabs.
  const int cluster_min_x = 584;
  if (periph_gps_fix()) snprintf(b, sizeof(b), "GPS %d", periph_gps_sats());
  else if (periph_gps_detected()) snprintf(b, sizeof(b), "GPS ?");
  else snprintf(b, sizeof(b), g_home_set ? "APP POS" : "NO POS");
  int gw = text_w(&FreeSansBold9pt7b, b);
  if (xr - gw >= cluster_min_x) {
    text_r(&FreeSansBold9pt7b, b, xr, 42, fg);
    xr -= gw + 14;
  }
  if (periph_has_utc_time()) {
    uint16_t cy; uint8_t cm, cd, ch, cmi, cs;
    periph_get_utc_time(&cy, &cm, &cd, &ch, &cmi, &cs);
    snprintf(b, sizeof(b), "%02u:%02uZ", ch, cmi);
    int cw = text_w(&FreeSansBold9pt7b, b);
    if (xr - cw >= cluster_min_x) text_r(&FreeSansBold9pt7b, b, xr, 42, fg);
  }
}

static void draw_footer(const UiSummary& sm, const char* hint) {
  rect(0, 496, W, 44, WHITE);
  rect(0, 496, W, 2, BLACK);
  const GFXfont* f9 = &FreeSansBold9pt7b;
  char b[64];
  if (sm.newest_age_s == UINT32_MAX) snprintf(b, sizeof(b), "SCANNING");
  else if (sm.newest_age_s < 10) snprintf(b, sizeof(b), "ACTIVE RX");
  else if (sm.newest_age_s < 60) snprintf(b, sizeof(b), "RX <1m");
  else snprintf(b, sizeof(b), "RX %lum ago", (unsigned long)(sm.newest_age_s / 60));

  char count_buf[32];
  snprintf(count_buf, sizeof(count_buf), " | %d LIVE", sm.active);
  strncat(b, count_buf, sizeof(b) - strlen(b) - 1);
  if (g_seen_count) {
    snprintf(count_buf, sizeof(count_buf), " | %lu seen", (unsigned long)g_seen_count);
    strncat(b, count_buf, sizeof(b) - strlen(b) - 1);
  }
  text(f9, b, TABLE_X, 524, BLACK);

  // Pagination button on Table
  if (!s_map && s_n > ROWS) {
    int total_pages = (s_n + ROWS - 1) / ROWS;
    char page_str[24];
    snprintf(page_str, sizeof(page_str), "PAGE %d/%d", s_table_page + 1, total_pages);
    int pw = text_w(f9, page_str) + 24;
    int px = 330, py = 502, ph = 32;
    box(px, py, pw, ph, BLACK);
    text(f9, page_str, px + 12, py + 22, BLACK);
  }

  // Right-side footer action buttons
  int btn_y = 502, btn_h = 32;
  // Button: [ SYSTEM ]
  int sys_w = 90, sys_x = W - 20 - sys_w;
  box(sys_x, btn_y, sys_w, btn_h, BLACK);
  text(f9, "SYSTEM", sys_x + (sys_w - text_w(f9, "SYSTEM")) / 2, btn_y + 22, BLACK);

  // Button: [ INSPECT ] (if an aircraft is selected on Table)
  if (!s_map && s_n > 0 && s_sel >= 0 && s_sel < s_n) {
    int ins_w = 100, ins_x = sys_x - 12 - ins_w;
    rect(ins_x, btn_y, ins_w, btn_h, BLACK);
    text(f9, "INSPECT", ins_x + (ins_w - text_w(f9, "INSPECT")) / 2, btn_y + 22, WHITE);
  }
}

static void draw_table() {
  rect(RECT_TABLE.x, RECT_TABLE.y, RECT_TABLE.width, RECT_TABLE.height, WHITE);
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

  int start_k = s_table_page * ROWS;
  for (int i = 0; i < ROWS; i++) {
    int k = start_k + i;
    if (k >= s_n) break;
    const Track* t = &g_tracks[s_order[k]];
    int y = y0 + 24 + i * ROW_H;
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

    // Line 2: Verdict on selected row, or alert/status on unselected
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
      else {
        char sub[48];
        uint32_t age_s = (s_now - t->last_ms) / 1000;
        const char* stat = ui_status_name(t->status);
        if (age_s < 60) snprintf(sub, sizeof(sub), "%s | %s%s%s | %lus", stat, (t->src_mask & 1) ? "W" : "", (t->src_mask & 2) ? "N" : "", (t->src_mask & 4) ? "B" : "", (unsigned long)age_s);
        else snprintf(sub, sizeof(sub), "%s | %s%s%s | %lum", stat, (t->src_mask & 1) ? "W" : "", (t->src_mask & 2) ? "N" : "", (t->src_mask & 4) ? "B" : "", (unsigned long)(age_s / 60));
        text(f9, sub, TABLE_X + 8, y + 36, GREY);
      }
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

static void draw_target_card(const Track* t, int sel_idx, int total_n) {
  const int cx = 574, cy = 76, cw = 378, ch = 416;
  const GFXfont* f12 = &FreeSansBold12pt7b;
  const GFXfont* f9  = &FreeSansBold9pt7b;
  char b[64];

  // Outer border
  box(cx, cy, cw, ch, BLACK);

  // Top header banner
  rect(cx, cy, cw, 32, BLACK);
  snprintf(b, sizeof(b), "CONTACT %d OF %d", sel_idx + 1, total_n);
  text(f9, b, cx + 12, cy + 22, WHITE);

  bool stale = ui_stale(t, s_now);
  bool danger = ui_danger(t, s_now);
  const char* status_badge = danger ? "EMERGENCY" : stale ? "STALE" : "ACTIVE";
  text_r(f9, status_badge, cx + cw - 12, cy + 22, WHITE);

  // UAS ID / Call sign
  int y = cy + 58;
  snprintf(b, sizeof(b), "%.20s", t->uas[0] ? t->uas : "(UNIDENTIFIED UAS)");
  text(f12, b, cx + 12, y, BLACK);

  // Subtitle: Manufacturer & Transport
  y += 24;
  snprintf(b, sizeof(b), "%s | %s%s%s",
           uas_manufacturer(t->uas),
           (t->src_mask & 1) ? "Wi-Fi " : "",
           (t->src_mask & 2) ? "NAN " : "",
           (t->src_mask & 4) ? "BLE" : "");
  text(f9, b, cx + 12, y, GREY);

  // Divider
  y += 10;
  rect(cx + 12, y, cw - 24, 1, GREY);

  // Grid Row 1: Altitude & Speed
  y += 22;
  text(f9, "ALTITUDE (AGL)", cx + 12, y, GREY);
  text(f9, "SPEED", cx + 200, y, GREY);

  y += 20;
  if (!isnan(t->height)) {
    snprintf(b, sizeof(b), "%d m (%d ft)", (int)t->height, (int)(t->height * 3.28084f));
  } else {
    snprintf(b, sizeof(b), "--");
  }
  text(f9, b, cx + 12, y, BLACK);

  if (!isnan(t->speed)) {
    snprintf(b, sizeof(b), "%.1f m/s (%.0f kt)", t->speed, t->speed * 1.94384f);
  } else {
    snprintf(b, sizeof(b), "--");
  }
  text(f9, b, cx + 200, y, BLACK);

  // Grid Row 2: Heading & Packets
  y += 24;
  text(f9, "HEADING", cx + 12, y, GREY);
  text(f9, "PACKETS", cx + 200, y, GREY);

  y += 20;
  if (!isnan(t->heading)) {
    static const char* CARDINALS[] = {"N", "NE", "E", "SE", "S", "SW", "W", "NW", "N"};
    int c_idx = (int)((t->heading + 22.5f) / 45.0f) % 8;
    snprintf(b, sizeof(b), "%03d deg (%s)", (int)t->heading, CARDINALS[c_idx]);
  } else {
    snprintf(b, sizeof(b), "--");
  }
  text(f9, b, cx + 12, y, BLACK);

  snprintf(b, sizeof(b), "%u msgs", t->msgs);
  text(f9, b, cx + 200, y, BLACK);

  // Divider
  y += 10;
  rect(cx + 12, y, cw - 24, 1, LIGHT);

  // Grid Row 3: Position / Coordinates
  y += 22;
  text(f9, "GNSS POSITION", cx + 12, y, GREY);
  y += 20;
  if (t->has_pos) {
    snprintf(b, sizeof(b), "%.6f, %.6f", t->lat, t->lon);
    text(f9, b, cx + 12, y, BLACK);
  } else {
    text(f9, "NO COORDINATES REPORTED", cx + 12, y, GREY);
  }

  // Divider
  y += 10;
  rect(cx + 12, y, cw - 24, 1, LIGHT);

  // Grid Row 4: Signal & Peak RSSI
  y += 22;
  text(f9, "SIGNAL STRENGTH", cx + 12, y, GREY);
  snprintf(b, sizeof(b), "%d dBm (Peak %d)", t->rssi, t->peak_rssi);
  text_r(f9, b, cx + cw - 12, y, BLACK);

  y += 8;
  int bar_w = cw - 24;
  box(cx + 12, y, bar_w, 10, BLACK);
  int fill = (int)(bar_w * ui_rssi01(t->rssi));
  if (fill > 0) rect(cx + 12, y, fill, 10, stale ? GREY : BLACK);

  // Grid Row 5: Authentication & Seen History
  y += 26;
  const char* auth_str = (t->auth_state == 3) ? "VALID (Ed25519)" :
                         (t->auth_state == 4) ? "INVALID SIGNATURE" :
                         (t->auth_state == 2) ? "Untrusted Key" :
                         (t->auth_state == 1) ? "Partial Page" : "None";
  snprintf(b, sizeof(b), "Auth: %s", auth_str);
  text(f9, b, cx + 12, y, t->auth_state == 4 ? BLACK : GREY);

  uint32_t age_s = (s_now - t->last_ms) / 1000;
  snprintf(b, sizeof(b), "Seen: %lus ago", (unsigned long)age_s);
  text_r(f9, b, cx + cw - 12, y, BLACK);

  // Footer tap banner
  rect(cx + 1, cy + ch - 24, cw - 2, 23, LIGHT);
  int tw_tap = text_w(f9, "TAP CARD FOR FULL AUDIT INSPECTOR");
  text(f9, "TAP CARD FOR FULL AUDIT INSPECTOR", cx + (cw - tw_tap) / 2, cy + ch - 8, BLACK);
}

static void draw_plot() {
  rect(RECT_PLOT.x, RECT_PLOT.y, RECT_PLOT.width, RECT_PLOT.height, WHITE);
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
    text(&FreeSansBold9pt7b, "S", PLOT_CX - 5, PLOT_CY + PLOT_R + 16, GREY);
    text(&FreeSansBold9pt7b, "W", PLOT_CX - PLOT_R - 18, PLOT_CY + 4, GREY);
    text(&FreeSansBold9pt7b, "E", PLOT_CX + PLOT_R + 8, PLOT_CY + 4, GREY);
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
      if (!isnan(t->height)) snprintf(b, sizeof(b), "%s %dm", uas_tail(t->uas, 5), (int)t->height);
      else snprintf(b, sizeof(b), "%s", uas_tail(t->uas, 8));
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
    // No operator fix: Display rich Selected Target Detail Card
    if (s_n > 0 && s_sel >= 0 && s_sel < s_n) {
      const Track* t = &g_tracks[s_order[s_sel]];
      draw_target_card(t, s_sel, s_n);
    } else {
      int tw1 = text_w(&FreeSansBold12pt7b, "WAITING FOR TARGETS");
      text(&FreeSansBold12pt7b, "WAITING FOR TARGETS", PLOT_CX - tw1 / 2, 230, BLACK);
      int tw2 = text_w(&FreeSansBold9pt7b, "Listening on BLE4, BLE5, Wi-Fi Beacon & NAN");
      text(&FreeSansBold9pt7b, "Listening on BLE4, BLE5, Wi-Fi Beacon & NAN", PLOT_CX - tw2 / 2, 260, GREY);
      int tw3 = text_w(&FreeSansBold9pt7b, "RF Spectrum: 2.4 GHz & 850-930 MHz");
      text(&FreeSansBold9pt7b, "RF Spectrum: 2.4 GHz & 850-930 MHz", PLOT_CX - tw3 / 2, 286, GREY);
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
  // Partial-refresh paths repaint over the previous frame: clear the map
  // body first (tiles may not cover it, and the HUD must vanish on deselect).
  rect(0, MAP_Y0, W, MAP_H, WHITE);
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
    if (!isnan(t->height)) snprintf(b, sizeof(b), "%s %dm", uas_tail(t->uas, 5), (int)t->height);
    else snprintf(b, sizeof(b), "%s", uas_tail(t->uas, 8));
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

  // Recenter / Follow GPS button
  int rby = MAP_Y0 + 164;
  rect(W - 54, rby, 44, 44, WHITE);
  box(W - 54, rby, 44, 44, BLACK);
  box(W - 53, rby + 1, 42, 42, BLACK);
  epd_draw_circle(W - 32, rby + 22, 10, BLACK, s_fb);
  epd_fill_circle(W - 32, rby + 22, 3, s_cam_manual ? WHITE : BLACK, s_fb);
  epd_draw_line(W - 32, rby + 8, W - 32, rby + 36, BLACK, s_fb);
  epd_draw_line(W - 46, rby + 22, W - 18, rby + 22, BLACK, s_fb);

  if (s_cam_manual) {
    int pw = 140, ph = 26;
    int px = 20, py = MAP_Y0 + 8;
    rect(px, py, pw, ph, WHITE);
    box(px, py, pw, ph, BLACK);
    text(&FreeSansBold9pt7b, "MANUAL PAN", px + 10, py + 18, BLACK);
  }

  // Tactical HUD banner when an aircraft is selected
  if (s_n > 0 && s_sel >= 0 && s_sel < s_n) {
    const Track* sel_t = &g_tracks[s_order[s_sel]];
    const int hud_h = 36;
    const int hud_y = MAP_Y0 + MAP_H - hud_h - 40;
    rect(20, hud_y, W - 40, hud_h, WHITE);
    box(20, hud_y, W - 40, hud_h, BLACK);
    box(21, hud_y + 1, W - 42, hud_h - 2, BLACK);

    char hb[16] = "--", sb[16] = "--", rb[16] = "--";
    if (!isnan(sel_t->height)) snprintf(hb, sizeof(hb), "%dm", (int)sel_t->height);
    if (!isnan(sel_t->speed)) snprintf(sb, sizeof(sb), "%.0fm/s", sel_t->speed);
    if (g_home_set && sel_t->has_pos) {
      ui_fmt_range(rb, sizeof(rb), ui_dist_m(g_home_lat, g_home_lon, sel_t->lat, sel_t->lon));
    }
    char hud_str[128];
    snprintf(hud_str, sizeof(hud_str), "%.16s | %s | Alt %s | Spd %s | Rng %s | %s",
             sel_t->uas[0] ? sel_t->uas : "(no id)",
             ui_status_name(sel_t->status), hb, sb, rb,
             (sel_t->src_mask & 1) ? "W" : (sel_t->src_mask & 2) ? "N" : "B");
    text(&FreeSansBold9pt7b, hud_str, 32, hud_y + 24, BLACK);

    // [ DETAILS ] button
    int d_w = 90, d_h = 26;
    int d_x = W - 140, d_y = hud_y + 5;
    rect(d_x, d_y, d_w, d_h, BLACK);
    text(&FreeSansBold9pt7b, "DETAILS", d_x + (d_w - text_w(&FreeSansBold9pt7b, "DETAILS")) / 2, d_y + 18, WHITE);

    // [ X ] button
    int x_w = 26, x_h = 26;
    int x_x = W - 44, x_y = hud_y + 5;
    box(x_x, x_y, x_w, x_h, BLACK);
    text(&FreeSansBold9pt7b, "X", x_x + 8, x_y + 18, BLACK);
  }

  UiSummary sm; ui_summarize(&sm, s_now);
  draw_header(sm, nullptr);
  draw_footer(sm, !s_map_touched ? "tap marker: select | tap: recentre | drag: pan" : "tap or button: table | hold: spectrum");
}

static void refresh_area(EpdRect area, bool force_full, bool fast_mode = false) {
  // E-Paper Best Practice: Full DC-balanced GC16 refresh on view changes,
  // alert state transitions, or periodically every 10 partial cycles / 3 minutes
  // to eliminate residual charge and ghosting.
  bool full = force_full || (!s_spec && (s_partials >= 10 || (s_now - s_last_full > 180000UL)))
                         || (s_spec && (s_now - s_last_full > 300000UL));
  epd_poweron();
  if (full) {
    epd_hl_update_screen(&s_hl, MODE_GC16, TEMP_C);
    s_partials = 0;
    s_last_full = s_now;
  } else {
    enum EpdDrawMode mode = fast_mode ? MODE_DU : MODE_GL16;
    epd_hl_update_area(&s_hl, mode, TEMP_C, area);
    s_partials++;
  }
  epd_poweroff();
}

static void refresh(bool force_full) {
  refresh_area(epd_full_screen(), force_full, false);
}

static void draw_inspector_modal() {
  if (s_sel < 0 || s_sel >= s_n) return;
  const Track* t = &g_tracks[s_order[s_sel]];
  const GFXfont* f9 = &FreeSansBold9pt7b;
  const GFXfont* f12 = &FreeSansBold12pt7b;

  int mw = 680, mh = 380;
  int mx = (W - mw) / 2, my = (H - mh) / 2;

  // Solid card with crisp double outline
  rect(mx, my, mw, mh, WHITE);
  box(mx, my, mw, mh, BLACK);
  box(mx + 1, my + 1, mw - 2, mh - 2, BLACK);
  box(mx + 2, my + 2, mw - 4, mh - 4, BLACK);

  // Header banner
  rect(mx + 3, my + 3, mw - 6, 42, BLACK);
  char title_buf[64];
  snprintf(title_buf, sizeof(title_buf), "CONTACT INSPECTOR: %.20s", t->uas[0] ? t->uas : "(no id)");
  text(f12, title_buf, mx + 16, my + 28, WHITE);

  // Close [ X ] button in header
  int close_w = 34, close_h = 34;
  int close_x = mx + mw - close_w - 6, close_y = my + 7;
  rect(close_x, close_y, close_w, close_h, WHITE);
  box(close_x, close_y, close_w, close_h, BLACK);
  text(f12, "X", close_x + (close_w - text_w(f12, "X")) / 2, close_y + 24, BLACK);

  int col1 = mx + 24;
  int col2 = mx + 350;
  int y = my + 68;

  // Section 1: IDENTITY & RF (Left column)
  text(f9, "IDENTITY & SIGNALS", col1, y, BLACK);
  rect(col1, y + 4, 300, 1, BLACK);

  char b[64];
  y += 24;
  snprintf(b, sizeof(b), "UAS ID: %s", t->uas[0] ? t->uas : "(not reported)");
  text(f9, b, col1, y, BLACK);

  y += 20;
  snprintf(b, sizeof(b), "MFR: %s", uas_manufacturer(t->uas));
  text(f9, b, col1, y, BLACK);

  y += 20;
  snprintf(b, sizeof(b), "MAC: %02X:%02X:%02X:%02X:%02X:%02X", t->mac[0], t->mac[1], t->mac[2], t->mac[3], t->mac[4], t->mac[5]);
  text(f9, b, col1, y, BLACK);

  y += 20;
  snprintf(b, sizeof(b), "Path: %s%s%s  (%u msgs)",
           (t->src_mask & 1) ? "Wi-Fi Beacon " : "",
           (t->src_mask & 2) ? "NAN " : "",
           (t->src_mask & 4) ? "BLE" : "",
           t->msgs);
  text(f9, b, col1, y, BLACK);

  y += 20;
  snprintf(b, sizeof(b), "RSSI: %d dBm  (Peak: %d dBm)", t->rssi, t->peak_rssi);
  text(f9, b, col1, y, BLACK);

  y += 20;
  uint32_t age_s = (s_now - t->last_ms) / 1000;
  uint32_t dur_s = (s_now - t->first_ms) / 1000;
  snprintf(b, sizeof(b), "Seen: %lus ago  (Track: %lum%lus)", (unsigned long)age_s, (unsigned long)(dur_s / 60), (unsigned long)(dur_s % 60));
  text(f9, b, col1, y, BLACK);

  y += 20;
  const char* auth_str = (t->auth_state == 3) ? "VALID (Ed25519 ASTM)" :
                         (t->auth_state == 4) ? "SIGNATURE INVALID!" :
                         (t->auth_state == 2) ? "Untrusted Key" :
                         (t->auth_state == 1) ? "Partial Page" : "None";
  snprintf(b, sizeof(b), "Auth: %s", auth_str);
  text(f9, b, col1, y, (t->auth_state == 4) ? BLACK : GREY);

  // Section 2: FLIGHT TELEMETRY (Right column)
  int y2 = my + 68;
  text(f9, "FLIGHT TELEMETRY", col2, y2, BLACK);
  rect(col2, y2 + 4, 300, 1, BLACK);

  y2 += 24;
  if (t->has_pos) {
    snprintf(b, sizeof(b), "Pos: %.6f, %.6f", t->lat, t->lon);
  } else {
    snprintf(b, sizeof(b), "Pos: NO POSITION REPORTED");
  }
  text(f9, b, col2, y2, BLACK);

  y2 += 20;
  char hb[16] = "--", mb[16] = "--";
  if (!isnan(t->height)) snprintf(hb, sizeof(hb), "%d m", (int)t->height);
  if (!isnan(t->max_height)) snprintf(mb, sizeof(mb), "%d m", (int)t->max_height);
  snprintf(b, sizeof(b), "Height AGL: %s  (Peak: %s)", hb, mb);
  text(f9, b, col2, y2, BLACK);

  y2 += 20;
  char sb[24] = "--";
  if (!isnan(t->speed)) snprintf(sb, sizeof(sb), "%.1f m/s (%.0f kt)", t->speed, t->speed * 1.94384f);
  snprintf(b, sizeof(b), "Speed: %s", sb);
  text(f9, b, col2, y2, BLACK);

  y2 += 20;
  char cb[16] = "--";
  if (!isnan(t->heading)) snprintf(cb, sizeof(cb), "%03d deg True", (int)t->heading);
  snprintf(b, sizeof(b), "Heading: %s", cb);
  text(f9, b, col2, y2, BLACK);

  y2 += 20;
  if (g_home_set && t->has_pos) {
    char rb[16]; ui_fmt_range(rb, sizeof(rb), ui_dist_m(g_home_lat, g_home_lon, t->lat, t->lon));
    int brg = (int)ui_bearing(g_home_lat, g_home_lon, t->lat, t->lon);
    snprintf(b, sizeof(b), "Range: %s  BRG: %03d deg", rb, brg);
  } else {
    snprintf(b, sizeof(b), "Range: NO OPERATOR FIX");
  }
  text(f9, b, col2, y2, BLACK);

  y2 += 20;
  snprintf(b, sizeof(b), "Status: %s", ui_status_name(t->status));
  text(f9, b, col2, y2, BLACK);

  y2 += 20;
  snprintf(b, sizeof(b), "Airspace: %s", t->in_tfr ? t->tfr_id : "Clear of TFRs");
  text(f9, b, col2, y2, t->in_tfr ? BLACK : GREY);

  // Bottom action buttons
  int btn_w = 200, btn_h = 44;
  int btn_y = my + mh - btn_h - 16;
  int btn1_x = mx + 60;
  int btn2_x = mx + mw - 60 - btn_w;

  // Button 1: [ SHOW ON MAP ]
  rect(btn1_x, btn_y, btn_w, btn_h, BLACK);
  const char* b1_txt = "SHOW ON MAP";
  text(f12, b1_txt, btn1_x + (btn_w - text_w(f12, b1_txt)) / 2, btn_y + 28, WHITE);

  // Button 2: [ CLOSE ]
  box(btn2_x, btn_y, btn_w, btn_h, BLACK);
  box(btn2_x + 1, btn_y + 1, btn_w - 2, btn_h - 2, BLACK);
  const char* b2_txt = "CLOSE";
  text(f12, b2_txt, btn2_x + (btn_w - text_w(f12, b2_txt)) / 2, btn_y + 28, BLACK);
}

static void draw_switch_modal() {
  int mw = 580, mh = 260;
  int mx = (W - mw) / 2, my = (H - mh) / 2;
  // White card with thick multi-stroke border
  rect(mx, my, mw, mh, WHITE);
  box(mx, my, mw, mh, BLACK);
  box(mx + 1, my + 1, mw - 2, mh - 2, BLACK);
  box(mx + 3, my + 3, mw - 6, mh - 6, BLACK);

  bool pwr = s_target_mode == UI_TARGET_POWER_OFF;
  const char* title = pwr ? "POWER OFF DEVICE?" : (s_target_mode == UI_MODE_TX) ? "SWITCH TO TEST BEACON?" : "SWITCH TO RECEIVER?";
  int tw = text_w(&FreeSansBold18pt7b, title);
  text(&FreeSansBold18pt7b, title, mx + (mw - tw) / 2, my + 48, BLACK);

  const char* l1 = pwr ? "The board will power down." :
    (s_target_mode == UI_MODE_TX) ?
    "The board will reboot into Test Beacon mode." :
    "The board will reboot into Remote ID Receiver mode.";
  const char* l2 = pwr ? "Use the power button to start it again." :
    (s_target_mode == UI_MODE_TX) ?
    "Radios will reinitialize to transmit test signals on 2.4 GHz." :
    "Radios will listen for Remote ID broadcasts on BLE and Wi-Fi.";

  text(&FreeSansBold9pt7b, l1, mx + (mw - text_w(&FreeSansBold9pt7b, l1)) / 2, my + 92, BLACK);
  text(&FreeSansBold9pt7b, l2, mx + (mw - text_w(&FreeSansBold9pt7b, l2)) / 2, my + 118, GREY);

  int bw = 220, bh = 54, by = my + 164;
  int bx_ok = mx + 45;
  int bx_can = mx + mw - 45 - bw;

  // OK button (solid black)
  rect(bx_ok, by, bw, bh, BLACK);
  const char* ok_txt = pwr ? "POWER OFF" : (s_target_mode == UI_MODE_TX) ? "REBOOT TO TX" : "REBOOT TO RX";
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
  snprintf(st_b, sizeof(st_b), "%d/%d ACTIVE | %lu PKTS", on, n, (unsigned long)total_sent);
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
  text(&FreeSansBold9pt7b, "CH 6 | 2.4 GHz", 765, 102, BLACK);
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
  text(f9, running ? "TRANSMITTING TEST BURSTS | DO NOT RADIATE NEAR LIVE AIRSPACE" :
                     "TRANSMIT PAUSED | CONFIGURE PATHS AND TAP [TRANSMIT] TO RADIATE",
       TABLE_X, 524, BLACK);
  text_r(f9, "tap card to toggle | hold BOOT: rx mode", W - 20, 524, BLACK);
}

static void draw_diagnostics() {
  epd_hl_set_all_white(&s_hl);
  const GFXfont* f9 = &FreeSansBold9pt7b;
  const GFXfont* f12 = &FreeSansBold12pt7b;
  const GFXfont* f18 = &FreeSansBold18pt7b;

  // Header banner
  rect(0, 0, W, 68, BLACK);
  text(f18, "SYSTEM DIAGNOSTICS & CALIBRATION", 24, 46, WHITE);

  // [ CLOSE ] button in header
  int cl_w = 100, cl_h = 42, cl_x = W - 120, cl_y = 13;
  rect(cl_x, cl_y, cl_w, cl_h, WHITE);
  box(cl_x, cl_y, cl_w, cl_h, BLACK);
  text(f12, "CLOSE", cl_x + (cl_w - text_w(f12, "CLOSE")) / 2, cl_y + 28, BLACK);

  // Section 1: PANEL VCOM VOLTAGE TUNING
  text(f12, "1. PANEL VCOM VOLTAGE TUNING", 24, 98, BLACK);
  char v_str[64];
  snprintf(v_str, sizeof(v_str), "Current: -%.2f V (%u mV)", (float)s_vcom / 1000.0f, s_vcom);
  text(f9, v_str, 460, 98, GREY);

  int b_y = 112, b_h = 36;
  struct Vbtn { const char* lbl; int x; int w; } vbtns[] = {
    { "-50 mV", 24, 90 }, { "-10 mV", 124, 90 },
    { "+10 mV", 364, 90 }, { "+50 mV", 464, 90 }
  };
  for (const auto& vb : vbtns) {
    box(vb.x, b_y, vb.w, b_h, BLACK);
    text(f9, vb.lbl, vb.x + (vb.w - text_w(f9, vb.lbl)) / 2, b_y + 24, BLACK);
  }
  // Value center badge
  rect(224, b_y, 130, b_h, BLACK);
  char cur_v[32]; snprintf(cur_v, sizeof(cur_v), "%u mV", s_vcom);
  text(f12, cur_v, 224 + (130 - text_w(f12, cur_v)) / 2, b_y + 25, WHITE);


  rect(24, 158, W - 48, 1, LIGHT);

  // Section 2: 16-LEVEL GREYSCALE CALIBRATION TEST STRIP
  text(f12, "2. 16-LEVEL GREYSCALE TEST STRIP (4-BIT DAC)", 24, 180, BLACK);
  int strip_x = 24, strip_y = 192, swatch_w = 56, swatch_h = 34;
  for (int i = 0; i < 16; i++) {
    int sx = strip_x + i * swatch_w;
    uint8_t shade = i * 17; // 0 to 255
    rect(sx, strip_y, swatch_w, swatch_h, shade);
    box(sx, strip_y, swatch_w, swatch_h, BLACK);
    char num_buf[4]; snprintf(num_buf, sizeof(num_buf), "%d", i);
    uint8_t text_col = (i < 8) ? WHITE : BLACK;
    text(f9, num_buf, sx + (swatch_w - text_w(f9, num_buf)) / 2, strip_y + 23, text_col);
  }
  text(f9, "Verify uniform monotonic gradation across all 16 levels without clipping or banding.", 24, strip_y + swatch_h + 18, GREY);

  rect(24, 256, W - 48, 1, LIGHT);

  // Section 3: DISPLAY BACKLIGHT & AMBIENT SENSING
  text(f12, "3. DISPLAY BACKLIGHT (PT4103 & SOLAR TIME)", 24, 278, BLACK);
  BlMode bm = periph_bl_get_mode();
  struct BlBtn { const char* lbl; BlMode m; int x; int w; } bl_btns[] = {
    { "AUTO (Sunset)", BL_AUTO, 24, 150 },
    { "MANUAL ON", BL_ON, 184, 130 },
    { "OFF", BL_OFF, 324, 90 }
  };
  int bl_btn_y = 290, bl_btn_h = 34;
  for (const auto& bb : bl_btns) {
    bool active = (bm == bb.m);
    if (active) {
      rect(bb.x, bl_btn_y, bb.w, bl_btn_h, BLACK);
      text(f9, bb.lbl, bb.x + (bb.w - text_w(f9, bb.lbl)) / 2, bl_btn_y + 23, WHITE);
    } else {
      box(bb.x, bl_btn_y, bb.w, bl_btn_h, BLACK);
      text(f9, bb.lbl, bb.x + (bb.w - text_w(f9, bb.lbl)) / 2, bl_btn_y + 23, BLACK);
    }
  }
  // Duty cycle stepper
  box(430, bl_btn_y, 40, bl_btn_h, BLACK);
  text(f12, "-", 430 + (40 - text_w(f12, "-")) / 2, bl_btn_y + 24, BLACK);
  uint8_t duty = periph_bl_get_duty();
  char duty_str[32]; snprintf(duty_str, sizeof(duty_str), "Duty: %u%% (%u)", (duty * 100) / 255, duty);
  box(478, bl_btn_y, 140, bl_btn_h, BLACK);
  text(f9, duty_str, 478 + (140 - text_w(f9, duty_str)) / 2, bl_btn_y + 23, BLACK);
  box(626, bl_btn_y, 40, bl_btn_h, BLACK);
  text(f12, "+", 626 + (40 - text_w(f12, "+")) / 2, bl_btn_y + 24, BLACK);

  char sun_buf[64];
  double sun_el = periph_sun_elevation();
  snprintf(sun_buf, sizeof(sun_buf), "Sun %+.0f deg | %s | BL %s",
           sun_el, periph_is_after_sundown() ? "Night" : "Day",
           periph_bl_is_active() ? "ON" : "OFF");
  text(f9, sun_buf, 680, bl_btn_y + 23, GREY);

  rect(24, 336, W - 48, 1, LIGHT);

  // Section 4: HARDWARE RESOURCE TELEMETRY
  text(f12, "4. HARDWARE TELEMETRY & RESOURCES", 24, 358, BLACK);
  int t_y = 382;
  // Col 1: ESP32 Memory
  char m1[48], m2[48];
  snprintf(m1, sizeof(m1), "PSRAM: %lu KB free / %lu KB", (unsigned long)(ESP.getFreePsram() / 1024), (unsigned long)(ESP.getPsramSize() / 1024));
  snprintf(m2, sizeof(m2), "Heap:   %lu KB free (internal)", (unsigned long)(ESP.getFreeHeap() / 1024));
  text(f9, m1, 24, t_y, BLACK);
  text(f9, m2, 24, t_y + 22, BLACK);

  // Col 2: Power & RTC
  char p1[48], p2[48];
  int mv = periph_batt_mv();
  if (mv > 0) snprintf(p1, sizeof(p1), "Cell:   %d mV (%d%%) | BQ27220 OK", mv, s_batt);
  else snprintf(p1, sizeof(p1), "Cell:   No Gauge Detected");
  if (periph_has_utc_time()) {
    uint16_t cy; uint8_t cm, cd, ch, cmi, cs;
    periph_get_utc_time(&cy, &cm, &cd, &ch, &cmi, &cs);
    snprintf(p2, sizeof(p2), "RTC:    %04u-%02u-%02u %02u:%02u:%02uZ", cy, cm, cd, ch, cmi, cs);
  } else {
    snprintf(p2, sizeof(p2), "RTC:    No Time Sync");
  }
  text(f9, p1, 340, t_y, BLACK);
  text(f9, p2, 340, t_y + 22, BLACK);

  // Col 3: GPS & LittleFS Map Cache
  char g1[48], g2[48];
  if (periph_gps_fix()) snprintf(g1, sizeof(g1), "GPS:    3D Fix (%d satellites)", periph_gps_sats());
  else if (periph_gps_detected()) snprintf(g1, sizeof(g1), "GPS:    Searching (UART1)");
  else snprintf(g1, sizeof(g1), "GPS:    Not Detected");
  size_t fs_used = LittleFS.usedBytes() / 1024;
  size_t fs_tot  = LittleFS.totalBytes() / 1024;
  snprintf(g2, sizeof(g2), "Tiles:  %lu KB / %lu KB (%d%%)", (unsigned long)fs_used, (unsigned long)fs_tot, fs_tot ? (int)((fs_used * 100) / fs_tot) : 0);
  text(f9, g1, 660, t_y, BLACK);
  text(f9, g2, 660, t_y + 22, BLACK);

  rect(24, 420, W - 48, 1, LIGHT);

  // Section 5: TRANSMITTER BEACON MODE SWITCH & POWER CONTROL
  text(f12, "5. OPERATING MODE SWITCH & POWER CONTROL", 24, 442, BLACK);
  int tx_btn_w = 380, tx_btn_h = 38, tx_btn_x = 24, tx_btn_y = 454;
  box(tx_btn_x, tx_btn_y, tx_btn_w, tx_btn_h, BLACK);
  box(tx_btn_x + 1, tx_btn_y + 1, tx_btn_w - 2, tx_btn_h - 2, BLACK);
  text(f9, "SWITCH TO TX BEACON MODE", tx_btn_x + (tx_btn_w - text_w(f9, "SWITCH TO TX BEACON MODE")) / 2, tx_btn_y + 25, BLACK);

  // Power Off button
  int pwr_btn_x = 420, pwr_btn_y = 454, pwr_btn_w = 210, pwr_btn_h = 38;
  rect(pwr_btn_x, pwr_btn_y, pwr_btn_w, pwr_btn_h, BLACK);
  text(f9, "POWER OFF DEVICE", pwr_btn_x + (pwr_btn_w - text_w(f9, "POWER OFF DEVICE")) / 2, pwr_btn_y + 25, WHITE);

  text(f9, "Cuts power or enters deep sleep.", pwr_btn_x + pwr_btn_w + 14, pwr_btn_y + 25, GREY);

  // Footer note
  rect(0, 506, W, 34, WHITE);
  rect(0, 506, W, 1, BLACK);
  text(f9, "T5 E-PAPER S3 PRO | ORECCHINO TACTICAL CONSOLE", 24, 528, BLACK);
}

static void draw_board(bool force_full) {
  if (s_diag) {
    draw_diagnostics();
    if (s_confirm_switch) draw_switch_modal();
    refresh(force_full);
    return;
  }
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
    if (s_inspector) draw_inspector_modal();
    if (s_confirm_switch) draw_switch_modal();
    refresh(force_full);
    s_alert_prev = sm.alert;
    return;
  }
  draw_header(sm, nullptr);
  draw_table();
  draw_plot();
  draw_footer(sm, nullptr);
  if (s_inspector) draw_inspector_modal();
  if (s_confirm_switch) draw_switch_modal();
  refresh(force_full || sm.alert != s_alert_prev);
  s_alert_prev = sm.alert;
}

static void draw_spectrum(bool full = false) {
  epd_hl_set_all_white(&s_hl);
  UiSummary sm = {}; sm.alert = UI_QUIET; sm.newest_age_s = UINT32_MAX;
  draw_header(sm, s_sx_ok ? "SPECTRUM" : "SPECTRUM 2.4G");
  // 2.4 GHz bars
  if (!s_spec_paused) {
    for (int c = 1; c <= 13; c++) {
      uint16_t cnt = s_wcnt[c];
      int32_t sum = s_wsum[c];
      s_wcnt[c] = 0;
      s_wsum[c] = 0;
      if (cnt) s_a24[c - 1] = s_a24[c - 1] * 0.5f + ((float)sum / cnt) * 0.5f;
      else s_a24[c - 1] -= 1.0f;
      if (s_a24[c - 1] < -115) s_a24[c - 1] = -115;
    }
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

  // Touch frequency measurement cursor:
  if (s_spec_cursor_x >= X0 && s_spec_cursor_x <= X0 + PW) {
    for (int cy = Y0 + 2; cy < Y0 + PH - 2; cy += 4) {
      epd_draw_pixel(s_spec_cursor_x, cy, BLACK, s_fb);
    }
    int bin = (s_spec_cursor_x - X0) * N_BIN / PW;
    if (bin < 0) bin = 0; if (bin >= N_BIN) bin = N_BIN - 1;
    float cur_freq = 850.0f + ((float)(s_spec_cursor_x - X0) / PW) * 80.0f;
    char cur_b[48];
    snprintf(cur_b, sizeof(cur_b), "%.2f MHz: %d dBm (Pk %d)", cur_freq, s_swp[bin], (int)s_pk[bin]);
    int cw = text_w(&FreeSansBold9pt7b, cur_b);
    rect(X0 + PW - cw - 18, Y0 + 6, cw + 14, 22, WHITE);
    box(X0 + PW - cw - 18, Y0 + 6, cw + 14, 22, BLACK);
    text(&FreeSansBold9pt7b, cur_b, X0 + PW - cw - 11, Y0 + 22, BLACK);
  }

  // Spectrum Footer & Action Buttons
  rect(0, 496, W, 44, WHITE);
  rect(0, 496, W, 2, BLACK);
  const GFXfont* f9 = &FreeSansBold9pt7b;
  text(f9, s_spec_paused ? "SPECTRUM PAUSED | TAP TRACE FOR CURSOR" : "SX1262 SWEEP ACTIVE | TAP TRACE FOR CURSOR", TABLE_X, 524, BLACK);

  int btn_y = 502, btn_h = 32;
  // Button: [ PAUSE / RESUME ]
  int p_w = 110, p_x = W - 20 - 90 - 12 - 120 - 12 - p_w;
  if (s_spec_paused) {
    rect(p_x, btn_y, p_w, btn_h, BLACK);
    text(f9, "RESUME", p_x + (p_w - text_w(f9, "RESUME")) / 2, btn_y + 22, WHITE);
  } else {
    box(p_x, btn_y, p_w, btn_h, BLACK);
    text(f9, "PAUSE", p_x + (p_w - text_w(f9, "PAUSE")) / 2, btn_y + 22, BLACK);
  }

  // Button: [ PEAK CLR ]
  int pk_w = 120, pk_x = W - 20 - 90 - 12 - pk_w;
  box(pk_x, btn_y, pk_w, btn_h, BLACK);
  text(f9, "PEAK CLR", pk_x + (pk_w - text_w(f9, "PEAK CLR")) / 2, btn_y + 22, BLACK);

  // Button: [ EXIT ]
  int ex_w = 90, ex_x = W - 20 - ex_w;
  box(ex_x, btn_y, ex_w, btn_h, BLACK);
  text(f9, "EXIT", ex_x + (ex_w - text_w(f9, "EXIT")) / 2, btn_y + 22, BLACK);

  refresh(full);
}

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
      draw_spectrum(true);
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

// One entry / exit path for the spectrum view, so every way in or out
// resets the same state (pause, cursor, accumulators) and refreshes once.
static void spectrum_enter() {
  s_spec = true;
  s_spec_cursor_x = -1;
  s_spec_paused = false;
  memset((void*)s_wsum, 0, sizeof(s_wsum)); memset((void*)s_wcnt, 0, sizeof(s_wcnt));
  for (int i = 0; i < N_BIN; i++) { s_swp[i] = -127; s_pk[i] = -127; }
  s_sx_ok = sx1262_sweep_begin();
  if (s_sx_ok) sx1262_sweep_set_span(SX_SWEEP_LO_HZ, SX_SWEEP_HI_HZ, N_BIN);
  draw_spectrum(true);
}

static void spectrum_exit(bool to_map) {
  s_spec = false;
  s_map = to_map;
  s_spec_cursor_x = -1;
  s_spec_paused = false;
  sx1262_sweep_stop();
  draw_board(true);
  s_sig_prev = signature();
}

void ui_tick(uint32_t now, bool ble_ok, int batt_pct, int sync_files) {
  if (!s_ok) return;
  s_now = now; s_ble_ok = ble_ok; s_batt = batt_pct;
  bool syncing = sync_files >= 0;
  static bool was_syncing = false;
  if (syncing != was_syncing) { was_syncing = syncing; if (!syncing) { s_sig_prev = 0; } }

  // Hardware Power/Function button (PCA9535 S3 button IO1_2):
  static bool pwr_was = false; static uint32_t pwr_down = 0;
  bool pwr_k = periph_pwr_btn_down();
  if (pwr_k && !pwr_was) { pwr_down = now; }
  if (pwr_k && (now - pwr_down >= 800)) {
    periph_power_off();
    return;
  }
  pwr_was = pwr_k;

  // BOOT button: tap = next contact, hold 1.5 s = spectrum in/out, hold 3.0 s = power off
  static bool was = false; static uint32_t down = 0; static uint8_t hold_level = 0;
  bool k = digitalRead(PIN_BOOT_BTN) == LOW;
  bool tap = false, hold = false;
  if (k && !was) { down = now; hold_level = 0; }
  if (k && hold_level == 0 && (now - down > 1500)) { hold_level = 1; hold = true; }
  if (k && hold_level == 1 && (now - down > 3000)) {
    hold_level = 2;
    periph_power_off();
    return;
  }
  if (!k && was && hold_level == 0 && (now - down > 30)) tap = true;
  was = k;

  // Capacitive round home button below display
  if (periph_home_key() && !s_spec && !s_diag && !s_inspector && !s_confirm_switch) {
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

  // touch: tap or drag-release (fast 15ms sampling)
  static bool t_was = false; static int tx0 = 0, ty0 = 0, txl = 0, tyl = 0;
  static uint32_t t_poll = 0;
  int tap_x = -1, tap_y = -1, drag_dx = 0, drag_dy = 0;
  if (now - t_poll >= 15) {
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
          if (s_target_mode == UI_TARGET_POWER_OFF) periph_power_off();
          else board_switch_mode(s_target_mode);
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

  // Inspector Modal Touch Routing
  if (s_inspector) {
    if (tap_x >= 0) {
      int mw = 680, mh = 380;
      int mx = (W - mw) / 2, my = (H - mh) / 2;
      int close_w = 34, close_h = 34;
      int close_x = mx + mw - close_w - 6, close_y = my + 7;
      int btn_w = 200, btn_h = 44;
      int btn_y = my + mh - btn_h - 16;
      int btn1_x = mx + 60;
      int btn2_x = mx + mw - 60 - btn_w;

      if (tap_x >= close_x && tap_x <= close_x + close_w && tap_y >= close_y && tap_y <= close_y + close_h) {
        s_inspector = false;
        s_sig_prev = 0;
        draw_board(false);
        return;
      } else if (tap_y >= btn_y && tap_y <= btn_y + btn_h) {
        if (tap_x >= btn1_x && tap_x <= btn1_x + btn_w) {
          s_inspector = false;
          s_map = true;
          if (s_sel >= 0 && s_sel < s_n) {
            const Track* t = &g_tracks[s_order[s_sel]];
            if (t->has_pos) {
              world_px(t->lat, t->lon, s_cam_z, &s_cam_wx, &s_cam_wy);
              s_cam_manual = true;
              s_cam_manual_ms = now;
            }
          }
          s_sig_prev = 0;
          draw_board(true);
          return;
        } else if (tap_x >= btn2_x && tap_x <= btn2_x + btn_w) {
          s_inspector = false;
          s_sig_prev = 0;
          draw_board(false);
          return;
        }
      } else if (tap_x < mx || tap_x > mx + mw || tap_y < my || tap_y > my + mh) {
        s_inspector = false;
        s_sig_prev = 0;
        draw_board(false);
        return;
      }
    }
    return;
  }

  // Diagnostics Screen Touch Routing
  if (s_diag) {
    if (tap || (tap_x >= W - 120 && tap_x <= W - 20 && tap_y >= 13 && tap_y <= 55)) {
      // [ CLOSE ] button or BOOT tap
      s_diag = false;
      s_sig_prev = 0;
      draw_board(true);
      return;
    }
    if (tap_x >= 0) {
      // VCOM buttons (y: 112..148)
      if (tap_y >= 112 && tap_y <= 148) {
        if (tap_x >= 24 && tap_x <= 114) {
          uint16_t nv = s_vcom > 550 ? s_vcom - 50 : 500;
          ui_set_vcom(nv);  // persists, redraws and refreshes itself
          return;
        } else if (tap_x >= 124 && tap_x <= 214) {
          uint16_t nv = s_vcom > 510 ? s_vcom - 10 : 500;
          ui_set_vcom(nv);  // persists, redraws and refreshes itself
          return;
        } else if (tap_x >= 364 && tap_x <= 454) {
          uint16_t nv = s_vcom < 2990 ? s_vcom + 10 : 3000;
          ui_set_vcom(nv);  // persists, redraws and refreshes itself
          return;
        } else if (tap_x >= 464 && tap_x <= 554) {
          uint16_t nv = s_vcom < 2950 ? s_vcom + 50 : 3000;
          ui_set_vcom(nv);  // persists, redraws and refreshes itself
          return;
        }
      }
      // Backlight mode buttons (y: 290..324)
      if (tap_y >= 290 && tap_y <= 324) {
        if (tap_x >= 24 && tap_x <= 174) {
          periph_bl_set_mode(BL_AUTO);
          draw_board(false);
          return;
        } else if (tap_x >= 184 && tap_x <= 314) {
          periph_bl_set_mode(BL_ON);
          draw_board(false);
          return;
        } else if (tap_x >= 324 && tap_x <= 414) {
          periph_bl_set_mode(BL_OFF);
          draw_board(false);
          return;
        } else if (tap_x >= 430 && tap_x <= 470) {
          uint8_t d = periph_bl_get_duty();
          periph_bl_set_duty(d > 35 ? d - 25 : 10);  // floor at 10, never step up
          draw_board(false);
          return;
        } else if (tap_x >= 626 && tap_x <= 666) {
          uint8_t d = periph_bl_get_duty();
          periph_bl_set_duty(d < 230 ? d + 25 : 255);
          draw_board(false);
          return;
        }
      }
      // Mode Switch: TX Beacon button (y: 454..492, x: 24..404)
      if (tap_y >= 454 && tap_y <= 492 && tap_x >= 24 && tap_x <= 404) {
        s_confirm_switch = true;
        s_target_mode = UI_MODE_TX;
        s_sig_prev = 0;
        draw_board(false);
        return;
      }
      // Power Off button (y: 454..492, x: 420..630): confirm first, like the mode switch
      if (tap_y >= 454 && tap_y <= 492 && tap_x >= 420 && tap_x <= 630) {
        s_confirm_switch = true;
        s_target_mode = UI_TARGET_POWER_OFF;
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
      board_switch_mode(UI_MODE_RX);
      return;
    }
    if (tap) {
      txui_set_running(!txui_running());
      s_sig_prev = 0;
      draw_board(false);
      return;
    }
    if (tap_x >= 0) {
      if (tap_y <= 70 && tap_x >= W - 160) {
        s_confirm_switch = true;
        s_target_mode = UI_MODE_RX;
        s_sig_prev = 0;
        draw_board(false);
        return;
      }
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
      if (tap_x >= 310 && tap_x < 386) {
        if (s_map) { s_map = false; s_sig_prev = 0; draw_board(true); return; }
      } else if (tap_x >= 386 && tap_x < 458) {
        if (!s_map) { s_map = true; s_sig_prev = 0; draw_board(true); return; }
      } else if (tap_x >= 458 && tap_x <= 570) {
        spectrum_enter();
        return;
      }
    }
    if (!s_map) {
      if (tap_y >= 104 && tap_y < 104 + ROWS * ROW_H && tap_x < TABLE_X + TABLE_W) {          // a table row
        int row_idx = (tap_y - 104) / ROW_H;
        int k = s_table_page * ROWS + row_idx;
        if (k < s_n) {
          if (s_sel == k) {
            // Tapped already selected row -> Open Inspector!
            s_inspector = true;
            s_sig_prev = 0;
            draw_board(false);
            return;
          }
          s_sel = k;
          s_table_page = s_sel / ROWS;
          draw_table();
          draw_plot();
          { UiSummary fsm; ui_summarize(&fsm, s_now); draw_footer(fsm, nullptr); }
          refresh_area(RECT_BODY, false);
          s_sig_prev = signature();
          return;
        }
      } else if (tap_x > 560 && tap_y > 70 && tap_y < 496) {        // plot area
        // Hit test aircraft on the plot!
        int hit = -1;
        if (g_home_set) {
          double far = 0;
          for (int k = 0; k < s_n; k++) {
            const Track* t = &g_tracks[s_order[k]];
            if (t->has_pos) { double d = ui_dist_m(g_home_lat, g_home_lon, t->lat, t->lon); if (d > far) far = d; }
          }
          double scale = nice_scale(far > 0 ? far * 1.1 : 500);
          for (int k = 0; k < s_n; k++) {
            const Track* t = &g_tracks[s_order[k]];
            if (!t->has_pos) continue;
            double d = ui_dist_m(g_home_lat, g_home_lon, t->lat, t->lon);
            double br = ui_bearing(g_home_lat, g_home_lon, t->lat, t->lon) * M_PI / 180;
            int px = PLOT_CX + (int)(sin(br) * d / scale * PLOT_R);
            int py = PLOT_CY - (int)(cos(br) * d / scale * PLOT_R);
            if (abs(px - tap_x) < 24 && abs(py - tap_y) < 24) { hit = k; break; }
          }
        } else {
          // In Target Card mode: tapping the card opens the full inspector modal
          if (s_n > 0 && s_sel >= 0 && s_sel < s_n) {
            s_inspector = true;
            s_sig_prev = 0;
            draw_board(false);
            return;
          }
        }
        if (hit >= 0) {
          s_sel = hit;
          s_table_page = s_sel / ROWS;
          draw_table();
          draw_plot();
          { UiSummary fsm; ui_summarize(&fsm, s_now); draw_footer(fsm, nullptr); }
          refresh_area(RECT_BODY, false);
          s_sig_prev = signature();
          return;
        }
        // If tapped outside any aircraft on radar, switch to map
        s_map = true;
        s_sig_prev = 0;
        draw_board(true);
        return;
      } else if (tap_y >= 496) {
        if (tap_x >= 320 && tap_x <= 480 && s_n > ROWS) {
          int max_pages = (s_n + ROWS - 1) / ROWS;
          s_table_page = (s_table_page + 1) % max_pages;
          s_sel = s_table_page * ROWS;
          draw_table();
          draw_plot();
          UiSummary sm; ui_summarize(&sm, s_now);
          draw_footer(sm, nullptr);
          refresh_area(RECT_BODY, false);
          s_sig_prev = signature();
          return;
        } else if (tap_x >= W - 220 && tap_x <= W - 120 && s_n > 0 && s_sel >= 0 && s_sel < s_n) {
          s_inspector = true;
          s_sig_prev = 0;
          draw_board(false);
          return;
        } else if (tap_x >= W - 110 && tap_x <= W - 20) {
          s_diag = true;
          s_sig_prev = 0;
          draw_board(true);
          return;
        }
      }
    } else {
      s_map_touched = true;
      // Tactical HUD button hit-test
      if (s_n > 0 && s_sel >= 0 && s_sel < s_n) {
        const int hud_h = 36;
        const int hud_y = MAP_Y0 + MAP_H - hud_h - 40;
        if (tap_y >= hud_y && tap_y <= hud_y + hud_h) {
          if (tap_x >= W - 140 && tap_x <= W - 50) {
            // [ DETAILS ] button
            s_inspector = true;
            s_sig_prev = 0;
            draw_board(false);
            return;
          } else if (tap_x >= W - 46 && tap_x <= W - 10) {
            // [ X ] button -> deselect
            s_sel = -1;
            draw_map();
            refresh_area(RECT_MAP, false);
            s_sig_prev = signature();
            return;
          }
        }
      }
      if (tap_x >= W - 56 && tap_y >= MAP_Y0 + 56 && tap_y < MAP_Y0 + 164) {   // zoom boxes
        int dz = tap_y < MAP_Y0 + 110 ? 1 : -1;
        int nz = s_cam_z + dz;
        if (nz >= TILE_ZMIN && nz <= TILE_ZMAX) {
          double f = dz > 0 ? 2.0 : 0.5;
          s_cam_wx *= f; s_cam_wy *= f; s_cam_z = nz; s_cam_manual = true; s_cam_manual_ms = now;
          draw_map();
          refresh_area(RECT_MAP, false);
          s_sig_prev = signature();
          return;
        }
      } else if (tap_x >= W - 56 && tap_y >= MAP_Y0 + 164 && tap_y < MAP_Y0 + 210) { // Recenter reticle
        s_cam_manual = false;
        map_camera();
        draw_map();
        refresh_area(RECT_MAP, false);
        s_sig_prev = signature();
        return;
      } else if (s_cam_manual && tap_x >= 20 && tap_x <= 310 && tap_y >= MAP_Y0 + 8 && tap_y <= MAP_Y0 + 36) {
        s_cam_manual = false;
        map_camera();
        draw_map();
        refresh_area(RECT_MAP, false);
        s_sig_prev = signature();
        return;
      } else if (tap_y >= 496 && tap_x >= W - 110 && tap_x <= W - 20) {
        s_diag = true;
        s_sig_prev = 0;
        draw_board(true);
        return;
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
        draw_map();
        refresh_area(RECT_MAP, false);
        s_sig_prev = signature();
        return;
      }
    }
  }
  if ((drag_dx || drag_dy) && s_map && !s_spec) {
    s_map_touched = true;
    s_cam_wx -= drag_dx; s_cam_wy -= drag_dy; s_cam_manual = true; s_cam_manual_ms = now;
    draw_map();
    refresh_area(RECT_MAP, false);
    s_sig_prev = signature();
    return;
  }
  if (s_cam_manual && now - s_cam_manual_ms > 120000) { s_cam_manual = false; s_sig_prev = 0; }

  if (hold) {
    if (s_spec) spectrum_exit(s_map); else spectrum_enter();
    return;
  }
  if (s_spec) {
    const int X0 = 20, PW = 920, Y0 = 250, PH = 220;
    // Header navigation tabs in Spectrum:
    if (tap_y <= 72) {
      if (tap_x >= 310 && tap_x < 386) {
        spectrum_exit(false); return;
      } else if (tap_x >= 386 && tap_x < 458) {
        spectrum_exit(true); return;
      }
    }
    // Touch on trace moves measurement cursor:
    if (tap_x >= X0 && tap_x <= X0 + PW && tap_y >= Y0 && tap_y <= Y0 + PH) {
      s_spec_cursor_x = tap_x;
      draw_spectrum();
      return;
    }
    // Footer action buttons:
    if (tap_y >= 496) {
      if (tap_x >= W - 20 - 90 - 12 - 120 - 12 - 110 && tap_x <= W - 20 - 90 - 12 - 120 - 12) {
        s_spec_paused = !s_spec_paused;
        if (!s_spec_paused) { memset((void*)s_wsum, 0, sizeof(s_wsum)); memset((void*)s_wcnt, 0, sizeof(s_wcnt)); }
        draw_spectrum();
        return;
      } else if (tap_x >= W - 20 - 90 - 12 - 120 && tap_x <= W - 20 - 90 - 12) {
        for (int i = 0; i < N_BIN; i++) s_pk[i] = -127;
        draw_spectrum();
        return;
      } else if (tap_x >= W - 20 - 90 && tap_x <= W - 20) {
        spectrum_exit(s_map); return;
      }
    }
    if (tap) { spectrum_exit(s_map); return; }
    if (s_sx_ok && !s_spec_paused) sx1262_sweep_chunk(s_swp, N_BIN, &s_cursor, 32);
    for (int i = 0; i < N_BIN; i++) s_pk[i] = s_swp[i] > s_pk[i] ? s_swp[i] : s_pk[i] - 0.02f;
    static uint32_t last = 0;
    // Throttled refresh budget to eliminate ghosting and screen flashing
    uint32_t spec_interval = 4000;
    if (now - last >= spec_interval) { last = now; draw_spectrum(); }
    return;
  }

  // tap: step through the contacts on the table, then over to the map,
  // then back to the table's first row.
  if (tap) {
    if (s_map && s_cam_manual) { s_cam_manual = false; map_camera(); draw_map(); refresh_area(RECT_MAP, false); s_sig_prev = signature(); return; }
    else if (s_map) { s_map = false; s_sel = 0; s_table_page = 0; draw_board(true); s_sig_prev = signature(); return; }
    else if (s_n > 0 && s_sel < s_n - 1) {
      s_sel++;
      s_table_page = s_sel / ROWS;
      draw_table();
      draw_plot();
      { UiSummary fsm; ui_summarize(&fsm, s_now); draw_footer(fsm, nullptr); }
      refresh_area(RECT_BODY, false);
      s_sig_prev = signature();
      return;
    } else {
      s_map = true;
      draw_board(true);
      s_sig_prev = signature();
      return;
    }
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

void ui_show_shutdown_screen() {
  if (!s_ok) return;
  epd_hl_set_all_white(&s_hl);
  const GFXfont* f9  = &FreeSansBold9pt7b;
  const GFXfont* f12 = &FreeSansBold12pt7b;
  const GFXfont* f18 = &FreeSansBold18pt7b;

  // Header banner
  rect(0, 0, W, 68, BLACK);
  text(f18, "ORECCHINO T5 TACTICAL CONSOLE", 24, 46, WHITE);

  // Central dialog frame
  int box_w = 580, box_h = 240;
  int box_x = (W - box_w) / 2;
  int box_y = (H - box_h) / 2 - 10;
  rect(box_x, box_y, box_w, box_h, WHITE);
  box(box_x, box_y, box_w, box_h, BLACK);
  box(box_x + 2, box_y + 2, box_w - 4, box_h - 4, BLACK);

  // Inner dark title band
  rect(box_x + 6, box_y + 6, box_w - 12, 46, BLACK);
  const char* title = "DEVICE POWERED OFF";
  text(f18, title, box_x + (box_w - text_w(f18, title)) / 2, box_y + 38, WHITE);

  // Subtitle
  const char* sub = "All radio receivers, sensors, and displays are shut down.";
  text(f9, sub, box_x + (box_w - text_w(f9, sub)) / 2, box_y + 88, BLACK);

  // Instructions
  const char* ins1 = "• Battery Mode: Press PWR button to power on";
  text(f12, ins1, box_x + 45, box_y + 130, BLACK);

  const char* ins2 = "• USB / Standby Mode: Press side button to wake";
  text(f12, ins2, box_x + 45, box_y + 164, BLACK);

  // Battery status line inside box
  char stat[64];
  int mv = periph_batt_mv();
  if (mv > 0) {
    snprintf(stat, sizeof(stat), "Battery Status: %d%% (%d mV) | Standby Ready", s_batt >= 0 ? s_batt : 0, mv);
  } else {
    snprintf(stat, sizeof(stat), "Power State: External Standby | Standby Ready");
  }
  text(f9, stat, box_x + (box_w - text_w(f9, stat)) / 2, box_y + 210, GREY);

  // Bottom footer watermark
  const char* foot = "Orecchino ASTM F3411 Remote ID Receiver | LilyGO T5 E-Paper S3 Pro";
  text(f9, foot, (W - text_w(f9, foot)) / 2, H - 24, GREY);

  // Full GC16 refresh to clear any ghosting and freeze high-contrast image
  epd_poweron();
  epd_hl_update_screen(&s_hl, MODE_GC16, epd_ambient_temperature());
  epd_poweroff();
}

