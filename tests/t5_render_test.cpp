// Host render of the T5 e-paper board: the production drawing code
// (ui_epd.cpp, included whole so its statics are reachable) painting the
// review's stress fixture into a framebuffer with the real font bitmaps.
// Every scene is saved as a PGM for eyes, and checked for text runs that
// collide -- the failure class that rendered "RANGEBRG" and drew the
// inspector's transport line across the next column. The check knows
// nothing of draw order: text painted over later (a modal over the board)
// would count as a collision, so modals are checked on their own runs.
//
// Needs the Adafruit GFX fonts; run_tests.sh skips it when they are absent.
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
#include "Arduino.h"
#include "gfxfont.h"
#include <string>
#include <vector>

struct TextRun { int x0, y0, x1, y1; std::string s; };
static std::vector<TextRun> g_runs;
static void hook_text(const GFXfont* f, const char* s, int x, int y) {
  TextRun r = { 1 << 30, 1 << 30, -(1 << 30), -(1 << 30), s };
  for (; *s; s++) {
    uint8_t c = (uint8_t)*s;
    if (c < f->first || c > f->last) continue;
    const GFXglyph* g = &f->glyph[c - f->first];
    if (g->width && g->height) {
      r.x0 = std::min(r.x0, x + g->xOffset); r.x1 = std::max(r.x1, x + g->xOffset + g->width);
      r.y0 = std::min(r.y0, y + g->yOffset); r.y1 = std::max(r.y1, y + g->yOffset + g->height);
    }
    x += g->xAdvance;
  }
  if (r.x1 > r.x0) g_runs.push_back(r);
}
#define UI_TEXT_HOOK(f, s, x, y) hook_text(f, s, x, y)
#include "ui_epd.cpp"

// ---- what the sketch and the peripherals would provide
uint8_t g_epd_fb[EPD_W * EPD_H / 2];
const EpdWaveform* EPD_BUILTIN_WAVEFORM = nullptr;
EpdBoardDefinition epd_board_v7; EpdDisplay_t ED047TC1;
MockFS LittleFS;
Track    g_tracks[TRK_MAX];
uint32_t g_seen_count = 0;
bool     g_home_set = false;
double   g_home_lat = 37.8039, g_home_lon = -122.4640;
uint8_t  g_tfr_n = 0; bool g_tfr_loaded = false; uint32_t g_tfr_ms = 0;
static bool p_gps_det = true, p_gps_fix = true; static int p_sats = 9;
bool periph_gps_detected() { return p_gps_det; }
bool periph_gps_fix() { return p_gps_fix; }
int  periph_gps_sats() { return p_sats; }
int  periph_batt_pct() { return 76; }
int  periph_batt_mv() { return 3900; }
int  periph_batt_full_mah() { return 1500; }
bool periph_gauge_configured() { return true; }
bool periph_has_utc_time() { return true; }
void periph_get_utc_time(uint16_t* y, uint8_t* m, uint8_t* d, uint8_t* h, uint8_t* mi, uint8_t* s) { *y = 2026; *m = 9; *d = 21; *h = 18; *mi = 24; *s = 0; }
void periph_bl_set_mode(BlMode) {} BlMode periph_bl_get_mode() { return BL_AUTO; }
void periph_bl_set_duty(uint8_t) {} uint8_t periph_bl_get_duty() { return 128; }
bool periph_bl_is_active() { return true; } bool periph_is_after_sundown() { return false; }
bool periph_on_vbus() { return true; }
double periph_sun_elevation() { return 31; }
bool periph_poll_touch_event(TouchEvent*) { return false; }
bool periph_home_key() { return false; } bool periph_io48_key_down() { return false; }
void periph_power_off() {}
int txui_count() { return 10; }
static const char* TXIDS[10] = {"ORECCHINO-TX-WIFI", "ORECCHINO-TX-NAN", "ORECCHINO-TX-BLE5", "ORECCHINO-TX-BLELR", "ORECCHINO-TX-BLE4", "ORECCHINO-TX-V0", "ORECCHINO-TX-SINGLE", "ORECCHINO-TX-DUAL", "ORECCHINO-TX-AUTH", "ORECCHINO-TX-AUTHBAD"};
const char* txui_id(int i) { return TXIDS[i]; }
const char* txui_carrier(int i) { return i == 1 ? "NAN" : i == 2 ? "BLE5" : i == 3 ? "BLE LR" : i == 4 ? "BLE4" : "Wi-Fi"; }
static const char* TXDESC[10] = {"TEST path=WIFI-BEACON", "TEST path=WIFI-NAN", "TEST path=BLE5-1M", "TEST path=BLE5-CODED",
  "TEST path=BLE4-LEGACY", "TEST fmt=F3411-19-v0", "TEST fmt=SINGLE-MSG", "TEST fmt=DUAL-BASIC-ID", "TEST fmt=AUTH-SIGNED", "TEST fmt=AUTH-BADSIG"};
