// Host render of the T-Embed handheld: the production drawing code
// (ui_tembed.cpp, included whole so its statics are reachable) painting the
// same stress fixture as the T5 check into a 320x170 RGB565 canvas with the
// real fonts. Every scene is saved as a PPM for eyes and checked for text
// runs that collide, leave the screen, or wrap at the right edge (the
// library wraps by default, which splits a long line onto the next row).
//
// Needs the Adafruit GFX fonts; run_tests.sh skips it when they are absent.
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
#include "Arduino.h"
#include <string>
#include <vector>

struct TextRun { int x0, y0, x1, y1; std::string s; bool wrapped; };
static std::vector<TextRun> g_runs;
#define UI_TEXT_RUN(x0, y0, x1, y1, s, wrapped) g_runs.push_back({x0, y0, x1, y1, s, wrapped})
#include "Arduino_GFX_Library.h"
#include "ui_tembed.cpp"

// ---- what the sketch, the core and the peripherals would provide
Track    g_tracks[TRK_MAX];
uint32_t g_seen_count = 0;
bool     g_home_set = false;
double   g_home_lat = 37.8039, g_home_lon = -122.4640;
uint8_t  g_tfr_n = 0; bool g_tfr_loaded = false; uint32_t g_tfr_ms = 0;
bool rx_get_home(double* lat, double* lon) { if (!g_home_set) return false; *lat = g_home_lat; *lon = g_home_lon; return true; }
void rx_log_flush() {}
void ring_begin() {} void ring_tick(uint32_t, uint8_t, float) {} void ring_off() {} void ring_set_dim(bool) {}
bool cc1101_sweep_begin() { return true; }
uint32_t cc1101_bin_hz(int i) { return 300000000u + (uint32_t)i * 4900000u; }
void cc1101_sweep_chunk(int8_t*, int*, int) {} void cc1101_sweep_stop() {}
static const char* TXIDS[10] = {"ORECCHINO-TX-WIFI", "ORECCHINO-TX-NAN", "ORECCHINO-TX-BLE5", "ORECCHINO-TX-BLELR",
  "ORECCHINO-TX-BLE4", "ORECCHINO-TX-V0", "ORECCHINO-TX-SINGLE", "ORECCHINO-TX-DUAL", "ORECCHINO-TX-AUTH", "ORECCHINO-TX-AUTHBAD"};
static const char* TXCARR[10] = {"Wi-Fi", "NAN", "BLE5", "BLE LR", "BLE4", "Wi-Fi", "Wi-Fi", "Wi-Fi", "Wi-Fi", "Wi-Fi"};
int txui_count() { return 10; }
const char* txui_id(int i) { return TXIDS[i]; }
const char* txui_carrier(int i) { return TXCARR[i]; }
static int p_tx_bad_row = 0, p_tx_master = 0;   // path indices off the list; master toggles
bool txui_enabled(int i) { if (i < 0 || i >= 10) p_tx_bad_row++; return i != 3; }
void txui_set_enabled(int i, bool) { if (i < 0 || i >= 10) p_tx_bad_row++; }
uint32_t txui_sent(int i) { return 1234 * (i + 1); } bool txui_running() { return true; } void txui_set_running(bool) { p_tx_master++; }
bool txui_emergency() { return false; } void txui_set_emergency(bool) {}
bool txui_slow() { return false; } void txui_set_slow(bool) {}
void board_switch_mode(uint8_t) {}
// The receiver core's match log, as the menu sees it (rx_core.h is not in
// this unit; tests/core_test.cpp checks the real clear, save and broadcast).
static int p_log_held = 48, p_log_clears = 0;
void rx_log_clear_all() { p_log_held = 0; p_log_clears++; }
void rx_log_stats(int* held, uint32_t* oldest_age_s) { *held = p_log_held; *oldest_age_s = p_log_held ? 7200 : UINT32_MAX; }

