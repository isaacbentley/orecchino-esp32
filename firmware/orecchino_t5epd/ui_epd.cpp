#include "ui_epd.h"
#include "board_t5.h"
#include "sx1262_sweep.h"
#include "t5_periph.h"
#include "../common/ui_common.h"
#include <epdiy.h>
#include <LittleFS.h>
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
#define ROWS  9
#define TABLE_X 20
#define TABLE_W 580
#define PLOT_CX 780
#define PLOT_CY 270
#define PLOT_R  150
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
static uint32_t signature() {
  uint32_t h = 2166136261u;
  auto mix = [&](uint32_t v) { h ^= v; h *= 16777619u; };
  for (int k = 0; k < s_n; k++) {
    const Track* t = &g_tracks[s_order[k]];
    for (const char* p = t->uas; *p; p++) mix((uint8_t)*p);
    mix(t->rssi / 6); mix(isnan(t->height) ? 0xFFFF : (int)t->height / 5);
    mix((uint32_t)(int32_t)(t->lat * 1e4)); mix((uint32_t)(int32_t)(t->lon * 1e4));
    mix(t->status); mix(t->auth_state); mix(t->in_tfr); mix(ui_stale(t, s_now));
  }
  mix(s_sel); mix(g_seen_count); mix(s_batt / 5); mix(s_ble_ok); mix(g_home_set);
  mix(s_map); mix((uint32_t)(int32_t)(g_home_lat * 1e4)); mix((uint32_t)(int32_t)(g_home_lon * 1e4));
  mix(periph_gps_fix()); mix(periph_gps_sats()); mix(s_cam_manual); mix(s_cam_z); mix((uint32_t)s_cam_wx); mix((uint32_t)s_cam_wy);
  return h;
}

static void draw_header(const UiSummary& sm, const char* title) {
  bool loud = sm.alert != UI_QUIET;
  rect(0, 0, W, 70, loud ? BLACK : WHITE);
  if (!loud) rect(0, 68, W, 2, BLACK);
  uint8_t fg = loud ? WHITE : BLACK, mut = loud ? LIGHT : GREY;
  char b[48];
  if (title) snprintf(b, sizeof(b), "%s", title); else ui_headline(b, sizeof(b), &sm);
  text(&FreeSansBold24pt7b, b, TABLE_X, 50, fg);
  int xr = W - 20;
  snprintf(b, sizeof(b), s_ble_ok ? "RX OK" : "RX FAULT");
  text_r(&FreeSansBold12pt7b, b, xr, 44, s_ble_ok ? mut : fg); xr -= text_w(&FreeSansBold12pt7b, b) + 28;
  if (s_batt >= 0) { snprintf(b, sizeof(b), "%d%%", s_batt); text_r(&FreeSansBold12pt7b, b, xr, 44, mut); xr -= text_w(&FreeSansBold12pt7b, b) + 28; }
  if (periph_gps_fix()) snprintf(b, sizeof(b), "GPS %d", periph_gps_sats());
  else snprintf(b, sizeof(b), g_home_set ? "APP POS" : "NO POS");
  text_r(&FreeSansBold12pt7b, b, xr, 44, mut); xr -= text_w(&FreeSansBold12pt7b, b) + 28;
  if (g_seen_count) { snprintf(b, sizeof(b), "%lu seen", (unsigned long)g_seen_count); text_r(&FreeSansBold12pt7b, b, xr, 44, mut); }
}

static void draw_footer(const UiSummary& sm, const char* hint) {
  rect(0, 500, W, 40, WHITE);
  rect(0, 500, W, 1, GREY);
  char b[64];
  if (sm.newest_age_s == UINT32_MAX) snprintf(b, sizeof(b), "SCANNING");
  else snprintf(b, sizeof(b), "LAST RX %lus", (unsigned long)sm.newest_age_s);
  text(&FreeSansBold9pt7b, b, TABLE_X, 526, GREY);
  text_r(&FreeSansBold9pt7b, hint, W - 20, 526, GREY);
}

