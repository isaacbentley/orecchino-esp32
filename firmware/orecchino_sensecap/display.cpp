// SenseCAP Indicator 480x480 drone console, v2.
//
// Rendering: tiles decode into a 3x3-tile "world" canvas (PSRAM); each frame
// is a flip-crop of that world into the main canvas plus chrome, flushed to
// the RGB panel in a single blit — the screen only ever sees finished frames.
// The panel is mounted 180 deg (wiki rotation 2): vector/text draws use the
// GFX rotation-2 transform, the map crop bakes the flip into its copy loop.
//
// Interaction (FT6336U @ 0x48, polled): drag pans, pinch or the +/- buttons
// zoom, tap a marker for a detail card, the target button re-enables
// auto-follow, the side hardware button toggles map/list.
#include "display.h"

#ifndef ORECCHINO_DISPLAY

bool display_begin() { return false; }
void display_render(const Track*, int, const DisplayStats&, uint32_t) {}
void display_tick(uint32_t) {}
bool display_map_center(double*, double*) { return false; }
void display_sync_status(uint32_t) {}
void display_force_redraw() {}

#else

#include <Wire.h>
#include <LittleFS.h>
#include <PNGdec.h>
#include <Arduino_GFX_Library.h>
#include "IndicatorBus.h"
#include "spectrum.h"
#include <Adafruit_GFX.h>  // for its Fonts/ (GFXfont layout is shared)
#include <Fonts/FreeSansBold12pt7b.h>
#include <Fonts/FreeSansBold9pt7b.h>

#define GFX_BL     45
#define BTN_PIN    38
#define TP_ADDR_GX 0x48
#define TP_ADDR_DX 0x38
#define TILE_ZMIN  11
#define TILE_ZMAX  15
#define HOME_LAT   37.7749
#define HOME_LON   -122.4194
#include "../common/ui_common.h"
#define ACTIVE_MS  UI_ACTIVE_MS

static Arduino_DataBus*       s_bus;
static Arduino_ESP32RGBPanel* s_panel;
static Arduino_RGB_Display*   s_gfx;
static Arduino_Canvas*        s_cv;      // 480x480, rotation 2 (chrome/markers)
static Arduino_Canvas*        s_world;   // 768x768, rotation 0 (3x3 tiles)
static PNG  s_png;
static File s_pngFile;
static int  s_blit_x, s_blit_y;
static uint8_t s_tp_addr = TP_ADDR_GX;

// world cache identity
static int  s_wz = -1;
static long s_wtx0 = -1, s_wty0 = -1;

// camera
static bool   s_auto = true;
static double s_lat = HOME_LAT, s_lon = HOME_LON;
static int    s_z = 12;

// interaction / view state
#define SPEC_HOLD_MS 10000  // button hold that unlocks the spectrum easter egg
static bool     s_spec_mode = false;
static bool     s_list_mode = false;
static char     s_sel_uas[41] = "";
static uint8_t  s_sel_mac[6] = {0};
static bool     s_sel_active = false;
static uint32_t s_dirty = 1;

// last render inputs (for tick-driven redraws)
static const Track* s_tr = nullptr;
static int          s_tr_n = 0;
static DisplayStats s_st = {};
static uint32_t     s_now_ms = 0;

// footer rates
static uint32_t s_prev_wifi = 0, s_prev_ble = 0, s_prev_ms = 0;
static uint32_t s_rate_wifi = 0, s_rate_ble = 0;

// marker hit-test record (logical coords)
struct Mark { int x, y, idx; };
static Mark s_marks[TRK_MAX];
static int  s_nmarks = 0;

// list-card hit-test record + scroll state
struct ListRow { int y0, y1, idx; };
static ListRow s_lrows[TRK_MAX];
static int     s_nlrows = 0;
static int     s_list_scroll = 0;

// ------------------------------------------------------------ PNG plumbing

static void* pngOpenCb(const char* fn, int32_t* size) {
  s_pngFile = LittleFS.open(fn, "r");
  if (!s_pngFile) return nullptr;
  *size = s_pngFile.size();
  return &s_pngFile;
}
static void pngCloseCb(void*) {
  if (s_pngFile) s_pngFile.close();
}
static int32_t pngReadCb(PNGFILE*, uint8_t* buf, int32_t len) {
  return s_pngFile.read(buf, len);
}
static int32_t pngSeekCb(PNGFILE*, int32_t pos) {
  return s_pngFile.seek(pos) ? pos : -1;
}
static int pngDrawCb(PNGDRAW* d) {
  static uint16_t line[256];
  s_png.getLineAsRGB565(d, line, PNG_RGB565_LITTLE_ENDIAN, 0xffffffff);
  s_world->draw16bitRGBBitmap(s_blit_x, s_blit_y + d->y, line, d->iWidth, 1);
  return 1;
}

// --------------------------------------------------------------- mercator

static void world_px(double lat, double lon, int z, double* wx, double* wy) {
  double n = 256.0 * (double)(1L << z);
  *wx = (lon + 180.0) / 360.0 * n;
  double rad = lat * M_PI / 180.0;
  *wy = (1.0 - log(tan(rad) + 1.0 / cos(rad)) / M_PI) / 2.0 * n;
}
static inline double rssi01(int rssi) { return ui_rssi01(rssi); }
static inline double dist_m(double la1, double lo1, double la2, double lo2) { return ui_dist_m(la1, lo1, la2, lo2); }
static inline void fmt_range(char* out, size_t n, double m) { ui_fmt_range(out, n, m); }