// ---- fixture: the T5 check's stress case
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
  add_track(8, "DRONE-B-9A01", 250, 640, 40, 6, 250, 2, 0, false, 4000, 4);
  add_track(9, "0123456789abcdef0123456789abcdef01234567", 120, 1500, NAN, NAN, NAN, 1, 2, false, 12000, 1);
  add_track(10, "DJI-1", 300, 0, 60, 3, 90, 2, 0, false, 8000, 2);
  add_track(11, "", 200, 900, 20, 2, 180, 0, 0, false, 30000, 4);
  g_seen_count = 14;
}

static void save_ppm(const char* name) {
  char path[256]; snprintf(path, sizeof(path), "%s/%s.ppm", getenv("TEMBED_OUT") ? getenv("TEMBED_OUT") : "/tmp", name);
  FILE* f = fopen(path, "wb"); if (!f) return;
  fprintf(f, "P6\n%d %d\n255\n", W, H);
  const uint16_t* fb = s_cv->getFramebuffer();
  for (int i = 0; i < W * H; i++) {
    uint16_t c = fb[i];
    fputc(((c >> 11) & 31) * 255 / 31, f); fputc(((c >> 5) & 63) * 255 / 63, f); fputc((c & 31) * 255 / 31, f);
  }
  fclose(f);
}
static int g_fails = 0;
static void scene_check(const char* name) {
  int bad = 0;
  for (size_t i = 0; i < g_runs.size(); i++) {
    const TextRun& a = g_runs[i];
    if (a.wrapped || a.x0 < 0 || a.y0 < 0 || a.x1 > W || a.y1 > H) {
      if (bad < 8) printf("   off screen%s: \"%s\" [%d,%d-%d,%d]\n", a.wrapped ? " (wrapped)" : "", a.s.c_str(), a.x0, a.y0, a.x1, a.y1);
      bad++;
    }
    for (size_t j = i + 1; j < g_runs.size(); j++) {
      const TextRun& b = g_runs[j];
      if (a.x0 < b.x1 && b.x0 < a.x1 && a.y0 < b.y1 && b.y0 < a.y1) {
        if (bad < 8) printf("   overlap: \"%s\" [%d,%d-%d,%d] x \"%s\" [%d,%d-%d,%d]\n", a.s.c_str(), a.x0, a.y0, a.x1, a.y1, b.s.c_str(), b.x0, b.y0, b.x1, b.y1);
        bad++;
      }
    }
  }
  printf("%s %s: %zu text runs, %d problem(s)\n", bad ? "FAIL" : "ok  ", name, g_runs.size(), bad);
  if (bad) g_fails++;
  save_ppm(name);
  g_runs.clear();
}