static void draw_table() {
  const int y0 = 84;
  // column heads
  const GFXfont* f9 = &FreeSansBold9pt7b;
  struct Col { const char* l; int x; } COLS[] = { {"ID", 34}, {"RSSI", 270}, {"HGT", 350}, {"SPD", 410}, {"RANGE", 470}, {"BRG", 545}, {"AUTH", 590} };
  for (auto& c : COLS) text(f9, c.l, TABLE_X + c.x - 20, y0 + 14, GREY);
  rect(TABLE_X, y0 + 20, TABLE_W, 1, GREY);
  for (int k = 0; k < ROWS && k < s_n; k++) {
    const Track* t = &g_tracks[s_order[k]];
    int y = y0 + 26 + k * ROW_H;
    bool stale = ui_stale(t, s_now), danger = ui_danger(t, s_now), sel = k == s_sel;
    uint8_t ink = stale ? GREY : BLACK;
    if (sel) rect(TABLE_X, y, 6, ROW_H - 6, BLACK);
    if (danger) box(TABLE_X + 10, y - 2, TABLE_W - 10, ROW_H - 2, BLACK);
    char b[32];
    snprintf(b, sizeof(b), "%.18s", t->uas[0] ? t->uas : "(no id)");
    text(&FreeSansBold12pt7b, b, TABLE_X + 14, y + 22, ink);
    // status / tfr tag under the id, small
    if (t->in_tfr) text(f9, "IN TFR", TABLE_X + 14, y + 38, BLACK);
    else if (t->status == 3) text(f9, "EMERGENCY", TABLE_X + 14, y + 38, BLACK);
    // rssi bar
    int bx = TABLE_X + 250, bw = 60;
    box(bx, y + 8, bw, 10, ink);
    rect(bx, y + 8, (int)(bw * ui_rssi01(t->rssi)), 10, ink);
    snprintf(b, sizeof(b), "%d", t->rssi); text(f9, b, bx, y + 36, ink);
    if (!isnan(t->height)) { snprintf(b, sizeof(b), "%dm", (int)t->height); text(f9, b, TABLE_X + 330, y + 22, ink); }
    if (!isnan(t->speed))  { snprintf(b, sizeof(b), "%.0f", t->speed);       text(f9, b, TABLE_X + 390, y + 22, ink); }
    if (g_home_set && t->has_pos) {
      char r[10]; ui_fmt_range(r, sizeof(r), ui_dist_m(g_home_lat, g_home_lon, t->lat, t->lon));
      text(f9, r, TABLE_X + 450, y + 22, ink);
      snprintf(b, sizeof(b), "%03d", (int)ui_bearing(g_home_lat, g_home_lon, t->lat, t->lon));
      text(f9, b, TABLE_X + 525, y + 22, ink);
    }
    if (t->auth_state) {
      const char* a = track_auth_badge(t->auth_state) + 3;   // drop the "ID " prefix: the column is headed AUTH
      if (t->auth_state == 4) { rect(TABLE_X + 566, y + 4, 34, 20, BLACK); text(f9, a, TABLE_X + 570, y + 19, WHITE); }
      else text(f9, a, TABLE_X + 570, y + 22, ink);
    }
    rect(TABLE_X + 10, y + ROW_H - 6, TABLE_W - 10, 1, LIGHT);
  }
  if (!s_n) text(&FreeSansBold18pt7b, "SCANNING", TABLE_X + 180, y0 + 200, GREY);
}

static double nice_scale(double m) {
  static const double S[] = { 100, 250, 500, 1000, 2000, 5000, 10000 };
  for (double s : S) if (m <= s) return s;
  return 20000;
}