static void px_world(double wx, double wy, int z, double* lat, double* lon) {
  double n = 256.0 * (double)(1L << z);
  *lon = wx / n * 360.0 - 180.0;
  double y = M_PI * (1.0 - 2.0 * wy / n);
  *lat = atan(sinh(y)) * 180.0 / M_PI;
}

// ------------------------------------------------------------- world cache

static void world_compose(int z, long tx0, long ty0) {
  if (z == s_wz && tx0 == s_wtx0 && ty0 == s_wty0) return;
  s_wz = z;
  s_wtx0 = tx0;
  s_wty0 = ty0;
  long tmax = (1L << z) - 1;
  for (int dy = 0; dy < 3; dy++) {
    for (int dx = 0; dx < 3; dx++) {
      long tx = tx0 + dx, ty = ty0 + dy;
      s_blit_x = dx * 256;
      s_blit_y = dy * 256;
      bool ok = false;
      if (tx >= 0 && ty >= 0 && tx <= tmax && ty <= tmax) {
        char path[48];
        snprintf(path, sizeof(path), "/tiles/%d/%ld/%ld.png", z, tx, ty);
        if (s_png.open(path, pngOpenCb, pngCloseCb, pngReadCb, pngSeekCb,
                       pngDrawCb) == PNG_SUCCESS) {
          s_png.decode(nullptr, 0);
          s_png.close();
          ok = true;
        }
      }
      if (!ok) {
        // Beyond coverage: plain black.
        s_world->fillRect(s_blit_x, s_blit_y, 256, 256, RGB565(0, 0, 0));
      }
    }
  }
}

// Copy the visible 480x480 window out of the world canvas into the main
// canvas framebuffer, baking in the 180 deg panel flip.
static void world_crop_flipped(long left, long top) {
  const uint16_t* src = s_world->getFramebuffer();
  uint16_t* dst = s_cv->getFramebuffer();
  int ox = (int)(left - s_wtx0 * 256);
  int oy = (int)(top - s_wty0 * 256);
  for (int ly = 0; ly < 480; ly++) {
    int sy = oy + ly;
    const uint16_t* srow =
        (sy >= 0 && sy < 768) ? src + (long)sy * 768 : nullptr;
    uint16_t* drow = dst + (long)(479 - ly) * 480;
    if (srow && ox >= 0 && ox + 480 <= 768) {
      // Fully inside the world canvas: unrolled reversed copy, no
      // per-pixel bounds checks. This loop is PSRAM-bandwidth-bound, so
      // -O2 + unrolling is the practical ceiling (SIMD can't beat the
      // memory wall here).
      const uint16_t* s = srow + ox;
      uint16_t* d = drow + 479;
      int n = 480;
      while (n >= 8) {
        d[0] = s[0]; d[-1] = s[1]; d[-2] = s[2]; d[-3] = s[3];
        d[-4] = s[4]; d[-5] = s[5]; d[-6] = s[6]; d[-7] = s[7];
        d -= 8; s += 8; n -= 8;
      }
      while (n--) *d-- = *s++;
    } else {
      for (int lx = 0; lx < 480; lx++) {
        int sx = ox + lx;
        uint16_t px = (srow && sx >= 0 && sx < 768) ? srow[sx] : 0;
        drow[479 - lx] = px;
      }
    }
  }
}

// ------------------------------------------------------------------ chrome

static bool any_emergency() {
  for (int i = 0; i < s_tr_n; i++) {
    const Track* t = &s_tr[i];
    if (t->used && t->status == 3 && s_now_ms - t->last_ms < ACTIVE_MS)
      return true;
  }
  return false;
}

static int active_count() {
  int n = 0;
  for (int i = 0; i < s_tr_n; i++)
    if (s_tr[i].used && s_now_ms - s_tr[i].last_ms < ACTIVE_MS) n++;
  return n;
}

// Bar state: dark = quiet sky, amber = active contact, red = emergency.
static uint16_t s_bar_bg, s_bar_fg, s_bar_mut;
static void compute_bar_state() {
  if (any_emergency()) {
    s_bar_bg = RGB565(0x6E, 0x14, 0x14);
    s_bar_fg = RGB565(0xFF, 0xE2, 0xE2);
    s_bar_mut = RGB565(0xD8, 0x9A, 0x9A);
  } else if (active_count() > 0) {
    s_bar_bg = RGB565(0xE0, 0xA8, 0x3A);   // amber alert
    s_bar_fg = RGB565(0x1A, 0x12, 0x02);
    s_bar_mut = RGB565(0x5E, 0x48, 0x10);
  } else {
    s_bar_bg = C_BAR;
    s_bar_fg = C_TEXT;
    s_bar_mut = C_MUTED;
  }
}

static uint32_t newest_rx_age_s() {
  uint32_t best = UINT32_MAX;
  for (int i = 0; i < s_tr_n; i++) {
    const Track* t = &s_tr[i];
    if (!t->used) continue;
    uint32_t age = (s_now_ms - t->last_ms) / 1000;
    if (age < best) best = age;
  }
  return best;
}

