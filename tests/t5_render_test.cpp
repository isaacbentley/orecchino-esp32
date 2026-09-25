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
char     g_home_src[16] = "app";
bool rx_get_home(double* lat, double* lon) { if (!g_home_set) return false; *lat = g_home_lat; *lon = g_home_lon; return true; }
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
static int p_pulses = 0; void periph_bl_pulse(uint8_t n) { p_pulses += n; }
static float p_elev = NAN; float periph_gps_elev_m() { return p_elev; }
bool periph_on_vbus() { return true; }
double periph_sun_elevation() { return 31; }
// Touches the harness feeds to ui_tick, oldest first.
static TouchEvent p_touch[8]; static int p_touch_n = 0;
bool periph_poll_touch_event(TouchEvent* e) {
  if (!p_touch_n) return false;
  *e = p_touch[0];
  memmove(p_touch, p_touch + 1, sizeof(TouchEvent) * --p_touch_n);
  return true;
}
static void touch(int x, int y, uint32_t ms = 0) {
  TouchEvent e = {}; e.type = TOUCH_EVT_TAP; e.x = (int16_t)x; e.y = (int16_t)y; e.ms = ms ? ms : g_millis;
  p_touch[p_touch_n++] = e;
}
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
static bool g_tx_slow = false;
bool txui_slow() { return g_tx_slow; } void txui_set_slow(bool on) { g_tx_slow = on; }
void board_switch_mode(uint8_t) {}
// The receiver core's match log, as the screen sees it (rx_core.h is not in
// this unit; tests/core_test.cpp checks the real clear, save and broadcast).
static int p_log_held = 48, p_log_clears = 0;
void rx_log_clear_all() { p_log_held = 0; p_log_clears++; }
void rx_log_stats(int* held, uint32_t* oldest_age_s) { *held = p_log_held; *oldest_age_s = p_log_held ? 7200 : UINT32_MAX; }

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
  t->alt_geo = isnan(h) ? NAN : h + 40;   // take-off 40 m above the ellipsoid, like the board
  t->speed = spd; t->heading = hdg;
  t->last_ms = g_millis - age_ms; t->first_ms = g_millis - age_ms - 120000 - 7000 * i;
  t->msgs = (uint16_t)(384 - 20 * i);
}
static void fixture() {
  memset(g_tracks, 0, sizeof(g_tracks));
  g_millis = 600000;
  const char* P = "1581F204C68D9A";
  char id[48];
  // Signatures: #1 invalid, #2 valid, #4 pages still coming, #5 the
  // published test key (TEST, never OK), the rest none.
  for (int i = 0; i < 8; i++) {
    snprintf(id, sizeof(id), "%s%02d", P, i + 1);
    add_track(i, id, 17, 116 + 117 * i, 125 + 8 * i, 12 + i, (float)(i * 3), i == 0 ? 3 : 2,
              i == 0 ? 4 : i == 1 ? 3 : i == 3 ? 1 : i == 4 ? 5 : 0, i == 2, i >= 6 ? 90000 : 2000 + 300 * i, 7);
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
/// Text the board had to cut ("..", fit_text): a sentence the reader loses
/// the end of. Allowed only where the thing cut is an identifier the screen
/// shows whole elsewhere (the inspector's UAS ID and SSID lines, under a
/// title that carries the ID).
static bool cut_allowed(const std::string& s) {
  static const char* ok[] = { "UAS ID: ", "SSID: ", "DRONE " };
  for (const char* p : ok) if (!s.compare(0, strlen(p), p)) return true;
  // The board's own ellipses ("Other network...", the AUTH column's "...")
  // are three dots; a cut is two.
  return s.size() >= 3 && !s.compare(s.size() - 3, 3, "...");
}
static void scene_check(const char* name) {
  int bad = 0, cut = 0;
  for (size_t i = 0; i < g_runs.size(); i++) {
    const TextRun& a = g_runs[i];
    if (a.s.size() > 2 && !a.s.compare(a.s.size() - 2, 2, "..") && !cut_allowed(a.s)) {
      if (cut < 6) printf("   cut: \"%s\" [%d,%d-%d,%d]\n", a.s.c_str(), a.x0, a.y0, a.x1, a.y1);
      cut++;
    }
    for (size_t j = i + 1; j < g_runs.size(); j++) {
      const TextRun& b = g_runs[j];
      if (a.x0 < b.x1 && b.x0 < a.x1 && a.y0 < b.y1 && b.y0 < a.y1) {
        if (bad < 6) printf("   overlap: \"%s\" [%d,%d-%d,%d] x \"%s\" [%d,%d-%d,%d]\n", a.s.c_str(), a.x0, a.y0, a.x1, a.y1, b.s.c_str(), b.x0, b.y0, b.x1, b.y1);
        bad++;
      }
    }
  }
  printf("%s %s: %zu text runs, %d colliding pair(s), %d cut\n", bad || cut ? "FAIL" : "ok  ", name, g_runs.size(), bad, cut);
  if (bad || cut) g_fails++;
  save_pgm(name);
  g_runs.clear();
}
/// The run that says `s`, or null.
static const TextRun* run_of(const char* s) {
  for (const TextRun& r : g_runs) if (strstr(r.s.c_str(), s)) return &r;
  return nullptr;
}

// ---- ADS-B traffic: ten aircraft around the fixture, one of them 1.1 km NE
// of drone D9A03 and 90 m above it (a warning), one low, one squawking 7700,
// one with an old position, one with no callsign.
static TrafficAircraft ac_at(const char* hex, const char* cs, const char* ty, double brg, double range_m,
                             double geom_m, double baro_ft, double kt, double trk, double fpm, uint32_t age_ms,
                             double from_lat, double from_lon) {
  TrafficAircraft a; memset(&a, 0, sizeof(a));
  snprintf(a.hex, sizeof(a.hex), "%s", hex); snprintf(a.callsign, sizeof(a.callsign), "%s", cs);
  snprintf(a.type, sizeof(a.type), "%s", ty);
  double br = brg * M_PI / 180;
  a.lat = from_lat + range_m * cos(br) / 111194.93;
  a.lon = from_lon + range_m * sin(br) / (111194.93 * cos(from_lat * M_PI / 180));
  a.alt_geom_m = geom_m; a.alt_baro_m = isnan(baro_ft) ? NAN : baro_ft * TRAFFIC_FT_TO_M;
  a.gs_mps = kt * TRAFFIC_KT_TO_MPS; a.track_deg = trk; a.vs_mps = isnan(fpm) ? NAN : fpm * TRAFFIC_FT_TO_M / 60;
  a.seen_ms = g_millis - age_ms;
  return a;
}
static void place(int i, double brg, double range_m) {
  double br = brg * M_PI / 180;
  g_tracks[i].lat = g_home_lat + range_m * cos(br) / 111111.0;
  g_tracks[i].lon = g_home_lon + range_m * sin(br) / (111111.0 * cos(g_home_lat * M_PI / 180));
}
static void traffic_fixture(bool stale = false) {
  // The live drones spread around the board, as a real field would have them.
  place(0, 17, 116); place(1, 330, 400); place(2, 60, 700); place(3, 150, 500); place(4, 200, 300); place(5, 280, 800);
  const Track* d = &g_tracks[2];   // 1581F204C68D9A03: 700 m at 060, 141 m up, alt_geo 181
  int n = 0;
  g_traffic_ac[n++] = ac_at("a1b2c3", "UAL123", "B738", 45, 900, 271, 850, 140, 30, -640, 3000, d->lat, d->lon);
  g_traffic_ac[n++] = ac_at("a0c4f1", "N512KX", "C172", 225, 2600, 350, 1050, 95, 40, 0, 5000, g_home_lat, g_home_lon);
  g_traffic_ac[n++] = ac_at("ab77e2", "DAL2045", "A321", 300, 14000, 5200, 16800, 390, 120, 1800, 2000, g_home_lat, g_home_lon);
  g_traffic_ac[n++] = ac_at("c0ffee", "SKW5432", "E75L", 160, 9000, 2100, 6600, 250, 330, -1500, 4000, g_home_lat, g_home_lon);
  g_traffic_ac[n++] = ac_at("a7700a", "N77EM", "PA28", 95, 12000, 900, 2800, 100, 270, NAN, 6000, g_home_lat, g_home_lon);
  g_traffic_ac[n - 1].squawk = 7700; g_traffic_ac[n - 1].emergency = true;
  g_traffic_ac[n++] = ac_at("a3e5d7", "", "", 20, 6500, 1500, 4700, 180, 200, 0, 8000, g_home_lat, g_home_lon);
  g_traffic_ac[n++] = ac_at("a44444", "ASA88", "B39M", 270, 22000, 10500, 34000, 450, 90, 0, 45000, g_home_lat, g_home_lon);
  g_traffic_ac[n++] = ac_at("a55555", "CPA873", "B77W", 350, 26000, 11200, 36000, 480, 170, 0, 3000, g_home_lat, g_home_lon);
  g_traffic_ac[n++] = ac_at("a66666", "LIFE1", "EC35", 120, 4200, 600, 1800, 110, 300, 200, 2000, g_home_lat, g_home_lon);
  g_traffic_ac[n++] = ac_at("a88888", "JBU15", "A320", 60, 18000, 2600, 8200, 280, 240, -900, 7000, g_home_lat, g_home_lon);
  g_traffic_ac[n++] = ac_at("a99999", "N123GD", "C208", 180, 1500, NAN, NAN, 12, 110, NAN, 4000, g_home_lat, g_home_lon);
  g_traffic_ac[n - 1].on_ground = true;   // taxiing 0.7 km from the MAC-only drone (900 m at 200)
  g_traffic_count = (uint8_t)n;
  g_traffic_have = true; g_traffic_rx_ms = g_millis;
  g_traffic_data_ms = g_millis - (stale ? 45000 : 6000);
  traffic_state_reset(&g_traffic_state);
  s_nwarn_keys = 0;
  p_elev = 40;
}
static void traffic_clear() {
  g_traffic_count = 0; g_traffic_have = false;
  traffic_state_reset(&g_traffic_state); memset(&g_traffic_result, 0, sizeof(g_traffic_result));
  s_nwarn_keys = 0; s_ac_hex[0] = 0;
}

// ---- Wi-Fi: networks as a scan would leave them, one saved.
static void wifi_fixture() {
  const char* names[7] = { "Hangar-Secure", "Airfield-Guest", "PilotLounge", "DroneNet_5G",
                           "A-very-long-network-name-32-chr", "OpenField", "Tower" };
  const int8_t rssi[7] = { -52, -61, -70, -79, -66, -58, -85 };
  const uint8_t auth[7] = { 3, 3, 3, 3, 4, 0, 3 };
  ScannedNetwork nets[7];
  for (int i = 0; i < 7; i++) {
    ScannedNetwork* n = &nets[i]; memset(n, 0, sizeof(*n));
    snprintf(n->ssid, sizeof(n->ssid), "%s", names[i]); n->rssi = rssi[i]; n->auth_mode = auth[i];
    n->channel = (uint8_t)(1 + i); n->saved = i == 0;
  }
  net_debug_set_scanned(nets, 7);
  net_debug_set_saved("Hangar-Secure", "hunter22", NET_MODE_SYNC, 15);
  net_debug_set_scanning(false);
  net_debug_set_state(NET_STATE_DISCONNECTED, "", "");
  net_debug_set_last_sync(1790001840);
  // The ADS-B radius, the map area, and the last tile plan (3 km at z12-14,
  // z15 shrunk to 2 km to fit). No debug setter for these: set as the tick would.
  g_net.cfg.adsb_km = 10; g_net.cfg.tile_km = 3;
  memset(&g_net.plan, 0, sizeof(g_net.plan));
  g_net.plan.radius_m[0] = g_net.plan.radius_m[1] = g_net.plan.radius_m[2] = 3000; g_net.plan.radius_m[3] = 2000;
  g_net.plan.plan_bytes = 1153434; g_net.plan.capacity = 13107200; g_net.plan.shrunk = true;
  g_net.have_plan = true; g_net.tile_max_m = 12000;
}

// ---- pixel checks
static uint8_t px_at(int x, int y) {
  uint8_t b = g_epd_fb[y * (EPD_W / 2) + x / 2];
  return (x & 1) ? (b >> 4) : (b & 0x0F);
}
/// Marks outside their panel: after drawing one panel on a white page, no
/// pixel outside `r` may be anything but white.
static void panel_check(const char* name, EpdRect r) {
  int bad = 0, bx = -1, by = -1;
  for (int y = 0; y < EPD_H; y++) for (int x = 0; x < EPD_W; x++) {
    if (x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height) continue;
    if (px_at(x, y) != 15) { if (!bad) { bx = x; by = y; } bad++; }
  }
  printf("%s %s: %d pixel(s) outside its panel%s", bad ? "FAIL" : "ok  ", name, bad, bad ? "" : "\n");
  if (bad) { printf(" (first at %d,%d)\n", bx, by); g_fails++; }
  g_runs.clear();
}
/// Stale pixels: what a partial path left on the page must equal a full redraw.
static uint8_t g_snap[EPD_W * EPD_H / 2];
static void snap() { memcpy(g_snap, g_epd_fb, sizeof(g_snap)); }
static void same_as_snap(const char* name) {
  int bad = 0, bx = -1, by = -1;
  for (int y = 0; y < EPD_H; y++) for (int x = 0; x < EPD_W; x++) {
    uint8_t a = g_snap[y * (EPD_W / 2) + x / 2], b = g_epd_fb[y * (EPD_W / 2) + x / 2];
    uint8_t va = (x & 1) ? a >> 4 : a & 15, vb = (x & 1) ? b >> 4 : b & 15;
    if (va != vb) { if (!bad) { bx = x; by = y; } bad++; }
  }
  printf("%s %s: %d pixel(s) differ from a full redraw%s", bad ? "FAIL" : "ok  ", name, bad, bad ? "" : "\n");
  if (bad) { printf(" (first at %d,%d)\n", bx, by); g_fails++; }
  g_runs.clear();
}
static void check(bool ok, const char* what) {
  printf("%s %s\n", ok ? "ok  " : "FAIL", what);
  if (!ok) g_fails++;
}
/// Traffic wording (traffic.h): never these words on any scene; "clear"
/// only in the instruction "KEEP CLEAR OF"; never a count of aircraft or a
/// "nearest traffic" (the board lists drones; ADS-B is for conflicts only).
static bool s_expect_action = false;   // the scene shows an alert: its action must be there
static void words_check(const char* name) {
  static const char* bad[] = { "collision", "safe", "tcas", "nm", "tau", "fl" };
  int hits = 0; bool action = false;
  for (const TextRun& r : g_runs) {
    std::string t;
    for (char c : r.s) t += (char)tolower((unsigned char)c);
    if (strstr(t.c_str(), "give way") || strstr(t.c_str(), "keep clear of") || strstr(t.c_str(), "be ready to land")) action = true;
    auto flag = [&](const char* why) { if (hits < 4) printf("   %s in \"%s\"\n", why, r.s.c_str()); hits++; };
    if (strstr(t.c_str(), "conflict resolved")) flag("\"conflict resolved\"");
    if (strstr(t.c_str(), "nearest traffic") || strstr(t.c_str(), "aircraft within") ||
        strstr(t.c_str(), "no ads-b traffic")) flag("aircraft wording outside a conflict");
    for (size_t k = 0; k + 1 < t.size(); k++) {   // "ADS-B 12", "TRAFFIC 3", "12 aircraft": counts of aircraft
      if (!isdigit((unsigned char)t[k + 1]) || t[k] != ' ') continue;
      size_t e = k + 1; while (e < t.size() && isdigit((unsigned char)t[e])) e++;
      if (!t.compare(e, 6, " s old")) continue;   // "ADS-B 6 s old": an age, not a count
      if ((k >= 5 && !t.compare(k - 5, 5, "ads-b")) || (k >= 7 && !t.compare(k - 7, 7, "traffic"))) flag("an aircraft count");
    }
    // "12 aircraft", "1 low aircraft", "2 more aircraft": a number within
    // the three words before "aircraft" is a count of them.
    for (size_t p = t.find("aircraft"); p != std::string::npos; p = t.find("aircraft", p + 8)) {
      size_t i = p; int words = 0; bool counted = false;
      while (i > 0 && words < 3 && !counted) {
        size_t e = i; while (e > 0 && t[e - 1] == ' ') e--;
        size_t b = e; while (b > 0 && isalnum((unsigned char)t[b - 1])) b--;
        if (b == e) break;   // punctuation: not the same clause
        std::string w = t.substr(b, e - b);
        if (!w.empty() && isdigit((unsigned char)w[0])) counted = true;
        i = b; words++;
      }
      if (counted) flag("an aircraft count");
    }
    size_t i = 0;
    while (i < t.size()) {
      while (i < t.size() && !isalnum((unsigned char)t[i])) i++;
      size_t j = i;
      while (j < t.size() && isalnum((unsigned char)t[j])) j++;
      std::string w = t.substr(i, j - i);
      for (const char* b : bad) if (w == b) flag("forbidden word");
      // ...and the CLEAR HISTORY control and its confirmation, which clear records, not airspace.
      bool history = !t.compare(j, 8, " history") || !t.compare(i, 10, "clear the ");
      if (w == "clear" && !history && !(i >= 5 && !t.compare(i - 5, 5, "keep ") && !t.compare(j, 3, " of"))) flag("\"clear\" outside KEEP CLEAR OF");
      i = j;
    }
  }
  if (s_expect_action && !action) { printf("   no alert action on screen\n"); hits++; }
  if (hits) { printf("FAIL %s: %d wording problem(s)\n", name, hits); g_fails++; }
}
/// Aircraft drawn only in an alert: every mark the last view placed is an
/// alerting aircraft's.
static void drawn_check(const char* name) {
  int bad = 0;
  for (int j = 0; j < s_pac_n; j++) if (!traffic_alert_for_hex(&g_traffic_result, s_pac_hex[j])) bad++;
  if (bad) { printf("FAIL %s: %d aircraft drawn without an alert\n", name, bad); g_fails++; }
}
/// The scene: collisions, forbidden traffic words, then the picture.
static void traffic_scene(const char* name) { words_check(name); drawn_check(name); scene_check(name); }
static void tick(uint32_t step = 10) { g_millis += step; ui_tick(g_millis, true, 76, -1); }
/// A tap of the BOOT button: down, held under the 2 s power-off hold, released.
static void boot_tap() { g_pin_low = PIN_BOOT_BTN; tick(); tick(100); g_pin_low = -1; tick(); }
/// The side view's ceiling label: whole, and no mark under it (a drone at
/// 120 m used to leave it reading "20 M / 400 FT CEILING").
static void ceiling_check(const char* name) {
  const TextRun* r = run_of("120 M / 400 FT CEILING");
  int under = 0;
  if (r) {
    for (int k = 0; k < s_n; k++)
      if (s_sv_on[k] && s_sv_px[k] + 8 > r->x0 && s_sv_px[k] - 8 < r->x1 && s_sv_py[k] + 8 > r->y0 && s_sv_py[k] - 8 < r->y1) under++;
    for (int j = 0; j < s_pac_n; j++)
      if (s_pac_x[j] + AC_R > r->x0 && s_pac_x[j] - AC_R < r->x1 && s_pac_y[j] + AC_R > r->y0 && s_pac_y[j] - AC_R < r->y1) under++;
  }
  char what[96]; snprintf(what, sizeof(what), "%s: the ceiling label is whole and clear of the marks", name);
  check(r && !under, what);
}
/// The whole board as draw_board paints it, checked on its own runs.
static void board_scene(const char* name) { g_runs.clear(); draw_board(true); scene_check(name); }
static void traffic_board_scene(const char* name) { g_runs.clear(); draw_board(true); traffic_scene(name); }

int main() {
  fixture();
  g_home_set = true; p_gps_det = true; p_gps_fix = true;
  ui_begin(UI_MODE_RX);                         // splash, then the board
  g_runs.clear();
  s_now = g_millis; build_order(); select_row(0);
  draw_board(true);
  // The test-key drone: its AUTH cell says TEST (never OK), its details say TEST KEY.
  { bool cell = false; for (auto& r : g_runs) if (r.s == "TEST" && r.x0 >= s_cols[4].x - 2) cell = true;
    check(cell, "the table's AUTH column says TEST for the test-key drone"); }
  scene_check("t5_table");
  {
    int k = -1; for (int q = 0; q < s_n; q++) if (!strcmp(g_tracks[s_order[q]].uas, "1581F204C68D9A05")) k = q;
    check(k >= 0, "the test-key drone is on the table");
    if (k >= 0) select_row(k);
    s_inspector = true; draw_board(false); g_runs.clear(); draw_inspector_modal();
    check(run_of("ID sig: TEST KEY") != nullptr, "its details say ID sig: TEST KEY");
    scene_check("t5_inspector_test"); s_inspector = false;
    select_row(0);
  }
  // A modal covers the board: check the modal's own runs, keep the full picture.
  s_inspector = true; draw_board(false); g_runs.clear(); draw_inspector_modal(); scene_check("t5_inspector"); s_inspector = false;
  s_confirm_switch = true; s_target_mode = UI_TARGET_POWER_OFF; draw_board(false); g_runs.clear(); draw_switch_modal(); scene_check("t5_confirm"); s_confirm_switch = false;
  rx_hook_pairing(123456, true); draw_board(false); g_runs.clear(); draw_pairing_modal(); scene_check("t5_pairing");
  rx_hook_pairing(0, false); draw_board(false); g_runs.clear();

  // ---- SYSTEM and the Wi-Fi screens, reached the way a finger reaches them
  wifi_fixture();
  s_diag = true; board_scene("t5_diag");
  // CLEAR HISTORY asks first; CANCEL keeps the records, CLEAR clears them.
  {
    const int mw = 580, mh = 260, mx = (W - mw) / 2, my = (H - mh) / 2, by = my + 164;
    tick(); touch(DG_CLR_X + 40, DG_MODE_BTN_Y + 15); tick();
    check(s_confirm_switch && s_target_mode == UI_TARGET_CLEAR_LOG && p_log_clears == 0, "CLEAR HISTORY opens a confirmation, nothing cleared yet");
    draw_board(false); g_runs.clear(); draw_switch_modal();
    { bool asks = false; for (auto& r : g_runs) if (strstr(r.s.c_str(), "Clear the 48 saved drone records?")) asks = true;
      check(asks, "the confirmation names the 48 records"); }
    scene_check("t5_confirm_clear");
    touch(mx + mw - 45 - 110, by + 27); tick();                               // CANCEL
    check(!s_confirm_switch && p_log_clears == 0 && p_log_held == 48, "CANCEL keeps the history");
    touch(DG_CLR_X + 40, DG_MODE_BTN_Y + 15); tick();
    touch(mx + 45 + 110, by + 27); tick();                                    // CLEAR
    check(!s_confirm_switch && p_log_clears == 1 && p_log_held == 0, "CLEAR clears the history (rx_log_clear_all)");
    g_runs.clear(); draw_board(true);
    { bool said = false; for (auto& r : g_runs) if (r.s == "History cleared") said = true;
      check(said, "SYSTEM then says History cleared"); }
    scene_check("t5_diag_cleared");
    p_log_held = 48;
  }
  // The steppers: ADS-B radius in 5 km steps, the map area in 1 km steps.
  tick(); touch(DG_STEP_X + 150, DG_ADSB_Y + 15); tick();
  touch(DG_STEP_X + 10, DG_MAP_Y + 15); tick();
  check(net_get_adsb_radius_km() == 15 && net_get_tile_radius_km() == 2, "ADS-B radius + (10 -> 15 km), map area - (3 -> 2 km)");
  g_net.cfg.adsb_km = 10; g_net.cfg.tile_km = 3;
  // A phone connected over BLE: the automatic Wi-Fi pauses, and SYSTEM says so.
  g_net.paused = true;
  g_runs.clear(); draw_board(true);
  { bool said = false; for (auto& r : g_runs) if (strstr(r.s.c_str(), "Wi-Fi paused: phone connected")) said = true;
    check(said, "SYSTEM says Wi-Fi paused: phone connected"); }
  scene_check("t5_diag_paused");
  g_net.paused = false;
  tick(); touch(DG_WF_X0 + 20, DG_WIFI_BTN_Y + 18); tick();   // NETWORKS
  check(s_wifi_modal && s_wv == WV_LIST && net_is_scanning(), "NETWORKS opens the list and asks for a scan");
  net_debug_set_scanning(true);                                    // what net_tick does with the request
  board_scene("t5_wifi_scanning");
  net_debug_set_scanning(false); tick();                           // the scan completes: redrawn
  board_scene("t5_wifi_list");
  touch(W - 100, WF_PAGE_Y + 28); tick();
  check(s_wifi_page == 1, "NEXT turns the page");
  board_scene("t5_wifi_list_p2");
  touch(W - 100, WF_PAGE_Y + 28); tick();                         // back to page 1
  touch(300, WF_ROW_Y0 + 30); tick();                             // Hangar-Secure: saved
  check(s_wv == WV_ACTION && !strcmp(s_wifi_ssid, "Hangar-Secure"), "a saved network offers CONNECT / FORGET");
  draw_board(false); g_runs.clear(); draw_wifi_action(); scene_check("t5_wifi_saved");
  touch(W / 2, 200); tick(); touch(W / 2 + 280, 400); tick();       // a stray tap inside, then CANCEL...
  check(s_wv == WV_LIST, "CANCEL returns to the list");
  // BOOT is "back" on the Wi-Fi screens too: out of CONNECT / FORGET, then out of the list.
  touch(300, WF_ROW_Y0 + 30); tick();
  check(s_wv == WV_ACTION, "the saved network's actions again");
  boot_tap();
  check(s_wifi_modal && s_wv == WV_LIST, "BOOT backs out of CONNECT / FORGET to the list");
  boot_tap();
  check(!s_wifi_modal && s_diag, "BOOT on the list closes it, back to SYSTEM");
  touch(DG_WF_X0 + 20, DG_WIFI_BTN_Y + 18); tick(); net_debug_set_scanning(false); tick();   // NETWORKS again
  check(s_wifi_modal && s_wv == WV_LIST && s_wifi_page == 0, "NETWORKS reopens the list");
  s_wv = WV_LIST; draw_board(false);
  touch(300, WF_ROW_Y0 + WF_ROW_H + 30); tick();                  // Airfield-Guest: secured, new
  check(s_kb_modal && !s_kb_ssid_stage && !strcmp(s_kb_ssid, "Airfield-Guest"), "a new secured network opens the keyboard");
  board_scene("t5_kb_lower");

  // Key presses: a partial DU refresh of what changed, never a full flash;
  // taps outside the keys lose nothing; taps made while busy are dropped.
  {
    int n0 = g_epd_log.n;
    touch(KB_X0 + 40, KB_Y0 + KB_PITCH + 30); tick();                          // 'q'
    bool du = g_epd_log.mode == MODE_DU && g_epd_log.n - n0 == 2 &&
              g_epd_log.area.y == 72 && g_epd_log.area.y + g_epd_log.area.height <= KB_Y0 + KB_PITCH + KB_KH;
    check(!strcmp(s_kb_buf, "q") && du, "a key types and refreshes in DU, twice (press, release), no full flash");
    touch(KB_X0 + 20, KB_Y0 + 3 * KB_PITCH + 30); tick();                      // SHIFT
    touch(KB_X0 + 40, KB_Y0 + 2 * KB_PITCH + 30); tick();                      // 'a' -> 'A'
    touch(KB_X0 + 5 * (KB_KW + KB_GAP) + 40, KB_Y0 + 2 * KB_PITCH + 30); tick();   // 'h' (shift was one-shot)
    check(!strcmp(s_kb_buf, "qAh"), "SHIFT types one capital");
    touch(W / 2, 510); tick();                                                 // below the keys
    check(s_kb_modal && !strcmp(s_kb_buf, "qAh"), "a tap outside the keys keeps what was typed");
    touch(KB_X0 + 40, KB_Y0 + 30, g_millis - 5000); tick();                   // released during a refresh
    check(!strcmp(s_kb_buf, "qAh"), "a tap made while the panel was busy is dropped");
    snap(); draw_board(true); same_as_snap("keyboard after presses matches a full redraw");
    touch(KB_X0 + 20, KB_Y0 + 3 * KB_PITCH + 30); tick();                      // SHIFT, SHIFT: caps lock
    touch(KB_X0 + 20, KB_Y0 + 3 * KB_PITCH + 30); tick();
    touch(KB_SHOW_X + 20, KB_FY + 30); tick();                                 // SHOW
    board_scene("t5_kb_caps_show");
    touch(KB_X0 + 60, KB_Y0 + 4 * KB_PITCH + 30); tick();                      // #+=
    board_scene("t5_kb_symbols");
    check(s_kb_layer == 1 && s_kb_caps, "#+= switches to symbols");
    touch(KB_X0 + 4 * (KB_KW + KB_GAP) + 40, KB_Y0 + 2 * KB_PITCH + 30); tick();   // ':'
    touch(KB_X0 + 5 * (KB_KW + KB_GAP) + 40, KB_Y0 + 2 * KB_PITCH + 30); tick();   // ';'
    check(!strcmp(s_kb_buf, "qAh:;"), "':' and ';' are on the symbols layer");
  }
  // CONNECT with a short password: refused at once, the reason on screen.
  touch(KB_X0 + 130 + 300 + 130 + 150 + 4 * KB_GAP + 60, KB_Y0 + 4 * KB_PITCH + 30); tick();
  check(s_wv == WV_RESULT && !s_wifi_join_ok, "a password that cannot be right fails at once");
  board_scene("t5_wifi_failed");
  touch(100, 430); tick();                                                     // TRY AGAIN
  check(s_kb_modal && !strcmp(s_kb_buf, "qAh:;"), "TRY AGAIN keeps what was typed");
  snprintf(s_kb_buf, sizeof(s_kb_buf), "correct-horse");
  touch(KB_X0 + 130 + 300 + 130 + 150 + 4 * KB_GAP + 60, KB_Y0 + 4 * KB_PITCH + 30); tick();
  check(s_wv == WV_JOINING, "CONNECT shows the joining screen");
  board_scene("t5_wifi_joining");
  net_debug_set_state(NET_STATE_CONNECTING, NULL, ""); tick();
  check(s_wv == WV_JOINING, "the joining screen stays while connecting");
  net_debug_set_state(NET_STATE_FAILED, NULL, "wrong password"); tick();
  check(s_wv == WV_RESULT && !s_wifi_join_ok && strstr(s_wifi_join_err, "wrong password"), "a failed join says why");
  s_wifi_join_ok = true; board_scene("t5_wifi_ok");
  s_wv = WV_LIST; net_debug_set_state(NET_STATE_DISCONNECTED, NULL, "");
  s_wifi_page = 1; draw_board(false);
  touch(300, WF_ROW_Y0 + 2 * WF_ROW_H + 30); tick();                           // Other network...
  check(s_kb_modal && s_kb_ssid_stage, "Other network... asks for the name first");
  snprintf(s_kb_buf, sizeof(s_kb_buf), "Hidden_Tower-2");
  board_scene("t5_kb_ssid");
  s_kb_ssid_stage = false; snprintf(s_kb_ssid, sizeof(s_kb_ssid), "A-very-long-network-name-32-chr"); s_kb_buf[0] = 0;
  board_scene("t5_kb_long_ssid");
  s_kb_modal = false; s_wifi_modal = false; s_wv = WV_LIST;
  net_debug_set_state(NET_STATE_FAILED, NULL, "network not found");
  board_scene("t5_diag_failed");
  net_debug_set_state(NET_STATE_DISCONNECTED, NULL, "");
  s_diag = false;
  // STAY connected: Remote ID over Wi-Fi is heard on the AP's channel only.
  net_debug_set_mode(NET_MODE_STAY); net_debug_set_state(NET_STATE_CONNECTED, NULL, "", 6);
  g_runs.clear(); draw_board(true);
  { bool said = false; for (auto& r : g_runs) if (strstr(r.s.c_str(), "WI-FI CH 6 ONLY")) said = true;
    check(said, "STAY mode says WI-FI CH 6 ONLY in the footer"); }
  scene_check("t5_table_stay");
  net_debug_set_mode(NET_MODE_SYNC); net_debug_set_state(NET_STATE_DISCONNECTED, NULL, "");

  // ---- ADS-B conflicts, through the real rules and the real tick
  traffic_fixture();
  s_now = g_millis; build_order(); select_row(0);
  p_pulses = 0;
  int n_before = g_epd_log.n;
  s_traffic_ms = 0; tick();
  const TrafficAlert* w = nullptr;   // anywhere in the list: alerts sort nearest first
  for (int i = 0; i < g_traffic_result.n; i++)
    if (!strcmp(g_traffic_result.alerts[i].text, "TRAFFIC NEAR DRONE D9A03")) w = &g_traffic_result.alerts[i];
  check(w != nullptr && !strcmp(w->action, "GIVE WAY: DESCEND AND LAND D9A03"),
        "the fixture raises TRAFFIC NEAR DRONE D9A03: GIVE WAY: DESCEND AND LAND D9A03");
  check(p_pulses == 3 && g_epd_log.n > n_before && g_epd_log.mode == MODE_GC16,
        "a new warning flashes the panel (GC16) and pulses the light three times");
  s_expect_action = true;
  g_runs.clear(); draw_board(true);
  { bool head = false; for (auto& r : g_runs) if (r.y1 < 70 && strstr(r.s.c_str(), "GIVE WAY")) head = true;
    check(head, "the header leads with the action"); }
  traffic_scene("t5_table_traffic");
  { const TrafficAircraft* ac; const TrafficAlert* al;
    check(traffic_card_pick(&ac, &al) && ac && !strcmp(ac->hex, "a1b2c3"), "the warning takes the plot panel"); }
  // Tap another row while the card shows: the partial path leaves no stale ink.
  touch(TABLE_X + 100, 104 + 3 * ROW_H + 20); tick();
  check(g_epd_log.area.y == RECT_BODY.y, "a row tap with the header unchanged refreshes the body only");
  snap(); draw_board(true); same_as_snap("a row tap under a traffic card matches a full redraw");
  // The header changed since the last full draw (a contact expired, the
  // count moved): the row tap refreshes the whole screen, band included.
  g_tracks[11].used = false;
  touch(TABLE_X + 100, 104 + 2 * ROW_H + 20); tick();
  check(g_epd_log.area.y == 0 && g_epd_log.area.height == H, "a row tap with a changed header refreshes the whole screen");
  snap(); draw_board(true); same_as_snap("...and the glass matches a full redraw");
  g_tracks[11].used = true; build_order(); select_row(3); draw_board(true);
  // The card's tap opens its drone's details.
  touch(760, 300); tick();
  check(s_inspector && s_sel >= 0 && !strcmp(g_tracks[s_order[s_sel]].uas, "1581F204C68D9A03"),
        "tapping the card opens the drone's details");
  draw_board(false); g_runs.clear(); draw_inspector_modal(); traffic_scene("t5_inspector_traffic"); s_inspector = false;
  // Panels keep their marks to themselves.
  epd_hl_set_all_white(&s_hl); draw_traffic_card(&g_traffic_ac[0], w); panel_check("traffic card", {TC_X, TC_Y, TC_W, TC_H});
  epd_hl_set_all_white(&s_hl); draw_plot(); panel_check("plot with aircraft", RECT_PLOT);
  drawn_check("plot");
  epd_hl_set_all_white(&s_hl); draw_table(); panel_check("table", RECT_TABLE);
  s_map = true; s_cam_manual = false; map_camera(); g_runs.clear(); draw_board(true);
  check(run_of("HOME") != nullptr, "the map labels HOME beside the board's mark, clear of the drones");
  traffic_scene("t5_map_traffic");
  // A diamond on the map is an alerting aircraft: tapping it shows its alert in the HUD.
  {
    int j = -1; for (int q = 0; q < s_pac_n; q++) if (!strcmp(s_pac_hex[q], "a1b2c3")) j = q;
    check(j >= 0, "the map draws UAL123 (in a conflict)");
    if (j >= 0) { touch(s_pac_x[j], s_pac_y[j]); s_traffic_ms = g_millis; tick(); }   // no re-evaluation this pass
    check(!strcmp(s_ac_hex, "a1b2c3"), "tapping a diamond chooses its aircraft");
  }
  traffic_board_scene("t5_map_ac_hud"); s_ac_hex[0] = 0;
  s_map = false;
  s_side = true; g_runs.clear(); draw_board(true);
  check(run_of("D9A01 125m") != nullptr, "the side view labels the emergency drone at the axis");
  ceiling_check("t5_side_traffic");
  traffic_scene("t5_side_traffic");
  epd_hl_set_all_white(&s_hl); draw_side();
  { int bad = 0; for (int y = 72; y < 496; y++) for (int x = SV_PANEL_X - 23; x < SV_PANEL_X - 1; x++) if (x != SV_PANEL_X - 20 && px_at(x, y) != 15) bad++;
    check(!bad, "side view: nothing crosses into the right panel"); g_runs.clear(); }
  p_elev = NAN; traffic_board_scene("t5_side_traffic_noelev"); p_elev = 40;
  s_side = false;
  g_runs.clear(); draw_glance(); traffic_scene("t5_glance_traffic");

  // The aircraft below the drone: descending would close on it, so move away first.
  traffic_clear(); traffic_fixture();
  g_traffic_ac[0].alt_geom_m = 181 - 90;      // 90 m below D9A03
  s_now = g_millis; ui_traffic_update(g_millis);
  { const TrafficAlert* b = traffic_alert_for_hex(&g_traffic_result, "a1b2c3");
    check(b && strstr(b->action, "GIVE WAY: MOVE") && strstr(b->action, "THEN LAND D9A03"), "an aircraft below: MOVE <away>, THEN LAND"); }
  traffic_board_scene("t5_table_traffic_below");

  // Low traffic only (no pair): BE READY TO LAND DRONES, the aircraft joined to the board.
  traffic_clear(); traffic_fixture();
  g_traffic_ac[0].lat += 0.05;                // UAL123 leaves the drones
  s_now = g_millis; ui_traffic_update(g_millis);
  { bool low = false; for (int i = 0; i < g_traffic_result.n; i++) if (strstr(g_traffic_result.alerts[i].action, "BE READY TO LAND")) low = true;
    check(low, "low traffic in the drones' airspace: BE READY TO LAND DRONES"); }
  traffic_board_scene("t5_table_low");
  s_map = true; s_cam_manual = false; map_camera(); traffic_board_scene("t5_map_low"); s_map = false;

  // No conflicts: no aircraft anywhere, the watch says it is running.
  traffic_clear(); traffic_fixture();
  for (int i = 0; i < g_traffic_count; i++) { g_traffic_ac[i].lat += 0.3; }   // all 30+ km away
  s_now = g_millis; ui_traffic_update(g_millis);
  s_expect_action = false;
  check(g_traffic_result.n == 0, "aircraft far from every drone raise nothing");
  g_runs.clear(); draw_board(true);
  { bool on = false; for (auto& r : g_runs) if (strstr(r.s.c_str(), "CONFLICT WATCH ON")) on = true;
    check(on && s_pac_n == 0, "no conflicts: no aircraft drawn, CONFLICT WATCH ON in the footer"); }
  traffic_scene("t5_table_watch_on");
  s_map = true; s_cam_manual = false; map_camera(); traffic_board_scene("t5_map_watch_on");
  check(s_pac_n == 0, "the map draws no aircraft outside a conflict"); s_map = false;
  s_side = true; traffic_board_scene("t5_side_watch_on"); check(s_pac_n == 0, "the side view draws no aircraft outside a conflict"); s_side = false;

  traffic_clear(); traffic_fixture(true); s_now = g_millis; ui_traffic_update(g_millis);
  check(g_traffic_result.stale, "a 45 s old set is stale");
  g_runs.clear(); draw_board(true);
  { bool head = false, foot = false;
    for (auto& r : g_runs) { if (r.s == "ADS-B STALE") head = true; if (strstr(r.s.c_str(), "TRAFFIC DATA STALE")) foot = true; }
    check(head && foot, "a stale feed says ADS-B STALE in the header and TRAFFIC DATA STALE in the footer"); }
  traffic_scene("t5_table_stale");
  traffic_clear();
  g_runs.clear(); draw_board(true);
  { bool off = false; for (auto& r : g_runs) if (strstr(r.s.c_str(), "CONFLICT WATCH OFF")) off = true;
    check(off, "no ADS-B source: CONFLICT WATCH OFF in the footer"); }
  traffic_scene("t5_table_watch_off");

  // A warning arriving under SYSTEM, the networks list or the keyboard:
  // the light pulses, the panel is not flashed (a black flash mid-password
  // shows nothing), the screen's header band says what to do, and the
  // flash comes with the board when the screen closes.
  {
    s_now = g_millis; ui_traffic_update(g_millis);
    s_diag = true; s_sig_prev = 0; draw_board(true);
    traffic_fixture(); s_traffic_ms = 0; p_pulses = 0;
    int gc = g_epd_log.gc16, n0 = g_epd_log.n;
    tick();
    check(p_pulses == 3 && g_epd_log.n > n0 && g_epd_log.gc16 == gc, "a warning under SYSTEM pulses the light and redraws without a flash");
    s_expect_action = true;
    g_runs.clear(); draw_diagnostics();
    { const TextRun* r = run_of("GIVE WAY"); check(r && r->y1 < 68, "SYSTEM's header band says GIVE WAY"); }
    check(run_of(ADSB_CREDIT) != nullptr, "SYSTEM credits adsb.lol beside the ADS-B radius");
    traffic_scene("t5_diag_warning");
    s_wifi_modal = true; s_wv = WV_LIST; s_wifi_page = 0;
    g_runs.clear(); draw_wifi_screen();
    { const TextRun* r = run_of("GIVE WAY"); check(r && r->y1 < WF_HEAD_H, "the networks list's header band says GIVE WAY"); }
    traffic_scene("t5_wifi_list_warning");
    s_kb_modal = true; s_kb_ssid_stage = false; snprintf(s_kb_ssid, sizeof(s_kb_ssid), "Airfield-Guest"); s_kb_buf[0] = 0;
    g_runs.clear(); draw_keyboard();
    { const TextRun* r = run_of("GIVE WAY"); check(r && r->y1 < 64, "the keyboard's header band says GIVE WAY"); }
    traffic_scene("t5_kb_warning");
    s_kb_modal = false; s_wifi_modal = false; s_expect_action = false;
    gc = g_epd_log.gc16;
    touch(W - 70, 34); tick();                                           // CLOSE
    check(!s_diag && g_epd_log.gc16 == gc + 1, "CLOSE brings the board back with its GC16 flash");
    traffic_clear();
  }

  // An underrun leaves the glass incomplete: the next pass repaints it all.
  {
    int clears = g_epd_clears;
    g_epd_fail_next = true; draw_board(false);
    int gc = g_epd_log.gc16;
    tick();
    check(g_epd_clears == clears + 1 && g_epd_log.gc16 == gc + 1, "an underrun is repaired with a clear and a full GC16");
    // A board whose refreshes keep underrunning (a busy radio task on the
    // feeder's core) must not repaint in a loop: one repair per 30 s.
    clears = g_epd_clears;
    g_epd_fail_next = true; draw_board(false); tick(1000);
    bool held = g_epd_clears == clears;
    tick(30000);
    check(held && g_epd_clears == clears + 1, "a second underrun within 30 s waits; the repair comes after 30 s");
  }

  g_home_set = false; p_gps_det = false; p_gps_fix = false;
  board_scene("t5_card");
  // No GPS: the header names where the position came from.
  g_home_set = true;
  for (const char* src : {"saved", "app"}) {
    snprintf(g_home_src, sizeof(g_home_src), "%s", src);
    const char* want = strcmp(src, "saved") ? "APP POS" : "SAVED POS";
    g_runs.clear(); draw_board(true);
    bool said = false;
    for (auto& r : g_runs) if (r.s == want) said = true;
    check(said, strcmp(src, "saved") ? "a position from the app shows APP POS in the header"
                                     : "a home restored from NVS shows SAVED POS in the header");
  }
  p_gps_det = true; p_gps_fix = true;
  s_map = true; s_cam_manual = false; map_camera(); s_cam_manual = true; board_scene("t5_map");
  s_map = false; s_cam_manual = false;
  s_mode = UI_MODE_TX;
  for (int slow = 0; slow < 2; slow++) {
    g_tx_slow = slow; g_runs.clear(); draw_board(true);
    bool said = false; for (auto& r : g_runs) if (r.s == (slow ? "RATE [SLOW]" : "RATE [SPEC]")) said = true;
    check(said, slow ? "...and RATE [SLOW] when slow" : "the test beacon shows its rate: RATE [SPEC]");
    scene_check(slow ? "t5_tx_slow" : "t5_tx");
  }
  g_tx_slow = false; s_mode = UI_MODE_RX;
  g_runs.clear(); draw_glance(); scene_check("t5_glance");
  // Glance cadence: a moving drone changes the routine figures every few
  // seconds; the panel may follow them at most once a minute, but an alert
  // reaches it at once.
  {
    traffic_clear();
    fixture(); s_now = g_millis; build_order();
    for (int i = 0; i < TRK_MAX; i++) if (g_tracks[i].used) g_tracks[i].status = 0;
    auto keep_fresh = [&]() { for (int i = 0; i < TRK_MAX; i++) if (g_tracks[i].used) g_tracks[i].last_ms = g_millis; };
    s_glance = true; keep_fresh(); glance_show(g_millis);
    int n0 = g_epd_log.n;
    Track* nt = nullptr; double best = 1e18;
    for (int i = 0; i < TRK_MAX; i++) {
      Track* t = &g_tracks[i];
      if (!t->used || !t->has_pos) continue;
      double d = ui_dist_m(g_home_lat, g_home_lon, t->lat, t->lon);
      if (d < best) { best = d; nt = t; }
    }
    int redraws_minute = 0;
    for (int k = 0; k < 19 && nt; k++) {           // 57 s of a drone moving 60 m every 3 s
      nt->lat += 60.0 / 111111.0; keep_fresh();
      int n = g_epd_log.n; tick(3000); redraws_minute += g_epd_log.n - n;
    }
    for (int k = 0; k < 2; k++) { keep_fresh(); tick(3000); }   // past the minute
    bool routine_once = s_glance && redraws_minute == 0 && g_epd_log.n - n0 == 1;
    check(routine_once, "glance: a moving drone redraws the panel at most once a minute");
    int n1 = g_epd_log.n;
    nt->status = 3; keep_fresh(); tick(3000);
    check(s_glance && g_epd_log.n - n1 == 1, "glance: a new emergency reaches the panel at once");
    s_glance = false;
  }
  s_side = true; g_runs.clear(); draw_board(true); ceiling_check("t5_side"); scene_check("t5_side");
  g_home_set = false; board_scene("t5_side_nopos"); g_home_set = true;
  s_side = false;
  memset(g_tracks, 0, sizeof(g_tracks)); build_order(); board_scene("t5_empty");
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

  // The map re-tone (map_tone.h). CARTO dark_all's palette (older .png
  // tiles): land is paper, streets darker than water and buildings and dark
  // enough to show (the panel renders grey 3-10 distinctly), labels darkest.
  // A plain inversion had made roads as light as land.
  {
    unsigned land = map_tone_carto(9), building = map_tone_carto(6), street = map_tone_carto(25),
             water = map_tone_carto(34), label = map_tone_carto(66);
    bool ok = land == 15 && building < land && water < land && street < water &&
              street < building && street <= 6 && label < street;
    printf("%s map tones (CARTO): land %u, buildings %u, water %u, streets %u, labels %u\n",
           ok ? "ok  " : "FAIL", land, building, water, street, label);
    if (!ok) g_fails++;
  }
  // Esri World Dark Gray (the .jpg basemap), on its measured palette: land
  // and blocks paper, water a light tint, streets dark, major roads darker,
  // labels black.
  {
    unsigned land = map_tone_esri(77), block = map_tone_esri(70), water = map_tone_esri(34),
             street = map_tone_esri(100), road = map_tone_esri(125), label = map_tone_esri(160);
    bool ok = land == 15 && block == 15 && water < land && water > street && street <= 6 &&
              road < street && label < road;
    printf("%s map tones (Esri): land %u, blocks %u, water %u, streets %u, major roads %u, labels %u\n",
           ok ? "ok  " : "FAIL", land, block, water, street, road, label);
    if (!ok) g_fails++;
  }

  if (g_fails) printf("%d FAILED\n", g_fails); else printf("all T5 render checks passed\n");
  return g_fails ? 1 : 0;
}