static void draw_plot() {
  // rings
  double far = 0;
  if (g_home_set)
    for (int k = 0; k < s_n; k++) {
      const Track* t = &g_tracks[s_order[k]];
      if (t->has_pos) { double d = ui_dist_m(g_home_lat, g_home_lon, t->lat, t->lon); if (d > far) far = d; }
    }
  double scale = nice_scale(far > 0 ? far * 1.1 : 500);
  for (int i = 1; i <= 3; i++) epd_draw_circle(PLOT_CX, PLOT_CY, PLOT_R * i / 3, i == 3 ? BLACK : GREY, s_fb);
  epd_draw_line(PLOT_CX, PLOT_CY - PLOT_R, PLOT_CX, PLOT_CY + PLOT_R, LIGHT, s_fb);
  epd_draw_line(PLOT_CX - PLOT_R, PLOT_CY, PLOT_CX + PLOT_R, PLOT_CY, LIGHT, s_fb);
  text(&FreeSansBold9pt7b, "N", PLOT_CX - 6, PLOT_CY - PLOT_R - 8, BLACK);
  char b[24];
  if (scale >= 1000) snprintf(b, sizeof(b), "%.0f km", scale / 1000); else snprintf(b, sizeof(b), "%.0f m", scale);
  text(&FreeSansBold9pt7b, b, PLOT_CX + PLOT_R - 40, PLOT_CY + PLOT_R + 22, GREY);
  if (!g_home_set) {
    text(&FreeSansBold9pt7b, "NO OPERATOR FIX", PLOT_CX - 65, PLOT_CY + PLOT_R + 44, GREY);
    text(&FreeSansBold9pt7b, "SYNC VIA APP", PLOT_CX - 50, PLOT_CY + PLOT_R + 62, GREY);
    // signal ladder instead: strongest at the top
    int y = PLOT_CY - PLOT_R + 20;
    for (int k = 0; k < s_n && k < 8; k++) {
      const Track* t = &g_tracks[s_order[k]];
      int w = (int)(2 * PLOT_R * ui_rssi01(t->rssi));
      rect(PLOT_CX - PLOT_R, y, w, 14, ui_stale(t, s_now) ? GREY : BLACK);
      snprintf(b, sizeof(b), "%.10s %d", t->uas[0] ? t->uas : "(no id)", t->rssi);
      text(&FreeSansBold9pt7b, b, PLOT_CX - PLOT_R, y + 30, GREY);
      y += 36;
    }
    return;
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
    snprintf(b, sizeof(b), "%.8s", t->uas[0] ? t->uas : "?");
    text(&FreeSansBold9pt7b, b, px + 10, py - 8, stale ? GREY : BLACK);
  }
}