static void draw_header(int count) {
  compute_bar_state();
  bool emg = any_emergency();
  int active = active_count();
  s_cv->fillRect(0, 0, 480, 34, s_bar_bg);
  s_cv->setFont(&FreeSansBold12pt7b);
  s_cv->setTextSize(1);
  s_cv->setCursor(10, 25);
  char b[36];
  if (emg) {
    s_cv->setTextColor(s_bar_fg);
    snprintf(b, sizeof(b), "EMERGENCY  %d CONTACT%s", count,
             count == 1 ? "" : "S");
  } else if (active > 0) {
    s_cv->setTextColor(s_bar_fg);
    snprintf(b, sizeof(b), "%d CONTACT%s", count, count == 1 ? "" : "S");
  } else if (count > 0) {
    s_cv->setTextColor(s_bar_mut);
    snprintf(b, sizeof(b), "%d TRACKED", count);
  } else {
    s_cv->setTextColor(s_bar_mut);
    snprintf(b, sizeof(b), "NO CONTACTS");
  }
  s_cv->print(b);
  s_cv->setFont(nullptr);
  // Session tally: unique drones since power-on, always visible, never loud.
  if (g_seen_count > 0) {
    s_cv->setTextSize(1);
    s_cv->setTextColor(s_bar_mut);
    char sc[16];
    snprintf(sc, sizeof(sc), "%lu seen", (unsigned long)g_seen_count);
    s_cv->setCursor(444 - strlen(sc) * 6, 14);
    s_cv->print(sc);
  }
  // RX health dot
  uint16_t ok = (active > 0 || emg) ? RGB565(0x1E, 0x64, 0x28)
                                    : RGB565(0x5E, 0xCB, 0x7A);
  s_cv->fillCircle(456, 17, 5, s_st.ble_ok ? ok : C_DANGER);
  if (!s_st.ble_ok) {
    s_cv->setTextSize(1);
    s_cv->setTextColor(C_DANGER);
    s_cv->setCursor(400, 14);
    s_cv->print("RX FLT");
  }
}

static void draw_footer() {
  s_cv->fillRect(0, 460, 480, 20, s_bar_bg);
  s_cv->setTextSize(1);
  s_cv->setTextColor(s_bar_mut);
  s_cv->setCursor(8, 466);
  uint32_t age = newest_rx_age_s();
  char b[48];
  if (age == UINT32_MAX) snprintf(b, sizeof(b), "SCANNING");
  else snprintf(b, sizeof(b), "LAST RX %lus", (unsigned long)age);
  s_cv->print(b);
}

struct Btn { int x, y; const char* glyph; };
static const Btn BTNS[] = { {432, 330, "+"}, {432, 374, "-"}, {432, 418, "o"} };

// Authentication badge: a signed ID reads "ID" with a tick, a bad
// signature "ID" with a cross in danger red. A bad signature is a
// security event, so it gets the loudest colour on the screen.
static void draw_auth_badge(uint8_t st, int x, int y, bool stale) {
  if (st == 0) return;                       // no auth: draw nothing
  uint16_t col = stale ? C_MUTED
               : (st == 3 ? RGB565(0x5E, 0xCB, 0x7A)
               : (st == 4 ? C_DANGER
               : (st == 2 ? RGB565(0xE0, 0xA8, 0x3A) : C_MUTED)));
  s_cv->fillRoundRect(x, y, 34, 15, 4, C_BAR);
  s_cv->drawRoundRect(x, y, 34, 15, 4, col);
  s_cv->setTextSize(1);
  s_cv->setTextColor(col, C_BAR);
  s_cv->setCursor(x + 4, y + 4);
  s_cv->print("ID");
  int gx = x + 20, gy = y + 7;
  if (st == 3) {                             // tick
    s_cv->drawLine(gx, gy, gx + 3, gy + 4, col);
    s_cv->drawLine(gx + 3, gy + 4, gx + 9, gy - 5, col);
    s_cv->drawLine(gx, gy + 1, gx + 3, gy + 5, col);
    s_cv->drawLine(gx + 3, gy + 5, gx + 9, gy - 4, col);
  } else if (st == 4) {                      // cross
    s_cv->drawLine(gx, gy - 4, gx + 8, gy + 4, col);
    s_cv->drawLine(gx + 8, gy - 4, gx, gy + 4, col);
    s_cv->drawLine(gx + 1, gy - 4, gx + 9, gy + 4, col);
    s_cv->drawLine(gx + 9, gy - 4, gx + 1, gy + 4, col);
  } else {                                   // partial / untrusted key
    s_cv->setCursor(gx, y + 4);
    s_cv->print(st == 2 ? "?" : "..");
  }
}

static void draw_buttons() {
  for (int i = 0; i < 3; i++) {
    bool hot = (i == 2 && s_auto);
    bool off = (i == 0 && s_z >= TILE_ZMAX) || (i == 1 && s_z <= TILE_ZMIN);
    uint16_t edge = hot ? C_ACCENT : (off ? RGB565(0x2A, 0x30, 0x3C) : C_MUTED);
    uint16_t ink  = hot ? C_ACCENT : (off ? RGB565(0x3A, 0x42, 0x50) : C_TEXT);
    s_cv->fillRoundRect(BTNS[i].x, BTNS[i].y, 40, 40, 6, C_BAR);
    s_cv->drawRoundRect(BTNS[i].x, BTNS[i].y, 40, 40, 6, edge);
    s_cv->setTextSize(2);
    s_cv->setTextColor(ink, C_BAR);
    s_cv->setCursor(BTNS[i].x + 14, BTNS[i].y + 13);
    s_cv->print(BTNS[i].glyph);
  }
}