int main() {
  fixture();
  ui_begin(UI_MODE_RX);
  g_runs.clear();
  s_now = g_millis;
  g_home_set = true;
  build_order(); draw_scope();                    scene_check("tembed_scope");
  s_sel = 4; ui_sel_set(&s_selid, s_order[4]); build_order(); draw_scope(); scene_check("tembed_scope_scrolled");
  s_sel = 0; ui_sel_set(&s_selid, s_order[0]); build_order();
  draw_detail();                                  scene_check("tembed_detail");
  // The selected aircraft's next fix is 60 m closer: the rate is 60 m over
  // the time between its fixes, and the view says closing.
  {
    Track* t = &g_tracks[s_order[s_sel]];
    uint32_t t0 = t->last_ms;
    double d = ui_dist_m(g_home_lat, g_home_lon, t->lat, t->lon);
    t->lat = g_home_lat + (t->lat - g_home_lat) * (d - 60) / d;
    t->lon = g_home_lon + (t->lon - g_home_lon) * (d - 60) / d;
    g_millis += 5000; t->last_ms = g_millis; s_now = g_millis;
    float rate = 0;
    bool ok = ui_range_rate(s_order[s_sel], t, s_now, &rate);
    float want = -60.0f * 1000.0f / (float)(t->last_ms - t0);
    bool right = ok && fabsf(rate - want) < 0.5f;
    printf("%s range rate: %.1f m/s, expected %.1f\n", right ? "ok  " : "FAIL", rate, want);
    if (!right) g_fails++;
    draw_scope();                                 scene_check("tembed_scope_closing");
    bool shows = false;
    draw_detail();
    for (auto& r : g_runs) if (r.s == "closing") shows = true;
    scene_check("tembed_detail_closing");
    printf("%s the detail view says closing\n", shows ? "ok  " : "FAIL");
    if (!shows) g_fails++;
  }
  g_home_set = false; draw_detail();              scene_check("tembed_detail_nohome");
  g_home_set = true;
  for (int i = 0; i < 13; i++) s_a24[i] = -95 + 3 * i;
  for (int i = 0; i < CC_SWEEP_BINS; i++) { s_swp[i] = (int8_t)(-100 + (i % 17 == 0 ? 40 : i % 5)); s_pk[i] = s_swp[i] + 6; }
  s_cc_ok = true; draw_spectrum();                scene_check("tembed_spectrum");
  s_menu_sel = 1; draw_menu();
  {
    // The selection box's top and bottom edges must not run through a line
    // of text (they once cut through the subtitle).
    int top = MENU_Y(1), bot = MENU_Y(1) + MENU_RH - 2, cut = 0;
    for (const TextRun& r : g_runs)
      if ((r.y0 <= top && r.y1 > top) || (r.y0 <= bot && r.y1 > bot)) {
        printf("   \"%s\" [%d-%d] crosses the menu box edge (%d / %d)\n", r.s.c_str(), r.y0, r.y1, top, bot);
        cut++;
      }
    printf("%s menu box clear of its text\n", cut ? "FAIL" : "ok  ");
    if (cut) g_fails++;
  }
  scene_check("tembed_menu");
  // Clear history: a click asks (CANCEL chosen), the knob picks CLEAR, a
  // click clears; CANCEL, or the side key, keeps everything.
  {
    auto click = [&](int pin) {
      g_pin_low = pin; g_millis += 20; ui_tick(g_millis, true, 80);
      g_millis += 120; ui_tick(g_millis, true, 80);
      g_pin_low = -1; g_millis += 20; ui_tick(g_millis, true, 80);
    };
    s_mode = UI_MODE_RX; s_view = V_MENU; s_menu_sel = MENU_CLEAR; s_clear_ask = false;
    g_runs.clear(); draw_menu(); scene_check("tembed_menu_clear");
    click(PIN_ENC_KEY);
    bool asks = s_clear_ask && s_clear_sel == 0 && p_log_clears == 0;
    printf("%s Clear history asks first, CANCEL chosen\n", asks ? "ok  " : "FAIL"); if (!asks) g_fails++;
    g_runs.clear(); draw_menu(); scene_check("tembed_clear_ask");
    click(PIN_ENC_KEY);                                   // CANCEL
    bool kept = !s_clear_ask && p_log_clears == 0 && p_log_held == 48;
    printf("%s CANCEL keeps the history\n", kept ? "ok  " : "FAIL"); if (!kept) g_fails++;
    click(PIN_ENC_KEY); click(PIN_USER_KEY);              // ask, then back out with the side key
    kept = !s_clear_ask && s_view == V_MENU && p_log_clears == 0;
    printf("%s the side key backs out without clearing\n", kept ? "ok  " : "FAIL"); if (!kept) g_fails++;
    click(PIN_ENC_KEY);
    s_enc_pos += 1; g_millis += 200; ui_tick(g_millis, true, 80);   // turn: CLEAR
    g_runs.clear(); draw_menu(); scene_check("tembed_clear_ask_clear");
    click(PIN_ENC_KEY);
    bool cleared = !s_clear_ask && p_log_clears == 1 && p_log_held == 0;
    printf("%s CLEAR clears the history (rx_log_clear_all)\n", cleared ? "ok  " : "FAIL"); if (!cleared) g_fails++;
    g_runs.clear(); draw_menu();
    bool said = false; for (auto& r : g_runs) if (r.s == "history cleared") said = true;
    printf("%s the menu then says history cleared\n", said ? "ok  " : "FAIL"); if (!said) g_fails++;
    scene_check("tembed_menu_cleared");
    // "history cleared" lasts 5 s, also across millis() wrapping (~49.7 days).
    uint32_t keep_now = s_now;
    s_cleared = true; s_cleared_ms = 0xFFFFF000u; p_log_held = 48;
    char hb[48];
    s_now = 0xFFFFF100u; history_words(hb, sizeof(hb));
    bool wrap_on = !strcmp(hb, "history cleared");
    s_now = 0x00000100u; history_words(hb, sizeof(hb));
    wrap_on = wrap_on && !strcmp(hb, "history cleared");
    s_now = 0x00002000u; history_words(hb, sizeof(hb));
    bool wrap_off = strcmp(hb, "history cleared") != 0;
    printf("%s \"history cleared\" lasts 5 s across the millis() wrap\n", wrap_on && wrap_off ? "ok  " : "FAIL");
    if (!(wrap_on && wrap_off)) g_fails++;
    s_cleared = false; s_now = keep_now;
    s_view = V_SCOPE; p_log_held = 48;
  }
  s_tx_sel = 4; draw_tx();                        scene_check("tembed_tx");
  // A turn past either end and a click in the same pass act on the end row,
  // never on a path index off the list (the click is handled before the draw
  // that used to be the only clamp).
  {
    s_view = V_TX; p_tx_bad_row = 0;
    auto turn_and_click = [&](int det) {
      g_pin_low = PIN_ENC_KEY; g_millis += 20; ui_tick(g_millis, true, 80);
      g_millis += 120; ui_tick(g_millis, true, 80);
      s_enc_pos += det; g_pin_low = -1; g_millis += 20; ui_tick(g_millis, true, 80);
    };
    s_tx_sel = 0; int m0 = p_tx_master;
    turn_and_click(-1);
    bool low = s_tx_sel == 0 && p_tx_master == m0 + 1;
    s_tx_sel = txui_count() + 2;
    turn_and_click(+3);
    bool high = s_tx_sel == txui_count() + 2;
    bool ok = low && high && p_tx_bad_row == 0;
    printf("%s TX list: a turn past the end and a click in one pass stay on the list\n", ok ? "ok  " : "FAIL");
    if (!ok) g_fails++;
    s_view = V_SCOPE; s_tx_sel = 4; g_runs.clear();
  }
  // Only what changed goes over SPI: an identical frame sends nothing, a
  // clock tick a band or two.
  {
    fixture(); s_now = g_millis; g_home_set = true; build_order();
    draw_scope(); g_runs.clear();
    uint32_t before = s_rows_sent; draw_scope(); uint32_t same = s_rows_sent - before;
    g_millis += 1000; s_now = g_millis;
    before = s_rows_sent; draw_scope(); uint32_t tick = s_rows_sent - before;
    g_runs.clear();
    bool ok = same == 0 && tick > 0 && tick <= 30;
    printf("%s partial flush: identical frame %u rows, one second later %u of %d rows\n",
           ok ? "ok  " : "FAIL", (unsigned)same, (unsigned)tick, H);
    if (!ok) g_fails++;
  }
  memset(g_tracks, 0, sizeof(g_tracks)); build_order();
  draw_scope();                                   scene_check("tembed_empty");
  draw_detail();                                  scene_check("tembed_detail_empty");

  if (g_fails) printf("%d FAILED\n", g_fails); else printf("all T-Embed render checks passed\n");
  return g_fails ? 1 : 0;
}