const char* txui_desc(int i) { return TXDESC[i]; }
bool txui_enabled(int i) { return i != 3; } void txui_set_enabled(int, bool) {}
uint32_t txui_sent(int i) { return 1234 * (i + 1); } bool txui_running() { return true; } void txui_set_running(bool) {}
bool txui_emergency() { return false; } void txui_set_emergency(bool) {}
void board_switch_mode(uint8_t) {}

// ---- fixture: the review's stress case, plus shared suffixes and a UUID
static void add_track(int i, const char* id, double brg, double range_m, float h, float spd, float hdg,
                      uint8_t status, uint8_t auth, bool tfr, uint32_t age_ms, uint8_t src) {
  Track* t = &g_tracks[i]; memset(t, 0, sizeof(*t));
  t->used = true; snprintf(t->uas, sizeof(t->uas), "%s", id);
  for (int k = 0; k < 6; k++) t->mac[k] = (uint8_t)(0x10 * (i + 1) + k);
  t->rssi = (int8_t)(-48 - 4 * i); t->peak_rssi = (int8_t)(-42 - 3 * i);
  t->src_mask = src; t->status = status; t->auth_state = auth; t->in_tfr = tfr;
  if (tfr) snprintf(t->tfr_id, sizeof(t->tfr_id), "6/3221");
  t->has_pos = range_m > 0;
  double br = brg * M_PI / 180;
  t->lat = g_home_lat + range_m * cos(br) / 111111.0;
  t->lon = g_home_lon + range_m * sin(br) / (111111.0 * cos(g_home_lat * M_PI / 180));
  t->height = h; t->height_ref = (uint8_t)(i & 1); t->max_height = isnan(h) ? NAN : h + 15;
  t->speed = spd; t->heading = hdg;
  t->last_ms = g_millis - age_ms; t->first_ms = g_millis - age_ms - 120000 - 7000 * i;
  t->msgs = (uint16_t)(384 - 20 * i);
}
static void fixture() {
  memset(g_tracks, 0, sizeof(g_tracks));
  g_millis = 600000;
  const char* P = "1581F204C68D9A";
  char id[48];
  for (int i = 0; i < 8; i++) {
    snprintf(id, sizeof(id), "%s%02d", P, i + 1);
    add_track(i, id, 17, 116 + 117 * i, 125 + 8 * i, 12 + i, (float)(i * 3), i == 0 ? 3 : 2,
              i == 0 ? 4 : i == 1 ? 3 : i == 3 ? 1 : 0, i == 2, i >= 6 ? 90000 : 2000 + 300 * i, 7);
  }
  add_track(8, "DRONE-B-9A01", 250, 640, 40, 6, 250, 2, 0, false, 4000, 4);           // shares a suffix with #1
  add_track(9, "0123456789abcdef0123456789abcdef01234567", 120, 1500, NAN, NAN, NAN, 1, 2, false, 12000, 1);  // UTM UUID, no telemetry
  add_track(10, "DJI-1", 300, 0, 60, 3, 90, 2, 0, false, 8000, 2);                    // short id, no position
  add_track(11, "", 200, 900, 20, 2, 180, 0, 0, false, 30000, 4);                     // MAC only
  snprintf(g_tracks[0].ssid, sizeof(g_tracks[0].ssid), "RID-%s", g_tracks[0].uas); g_tracks[0].ssid_check = 1; g_tracks[0].fmt = 1;
  snprintf(g_tracks[2].ssid, sizeof(g_tracks[2].ssid), "RID-1581F204C68D9A99"); g_tracks[2].ssid_check = 2; g_tracks[2].fmt = 3;
  snprintf(g_tracks[7].uas, sizeof(g_tracks[7].uas), "1581F6Z9C68D9A08");           // a serial the model table knows
  g_seen_count = 14;
  g_tfr_n = 3; g_tfr_loaded = true; g_tfr_ms = g_millis - 900000;
}