// ------------------------------------------------------------------- views

static const Track* find_selected() {
  if (!s_sel_active || !s_tr) return nullptr;
  for (int i = 0; i < s_tr_n; i++) {
    const Track* t = &s_tr[i];
    if (!t->used) continue;
    if (s_sel_uas[0] && strncmp(t->uas, s_sel_uas, sizeof(s_sel_uas)) == 0)
      return t;
    if (!s_sel_uas[0] && memcmp(t->mac, s_sel_mac, 6) == 0) return t;
  }
  return nullptr;
}

static void draw_detail_card(const Track* t) {
  int y0 = 310;
  s_cv->fillRoundRect(8, y0, 416, 142, 8, C_BAR);
  s_cv->drawRoundRect(8, y0, 416, 142, 8, C_ACCENT);
  s_cv->setFont(&FreeSansBold9pt7b);
  s_cv->setTextSize(1);
  s_cv->setTextColor(C_TEXT);
  s_cv->setCursor(20, y0 + 20);
  s_cv->print(t->uas[0] ? t->uas : "(no id)");
  s_cv->setFont(nullptr);
  s_cv->setTextSize(1);
  s_cv->setTextColor(C_MUTED, C_BAR);
  char b[96];
  char hb[12] = "--", sb[16] = "--";
  if (!isnan(t->height)) snprintf(hb, sizeof(hb), "%d m", (int)t->height);
  if (!isnan(t->speed)) snprintf(sb, sizeof(sb), "%.1f m/s", t->speed);
  s_cv->setCursor(20, y0 + 34);
  snprintf(b, sizeof(b), "rssi %d dBm   height %s   speed %s", t->rssi, hb, sb);
  s_cv->print(b);
  s_cv->setCursor(20, y0 + 48);
  snprintf(b, sizeof(b), "pos %.5f, %.5f", t->lat, t->lon);
  s_cv->print(b);
  s_cv->setCursor(20, y0 + 62);
  const char* stat = ui_status_name(t->status);
  snprintf(b, sizeof(b), "status %s   src %s%s%s   msgs %u", stat,
           (t->src_mask & 1) ? "W" : "", (t->src_mask & 2) ? "N" : "",
           (t->src_mask & 4) ? "B" : "", t->msgs);
  s_cv->print(b);
  s_cv->setCursor(20, y0 + 76);
  snprintf(b, sizeof(b), "mac %02X:%02X:%02X:%02X:%02X:%02X   seen %lus ago",
           t->mac[0], t->mac[1], t->mac[2], t->mac[3], t->mac[4], t->mac[5],
           (unsigned long)((s_now_ms - t->last_ms) / 1000));
  s_cv->print(b);
  s_cv->setCursor(20, y0 + 90);
  if (t->auth_state) {
    uint16_t ac = ui_auth_color(t->auth_state);
    s_cv->setTextColor(ac, C_BAR);
    s_cv->print(ui_auth_text(t->auth_state));
  } else {
    s_cv->setTextColor(C_MUTED, C_BAR);
    s_cv->print("no auth");
  }
  s_cv->setCursor(20, y0 + 104);
  if (g_home_set && t->has_pos) {
    char r[12];
    fmt_range(r, sizeof(r), dist_m(g_home_lat, g_home_lon, t->lat, t->lon));
    snprintf(b, sizeof(b), "range %s%s%s", r,
             t->in_tfr ? "   IN TFR " : "", t->in_tfr ? t->tfr_id : "");
  } else {
    snprintf(b, sizeof(b), "%s%s",
             t->in_tfr ? "IN TFR " : "", t->in_tfr ? t->tfr_id : "");
  }
  if (b[0]) {
    s_cv->setTextColor(t->in_tfr ? C_DANGER : C_MUTED, C_BAR);
    s_cv->print(b);
  }
  s_cv->setCursor(20, y0 + 124);
  s_cv->setTextColor(C_ACCENT, C_BAR);
  s_cv->print("tap to close");
}

static void pick_auto_view() {
  double miLat = 90, maLat = -90, miLon = 180, maLon = -180;
  int cnt = 0;
  for (int i = 0; i < s_tr_n; i++) {
    const Track* t = &s_tr[i];
    if (!t->used || !t->has_pos || s_now_ms - t->last_ms > ACTIVE_MS) continue;
    if (t->lat < miLat) miLat = t->lat;
    if (t->lat > maLat) maLat = t->lat;
    if (t->lon < miLon) miLon = t->lon;
    if (t->lon > maLon) maLon = t->lon;
    cnt++;
  }
  if (!cnt) {
    s_lat = g_home_set ? g_home_lat : HOME_LAT;
    s_lon = g_home_set ? g_home_lon : HOME_LON;
    s_z = g_home_set ? 13 : 12;
    return;
  }
  s_lat = (miLat + maLat) / 2;
  s_lon = (miLon + maLon) / 2;
  for (int z = TILE_ZMAX; z >= TILE_ZMIN; z--) {
    double x0, y0, x1, y1;
    world_px(maLat, miLon, z, &x0, &y0);
    world_px(miLat, maLon, z, &x1, &y1);
    if (x1 - x0 < 420 && y1 - y0 < 380) {
      s_z = z;
      return;
    }
  }
  s_z = TILE_ZMIN;
}

