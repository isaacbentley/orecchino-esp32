#include "ui_epd.h"
#include "board_t5.h"
#include "t5_periph.h"
#include "../common/ui_common.h"
#include "../common/traffic.h"
#include "../common/net_sync.h"
#include "../common/ext_ram.h"
#include <epdiy.h>
#include <LittleFS.h>
#include <Preferences.h>
#include <PNGdec.h>
#include <JPEGDEC.h>
#include <new>
#include "../common/map_tone.h"
#include "../common/tile_path.h"
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
#define LIGHT 0x88   // grey 8: the lightest tone the panel shows distinctly
#define ROW_H 46
#define ROWS  8
#define TABLE_X 20
#define TABLE_W 540
#define TAB_X 322     // header view tabs: three of TAB_W from here
#define TAB_W 84
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
static bool s_map = false;        // table (false) or map (true) board
static bool s_side = false;       // side view: height against range (s_map stays false)
static bool s_map_touched = false; // first-use guidance
static int  s_cam_z = 13;         // map camera: zoom and centre in world px
static double s_cam_wx = 0, s_cam_wy = 0;
static bool s_cam_valid = false;
static bool s_cam_manual = false; // touched: auto-follow suspended
static uint32_t s_cam_manual_ms = 0;
static uint32_t s_last_full = 0;
static int s_partials = 0;
static uint32_t s_sig_prev = 0;
static UiAlert s_alert_prev = UI_QUIET;
static uint8_t s_mode = UI_MODE_RX;
static bool s_confirm_switch = false;
static uint8_t s_target_mode = UI_MODE_RX;
#define UI_TARGET_POWER_OFF 0xFF   // s_target_mode: the confirm modal powers off instead of rebooting
#define UI_TARGET_CLEAR_LOG 0xFE   // ...or clears the saved drone history
// The match log lives in the receiver core (rx_core.h, the sketch's unit).
void rx_log_clear_all();                            // clear, save now, tell every host
void rx_log_stats(int* held, uint32_t* oldest_age_s);
static bool s_hist_cleared = false;                 // SYSTEM says "history cleared" until a record arrives
/// The saved drone history in brief: "48 records, oldest 2 h ago" (or
/// "no saved drone records", or "History cleared" right after a clear).
static void history_words(char* b, size_t n) {
  int held = 0; uint32_t age = UINT32_MAX;
  rx_log_stats(&held, &age);
  if (held) s_hist_cleared = false;
  if (!held) { snprintf(b, n, s_hist_cleared ? "History cleared" : "no saved drone records"); return; }
  char a[24] = "";
  if (age != UINT32_MAX) {
    if (age < 60) snprintf(a, sizeof(a), ", oldest just now");
    else if (age < 3600) snprintf(a, sizeof(a), ", oldest %lu min ago", (unsigned long)(age / 60));
    else if (age < 172800) snprintf(a, sizeof(a), ", oldest %lu h ago", (unsigned long)(age / 3600));
    else snprintf(a, sizeof(a), ", oldest %lu days ago", (unsigned long)(age / 86400));
  }
  snprintf(b, n, "%d record%s%s", held, held == 1 ? "" : "s", a);
}
static int s_table_page = 0;       // 0 for rows 0..7, 1 for rows 8..15
static bool s_inspector = false;    // Contact detail modal
static bool s_diag = false;         // System diagnostics & hardware calibration screen
static bool s_wifi_modal = false;   // Wi-Fi networks screen (full screen, opened from SYSTEM)
static bool s_kb_modal = false;     // on-screen keyboard (full screen, over the networks screen)
static char s_kb_ssid[NET_MAX_SSID_LEN + 1] = {0};
static char s_kb_buf[NET_MAX_PASS_LEN + 1] = {0};
static uint8_t  s_kb_layer = 0;     // 0 letters, 1 symbols
static bool     s_kb_shift = false; // one-shot capital
static bool     s_kb_caps = false;  // caps lock: SHIFT tapped twice
static uint32_t s_kb_shift_ms = 0;
static bool     s_kb_show = false;  // the password as typed (masked by default)
static bool     s_kb_ssid_stage = false;  // typing a hidden network's name first
static int      s_kb_du = 0;        // fast (DU) updates since the field was cleaned
// Touches released while the panel was busy are dropped, never queued:
// a finger that tapped twice during a refresh must not type two letters.
static uint32_t s_touch_ignore_ms = 0;
// Wi-Fi screens: the list, a saved network's actions, joining, the result.
enum WifiView : uint8_t { WV_LIST = 0, WV_ACTION, WV_JOINING, WV_RESULT };
static uint8_t  s_wv = WV_LIST;
static int      s_wifi_page = 0;
static char     s_wifi_ssid[NET_MAX_SSID_LEN + 1] = {0};  // the network being acted on
static bool     s_wifi_was_scanning = false;
static uint32_t s_wifi_join_ms = 0;
static bool     s_wifi_join_ok = false;
static bool     s_wifi_join_seen = false;   // the join request reached CONNECTING
static char     s_wifi_join_err[64] = {0};
static char     s_diag_note[64] = {0};  // SYSTEM's last Wi-Fi action, until the next one
// ADS-B traffic (traffic.h): the aircraft chosen by tapping its diamond ("" none).
static char     s_ac_hex[7] = "";
// Phone pairing (rx_hook_pairing, NimBLE's task): the loop draws it.
static volatile bool     s_pair_show = false;
static volatile uint32_t s_pair_key = 0;
static void draw_board(bool force_full);
#define DEFAULT_VCOM 1560
// Service screen rows (drawing and touch routing use the same numbers):
// everyday controls first, engineering last.
#define DG_BL_BTN_Y   98     // 1. backlight mode / brightness buttons
#define DG_BL_BTN_H   30
#define DG_MODE_BTN_Y 164    // 2. mode switch / power off
#define DG_MODE_BTN_H 32
#define DG_TXB_W      280    //    SWITCH TO TEST BEACON
#define DG_PWR_X      318    //    POWER OFF
#define DG_PWR_W      160
#define DG_CLR_X      494    //    CLEAR HISTORY, the saved records beside it
#define DG_CLR_W      170
#define DG_WIFI_BTN_Y 232    // 3. Wi-Fi: NETWORKS, MODE, SYNC NOW, UPDATE MAP
#define DG_WIFI_BTN_H 32
#define DG_WF_X0 24
#define DG_WF_W0 170
#define DG_WF_X1 204
#define DG_WF_W1 170
#define DG_WF_X2 384
#define DG_WF_W2 160
#define DG_WF_X3 554
#define DG_WF_W3 180
#define DG_ADSB_Y     272    //    ADS-B radius stepper, then the conflict watch status
#define DG_MAP_Y      308    //    map area stepper, then the storage plan
#define DG_STEP_H     30
#define DG_STEP_X     168    //    [-] value [+]
#define DG_VCOM_BTN_Y 440    // 5. VCOM trim buttons, the greyscale strip beside them
#define DG_VCOM_BTN_H 32
static uint16_t s_vcom = DEFAULT_VCOM;

// PMIC rail hold: avoid repeated TPS65185 power-up/down (~90 ms each).
// Keep high-voltage rails energized during active interaction; idle-timeout
// after EPD_POWER_HOLD_MS of inactivity.
#define EPD_POWER_HOLD_MS 3000
static bool     s_epd_powered = false;
static uint32_t s_epd_last_use_ms = 0;

static void epd_ensure_on() {
  if (!s_epd_powered) { epd_poweron(); s_epd_powered = true; }
  s_epd_last_use_ms = s_now;
}
static void epd_idle_check(uint32_t now) {
  if (s_epd_powered && (now - s_epd_last_use_ms > EPD_POWER_HOLD_MS)) {
    epd_poweroff();
    s_epd_powered = false;
  }
}

// 8-pixel aligned bounding boxes for sub-screen updates (eliminates sub-byte boundary artifacts)
static const EpdRect RECT_BODY = { 0, 72, 960, 468 };   // table + plot + footer
static const EpdRect RECT_TABLE  = { 16, 72, 552, 424 };
static const EpdRect RECT_PLOT   = { 568, 72, 392, 424 };
static const EpdRect RECT_MAIN   = { 16, 72, 944, 424 }; // Table + Plot combined
static const EpdRect RECT_MAP    = { 0, 72, 960, 424 };
static const EpdRect RECT_FOOTER = { 0, 496, 960, 44 };

uint8_t ui_get_mode() { return s_mode; }
bool ui_diagnostics_active() { return s_diag; }

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
// UI_TEXT_HOOK is a seam for the host-side render check (tests/t5_render_test.cpp):
// it sees every text run, so runs that collide are caught before they reach glass.
static void text(const GFXfont* f, const char* s, int x, int y, uint8_t color = BLACK) {
#ifdef UI_TEXT_HOOK
  UI_TEXT_HOOK(f, s, x, y);
#endif
  glyph_run(f, s, x, y, color, true);
}
static int  text_w(const GFXfont* f, const char* s) { return glyph_run(f, s, 0, 0, 0, false); }
static void text_r(const GFXfont* f, const char* s, int xr, int y, uint8_t color = BLACK) { text(f, s, xr - text_w(f, s), y, color); }
static void rect(int x, int y, int w, int h, uint8_t c) { EpdRect r = {x, y, w, h}; epd_fill_rect(r, c, s_fb); }
static void box(int x, int y, int w, int h, uint8_t c) { EpdRect r = {x, y, w, h}; epd_draw_rect(r, c, s_fb); }

// Stubs for common radio hooks
void ui_feed_wifi(uint8_t, int8_t) {}
void ui_set_wifi_channel(uint8_t) {}
bool ui_spectrum_active() { return false; }

// Danger first, then live contacts, then history (shared with every board).
// The selection follows its aircraft: s_selid names the contact, s_sel is
// merely the row it sits on this time round. s_sel == -1 is the deliberate
// "nothing selected" state (map HUD [X]); every s_order[s_sel] read is
// range-guarded.
static UiSel s_selid = {-1, 0};
static void select_row(int r) {
  s_sel = r;
  ui_sel_set(&s_selid, (r >= 0 && r < s_n) ? s_order[r] : -1);
  if (r >= 0) s_table_page = r / ROWS;
}
static void build_order() {
  ui_order_build(s_order, &s_n, s_now);
  if (s_n == 0) { s_sel = 0; ui_sel_set(&s_selid, -1); s_table_page = 0; return; }
  if (s_sel == -1 && s_selid.slot < 0) { s_table_page = 0; return; }
  int row = ui_sel_row(&s_selid, s_order, s_n);
  if (row < 0) { row = 0; ui_sel_set(&s_selid, s_order[0]); }   // first contact, or the chosen one has gone
  s_sel = row;
  s_table_page = s_sel / ROWS;
}

// ---- text fitting: nothing may run into the next column or a control
/// Shorten `b` (capacity n) with ".." until it is at most `max_w` wide.
static void fit_text(char* b, size_t n, const GFXfont* f, int max_w) {
  if (text_w(f, b) <= max_w) return;
  size_t len = strlen(b);
  char t[96];
  while (len > 1) {
    b[--len] = 0;
    snprintf(t, sizeof(t), "%s..", b);
    if (text_w(f, t) <= max_w) { snprintf(b, n, "%s", t); return; }
  }
}
/// Draw `s` on one or two lines of `max_w`, breaking at a space; returns
/// the number of lines used.
static int text_wrap2(const GFXfont* f, const char* s, int x, int y, int line_h, int max_w, uint8_t color) {
  char l1[96]; snprintf(l1, sizeof(l1), "%s", s);
  if (text_w(f, l1) <= max_w) { text(f, l1, x, y, color); return 1; }
  int cut = -1;
  for (int i = 1; l1[i]; i++) {
    if (l1[i] != ' ') continue;
    l1[i] = 0;
    bool ok = text_w(f, l1) <= max_w;
    l1[i] = ' ';
    if (ok) cut = i; else break;
  }
  if (cut < 0) { fit_text(l1, sizeof(l1), f, max_w); text(f, l1, x, y, color); return 1; }
  l1[cut] = 0;
  text(f, l1, x, y, color);
  char l2[96]; snprintf(l2, sizeof(l2), "%s", s + cut + 1);
  fit_text(l2, sizeof(l2), f, max_w);
  text(f, l2, x, y + line_h, color);
  return 2;
}

/// Draw `s` wrapped at spaces to `max_w`, at most `max_lines` lines (the
/// last one fitted with ".."); returns the lines used. draw=false only counts.
static int text_para(const GFXfont* f, const char* s, int x, int y, int line_h, int max_w, uint8_t color,
                     int max_lines, bool draw = true) {
  int lines = 0;
  while (*s && lines < max_lines) {
    char l[128]; int best = -1, i = 0;
    for (; s[i] && i < (int)sizeof(l) - 1; i++) {
      l[i] = s[i];
      if (s[i] == ' ') { l[i] = 0; if (text_w(f, l) <= max_w) best = i; else break; l[i] = ' '; }
    }
    l[i] = 0;
    if (!s[i] && text_w(f, l) <= max_w) { if (draw) text(f, l, x, y + lines * line_h, color); return lines + 1; }
    if (best < 0 || lines == max_lines - 1) {   // the last line: whatever fits of the rest
      snprintf(l, sizeof(l), "%s", s);
      fit_text(l, sizeof(l), f, max_w);
      if (draw) text(f, l, x, y + lines * line_h, color);
      return lines + 1;
    }
    l[best] = 0;
    if (draw) text(f, l, x, y + lines * line_h, color);
    s += best + 1;
    lines++;
  }
  return lines;
}

// ---- wording shared by every screen, so each says these things one way
/// The transports a contact was heard on: "Wi-Fi, NAN, BLE".
static void carriers_text(char* b, size_t n, uint8_t mask) {
  static const char* names[3] = { "Wi-Fi", "NAN", "BLE" };
  b[0] = 0;
  for (int i = 0; i < 3; i++) {
    if (!(mask & (1 << i))) continue;
    size_t o = strlen(b);
    snprintf(b + o, n - o, "%s%s", o ? ", " : "", names[i]);
  }
}
/// How long ago: "now", "12s ago", "3min ago" ("m" is metres here).
static void age_text(char* b, size_t n, uint32_t age_s) {
  if (age_s < 10) snprintf(b, n, "now");
  else if (age_s < 60) snprintf(b, n, "%lus ago", (unsigned long)age_s);
  else snprintf(b, n, "%lumin ago", (unsigned long)(age_s / 60));
}
/// A distance in running text: "350 m", "1.5 km". Table cells and plot
/// labels keep the compact ui_fmt_range() form.
static void dist_text(char* b, size_t n, double m) {
  if (m >= 1000) snprintf(b, n, "%.1f km", m / 1000); else snprintf(b, n, "%d m", (int)m);
}
static const char* cardinal(float deg) {
  static const char* C[8] = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" };
  return C[(int)((deg + 22.5f) / 45.0f) % 8];
}
/// The ID signature state in words, as every board says it (ui_common.h):
/// a test-key signature reads "TEST KEY", never "valid". The table's AUTH
/// column is the short form.
static const char* sig_words(uint8_t st) { return st ? ui_auth_text(st) : "ID sig: none"; }
/// Whole seconds since a stamp. Signed: the decode task stamps last_ms with
/// a millis() newer than the loop's s_now, and unsigned that would wrap.
static uint32_t since_s(uint32_t ms) {
  int32_t d = (int32_t)(s_now - ms);
  return d > 0 ? (uint32_t)d / 1000 : 0;
}

// ---- ADS-B traffic (traffic.h). Separations in km and m, like the rest of
// the board; an aircraft's own altitude and speed in ft and kt, as ADS-B and
// pilots give them. Never NM, never a prediction, never "clear".
/// Nearest integer; 0 for NaN/inf, whose cast to an integer is undefined.
static long iround(double v) { return isfinite(v) ? (long)floor(v + 0.5) : 0; }
/// "2,650 ft"
static void ft_text(char* b, size_t n, double m) {
  long ft = iround(m / TRAFFIC_FT_TO_M), a = labs(ft);
  if (a >= 1000) snprintf(b, n, "%s%ld,%03ld ft", ft < 0 ? "-" : "", a / 1000, a % 1000);
  else snprintf(b, n, "%ld ft", ft);
}
/// Marker label altitude, "2.6k ft" or "850 ft": pressure altitude (what a
/// pilot reads), else geometric; "" when neither was reported.
static void ac_alt_short(const TrafficAircraft* a, char* b, size_t n) {
  if (a->on_ground) { snprintf(b, n, "GND"); return; }
  double m = isfinite(a->alt_baro_m) ? a->alt_baro_m : a->alt_geom_m;
  if (!isfinite(m)) { b[0] = 0; return; }
  long ft = iround(m / TRAFFIC_FT_TO_M);
  if (ft >= 1000) snprintf(b, n, "%ld.%ldk ft", ft / 1000, (ft % 1000) / 100);
  else snprintf(b, n, "%ld ft", ft);
}
/// Position older than the rules' freshness window: drawn grey.
static bool ac_old(const TrafficAircraft* a) { return traffic_age_s(a->seen_ms, s_now) >= TRAFFIC_FRESH_S; }
static int ac_index(const char* hex) {
  if (!hex || !hex[0]) return -1;
  for (int i = 0; i < g_traffic_count; i++) if (!strcmp(g_traffic_ac[i].hex, hex)) return i;
  return -1;
}
/// The id traffic.h knows a contact by: its UAS ID, else its MAC.
static void drone_key(const Track* t, char* out, size_t n) {
  if (t->uas[0]) snprintf(out, n, "%s", t->uas);
  else snprintf(out, n, "%02X%02X%02X%02X%02X%02X", t->mac[0], t->mac[1], t->mac[2], t->mac[3], t->mac[4], t->mac[5]);
}
/// The table slot of the drone an alert names, -1 when it has gone.
static int drone_slot(const char* id) {
  char k[TRAFFIC_ID_LEN];
  for (int i = 0; i < TRK_MAX; i++) {
    if (!g_tracks[i].used) continue;
    drone_key(&g_tracks[i], k, sizeof(k));
    if (!strcmp(k, id)) return i;
  }
  return -1;
}
static bool is_pair(const TrafficAlert* a) { return a && a->kind <= TRAFFIC_KIND_CONVERGING && a->drone_id[0]; }
/// The most urgent pair alert naming this drone, or NULL (alerts are sorted).
static const TrafficAlert* alert_for_drone(const Track* t) {
  char k[TRAFFIC_ID_LEN]; drone_key(t, k, sizeof(k));
  for (int i = 0; i < g_traffic_result.n; i++)
    if (is_pair(&g_traffic_result.alerts[i]) && !strcmp(g_traffic_result.alerts[i].drone_id, k))
      return &g_traffic_result.alerts[i];
  return nullptr;
}
/// A drone's loud reasons in words, an ADS-B conflict's action first (its
/// own id dropped, the row already names it): "GIVE WAY: DESCEND AND LAND +
/// TFR MATCH". Empty when quiet or stale.
static void drone_alert_words(char* b, size_t n, const Track* t) {
  char al[48]; ui_alert_text(al, sizeof(al), t, s_now);
  const TrafficAlert* ta = alert_for_drone(t);
  char act[TRAFFIC_ACTION_LEN] = "";
  if (ta) {
    snprintf(act, sizeof(act), "%s", ta->action);
    char id[TRAFFIC_ID_LEN]; traffic_drone_label(ta->drone_id, id, sizeof(id));
    size_t la = strlen(act), li = strlen(id);
    if (li && la > li + 1 && !strcmp(act + la - li, id) && act[la - li - 1] == ' ') act[la - li - 1] = 0;
  }
  traffic_textf(b, n, "%s%s%s", act, act[0] && al[0] ? " + " : "", al);
}
/// What the plot panel shows as a traffic card: the alerting aircraft tapped
/// on the plot or map, else, while a warning lasts, the most urgent warning.
/// Aircraft appear only through an alert: there is no card for one that is
/// not in conflict with a drone. `ac` is NULL for a warning kept by the
/// hysteresis after its aircraft left the feed (the card then shows the
/// alert's last numbers).
static bool traffic_card_pick(const TrafficAircraft** ac, const TrafficAlert** al) {
  *ac = nullptr; *al = nullptr;
  if (s_ac_hex[0]) {
    const TrafficAlert* a = traffic_alert_for_hex(&g_traffic_result, s_ac_hex);
    int i = ac_index(s_ac_hex);
    if (a) { *al = a; *ac = i >= 0 ? &g_traffic_ac[i] : nullptr; return true; }
    s_ac_hex[0] = 0;   // its alert ended
  }
  const TrafficResult* r = &g_traffic_result;
  if (r->n && r->alerts[0].level == TRAFFIC_WARNING) {
    *al = &r->alerts[0];
    int i = ac_index(r->alerts[0].hex);
    *ac = i >= 0 ? &g_traffic_ac[i] : nullptr;
    return true;
  }
  return false;
}
/// The geometry half of an alert's resolution ("AIRCRAFT 90 M ABOVE, 800 M
/// NE, CLOSEST IN 24 S"): what follows the action and "; ".
static const char* alert_geometry(const TrafficAlert* a) {
  const char* p = strstr(a->resolution, "; ");
  return p ? p + 2 : "";
}
/// Where an alert's line goes from: its drone, else (an alert about the
/// airspace, not one drone) the board. False when neither is on screen.
static bool alert_anchor(const TrafficAlert* a, double* lat, double* lon) {
  int slot = (!a->from_observer && a->drone_id[0]) ? drone_slot(a->drone_id) : -1;
  if (slot >= 0 && g_tracks[slot].has_pos) { *lat = g_tracks[slot].lat; *lon = g_tracks[slot].lon; return true; }
  if (g_home_set) { *lat = g_home_lat; *lon = g_home_lon; return true; }
  return false;
}

// Drones as the traffic rules see them, rebuilt from the table each pass
// (1.5 KB: in PSRAM, the internal heap is the radios').
static TrafficDrone* s_tdrones = nullptr;
static uint32_t     s_warn_keys[TRAFFIC_MAX_ALERTS];
static int          s_nwarn_keys = 0;
static uint32_t     s_traffic_ms = 0;
/// Evaluate the ADS-B set against this board's drones (traffic_tick) with
/// the board as the observer. True when a warning appeared that was not
/// there last time: the caller flashes the panel and pulses the light.
static bool ui_traffic_update(uint32_t now) {
  if (!s_tdrones) s_tdrones = ext_new<TrafficDrone>(TRK_MAX);
  if (!s_tdrones) return false;
  int nd = 0;
  for (int i = 0; i < TRK_MAX; i++) {
    const Track* t = &g_tracks[i];
    if (!t->used || !t->has_pos) continue;
    TrafficDrone* d = &s_tdrones[nd++];
    drone_key(t, d->id, sizeof(d->id));
    d->lat = t->lat; d->lon = t->lon;
    d->alt_geo_m = isfinite(t->alt_geo) ? t->alt_geo : NAN;
    d->speed_mps = isfinite(t->speed) ? t->speed : NAN;
    d->heading_deg = isfinite(t->heading) ? t->heading : NAN;
    d->height_m = isfinite(t->height) ? t->height : NAN;   // LOW's ground level (never a zeroed 0 m)
    d->live = (int32_t)(now - t->last_ms) <= (int32_t)UI_ACTIVE_MS;
  }
  g_traffic_observer.lat = g_home_set ? g_home_lat : NAN;
  g_traffic_observer.lon = g_home_set ? g_home_lon : NAN;
  float e = periph_gps_elev_m();
  g_traffic_observer.elev_m = isfinite(e) ? (double)e : NAN;
  traffic_tick(s_tdrones, nd, now);
  s_traffic_ms = now;

  uint32_t keys[TRAFFIC_MAX_ALERTS]; int nk = 0; bool fresh = false;
  for (int i = 0; i < g_traffic_result.n; i++) {
    const TrafficAlert* a = &g_traffic_result.alerts[i];
    if (a->level != TRAFFIC_WARNING) continue;
    uint32_t h = 2166136261u;
    for (const char* p = a->drone_id; *p; p++) { h ^= (uint8_t)*p; h *= 16777619u; }
    for (const char* p = a->hex; *p; p++) { h ^= (uint8_t)*p; h *= 16777619u; }
    bool known = false;
    for (int j = 0; j < s_nwarn_keys; j++) if (s_warn_keys[j] == h) known = true;
    if (!known) fresh = true;
    keys[nk++] = h;
  }
  memcpy(s_warn_keys, keys, sizeof(uint32_t) * nk);
  s_nwarn_keys = nk;
  return fresh;
}

/// Table form of the k-th listed ID: the whole thing when it fits `max_w`,
/// else head + ".." + the tail that tells it from the others on screen --
/// serials differ at the end, so that is the part that must survive.
static void short_id(char* out, size_t n, int k, const GFXfont* f, int max_w) {
  const Track* t = &g_tracks[s_order[k]];
  if (!t->uas[0]) { snprintf(out, n, "NO ID"); return; }
  int tail = ui_unique_tail(s_order, s_n, k, 4);
  for (int chars = 40; chars >= tail + 2; chars--) {
    ui_short_id(out, n, t->uas, tail, chars);
    if (text_w(f, out) <= max_w) return;
  }
}
/// Marker label: the whole ID when it is short, else the distinguishing
/// tail (at least five characters), grown past any leading punctuation so
/// "DRONE-B-9A01" reads "B-9A01", never a cut-looking "-9A01".
static const char* label_id(int k) {
  const Track* t = &g_tracks[s_order[k]];
  if (!t->uas[0]) return "?";
  int len = (int)strlen(t->uas);
  if (len <= 8) return t->uas;
  int tail = ui_unique_tail(s_order, s_n, k, 5);
  while (tail < len && !isalnum((unsigned char)t->uas[len - tail])) tail++;
  return t->uas + len - tail;
}