static void draw_selected_strip() {
  // one line of detail for the selected contact, under the table
  if (!s_n) return;
  const Track* t = &g_tracks[s_order[s_sel]];
  char b[120];
  snprintf(b, sizeof(b), "%s  %s  %s  src %s%s%s  msgs %u  %lus ago",
           t->uas[0] ? t->uas : "(no id)", ui_status_name(t->status),
           t->auth_state ? ui_auth_text(t->auth_state) : "",
           (t->src_mask & 1) ? "W" : "", (t->src_mask & 2) ? "N" : "",
           (t->src_mask & 4) ? "B" : "", t->msgs, (unsigned long)((s_now - t->last_ms) / 1000));
  text(&FreeSansBold9pt7b, b, TABLE_X, 492, GREY);
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
  UiSummary sm; ui_summarize(&sm, s_now);
  map_camera();
  // tiles covering the window
  double left = s_cam_wx - W / 2.0, top = s_cam_wy - MAP_H / 2.0;
  long tx0 = (long)floor(left / 256), ty0 = (long)floor(top / 256);
  long tx1 = (long)floor((left + W) / 256), ty1 = (long)floor((top + MAP_H) / 256);
  long tmax = (1L << s_cam_z) - 1;
  int missing = 0;
  for (long ty = ty0; ty <= ty1; ty++) {
    for (long tx = tx0; tx <= tx1; tx++) {
      s_blit_x = (int)(tx * 256 - left);
      s_blit_y = MAP_Y0 + (int)(ty * 256 - top);
      bool ok = false;
      if (tx >= 0 && ty >= 0 && tx <= tmax && ty <= tmax) {
        char path[48];
        snprintf(path, sizeof(path), "/tiles/%d/%ld/%ld.png", s_cam_z, tx, ty);
        if (s_png.open(path, pngOpenCb, pngCloseCb, pngReadCb, pngSeekCb, pngDrawCb) == PNG_SUCCESS) {
          if (s_png.getWidth() <= 256) {
            s_png.decode(nullptr, 0);
            ok = true;
          }
          s_png.close();
        }
      }
      if (!ok) missing++;
    }
  }
  // overlay: home, contacts, scale, north
  if (g_home_set) {
    double wx, wy; world_px(g_home_lat, g_home_lon, s_cam_z, &wx, &wy);
    int x = (int)(wx - left), y = MAP_Y0 + (int)(wy - top);
    epd_fill_circle(x, y, 5, BLACK, s_fb);
    epd_draw_circle(x, y, 10, BLACK, s_fb);
  }
  char b[32];
  for (int k = 0; k < s_n; k++) {
    const Track* t = &g_tracks[s_order[k]];
    if (!t->has_pos) continue;
    double wx, wy; world_px(t->lat, t->lon, s_cam_z, &wx, &wy);
    int x = (int)(wx - left), y = MAP_Y0 + (int)(wy - top);
    if (x < 0 || x >= W || y < MAP_Y0 || y >= MAP_Y0 + MAP_H) continue;
    bool stale = ui_stale(t, s_now), danger = ui_danger(t, s_now);
    // white halo so the marker reads over street ink
    epd_fill_circle(x, y, danger ? 15 : 11, WHITE, s_fb);
    if (danger) epd_draw_circle(x, y, 13, BLACK, s_fb);
    epd_fill_circle(x, y, k == s_sel ? 8 : 6, stale ? GREY : BLACK, s_fb);
    if (!isnan(t->heading)) {
      double hr = t->heading * M_PI / 180;
      epd_draw_line(x, y, x + (int)(sin(hr) * 20), y - (int)(cos(hr) * 20), BLACK, s_fb);
    }
    snprintf(b, sizeof(b), "%.10s", t->uas[0] ? t->uas : "?");
    int tw = text_w(&FreeSansBold9pt7b, b);
    rect(x + 10, y - 20, tw + 6, 18, WHITE);
    text(&FreeSansBold9pt7b, b, x + 13, y - 6, stale ? GREY : BLACK);
  }
  // scale bar: 100 px in metres at this zoom and latitude
  double clat, clon; px_world(s_cam_wx, s_cam_wy, s_cam_z, &clat, &clon);
  double m_per_px = 156543.03 * cos(clat * M_PI / 180) / (double)(1L << s_cam_z);
  double bar_m = m_per_px * 100;
  if (bar_m >= 1000) snprintf(b, sizeof(b), "%.1f km", bar_m / 1000); else snprintf(b, sizeof(b), "%d m", (int)bar_m);
  rect(20, MAP_Y0 + MAP_H - 30, 100 + 60, 24, WHITE);
  rect(24, MAP_Y0 + MAP_H - 14, 100, 3, BLACK);
  text(&FreeSansBold9pt7b, b, 130, MAP_Y0 + MAP_H - 12, BLACK);
  rect(W - 44, MAP_Y0 + 8, 30, 30, WHITE);
  text(&FreeSansBold12pt7b, "N", W - 38, MAP_Y0 + 30, BLACK);
  // touch zoom boxes, right edge
  for (int i = 0; i < 2; i++) {
    int by = MAP_Y0 + 60 + i * 56;
    rect(W - 56, by, 48, 48, WHITE); box(W - 56, by, 48, 48, BLACK);
    text(&FreeSansBold18pt7b, i ? "-" : "+", W - 40, by + 34, BLACK);
  }
  if (s_cam_manual) {
    int pw = 140, ph = 26;
    int px = 20, py = MAP_Y0 + 8;
    rect(px, py, pw, ph, WHITE);
    box(px, py, pw, ph, BLACK);
    text(&FreeSansBold9pt7b, "MANUAL PAN", px + 10, py + 18, BLACK);
  }
  epd_draw_line(W - 29, MAP_Y0 + 32, W - 29, MAP_Y0 + 38, BLACK, s_fb);
  if (missing == (tx1 - tx0 + 1) * (ty1 - ty0 + 1)) {
    text(&FreeSansBold12pt7b, "NO TILES • SYNC VIA APP", 320, MAP_CY, GREY);
  }
  draw_header(sm, nullptr);
  draw_footer(sm, "btn: table   hold: spec");
  // images ghost badly under a fast update: always a clean refresh
  epd_poweron();
  epd_hl_update_screen(&s_hl, MODE_GC16, TEMP_C);
  epd_poweroff();
  s_partials = 0; s_last_full = s_now;
  s_alert_prev = sm.alert;
}