static void render_map() {
  if (s_auto) pick_auto_view();
  double cwx, cwy;
  world_px(s_lat, s_lon, s_z, &cwx, &cwy);
  long left = lround(cwx) - 240;
  long top  = lround(cwy) - 240;
  world_compose(s_z, (left + 240) / 256 - 1, (top + 240) / 256 - 1);
  world_crop_flipped(left, top);

  s_nmarks = 0;
  int count = 0;
  for (int i = 0; i < s_tr_n; i++) {
    const Track* t = &s_tr[i];
    if (!t->used) continue;
    count++;
    if (!t->has_pos) continue;
    double wx, wy;
    world_px(t->lat, t->lon, s_z, &wx, &wy);
    int x = (int)(lround(wx) - left), y = (int)(lround(wy) - top);
    if (x < -20 || x > 500 || y < -20 || y > 500) continue;
    bool stale = s_now_ms - t->last_ms > ACTIVE_MS;
    bool danger = ui_danger(t, s_now_ms);
    uint16_t col = stale ? C_MUTED
                 : (danger ? C_DANGER : TRACK_COLORS[i % N_TRACK_COLORS]);
    const Track* sel = find_selected();
    bool is_sel = (sel == t);
    s_cv->fillCircle(x, y, 6, col);
    s_cv->drawCircle(x, y, 8, C_BG);
    s_cv->drawCircle(x, y, 9, col);
    if (is_sel) s_cv->drawCircle(x, y, 12, C_ACCENT);
    if (!isnan(t->heading)) {
      // direction-of-travel tick (map is north-up)
      float rad = t->heading * (float)M_PI / 180.0f;
      int hx = x + (int)(sinf(rad) * 16), hy = y - (int)(cosf(rad) * 16);
      s_cv->drawLine(x, y, hx, hy, col);
      s_cv->drawLine(x + 1, y, hx + 1, hy, col);
    }
    const char* id = t->uas[0] ? t->uas : "?";
    int len = strlen(id);
    const char* tail = len > 12 ? id + len - 12 : id;
    s_cv->setTextSize(1);
    s_cv->setTextColor(C_TEXT, C_BG);
    s_cv->setCursor(x + 14, y - 8);
    s_cv->print(tail);
    s_cv->setTextColor(C_MUTED, C_BG);
    s_cv->setCursor(x + 14, y + 2);
    char cb[24];
    char hb2[10] = "";
    if (!isnan(t->height)) snprintf(hb2, sizeof(hb2), "%dm ", (int)t->height);
    snprintf(cb, sizeof(cb), "%s%ddBm", hb2, t->rssi);
    s_cv->print(cb);
    if (s_nmarks < TRK_MAX) {
      s_marks[s_nmarks++] = { x, y, i };
    }
  }

  draw_header(count);
  draw_buttons();
  const Track* sel = find_selected();
  if (sel) draw_detail_card(sel);
  draw_footer();
  // basemap attribution (ODbL / CARTO terms)
  s_cv->fillRect(4, 444, 108, 13, C_BG);
  s_cv->setTextSize(1);
  s_cv->setTextColor(C_MUTED);
  s_cv->setCursor(8, 447);
  s_cv->print("(c) OSM (c) CARTO");
  s_cv->flush();
}