// ---- marker labels: the selected aircraft and alerts always get first
// pick; the rest only where a label fits without covering a marker,
// another label or a control.
struct LabelBox { int x, y, w, h; };
static LabelBox s_lb[TRK_MAX * 2 + 8];
static int      s_nlb = 0;
static void lb_reset() { s_nlb = 0; }
static void lb_block(int x, int y, int w, int h) {
  if (s_nlb < (int)(sizeof(s_lb) / sizeof(s_lb[0]))) s_lb[s_nlb++] = {x, y, w, h};
}
static bool lb_free(const LabelBox& r, int x0, int y0, int x1, int y1) {
  if (r.x < x0 || r.y < y0 || r.x + r.w > x1 || r.y + r.h > y1) return false;
  for (int i = 0; i < s_nlb; i++) {
    const LabelBox& o = s_lb[i];
    if (r.x < o.x + o.w && o.x < r.x + r.w && r.y < o.y + o.h && o.y < r.y + r.h) return false;
  }
  return true;
}
/// A spot for a w x h label beside the marker at (px,py): right, left,
/// above, below. False when every spot is taken.
static bool lb_place(int px, int py, int w, int h, int x0, int y0, int x1, int y1, int* ox, int* oy,
                     int off = 10) {
  const int cand[4][2] = { {px + off, py - h / 2}, {px - off - w, py - h / 2},
                           {px - w / 2, py - off - 2 - h}, {px - w / 2, py + off + 2} };
  for (int i = 0; i < 4; i++) {
    LabelBox r = { cand[i][0], cand[i][1], w, h };
    if (!lb_free(r, x0, y0, x1, y1)) continue;
    lb_block(r.x, r.y, r.w, r.h);
    *ox = r.x; *oy = r.y;
    return true;
  }
  return false;
}
/// Rows in drawing priority: the selected aircraft, then table order
/// (danger, live, history).
static int priority_rows(int* rows) {
  int n = 0;
  if (s_sel >= 0 && s_sel < s_n) rows[n++] = s_sel;
  for (int k = 0; k < s_n; k++) if (k != s_sel) rows[n++] = k;
  return n;
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
  if (s_mode == UI_MODE_TX) {
    mix(txui_running());
    mix(txui_emergency());
    int n = txui_count();
    mix(txui_slow());
    for (int i = 0; i < n; i++) {
      mix(txui_enabled(i));
      mix(txui_sent(i) > 0);
    }
    // At the spec rate the sent counts move several times a second: ink
    // them once a minute, not at every check.
    mix(s_now / 60000);
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
  mix(s_map); mix(s_side); mix(s_map_touched); mix((uint32_t)(int32_t)(g_home_lat * 1e3)); mix((uint32_t)(int32_t)(g_home_lon * 1e3));
  mix(periph_gps_detected()); mix(periph_gps_fix()); mix(periph_gps_sats()); mix(s_cam_manual); mix(s_cam_z); mix((uint32_t)s_cam_wx); mix((uint32_t)s_cam_wy);
  mix(s_wifi_modal); mix(s_kb_modal); mix(s_pair_show); mix(s_wv);
  // Traffic: the alerts' words and coarse numbers, the feed's state and age
  // (10 s steps: the card shows it), and every aircraft to ~100 m.
  const TrafficResult* r = &g_traffic_result;
  mix(r->have_data); mix(r->stale); mix(r->n);
  mix(isfinite(r->data_age_s) ? (uint32_t)(r->data_age_s / 10) : 0xFFFF);
  for (int i = 0; i < r->n; i++) {
    const TrafficAlert* a = &r->alerts[i];
    for (const char* p = a->text; *p; p++) mix((uint8_t)*p);
    mix(a->held); mix((uint32_t)iround(a->horiz_m / 100)); mix((uint32_t)iround(a->vert_m / 10));
  }
  for (int i = 0; i < g_traffic_count; i++) {   // only those drawn: the alerting ones
    const TrafficAircraft* a = &g_traffic_ac[i];
    if (!traffic_alert_for_hex(r, a->hex)) continue;
    mix((uint32_t)(int32_t)(a->lat * 1e3)); mix((uint32_t)(int32_t)(a->lon * 1e3)); mix(ac_old(a));
  }
  for (const char* p = s_ac_hex; *p; p++) mix((uint8_t)*p);
  return h;
}

static void draw_header(const UiSummary& sm, const char* title) {
  // Traffic leads (§8.3): a warning makes the band black like a drone
  // emergency, and a warning or caution supplies the headline's words.
  const TrafficResult* tr = &g_traffic_result;
  bool traffic_head = !title && tr->n && tr->alerts[0].level >= TRAFFIC_CAUTION;
  bool loud = sm.alert == UI_EMERGENCY || (tr->n && tr->alerts[0].level == TRAFFIC_WARNING);
  rect(0, 0, W, 70, loud ? BLACK : WHITE);
  if (!loud) rect(0, 68, W, 2, BLACK);
  uint8_t fg = loud ? WHITE : BLACK;
  char b[72];
  if (title) snprintf(b, sizeof(b), "%s", title);
  else if (traffic_head) snprintf(b, sizeof(b), "%s", tr->alerts[0].action);   // what to do, first
  else ui_headline(b, sizeof(b), &sm);
  if (!title && !traffic_head && sm.tracked == 0) b[0] = 0;  // an empty sky needs no headline

  // The title must stay clear of the view switcher at x=330: step down
  // 18 -> 12 pt, then 12 pt on two lines, then 9 pt, before trimming, so
  // "EMERGENCY N CONTACTS" and "TRAFFIC NEAR DRONE D9A03" stay whole.
  // Two lines break at the space that balances them best.
  int cut = -1, cut_w = 1 << 30;
  if (b[0] && text_w(&FreeSansBold12pt7b, b) > 290) {
    for (int i = 1; b[i]; i++) {
      if (b[i] != ' ' || b[i - 1] == ' ') continue;
      int j = i; while (b[j] == ' ') j++;
      b[i] = 0;
      int w1 = text_w(&FreeSansBold12pt7b, b), w2 = text_w(&FreeSansBold12pt7b, b + j);
      b[i] = ' ';
      if (w1 <= 290 && w2 <= 290 && max(w1, w2) < cut_w) { cut = i; cut_w = max(w1, w2); }
    }
  }
  if (b[0]) {
    if (text_w(&FreeSansBold18pt7b, b) <= 290) {
      text(&FreeSansBold18pt7b, b, TABLE_X, 48, fg);
    } else if (text_w(&FreeSansBold12pt7b, b) <= 290) {
      text(&FreeSansBold12pt7b, b, TABLE_X, 44, fg);
    } else if (cut > 0) {
      b[cut] = 0;
      const char* l2 = b + cut + 1; while (*l2 == ' ') l2++;
      text(&FreeSansBold12pt7b, b, TABLE_X, 31, fg);
      text(&FreeSansBold12pt7b, l2, TABLE_X, 58, fg);
    } else {
      if (text_w(&FreeSansBold9pt7b, b) > 290) {
        size_t n = strlen(b);
        while (n > 3 && text_w(&FreeSansBold9pt7b, b) > 275) b[--n] = 0;
        if (n + 2 < sizeof(b)) strcat(b, "..");
      }
      text(&FreeSansBold9pt7b, b, TABLE_X, 42, fg);
    }
  }

  // Persistent Segmented View Switcher: [ TABLE | MAP | SIDE ]
  // (Available whenever in RX mode and not in modal diagnostics). It sits
  // between the title (which stops at x=310) and the status cluster (584).
  if (s_mode != UI_MODE_TX && !s_diag) {
    const int bx = TAB_X, by = 12, tw = TAB_W, bh = 46, bw = tw * 3;
    uint8_t border_col = loud ? WHITE : BLACK;
    box(bx, by, bw, bh, border_col);
    box(bx + 1, by + 1, bw - 2, bh - 2, border_col);
    rect(bx + tw - 1, by, 2, bh, border_col);
    rect(bx + 2 * tw - 1, by, 2, bh, border_col);
    const char* names[3] = { "TABLE", "MAP", "SIDE" };
    int cur = s_side ? 2 : s_map ? 1 : 0;
    for (int i = 0; i < 3; i++) {
      bool on = i == cur;
      // The chosen tab is inked in the header's opposite colour.
      bool ink = on != loud;
      rect(bx + i * tw + (i ? 1 : 2), by + 2, tw - 3, bh - 4, ink ? BLACK : WHITE);
      int w = text_w(&FreeSansBold12pt7b, names[i]);
      text(&FreeSansBold12pt7b, names[i], bx + i * tw + (tw - w) / 2, 41, ink ? WHITE : BLACK);
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
    xr = bx - 12;
  }

  // GPS status, the ADS-B feed, then the UTC clock (minutes only: nothing
  // redraws on the second). Each item is drawn only if it fits left of the
  // view switcher (which ends at x=570) instead of printing over the tabs.
  const int cluster_min_x = 580;   // the view switcher's box ends at 574
  if (periph_gps_fix()) snprintf(b, sizeof(b), "GPS %d", periph_gps_sats());
  else if (periph_gps_detected()) snprintf(b, sizeof(b), "GPS --");
  else snprintf(b, sizeof(b), !g_home_set ? "NO POS" : !strcmp(g_home_src, "saved") ? "SAVED POS" : "APP POS");
  int gw = text_w(&FreeSansBold9pt7b, b);
  if (xr - gw >= cluster_min_x) {
    text_r(&FreeSansBold9pt7b, b, xr, 42, fg);
    xr -= gw + 12;
  }
  // Whether the conflict watch is running: ADS-B ON, ADS-B STALE, or
  // nothing without a source (the footer and SYSTEM then say it is off).
  // Never a count of aircraft: the board counts drones.
  if (tr->have_data) {
    snprintf(b, sizeof(b), tr->stale ? "ADS-B STALE" : "ADS-B ON");
    int aw = text_w(&FreeSansBold9pt7b, b);
    if (xr - aw >= cluster_min_x) {
      text_r(&FreeSansBold9pt7b, b, xr, 42, fg);
      xr -= aw + 12;
    }
  }
  if (periph_has_utc_time()) {
    uint16_t cy; uint8_t cm, cd, ch, cmi, cs;
    periph_get_utc_time(&cy, &cm, &cd, &ch, &cmi, &cs);
    snprintf(b, sizeof(b), "%02u:%02uZ", ch, cmi);
    int cw = text_w(&FreeSansBold9pt7b, b);
    if (xr - cw >= cluster_min_x) text_r(&FreeSansBold9pt7b, b, xr, 42, fg);
  }
}

static int s_page_bx = 330, s_page_bw = 0;   // the PAGE button, for the hit test
static void draw_footer(const UiSummary& sm, const char* hint) {
  rect(0, 496, W, 44, WHITE);
  rect(0, 496, W, 2, BLACK);
  const GFXfont* f9 = &FreeSansBold9pt7b;
  char b[96];
  if (sm.newest_age_s == UINT32_MAX) snprintf(b, sizeof(b), "SCANNING");
  else if (sm.newest_age_s < 10) snprintf(b, sizeof(b), "RECEIVING");
  else if (sm.newest_age_s < 60) snprintf(b, sizeof(b), "QUIET <1 MIN");
  else snprintf(b, sizeof(b), "QUIET %lu MIN", (unsigned long)(sm.newest_age_s / 60));

  // "QUIET" is about Remote ID only. The conflict watch has its own words
  // (traffic_summary's, short): CONFLICTS n, WATCH ON, TRAFFIC DATA STALE,
  // CONFLICT WATCH OFF -- never a count of aircraft.
  char count_buf[48];
  snprintf(count_buf, sizeof(count_buf), " | %d LIVE", sm.active);
  strncat(b, count_buf, sizeof(b) - strlen(b) - 1);
  const TrafficResult* tr = &g_traffic_result;
  if (!tr->have_data) snprintf(count_buf, sizeof(count_buf), " | CONFLICT WATCH OFF");
  else if (tr->stale) snprintf(count_buf, sizeof(count_buf), " | TRAFFIC DATA STALE");
  else {
    unsigned conf = 0, low = 0;   // as traffic_summary counts them
    for (int i = 0; i < tr->n; i++) { if (is_pair(&tr->alerts[i])) conf++; else low++; }
    if (conf && low) snprintf(count_buf, sizeof(count_buf), " | ADS-B CONFLICTS %u + LOW TRAFFIC", conf);
    else if (conf) snprintf(count_buf, sizeof(count_buf), " | ADS-B CONFLICTS %u", conf);
    else if (low) snprintf(count_buf, sizeof(count_buf), " | LOW TRAFFIC");
    else snprintf(count_buf, sizeof(count_buf), " | CONFLICT WATCH ON");
  }
  strncat(b, count_buf, sizeof(b) - strlen(b) - 1);
  // STAY mode holds the radio on the access point's channel (plan §4.2):
  // Remote ID over Wi-Fi is heard there only, and the board says so.
  if (net_get_mode() == NET_MODE_STAY && net_get_channel()) {
    snprintf(count_buf, sizeof(count_buf), " | WI-FI CH %u ONLY", (unsigned)net_get_channel());
    strncat(b, count_buf, sizeof(b) - strlen(b) - 1);
  }
  if (g_seen_count && text_w(f9, b) < 300) {
    snprintf(count_buf, sizeof(count_buf), " | %lu SEEN", (unsigned long)g_seen_count);
    strncat(b, count_buf, sizeof(b) - strlen(b) - 1);
  }
  text(f9, b, TABLE_X, 524, BLACK);
  int left_edge = TABLE_X + text_w(f9, b) + 16;   // where a hint may start

  // Pagination button on Table, after the status (the hit test reads s_page_bx)
  s_page_bw = 0;
  if (!s_map && !s_side && s_n > ROWS) {
    int total_pages = (s_n + ROWS - 1) / ROWS;
    char page_str[32];
    snprintf(page_str, sizeof(page_str), "PAGE %d/%d", s_table_page + 1, total_pages);
    int pw = text_w(f9, page_str) + 24;
    int px = max(330, left_edge), py = 502, ph = 32;
    box(px, py, pw, ph, BLACK);
    text(f9, page_str, px + 12, py + 22, BLACK);
    s_page_bx = px; s_page_bw = pw;
    left_edge = px + pw + 16;
  }

  // Right-side footer action buttons
  int btn_y = 502, btn_h = 32;
  // Button: [ SYSTEM ]
  int sys_w = 90, sys_x = W - 20 - sys_w;
  box(sys_x, btn_y, sys_w, btn_h, BLACK);
  text(f9, "SYSTEM", sys_x + (sys_w - text_w(f9, "SYSTEM")) / 2, btn_y + 22, BLACK);
  int right_edge = sys_x - 16;

  // Button: [ DETAILS ] (if an aircraft is selected on Table)
  if (!s_map && s_n > 0 && s_sel >= 0 && s_sel < s_n) {
    int ins_w = 100, ins_x = sys_x - 12 - ins_w;
    rect(ins_x, btn_y, ins_w, btn_h, BLACK);
    text(f9, "DETAILS", ins_x + (ins_w - text_w(f9, "DETAILS")) / 2, btn_y + 22, WHITE);
    right_edge = ins_x - 16;
  }

  // What a tap does here, in whatever room is left between the status and
  // the buttons -- the board should never rely on the reader discovering it.
  if (!hint) hint = "tap row: select | tap plot: map";
  char h[96]; snprintf(h, sizeof(h), "%s", hint);
  int max_w = right_edge - left_edge;
  // Whole instructions only: drop trailing " | ..." parts rather than cut one.
  while (text_w(f9, h) > max_w) {
    char* bar = strrchr(h, '|');
    if (!bar || bar - h < 3) { h[0] = 0; break; }
    bar[-1] = 0;
  }
  if (h[0]) text_r(f9, h, right_edge, 524, GREY);
}

// Column layout, measured against the actual font so no heading or value
// can run into its neighbour, and the same whatever the GPS is doing: a
// missing range or bearing shows as dashes rather than moving the columns.
// Units sit in the headings; the values are bare numbers.
struct TableCol { const char* head; const char* widest; int x, w; };
static TableCol s_cols[5] = {
  {"HGT m", "1250", 0, 0}, {"SPD m/s", "99.9", 0, 0}, {"RNG", "99.9km", 0, 0},
  {"BRG", "359", 0, 0}, {"AUTH", "KEY?", 0, 0},
};
/// Lay the columns out from the right edge; returns the width left for the ID.
static int layout_columns(const GFXfont* f) {
  const int gap = 14;
  int x = TABLE_X + TABLE_W - 8;
  for (int i = 4; i >= 0; i--) {
    int w = max(text_w(f, s_cols[i].head), text_w(f, s_cols[i].widest));
    if (i == 4) w = max(w, 34);              // the inverted BAD badge
    x -= w;
    s_cols[i].x = x; s_cols[i].w = w;
    x -= gap;
  }
  return x - (TABLE_X + 8);
}

static void draw_table() {
  rect(RECT_TABLE.x, RECT_TABLE.y, RECT_TABLE.width, RECT_TABLE.height, WHITE);
  const int y0 = 80;
  const GFXfont* f9 = &FreeSansBold9pt7b;
  const GFXfont* f12 = &FreeSansBold12pt7b;
  int id_w = layout_columns(f9);
  text(f9, "ID", TABLE_X + 8, y0 + 16, BLACK);
  for (auto& c : s_cols) text(f9, c.head, c.x, y0 + 16, BLACK);
  rect(TABLE_X, y0 + 22, TABLE_W, 2, BLACK);
  rect(565, 76, 1, 416, LIGHT);  // vertical divider between table and right board

  int start_k = s_table_page * ROWS;
  for (int i = 0; i < ROWS; i++) {
    int k = start_k + i;
    if (k >= s_n) break;
    const Track* t = &g_tracks[s_order[k]];
    int y = y0 + 24 + i * ROW_H;
    const TrafficAlert* ta = alert_for_drone(t);
    bool stale = ui_stale(t, s_now), sel = (k == s_sel);
    bool danger = ui_danger(t, s_now) || (ta && ta->level == TRAFFIC_WARNING);
    uint8_t ink = sel ? WHITE : (stale ? GREY : BLACK);

    if (sel) rect(TABLE_X, y, TABLE_W, ROW_H - 2, BLACK);   // inverted row
    else rect(TABLE_X + 8, y + ROW_H - 2, TABLE_W - 8, 1, LIGHT);
    if (danger && !sel) box(TABLE_X + 8, y - 2, TABLE_W - 8, ROW_H - 2, BLACK);

    // Line 1: the ID, shortened from the head so the distinguishing tail
    // survives. Line 2: the literal alert, or the status and when the
    // aircraft was last heard. Transports and RSSI live in the details.
    char b[64];
    short_id(b, sizeof(b), k, f12, id_w);
    text(f12, b, TABLE_X + 8, y + 20, ink);
    char age[16]; age_text(age, sizeof(age), since_s(t->last_ms));
    char al[72]; drone_alert_words(al, sizeof(al), t);
    traffic_textf(b, sizeof(b), "%s | %s", al[0] ? al : stale ? "history" : ui_status_name(t->status), age);
    fit_text(b, sizeof(b), f9, TABLE_W - 16);   // the numbers all sit on line one
    text(f9, b, TABLE_X + 8, y + 36, sel ? WHITE : (al[0] ? BLACK : GREY));

    uint8_t dash = sel ? WHITE : GREY;
    if (!isnan(t->height)) { snprintf(b, sizeof(b), "%d", (int)t->height); text(f9, b, s_cols[0].x, y + 20, ink); }
    else text(f9, "--", s_cols[0].x, y + 20, dash);
    if (!isnan(t->speed)) { snprintf(b, sizeof(b), "%.0f", t->speed); text(f9, b, s_cols[1].x, y + 20, ink); }
    else text(f9, "--", s_cols[1].x, y + 20, dash);
    if (g_home_set && t->has_pos) {
      ui_fmt_range(b, sizeof(b), ui_dist_m(g_home_lat, g_home_lon, t->lat, t->lon));
      text(f9, b, s_cols[2].x, y + 20, ink);
      snprintf(b, sizeof(b), "%03d", (int)ui_bearing(g_home_lat, g_home_lon, t->lat, t->lon));
      text(f9, b, s_cols[3].x, y + 20, ink);
    } else {
      text(f9, "--", s_cols[2].x, y + 20, dash);
      text(f9, "--", s_cols[3].x, y + 20, dash);
    }
    if (t->auth_state) {
      // unknown key; the published test key (not an identity); pages still coming
      const char* a = t->auth_state == 3 ? "OK" : t->auth_state == 4 ? "BAD"
                    : t->auth_state == 2 ? "KEY?" : t->auth_state == 5 ? "TEST" : "...";
      if (!sel && t->auth_state == 4) {
        rect(s_cols[4].x - 4, y + 4, text_w(f9, a) + 8, 18, BLACK);
        text(f9, a, s_cols[4].x, y + 17, WHITE);
      } else {
        text(f9, a, s_cols[4].x, y + 20, ink);
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
  const char* status_badge = danger ? "ALERT" : stale ? "HISTORY" : "LIVE";
  text_r(f9, status_badge, cx + cw - 12, cy + 22, WHITE);

  // UAS ID / Call sign, then the literal reasons it is loud, if any
  int y = cy + 58;
  snprintf(b, sizeof(b), "%s", t->uas[0] ? t->uas : "NO ID");
  fit_text(b, sizeof(b), f12, cw - 24);
  text(f12, b, cx + 12, y, BLACK);
  drone_alert_words(b, sizeof(b), t);
  if (b[0]) { y += 20; fit_text(b, sizeof(b), f9, cw - 24); text(f9, b, cx + 12, y, BLACK); }

  // Subtitle: Manufacturer & Transport
  y += 24;
  char via[24]; carriers_text(via, sizeof(via), t->src_mask);
  snprintf(b, sizeof(b), "%s | %s", ui_uas_type_name(t->uas), via);
  fit_text(b, sizeof(b), f9, cw - 24);
  text(f9, b, cx + 12, y, GREY);

  // Divider
  y += 10;
  rect(cx + 12, y, cw - 24, 1, GREY);

  // Grid Row 1: Altitude & Speed
  y += 22;
  if (isnan(t->height)) snprintf(b, sizeof(b), "HEIGHT");
  else snprintf(b, sizeof(b), "HEIGHT %s", t->height_ref ? "AGL" : "ABOVE T/O");
  text(f9, b, cx + 12, y, GREY);
  text(f9, "SPEED", cx + 210, y, GREY);

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
  text(f9, b, cx + 210, y, BLACK);

  // Grid Row 2: Heading & range rate (is it coming this way?)
  y += 24;
  text(f9, "HEADING", cx + 12, y, GREY);
  text(f9, "RANGE RATE", cx + 210, y, GREY);

  y += 20;
  if (!isnan(t->heading)) {
    snprintf(b, sizeof(b), "%03d deg (%s)", (int)t->heading, cardinal(t->heading));
  } else {
    snprintf(b, sizeof(b), "--");
  }
  text(f9, b, cx + 12, y, BLACK);

  float rate;
  if (ui_range_rate((int)(t - g_tracks), t, s_now, &rate)) ui_rate_text(b, sizeof(b), rate);
  else snprintf(b, sizeof(b), "%s", g_home_set && t->has_pos ? "measuring" : "--");
  fit_text(b, sizeof(b), f9, cw - 222);
  text(f9, b, cx + 210, y, BLACK);

  // Divider
  y += 10;
  rect(cx + 12, y, cw - 24, 1, LIGHT);

  // Grid Row 3: Position / Coordinates
  y += 22;
  text(f9, "POSITION", cx + 12, y, GREY);
  y += 20;
  if (t->has_pos) {
    snprintf(b, sizeof(b), "%.6f, %.6f", t->lat, t->lon);
    text(f9, b, cx + 12, y, BLACK);
  } else {
    text(f9, "not reported", cx + 12, y, GREY);
  }

  // Divider
  y += 10;
  rect(cx + 12, y, cw - 24, 1, LIGHT);

  // Grid Row 4: Signal & Peak RSSI
  y += 22;
  text(f9, "SIGNAL", cx + 12, y, GREY);
  snprintf(b, sizeof(b), "%d dBm (peak %d)", t->rssi, t->peak_rssi);
  text_r(f9, b, cx + cw - 12, y, BLACK);

  y += 8;
  int bar_w = cw - 24;
  box(cx + 12, y, bar_w, 10, BLACK);
  int fill = (int)(bar_w * ui_rssi01(t->rssi));
  if (fill > 0) rect(cx + 12, y, fill, 10, stale ? GREY : BLACK);

  // Grid Row 5: Authentication & Seen History
  y += 26;
  snprintf(b, sizeof(b), "%s", sig_words(t->auth_state));
  text(f9, b, cx + 12, y, t->auth_state == 4 ? BLACK : GREY);

  char age[16]; age_text(age, sizeof(age), since_s(t->last_ms));
  snprintf(b, sizeof(b), "Heard %s", age);
  text_r(f9, b, cx + cw - 12, y, BLACK);

  // Airspace, qualified by what TFR data the host has actually pushed
  y += 20;
  ui_airspace_text(b, sizeof(b), t, s_now);
  fit_text(b, sizeof(b), f9, cw - 24);
  text(f9, b, cx + 12, y, t->in_tfr ? BLACK : GREY);

  // Footer tap banner
  rect(cx + 1, cy + ch - 24, cw - 2, 23, LIGHT);
  int tw_tap = text_w(f9, "TAP FOR DETAILS");
  text(f9, "TAP FOR DETAILS", cx + (cw - tw_tap) / 2, cy + ch - 8, BLACK);
}

// ---- aircraft marks (ADS-B). Outlined diamonds, never filled, drawn under
// the drones' filled dots and squares, so the two can never be confused in
// grey or in a hurry. A warning or caution doubles the outline; a time ghost
// (a dot every 15 s along the next minute of the reported track) shows where
// each is heading without anything having to move on e-paper.
struct Clip { int x0, y0, x1, y1; };
static bool in_clip(const Clip& c, int x, int y, int m) {
  return x - m >= c.x0 && x + m < c.x1 && y - m >= c.y0 && y + m < c.y1;
}
#define AC_R 8   // diamond half-diagonal; the doubled outline reaches AC_R + 5
static void diamond(int x, int y, int r, uint8_t ink) {
  for (int d = -r; d <= r; d++) {
    int w = r - abs(d);
    if (w >= 2) rect(x - w + 2, y + d, 2 * w - 3, 1, WHITE);   // knock out what lies beneath
    epd_draw_pixel(x - w, y + d, ink, s_fb);
    epd_draw_pixel(x + w, y + d, ink, s_fb);
    if (w >= 1) { epd_draw_pixel(x - w + 1, y + d, ink, s_fb); epd_draw_pixel(x + w - 1, y + d, ink, s_fb); }
  }
}
/// The mark at (x,y) with its ghost dots (gx/gy, ng of them) and, when
/// `track` is known, a heading tick. The caller has clipped every point.
/// An aircraft reported on the ground is a small plain diamond: no ghost,
/// no tick, never doubled -- it is not airborne traffic.
static void aircraft_mark(int x, int y, const int* gx, const int* gy, int ng, double track,
                          uint8_t lvl, bool old, bool ground = false) {
  uint8_t ink = old ? GREY : BLACK;
  if (ground) { diamond(x, y, AC_R - 3, ink); return; }
  for (int i = 0; i < ng; i++) epd_fill_circle(gx[i], gy[i], 2, ink, s_fb);
  if (isfinite(track)) {
    double tr = track * M_PI / 180;
    int r0 = lvl >= TRAFFIC_CAUTION ? AC_R + 5 : AC_R;
    epd_draw_line(x + iround(sin(tr) * r0), y - iround(cos(tr) * r0),
                  x + iround(sin(tr) * (r0 + 10)), y - iround(cos(tr) * (r0 + 10)), ink, s_fb);
  }
  if (lvl >= TRAFFIC_CAUTION) { diamond(x, y, AC_R + 5, ink); }
  diamond(x, y, AC_R, ink);
}
/// The line from an alert's drone (or the board) to its aircraft: dashed,
/// so it reads as a relation, not a track; only its points inside `c`.
static void bridge(int x0, int y0, int x1, int y1, const Clip& c) {
  int n = max(abs(x1 - x0), abs(y1 - y0));
  for (int i = 0; i <= n; i++) {
    if ((i % 10) >= 6) continue;
    int x = x0 + (n ? (x1 - x0) * i / n : 0), y = y0 + (n ? (y1 - y0) * i / n : 0);
    if (x < c.x0 || x >= c.x1 || y < c.y0 || y >= c.y1) continue;
    rect(x, y, 2, 2, BLACK);
  }
}
/// An aircraft's label beside its mark, where one fits: "UAL123 2.6k ft".
/// Inverted for a warning; grey when the position is older than 30 s.
static void aircraft_label(const TrafficAircraft* a, uint8_t lvl, int x, int y, const Clip& c) {
  char name[12], alt[16], b[32];
  traffic_ac_name(a, name, sizeof(name));
  ac_alt_short(a, alt, sizeof(alt));
  snprintf(b, sizeof(b), "%s%s%s", name, alt[0] ? " " : "", alt);
  int w = text_w(&FreeSansBold9pt7b, b) + 6, lx, ly;
  if (!lb_place(x, y, w, 16, c.x0, c.y0, c.x1, c.y1, &lx, &ly, AC_R + 6)) return;
  bool loud = lvl == TRAFFIC_WARNING;
  rect(lx, ly, w, 16, loud ? BLACK : WHITE);
  text(&FreeSansBold9pt7b, b, lx + 3, ly + 12, loud ? WHITE : (ac_old(a) ? GREY : BLACK));
}
/// Aircraft that set a view's range: those in a pair alert (and LOW ones,
/// when `low`), and the one chosen.
static bool ac_in_scale(const TrafficAircraft* a, bool = true) {
  return traffic_alert_for_hex(&g_traffic_result, a->hex) != nullptr;
}
/// Aircraft are drawn only while they are in an alert (a conflict with a
/// drone, or low traffic in the drones' airspace): the board is Remote ID
/// first, and ADS-B is there for conflicts only.
static bool ac_drawn(const TrafficAircraft* a) { return ac_in_scale(a); }
/// True when a w x h box would sit on a label or control already placed.
static bool lb_hits(int x, int y, int w, int h) {
  for (int i = 0; i < s_nlb; i++) {
    const LabelBox& o = s_lb[i];
    if (x < o.x + o.w && o.x < x + w && y < o.y + o.h && o.y < y + h) return true;
  }
  return false;
}

// Where the last plot put each mark, for the hit test (no second copy of
// the scale arithmetic that could disagree with what was drawn).
static int  s_plot_px[TRK_MAX], s_plot_py[TRK_MAX];
static bool s_plot_on[TRK_MAX];
static int  s_pac_n = 0, s_pac_x[TRAFFIC_MAX_AIRCRAFT], s_pac_y[TRAFFIC_MAX_AIRCRAFT];
static char s_pac_hex[TRAFFIC_MAX_AIRCRAFT][7];

static void draw_plot() {
  rect(RECT_PLOT.x, RECT_PLOT.y, RECT_PLOT.width, RECT_PLOT.height, WHITE);
  memset(s_plot_on, 0, sizeof(s_plot_on));
  s_pac_n = 0;
  if (g_home_set) {
    double far = 0;
    for (int k = 0; k < s_n; k++) {
      const Track* t = &g_tracks[s_order[k]];
      if (t->has_pos) { double d = ui_dist_m(g_home_lat, g_home_lon, t->lat, t->lon); if (d > far) far = d; }
    }
    for (int i = 0; i < g_traffic_count; i++) {
      const TrafficAircraft* a = &g_traffic_ac[i];
      if (!ac_in_scale(a)) continue;
      double d = traffic_distance_m(g_home_lat, g_home_lon, a->lat, a->lon);
      if (isfinite(d) && d > far) far = d;
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

    // Compass and ring text are furniture: no mark or label may cover them.
    lb_reset();
    lb_block(PLOT_CX - 10, PLOT_CY - PLOT_R - 22, 20, 18); lb_block(PLOT_CX - 10, PLOT_CY + PLOT_R + 2, 20, 18);
    lb_block(PLOT_CX - PLOT_R - 22, PLOT_CY - 10, 22, 18); lb_block(PLOT_CX + PLOT_R + 4, PLOT_CY - 10, 20, 18);
    for (int i = 1; i <= 3; i++) lb_block(PLOT_CX + 4, PLOT_CY + (PLOT_R * i / 3) - 16, 64, 18);
    // Aircraft first, so every drone mark sits on top of them.
    const Clip clip = { RECT_PLOT.x + 2, RECT_PLOT.y + 2, W - 8, RECT_PLOT.y + RECT_PLOT.height - 2 };
    auto P = [&](double dx, double dy, int* x, int* y) {
      *x = PLOT_CX + (int)iround(dx / scale * PLOT_R);
      *y = PLOT_CY - (int)iround(dy / scale * PLOT_R);
    };
    uint8_t ac_lvl[TRAFFIC_MAX_AIRCRAFT]; int ac_i[TRAFFIC_MAX_AIRCRAFT];
    for (int i = 0; i < g_traffic_count && s_pac_n < TRAFFIC_MAX_AIRCRAFT; i++) {
      const TrafficAircraft* a = &g_traffic_ac[i];
      if (!ac_drawn(a)) continue;   // aircraft appear only in an alert
      double dx, dy;
      traffic_offset_m(g_home_lat, g_home_lon, a->lat, a->lon, &dx, &dy);
      if (!isfinite(dx) || !isfinite(dy) || hypot(dx, dy) > scale * 1.08) continue;   // off the rings
      int x, y; P(dx, dy, &x, &y);
      if (!in_clip(clip, x, y, AC_R + 6)) continue;
      int gx[4], gy[4], ng = 0;
      if (!a->on_ground && isfinite(a->gs_mps) && isfinite(a->track_deg)) {
        double vx = a->gs_mps * sin(a->track_deg * TRAFFIC_DEG), vy = a->gs_mps * cos(a->track_deg * TRAFFIC_DEG);
        for (int s = 1; s <= 4; s++) {
          int qx, qy; P(dx + vx * 15 * s, dy + vy * 15 * s, &qx, &qy);
          if (in_clip(clip, qx, qy, 3) && !lb_hits(qx - 3, qy - 3, 7, 7)) { gx[ng] = qx; gy[ng] = qy; ng++; }
        }
      }
      const TrafficAlert* al = traffic_alert_for_hex(&g_traffic_result, a->hex);
      uint8_t lvl = al ? al->level : (uint8_t)TRAFFIC_NONE;
      double alat, alon;
      if (al && alert_anchor(al, &alat, &alon)) {   // the bridge to its drone (or to the board)
        double ax, ay; int bx, by;
        traffic_offset_m(g_home_lat, g_home_lon, alat, alon, &ax, &ay);
        P(ax, ay, &bx, &by);
        bridge(bx, by, x, y, clip);
      }
      aircraft_mark(x, y, gx, gy, ng, a->track_deg, lvl, ac_old(a), a->on_ground);
      s_pac_x[s_pac_n] = x; s_pac_y[s_pac_n] = y;
      snprintf(s_pac_hex[s_pac_n], sizeof(s_pac_hex[0]), "%s", a->hex);
      ac_lvl[s_pac_n] = lvl; ac_i[s_pac_n] = i;
      s_pac_n++;
    }

    // Drone markers in reverse priority so the selected aircraft ends on
    // top; then labels in priority order, each only where one fits.
    int rows[TRK_MAX]; int nr = priority_rows(rows);
    int* px = s_plot_px; int* py = s_plot_py; bool* on = s_plot_on;
    for (int k = 0; k < s_n; k++) {
      const Track* t = &g_tracks[s_order[k]];
      on[k] = t->has_pos;
      if (!on[k]) continue;
      double d = ui_dist_m(g_home_lat, g_home_lon, t->lat, t->lon);
      double br = ui_bearing(g_home_lat, g_home_lon, t->lat, t->lon) * M_PI / 180;
      px[k] = PLOT_CX + (int)(sin(br) * d / scale * PLOT_R);
      py[k] = PLOT_CY - (int)(cos(br) * d / scale * PLOT_R);
    }
    for (int i = nr - 1; i >= 0; i--) {
      int k = rows[i];
      if (!on[k]) continue;
      const Track* t = &g_tracks[s_order[k]];
      bool stale = ui_stale(t, s_now), danger = ui_danger(t, s_now) || alert_for_drone(t);
      if (danger) epd_draw_circle(px[k], py[k], 12, BLACK, s_fb);
      epd_fill_circle(px[k], py[k], k == s_sel ? 8 : 6, stale ? GREY : BLACK, s_fb);
      if (!isnan(t->heading)) {
        double hr = t->heading * M_PI / 180;
        epd_draw_line(px[k], py[k], px[k] + (int)(sin(hr) * 18), py[k] - (int)(cos(hr) * 18), BLACK, s_fb);
      }
    }
    // Labels: the selected aircraft and alerts get theirs first (they may
    // cover a lesser marker), then markers become obstacles for everyone
    // else; aircraft labels last, warnings first.
    for (int pass = 0; pass < 2; pass++) {
      if (pass == 1) {
        for (int k = 0; k < s_n; k++) if (on[k]) lb_block(px[k] - 12, py[k] - 12, 24, 24);
        for (int j = 0; j < s_pac_n; j++) lb_block(s_pac_x[j] - AC_R - 1, s_pac_y[j] - AC_R - 1, 2 * AC_R + 3, 2 * AC_R + 3);
      }
      for (int i = 0; i < nr; i++) {
        int k = rows[i];
        if (!on[k]) continue;
        const Track* t = &g_tracks[s_order[k]];
        bool first = (k == s_sel) || ui_danger(t, s_now) || alert_for_drone(t);
        if (first != (pass == 0)) continue;
        bool stale = ui_stale(t, s_now);
        char b[24];
        if (!isnan(t->height)) snprintf(b, sizeof(b), "%s %dm", label_id(k), (int)t->height);
        else snprintf(b, sizeof(b), "%s", label_id(k));
        int box_w = text_w(&FreeSansBold9pt7b, b) + 6, lx, ly;
        if (!lb_place(px[k], py[k], box_w, 16, RECT_PLOT.x + 2, RECT_PLOT.y + 2,
                      W - 8, RECT_PLOT.y + RECT_PLOT.height - 2, &lx, &ly)) continue;
        rect(lx, ly, box_w, 16, WHITE);
        box(lx, ly, box_w, 16, stale ? GREY : BLACK);
        text(&FreeSansBold9pt7b, b, lx + 3, ly + 12, stale ? GREY : BLACK);
      }
    }
    for (int lv = TRAFFIC_WARNING; lv >= TRAFFIC_NONE; lv--)
      for (int j = 0; j < s_pac_n; j++)
        if (ac_lvl[j] == lv) aircraft_label(&g_traffic_ac[ac_i[j]], ac_lvl[j], s_pac_x[j], s_pac_y[j], clip);
  } else {
    // No operator fix: Display rich Selected Target Detail Card
    if (s_n > 0 && s_sel >= 0 && s_sel < s_n) {
      const Track* t = &g_tracks[s_order[s_sel]];
      draw_target_card(t, s_sel, s_n);
    } else {
      // No position, so no rings: say what would bring them.
      const char* l[3] = { "NO POSITION", "Range rings need a GPS fix",
                           s_n ? "or the Mac app. Tap a row for its card." : "or a position from the Mac app." };
      text(&FreeSansBold12pt7b, l[0], PLOT_CX - text_w(&FreeSansBold12pt7b, l[0]) / 2, 230, BLACK);
      for (int i = 1; i < 3; i++) {
        char c[64]; snprintf(c, sizeof(c), "%s", l[i]);
        fit_text(c, sizeof(c), &FreeSansBold9pt7b, RECT_PLOT.width - 24);
        text(&FreeSansBold9pt7b, c, PLOT_CX - text_w(&FreeSansBold9pt7b, c) / 2, 234 + 26 * i, GREY);
      }
    }
  }
}

// ---- offline map: tiles from the shared store, inverted into greys

// Dark basemaps re-toned as a printed street map (map_tone.h): a plain
// inversion put every feature at grey 11-15 and roads came out white on
// white. Esri World Dark Gray JPEG tiles (/tiles/z/x/y.jpg, the basemap now)
// decode straight to 8-bit grey; CARTO dark_all PNGs (older tiles) keep
// their own palette.
#define MAP_Y0   72
#define MAP_H    424   // ends at the footer rule; must match RECT_MAP
#define MAP_CX   (W / 2)
#define MAP_CY   (MAP_Y0 + MAP_H / 2)
#define TILE_ZMIN 12   // the tile syncs (Mac app, net_fetch.h) fetch z12-15: no empty z11
#define TILE_ZMAX 15
#define MAP_HUD_H 46             // selected-contact banner: tall enough for a finger
static int s_pan_bx = 20, s_pan_bw = 0;   // the MANUAL PAN button, for the hit-test
// The decoder carries ~45 KB of state. It lives in PSRAM: the Wi-Fi driver
// and the BT controller need every kilobyte of internal RAM, and with this
// in internal .bss the Wi-Fi driver failed to start ("Expected to init 4 rx
// buffer, actual is 3"), silently stopping Remote ID reception over Wi-Fi.
// Without PSRAM there is no decoder and the map draws without tiles, rather
// than taking the internal RAM back.
static PNG* png() {
  static PNG* p = nullptr;
  if (!p) {
#if defined(ESP_PLATFORM)
    void* m = heap_caps_malloc(sizeof(PNG), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (m) p = new (m) PNG();
#else
    p = new PNG();
#endif
  }
  return p;
}
static File s_pngFile;
static int  s_blit_x, s_blit_y;             // screen origin of the tile being decoded

// JPEG tiles: the decoder (~18 KB of state) and the tile's bytes (read whole,
// then decoded from RAM) also live in PSRAM; no PSRAM, no tiles.
#define TILE_JPG_MAX (64 * 1024)
static JPEGDEC* jpg() {
  static JPEGDEC* j = nullptr;
  if (!j) {
#if defined(ESP_PLATFORM)
    void* m = heap_caps_malloc(sizeof(JPEGDEC), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (m) j = new (m) JPEGDEC();
#else
    j = new JPEGDEC();
#endif
  }
  return j;
}
static uint8_t* jpg_buf() {
  static uint8_t* b = nullptr;
#if defined(ESP_PLATFORM)
  if (!b) b = (uint8_t*)heap_caps_malloc(TILE_JPG_MAX, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
#else
  if (!b) b = (uint8_t*)malloc(TILE_JPG_MAX);
#endif
  return b;
}

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
  double lats[TRK_MAX + 1 + 4], lons[TRK_MAX + 1 + 4]; int n = 0;
  if (g_home_set) { lats[n] = g_home_lat; lons[n] = g_home_lon; n++; }
  for (int k = 0; k < s_n; k++) {
    const Track* t = &g_tracks[s_order[k]];
    if (t->has_pos && !ui_stale(t, s_now)) { lats[n] = t->lat; lons[n] = t->lon; n++; }
  }
  // ...and the aircraft in a traffic alert with them (pairs, LOW), and the chosen one.
  for (int i = 0; i < g_traffic_count && n < TRK_MAX + 1 + 4; i++)
    if (ac_in_scale(&g_traffic_ac[i])) { lats[n] = g_traffic_ac[i].lat; lons[n] = g_traffic_ac[i].lon; n++; }
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
    // The bottom 90 px hold the HUD and the scale bar: frame above them.
    const int bottom = 90;
    bool fits = (x1 - x0) < W - 120 && (y1 - y0) < MAP_H - 60 - bottom;
    if ((fits && (n > 1 || z == 14)) || z == TILE_ZMIN) {
      s_cam_z = z; s_cam_wx = (x0 + x1) / 2; s_cam_wy = (y0 + y1) / 2 + bottom / 2; s_cam_valid = true;
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
  png()->getLineAsRGB565(d, line, PNG_RGB565_LITTLE_ENDIAN, 0xffffffff);

  // Direct 4-bit framebuffer span write — EPD_ROT_LANDSCAPE is the identity
  // transform, so user (x,y) maps straight to framebuffer (x,y).  The stride
  // is epd_width()/2 bytes per row.  Eliminates ~256 epd_draw_pixel() calls
  // (each doing _rotate + bounds check + read-modify-write) per PNG scanline.
  const int stride = epd_width() / 2;
  int x0 = s_blit_x;
  int x1 = s_blit_x + d->iWidth;
  if (x0 < 0) x0 = 0;
  if (x1 > W) x1 = W;
  uint8_t* row = s_fb + y * stride;
  for (int x = x0; x < x1; x++) {
    uint16_t c = line[x - s_blit_x];
    int r = (c >> 11) << 3, g = ((c >> 5) & 0x3F) << 2, b = (c & 0x1F) << 3;
    int luma = (r * 77 + g * 150 + b * 29) >> 8;
    int g4 = map_tone_carto(luma);
    uint8_t* bp = &row[x / 2];
    if (x & 1) *bp = (*bp & 0x0F) | (uint8_t)(g4 << 4);
    else       *bp = (*bp & 0xF0) | (uint8_t)(g4);
  }
  return 1;
}

// One block of 8-bit grey from JPEGDEC: re-tone it into the 4-bit framebuffer.
static int jpgDrawCb(JPEGDRAW* d) {
  const uint8_t* px = (const uint8_t*)d->pPixels;
  const int stride = epd_width() / 2;
  for (int r = 0; r < d->iHeight; r++) {
    int y = s_blit_y + d->y + r;
    if (y < MAP_Y0 || y >= MAP_Y0 + MAP_H) continue;
    uint8_t* row = s_fb + y * stride;
    const uint8_t* src = px + r * d->iWidth;
    int x0 = s_blit_x + d->x;
    for (int c = 0; c < d->iWidth; c++) {
      int x = x0 + c;
      if (x < 0 || x >= W) continue;
      int g4 = map_tone_esri(src[c]);
      uint8_t* bp = &row[x / 2];
      if (x & 1) *bp = (*bp & 0x0F) | (uint8_t)(g4 << 4);
      else       *bp = (*bp & 0xF0) | (uint8_t)(g4);
    }
  }
  return 1;
}

/// Draw /tiles/z/x/y.jpg at the blit origin; false when it is absent or not
/// a JPEG the decoder takes (the caller then tries the .png).
static bool draw_tile_jpg(const char* path) {
  File f = LittleFS.open(path, "r");
  if (!f) return false;
  size_t n = f.size();
  uint8_t* buf = jpg_buf();
  JPEGDEC* j = jpg();
  bool ok = false;
  if (buf && j && n >= 3 && n <= TILE_JPG_MAX && (size_t)f.read(buf, n) == n &&
      tile_sniff(buf, n) == TILE_FMT_JPEG && j->openRAM(buf, (int)n, jpgDrawCb)) {
    j->setPixelType(EIGHT_BIT_GRAYSCALE);   // after open: open clears the settings
    ok = j->getWidth() <= 256 && j->getHeight() <= 256 && j->decode(0, 0, 0) == 1;
    j->close();
  }
  f.close();
  return ok;
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
  int tiles_drawn = 0, tiles_jpg = 0;
  for (long ty = ty0; ty <= ty1; ty++) {
    for (long tx = tx0; tx <= tx1; tx++) {
      s_blit_x = (int)(tx * 256 - left);
      s_blit_y = MAP_Y0 + (int)(ty * 256 - top);
      if (tx >= 0 && ty >= 0 && tx <= tmax && ty <= tmax) {
        char path[48];
        snprintf(path, sizeof(path), "/tiles/%d/%ld/%ld.jpg", s_cam_z, tx, ty);
        if (draw_tile_jpg(path)) { tiles_drawn++; tiles_jpg++; continue; }
        snprintf(path, sizeof(path), "/tiles/%d/%ld/%ld.png", s_cam_z, tx, ty);
        PNG* dec = png();
        if (dec && dec->open(path, pngOpenCb, pngCloseCb, pngReadCb, pngSeekCb, pngDrawCb) == PNG_SUCCESS) {
          if (dec->getWidth() <= 256) {
            dec->decode(nullptr, 0);
            tiles_drawn++;
          }
          dec->close();
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
    rect(20, MAP_Y0 + 8, 130, 28, WHITE);
    box(20, MAP_Y0 + 8, 130, 28, BLACK);
    box(21, MAP_Y0 + 9, 128, 26, BLACK);
    text(&FreeSansBold9pt7b, "NO TILES", 30, MAP_Y0 + 26, BLACK);

    if (!s_n && !g_home_set) {
      rect(cx - 160, cy - 28, 320, 56, WHITE);
      box(cx - 160, cy - 28, 320, 56, BLACK);
      const char* t1 = "NO MAP TILES";
      const char* t2 = "Sync them from the Mac app.";
      text(&FreeSansBold12pt7b, t1, cx - text_w(&FreeSansBold12pt7b, t1) / 2, cy - 4, BLACK);
      text(&FreeSansBold9pt7b, t2, cx - text_w(&FreeSansBold9pt7b, t2) / 2, cy + 18, GREY);
    }
  } else {
    // Raster tiles present
    rect(20, MAP_Y0 + 8, 130, 28, WHITE);
    box(20, MAP_Y0 + 8, 130, 28, BLACK);
    box(21, MAP_Y0 + 9, 128, 26, BLACK);
    char b[32]; snprintf(b, sizeof(b), "ZOOM %d", s_cam_z);
    text(&FreeSansBold9pt7b, b, 30, MAP_Y0 + 26, BLACK);
  }

  // overlay: home, contacts, scale, north
  int home_x = -1, home_y = -1;
  if (g_home_set) {
    double wx, wy; world_px(g_home_lat, g_home_lon, s_cam_z, &wx, &wy);
    int x = (int)(wx - left), y = MAP_Y0 + (int)(wy - top);
    if (x >= 0 && x < W && y >= MAP_Y0 && y < MAP_Y0 + MAP_H) {
      epd_fill_circle(x, y, 5, BLACK, s_fb);
      epd_draw_circle(x, y, 10, BLACK, s_fb);
      rect(x + 12, y - 12, 48, 16, WHITE);
      text(&FreeSansBold9pt7b, "HOME", x + 14, y, BLACK);
      home_x = x; home_y = y;
    }
  }

  char b[32];
  // Markers in reverse priority so the selected aircraft ends on top, then
  // labels in priority order, each only where one fits clear of markers,
  // other labels and the map furniture.
  int rows[TRK_MAX]; int nr = priority_rows(rows);
  int px[TRK_MAX], py[TRK_MAX]; bool on[TRK_MAX];
  for (int k = 0; k < s_n; k++) {
    const Track* t = &g_tracks[s_order[k]];
    on[k] = false;
    if (!t->has_pos) continue;
    double wx, wy; world_px(t->lat, t->lon, s_cam_z, &wx, &wy);
    px[k] = (int)(wx - left); py[k] = MAP_Y0 + (int)(wy - top);
    on[k] = px[k] >= 0 && px[k] < W && py[k] >= MAP_Y0 && py[k] < MAP_Y0 + MAP_H;
  }
  lb_reset();
  static const char* PAN_LABEL = "MANUAL VIEW | TAP TO FIT ALL";
  int pan_reserve = max(240, text_w(&FreeSansBold9pt7b, PAN_LABEL) + 24);
  lb_block(20, MAP_Y0 + 8, s_cam_manual ? pan_reserve : 240, s_cam_manual ? 62 : 28);   // zoom badge (+ manual-view button)
  lb_block(20, MAP_Y0 + MAP_H - 32, 160, 26);            // scale bar
  // The basemap's attribution, bottom right (its terms ask for it on screen).
  const char* attrib = tiles_jpg ? TILE_ATTRIBUTION : (tiles_drawn ? "(c) OpenStreetMap contributors, (c) CARTO" : nullptr);
  int attrib_w = attrib ? text_w(&FreeSansBold9pt7b, attrib) : 0;
  if (attrib) lb_block(W - 16 - attrib_w, MAP_Y0 + MAP_H - 26, attrib_w + 12, 22);
  lb_block(W - 60, MAP_Y0, 60, 240);                     // compass, zoom, follow
  if (home_x >= 0) lb_block(home_x - 12, home_y - 14, 74, 28);   // the HOME marker and its label
  bool ac_hud = ac_index(s_ac_hex) >= 0 && traffic_alert_for_hex(&g_traffic_result, s_ac_hex);
  if (ac_hud || (s_n > 0 && s_sel >= 0 && s_sel < s_n)) lb_block(20, MAP_Y0 + MAP_H - MAP_HUD_H - 40, W - 40, MAP_HUD_H);

  // Aircraft (ADS-B) under the drones: diamonds with their time ghosts.
  const Clip mclip = { 8, MAP_Y0 + 4, W - 62, MAP_Y0 + MAP_H - 4 };
  uint8_t mac_lvl[TRAFFIC_MAX_AIRCRAFT]; int mac_i[TRAFFIC_MAX_AIRCRAFT];
  s_pac_n = 0;
  for (int i = 0; i < g_traffic_count && s_pac_n < TRAFFIC_MAX_AIRCRAFT; i++) {
    const TrafficAircraft* a = &g_traffic_ac[i];
    if (!ac_drawn(a)) continue;   // aircraft appear only in an alert
    double wx, wy; world_px(a->lat, a->lon, s_cam_z, &wx, &wy);
    if (!isfinite(wx) || !isfinite(wy)) continue;
    int x = (int)iround(wx - left), y = MAP_Y0 + (int)iround(wy - top);
    if (!in_clip(mclip, x, y, AC_R + 6)) continue;
    int gx[4], gy[4], ng = 0;
    if (!a->on_ground && isfinite(a->gs_mps) && isfinite(a->track_deg)) {
      double mpp = 156543.03 * cos(a->lat * M_PI / 180) / (double)(1L << s_cam_z);
      double vx = a->gs_mps * sin(a->track_deg * TRAFFIC_DEG), vy = a->gs_mps * cos(a->track_deg * TRAFFIC_DEG);
      for (int st = 1; st <= 4; st++) {
        int qx = x + (int)iround(vx * 15 * st / mpp), qy = y - (int)iround(vy * 15 * st / mpp);
        if (in_clip(mclip, qx, qy, 3) && !lb_hits(qx - 3, qy - 3, 7, 7)) { gx[ng] = qx; gy[ng] = qy; ng++; }
      }
    }
    const TrafficAlert* al = traffic_alert_for_hex(&g_traffic_result, a->hex);
    uint8_t lvl = al ? al->level : (uint8_t)TRAFFIC_NONE;
    double alat, alon;
    if (al && alert_anchor(al, &alat, &alon)) {   // the bridge to its drone (or to the board)
      double awx, awy; world_px(alat, alon, s_cam_z, &awx, &awy);
      bridge((int)iround(awx - left), MAP_Y0 + (int)iround(awy - top), x, y, mclip);
    }
    aircraft_mark(x, y, gx, gy, ng, a->track_deg, lvl, ac_old(a), a->on_ground);
    if (ac_hud && !strcmp(a->hex, s_ac_hex)) epd_draw_circle(x, y, AC_R + 9, BLACK, s_fb);
    s_pac_x[s_pac_n] = x; s_pac_y[s_pac_n] = y;
    snprintf(s_pac_hex[s_pac_n], sizeof(s_pac_hex[0]), "%s", a->hex);
    mac_lvl[s_pac_n] = lvl; mac_i[s_pac_n] = i;
    s_pac_n++;
  }

  for (int i = nr - 1; i >= 0; i--) {
    int k = rows[i];
    if (!on[k]) continue;
    const Track* t = &g_tracks[s_order[k]];
    bool stale = ui_stale(t, s_now), danger = ui_danger(t, s_now) || alert_for_drone(t);
    epd_fill_circle(px[k], py[k], danger ? 15 : 11, WHITE, s_fb);
    if (danger) epd_draw_circle(px[k], py[k], 13, BLACK, s_fb);
    epd_fill_circle(px[k], py[k], k == s_sel ? 8 : 6, stale ? GREY : BLACK, s_fb);
    if (!isnan(t->heading)) {
      double hr = t->heading * M_PI / 180;
      epd_draw_line(px[k], py[k], px[k] + (int)(sin(hr) * 20), py[k] - (int)(cos(hr) * 20), BLACK, s_fb);
    }
  }
  // The selected aircraft and alerts label first (they may cover a lesser
  // marker); then markers become obstacles for everyone else.
  for (int pass = 0; pass < 2; pass++) {
    if (pass == 1) {
      for (int k = 0; k < s_n; k++) if (on[k]) lb_block(px[k] - 16, py[k] - 16, 32, 32);
      for (int j = 0; j < s_pac_n; j++) lb_block(s_pac_x[j] - AC_R - 1, s_pac_y[j] - AC_R - 1, 2 * AC_R + 3, 2 * AC_R + 3);
    }
    for (int i = 0; i < nr; i++) {
      int k = rows[i];
      if (!on[k]) continue;
      const Track* t = &g_tracks[s_order[k]];
      bool first = (k == s_sel) || ui_danger(t, s_now) || alert_for_drone(t);
      if (first != (pass == 0)) continue;
      bool stale = ui_stale(t, s_now);
      if (!isnan(t->height)) snprintf(b, sizeof(b), "%s %dm", label_id(k), (int)t->height);
      else snprintf(b, sizeof(b), "%s", label_id(k));
      int box_w = text_w(&FreeSansBold9pt7b, b) + 8, lx, ly;
      if (!lb_place(px[k], py[k], box_w, 18, 8, MAP_Y0 + 4, W - 62, MAP_Y0 + MAP_H - 4, &lx, &ly)) continue;
      rect(lx, ly, box_w, 18, WHITE);
      box(lx, ly, box_w, 18, stale ? GREY : BLACK);
      text(&FreeSansBold9pt7b, b, lx + 4, ly + 14, stale ? GREY : BLACK);
    }
  }
  for (int lv = TRAFFIC_WARNING; lv >= TRAFFIC_NONE; lv--)
    for (int j = 0; j < s_pac_n; j++)
      if (mac_lvl[j] == lv) aircraft_label(&g_traffic_ac[mac_i[j]], mac_lvl[j], s_pac_x[j], s_pac_y[j], mclip);

  // scale bar: 100 px in metres at this zoom and latitude
  double clat, clon; px_world(s_cam_wx, s_cam_wy, s_cam_z, &clat, &clon);
  double m_per_px = 156543.03 * cos(clat * M_PI / 180) / (double)(1L << s_cam_z);
  double bar_m = m_per_px * 100;
  dist_text(b, sizeof(b), bar_m);
  rect(20, MAP_Y0 + MAP_H - 32, 160, 26, WHITE);
  box(20, MAP_Y0 + MAP_H - 32, 160, 26, BLACK);
  box(21, MAP_Y0 + MAP_H - 31, 158, 24, BLACK);
  rect(28, MAP_Y0 + MAP_H - 16, 80, 4, BLACK);
  text(&FreeSansBold9pt7b, b, 114, MAP_Y0 + MAP_H - 14, BLACK);
  if (attrib) {
    rect(W - 16 - attrib_w, MAP_Y0 + MAP_H - 26, attrib_w + 12, 22, WHITE);
    text(&FreeSansBold9pt7b, attrib, W - 10 - attrib_w, MAP_Y0 + MAP_H - 10, GREY);
  }

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

  // Mode feedback that is also the way out: a button, not a badge.
  if (s_cam_manual) {
    const char* lbl = PAN_LABEL;   // back to framing you and every live contact
    s_pan_bw = text_w(&FreeSansBold9pt7b, lbl) + 24;
    s_pan_bx = 20;                                     // under the zoom badge
    int py = MAP_Y0 + 42, ph = 28;
    rect(s_pan_bx, py, s_pan_bw, ph, WHITE);
    box(s_pan_bx, py, s_pan_bw, ph, BLACK);
    box(s_pan_bx + 1, py + 1, s_pan_bw - 2, ph - 2, BLACK);
    text(&FreeSansBold9pt7b, lbl, s_pan_bx + 12, py + 19, BLACK);
  } else {
    s_pan_bw = 0;
  }

  // Tactical HUD banner when a drone or an aircraft is selected
  if (ac_hud || (s_n > 0 && s_sel >= 0 && s_sel < s_n)) {
    const int hud_h = MAP_HUD_H;
    const int hud_y = MAP_Y0 + MAP_H - hud_h - 40;
    rect(20, hud_y, W - 40, hud_h, WHITE);
    box(20, hud_y, W - 40, hud_h, BLACK);
    box(21, hud_y + 1, W - 42, hud_h - 2, BLACK);

    char hud_str[160];
    if (ac_hud) {
      // The alert: its action first, then the geometry, the aircraft, the age.
      const TrafficAircraft* a = &g_traffic_ac[ac_index(s_ac_hex)];
      const TrafficAlert* al = traffic_alert_for_hex(&g_traffic_result, a->hex);
      char name[12], age[24];
      traffic_ac_name(a, name, sizeof(name));
      traffic_age_words(traffic_age_s(a->seen_ms, s_now), age, sizeof(age));
      traffic_textf(hud_str, sizeof(hud_str), "%s | %s | %s | %s", al->action, alert_geometry(al), name, age);
    } else {
      const Track* sel_t = &g_tracks[s_order[s_sel]];
      char hb[16] = "--", sb[16] = "--", rb[16] = "--";
      if (!isnan(sel_t->height)) snprintf(hb, sizeof(hb), "%d m", (int)sel_t->height);
      if (!isnan(sel_t->speed)) snprintf(sb, sizeof(sb), "%.0f m/s", sel_t->speed);
      if (g_home_set && sel_t->has_pos) {
        dist_text(rb, sizeof(rb), ui_dist_m(g_home_lat, g_home_lon, sel_t->lat, sel_t->lon));
      }
      char al[72];
      drone_alert_words(al, sizeof(al), sel_t);
      snprintf(hud_str, sizeof(hud_str), "%s | %s | HGT %s | SPD %s | RNG %s",
               sel_t->uas[0] ? sel_t->uas : "NO ID",
               al[0] ? al : ui_status_name(sel_t->status), hb, sb, rb);
    }
    // [ DETAILS ] and [ X ] buttons, finger-sized; the text stops short of them
    int d_w = 100, d_h = 36;
    int d_x = W - 170, d_y = hud_y + 5;
    fit_text(hud_str, sizeof(hud_str), &FreeSansBold9pt7b, d_x - 12 - 32);
    text(&FreeSansBold9pt7b, hud_str, 32, hud_y + 29, BLACK);
    rect(d_x, d_y, d_w, d_h, BLACK);
    text(&FreeSansBold9pt7b, "DETAILS", d_x + (d_w - text_w(&FreeSansBold9pt7b, "DETAILS")) / 2, d_y + 24, WHITE);
    int x_w = 36, x_h = 36;
    int x_x = W - 62, x_y = hud_y + 5;
    box(x_x, x_y, x_w, x_h, BLACK);
    box(x_x + 1, x_y + 1, x_w - 2, x_h - 2, BLACK);
    text(&FreeSansBold9pt7b, "X", x_x + (x_w - text_w(&FreeSansBold9pt7b, "X")) / 2, x_y + 24, BLACK);
  }

  UiSummary sm; ui_summarize(&sm, s_now);
  draw_header(sm, nullptr);
  draw_footer(sm, !s_map_touched ? "tap marker: select | tap map: recentre | drag: pan" : "BOOT: table | hold BOOT: power off");
}

// A refresh epdiy could not feed in time ("line buffer underrun") leaves
// the glass incomplete while its back buffer says it is done, so later
// difference updates would never repair it: the next pass repaints the
// whole panel from white (epd_repaint_all) -- at most once every 30 s, so a
// board whose refreshes keep underrunning does not repaint in a loop (each
// repair is itself a full refresh that can underrun).
#define EPD_REDO_MIN_MS 30000UL
static bool     s_epd_redo = false;
static uint32_t s_epd_redo_ms = 0;
static bool     s_epd_redo_once = false;   // a repair has run: the gap applies
static void refresh_checked(EpdRect area, enum EpdDrawMode mode) {
  epd_ensure_on();  // PMIC rail hold: skip poweron if already energized
  enum EpdDrawError e = epd_hl_update_area(&s_hl, mode, TEMP_C, area);
  if (e & EPD_DRAW_EMPTY_LINE_QUEUE) s_epd_redo = true;
  // Taps released while the panel was busy are dropped, never queued.
  s_touch_ignore_ms = millis();
}
static void epd_repaint_all() {
  epd_ensure_on();
  epd_clear();                                  // every pixel to white, whatever it held
  memset(s_hl.back_fb, 0xFF, (size_t)W * H / 2); // and the back buffer says so
  refresh_checked(epd_full_screen(), MODE_GC16);
  s_partials = 0;
  s_last_full = s_now;
}

static void refresh_area(EpdRect area, bool force_full, bool fast_mode = false) {
  // E-Paper Best Practice: Full DC-balanced GC16 refresh on view changes,
  // alert state transitions, or periodically every 10 partial cycles / 3 minutes
  // to eliminate residual charge and ghosting.
  bool full = force_full || (s_partials >= 10 || (s_now - s_last_full > 180000UL));
  if (full) {
    refresh_checked(epd_full_screen(), MODE_GC16);
    s_partials = 0;
    s_last_full = s_now;
  } else {
    enum EpdDrawMode mode = fast_mode ? MODE_DU : MODE_GL16;
    refresh_checked(area, mode);
    s_partials++;
  }
  // No epd_poweroff() here — rails stay hot during interaction;
  // epd_idle_check() in ui_tick() handles the 3-second idle timeout.
}

static void refresh(bool force_full) {
  refresh_area(epd_full_screen(), force_full, false);
}

/// One inspector line, fitted to its column so it can never cross into the
/// other one.
static void ins_line(int x, int* y, const char* s, uint8_t ink = BLACK) {
  char c[96]; snprintf(c, sizeof(c), "%s", s);
  fit_text(c, sizeof(c), &FreeSansBold9pt7b, 300);
  text(&FreeSansBold9pt7b, c, x, *y, ink);
  *y += 20;
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

  // Header banner: a title that stops short of the close button
  rect(mx + 3, my + 3, mw - 6, 42, BLACK);
  int close_w = 40, close_h = 34;
  int close_x = mx + mw - close_w - 6, close_y = my + 7;
  char b[96];
  snprintf(b, sizeof(b), "DRONE %s", t->uas[0] ? t->uas : "NO ID");   // "aircraft" means ADS-B traffic now
  fit_text(b, sizeof(b), f12, close_x - 12 - (mx + 16));
  text(f12, b, mx + 16, my + 28, WHITE);
  rect(close_x, close_y, close_w, close_h, WHITE);
  box(close_x, close_y, close_w, close_h, BLACK);
  text(f12, "X", close_x + (close_w - text_w(f12, "X")) / 2, close_y + 24, BLACK);

  int col1 = mx + 24;
  int col2 = mx + 350;
  int y = my + 68;

  // Section 1: IDENTITY & SIGNAL (Left column)
  text(f9, "IDENTITY & SIGNAL", col1, y, BLACK);
  rect(col1, y + 4, 300, 1, BLACK);
  y += 24;
  char al[72]; drone_alert_words(al, sizeof(al), t);
  if (al[0]) { snprintf(b, sizeof(b), "Alert: %s", al); ins_line(col1, &y, b); }
  snprintf(b, sizeof(b), "UAS ID: %s", t->uas[0] ? t->uas : "not reported");
  ins_line(col1, &y, b);
  snprintf(b, sizeof(b), "%s: %s", uas_model_name(t->uas) ? "Type" : "Make", ui_uas_type_name(t->uas));
  ins_line(col1, &y, b);
  if (t->ssid[0]) {
    snprintf(b, sizeof(b), "SSID: %s", t->ssid);
    ins_line(col1, &y, b, GREY);
    if (t->ssid_check == 2) ins_line(col1, &y, "SSID names a different serial", BLACK);
  }
  snprintf(b, sizeof(b), "MAC: %02X:%02X:%02X:%02X:%02X:%02X", t->mac[0], t->mac[1], t->mac[2], t->mac[3], t->mac[4], t->mac[5]);
  if (t->alt_mac_count) {
    char more[24]; snprintf(more, sizeof(more), "  (+%u more)", (unsigned)t->alt_mac_count);
    strncat(b, more, sizeof(b) - strlen(b) - 1);
  }
  ins_line(col1, &y, b);
  char via[24]; carriers_text(via, sizeof(via), t->src_mask);
  snprintf(b, sizeof(b), "Via: %s", via);
  if (t->fmt & 2) strncat(b, " (GB 46750)", sizeof(b) - strlen(b) - 1);
  ins_line(col1, &y, b);
  snprintf(b, sizeof(b), "Signal: %d dBm (peak %d)", t->rssi, t->peak_rssi);
  ins_line(col1, &y, b);
  char age[16]; age_text(age, sizeof(age), since_s(t->last_ms));
  uint32_t dur_s = since_s(t->first_ms);
  snprintf(b, sizeof(b), "Heard %s | %u msgs in %lu:%02lu", age, t->msgs,
           (unsigned long)(dur_s / 60), (unsigned long)(dur_s % 60));
  ins_line(col1, &y, b);
  snprintf(b, sizeof(b), "%s", sig_words(t->auth_state));
  ins_line(col1, &y, b, (t->auth_state == 4) ? BLACK : GREY);

  // Section 2: FLIGHT (Right column)
  int y2 = my + 68;
  text(f9, "FLIGHT", col2, y2, BLACK);
  rect(col2, y2 + 4, 300, 1, BLACK);
  y2 += 24;
  if (t->has_pos) snprintf(b, sizeof(b), "Position: %.6f, %.6f", t->lat, t->lon);
  else snprintf(b, sizeof(b), "Position: not reported");
  ins_line(col2, &y2, b);
  char mb[16] = "--";
  if (!isnan(t->max_height)) snprintf(mb, sizeof(mb), "%d m", (int)t->max_height);
  if (isnan(t->height)) snprintf(b, sizeof(b), "Height: --");
  else snprintf(b, sizeof(b), "Height %s: %d m", ui_height_ref(t->height_ref), (int)t->height);
  ins_line(col2, &y2, b);
  snprintf(b, sizeof(b), "Peak height: %s", mb);
  ins_line(col2, &y2, b);
  char sb[24] = "--";
  if (!isnan(t->speed)) snprintf(sb, sizeof(sb), "%.1f m/s (%.0f kt)", t->speed, t->speed * 1.94384f);
  snprintf(b, sizeof(b), "Speed: %s", sb);
  ins_line(col2, &y2, b);
  char cb[16] = "--";
  if (!isnan(t->heading)) snprintf(cb, sizeof(cb), "%03d deg (%s)", (int)t->heading, cardinal(t->heading));
  snprintf(b, sizeof(b), "Heading: %s", cb);
  ins_line(col2, &y2, b);
  if (g_home_set && t->has_pos) {
    char rb[16]; dist_text(rb, sizeof(rb), ui_dist_m(g_home_lat, g_home_lon, t->lat, t->lon));
    int brg = (int)ui_bearing(g_home_lat, g_home_lon, t->lat, t->lon);
    snprintf(b, sizeof(b), "Range: %s, bearing %03d deg", rb, brg);
  } else {
    snprintf(b, sizeof(b), "Range: no receiver position");
  }
  ins_line(col2, &y2, b);
  snprintf(b, sizeof(b), "Status: %s", t->status == 3 ? "EMERGENCY REPORTED" : ui_status_name(t->status));
  ins_line(col2, &y2, b);
  // An ADS-B conflict with this drone: its action, then the geometry.
  // Nothing when there is none: the board lists drones, not aircraft.
  if (const TrafficAlert* ta = alert_for_drone(t)) {
    snprintf(b, sizeof(b), "ADS-B: %s", ta->action);
    y2 += 20 * text_wrap2(&FreeSansBold9pt7b, b, col2, y2, 20, 300, BLACK);
    snprintf(b, sizeof(b), "%s", alert_geometry(ta));
    y2 += 20 * text_wrap2(&FreeSansBold9pt7b, b, col2, y2, 20, 300, GREY);
  }
  // "No match" is only claimed against data the host actually pushed.
  ui_airspace_text(al, sizeof(al), t, s_now);
  snprintf(b, sizeof(b), "Airspace: %s", al);
  y2 += 20 * text_wrap2(f9, b, col2, y2, 20, 300, t->in_tfr ? BLACK : GREY);

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
  bool clr = s_target_mode == UI_TARGET_CLEAR_LOG;
  const char* title = clr ? "CLEAR HISTORY?" : pwr ? "POWER OFF?" : (s_target_mode == UI_MODE_TX) ? "SWITCH TO TEST BEACON?" : "SWITCH TO RECEIVER?";
  int tw = text_w(&FreeSansBold18pt7b, title);
  text(&FreeSansBold18pt7b, title, mx + (mw - tw) / 2, my + 48, BLACK);

  // On USB the board sleeps and BOOT wakes it; on battery it cuts its
  // power and only PWR brings it back (periph_power_off).
  const char* l1 = pwr ? "The radios and screen turn off." :
    (s_target_mode == UI_MODE_TX) ?
    "The board restarts as a Remote ID test beacon." :
    "The board restarts as a Remote ID receiver.";
  const char* l2 = pwr ? (periph_on_vbus() ? "Press BOOT to wake it." : "Press PWR to turn it back on.") :
    (s_target_mode == UI_MODE_TX) ?
    "It transmits test broadcasts on 2.4 GHz." :
    "It listens for drones on Wi-Fi and BLE.";

  char l1c[64];
  if (clr) {
    int held = 0; uint32_t age; rx_log_stats(&held, &age);
    snprintf(l1c, sizeof(l1c), "Clear the %d saved drone record%s?", held, held == 1 ? "" : "s");
    l1 = l1c;
    l2 = "This can't be undone. Connected apps are told.";
  }
  text(&FreeSansBold9pt7b, l1, mx + (mw - text_w(&FreeSansBold9pt7b, l1)) / 2, my + 92, BLACK);
  text(&FreeSansBold9pt7b, l2, mx + (mw - text_w(&FreeSansBold9pt7b, l2)) / 2, my + 118, GREY);

  int bw = 220, bh = 54, by = my + 164;
  int bx_ok = mx + 45;
  int bx_can = mx + mw - 45 - bw;

  // OK button (solid black)
  rect(bx_ok, by, bw, bh, BLACK);
  const char* ok_txt = clr ? "CLEAR" : pwr ? "POWER OFF" : "SWITCH";
  text(&FreeSansBold12pt7b, ok_txt, bx_ok + (bw - text_w(&FreeSansBold12pt7b, ok_txt)) / 2, by + 35, WHITE);

  // Cancel button (outline)
  box(bx_can, by, bw, bh, BLACK);
  box(bx_can + 1, by + 1, bw - 2, bh - 2, BLACK);
  text(&FreeSansBold12pt7b, "CANCEL", bx_can + (bw - text_w(&FreeSansBold12pt7b, "CANCEL")) / 2, by + 35, BLACK);
}

// The traffic card (§8.3, docs/mockups/orecchino-traffic-alerts.html, and
// the conflict-only decision): the plot panel while a warning lasts, or when
// an alerting aircraft's diamond is tapped. It leads with the action for the
// drone, inverted and biggest, then the geometry that justifies it, then the
// aircraft and its data age, and keeps the two honest sentences.
#define TC_X 574
#define TC_Y 76
#define TC_W 378
#define TC_H 416
static void tri(int x, int y, int w, bool up) {   // filled, apex up or down; (x,y) top-left
  for (int r = 0; r <= w / 2; r++) {
    int yy = up ? y + r : y + w / 2 - r;
    rect(x + w / 2 - r, yy, 2 * r + 1, 1, BLACK);
  }
}
static void draw_traffic_card(const TrafficAircraft* ac, const TrafficAlert* al) {
  const GFXfont* f9 = &FreeSansBold9pt7b;
  const GFXfont* f12 = &FreeSansBold12pt7b;
  const GFXfont* f18 = &FreeSansBold18pt7b;
  const int x = TC_X + 16, maxw = TC_W - 32;
  char b[96];
  rect(TC_X, TC_Y, TC_W, TC_H, WHITE);
  for (int i = 0; i < 3; i++) box(TC_X + i, TC_Y + i, TC_W - 2 * i, TC_H - 2 * i, BLACK);

  // What to do, first and biggest: the action, inverted (18 pt on two
  // lines, else 12 pt on three).
  const char* act = al ? al->action : "TRAFFIC";
  const GFXfont* af = f18; int alh = 30, maxl = 2;
  int lines = text_para(f18, act, 0, 0, alh, maxw, WHITE, 3, false);
  if (lines > 2) { af = f12; alh = 24; maxl = 3; lines = text_para(f12, act, 0, 0, alh, maxw, WHITE, maxl, false); }
  int band_h = 14 + lines * alh + 8;
  rect(TC_X, TC_Y, TC_W, band_h, BLACK);
  text_para(af, act, x, TC_Y + 12 + (af == f18 ? 26 : 20), alh, maxw, WHITE, maxl);
  int y = TC_Y + band_h;

  // The geometry that justifies it (from the resolution), broken between
  // its parts ("AIRCRAFT 90 M ABOVE," / "900 M NE"), never inside one.
  if (al) {
    char g[TRAFFIC_RES_LEN]; snprintf(g, sizeof(g), "%s", alert_geometry(al));
    char line[TRAFFIC_RES_LEN] = ""; int nl = 0;
    for (char* part = strtok(g, ","); part && nl < 3; part = strtok(nullptr, ",")) {
      while (*part == ' ') part++;
      char next[TRAFFIC_RES_LEN];
      snprintf(next, sizeof(next), "%s%s%s", line, line[0] ? ", " : "", part);
      if (line[0] && text_w(f12, next) > maxw) {
        strncat(line, ",", sizeof(line) - strlen(line) - 1);
        text(f12, line, x, y + 28 + 24 * nl++, BLACK);
        snprintf(line, sizeof(line), "%s", part);
      } else {
        snprintf(line, sizeof(line), "%s", next);
      }
    }
    if (line[0] && nl < 3) { fit_text(line, sizeof(line), f12, maxw); text(f12, line, x, y + 28 + 24 * nl++, BLACK); }
    y += 24 * nl;
  }
  y += 14;

  // The aircraft, and how old its position is.
  char name[12];
  if (ac) traffic_ac_name(ac, name, sizeof(name));
  else if (al && al->callsign[0]) snprintf(name, sizeof(name), "%s", al->callsign);
  else { snprintf(name, sizeof(name), "%s", al ? al->hex : "?"); for (char* p = name; *p; p++) *p = (char)toupper((unsigned char)*p); }
  double age = ac ? traffic_age_s(ac->seen_ms, s_now) : (al ? al->age_s : NAN);
  char agew[32];
  if (isfinite(age)) traffic_age_words(age, agew, sizeof(agew)); else snprintf(agew, sizeof(agew), "ADS-B age unknown");
  bool stale = g_traffic_result.stale || (isfinite(age) && age >= TRAFFIC_FRESH_S);
  int agw = text_w(f9, agew);
  text_r(f9, agew, TC_X + TC_W - 16, y + 22, stale ? BLACK : GREY);
  text(f12, name, x, y + 24, BLACK);
  b[0] = 0;
  if (ac) {
    char hex[8]; snprintf(hex, sizeof(hex), "%s", ac->hex);
    for (char* p = hex; *p; p++) *p = (char)toupper((unsigned char)*p);
    snprintf(b, sizeof(b), "%s%s%s", ac->type[0] ? ac->type : "", ac->type[0] ? " | " : "", hex);
  }
  int nx = x + text_w(f12, name) + 10;
  if (ac && text_w(f9, b) > TC_X + TC_W - 16 - agw - 10 - nx) snprintf(b, sizeof(b), "%s", ac->type);   // no room for the address
  fit_text(b, sizeof(b), f9, TC_X + TC_W - 16 - agw - 10 - nx);
  text(f9, b, nx, y + 22, GREY);
  y += 38;
  rect(x, y, maxw, 1, LIGHT);

  // Its own altitude and speed, as reported.
  text(f9, "ALTITUDE", x, y + 22, GREY);
  text(f9, "SPEED", x + 180, y + 22, GREY);
  if (ac && ac->on_ground) snprintf(b, sizeof(b), "on ground");
  else if (ac && isfinite(ac->alt_baro_m)) ft_text(b, sizeof(b), ac->alt_baro_m);
  else if (ac && isfinite(ac->alt_geom_m)) { char f[20]; ft_text(f, sizeof(f), ac->alt_geom_m); snprintf(b, sizeof(b), "%s GNSS", f); }
  else snprintf(b, sizeof(b), "--");
  text(text_w(f18, b) <= 170 ? f18 : f12, b, x, y + 52, BLACK);
  if (ac && isfinite(ac->gs_mps)) snprintf(b, sizeof(b), "%ld kt", iround(ac->gs_mps / TRAFFIC_KT_TO_MPS));
  else snprintf(b, sizeof(b), "--");
  text(f18, b, x + 180, y + 52, BLACK);
  y += 60;
  if (ac && !ac->on_ground && isfinite(ac->vs_mps)) {
    long fpm = iround(ac->vs_mps / TRAFFIC_FT_TO_M * 60);
    if (labs(fpm) < 100) snprintf(b, sizeof(b), "level");
    else snprintf(b, sizeof(b), "%s %ld fpm", fpm > 0 ? "climbing" : "descending", labs(fpm));
    int tx = x;
    if (labs(fpm) >= 100) { tri(x, y + 12, 14, fpm > 0); tx = x + 22; }
    text(f12, b, tx, y + 26, BLACK);
  }

  // The two honest sentences, above the tap band.
  const int by = TC_Y + TC_H - 37;
  text(f9, "Positions as reported, not a prediction.", x, by - 32, GREY);
  text(f9, "Not every aircraft broadcasts ADS-B.", x, by - 12, GREY);

  // What a tap does.
  rect(TC_X + 3, by, TC_W - 6, 34, LIGHT);
  const char* tap = is_pair(al) ? "TAP FOR THE DRONE'S DETAILS" : "TAP TO CLOSE";
  text(f9, tap, TC_X + (TC_W - text_w(f9, tap)) / 2, TC_Y + TC_H - 14, BLACK);
}

// ---- Wi-Fi setup (plan §4.3), on net_sync.h's API. Opened from SYSTEM:
// the networks screen (a scan, a list with signal bars, a lock for secured
// networks, SAVED chips, pages, "Other network..."), a saved network's
// CONNECT / FORGET, the keyboard, then a joining screen that stays until
// the join succeeds or fails, and the result in words.
#define WF_HEAD_H 76
#define WF_ROW_Y0 118
#define WF_ROW_H  64
#define WF_ROWS   5
#define WF_PAGE_Y 446
#define WF_BTN_W  120
#define WF_BTN_H  60
static const EpdRect RECT_KB_FIELD = { 16, 72, 944, 72 };     // 8-px aligned: the field and SHOW
static const EpdRect RECT_KB_ALL   = { 16, 72, 944, 468 };    // field, keys, hint

/// Networks in list order plus "Other network..." as the last entry.
static int wifi_entries() { uint8_t n = 0; net_get_scanned(&n); return n + 1; }
static int wifi_pages() { return (wifi_entries() + WF_ROWS - 1) / WF_ROWS; }
static void signal_bars(int x, int y, int rssi) {   // (x,y): bottom-left; 4 bars, 33 px wide
  int lvl = rssi >= -55 ? 4 : rssi >= -65 ? 3 : rssi >= -75 ? 2 : 1;
  for (int i = 0; i < 4; i++) {
    int h = 7 + i * 5;
    if (i < lvl) rect(x + i * 9, y - h, 6, h, BLACK); else box(x + i * 9, y - h, 6, h, GREY);
  }
}
static void lock_glyph(int x, int y) {   // (x,y): bottom-left, 14 x 20
  rect(x, y - 11, 14, 11, BLACK);
  box(x + 3, y - 19, 8, 9, BLACK);
  box(x + 4, y - 18, 6, 8, BLACK);
}
static void header_button(int x, const char* lbl) {   // white button in a black header
  rect(x, 8, WF_BTN_W, WF_BTN_H, WHITE);
  text(&FreeSansBold12pt7b, lbl, x + (WF_BTN_W - text_w(&FreeSansBold12pt7b, lbl)) / 2, 8 + 38, BLACK);
}
static void big_button(int x, int y, int w, int h, const char* lbl, bool solid) {
  if (solid) rect(x, y, w, h, BLACK);
  else { box(x, y, w, h, BLACK); box(x + 1, y + 1, w - 2, h - 2, BLACK); }
  text(&FreeSansBold12pt7b, lbl, x + (w - text_w(&FreeSansBold12pt7b, lbl)) / 2, y + h / 2 + 8, solid ? WHITE : BLACK);
}

static void draw_wifi_list() {
  const GFXfont* f9 = &FreeSansBold9pt7b;
  const GFXfont* f12 = &FreeSansBold12pt7b;
  const GFXfont* f18 = &FreeSansBold18pt7b;
  rect(0, 0, W, WF_HEAD_H, BLACK);
  text(f18, "WI-FI NETWORKS", 24, 50, WHITE);
  header_button(W - 24 - 2 * WF_BTN_W - 12, "SCAN");
  header_button(W - 24 - WF_BTN_W, "CLOSE");
  char b[80];
  bool scanning = net_is_scanning();
  if (scanning) snprintf(b, sizeof(b), "scanning, Remote ID Wi-Fi paused (about 2 s)");
  else net_status_line(b, sizeof(b));
  fit_text(b, sizeof(b), f9, W - 48);
  text(f9, b, 24, 104, scanning ? BLACK : GREY);

  uint8_t count = 0;
  const ScannedNetwork* nets = net_get_scanned(&count);
  int entries = count + 1, pages = wifi_pages();
  if (s_wifi_page >= pages) s_wifi_page = pages - 1;
  if (s_wifi_page < 0) s_wifi_page = 0;
  for (int r = 0; r < WF_ROWS; r++) {
    int e = s_wifi_page * WF_ROWS + r;
    if (e >= entries) break;
    int ry = WF_ROW_Y0 + r * WF_ROW_H;
    box(24, ry, W - 48, WF_ROW_H - 6, BLACK);
    if (e == count) {   // hidden networks
      text(f12, "Other network...", 40, ry + 38, BLACK);
      text_r(f9, "type its name", W - 40, ry + 36, GREY);
      continue;
    }
    const ScannedNetwork* n = &nets[e];
    int xr = W - 40;
    signal_bars(xr - 33, ry + 44, n->rssi);
    xr -= 33 + 16;
    if (n->auth_mode) { lock_glyph(xr - 14, ry + 42); xr -= 14 + 16; }
    else { text_r(f9, "open", xr, ry + 38, GREY); xr -= text_w(f9, "open") + 16; }
    bool on = net_get_state() == NET_STATE_CONNECTED && !strcmp(net_get_ssid(), n->ssid);
    const char* chip = on ? "CONNECTED" : n->saved ? "SAVED" : nullptr;
    if (chip) {
      int cw = text_w(f9, chip) + 14;
      rect(xr - cw, ry + 18, cw, 22, BLACK);
      text(f9, chip, xr - cw + 7, ry + 35, WHITE);
      xr -= cw + 16;
    }
    snprintf(b, sizeof(b), "%s", n->ssid);
    fit_text(b, sizeof(b), f12, xr - 40);
    text(f12, b, 40, ry + 38, BLACK);
  }
  if (!count && !scanning) text(f9, "No networks heard. Tap SCAN to look again.", 24, WF_ROW_Y0 + WF_ROW_H + 30, GREY);
  if (pages > 1) {
    big_button(24, WF_PAGE_Y, 150, 56, "< PREV", false);
    big_button(W - 24 - 150, WF_PAGE_Y, 150, 56, "NEXT >", false);
    snprintf(b, sizeof(b), "page %d of %d", s_wifi_page + 1, pages);
    text(f12, b, (W - text_w(f12, b)) / 2, WF_PAGE_Y + 36, BLACK);
  }
  text(f9, "Tap a network to connect. Passwords are kept on this board in plain NVS.", 24, 528, GREY);
}

static void draw_wifi_action() {   // CONNECT / FORGET for a saved network, over the list
  const GFXfont* f12 = &FreeSansBold12pt7b;
  const int mw = 600, mh = 250, mx = (W - mw) / 2, my = (H - mh) / 2;
  rect(mx, my, mw, mh, WHITE);
  for (int i = 0; i < 3; i++) box(mx + i, my + i, mw - 2 * i, mh - 2 * i, BLACK);
  char b[48]; snprintf(b, sizeof(b), "%s", s_wifi_ssid);
  fit_text(b, sizeof(b), &FreeSansBold18pt7b, mw - 48);
  text(&FreeSansBold18pt7b, b, mx + 24, my + 54, BLACK);
  text(&FreeSansBold9pt7b, "A saved network. Connect now, or forget it and its password.", mx + 24, my + 88, GREY);
  const int by = my + mh - 24 - 64, bw = 170;
  big_button(mx + 24, by, bw, 64, "CONNECT", true);
  big_button(mx + 24 + bw + 15, by, bw, 64, "FORGET", false);
  big_button(mx + mw - 24 - bw, by, bw, 64, "CANCEL", false);
  (void)f12;
}

static void draw_wifi_join() {   // joining, then the result
  const GFXfont* f9 = &FreeSansBold9pt7b;
  const GFXfont* f12 = &FreeSansBold12pt7b;
  const GFXfont* f18 = &FreeSansBold18pt7b;
  rect(0, 0, W, WF_HEAD_H, BLACK);
  text(f18, "WI-FI", 24, 50, WHITE);
  char b[96];
  snprintf(b, sizeof(b), "%s", s_wifi_ssid);
  fit_text(b, sizeof(b), f18, W - 96);
  if (s_wv == WV_JOINING) {
    text(f12, "CONNECTING TO", 48, 190, GREY);
    text(f18, b, 48, 236, BLACK);
    text(f9, "Remote ID reception over Wi-Fi pauses while the board joins (up to 15 s).", 48, 290, GREY);
    text(f9, "Bluetooth reception carries on.", 48, 314, GREY);
    return;
  }
  text(f18, s_wifi_join_ok ? "CONNECTED" : "COULD NOT CONNECT", 48, 170, BLACK);
  text(f12, b, 48, 214, BLACK);
  if (s_wifi_join_ok) {
    snprintf(b, sizeof(b), "Saved. %s", net_get_mode() == NET_MODE_STAY ? "The board stays connected."
             : "The board joins it for each sync, then goes back to listening.");
    fit_text(b, sizeof(b), f9, W - 96);
    text(f9, b, 48, 256, GREY);
  } else {
    snprintf(b, sizeof(b), "Reason: %s", s_wifi_join_err[0] ? s_wifi_join_err : "unknown");
    fit_text(b, sizeof(b), f12, W - 96);
    text(f12, b, 48, 262, BLACK);
    text(f9, "Nothing was saved.", 48, 292, GREY);
  }
  if (!s_wifi_join_ok) big_button(48, 400, 220, 64, "TRY AGAIN", false);
  big_button(W - 48 - 220, 400, 220, 64, "OK", true);
}

static void draw_wifi_screen() {
  epd_hl_set_all_white(&s_hl);
  if (s_wv == WV_JOINING || s_wv == WV_RESULT) { draw_wifi_join(); return; }
  draw_wifi_list();
  if (s_wv == WV_ACTION) draw_wifi_action();
}

// ---- the on-screen keyboard (plan §4.3). Full screen: keys 84 x 60 px (a
// fingertip on this panel), five rows; digits always on top; letters shown
// in the case they will type; SHIFT once for one capital, twice for caps
// lock; #+= for symbols. A key press refreshes only what changed in fast
// 1-bit DU (the pressed key inverts, then the field updates) and the field
// is cleaned with GL16 after 20 of those -- never a full-screen flash.
#define KB_X0    24
#define KB_KW    84
#define KB_KH    60
#define KB_GAP   8
#define KB_Y0    150
#define KB_PITCH 68
#define KB_FX    24
#define KB_FY    76
#define KB_FW    762
#define KB_FH    60
#define KB_SHOW_X (KB_FX + KB_FW + 12)
#define KB_SHOW_W (W - 24 - KB_SHOW_X)
static const char* const KB_ROWS[2][4] = {
  { "1234567890", "qwertyuiop", "asdfghjkl-", "\x01zxcvbnm._" },   // \x01: SHIFT
  { "1234567890", "!@#$%^&*()", "-_=+:;'\"?/", "[]{}<>\\|~," },
};
enum : uint8_t { KB_K_CHAR = 0, KB_K_SHIFT, KB_K_LAYER, KB_K_SPACE, KB_K_BKSP, KB_K_CANCEL, KB_K_OK };
struct KbKey { int x, y, w, h; uint8_t kind; char ch; };
#define KB_MAXKEYS 48
static int kb_keys(KbKey* out) {
  int n = 0;
  for (int r = 0; r < 4; r++) {
    const char* row = KB_ROWS[s_kb_layer][r];
    for (int i = 0; row[i]; i++)
      out[n++] = { KB_X0 + i * (KB_KW + KB_GAP), KB_Y0 + r * KB_PITCH, KB_KW, KB_KH,
                   row[i] == '\x01' ? KB_K_SHIFT : KB_K_CHAR, row[i] };
  }
  static const int bw[5] = { 130, 300, 130, 150, 170 };   // with 4 gaps: 912, the rows' width
  static const uint8_t bk[5] = { KB_K_LAYER, KB_K_SPACE, KB_K_BKSP, KB_K_CANCEL, KB_K_OK };
  int x = KB_X0;
  for (int i = 0; i < 5; i++) { out[n++] = { x, KB_Y0 + 4 * KB_PITCH, bw[i], KB_KH, bk[i], 0 }; x += bw[i] + KB_GAP; }
  return n;
}
static char kb_char(char c) {   // what the key types (and shows) now
  bool upper = s_kb_layer == 0 && (s_kb_shift || s_kb_caps);
  return upper && c >= 'a' && c <= 'z' ? (char)(c - 32) : c;
}
static void kb_draw_key(const KbKey& k, bool pressed) {
  const GFXfont* f9 = &FreeSansBold9pt7b;
  const GFXfont* f18 = &FreeSansBold18pt7b;
  char lbl[12]; const GFXfont* f = f9;
  bool solid = false;
  switch (k.kind) {
    case KB_K_CHAR:   lbl[0] = kb_char(k.ch); lbl[1] = 0; f = f18; break;
    case KB_K_SHIFT:  snprintf(lbl, sizeof(lbl), s_kb_caps ? "CAPS" : "SHIFT"); solid = s_kb_shift || s_kb_caps; break;
    case KB_K_LAYER:  snprintf(lbl, sizeof(lbl), s_kb_layer ? "abc" : "#+="); f = &FreeSansBold12pt7b; break;
    case KB_K_SPACE:  snprintf(lbl, sizeof(lbl), "SPACE"); break;
    case KB_K_BKSP:   snprintf(lbl, sizeof(lbl), "DELETE"); break;
    case KB_K_CANCEL: snprintf(lbl, sizeof(lbl), "CANCEL"); break;
    default:          snprintf(lbl, sizeof(lbl), s_kb_ssid_stage ? "NEXT" : "CONNECT"); solid = true; break;
  }
  bool ink = solid != pressed;   // a press inverts the key
  rect(k.x, k.y, k.w, k.h, ink ? BLACK : WHITE);
  if (!ink) { box(k.x, k.y, k.w, k.h, BLACK); box(k.x + 1, k.y + 1, k.w - 2, k.h - 2, BLACK); }
  int tw = text_w(f, lbl);
  int ty = f == f18 ? k.y + 42 : k.y + 37;
  text(f, lbl, k.x + (k.w - tw) / 2, ty, ink ? WHITE : BLACK);
  if (k.kind == KB_K_SHIFT && s_kb_caps) rect(k.x + 20, k.y + k.h - 10, k.w - 40, 3, ink ? WHITE : BLACK);
}
static void kb_draw_field() {
  const GFXfont* f9 = &FreeSansBold9pt7b;
  const GFXfont* f18 = &FreeSansBold18pt7b;
  rect(RECT_KB_FIELD.x, RECT_KB_FIELD.y, RECT_KB_FIELD.width, RECT_KB_FIELD.height, WHITE);
  box(KB_FX, KB_FY, KB_FW, KB_FH, BLACK);
  box(KB_FX + 1, KB_FY + 1, KB_FW - 2, KB_FH - 2, BLACK);
  // What was typed (dots unless SHOW), its tail when long, and a caret.
  char shown[NET_MAX_PASS_LEN + 4];
  size_t n = strlen(s_kb_buf);
  bool mask = !s_kb_ssid_stage && !s_kb_show;
  for (size_t i = 0; i < n; i++) shown[i] = mask ? '*' : s_kb_buf[i];
  shown[n] = '_'; shown[n + 1] = 0;
  // The count at the field's right end: what 8-to-63 is measured against.
  char cnt[12]; snprintf(cnt, sizeof(cnt), "%u", (unsigned)n);
  text_r(f9, cnt, KB_FX + KB_FW - 12, KB_FY + 38, GREY);
  const char* p = shown;
  while (text_w(f18, p) > KB_FW - 40 - text_w(f9, cnt) && p[1]) p++;
  text(f18, p, KB_FX + 12, KB_FY + 42, BLACK);
  if (!s_kb_ssid_stage) {
    KbKey k = { KB_SHOW_X, KB_FY, KB_SHOW_W, KB_FH, 0, 0 };
    rect(k.x, k.y, k.w, k.h, WHITE);
    box(k.x, k.y, k.w, k.h, BLACK); box(k.x + 1, k.y + 1, k.w - 2, k.h - 2, BLACK);
    const char* l = s_kb_show ? "HIDE" : "SHOW";
    text(&FreeSansBold12pt7b, l, k.x + (k.w - text_w(&FreeSansBold12pt7b, l)) / 2, k.y + 38, BLACK);
  }
}
static void draw_keyboard() {
  const GFXfont* f9 = &FreeSansBold9pt7b;
  const GFXfont* f12 = &FreeSansBold12pt7b;
  const GFXfont* f18 = &FreeSansBold18pt7b;
  epd_hl_set_all_white(&s_hl);
  rect(0, 0, W, 64, BLACK);
  const char* lead = s_kb_ssid_stage ? "NETWORK NAME" : "PASSWORD FOR";
  text(f12, lead, 24, 42, WHITE);
  if (!s_kb_ssid_stage) {
    int x = 24 + text_w(f12, lead) + 14;
    char b[48]; snprintf(b, sizeof(b), "%s", s_kb_ssid);
    fit_text(b, sizeof(b), f18, W - 24 - x);
    text(f18, b, x, 44, WHITE);
  } else {
    text(f9, "(a hidden network: type its name exactly)", 24 + text_w(f12, lead) + 14, 40, WHITE);
  }
  kb_draw_field();
  KbKey keys[KB_MAXKEYS]; int n = kb_keys(keys);
  for (int i = 0; i < n; i++) kb_draw_key(keys[i], false);
  const char* h = s_kb_ssid_stage ? "Up to 32 characters, exactly as the network is named. NEXT: its password."
                                   : "8 to 63 characters, or none for an open network. SHOW to check what you typed.";
  text(f9, h, 24, 516, GREY);
}
/// A fast partial of the keyboard: DU (1-bit, ~260 ms), then GL16 on the
/// field and keys after 20 of them to clear the ghosting DU leaves.
static void kb_flush(EpdRect r) {
  epd_ensure_on();
  EpdRect a = { r.x & ~7, r.y, ((r.x + r.width + 7) & ~7) - (r.x & ~7), r.height };
  refresh_checked(a, MODE_DU);
  if (++s_kb_du >= 20) {
    refresh_checked(RECT_KB_ALL, MODE_GL16);
    s_kb_du = 0;
  }
}
static EpdRect rect_union(EpdRect a, EpdRect b) {
  int x0 = min(a.x, b.x), y0 = min(a.y, b.y);
  int x1 = max(a.x + a.width, b.x + b.width), y1 = max(a.y + a.height, b.y + b.height);
  return { x0, y0, x1 - x0, y1 - y0 };
}
static void wifi_start_join(const char* ssid, const char* pass) {
  char name[NET_MAX_SSID_LEN + 1];
  snprintf(name, sizeof(name), "%s", ssid);   // ssid may be s_wifi_ssid itself
  snprintf(s_wifi_ssid, sizeof(s_wifi_ssid), "%s", name);
  bool queued = net_connect(name, pass);
  s_kb_modal = false;
  s_wifi_join_ms = s_now;
  s_wifi_join_seen = false;
  s_wifi_join_err[0] = 0;
  if (!queued) {   // refused at once (a password that cannot be right)
    s_wifi_join_ok = false;
    snprintf(s_wifi_join_err, sizeof(s_wifi_join_err), "%s", net_last_error());
    s_wv = WV_RESULT;
    return;
  }
  s_wv = WV_JOINING;
}
/// The Wi-Fi screens' own clock: redraw when a scan finishes; turn the
/// joining screen into the result once the join has succeeded or failed.
static void wifi_poll(uint32_t now) {
  bool scanning = net_is_scanning();
  if (s_wifi_was_scanning && !scanning) {
    s_wifi_was_scanning = false;
    if (s_wv == WV_LIST) { draw_board(false); s_sig_prev = signature(); }
    return;
  }
  if (scanning) s_wifi_was_scanning = true;
  if (s_wv != WV_JOINING) return;
  NetState st = net_get_state();
  if (st == NET_STATE_CONNECTING) s_wifi_join_seen = true;
  bool done = s_wifi_join_seen && st != NET_STATE_CONNECTING;
  bool timed_out = (int32_t)(now - s_wifi_join_ms) > 60000;
  if (!done && !timed_out) return;
  s_wifi_join_ok = done && st != NET_STATE_FAILED;
  snprintf(s_wifi_join_err, sizeof(s_wifi_join_err), "%s", timed_out && !done ? "no answer from the Wi-Fi task" : net_last_error());
  snprintf(s_diag_note, sizeof(s_diag_note), s_wifi_join_ok ? "joined %s" : "could not join %s", s_wifi_ssid);
  s_wv = WV_RESULT;
  draw_board(false);
  s_sig_prev = signature();
}
/// A tap on the keyboard. Returns after its own partial refreshes.
static void kb_tap(int tx, int ty) {
  if (!s_kb_ssid_stage && tx >= KB_SHOW_X && tx < KB_SHOW_X + KB_SHOW_W && ty >= KB_FY && ty < KB_FY + KB_FH) {
    s_kb_show = !s_kb_show;
    kb_draw_field();
    kb_flush(RECT_KB_FIELD);
    return;
  }
  // The key under the touch point (the gaps count toward the nearest key).
  KbKey keys[KB_MAXKEYS]; int n = kb_keys(keys);
  int hit = -1;
  for (int i = 0; i < n; i++) {
    const KbKey& k = keys[i];
    if (tx >= k.x - KB_GAP / 2 && tx < k.x + k.w + KB_GAP / 2 && ty >= k.y - KB_GAP / 2 && ty < k.y + k.h + KB_GAP / 2) { hit = i; break; }
  }
  if (hit < 0) return;   // outside the keys: nothing, and nothing typed is lost
  KbKey k = keys[hit];
  EpdRect kr = { k.x, k.y, k.w, k.h };
  kb_draw_key(k, true);
  kb_flush(kr);
  bool relabel = false;
  size_t len = strlen(s_kb_buf);
  size_t cap = s_kb_ssid_stage ? NET_MAX_SSID_LEN : NET_MAX_PASS_LEN;
  switch (k.kind) {
    case KB_K_CHAR:
      if (len < cap) { s_kb_buf[len] = kb_char(k.ch); s_kb_buf[len + 1] = 0; }
      if (s_kb_shift) { s_kb_shift = false; relabel = true; }
      break;
    case KB_K_SPACE:
      if (len < cap) { s_kb_buf[len] = ' '; s_kb_buf[len + 1] = 0; }
      break;
    case KB_K_BKSP:
      if (len) s_kb_buf[len - 1] = 0;
      break;
    case KB_K_SHIFT:
      if (s_kb_caps) s_kb_caps = false;
      else if (s_kb_shift && s_now - s_kb_shift_ms < 700) { s_kb_shift = false; s_kb_caps = true; }
      else s_kb_shift = !s_kb_shift;
      s_kb_shift_ms = s_now;
      relabel = true;
      break;
    case KB_K_LAYER:
      s_kb_layer ^= 1;
      s_kb_shift = false;
      relabel = true;
      break;
    case KB_K_CANCEL:
      s_kb_modal = false;
      s_wv = WV_LIST;
      s_sig_prev = 0;
      draw_board(false);
      return;
    case KB_K_OK:
      if (s_kb_ssid_stage) {
        if (!s_kb_buf[0]) break;
        snprintf(s_kb_ssid, sizeof(s_kb_ssid), "%.*s", NET_MAX_SSID_LEN, s_kb_buf);   // typed up to that cap
        s_kb_buf[0] = 0;
        s_kb_ssid_stage = false;
        s_kb_show = false;
        draw_board(false);
        return;
      }
      wifi_start_join(s_kb_ssid, s_kb_buf);
      s_sig_prev = 0;
      draw_board(false);
      return;
  }
  if (relabel) {
    for (int i = 0; i < n; i++) if (keys[i].kind == KB_K_CHAR || keys[i].kind == KB_K_SHIFT || keys[i].kind == KB_K_LAYER) kb_draw_key(keys[i], false);
    kb_draw_key(k, false);
  } else {
    kb_draw_key(k, false);
  }
  kb_draw_field();
  kb_flush(relabel ? RECT_KB_ALL : rect_union(kr, RECT_KB_FIELD));
}

static void draw_tx() {
  bool running = txui_running();
  rect(0, 0, W, 70, running ? BLACK : WHITE);
  if (!running) rect(0, 68, W, 2, BLACK);
  uint8_t fg = running ? WHITE : BLACK, mut = running ? WHITE : BLACK;

  // Headline, then the tally where the headline ends
  const char* head = running ? "TEST BEACON  ON AIR" : "TEST BEACON  PAUSED";
  text(&FreeSansBold18pt7b, head, TABLE_X, 48, fg);
  int tally_x = TABLE_X + text_w(&FreeSansBold18pt7b, head) + 24;

  // Status tally
  int n = txui_count();
  int on = 0;
  uint32_t total_sent = 0;
  for (int i = 0; i < n; i++) {
    if (txui_enabled(i)) on++;
    total_sent += txui_sent(i);
  }
  char st_b[48];
  snprintf(st_b, sizeof(st_b), "%d/%d ON | %lu SENT", on, n, (unsigned long)total_sent);
  text(&FreeSansBold9pt7b, st_b, tally_x, 45, mut);

  // Battery, then the button back to the receiver
  int xr = W - 184;
  if (s_batt >= 0) {
    char bb[16]; snprintf(bb, sizeof(bb), "%d%%", s_batt);
    text_r(&FreeSansBold12pt7b, bb, xr, 44, mut);
  }

  // [ RECEIVER ] button
  const int rx_btn_w = 146, rx_btn_h = 46, rx_btn_x = W - 166, rx_btn_y = 12;
  box(rx_btn_x, rx_btn_y, rx_btn_w, rx_btn_h, fg);
  box(rx_btn_x + 1, rx_btn_y + 1, rx_btn_w - 2, rx_btn_h - 2, fg);
  int tw_rx = text_w(&FreeSansBold12pt7b, "RECEIVER");
  text(&FreeSansBold12pt7b, "RECEIVER", rx_btn_x + (rx_btn_w - tw_rx) / 2, 41, fg);

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

  // Button 5: RATE [SPEC] / [SLOW], in the room left after ALL OFF. SPEC
  // meets the Remote ID rates; SLOW sends each path once every 5 s, and is
  // inked solid because it is the one a receiver will drop contacts on.
  {
    bool slow = txui_slow();
    int rt_x = aoff_x + aoff_w + 15, rt_y = 82, rt_w = W - 20 - rt_x, rt_h = 46;
    const char* lbl = slow ? "RATE [SLOW]" : "RATE [SPEC]";
    if (slow) {
      rect(rt_x, rt_y, rt_w, rt_h, BLACK);
    } else {
      box(rt_x, rt_y, rt_w, rt_h, BLACK);
      box(rt_x + 1, rt_y + 1, rt_w - 2, rt_h - 2, BLACK);
    }
    char rb[24];
    snprintf(rb, sizeof(rb), "%s", lbl);
    fit_text(rb, sizeof(rb), &FreeSansBold12pt7b, rt_w - 12);
    text(&FreeSansBold12pt7b, rb, rt_x + (rt_w - text_w(&FreeSansBold12pt7b, rb)) / 2, rt_y + 30, slow ? WHITE : BLACK);
  }

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
      snprintf(cb, sizeof(cb), "%lu sent", (unsigned long)txui_sent(i));
      int cnt_w = text_w(f9, cb);

      // The variant's name is the title: it is what tells the ten paths
      // apart, and every UAS ID shares the ORECCHINO-TX- head.
      int id_x = cx + cw + 10;
      int max_id_w = (x0 + card_w - 14 - cnt_w - 10) - id_x;
      if (max_id_w < 50) max_id_w = 50;
      char id_b[32];
      snprintf(id_b, sizeof(id_b), "%s", ui_tx_variant(txui_id(i)));
      fit_text(id_b, sizeof(id_b), f12, max_id_w);
      text(f12, id_b, id_x, y + 26, BLACK);

      // Subtitle (self desc)
      text(f9, txui_desc(i), cx, y + 46, BLACK);

      text_r(f9, cb, x0 + card_w - 12, y + 34, BLACK);
    }
  }

  // Footer (y: 496..540)
  rect(0, 496, W, 44, WHITE);
  rect(0, 496, W, 2, BLACK);
  const char* hint = "tap card: on/off | hold BOOT: receiver";
  int hint_x = W - 20 - text_w(f9, hint);
  char note[96];
  snprintf(note, sizeof(note), "%s", !running ? "PAUSED | pick variants, then tap TRANSMIT"
                                    : txui_slow() ? "ON AIR | CH 6 | SLOW: each path every 5 s"
                                                  : "ON AIR | CH 6 | bench test only");
  fit_text(note, sizeof(note), f9, hint_x - 16 - TABLE_X);
  text(f9, note, TABLE_X, 524, BLACK);
  text(f9, hint, hint_x, 524, BLACK);
}

static void draw_diagnostics() {
  epd_hl_set_all_white(&s_hl);
  const GFXfont* f9 = &FreeSansBold9pt7b;
  const GFXfont* f12 = &FreeSansBold12pt7b;
  const GFXfont* f18 = &FreeSansBold18pt7b;

  // Header banner
  rect(0, 0, W, 68, BLACK);
  text(f18, "SYSTEM", 24, 46, WHITE);

  // [ CLOSE ] button in header
  int cl_w = 100, cl_h = 42, cl_x = W - 120, cl_y = 13;
  rect(cl_x, cl_y, cl_w, cl_h, WHITE);
  box(cl_x, cl_y, cl_w, cl_h, BLACK);
  text(f12, "CLOSE", cl_x + (cl_w - text_w(f12, "CLOSE")) / 2, cl_y + 28, BLACK);

  // Section 1: DISPLAY BACKLIGHT -- the control people actually reach for
  text(f12, "BACKLIGHT", 24, DG_BL_BTN_Y - 8, BLACK);
  BlMode bm = periph_bl_get_mode();
  struct BlBtn { const char* lbl; BlMode m; int x; int w; } bl_btns[] = {
    { "AUTO", BL_AUTO, 24, 150 },
    { "ON", BL_ON, 184, 130 },
    { "OFF", BL_OFF, 324, 90 }
  };
  int bl_btn_y = DG_BL_BTN_Y, bl_btn_h = DG_BL_BTN_H;
  for (const auto& bb : bl_btns) {
    bool active = (bm == bb.m);
    if (active) {
      rect(bb.x, bl_btn_y, bb.w, bl_btn_h, BLACK);
      text(f9, bb.lbl, bb.x + (bb.w - text_w(f9, bb.lbl)) / 2, bl_btn_y + 22, WHITE);
    } else {
      box(bb.x, bl_btn_y, bb.w, bl_btn_h, BLACK);
      text(f9, bb.lbl, bb.x + (bb.w - text_w(f9, bb.lbl)) / 2, bl_btn_y + 22, BLACK);
    }
  }
  // Duty cycle stepper
  box(430, bl_btn_y, 40, bl_btn_h, BLACK);
  text(f12, "-", 430 + (40 - text_w(f12, "-")) / 2, bl_btn_y + 23, BLACK);
  uint8_t duty = periph_bl_get_duty();
  char duty_str[32]; snprintf(duty_str, sizeof(duty_str), "%u%%", (duty * 100) / 255);
  box(478, bl_btn_y, 140, bl_btn_h, BLACK);
  text(f9, duty_str, 478 + (140 - text_w(f9, duty_str)) / 2, bl_btn_y + 22, BLACK);
  box(626, bl_btn_y, 40, bl_btn_h, BLACK);
  text(f12, "+", 626 + (40 - text_w(f12, "+")) / 2, bl_btn_y + 23, BLACK);

  char sun_buf[64];
  double sun_el = periph_sun_elevation();
  // AUTO lights the panel after sunset at the home position.
  snprintf(sun_buf, sizeof(sun_buf), "Sun %+.0f deg | %s | light %s",
           sun_el, periph_is_after_sundown() ? "night" : "day",
           periph_bl_is_active() ? "on" : "off");
  text(f9, sun_buf, 680, bl_btn_y + 22, GREY);

  rect(24, DG_BL_BTN_Y + DG_BL_BTN_H + 10, W - 48, 1, LIGHT);

  // Section 2: MODE & POWER
  text(f12, "MODE & POWER", 24, DG_MODE_BTN_Y - 8, BLACK);
  int tx_btn_w = DG_TXB_W, tx_btn_h = DG_MODE_BTN_H, tx_btn_x = 24, tx_btn_y = DG_MODE_BTN_Y;
  box(tx_btn_x, tx_btn_y, tx_btn_w, tx_btn_h, BLACK);
  box(tx_btn_x + 1, tx_btn_y + 1, tx_btn_w - 2, tx_btn_h - 2, BLACK);
  text(f9, "SWITCH TO TEST BEACON", tx_btn_x + (tx_btn_w - text_w(f9, "SWITCH TO TEST BEACON")) / 2, tx_btn_y + 23, BLACK);
  int pwr_btn_x = DG_PWR_X, pwr_btn_y = DG_MODE_BTN_Y, pwr_btn_w = DG_PWR_W, pwr_btn_h = DG_MODE_BTN_H;
  rect(pwr_btn_x, pwr_btn_y, pwr_btn_w, pwr_btn_h, BLACK);
  text(f9, "POWER OFF", pwr_btn_x + (pwr_btn_w - text_w(f9, "POWER OFF")) / 2, pwr_btn_y + 23, WHITE);
  // The saved drone history: how much, and the way to clear it (confirmed).
  box(DG_CLR_X, DG_MODE_BTN_Y, DG_CLR_W, DG_MODE_BTN_H, BLACK);
  box(DG_CLR_X + 1, DG_MODE_BTN_Y + 1, DG_CLR_W - 2, DG_MODE_BTN_H - 2, BLACK);
  text(f9, "CLEAR HISTORY", DG_CLR_X + (DG_CLR_W - text_w(f9, "CLEAR HISTORY")) / 2, DG_MODE_BTN_Y + 23, BLACK);
  {
    char hb[64]; history_words(hb, sizeof(hb));
    int hx = DG_CLR_X + DG_CLR_W + 14;
    fit_text(hb, sizeof(hb), f9, W - 24 - hx);
    text(f9, hb, hx, DG_MODE_BTN_Y + 23, GREY);
  }

  rect(24, DG_MODE_BTN_Y + DG_MODE_BTN_H + 10, W - 48, 1, LIGHT);

  // Section 3: WI-FI (plan §4.3): the state in words, sticky until the next
  // change -- including the last failure's reason -- and its four buttons.
  text(f12, "WI-FI", 24, DG_WIFI_BTN_Y - 8, BLACK);
  {
    char st[96]; net_status_line(st, sizeof(st));
    // A phone on BLE pauses the automatic windows (its own data takes over).
    if (net_is_paused() && !strstr(st, "paused")) {
      size_t l = strlen(st); snprintf(st + l, sizeof(st) - l, " | Wi-Fi paused: phone connected");
    }
    int sx = 24 + text_w(f12, "WI-FI") + 16;
    fit_text(st, sizeof(st), f9, W - 24 - sx);
    bool bad = net_get_state() == NET_STATE_FAILED;
    text(f9, st, sx, DG_WIFI_BTN_Y - 9, bad ? BLACK : GREY);
  }
  char mode_lbl[24];
  NetMode nm = net_get_mode();
  snprintf(mode_lbl, sizeof(mode_lbl), "MODE: %s", nm == NET_MODE_OFF ? "OFF" : nm == NET_MODE_STAY ? "STAY" : "SYNC");
  struct WfBtn { const char* lbl; int x; int w; } wf[4] = {
    { "NETWORKS", DG_WF_X0, DG_WF_W0 }, { mode_lbl, DG_WF_X1, DG_WF_W1 },
    { "SYNC NOW", DG_WF_X2, DG_WF_W2 }, { "UPDATE MAP", DG_WF_X3, DG_WF_W3 },
  };
  for (const auto& w : wf) {
    box(w.x, DG_WIFI_BTN_Y, w.w, DG_WIFI_BTN_H, BLACK);
    box(w.x + 1, DG_WIFI_BTN_Y + 1, w.w - 2, DG_WIFI_BTN_H - 2, BLACK);
    text(f9, w.lbl, w.x + (w.w - text_w(f9, w.lbl)) / 2, DG_WIFI_BTN_Y + 24, BLACK);
  }
  if (s_diag_note[0]) {
    char nb[64]; snprintf(nb, sizeof(nb), "%s", s_diag_note);
    int nx = DG_WF_X3 + DG_WF_W3 + 14;
    fit_text(nb, sizeof(nb), f9, W - 24 - nx);
    text(f9, nb, nx, DG_WIFI_BTN_Y + 24, GREY);
  }

  // The ADS-B query radius, and whether the conflict watch is running;
  // the map area, and what it costs in flash (the plan G's tile sync made).
  struct Step { const char* lbl; int y; char val[16]; } steps[2] = {
    { "ADS-B RADIUS", DG_ADSB_Y, "" }, { "MAP AREA", DG_MAP_Y, "" } };
  snprintf(steps[0].val, sizeof(steps[0].val), "%u km", (unsigned)net_get_adsb_radius_km());
  snprintf(steps[1].val, sizeof(steps[1].val), "%u km", (unsigned)net_get_tile_radius_km());
  for (const auto& st : steps) {
    text(f9, st.lbl, 24, st.y + 21, BLACK);
    box(DG_STEP_X, st.y, 40, DG_STEP_H, BLACK);
    text(f12, "-", DG_STEP_X + (40 - text_w(f12, "-")) / 2, st.y + 22, BLACK);
    box(DG_STEP_X + 44, st.y, 90, DG_STEP_H, BLACK);
    text(f9, st.val, DG_STEP_X + 44 + (90 - text_w(f9, st.val)) / 2, st.y + 21, BLACK);
    box(DG_STEP_X + 138, st.y, 40, DG_STEP_H, BLACK);
    text(f12, "+", DG_STEP_X + 138 + (40 - text_w(f12, "+")) / 2, st.y + 22, BLACK);
  }
  {
    const int sx = DG_STEP_X + 196, sw = W - 24 - sx;
    char st[112];
    traffic_summary(&g_traffic_result, st, sizeof(st));
    fit_text(st, sizeof(st), f9, sw);
    bool off = !g_traffic_result.have_data || g_traffic_result.stale;
    text(f9, st, sx, DG_ADSB_Y + 21, off ? BLACK : GREY);
    net_tile_plan_line(st, sizeof(st));
    if (!st[0]) snprintf(st, sizeof(st), "Map: %u km, sized at the first UPDATE MAP", (unsigned)net_get_tile_radius_km());
    fit_text(st, sizeof(st), f9, sw);
    text(f9, st, sx, DG_MAP_Y + 21, GREY);
  }

  rect(24, DG_MAP_Y + DG_STEP_H + 8, W - 48, 1, LIGHT);

  // Section 4: HARDWARE RESOURCE TELEMETRY
  const int hw_y = DG_MAP_Y + DG_STEP_H + 30;
  text(f12, "HARDWARE", 24, hw_y, BLACK);
  int t_y = hw_y + 20;
  // Col 1: ESP32 Memory
  char m1[48], m2[48];
  snprintf(m1, sizeof(m1), "PSRAM: %lu of %lu KB free", (unsigned long)(ESP.getFreePsram() / 1024), (unsigned long)(ESP.getPsramSize() / 1024));
  snprintf(m2, sizeof(m2), "Heap: %lu KB free", (unsigned long)(ESP.getFreeHeap() / 1024));
  text(f9, m1, 24, t_y, BLACK);
  text(f9, m2, 24, t_y + 18, BLACK);

  // Col 2: Power & RTC
  char p1[48], p2[48];
  // The capacity the gauge counts against is the figure to trust the
  // percentage by: 1500 mAh once the boot check has configured it.
  int mv = periph_batt_mv();
  int cap = periph_batt_full_mah();
  char pct[16] = "--";
  if (s_batt >= 0) snprintf(pct, sizeof(pct), "%d%%", s_batt);
  if (mv > 0 && cap > 0 && periph_gauge_configured())
    snprintf(p1, sizeof(p1), "Battery: %s, %d.%02d V, %d mAh", pct, mv / 1000, (mv % 1000) / 10, cap);
  else if (mv > 0) snprintf(p1, sizeof(p1), "Battery: %s, %d.%02d V (gauge not set up)", pct, mv / 1000, (mv % 1000) / 10);
  else snprintf(p1, sizeof(p1), "Battery: no gauge");
  fit_text(p1, sizeof(p1), f9, 660 - 340 - 12);   // column 3 starts at x=660
  if (periph_has_utc_time()) {
    uint16_t cy; uint8_t cm, cd, ch, cmi, cs;
    periph_get_utc_time(&cy, &cm, &cd, &ch, &cmi, &cs);
    snprintf(p2, sizeof(p2), "Clock: %04u-%02u-%02u %02u:%02u:%02uZ%s", cy, cm, cd, ch, cmi, cs,
             net_is_clock_synced() ? " NTP" : "");
  } else {
    snprintf(p2, sizeof(p2), "Clock: not set");
  }
  text(f9, p1, 340, t_y, BLACK);
  text(f9, p2, 340, t_y + 18, BLACK);

  // Col 3: GPS & LittleFS Map Cache
  char g1[48], g2[48];
  if (periph_gps_fix()) snprintf(g1, sizeof(g1), "GPS: fix, %d satellites", periph_gps_sats());
  else if (periph_gps_detected()) snprintf(g1, sizeof(g1), "GPS: searching");
  else snprintf(g1, sizeof(g1), "GPS: not detected");
  double fs_used = LittleFS.usedBytes() / 1048576.0;
  double fs_tot  = LittleFS.totalBytes() / 1048576.0;
  if (fs_tot > 0) snprintf(g2, sizeof(g2), "Map storage: %.1f of %.1f MB used", fs_used, fs_tot);
  else snprintf(g2, sizeof(g2), "Map storage: not mounted");
  text(f9, g1, 660, t_y, BLACK);
  text(f9, g2, 660, t_y + 18, BLACK);

  rect(24, t_y + 26, W - 48, 1, LIGHT);

  // Section 5: PANEL (engineering): VCOM trim, and the greyscale strip.
  text(f12, "PANEL VOLTAGE (VCOM)", 24, DG_VCOM_BTN_Y - 8, BLACK);
  text(f9, "Match the VCOM on the cable label. Each grey a little lighter:", 24 + text_w(f12, "PANEL VOLTAGE (VCOM)") + 14,
       DG_VCOM_BTN_Y - 9, GREY);
  int b_y = DG_VCOM_BTN_Y, b_h = DG_VCOM_BTN_H;
  struct Vbtn { const char* lbl; int x; int w; } vbtns[] = {
    { "-50 mV", 24, 90 }, { "-10 mV", 124, 90 },
    { "+10 mV", 364, 90 }, { "+50 mV", 464, 90 }
  };
  for (const auto& vb : vbtns) {
    box(vb.x, b_y, vb.w, b_h, BLACK);
    text(f9, vb.lbl, vb.x + (vb.w - text_w(f9, vb.lbl)) / 2, b_y + 23, BLACK);
  }
  // Value center badge
  rect(224, b_y, 130, b_h, BLACK);
  char cur_v[32]; snprintf(cur_v, sizeof(cur_v), "%u mV", s_vcom);
  text(f12, cur_v, 224 + (130 - text_w(f12, cur_v)) / 2, b_y + 25, WHITE);

  rect(24, DG_VCOM_BTN_Y + DG_VCOM_BTN_H + 10, W - 48, 1, LIGHT);

  // 16-level greyscale strip, beside the VCOM buttons
  int strip_x = 568, strip_y = DG_VCOM_BTN_Y, swatch_w = 23, swatch_h = DG_VCOM_BTN_H;
  for (int i = 0; i < 16; i++) {
    int sx = strip_x + i * swatch_w;
    uint8_t shade = i * 17; // 0 to 255
    rect(sx, strip_y, swatch_w, swatch_h, shade);
    box(sx, strip_y, swatch_w, swatch_h, BLACK);
    (void)i;   // no numbers: at this size they would crowd the greys
  }

  // Footer note
  rect(0, 506, W, 34, WHITE);
  rect(0, 506, W, 1, BLACK);
  text(f9, "ORECCHINO | LILYGO T5 E-PAPER S3 PRO", 24, 528, BLACK);
}

// ---- side view: height against range, with the ceiling drawn in. The
// plan views say where; this says how high, and who is over the limit.
// With ADS-B it also answers how far apart vertically a drone and an
// aircraft are: a bracket joins each traffic pair, labelled in m and ft.
#define CEILING_M 120          // US Part 107 and EU open category: 120 m / 400 ft
#define SV_X0 90
#define SV_X1 650
#define SV_Y0 100
#define SV_Y1 440
#define SV_PANEL_X 690         // the right-hand list
#define SV_HCAP 1500.0         // the height scale grows for aircraft up to 1,500 m, then clips
static int  s_sv_px[TRK_MAX], s_sv_py[TRK_MAX];
static bool s_sv_on[TRK_MAX];

/// "Δ" drawn by hand (the fonts are ASCII), then `s`; returns the width.
static int delta_text(const GFXfont* f, const char* s, int x, int y, uint8_t c, bool draw = true) {
  if (draw) {
    epd_draw_line(x + 5, y - 11, x, y - 1, c, s_fb);
    epd_draw_line(x + 5, y - 11, x + 10, y - 1, c, s_fb);
    epd_draw_line(x, y - 1, x + 10, y - 1, c, s_fb);
    epd_draw_line(x + 5, y - 10, x + 1, y - 2, c, s_fb);   // a second stroke: bold like the font
    epd_draw_line(x + 5, y - 10, x + 9, y - 2, c, s_fb);
    text(f, s, x + 15, y, c);
  }
  return 15 + text_w(f, s);
}
/// "90 m / 300 ft" for a vertical separation (ft to the nearest 10).
static void sep_text(char* b, size_t n, double v) {
  long m = labs(iround(v)), ft = labs(iround(v / TRAFFIC_FT_TO_M / 10)) * 10;
  snprintf(b, n, "%ld m / %ld ft", m, ft);
}

static void draw_side() {
  const GFXfont* f9 = &FreeSansBold9pt7b;
  const GFXfont* f12 = &FreeSansBold12pt7b;
  rect(0, 72, W, 424, WHITE);
  memset(s_sv_on, 0, sizeof(s_sv_on));
  s_pac_n = 0;
  char b[64];
  int no_pos = 0, no_h = 0, ac_no_h = 0, ac_shown = 0;
  const int px0 = SV_PANEL_X;
  rect(px0 - 20, 90, 1, 390, BLACK);

  // ADS-B conflicts, most urgent first (the result is sorted); brackets
  // for those between a drone and an aircraft.
  const TrafficResult* tr = &g_traffic_result;
  const TrafficAlert* pairs[4]; int np = 0;
  for (int i = 0; i < tr->n && np < 4; i++) if (is_pair(&tr->alerts[i])) pairs[np++] = &tr->alerts[i];
  int nconf = tr->n;

  if (g_home_set) {
    // Where each aircraft goes: range from here, height above this board
    // (GNSS altitude minus the board's GNSS elevation), or, without the
    // board's elevation, the pair's own separation above its drone.
    double elev = g_traffic_observer.elev_m;
    double ac_d[TRAFFIC_MAX_AIRCRAFT], ac_h[TRAFFIC_MAX_AIRCRAFT];
    bool ac_on[TRAFFIC_MAX_AIRCRAFT];
    double far = 0; float top = CEILING_M;
    for (int k = 0; k < s_n; k++) {
      const Track* t = &g_tracks[s_order[k]];
      if (!t->has_pos) { no_pos++; continue; }
      if (isnan(t->height)) { no_h++; continue; }
      double d = ui_dist_m(g_home_lat, g_home_lon, t->lat, t->lon);
      if (d > far) far = d;
      if (t->height > top) top = t->height;
    }
    for (int i = 0; i < g_traffic_count; i++) {
      const TrafficAircraft* a = &g_traffic_ac[i];
      ac_on[i] = false;
      ac_d[i] = traffic_distance_m(g_home_lat, g_home_lon, a->lat, a->lon);
      ac_h[i] = NAN;
      const TrafficAlert* aal = traffic_alert_for_hex(tr, a->hex);
      if (traffic_alt_known(a->alt_geom_m) && isfinite(elev)) ac_h[i] = a->alt_geom_m - elev;
      else if (a->on_ground) ac_h[i] = 0;   // on the ground: at the axis, whatever the field's height
      else if (aal && !is_pair(aal) && isfinite(aal->vert_m)) ac_h[i] = aal->vert_m;   // LOW: its height above ground
      else {
        const TrafficAlert* al = traffic_alert_for_hex(tr, a->hex);
        int slot = is_pair(al) ? drone_slot(al->drone_id) : -1;
        if (slot >= 0 && isfinite(al->vert_m) && !isnan(g_tracks[slot].height))
          ac_h[i] = g_tracks[slot].height + al->vert_m;
      }
      if (!ac_drawn(a) || !isfinite(ac_d[i])) continue;   // aircraft appear only in an alert
      if (!isfinite(ac_h[i])) { ac_no_h++; continue; }
      ac_on[i] = true;
      if (ac_d[i] > far) far = ac_d[i];
      if (ac_h[i] > top) top = (float)min(ac_h[i], SV_HCAP);
    }
    double rmax = nice_scale(far > 0 ? far * 1.1 : 500);
    double hmax = ceil(top * 1.15 / 50.0) * 50.0;
    if (hmax < 150) hmax = 150;
    if (hmax > SV_HCAP) hmax = SV_HCAP;
    auto X = [&](double d) { return SV_X0 + (int)iround(d / rmax * (SV_X1 - SV_X0)); };
    auto Y = [&](double h) { return SV_Y1 - (int)iround((h < 0 ? 0 : h > hmax ? hmax : h) / hmax * (SV_Y1 - SV_Y0)); };
    // Above the ceiling: a dot screen, light enough for labels to sit on.
    int yc = Y(CEILING_M);
    for (int yy = SV_Y0 + 4; yy < yc - 2; yy += 8)
      for (int xx = SV_X0 + 4 + ((yy / 8) & 1) * 4; xx < SV_X1; xx += 8) rect(xx, yy, 2, 2, LIGHT);
    for (int xx = SV_X0; xx < SV_X1; xx += 16) rect(xx, yc - 1, 10, 3, BLACK);   // the ceiling, dashed
    // axes and scale
    rect(SV_X0, SV_Y1, SV_X1 - SV_X0, 2, BLACK);
    rect(SV_X0 - 2, SV_Y0, 2, SV_Y1 - SV_Y0 + 2, BLACK);
    lb_reset();
    for (int i = 0; i <= 2; i++) {
      double d = rmax * i / 2;
      if (d >= 1000) snprintf(b, sizeof(b), "%.1f km", d / 1000); else snprintf(b, sizeof(b), "%d m", (int)d);
      int x = X(d), w = text_w(f9, b);
      int lx = i == 0 ? x : i == 2 ? x - w : x - w / 2;
      text(f9, b, lx, SV_Y1 + 22, GREY);
      rect(x, SV_Y1, 2, 6, BLACK);
    }
    for (int i = 0; i <= 2; i++) {
      double h = hmax * i / 2;
      snprintf(b, sizeof(b), "%d m", (int)h);
      int yy = Y(h);
      text_r(f9, b, SV_X0 - 10, yy + (i == 2 ? 12 : i == 0 ? 0 : 6), GREY);
      lb_block(SV_X0 - 10 - text_w(f9, b), yy - 12, text_w(f9, b), 18);
    }
    snprintf(b, sizeof(b), "%d M / %d FT CEILING", CEILING_M, (int)lround(CEILING_M * 3.28084 / 100) * 100);
    int cw = text_w(f9, b);
    rect(SV_X1 - cw - 8, yc - 24, cw + 8, 18, WHITE);
    text(f9, b, SV_X1 - cw - 4, yc - 10, BLACK);
    lb_block(SV_X1 - cw - 8, yc - 24, cw + 8, 20);

    // Aircraft under the drones: diamonds, their time ghosts, and an arrow
    // for one above the scale (drawn at the top, its label says how high).
    const Clip clip = { SV_X0 + 2, SV_Y0 - 14, px0 - 24, SV_Y1 - 2 };
    uint8_t lvl_of[TRAFFIC_MAX_AIRCRAFT]; int idx_of[TRAFFIC_MAX_AIRCRAFT];
    for (int i = 0; i < g_traffic_count; i++) {
      if (!ac_on[i]) continue;
      const TrafficAircraft* a = &g_traffic_ac[i];
      int x = X(ac_d[i]), y = Y(ac_h[i]);
      bool above = ac_h[i] > hmax;
      if (above) y = SV_Y0 + AC_R + 6;
      if (y > clip.y1 - AC_R - 7) y = clip.y1 - AC_R - 7;   // low or on the ground: sitting on the axis
      if (!in_clip(clip, x, y, AC_R + 6)) continue;
      int gx[4], gy[4], ng = 0;
      if (!above && !a->on_ground && isfinite(a->gs_mps) && isfinite(a->track_deg)) {
        double dx, dy;
        traffic_offset_m(g_home_lat, g_home_lon, a->lat, a->lon, &dx, &dy);
        double vx = a->gs_mps * sin(a->track_deg * TRAFFIC_DEG), vy = a->gs_mps * cos(a->track_deg * TRAFFIC_DEG);
        for (int st = 1; st <= 4; st++) {
          double t = 15.0 * st, h = ac_h[i] + (isfinite(a->vs_mps) ? a->vs_mps * t : 0);
          double d = hypot(dx + vx * t, dy + vy * t);
          if (d > rmax || h > hmax || h < 0) continue;
          int qx = X(d), qy = Y(h);
          if (in_clip(clip, qx, qy, 3) && !lb_hits(qx - 3, qy - 3, 7, 7)) { gx[ng] = qx; gy[ng] = qy; ng++; }
        }
      }
      const TrafficAlert* al = traffic_alert_for_hex(tr, a->hex);
      uint8_t lvl = al ? al->level : (uint8_t)TRAFFIC_NONE;
      aircraft_mark(x, y, gx, gy, ng, NAN, lvl, ac_old(a), a->on_ground);
      if (above) tri(x - 6, y - AC_R - 19, 12, true);
      s_pac_x[s_pac_n] = x; s_pac_y[s_pac_n] = y;
      snprintf(s_pac_hex[s_pac_n], sizeof(s_pac_hex[0]), "%s", a->hex);
      lvl_of[s_pac_n] = lvl; idx_of[s_pac_n] = i;
      s_pac_n++; ac_shown++;
    }

    // Drones: selected and alerts last so they sit on top.
    int rows[TRK_MAX]; int nr = priority_rows(rows);
    for (int i = nr - 1; i >= 0; i--) {
      int k = rows[i];
      const Track* t = &g_tracks[s_order[k]];
      if (!t->has_pos || isnan(t->height)) continue;
      int x = X(ui_dist_m(g_home_lat, g_home_lon, t->lat, t->lon)), yy = Y(t->height);
      s_sv_px[k] = x; s_sv_py[k] = yy; s_sv_on[k] = true;
      bool stale = ui_stale(t, s_now), over = t->height > CEILING_M;
      uint8_t ink = stale ? GREY : BLACK;
      if (over) rect(x - 7, yy - 7, 14, 14, ink); else epd_fill_circle(x, yy, 6, ink, s_fb);
      if (k == s_sel) epd_draw_circle(x, yy, 13, BLACK, s_fb);
      if (ui_danger(t, s_now) || alert_for_drone(t)) epd_draw_circle(x, yy, 17, BLACK, s_fb);
    }
    for (int k = 0; k < s_n; k++) if (s_sv_on[k]) lb_block(s_sv_px[k] - 10, s_sv_py[k] - 10, 20, 20);
    for (int j = 0; j < s_pac_n; j++) lb_block(s_pac_x[j] - AC_R - 1, s_pac_y[j] - AC_R - 1, 2 * AC_R + 3, 2 * AC_R + 3);

    // A bracket from each paired drone to its aircraft, labelled with the
    // separation the rules measured (GNSS against GNSS), in m and ft.
    for (int p = 0; p < np; p++) {
      const TrafficAlert* al = pairs[p];
      int slot = drone_slot(al->drone_id), k = -1, j = -1;
      for (int q = 0; q < s_n; q++) if (s_order[q] == slot) k = q;
      for (int q = 0; q < s_pac_n; q++) if (!strcmp(s_pac_hex[q], al->hex)) j = q;
      if (k < 0 || !s_sv_on[k] || j < 0 || al->on_ground) continue;   // the list says "on the ground"
      int xd = s_sv_px[k], yd = s_sv_py[k], xa = s_pac_x[j], ya = s_pac_y[j];
      int bx = (xd + xa) / 2;
      if (abs(xa - xd) < 40) bx = min(xd, xa) - 24;   // stacked: beside them, not through them
      if (bx < SV_X0 + 6) bx = max(xd, xa) + 24;
      int y0 = min(yd, ya), y1 = max(yd, ya);
      if (al->on_ground) snprintf(b, sizeof(b), "on the ground");
      else if (!isfinite(al->vert_m) || al->height_unknown) snprintf(b, sizeof(b), "height unknown");
      else sep_text(b, sizeof(b), al->vert_m);
      bool delta = isfinite(al->vert_m) && !al->height_unknown && !al->on_ground;
      if (delta && y1 - y0 >= 8) {
        rect(bx - 1, y0, 2, y1 - y0, BLACK);
        rect(bx - 7, y0, 14, 2, BLACK);
        rect(bx - 7, y1 - 1, 14, 2, BLACK);
      }
      int w = (delta ? delta_text(f9, b, 0, 0, WHITE, false) : text_w(f9, b)) + 12, lx, ly;
      if (!lb_place(bx, (y0 + y1) / 2, w, 22, clip.x0, clip.y0, clip.x1, clip.y1, &lx, &ly, 8)) continue;
      rect(lx, ly, w, 22, BLACK);
      if (delta) delta_text(f9, b, lx + 6, ly + 16, WHITE); else text(f9, b, lx + 6, ly + 16, WHITE);
    }

    // Labels: the selected drone and alerts first, then the rest where they
    // fit, then the aircraft (warnings first).
    for (int pass = 0; pass < 2; pass++) {
      for (int i = 0; i < nr; i++) {
        int k = rows[i];
        if (!s_sv_on[k]) continue;
        const Track* t = &g_tracks[s_order[k]];
        bool first = (k == s_sel) || ui_danger(t, s_now) || alert_for_drone(t);
        if (first != (pass == 0)) continue;
        snprintf(b, sizeof(b), "%s %dm", label_id(k), (int)t->height);
        int w = text_w(f9, b) + 6, lx, ly;
        if (!lb_place(s_sv_px[k], s_sv_py[k], w, 16, clip.x0, clip.y0, clip.x1, clip.y1, &lx, &ly)) continue;   // clear of the panel rule
        bool stale = ui_stale(t, s_now);
        rect(lx, ly, w, 16, WHITE);
        box(lx, ly, w, 16, stale ? GREY : BLACK);
        text(f9, b, lx + 3, ly + 12, stale ? GREY : BLACK);
      }
    }
    for (int lv = TRAFFIC_WARNING; lv >= TRAFFIC_NONE; lv--)
      for (int j = 0; j < s_pac_n; j++)
        if (lvl_of[j] == lv) aircraft_label(&g_traffic_ac[idx_of[j]], lvl_of[j], s_pac_x[j], s_pac_y[j], clip);
  } else {
    const char* l[3] = { "NO POSITION", "The side view plots range from this", "board: it needs a GPS fix or the app." };
    text(f12, l[0], SV_X0 + (SV_X1 - SV_X0 - text_w(f12, l[0])) / 2, 250, BLACK);
    for (int i = 1; i < 3; i++) text(f9, l[i], SV_X0 + (SV_X1 - SV_X0 - text_w(f9, l[i])) / 2, 254 + 26 * i, GREY);
  }

  // Right panel: traffic pairs while an alert lasts, else who is above the
  // ceiling; then the feed; then what the marks mean and what is missing.
  const int pw = W - 20 - px0, ybot = 482;
  int y;
  if (nconf) {
    // Each conflict leads with its action, inverted, then its geometry.
    text(f12, "ADS-B ALERTS", px0, 118, BLACK);
    y = 130;
    int shown = 0;
    for (int p = 0; p < nconf && shown < 3; p++) {
      const TrafficAlert* al = &tr->alerts[p];
      int la = text_para(f9, al->action, 0, 0, 18, pw - 16, WHITE, 2, false);
      int h = 12 + la * 18 + 24;
      if (y + h > 400 && shown) break;
      rect(px0, y, pw, h, BLACK);
      text_para(f9, al->action, px0 + 8, y + 18, 18, pw - 16, WHITE, 2);
      // Its geometry in short: "Δ 90 m above, 900 m NE", "on ground, 700 m S".
      char hz[16]; dist_text(hz, sizeof(hz), al->horiz_m < 1000 ? 10.0 * iround(al->horiz_m / 10) : al->horiz_m);
      const char* brg = traffic_compass8(al->bearing_deg);
      bool low = !is_pair(al);
      if (isfinite(al->vert_m) && !al->height_unknown && !al->on_ground) {
        if (low) snprintf(b, sizeof(b), "%ld m up, %s %s", labs(iround(al->vert_m)), hz, brg);
        else snprintf(b, sizeof(b), "%ld m %s, %s %s", labs(iround(al->vert_m)), al->vert_m >= 0 ? "above" : "below", hz, brg);
        fit_text(b, sizeof(b), f9, pw - 32);
        delta_text(f9, b, px0 + 8, y + h - 10, WHITE);
      } else {
        snprintf(b, sizeof(b), "%s, %s %s", al->on_ground ? "on ground" : "height unknown", hz, brg);
        fit_text(b, sizeof(b), f9, pw - 16);
        text(f9, b, px0 + 8, y + h - 10, WHITE);
      }
      y += h + 6;
      shown++;
    }
    if (nconf > shown) { snprintf(b, sizeof(b), "+ %d more", nconf - shown); text(f9, b, px0, y + 14, BLACK); y += 22; }
  } else {
    int above[TRK_MAX], na = 0;
    for (int k = 0; k < s_n; k++) {
      const Track* t = &g_tracks[s_order[k]];
      if (!ui_stale(t, s_now) && !isnan(t->height) && t->height > CEILING_M) above[na++] = k;
    }
    for (int i = 1; i < na; i++)
      for (int j = i; j > 0 && g_tracks[s_order[above[j]]].height > g_tracks[s_order[above[j - 1]]].height; j--) {
        int x = above[j]; above[j] = above[j - 1]; above[j - 1] = x;
      }
    snprintf(b, sizeof(b), "ABOVE %d M", CEILING_M);
    text(f12, b, px0, 118, BLACK);
    y = 132;
    const int SV_LIST = tr->have_data ? 3 : 4;
    for (int i = 0; i < na && i < SV_LIST; i++) {
      const Track* t = &g_tracks[s_order[above[i]]];
      rect(px0, y, pw, 34, BLACK);
      snprintf(b, sizeof(b), "%d m", (int)t->height);
      text_r(f12, b, W - 30, y + 25, WHITE);
      char id[32]; snprintf(id, sizeof(id), "%s", label_id(above[i]));
      fit_text(id, sizeof(id), f12, W - 30 - text_w(f12, b) - 16 - (px0 + 10));
      text(f12, id, px0 + 10, y + 25, WHITE);
      y += 40;
    }
    if (na > SV_LIST) { snprintf(b, sizeof(b), "+ %d more", na - SV_LIST); text(f9, b, px0, y + 14, BLACK); y += 22; }
    if (!na) { text(f9, "none of the live contacts", px0, y + 14, GREY); y += 22; }
  }
  // Whether the conflict watch is running, in the rules' words.
  if (y + 50 <= ybot) {
    char st[112]; traffic_summary(tr, st, sizeof(st));
    y += 20 * text_para(f9, st, px0, y + 26, 20, pw, tr->stale || !tr->have_data ? BLACK : GREY, 3) + 12;
  }
  y += 6;
  if (ac_shown && y + 70 <= ybot) {
    y += 20 * text_para(f9, "Diamonds: aircraft in a conflict; dots 15 s apart show where each is heading.",
                        px0, y + 16, 20, pw, GREY, (ybot - y - 40) / 20) + 6;
  } else if (!nconf && y + 60 <= ybot) {
    y += 20 * text_para(f9, "Heights as each drone sends them: above take-off or above ground, which is not the same.",
                        px0, y + 16, 20, pw, GREY, (ybot - y - 40) / 20) + 6;
  }
  if ((no_pos || no_h) && y + 40 <= ybot) {
    text(f9, "not plotted:", px0, y + 16, GREY);
    b[0] = 0;
    if (no_pos) snprintf(b, sizeof(b), "%d no position", no_pos);
    if (no_h) snprintf(b + strlen(b), sizeof(b) - strlen(b), "%s%d no height", b[0] ? ", " : "", no_h);
    fit_text(b, sizeof(b), f9, pw);
    text(f9, b, px0, y + 36, GREY);
  }
}

// ---- glance mode: after GLANCE_IDLE_MS without a touch or a button, one
// screen meant to be read across a room -- how many are in range, the
// nearest, and a black band only when there is an alert. E-paper holds it
// at no power; it refreshes only when what it says changes: at once for an
// alert (an emergency, a TFR, a bad signature, an ADS-B action, the conflict
// watch going stale or off), at most once a minute for the routine figures
// (how many, the nearest one's range, bearing and height), which a moving
// drone would otherwise change every few seconds.
#define GLANCE_IDLE_MS    300000UL
#define GLANCE_ROUTINE_MS 60000UL
static bool     s_glance = false;
static uint32_t s_last_input_ms = 0;
static uint32_t s_glance_sig = 0;       // everything the glance shows
static uint32_t s_glance_urgent = 0;    // the alert part of it
static uint32_t s_glance_drawn_ms = 0;

/// Text at an integer scale: every glyph pixel becomes a scale x scale block.
/// Blocky by design -- the point is legibility at distance, not finesse.
static int text_big(const GFXfont* f, const char* s, int x, int y, int scale, bool draw) {
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
            rect(x + (g->xOffset + xx) * scale, y + (g->yOffset + yy) * scale, scale, scale, BLACK);
    }
    x += g->xAdvance * scale;
  }
  return x - x0;
}

struct Glance { int live, emerg, tfr, bad; bool near; double near_m, near_brg; float near_h; };
static void glance_facts(Glance* g) {
  memset(g, 0, sizeof(*g));
  for (int i = 0; i < TRK_MAX; i++) {
    const Track* t = &g_tracks[i];
    if (!t->used || ui_stale(t, s_now)) continue;
    g->live++;
    if (t->status == 3) g->emerg++;
    if (t->in_tfr) g->tfr++;
    if (t->auth_state == 4) g->bad++;
    if (g_home_set && t->has_pos) {
      double d = ui_dist_m(g_home_lat, g_home_lon, t->lat, t->lon);
      if (!g->near || d < g->near_m) {
        g->near = true; g->near_m = d;
        g->near_brg = ui_bearing(g_home_lat, g_home_lon, t->lat, t->lon); g->near_h = t->height;
      }
    }
  }
}
/// Glance's conflict words: the band leads with the most urgent alert's
/// action ("GIVE WAY: DESCEND AND LAND D9A03"), `lo` counts any others; the
/// line says whether the conflict watch is running (no aircraft, no counts
/// of them, no data age that would redraw the glance every few seconds:
/// staleness has its own words).
static void glance_traffic(char* band, size_t nb, char* line, size_t nl, char* lo = nullptr, size_t nlo = 0) {
  band[0] = line[0] = 0;
  if (lo && nlo) lo[0] = 0;
  const TrafficResult* r = &g_traffic_result;
  if (r->n) snprintf(band, nb, "%s", r->alerts[0].action);
  if (r->n > 1) {
    char* d = lo && nlo ? lo : band; size_t dn = lo && nlo ? nlo : nb; size_t l = strlen(d);
    snprintf(d + l, dn - l, "%s%d MORE ADS-B ALERT%s", l ? " | " : "", r->n - 1, r->n > 2 ? "S" : "");
  }
  unsigned conf = 0, low = 0;   // as traffic_summary counts them
  for (int i = 0; i < r->n; i++) { if (is_pair(&r->alerts[i])) conf++; else low++; }
  if (!r->have_data) snprintf(line, nl, "CONFLICT WATCH OFF: no ADS-B source");
  else if (r->stale) snprintf(line, nl, "TRAFFIC DATA STALE");
  else if (!r->n) snprintf(line, nl, "conflict watch on, no ADS-B conflicts");
  else if (!conf) snprintf(line, nl, "conflict watch on, low traffic");
  else snprintf(line, nl, "conflict watch on, %u ADS-B conflict%s%s", conf, conf == 1 ? "" : "s", low ? ", low traffic" : "");
}
/// The alert part of the glance: what must reach the panel at once.
static uint32_t glance_urgent_signature() {
  Glance g; glance_facts(&g);
  uint32_t h = 2166136261u;
  auto mix = [&](uint32_t v) { h ^= v; h *= 16777619u; };
  mix(g.emerg); mix(g.tfr); mix(g.bad);
  char tb[96], tl[96]; glance_traffic(tb, sizeof(tb), tl, sizeof(tl));
  for (const char* p = tb; *p; p++) mix((uint8_t)*p);
  for (const char* p = tl; *p; p++) mix((uint8_t)*p);
  return h;
}
/// Everything the glance shows: the alert part plus the routine figures.
static uint32_t glance_signature() {
  Glance g; glance_facts(&g);
  uint32_t h = glance_urgent_signature();
  auto mix = [&](uint32_t v) { h ^= v; h *= 16777619u; };
  mix(g.live); mix(g.near);
  if (g.near) { mix((uint32_t)(g.near_m / 25)); mix((uint32_t)(g.near_brg / 22.5)); mix(isnan(g.near_h) ? 0xFFFF : (int)g.near_h / 10); }
  return h;
}

static void draw_glance() {
  const GFXfont* f24 = &FreeSansBold24pt7b;
  const GFXfont* f18 = &FreeSansBold18pt7b;
  const GFXfont* f12 = &FreeSansBold12pt7b;
  Glance g; glance_facts(&g);
  epd_hl_set_all_white(&s_hl);
  char b[96];
  snprintf(b, sizeof(b), "%d", g.live);
  const int scale = 6, base = 300;
  int nw = text_big(f24, b, 40, base, scale, true);
  int col = 40 + nw + 40;
  text(f24, g.live == 1 ? "DRONE IN RANGE" : g.live ? "DRONES IN RANGE" : "NO DRONES IN RANGE", col, 170, BLACK);
  if (g.near) {
    char r[16];
    if (g.near_m < 1000) snprintf(r, sizeof(r), "%d m", (int)g.near_m);
    else snprintf(r, sizeof(r), "%.1f km", g.near_m / 1000);
    if (isnan(g.near_h)) snprintf(b, sizeof(b), "nearest %s %s", r, cardinal((float)g.near_brg));
    else snprintf(b, sizeof(b), "nearest %s %s, %d m high", r, cardinal((float)g.near_brg), (int)g.near_h);
  } else {
    snprintf(b, sizeof(b), "%s", g.live ? "no position to range from" : "listening on Wi-Fi and Bluetooth");
  }
  fit_text(b, sizeof(b), f18, W - col - 24);
  text(f18, b, col, 226, GREY);
  // The band: only what is true, in words.
  b[0] = 0;
  auto add = [&](int n, const char* one, const char* many) {
    if (!n) return;
    size_t l = strlen(b);
    snprintf(b + l, sizeof(b) - l, "%s%d %s", l ? " | " : "", n, n == 1 ? one : many);
  };
  char tb[96], tl[96], tlo[64]; glance_traffic(tb, sizeof(tb), tl, sizeof(tl), tlo, sizeof(tlo));
  add(g.emerg, "EMERGENCY", "EMERGENCIES");
  add(g.tfr, "IN A TFR", "IN TFRS");
  add(g.bad, "ID SIG INVALID", "ID SIGS INVALID");
  if (tlo[0]) { size_t l = strlen(b); snprintf(b + l, sizeof(b) - l, "%s%s", l ? " | " : "", tlo); }
  if (tl[0]) {
    fit_text(tl, sizeof(tl), f18, W - col - 24);
    text(f18, tl, col, 266, GREY);
  }
  if (tb[0]) {
    // An ADS-B conflict: its action is the band's first line, the rest (the
    // drones' own alerts, other conflicts) the second, whole items only.
    const int bw = W - 80 - 48;
    rect(40, 330, W - 80, 96, BLACK);
    const GFXfont* af = text_w(f24, tb) <= bw ? f24 : f18;
    fit_text(tb, sizeof(tb), af, bw);
    text(af, tb, 64, b[0] ? 372 : 392, WHITE);
    while (b[0] && text_w(f18, b) > bw) {
      char* bar = strrchr(b, '|');
      if (!bar || bar - b < 3) { fit_text(b, sizeof(b), f18, bw); break; }
      bar[-1] = 0;
    }
    if (b[0]) text(f18, b, 64, 412, WHITE);
  } else if (b[0]) {
    // One line in 24 pt, else 18 pt, else two lines of 18 pt broken at a
    // " | " -- smaller, never cut.
    const int bw = W - 80 - 48;
    rect(40, 330, W - 80, 96, BLACK);
    if (text_w(f24, b) <= bw) text(f24, b, 64, 392, WHITE);
    else if (text_w(f18, b) <= bw) text(f18, b, 64, 388, WHITE);
    else {
      int cut = -1;
      for (char* p = strstr(b, " | "); p; p = strstr(p + 3, " | ")) {
        *p = 0; bool ok = text_w(f18, b) <= bw; *p = ' ';
        if (ok) cut = (int)(p - b); else break;
      }
      if (cut < 0) { fit_text(b, sizeof(b), f18, bw); text(f18, b, 64, 388, WHITE); }
      else {
        b[cut] = 0;
        char l2[96]; snprintf(l2, sizeof(l2), "%s", b + cut + 3);
        while (text_w(f18, l2) > bw) {   // whole items only, the least urgent go first
          char* bar = strrchr(l2, '|');
          if (!bar || bar - l2 < 3) { fit_text(l2, sizeof(l2), f18, bw); break; }
          bar[-1] = 0;
        }
        text(f18, b, 64, 370, WHITE);
        text(f18, l2, 64, 408, WHITE);
      }
    }
  }
  char when[24] = "";
  if (periph_has_utc_time()) {
    uint16_t cy; uint8_t cm, cd, ch, cmi, cs;
    periph_get_utc_time(&cy, &cm, &cd, &ch, &cmi, &cs);
    snprintf(when, sizeof(when), "as of %02u:%02uZ | ", ch, cmi);
  }
  snprintf(b, sizeof(b), "%stap anywhere for the board", when);
  text(f12, b, 40, 500, GREY);
  refresh(true);
}

/// Draw the glance now and remember what it showed and when.
static void glance_show(uint32_t now) {
  s_glance_sig = glance_signature();
  s_glance_urgent = glance_urgent_signature();
  s_glance_drawn_ms = now;
  draw_glance();
}

// ---- phone pairing (C8). NimBLE shows the passkey through rx_hook_pairing
// on its own task; the hook only records it and the loop draws. The code is
// fixed and published (every Orecchino uses it), and the screen says so.
extern "C" void rx_hook_pairing(uint32_t passkey, bool show) {
  s_pair_key = passkey;
  s_pair_show = show;
}
static bool s_pair_drawn = false;
static void draw_pairing_modal() {
  const GFXfont* f9 = &FreeSansBold9pt7b;
  const GFXfont* f12 = &FreeSansBold12pt7b;
  const GFXfont* f24 = &FreeSansBold24pt7b;
  const int mw = 600, mh = 290, mx = (W - mw) / 2, my = (H - mh) / 2;
  rect(mx, my, mw, mh, WHITE);
  for (int i = 0; i < 3; i++) box(mx + i, my + i, mw - 2 * i, mh - 2 * i, BLACK);
  rect(mx + 3, my + 3, mw - 6, 46, BLACK);
  const char* t = "PAIRING WITH A PHONE";
  text(f12, t, mx + (mw - text_w(f12, t)) / 2, my + 34, WHITE);
  const char* l1 = "Enter this code on the phone:";
  text(f12, l1, mx + (mw - text_w(f12, l1)) / 2, my + 92, BLACK);
  char code[12]; snprintf(code, sizeof(code), "%06lu", (unsigned long)(s_pair_key % 1000000UL));
  int cw = text_big(f24, code, 0, 0, 2, false);
  text_big(f24, code, mx + (mw - cw) / 2, my + 180, 2, true);
  const char* l2 = "Every Orecchino uses this code. It encrypts the link;";
  const char* l3 = "it does not prove which phone is on the other end.";
  text(f9, l2, mx + (mw - text_w(f9, l2)) / 2, my + 234, GREY);
  text(f9, l3, mx + (mw - text_w(f9, l3)) / 2, my + 256, GREY);
}

/// The right half of TABLE: the traffic card while a warning lasts or an
/// aircraft is chosen, else the plot (without a position: the contact card).
static void draw_right_panel() {
  const TrafficAircraft* ac; const TrafficAlert* al;
  if (traffic_card_pick(&ac, &al)) {
    rect(RECT_PLOT.x, RECT_PLOT.y, RECT_PLOT.width, RECT_PLOT.height, WHITE);
    memset(s_plot_on, 0, sizeof(s_plot_on));
    s_pac_n = 0;
    draw_traffic_card(ac, al);
  } else {
    draw_plot();
  }
}
/// TABLE's body after a tap there: exactly what draw_board draws below the
/// header (so nothing stale is left behind a card), as one partial refresh.
static void redraw_body() {
  draw_table();
  draw_right_panel();
  UiSummary fsm; ui_summarize(&fsm, s_now);
  draw_footer(fsm, nullptr);
  refresh_area(RECT_BODY, false);
  s_sig_prev = signature();
}

static void draw_board(bool force_full) {
  if (s_diag) {
    if (s_kb_modal) draw_keyboard();
    else if (s_wifi_modal) draw_wifi_screen();
    else draw_diagnostics();
    if (s_confirm_switch) draw_switch_modal();
    if (s_pair_show) draw_pairing_modal();
    s_pair_drawn = s_pair_show;
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
  } else if (s_side) {
    draw_header(sm, nullptr);
    draw_side();
    draw_footer(sm, "tap a mark: select | again: details");
  } else {
    draw_header(sm, nullptr);
    draw_table();
    draw_right_panel();
    draw_footer(sm, nullptr);
  }
  if (s_inspector) draw_inspector_modal();
  if (s_confirm_switch) draw_switch_modal();
  if (s_pair_show) draw_pairing_modal();
  s_pair_drawn = s_pair_show;
  refresh(force_full || (!s_map && sm.alert != s_alert_prev));
  s_alert_prev = sm.alert;
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
    // epdiy hands VCOM to the TPS65185 only at power-up, and the rails are
    // held on between redraws: drop them, or the redraw below (and every
    // one after it until the hold lapses) still runs at the old VCOM.
    if (s_epd_powered) { epd_poweroff(); s_epd_powered = false; }
    draw_board(true);
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
  const char* sub = (s_mode == UI_MODE_TX) ? "Remote ID test beacon | starting transmitter" : "Remote ID receiver | starting radios";
  int w_sub = text_w(&FreeSansBold12pt7b, sub);
  text(&FreeSansBold12pt7b, sub, (W - w_sub) / 2, 300, BLACK);
  epd_hl_update_screen(&s_hl, MODE_GC16, TEMP_C);
  epd_poweroff();
  s_ok = true;
  s_now = millis();
  s_last_full = s_now;
  s_last_input_ms = s_now;
  build_order();
  draw_board(true);
  s_sig_prev = signature();
  return true;
}

void ui_tick(uint32_t now, bool ble_ok, int batt_pct, int sync_files) {
  if (!s_ok) return;
  s_now = now; s_ble_ok = ble_ok; s_batt = batt_pct;
  struct EpdIdleGuard {
    uint32_t now;
    ~EpdIdleGuard() { epd_idle_check(now); }
  } idle_guard{now};

  if (s_epd_redo && (!s_epd_redo_once || (int32_t)(now - s_epd_redo_ms) >= (int32_t)EPD_REDO_MIN_MS)) {
    s_epd_redo = false; s_epd_redo_once = true; s_epd_redo_ms = now;
    epd_repaint_all();
  }

  bool syncing = sync_files >= 0;
  static bool was_syncing = false;
  if (syncing != was_syncing) { was_syncing = syncing; if (!syncing) { s_sig_prev = 0; } }

  // The IO48 key (PCA9535 IO1_2): hold to power off, LilyGO's convention for
  // this board. The PWR key cannot do it: it is not wired to the MCU.
  static bool io48_was = false; static uint32_t io48_down = 0, io48_poll = 0;
  bool io48 = io48_was;
  if (now - io48_poll >= 50) { io48_poll = now; io48 = periph_io48_key_down(); }  // one I2C read per 50 ms, not per pass
  if (io48 && !io48_was) { io48_down = now; }
  if (io48 && (now - io48_down >= 800)) {
    periph_power_off();
    return;
  }
  io48_was = io48;

  // BOOT button: tap = next contact / toggle TX, hold 2.0 s = power off (RX) or return to RX (TX)
  static bool was = false; static uint32_t down = 0; static uint8_t hold_level = 0;
  bool k = digitalRead(PIN_BOOT_BTN) == LOW;
  bool tap = false, hold = false;
  if (k && !was) { down = now; hold_level = 0; }
  if (k && hold_level == 0 && (now - down > 2000)) {
    hold_level = 1;
    hold = true;
    if (s_mode == UI_MODE_TX) {
      board_switch_mode(UI_MODE_RX);
      return;
    } else {
      periph_power_off();
      return;
    }
  }
  if (!k && was && hold_level == 0 && (now - down > 30)) tap = true;
  was = k;

  // Traffic (traffic.h), once a second in receiver mode. A NEW warning is
  // the one thing that interrupts whatever is on screen: a full GC16
  // refresh -- the black flash is the only motion e-paper can make -- and
  // three pulses of the front light, by day too (§8.3).
  if (s_mode == UI_MODE_RX && now - s_traffic_ms >= 1000) {
    if (ui_traffic_update(now)) {
      periph_bl_pulse(3);
      s_ac_hex[0] = 0;          // the card goes to the new warning
      build_order();
      if (s_glance) glance_show(now);
      else { draw_board(true); s_sig_prev = signature(); }
      return;
    }
  }
  // A phone is pairing (or stopped): show or clear the passkey at once.
  if (s_pair_show != s_pair_drawn && s_mode == UI_MODE_RX) {
    if (s_glance) { s_glance = false; s_last_input_ms = now; build_order(); }
    draw_board(false);
    s_sig_prev = signature();
    return;
  }

  // Glance mode: any touch or button only wakes the board, exactly as it was.
  bool home = periph_home_key();
  if (s_glance) {
    TouchEvent ge;
    bool touched = periph_poll_touch_event(&ge);
    if (tap || home || touched) {
      s_glance = false;
      s_last_input_ms = now;
      s_sig_prev = 0;
      build_order();
      draw_board(true);
      return;
    }
    static uint32_t last_glance = 0;
    if (now - last_glance >= 3000) {
      last_glance = now;
      if (glance_urgent_signature() != s_glance_urgent) glance_show(now);
      else if ((int32_t)(now - s_glance_drawn_ms) >= (int32_t)GLANCE_ROUTINE_MS &&
               glance_signature() != s_glance_sig) glance_show(now);
    }
    return;
  }
  if (tap || home) s_last_input_ms = now;

  // Capacitive round home button below display
  if (home && !s_diag && !s_inspector && !s_confirm_switch) {
    if (s_mode == UI_MODE_TX) {
      txui_set_running(!txui_running());
      s_sig_prev = 0;
      draw_board(false);
      return;
    }
    if (s_side) { s_side = false; }
    else if (s_map) { s_map = false; s_side = true; }
    else s_map = true;
    s_sig_prev = 0;
    draw_board(true);
    return;
  }

  // Asynchronous touch event consumption (produced on Core 0). A touch
  // released while the panel was refreshing is dropped: e-paper cannot show
  // what it did, and a queued double tap would type a letter twice.
  int tap_x = -1, tap_y = -1, drag_dx = 0, drag_dy = 0;
  TouchEvent evt;
  bool touched = periph_poll_touch_event(&evt);
  while (touched && (int32_t)(evt.ms - s_touch_ignore_ms) < 0) touched = periph_poll_touch_event(&evt);
  if (touched) s_last_input_ms = now;
  if (touched) {
    // Slop and drag discrimination:
    // Only the open map canvas supports drag/pan. In table, modals, diag,
    // inspector, and on controls (header tabs, footer buttons, zoom buttons, HUD),
    // any touch release is an instant tap!
    bool is_map_drag_area = (s_map && !s_diag && !s_confirm_switch && !s_inspector &&
                             evt.y > 92 && evt.y < 485 && evt.x < W - 65);

    if (evt.type == TOUCH_EVT_TAP || !is_map_drag_area) {
      tap_x = evt.x;
      tap_y = evt.y;
    } else if (evt.type == TOUCH_EVT_DRAG && is_map_drag_area) {
      drag_dx = evt.dx;
      drag_dy = evt.dy;
    }
  }

  // The keyboard: every tap is a key (or nothing); only CANCEL leaves it,
  // so a stray touch can never throw away a half-typed password.
  if (s_kb_modal) {
    if (tap_x >= 0) kb_tap(tap_x, tap_y);
    return;
  }

  // The Wi-Fi screens
  if (s_wifi_modal) {
    wifi_poll(now);
    if (tap_x < 0) return;
    if (s_wv == WV_JOINING) return;   // it stays until the join succeeds or fails
    if (s_wv == WV_RESULT) {
      if (tap_y >= 400 && tap_y < 464 && tap_x >= 48 && tap_x < 268 && !s_wifi_join_ok) {
        // TRY AGAIN: the keyboard, with what was typed still there
        snprintf(s_kb_ssid, sizeof(s_kb_ssid), "%s", s_wifi_ssid);
        s_kb_ssid_stage = false; s_kb_show = false; s_kb_du = 0;
        s_kb_modal = true; s_wv = WV_LIST;
        draw_board(true);
      } else if (tap_y >= 400 && tap_y < 464 && tap_x >= W - 268 && tap_x < W - 48) {
        s_wv = WV_LIST;
        net_scan_start();
        draw_board(false);
      }
      s_sig_prev = signature();
      return;
    }
    if (s_wv == WV_ACTION) {
      const int mw = 600, mh = 250, mx = (W - mw) / 2, my = (H - mh) / 2, by = my + mh - 24 - 64, bw = 170;
      if (tap_y >= by - 8 && tap_y < by + 72) {
        if (tap_x >= mx + 24 && tap_x < mx + 24 + bw) {
          wifi_start_join(s_wifi_ssid, nullptr);   // its saved password
        } else if (tap_x >= mx + 24 + bw + 15 && tap_x < mx + 24 + 2 * bw + 15) {
          bool gone = net_forget(s_wifi_ssid);
          snprintf(s_diag_note, sizeof(s_diag_note), gone ? "forgot %s" : "%s was not saved", s_wifi_ssid);
          s_wv = WV_LIST;
        } else if (tap_x >= mx + mw - 24 - bw && tap_x < mx + mw - 24) {
          s_wv = WV_LIST;
        } else {
          return;
        }
      } else if (tap_x < mx || tap_x > mx + mw || tap_y < my || tap_y > my + mh) {
        s_wv = WV_LIST;
      } else {
        return;
      }
      draw_board(false);
      s_sig_prev = signature();
      return;
    }
    // The list
    if (tap_y < WF_HEAD_H) {
      if (tap_x >= W - 24 - 2 * WF_BTN_W - 12 && tap_x < W - 24 - WF_BTN_W - 6) {   // SCAN
        net_scan_start();
        s_wifi_was_scanning = true;
        draw_board(false);
      } else if (tap_x >= W - 24 - WF_BTN_W - 6) {                                  // CLOSE
        s_wifi_modal = false;
        net_serial_setup(false);
        draw_board(true);
      }
      s_sig_prev = signature();
      return;
    }
    uint8_t count = 0;
    const ScannedNetwork* nets = net_get_scanned(&count);
    int pages = wifi_pages();
    if (pages > 1 && tap_y >= WF_PAGE_Y - 6 && tap_y < WF_PAGE_Y + 62) {
      if (tap_x < 24 + 160) s_wifi_page = (s_wifi_page + pages - 1) % pages;
      else if (tap_x >= W - 24 - 160) s_wifi_page = (s_wifi_page + 1) % pages;
      else return;
      draw_board(false);
      s_sig_prev = signature();
      return;
    }
    if (tap_y >= WF_ROW_Y0 && tap_y < WF_ROW_Y0 + WF_ROWS * WF_ROW_H && tap_x >= 24 && tap_x < W - 24) {
      int e = s_wifi_page * WF_ROWS + (tap_y - WF_ROW_Y0) / WF_ROW_H;
      if (e > count) return;
      s_kb_layer = 0; s_kb_shift = s_kb_caps = false; s_kb_show = false; s_kb_du = 0;
      if (e == count) {                                   // Other network...
        s_kb_ssid_stage = true;
        s_kb_buf[0] = 0; s_kb_ssid[0] = 0;
        s_kb_modal = true;
        draw_board(true);
      } else {
        snprintf(s_wifi_ssid, sizeof(s_wifi_ssid), "%s", nets[e].ssid);
        if (nets[e].saved) {
          s_wv = WV_ACTION;
          draw_board(false);
        } else if (!nets[e].auth_mode) {
          wifi_start_join(nets[e].ssid, "");              // open: no keyboard
          draw_board(false);
        } else {
          snprintf(s_kb_ssid, sizeof(s_kb_ssid), "%s", nets[e].ssid);
          s_kb_ssid_stage = false;
          s_kb_buf[0] = 0;
          s_kb_modal = true;
          draw_board(true);
        }
      }
      s_sig_prev = signature();
    }
    return;
  }

  // Confirmation Modal Touch Routing
  if (s_confirm_switch) {
    if (tap_x >= 0) {
      int mw = 580, mh = 260;
      int mx = (W - mw) / 2, my = (H - mh) / 2;
      int bw = 220, bh = 54, by = my + 164;
      int bx_ok = mx + 45;
      int bx_can = mx + mw - 45 - bw;
      if (tap_y >= by - 12 && tap_y <= by + bh + 16) {
        if (tap_x >= bx_ok - 15 && tap_x <= bx_ok + bw + 15) {
          if (s_target_mode == UI_TARGET_CLEAR_LOG) {
            rx_log_clear_all();   // under the core's lock; saved now; log_cleared to every host
            s_hist_cleared = true;
            s_confirm_switch = false;
            s_sig_prev = 0;
            draw_board(false);
            return;
          }
          if (s_target_mode == UI_TARGET_POWER_OFF) periph_power_off();
          else board_switch_mode(s_target_mode);
          return;
        } else if (tap_x >= bx_can - 15 && tap_x <= bx_can + bw + 15) {
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
      int btn_w = 200, btn_h = 44;
      int btn_y = my + mh - btn_h - 16;
      int btn1_x = mx + 60;
      int btn2_x = mx + mw - 60 - btn_w;

      if (tap_x >= mx + mw - 60 && tap_y >= my && tap_y <= my + 55) {
        s_inspector = false;
        s_sig_prev = 0;
        draw_board(false);
        return;
      } else if (tap_y >= btn_y - 12 && tap_y <= my + mh) {
        if (tap_x >= btn1_x - 15 && tap_x <= btn1_x + btn_w + 20) {
          s_inspector = false;
          s_map = true;
          s_side = false;   // may be opened from the side view
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
        } else if (tap_x >= btn2_x - 20 && tap_x <= btn2_x + btn_w + 15) {
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
      // VCOM buttons
      if (tap_y >= DG_VCOM_BTN_Y && tap_y <= DG_VCOM_BTN_Y + DG_VCOM_BTN_H) {
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
      // Backlight mode buttons
      if (tap_y >= DG_BL_BTN_Y && tap_y <= DG_BL_BTN_Y + DG_BL_BTN_H) {
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
      // Mode Switch: TX Beacon button (x: 24..344)
      if (tap_y >= DG_MODE_BTN_Y && tap_y <= DG_MODE_BTN_Y + DG_MODE_BTN_H && tap_x >= 24 && tap_x <= 24 + DG_TXB_W) {
        s_confirm_switch = true;
        s_target_mode = UI_MODE_TX;
        s_sig_prev = 0;
        draw_board(false);
        return;
      }
      // CLEAR HISTORY: confirm first; only CLEAR in the dialog clears
      if (tap_y >= DG_MODE_BTN_Y && tap_y <= DG_MODE_BTN_Y + DG_MODE_BTN_H && tap_x >= DG_CLR_X && tap_x < DG_CLR_X + DG_CLR_W) {
        s_confirm_switch = true;
        s_target_mode = UI_TARGET_CLEAR_LOG;
        s_sig_prev = 0;
        draw_board(false);
        return;
      }
      // Power Off button: confirm first, like the mode switch
      if (tap_y >= DG_MODE_BTN_Y && tap_y <= DG_MODE_BTN_Y + DG_MODE_BTN_H && tap_x >= DG_PWR_X && tap_x <= DG_PWR_X + DG_PWR_W) {
        s_confirm_switch = true;
        s_target_mode = UI_TARGET_POWER_OFF;
        s_sig_prev = 0;
        draw_board(false);
        return;
      }
      // ADS-B radius (5 km steps) and map area (1 km steps): [-] value [+]
      for (int r = 0; r < 2; r++) {
        int ry = r ? DG_MAP_Y : DG_ADSB_Y;
        if (tap_y < ry - 3 || tap_y > ry + DG_STEP_H + 3) continue;
        int dir = (tap_x >= DG_STEP_X - 6 && tap_x < DG_STEP_X + 42) ? -1
                : (tap_x >= DG_STEP_X + 136 && tap_x < DG_STEP_X + 184) ? 1 : 0;
        if (!dir) return;
        if (r == 0) {
          int km = net_get_adsb_radius_km() + dir * 5;
          net_set_adsb_radius_km((uint8_t)(km < 1 ? 1 : km));
        } else {
          int km = net_get_tile_radius_km() + dir;
          net_set_tile_radius_km((uint8_t)(km < 1 ? 1 : km));
          snprintf(s_diag_note, sizeof(s_diag_note), "Area changed: tap UPDATE MAP");
        }
        s_sig_prev = 0;
        draw_board(false);
        return;
      }
      // Wi-Fi row: NETWORKS, MODE, SYNC NOW, UPDATE MAP
      if (tap_y >= DG_WIFI_BTN_Y - 6 && tap_y <= DG_WIFI_BTN_Y + DG_WIFI_BTN_H + 6) {
        if (tap_x >= DG_WF_X0 && tap_x < DG_WF_X0 + DG_WF_W0) {
          s_wifi_modal = true; s_wv = WV_LIST; s_wifi_page = 0;
          net_serial_setup(true);   // the phone or Mac may provision over USB while this is open
          net_scan_start();
          s_wifi_was_scanning = true;
          s_sig_prev = 0;
          draw_board(true);
          return;
        } else if (tap_x >= DG_WF_X1 && tap_x < DG_WF_X1 + DG_WF_W1) {
          NetMode m = net_get_mode();
          NetMode nm = m == NET_MODE_OFF ? NET_MODE_SYNC : m == NET_MODE_SYNC ? NET_MODE_STAY : NET_MODE_OFF;
          net_set_mode(nm);
          snprintf(s_diag_note, sizeof(s_diag_note), "%s",
                   nm == NET_MODE_OFF ? "no Wi-Fi joins" : nm == NET_MODE_SYNC ? "joins to sync, then listens"
                   : "Remote ID Wi-Fi: its channel only");
        } else if (tap_x >= DG_WF_X2 && tap_x < DG_WF_X2 + DG_WF_W2) {
          net_sync_now();
          snprintf(s_diag_note, sizeof(s_diag_note), "sync asked for");
        } else if (tap_x >= DG_WF_X3 && tap_x < DG_WF_X3 + DG_WF_W3) {
          if (!g_home_set) snprintf(s_diag_note, sizeof(s_diag_note), "needs a position first");
          else { net_update_map(); snprintf(s_diag_note, sizeof(s_diag_note), "map update asked for"); }
        } else {
          return;
        }
        s_sig_prev = 0;
        draw_board(false);
        return;
      }
    }
    // Keep the Wi-Fi line (and the rest) current while SYSTEM is open.
    static uint32_t last_diag = 0, diag_sig = 0;
    if (now - last_diag >= 2000) {
      last_diag = now;
      char st[96]; net_status_line(st, sizeof(st));
      uint32_t h = 2166136261u;
      for (const char* p = st; *p; p++) { h ^= (uint8_t)*p; h *= 16777619u; }
      h ^= (uint32_t)net_get_mode() * 31u + net_is_clock_synced() + (periph_gps_fix() << 4) + ((uint32_t)periph_gps_sats() << 8);
      char hb[64]; history_words(hb, sizeof(hb));
      for (const char* p = hb; *p; p++) { h ^= (uint8_t)*p; h *= 16777619u; }
      if (h != diag_sig) { diag_sig = h; draw_board(false); }
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
      if (tap_y <= 70 && tap_x >= W - 170) {   // the RECEIVER button
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
        } else if (tap_x >= 752 && tap_x <= W - 12) {   // RATE: spec <-> slow (saved)
          txui_set_slow(!txui_slow());
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
  if (tap_x >= 0) {
    // Top bar view switcher tabs: [ TABLE | MAP | SIDE ]
    if (tap_y <= 92 && tap_x >= TAB_X - 12 && tap_x <= TAB_X + 3 * TAB_W + 8) {
      int want = (tap_x - TAB_X) / TAB_W;
      if (want < 0) want = 0;
      if (want > 2) want = 2;
      int cur = s_side ? 2 : s_map ? 1 : 0;
      if (want != cur) {
        s_map = want == 1;
        s_side = want == 2;
        s_sig_prev = 0;
        draw_board(true);
        return;
      }
    }
    if (s_side) {
      if (tap_y >= 485) {                                     // footer buttons
        if (tap_x >= W - 230 && tap_x <= W - 115 && s_n > 0 && s_sel >= 0 && s_sel < s_n) {
          s_inspector = true; s_sig_prev = 0; draw_board(false); return;
        } else if (tap_x >= W - 115 && tap_x <= W - 10) {
          s_diag = true; s_sig_prev = 0; draw_board(true); return;
        }
        return;
      }
      int hit = -1, best = 30 * 30;
      for (int k = 0; k < s_n; k++) {
        if (!s_sv_on[k]) continue;
        int dx = s_sv_px[k] - tap_x, dy = s_sv_py[k] - tap_y;
        if (dx * dx + dy * dy < best) { best = dx * dx + dy * dy; hit = k; }
      }
      if (hit >= 0) {
        if (hit == s_sel) { s_inspector = true; s_sig_prev = 0; draw_board(false); return; }
        select_row(hit);
        draw_board(false);
        s_sig_prev = signature();
      }
      return;
    }
    if (!s_map) {
      if (tap_y >= 92 && tap_y < 104 + ROWS * ROW_H && tap_x < TABLE_X + TABLE_W) {          // a table row
        int row_idx = (tap_y < 104) ? 0 : (tap_y - 104) / ROW_H;
        int k = s_table_page * ROWS + row_idx;
        if (k < s_n) {
          if (s_sel == k) {
            // Tapped already selected row -> Open Inspector!
            s_inspector = true;
            s_sig_prev = 0;
            draw_board(false);
            return;
          }
          select_row(k);
          redraw_body();
          return;
        }
      } else if (tap_x > 560 && tap_y > 70 && tap_y < 496) {        // plot area
        // The traffic card: its drone's details, or (a chosen aircraft) close it.
        const TrafficAircraft* tc; const TrafficAlert* ta;
        if (traffic_card_pick(&tc, &ta)) {
          int slot = is_pair(ta) ? drone_slot(ta->drone_id) : -1;
          for (int k = 0; k < s_n && slot >= 0; k++)
            if (s_order[k] == slot) { select_row(k); s_inspector = true; s_sig_prev = 0; draw_board(false); return; }
          if (s_ac_hex[0]) { s_ac_hex[0] = 0; redraw_body(); }
          return;
        }
        // The marks where the plot drew them: an aircraft's diamond opens its
        // card, a drone's dot selects its row.
        int hit = -1, ac_hit = -1, best = 24 * 24;
        if (g_home_set) {
          for (int k = 0; k < s_n; k++) {
            if (!s_plot_on[k]) continue;
            int dx = s_plot_px[k] - tap_x, dy = s_plot_py[k] - tap_y;
            if (dx * dx + dy * dy < best) { best = dx * dx + dy * dy; hit = k; }
          }
          for (int j = 0; j < s_pac_n; j++) {
            int dx = s_pac_x[j] - tap_x, dy = s_pac_y[j] - tap_y;
            if (dx * dx + dy * dy < best) { best = dx * dx + dy * dy; ac_hit = j; hit = -1; }
          }
          if (ac_hit >= 0) {
            snprintf(s_ac_hex, sizeof(s_ac_hex), "%s", s_pac_hex[ac_hit]);
            redraw_body();
            return;
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
          select_row(hit);
          redraw_body();
          return;
        }
        // If tapped outside any aircraft on radar, switch to map
        s_map = true;
        s_sig_prev = 0;
        draw_board(true);
        return;
      } else if (tap_y >= 485) {
        if (s_page_bw && tap_x >= s_page_bx - 12 && tap_x <= s_page_bx + s_page_bw + 12 && s_n > ROWS) {
          int max_pages = (s_n + ROWS - 1) / ROWS;
          s_table_page = (s_table_page + 1) % max_pages;
          select_row(s_table_page * ROWS);
          redraw_body();
          return;
        } else if (tap_x >= W - 230 && tap_x <= W - 115 && s_n > 0 && s_sel >= 0 && s_sel < s_n) {
          s_inspector = true;
          s_sig_prev = 0;
          draw_board(false);
          return;
        } else if (tap_x >= W - 115 && tap_x <= W - 10) {
          s_diag = true;
          s_sig_prev = 0;
          draw_board(true);
          return;
        }
      }
    } else {
      s_map_touched = true;
      // Tactical HUD button hit-test (an aircraft's HUD first: it is drawn instead)
      bool ac_hud = ac_index(s_ac_hex) >= 0 && traffic_alert_for_hex(&g_traffic_result, s_ac_hex);
      if (ac_hud || (s_n > 0 && s_sel >= 0 && s_sel < s_n)) {
        const int hud_h = MAP_HUD_H;
        const int hud_y = MAP_Y0 + MAP_H - hud_h - 40;
        if (tap_y >= hud_y && tap_y <= hud_y + hud_h) {
          if (tap_x >= W - 172 && tap_x <= W - 66) {
            // [ DETAILS ]: the drone's inspector, or the aircraft's card on TABLE
            if (ac_hud) { s_map = false; draw_board(true); s_sig_prev = signature(); return; }
            s_inspector = true;
            s_sig_prev = 0;
            draw_board(false);
            return;
          } else if (tap_x >= W - 64 && tap_x <= W - 14) {
            // [ X ] button -> deselect
            if (ac_hud) s_ac_hex[0] = 0;
            else select_row(-1);
            draw_map();
            refresh_area(RECT_MAP, false);
            s_sig_prev = signature();
            return;
          }
        }
      }
      if (tap_x >= W - 70 && tap_y >= MAP_Y0 + 40 && tap_y < MAP_Y0 + 164) {   // zoom boxes
        int dz = tap_y < MAP_Y0 + 105 ? 1 : -1;
        int nz = s_cam_z + dz;
        if (nz >= TILE_ZMIN && nz <= TILE_ZMAX) {
          double f = dz > 0 ? 2.0 : 0.5;
          s_cam_wx *= f; s_cam_wy *= f; s_cam_z = nz; s_cam_manual = true; s_cam_manual_ms = now;
          draw_map();
          refresh_area(RECT_MAP, false);
          s_sig_prev = signature();
          return;
        }
      } else if (tap_x >= W - 70 && tap_y >= MAP_Y0 + 164 && tap_y < MAP_Y0 + 225) { // Recenter reticle
        s_cam_manual = false;
        map_camera();
        draw_map();
        refresh_area(RECT_MAP, false);
        s_sig_prev = signature();
        return;
      } else if (s_cam_manual && s_pan_bw && tap_x >= s_pan_bx && tap_x <= s_pan_bx + s_pan_bw && tap_y >= MAP_Y0 + 38 && tap_y <= MAP_Y0 + 76) {
        s_cam_manual = false;
        map_camera();
        draw_map();
        refresh_area(RECT_MAP, false);
        s_sig_prev = signature();
        return;
      } else if (tap_y >= 485 && tap_x >= W - 115 && tap_x <= W - 10) {
        s_diag = true;
        s_sig_prev = 0;
        draw_board(true);
        return;
      } else if (tap_y >= MAP_Y0 && tap_y < MAP_Y0 + MAP_H) {
        // a marker near the tap selects it; anywhere else on the map re-centres there
        double left = s_cam_wx - W / 2.0, top = s_cam_wy - MAP_H / 2.0;
        int hit = -1, ac_hit = -1, best = 36 * 36;
        for (int k = 0; k < s_n; k++) {
          const Track* t = &g_tracks[s_order[k]];
          if (!t->has_pos) continue;
          double wx, wy; world_px(t->lat, t->lon, s_cam_z, &wx, &wy);
          int dx = (int)(wx - left) - tap_x, dy = MAP_Y0 + (int)(wy - top) - tap_y;
          if (dx * dx + dy * dy < best) { best = dx * dx + dy * dy; hit = k; }
        }
        for (int j = 0; j < s_pac_n; j++) {   // where the last map drew them
          int dx = s_pac_x[j] - tap_x, dy = s_pac_y[j] - tap_y;
          if (dx * dx + dy * dy < best) { best = dx * dx + dy * dy; ac_hit = j; hit = -1; }
        }
        if (ac_hit >= 0) snprintf(s_ac_hex, sizeof(s_ac_hex), "%s", s_pac_hex[ac_hit]);
        else if (hit >= 0) { s_ac_hex[0] = 0; select_row(hit); }
        else { s_cam_wx = left + tap_x; s_cam_wy = top + (tap_y - MAP_Y0); s_cam_manual = true; s_cam_manual_ms = now; }
        draw_map();
        refresh_area(RECT_MAP, false);
        s_sig_prev = signature();
        return;
      }
    }
  }
  if ((drag_dx || drag_dy) && s_map) {
    s_map_touched = true;
    s_cam_wx -= drag_dx; s_cam_wy -= drag_dy; s_cam_manual = true; s_cam_manual_ms = now;
    draw_map();
    refresh_area(RECT_MAP, false, true);  // MODE_DU during active drag for speed
    s_sig_prev = signature();
    return;
  }
  if (s_cam_manual && now - s_cam_manual_ms > 120000) { s_cam_manual = false; s_sig_prev = 0; }

  // tap: step through the contacts on the table, then over to the map,
  // then back to the table's first row.
  if (tap) {
    if (s_map && s_cam_manual) { s_cam_manual = false; map_camera(); draw_map(); refresh_area(RECT_MAP, false); s_sig_prev = signature(); return; }
    else if (s_map) { s_map = false; s_side = true; draw_board(true); s_sig_prev = signature(); return; }
    else if (s_side) { s_side = false; select_row(0); draw_board(true); s_sig_prev = signature(); return; }
    else if (s_n > 0 && s_sel < s_n - 1) {
      select_row(s_sel + 1);
      redraw_body();
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
      char b[48]; snprintf(b, sizeof(b), "SYNCING MAP TILES | %d RECEIVED", sync_files);
      text(&FreeSansBold9pt7b, b, TABLE_X, 524, BLACK);
      EpdRect r = {0, 496, W, 44};
      refresh_checked(r, MODE_GL16);
    }
    return;
  }
  // Re-read the table every 3 s whether or not a frame arrived: the
  // signature also moves with time (a contact going stale, an emergency
  // header clearing), with the peripherals (GPS fix, battery), and with
  // expiry, which drops rows without any message announcing it.
  // Nobody has touched it for a while: switch to glance mode.
  if (s_mode == UI_MODE_RX && !s_diag && !s_inspector && !s_confirm_switch && !syncing &&
      now - s_last_input_ms >= GLANCE_IDLE_MS) {
    s_glance = true;
    build_order();
    glance_show(now);
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

  // PMIC idle timeout: power down TPS65185 high-voltage rails after 3 s
  // of display inactivity, saving ~10–15 mA.
  epd_idle_check(now);
}

void ui_show_shutdown_screen(bool boot_wakes) {
  if (!s_ok) return;
  epd_hl_set_all_white(&s_hl);
  const GFXfont* f9  = &FreeSansBold9pt7b;
  const GFXfont* f12 = &FreeSansBold12pt7b;
  const GFXfont* f18 = &FreeSansBold18pt7b;

  // Header banner
  rect(0, 0, W, 68, BLACK);
  text(f18, "ORECCHINO", 24, 46, WHITE);

  // Central dialog frame
  int box_w = 580, box_h = 240;
  int box_x = (W - box_w) / 2;
  int box_y = (H - box_h) / 2 - 10;
  rect(box_x, box_y, box_w, box_h, WHITE);
  box(box_x, box_y, box_w, box_h, BLACK);
  box(box_x + 2, box_y + 2, box_w - 4, box_h - 4, BLACK);

  // Inner dark title band
  rect(box_x + 6, box_y + 6, box_w - 12, 46, BLACK);
  const char* title = "POWERED OFF";
  text(f18, title, box_x + (box_w - text_w(f18, title)) / 2, box_y + 38, WHITE);

  // Subtitle
  const char* sub = "The radios and screen are off.";
  text(f9, sub, box_x + (box_w - text_w(f9, sub)) / 2, box_y + 88, BLACK);

  // How to bring it back, as periph_power_off decided before drawing. The
  // font has no bullet glyph, so none is drawn.
  const char* ins = boot_wakes ? "Press BOOT to wake it." : "Press PWR to turn it on.";
  text(f12, ins, box_x + (box_w - text_w(f12, ins)) / 2, box_y + 146, BLACK);

  if (s_batt >= 0) {
    char stat[32];
    snprintf(stat, sizeof(stat), "Battery %d%%", s_batt);
    text(f9, stat, box_x + (box_w - text_w(f9, stat)) / 2, box_y + 200, GREY);
  }

  // Bottom footer
  const char* foot = "Orecchino Remote ID receiver | LilyGO T5 E-Paper S3 Pro";
  text(f9, foot, (W - text_w(f9, foot)) / 2, H - 24, GREY);

  // Full GC16 refresh to clear any ghosting and freeze high-contrast image
  epd_ensure_on();
  epd_hl_update_screen(&s_hl, MODE_GC16, epd_ambient_temperature());
  epd_poweroff();
  s_epd_powered = false;
}