static void refresh(bool force_full) {
  bool full = force_full || s_partials >= 12 || s_now - s_last_full > 600000UL;
  epd_poweron();
  epd_hl_update_screen(&s_hl, full ? MODE_GC16 : MODE_DU, TEMP_C);
  epd_poweroff();
  if (full) { s_partials = 0; s_last_full = s_now; } else s_partials++;
}

static void draw_board(bool force_full) {
  epd_hl_set_all_white(&s_hl);
  if (s_map) { draw_map(); return; }
  UiSummary sm; ui_summarize(&sm, s_now);
  draw_header(sm, nullptr);
  draw_table();
  draw_plot();
  draw_selected_strip();
  draw_footer(sm, s_n > 1 ? "btn: next / map   hold: spec" : "btn: map   hold: spec");
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
  text(&FreeSansBold9pt7b, "2.4 GHz CHANNELS", 20, 100, GREY);
  for (int c = 0; c < 13; c++) {
    float v = (s_a24[c] + 115) / 70.0f; v = v < 0 ? 0 : v > 1 ? 1 : v;
    int h = (int)(90 * v), x = 20 + c * 70;
    rect(x, 200 - h, 56, h, BLACK);
    char b[4]; snprintf(b, sizeof(b), "%d", c + 1); text(&FreeSansBold9pt7b, b, x + 20, 220, GREY);
  }
  // sub-GHz trace
  int lo = 0, hi = -127;
  for (int i = 0; i < N_BIN; i++) { if (s_swp[i] < lo) lo = s_swp[i]; if (s_swp[i] > hi) hi = s_swp[i]; }
  int top = hi + 6, bot = lo - 2; if (top - bot < 30) top = bot + 30;
  const int X0 = 20, PW = 920, Y0 = 250, PH = 220;
  box(X0, Y0, PW, PH, GREY);
  int px = -1, py = -1;
  for (int i = 0; i < N_BIN; i++) {
    int x = X0 + i * PW / N_BIN;
    float v = (float)(s_swp[i] - bot) / (top - bot); v = v < 0 ? 0 : v > 1 ? 1 : v;
    int y = Y0 + PH - (int)(PH * v);
    float vp = (float)(s_pk[i] - bot) / (top - bot); vp = vp < 0 ? 0 : vp > 1 ? 1 : vp;
    epd_draw_pixel(x, Y0 + PH - (int)(PH * vp), GREY, s_fb);
    if (px >= 0) epd_draw_line(px, py, x, y, BLACK, s_fb);
    px = x; py = y;
  }
  char b[32];
  snprintf(b, sizeof(b), "%d dBm", top); text(&FreeSansBold9pt7b, b, X0 + 4, Y0 + 16, GREY);
  snprintf(b, sizeof(b), "%d dBm", bot); text(&FreeSansBold9pt7b, b, X0 + 4, Y0 + PH - 6, GREY);
  const char* L[] = { "850", "868", "890", "915", "930" };
  for (int i = 0; i < 5; i++) text(&FreeSansBold9pt7b, L[i], X0 + i * (PW / 4) - (i == 4 ? 30 : 0), Y0 + PH + 18, GREY);
  draw_footer(sm, "button: back");
  epd_poweron();
  epd_hl_update_screen(&s_hl, (++s_partials % 8) == 0 ? MODE_GC16 : MODE_DU, TEMP_C);
  epd_poweroff();
}