static void render_list() {
  s_cv->fillScreen(C_BG);
  const int CARD_H = 62, GAP = 8, TOP = 42, BOT = 456;
  int count = 0, row = 0;
  s_nlrows = 0;
  for (int i = 0; i < s_tr_n; i++)
    if (s_tr[i].used) count++;

  int content_h = count * (CARD_H + GAP);
  int max_scroll = content_h > (BOT - TOP) ? content_h - (BOT - TOP) : 0;
  if (s_list_scroll > max_scroll) s_list_scroll = max_scroll;
  if (s_list_scroll < 0) s_list_scroll = 0;

  for (int i = 0; i < s_tr_n; i++) {
    const Track* t = &s_tr[i];
    if (!t->used) continue;
    int y = TOP + row * (CARD_H + GAP) - s_list_scroll;
    row++;
    if (y + CARD_H < TOP - 4 || y > BOT) continue;
    s_lrows[s_nlrows++] = { y, y + CARD_H, i };

    bool stale = s_now_ms - t->last_ms > ACTIVE_MS;
    bool danger = (t->status == 3 || t->in_tfr || t->auth_state == 4)
                  && !stale;
    uint16_t col = stale ? C_MUTED
                 : (danger ? C_DANGER : TRACK_COLORS[i % N_TRACK_COLORS]);
    uint16_t edge = danger ? C_DANGER : RGB565(0x1C, 0x22, 0x2C);

    s_cv->fillRoundRect(9, y, 462, CARD_H, 8, C_BAR);
    s_cv->drawRoundRect(9, y, 462, CARD_H, 8, edge);
    s_cv->fillRect(9, y + 8, 4, CARD_H - 16, col);  // identity stripe

    s_cv->setFont(&FreeSansBold9pt7b);
    s_cv->setTextSize(1);
    s_cv->setTextColor(stale ? C_MUTED : C_TEXT);
    s_cv->setCursor(24, y + 24);
    s_cv->print(t->uas[0] ? t->uas : "(no id)");
    int16_t bx, by; uint16_t bw, bh;
    s_cv->getTextBounds(t->uas[0] ? t->uas : "(no id)", 24, y + 24, &bx, &by,
                        &bw, &bh);
    s_cv->setFont(nullptr);
    draw_auth_badge(t->auth_state, 24 + bw + 8, y + 12, stale);

    // RSSI meter, right-aligned
    double st = rssi01(t->rssi);
    s_cv->fillRect(388, y + 12, 56, 4, RGB565(0x20, 0x26, 0x30));
    s_cv->fillRect(388, y + 12, (int)(56 * st), 4, col);
    s_cv->setTextSize(1);
    s_cv->setTextColor(C_MUTED, C_BAR);
    char rs[12];
    snprintf(rs, sizeof(rs), "%d dBm", t->rssi);
    s_cv->setCursor(388, y + 22);
    s_cv->print(rs);

    // stat line
    s_cv->setCursor(24, y + 42);
    char b[96];
    char hb[12] = "--", sb[16] = "--";
    if (!isnan(t->height)) snprintf(hb, sizeof(hb), "%dm", (int)t->height);
    if (!isnan(t->speed)) snprintf(sb, sizeof(sb), "%.1fm/s", t->speed);
    char rb[16] = "";
    if (g_home_set && t->has_pos) {
      char r[12];
      fmt_range(r, sizeof(r), dist_m(g_home_lat, g_home_lon, t->lat, t->lon));
      snprintf(rb, sizeof(rb), "  %s", r);
    }
    snprintf(b, sizeof(b), "h %s  v %s  %lus%s  %s%s%s", hb, sb,
             (unsigned long)((s_now_ms - t->last_ms) / 1000), rb,
             (t->src_mask & 1) ? "W" : "", (t->src_mask & 2) ? "N" : "",
             (t->src_mask & 4) ? "B" : "");
    s_cv->setTextColor(C_MUTED, C_BAR);
    s_cv->print(b);
    if (t->in_tfr) {
      s_cv->setTextColor(C_DANGER, C_BAR);
      s_cv->print("  TFR!");
    }
  }
  if (!count) {
    s_cv->setFont(&FreeSansBold12pt7b);
    s_cv->setTextSize(1);
    s_cv->setTextColor(C_MUTED);
    s_cv->setCursor(168, 244);
    s_cv->print("SCANNING");
    s_cv->setFont(nullptr);
  }
  draw_header(count);
  draw_footer();
  s_cv->flush();
}

static void render_frame() {
  if (s_list_mode) render_list();
  else render_map();
}

// ------------------------------------------------------------------- touch

static int tp_points(int* x0, int* y0, int* x1, int* y1) {
  Wire.beginTransmission(s_tp_addr);
  Wire.write(0x02);
  if (Wire.endTransmission(false) != 0) return -1;
  if (Wire.requestFrom((int)s_tp_addr, 11) != 11) return -1;
  uint8_t d[11];
  for (int i = 0; i < 11; i++) d[i] = Wire.read();
  int n = d[0] & 0x0F;
  if (n < 1 || n > 2) return 0;
  int rx0 = ((d[1] & 0x0F) << 8) | d[2];
  int ry0 = ((d[3] & 0x0F) << 8) | d[4];
  *x0 = 479 - rx0;  // raw panel coords -> logical (180 deg mount)
  *y0 = 479 - ry0;
  if (n == 2) {
    int rx1 = ((d[7] & 0x0F) << 8) | d[8];
    int ry1 = ((d[9] & 0x0F) << 8) | d[10];
    *x1 = 479 - rx1;
    *y1 = 479 - ry1;
  }
  return n;
}

static void handle_tap(int x, int y) {
  if (!s_list_mode) {
    for (int i = 0; i < 3; i++) {
      if (x >= BTNS[i].x - 4 && x < BTNS[i].x + 44 &&
          y >= BTNS[i].y - 4 && y < BTNS[i].y + 44) {
        if (i == 0 && s_z < TILE_ZMAX) { s_z++; s_auto = false; }
        if (i == 1 && s_z > TILE_ZMIN) { s_z--; s_auto = false; }
        if (i == 2) { s_auto = true; s_sel_active = false; }
        s_dirty = 1;
        return;
      }
    }
    int best = -1, bestd = 28 * 28;
    for (int i = 0; i < s_nmarks; i++) {
      int dx = s_marks[i].x - x, dy = s_marks[i].y - y;
      int d2 = dx * dx + dy * dy;
      if (d2 < bestd) { bestd = d2; best = i; }
    }
    if (best >= 0 && s_tr) {
      const Track* t = &s_tr[s_marks[best].idx];
      strncpy(s_sel_uas, t->uas, sizeof(s_sel_uas) - 1);
      s_sel_uas[sizeof(s_sel_uas) - 1] = 0;
      memcpy(s_sel_mac, t->mac, 6);
      s_sel_active = true;
    } else {
      s_sel_active = false;
    }
    s_dirty = 1;
  } else {
    // list view: tap a row to select and jump to it on the map
    for (int i = 0; i < s_nlrows; i++) {
      if (y < s_lrows[i].y0 || y > s_lrows[i].y1 || !s_tr) continue;
      const Track* t = &s_tr[s_lrows[i].idx];
      strncpy(s_sel_uas, t->uas, sizeof(s_sel_uas) - 1);
      s_sel_uas[sizeof(s_sel_uas) - 1] = 0;
      memcpy(s_sel_mac, t->mac, 6);
      s_sel_active = true;
      s_list_mode = false;
      if (t->has_pos) {
        s_lat = t->lat;
        s_lon = t->lon;
        if (s_z < 14) s_z = 14;
        s_auto = false;
      }
      s_dirty = 1;
      render_frame();
      return;
    }
  }
}