static void save_pgm(const char* name) {
  char path[256]; snprintf(path, sizeof(path), "%s/%s.pgm", getenv("T5_OUT") ? getenv("T5_OUT") : "/tmp", name);
  FILE* f = fopen(path, "wb"); if (!f) return;
  fprintf(f, "P5\n%d %d\n255\n", EPD_W, EPD_H);
  for (int y = 0; y < EPD_H; y++) for (int x = 0; x < EPD_W; x++) {
    uint8_t b = g_epd_fb[y * (EPD_W / 2) + x / 2];
    uint8_t v = (x & 1) ? (b >> 4) : (b & 0x0F);
    fputc(v * 17, f);
  }
  fclose(f);
}
static int g_fails = 0;
static void scene_check(const char* name) {
  int bad = 0;
  for (size_t i = 0; i < g_runs.size(); i++)
    for (size_t j = i + 1; j < g_runs.size(); j++) {
      const TextRun &a = g_runs[i], &b = g_runs[j];
      if (a.x0 < b.x1 && b.x0 < a.x1 && a.y0 < b.y1 && b.y0 < a.y1) {
        if (bad < 6) printf("   overlap: \"%s\" [%d,%d-%d,%d] x \"%s\" [%d,%d-%d,%d]\n", a.s.c_str(), a.x0, a.y0, a.x1, a.y1, b.s.c_str(), b.x0, b.y0, b.x1, b.y1);
        bad++;
      }
    }
  printf("%s %s: %zu text runs, %d colliding pair(s)\n", bad ? "FAIL" : "ok  ", name, g_runs.size(), bad);
  if (bad) g_fails++;
  save_pgm(name);
  g_runs.clear();
}

int main() {
  fixture();
  g_home_set = true; p_gps_det = true; p_gps_fix = true;
  ui_begin(UI_MODE_RX);                         // splash, then the board
  g_runs.clear();
  s_now = g_millis; build_order(); select_row(0);
  draw_board(true);           scene_check("t5_table");
  // A modal covers the board: check the modal's own runs, keep the full picture.
  s_inspector = true; draw_board(false); g_runs.clear(); draw_inspector_modal(); scene_check("t5_inspector"); s_inspector = false;
  s_confirm_switch = true; s_target_mode = UI_TARGET_POWER_OFF; draw_board(false); g_runs.clear(); draw_switch_modal(); scene_check("t5_confirm"); s_confirm_switch = false;
  g_home_set = false; p_gps_det = false; p_gps_fix = false;
  draw_board(true);           scene_check("t5_card");
  g_home_set = true; p_gps_det = true; p_gps_fix = true;
  s_map = true; s_cam_manual = false; map_camera(); s_cam_manual = true; draw_board(true); scene_check("t5_map");
  s_map = false; s_cam_manual = false;
  s_diag = true; draw_board(true); scene_check("t5_diag"); s_diag = false;
  s_mode = UI_MODE_TX; draw_board(true); scene_check("t5_tx"); s_mode = UI_MODE_RX;
  draw_glance();              scene_check("t5_glance");
  memset(g_tracks, 0, sizeof(g_tracks)); build_order(); draw_board(true); scene_check("t5_empty");
  fixture();

  // Selection follows the aircraft through a re-sort, an alert and an expiry.
  s_now = g_millis; build_order(); select_row(2);
  const Track* chosen = &g_tracks[s_order[s_sel]];
  g_tracks[s_order[5]].status = 3;                   // another aircraft goes loud: moves to the top
  g_tracks[s_order[7]].used = false;                 // one expires
  g_tracks[s_order[6]].last_ms = g_millis;           // and one just spoke
  build_order();
  bool same = s_sel >= 0 && &g_tracks[s_order[s_sel]] == chosen;
  printf("%s selection survives re-sort/alert/expiry (row %d)\n", same ? "ok  " : "FAIL", s_sel);
  if (!same) g_fails++;
  // The chosen aircraft expires and a newcomer takes its slot before the
  // next tick: the selection must re-resolve (to some real row), never keep
  // the old creation stamp while pointing at the newcomer's slot.
  int slot = s_order[s_sel];
  uint32_t old_stamp = s_selid.first_ms;
  g_tracks[slot].used = true;
  g_tracks[slot].first_ms = g_millis + 1;
  build_order();
  bool resolved = s_sel >= 0 && s_sel < s_n && s_selid.first_ms != old_stamp &&
                  s_selid.first_ms == g_tracks[s_order[s_sel]].first_ms;
  printf("%s a reused slot is not mistaken for the old selection\n", resolved ? "ok  " : "FAIL");
  if (!resolved) g_fails++;

  // The map re-tone, on dark_all's palette: land is paper, streets are
  // darker than water and buildings and dark enough to show (the panel
  // renders grey 3-10 distinctly), labels darkest. A plain inversion had
  // made roads as light as land.
  {
    unsigned land = map_tone(9), building = map_tone(6), street = map_tone(25),
             water = map_tone(34), label = map_tone(66);
    bool ok = land == 15 && building < land && water < land && street < water &&
              street < building && street <= 6 && label < street;
    printf("%s map tones: land %u, buildings %u, water %u, streets %u, labels %u\n",
           ok ? "ok  " : "FAIL", land, building, water, street, label);
    if (!ok) g_fails++;
  }

  if (g_fails) printf("%d FAILED\n", g_fails); else printf("all T5 render checks passed\n");
  return g_fails ? 1 : 0;
}