bool ui_begin() {
  pinMode(PIN_BOOT_BTN, INPUT_PULLUP);
  // The 1 K LUT trades a little refresh time for ~60 KB of internal RAM,
  // which the radio stacks need more than the panel does.
  epd_init(&epd_board_v7, &ED047TC1, EPD_LUT_1K);
  epd_set_vcom(1560);
  s_hl = epd_hl_init(EPD_BUILTIN_WAVEFORM);
  epd_set_rotation(EPD_ROT_LANDSCAPE);
  s_fb = epd_hl_get_framebuffer(&s_hl);
  if (!s_fb) return false;
  epd_poweron();
  epd_clear();
  epd_poweroff();
  s_ok = true;
  s_now = millis();
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
      if (!t_was) { tx0 = sx; ty0 = sy; Serial.printf("{\"type\":\"touch\",\"raw\":[%d,%d],\"xy\":[%d,%d]}\n", rx, ry, sx, sy); }
      txl = sx; tyl = sy;
    } else if (t_was) {
      if (abs(txl - tx0) < 25 && abs(tyl - ty0) < 25) { tap_x = tx0; tap_y = ty0; }
      else { drag_dx = txl - tx0; drag_dy = tyl - ty0; }
    }
    t_was = t;
  }
  if (tap_x >= 0 && !s_spec) {
    if (!s_map) {
      if (tap_y >= 84 + 26 && tap_x < TABLE_X + TABLE_W) {          // a table row
        int k = (tap_y - (84 + 26)) / ROW_H;
        if (k < s_n) { s_sel = k; s_sig_prev = 0; }
      } else if (tap_x > 620 && tap_y > 70 && tap_y < 500) {        // the plot: go to the map
        s_map = true; s_sig_prev = 0;
      }
    } else {
      if (tap_x >= W - 56 && tap_y >= MAP_Y0 + 60 && tap_y < MAP_Y0 + 60 + 104) {   // zoom boxes
        int dz = tap_y < MAP_Y0 + 60 + 52 ? 1 : -1;
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
    s_cam_wx -= drag_dx; s_cam_wy -= drag_dy; s_cam_manual = true; s_cam_manual_ms = now; s_sig_prev = 0;
  }
  if (s_cam_manual && now - s_cam_manual_ms > 120000) { s_cam_manual = false; s_sig_prev = 0; }

  if (hold) {
    s_spec = !s_spec;
    if (s_spec) {
      memset((void*)s_wsum, 0, sizeof(s_wsum)); memset((void*)s_wcnt, 0, sizeof(s_wcnt));
      for (int i = 0; i < N_BIN; i++) { s_swp[i] = -127; s_pk[i] = -127; }
      s_sx_ok = sx1262_sweep_begin();
      if (s_sx_ok) sx1262_sweep_set_span(SX_SWEEP_LO_HZ, SX_SWEEP_HI_HZ, N_BIN);
    } else {
      sx1262_sweep_stop();
      draw_board(true);
      s_sig_prev = signature();
    }
  }
  if (s_spec) {
    if (tap || tap_x >= 0) { s_spec = false; sx1262_sweep_stop(); draw_board(true); s_sig_prev = signature(); return; }
    if (s_sx_ok) sx1262_sweep_chunk(s_swp, N_BIN, &s_cursor, 32);
    for (int i = 0; i < N_BIN; i++) s_pk[i] = s_swp[i] > s_pk[i] ? s_swp[i] : s_pk[i] - 0.02f;
    static uint32_t last = 0;
    if (now - last >= 1500) { last = now; draw_spectrum(); }
    return;
  }

  // tap: step through the contacts on the table, then over to the map,
  // then back to the table's first row.
  if (tap) {
    if (s_map && s_cam_manual) { s_cam_manual = false; }
    else if (s_map) { s_map = false; s_sel = 0; }
    else if (s_n > 1 && s_sel < s_n - 1) s_sel++;
    else s_map = true;
  }
  if (syncing) {
    static uint32_t last_prog = 0;
    if (now - last_prog >= 5000) {          // progress line, sparingly
      last_prog = now;
      rect(0, 500, W, 40, WHITE);
      char b[48]; snprintf(b, sizeof(b), "SYNCING MAP TILES  %d received", sync_files);
      text(&FreeSansBold9pt7b, b, TABLE_X, 526, BLACK);
      EpdRect r = {0, 500, W, 40};
      epd_poweron(); epd_hl_update_area(&s_hl, MODE_DU, TEMP_C, r); epd_poweroff();
    }
    return;
  }
  static uint32_t last_check = 0;
  if (tap || now - last_check >= 1000) {
    last_check = now;
    build_order();
    uint32_t sig = signature();
    if (sig != s_sig_prev || now - s_last_full > 600000UL) {
      s_sig_prev = sig;
      draw_board(false);
    }
  }
}