static void touch_tick(uint32_t now) {
  static uint32_t last_poll = 0;
  if (now - last_poll < 30) return;
  last_poll = now;

  static bool down = false, moved = false, pinching = false;
  static int sx = 0, sy = 0, lx = 0, ly = 0;
  static double pinch_d0 = 0;
  static uint32_t down_ms = 0;

  int x0, y0, x1, y1;
  int n = tp_points(&x0, &y0, &x1, &y1);
  if (n < 0) return;  // touch controller absent/unhappy: stay quiet

  if (n == 2 && !s_list_mode) {
    double d = sqrt((double)(x1 - x0) * (x1 - x0) + (double)(y1 - y0) * (y1 - y0));
    if (!pinching) {
      pinching = true;
      pinch_d0 = d;
    } else if (pinch_d0 > 1) {
      if (d / pinch_d0 > 1.3 && s_z < TILE_ZMAX) {
        s_z++; s_auto = false; pinch_d0 = d; s_dirty = 1;
      } else if (d / pinch_d0 < 0.75 && s_z > TILE_ZMIN) {
        s_z--; s_auto = false; pinch_d0 = d; s_dirty = 1;
      }
    }
    down = false;
    return;
  }

  if (n == 1) {
    if (pinching) return;  // ignore the trailing finger of a pinch
    if (!down) {
      down = true;
      moved = false;
      sx = lx = x0;
      sy = ly = y0;
      down_ms = now;
    } else {
      int dx = x0 - lx, dy = y0 - ly;
      if (abs(x0 - sx) > 12 || abs(y0 - sy) > 12) moved = true;
      if (moved && (dx || dy)) {
        if (s_list_mode) {
          s_list_scroll -= dy;  // drag scrolls the cards
        } else {
          // pan: shift the camera against the drag
          double cwx, cwy;
          world_px(s_lat, s_lon, s_z, &cwx, &cwy);
          px_world(cwx - dx, cwy - dy, s_z, &s_lat, &s_lon);
          s_auto = false;
        }
        s_dirty = 1;
        render_frame();  // immediate feedback while dragging
      }
      lx = x0;
      ly = y0;
    }
    return;
  }

  // n == 0: release
  pinching = false;
  if (down) {
    down = false;
    if (!moved && now - down_ms < 400) handle_tap(sx, sy);
  }
}

// Spectrum view wants taps only (zoom in on the trace, zoom-out control):
// a stripped-down poll that shares tp_points but none of touch_tick's
// pan/pinch state.
static void spectrum_touch_tick(uint32_t now) {
  static uint32_t last_poll = 0;
  if (now - last_poll < 30) return;
  last_poll = now;

  static bool down = false, moved = false;
  static int sx = 0, sy = 0;
  static uint32_t down_ms = 0;

  int x0, y0, x1, y1;
  int n = tp_points(&x0, &y0, &x1, &y1);
  if (n < 0) return;
  if (n >= 1) {
    if (!down) {
      down = true;
      moved = false;
      sx = x0;
      sy = y0;
      down_ms = now;
    } else if (abs(x0 - sx) > 12 || abs(y0 - sy) > 12) {
      moved = true;
    }
    return;
  }
  if (down) {
    down = false;
    if (!moved && now - down_ms < 400) spectrum_tap(sx, sy);
  }
}

// -------------------------------------------------------------- public API

bool display_begin() {
  pinMode(BTN_PIN, INPUT_PULLUP);
  pinMode(GFX_BL, OUTPUT);
  digitalWrite(GFX_BL, LOW);  // dark until the first clean frame is up

  indicator_expander_init();
  s_bus = new IndicatorSWSPI();
  s_panel = new Arduino_ESP32RGBPanel(
      18, 17, 16, 21,
      4, 3, 2, 1, 0,
      10, 9, 8, 7, 6, 5,
      15, 14, 13, 12, 11,
      1, 10, 8, 50,
      1, 10, 8, 20,
      0 /* pclk_active_neg */, 14000000 /* prefer_speed: ease PSRAM load */,
      false, 0, 0, 480 * 16 /* bounce buffer px */);
  s_gfx = new Arduino_RGB_Display(480, 480, s_panel, 0 /* rotation */,
                                  true, s_bus, GFX_NOT_DEFINED,
                                  st7701_type1_init_operations,
                                  sizeof(st7701_type1_init_operations));
  if (!s_gfx->begin()) return false;

  s_cv = new Arduino_Canvas(480, 480, s_gfx, 0, 0, 2 /* rotation for draws */);
  if (!s_cv->begin(GFX_SKIP_OUTPUT_BEGIN)) return false;
  s_world = new Arduino_Canvas(768, 768, nullptr);
  if (!s_world->begin(GFX_SKIP_OUTPUT_BEGIN)) return false;

  LittleFS.begin(true, "/littlefs", 10, "littlefs");  // idempotent; .ino owns it

  // Probe touch controller generation
  Wire.beginTransmission(TP_ADDR_GX);
  if (Wire.endTransmission() != 0) s_tp_addr = TP_ADDR_DX;

  s_cv->fillScreen(C_BG);
  s_cv->setFont(&FreeSansBold12pt7b);
  s_cv->setTextSize(1);
  s_cv->setTextColor(C_MUTED);
  s_cv->setCursor(168, 244);
  s_cv->print("SCANNING");
  s_cv->setFont(nullptr);
  s_cv->flush();
  digitalWrite(GFX_BL, HIGH);  // first frame is clean — lights on
  return true;
}

void display_render(const Track* tracks, int n, const DisplayStats& st,
                    uint32_t now) {
  if (!s_gfx) return;
  s_tr = tracks;
  s_tr_n = n;
  s_now_ms = now;

  if (s_prev_ms) {
    uint32_t dt = now - s_prev_ms;
    if (dt > 200) {
      s_rate_wifi = (st.wifi_frames - s_prev_wifi) * 1000 / dt;
      s_rate_ble = (st.ble_advs - s_prev_ble) * 1000 / dt;
    }
  }
  s_prev_wifi = st.wifi_frames;
  s_prev_ble = st.ble_advs;
  s_prev_ms = now;
  s_st = st;

  if (s_spec_mode) return;  // spectrum easter egg owns the screen

  // Redraw signature: positions/selection/camera/mode — NOT the hop channel
  // or raw counters, which used to force a repaint every few hundred ms.
  uint32_t sig = (s_list_mode ? 1 : 0) ^ (s_auto ? 2 : 0) ^ (s_z << 2) ^
                 (s_sel_active ? 8 : 0);
  for (int i = 0; i < n; i++) {
    const Track* t = &tracks[i];
    if (!t->used) continue;
    sig = sig * 31 + (uint32_t)(t->lat * 2e4) + (uint32_t)(t->lon * 2e4) + 7;
  }
  if (s_list_mode) sig = sig * 31 + now / 1000;  // ages tick in list view
  static uint32_t last_sig = 0;
  static uint32_t last_chrome = 0;
  bool chrome_due = now - last_chrome >= 2000;  // rates/footer refresh
  if (sig == last_sig && !s_dirty && !chrome_due) return;
  last_sig = sig;
  last_chrome = now;
  s_dirty = 0;
  render_frame();
}

bool display_map_center(double* lat, double* lon) {
  *lat = s_lat;
  *lon = s_lon;
  return true;
}

void display_force_redraw() { s_dirty = 1; }

void display_sync_status(uint32_t files_done) {
  if (!s_gfx) return;
  if (s_spec_mode) {
    s_spec_mode = false;  // a tile push takes the screen back
    spectrum_stop();
  }
  static uint32_t last = 0;
  uint32_t now = millis();
  if (now - last < 500) return;
  last = now;
  s_cv->fillScreen(C_BG);
  s_cv->setFont(&FreeSansBold12pt7b);
  s_cv->setTextSize(1);
  s_cv->setTextColor(C_ACCENT);
  s_cv->setCursor(96, 228);
  s_cv->print("RECEIVING MAP DATA");
  s_cv->setFont(nullptr);
  s_cv->setTextSize(1);
  s_cv->setTextColor(C_MUTED);
  s_cv->setCursor(210, 248);
  char b[24];
  snprintf(b, sizeof(b), "%lu tiles", (unsigned long)files_done);
  s_cv->print(b);
  s_cv->flush();
  s_dirty = 1;
}

void display_tick(uint32_t now) {
  if (!s_gfx) return;

  // Side button: short press acts on release (toggle map/list, or leave the
  // spectrum view); a 10 s hold fires the spectrum easter egg while held.
  static bool     btn_was = false;
  static uint32_t btn_down_ms = 0;
  static bool     hold_fired = false;
  bool btn = digitalRead(BTN_PIN) == LOW;
  if (btn && !btn_was) {
    btn_down_ms = now;
    hold_fired = false;
  }
  if (btn && !hold_fired && now - btn_down_ms >= SPEC_HOLD_MS) {
    hold_fired = true;
    s_spec_mode = true;
    spectrum_reset(now);
  } else if (btn && !hold_fired && now - btn_down_ms >= 400 && !s_spec_mode) {
    int prog_w = (int)(480L * (now - btn_down_ms) / SPEC_HOLD_MS);
    if (prog_w > 480) prog_w = 480;
    s_cv->fillRect(0, 0, prog_w, 4, C_ACCENT);
    s_cv->flush();
  }
  if (!btn && btn_was && !hold_fired) {
    if (s_spec_mode) {
      s_spec_mode = false;
      spectrum_stop();
    } else {
      s_list_mode = !s_list_mode;
    }
    s_dirty = 1;
    render_frame();
  }
  btn_was = btn;

  if (s_spec_mode) {
    spectrum_touch_tick(now);
    spectrum_tick(s_cv, now);
    return;
  }
  if (s_tr) touch_tick(now);
}

#endif  // ORECCHINO_DISPLAY
