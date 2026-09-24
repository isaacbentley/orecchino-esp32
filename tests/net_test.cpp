// Host tests for the T5's Wi-Fi: the real net_sync.h state machine driven
// through fake Wi-Fi / clock / NVS / fetch ops, the wifi_* host commands,
// and net_parse.h against saved answers from the FAA and adsb.lol
// (tests/vectors/net/). No shims needed: both headers are plain C++ on a host.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
#include "net_sync.h"
#include <algorithm>
#include <string>
#include <vector>

static int g_fails = 0;
#define CHECK(c, name) do { if (c) printf("ok   %s\n", name); else { printf("FAIL %s\n", name); g_fails++; } } while (0)

static std::string read_file(const char* path) {
  FILE* f = fopen(path, "rb");
  if (!f) { printf("FAIL cannot open %s\n", path); g_fails++; return ""; }
  std::string s;
  char buf[4096];
  size_t n;
  while ((n = fread(buf, 1, sizeof(buf), f)) > 0) s.append(buf, n);
  fclose(f);
  return s;
}

// ---------------------------------------------------------------------------
// The fake radio, NVS, clock and fetch worker

struct Fake {
  NetLink  link = NET_LINK_PENDING;
  std::vector<std::string> begins;   // "ssid/pass"
  int      leaves = 0;
  bool     hold = false;
  int      hold_calls = 0;
  bool     scan_ok = true;
  int      scan_starts = 0;
  int      scan_result = NET_SCAN_RUNNING;
  std::vector<ScannedNetwork> nets;
  NetConfig nvs = {};
  int      stores = 0;
  bool     jobs_ok = true;
  std::vector<uint32_t> job_reqs;
  std::vector<uint16_t> budgets;
  bool     running = false;
  bool     done = false;
  int      cancels = 0;
  NetJobResult result = {};
  std::vector<uint32_t> utc_set;
  uint32_t utc_now = 0;
  std::vector<std::pair<int, std::string>> lines;
};
static Fake F;

static void f_begin(const char* s, const char* p) { F.begins.push_back(std::string(s) + "/" + p); F.link = NET_LINK_PENDING; }
static void f_leave() { F.leaves++; F.link = NET_LINK_DOWN; }
static NetLink f_link() { return F.link; }
static bool f_scan_start() { F.scan_starts++; return F.scan_ok; }
static int f_scan_poll(ScannedNetwork* out, int max) {
  if (F.scan_result != 0) return F.scan_result;
  int n = (int)F.nets.size() < max ? (int)F.nets.size() : max;
  for (int i = 0; i < n; i++) out[i] = F.nets[i];
  return n;
}
static void f_ip(char* out, size_t n) { snprintf(out, n, "192.168.1.42"); }
static int f_rssi() { return -61; }
static uint8_t f_channel() { return 6; }
static void f_hold(bool h) { F.hold = h; F.hold_calls++; }
static void f_load(NetConfig* c) { *c = F.nvs; }
static void f_store(const NetConfig* c) { F.nvs = *c; F.stores++; }
static bool f_jobs_start(const NetJobReq* r) {
  if (!F.jobs_ok) return false;
  F.job_reqs.push_back(r->jobs);
  F.budgets.push_back(r->tile_budget);
  F.running = true;
  F.done = false;
  return true;
}
static bool f_jobs_poll(NetJobResult* out) {
  if (!F.running || !F.done) return false;
  F.running = false;
  *out = F.result;
  return true;
}
static void f_jobs_cancel() { F.cancels++; }
static void f_set_utc(uint32_t u) { F.utc_set.push_back(u); }
static uint32_t f_utc_now() { return F.utc_now; }
static void f_emit(uint8_t dst, const char* line, size_t n) { F.lines.push_back({dst, std::string(line, n)}); }
static bool g_have_pos = true;
static bool f_have_pos() { return g_have_pos; }
static bool g_phone = false;
static bool f_phone() { return g_phone; }

static NetOps fake_ops() {
  NetOps o = {};
  o.begin = f_begin; o.leave = f_leave; o.link = f_link;
  o.scan_start = f_scan_start; o.scan_poll = f_scan_poll;
  o.ip = f_ip; o.rssi = f_rssi; o.channel = f_channel; o.hop_hold = f_hold;
  o.load = f_load; o.store = f_store;
  o.jobs_start = f_jobs_start; o.jobs_poll = f_jobs_poll; o.jobs_cancel = f_jobs_cancel;
  o.set_utc = f_set_utc; o.utc_now = f_utc_now; o.emit = f_emit; o.have_position = f_have_pos;
  o.phone_connected = f_phone;
  return o;
}

static NetSaved saved(const char* s, const char* p) {
  NetSaved n = {};
  snprintf(n.ssid, sizeof(n.ssid), "%s", s);
  snprintf(n.pass, sizeof(n.pass), "%s", p);
  return n;
}

static void reset(uint8_t mode, std::vector<NetSaved> nets, uint8_t every = 15) {
  F = Fake();
  g_phone = false;
  g_have_pos = true;
  F.nvs.mode = mode;
  F.nvs.every_min = every;
  F.nvs.n = (uint8_t)nets.size();
  for (size_t i = 0; i < nets.size(); i++) F.nvs.saved[i] = nets[i];
  F.utc_now = 1790000000;
  NetOps o = fake_ops();
  net_sync_init(&o);
}

static NetJobResult result_ok(uint32_t jobs, uint32_t utc = 0, uint32_t at = 0) {
  NetJobResult r = {};
  r.ok = jobs;
  r.utc = utc;
  r.utc_at_ms = at;
  r.tfr_n = 3;
  r.ac_n = 7;
  r.heap_free = 61000;
  r.heap_block = 30000;
  return r;
}

static bool has_line(const char* needle, int dst = -1) {
  for (auto& l : F.lines)
    if ((dst < 0 || l.first == dst) && l.second.find(needle) != std::string::npos) return true;
  return false;
}
static int count_lines(const char* needle, int dst = -1) {
  int n = 0;
  for (auto& l : F.lines)
    if ((dst < 0 || l.first == dst) && l.second.find(needle) != std::string::npos) n++;
  return n;
}

// ---------------------------------------------------------------------------
// State machine

static void test_sync_window() {
  uint32_t t = 1000;
  reset(NET_MODE_SYNC, {saved("Home", "password1")});
  CHECK(!F.hold, "sm: hop runs after init");
  net_tick(t);
  CHECK(F.begins.size() == 1 && F.begins[0] == "Home/password1", "sm: first tick joins the saved network");
  CHECK(F.hold && net_get_state() == NET_STATE_CONNECTING, "sm: the hop is held while joining");
  CHECK(has_line("\"state\":\"connecting\"", NET_DST_ALL), "sm: a net connecting line goes to every transport");
  net_tick(t += 500);
  CHECK(net_get_state() == NET_STATE_CONNECTING, "sm: still connecting while nothing decisive");
  F.link = NET_LINK_UP;
  net_tick(t += 500);
  CHECK(net_get_state() == NET_STATE_CONNECTED && !strcmp(net_get_ip(), "192.168.1.42") && net_get_channel() == 6,
        "sm: joined: connected with an IP and channel");
  CHECK(F.job_reqs.size() == 1 && F.job_reqs[0] == (NET_JOB_TIME | NET_JOB_TFR | NET_JOB_ADSB | NET_JOB_TILES),
        "sm: the first window runs every job");
  CHECK(F.budgets[0] == NET_TILE_BUDGET_AUTO, "sm: an automatic window caps new tiles");
  net_tick(t += 3000);
  CHECK(F.hold && F.leaves == 0, "sm: the loop keeps going while the worker fetches, hop still held");
  F.result = result_ok(NET_JOB_TIME | NET_JOB_TFR | NET_JOB_ADSB | NET_JOB_TILES, 1790000100, t - 1500);
  F.done = true;
  F.utc_now = 1790000102;
  net_tick(t += 1000);
  CHECK(F.utc_set.size() == 1 && F.utc_set[0] == 1790000100 + 3, "sm: the SNTP time is written, advanced by the time since the answer");
  CHECK(net_is_clock_synced(), "sm: the clock counts as synced after a real SNTP answer");
  CHECK(F.leaves == 1 && !F.hold && net_get_state() == NET_STATE_DISCONNECTED, "sm: SYNC mode leaves and resumes the hop");
  CHECK(net_get_last_sync() == 1790000102, "sm: last sync time recorded");
  CHECK(has_line("\"state\":\"synced\"") && has_line("\"ok\":[\"time\",\"tfr\",\"adsb\",\"tiles\"]") &&
        has_line("\"heap_int\":61000"), "sm: the synced line lists the jobs and the heap numbers");
  CHECK(fabs(net_adsb_age_s() - 0.0) < 0.01, "sm: ADS-B age starts at zero");
  uint32_t start = 1000;
  net_tick(start + 14 * 60000);
  CHECK(F.begins.size() == 1 && fabs(net_adsb_age_s() - (14 * 60000 - 5000) / 1000.0) < 0.01,
        "sm: no window before 15 min; ADS-B age grows");
  net_tick(start + 15 * 60000);
  CHECK(F.begins.size() == 2 && F.hold, "sm: the next window 15 min after the last one started");
  F.link = NET_LINK_UP;
  net_tick(start + 15 * 60000 + 800);
  CHECK(F.job_reqs.size() == 2 && F.job_reqs[1] == (NET_JOB_TIME | NET_JOB_TFR | NET_JOB_ADSB),
        "sm: at 15 min: time, TFR and ADS-B again, tiles not (weekly)");
}

static void test_clock_rules() {
  uint32_t t = 5000;
  reset(NET_MODE_SYNC, {saved("Home", "password1")}, 5);
  net_tick(t);
  F.link = NET_LINK_UP;
  net_tick(t += 100);
  F.result = result_ok(0);
  F.result.failed = NET_JOB_TIME;
  F.result.ok = NET_JOB_TFR | NET_JOB_ADSB | NET_JOB_TILES;
  snprintf(F.result.err, sizeof(F.result.err), "CLOCK: no SNTP answer");
  F.done = true;
  net_tick(t += 100);
  CHECK(!net_is_clock_synced() && F.utc_set.empty(), "clock: no answer, not synced, nothing written (a set RTC is not a sync)");
  CHECK(!strcmp(net_last_error(), "CLOCK: no SNTP answer"), "clock: the failure is reported");
  // Window 2 (5 min later): the time job backs off 1 min after one failure, so it is due again.
  net_tick(t = 5000 + 5 * 60000);
  F.link = NET_LINK_UP;
  net_tick(t += 100);
  CHECK(F.job_reqs.size() == 2 && (F.job_reqs[1] & NET_JOB_TIME), "clock: retried at the next window");
  F.result = result_ok(NET_JOB_TIME | NET_JOB_ADSB, 1790001000, t);
  F.done = true;
  net_tick(t += 100);
  CHECK(net_is_clock_synced() && F.utc_set.size() == 1, "clock: synced on a real answer");
  CHECK(!strcmp(net_last_error(), ""), "clock: the error clears after a clean window");
  // Window 3 (5 min later): clock synced 5 min ago -> not due; TFR 10 min old -> not due.
  net_tick(t = 5000 + 10 * 60000);
  F.link = NET_LINK_UP;
  net_tick(t += 100);
  CHECK(F.job_reqs.size() == 3 && F.job_reqs[2] == NET_JOB_ADSB, "clock: a 5-min window only refreshes ADS-B");
}

static void test_join_failures() {
  uint32_t t = 2000;
  reset(NET_MODE_SYNC, {saved("Home", "password1")});
  net_tick(t);
  F.link = NET_LINK_AUTH_FAIL;
  net_tick(t += 3000);
  CHECK(net_get_state() == NET_STATE_FAILED && !strcmp(net_last_error(), "wrong password"), "join: auth failure -> wrong password");
  CHECK(F.leaves == 1 && !F.hold, "join: a failure leaves and resumes the hop at once");
  CHECK(has_line("\"state\":\"failed\"") && has_line("wrong password"), "join: the failure is broadcast");
  char line[120];
  net_status_line(line, sizeof(line));
  CHECK(!strcmp(line, "FAILED: wrong password, retry in 1 min"), "join: SYSTEM line shows the reason and the retry");
  net_tick(t + 59000);
  CHECK(F.begins.size() == 1, "join: no retry before 1 min");
  net_tick(t += 60000);
  CHECK(F.begins.size() == 2, "join: retry after 1 min");
  F.link = NET_LINK_NO_AP;
  net_tick(t += 2000);
  CHECK(!strcmp(net_last_error(), "network not found"), "join: no AP -> network not found");
  net_tick(t += 119000);
  CHECK(F.begins.size() == 2, "join: second back-off is 2 min");
  net_tick(t += 1000);
  CHECK(F.begins.size() == 3, "join: retried after 2 min");
  F.link = NET_LINK_ASSOC;
  net_tick(t += NET_JOIN_TIMEOUT_MS);
  CHECK(!strcmp(net_last_error(), "no IP address"), "join: associated without an address -> no IP address");
  net_tick(t += 5 * 60000);
  CHECK(F.begins.size() == 4, "join: third back-off is 5 min");
  F.link = NET_LINK_PENDING;
  net_tick(t += NET_JOIN_TIMEOUT_MS);
  CHECK(!strcmp(net_last_error(), "timed out"), "join: nothing at all -> timed out");
  net_tick(t += 15 * 60000 - 1);
  CHECK(F.begins.size() == 4, "join: back-off capped at 15 min (the SYNC interval)");
  net_tick(t += 1);
  CHECK(F.begins.size() == 5, "join: retried after 15 min");
  F.link = NET_LINK_UP;
  net_tick(t += 100);
  CHECK(net_get_state() == NET_STATE_CONNECTED && !strcmp(net_last_error(), ""), "join: success clears the error");
}

static void test_connect_saves_only_on_success() {
  uint32_t t = 1000;
  reset(NET_MODE_OFF, {});
  net_tick(t);
  CHECK(F.begins.empty() && !F.hold, "connect: mode OFF with nothing saved does nothing");
  net_connect("Cafe \"Wifi\"", "hunter2hunter2");
  CHECK(F.stores == 0, "connect: nothing saved before trying");
  net_tick(t += 10);
  CHECK(F.begins.size() == 1 && F.begins[0] == "Cafe \"Wifi\"/hunter2hunter2", "connect: joins the typed network");
  F.link = NET_LINK_AUTH_FAIL;
  net_tick(t += 1000);
  CHECK(F.stores == 0 && net_saved_count() == 0, "connect: a failed join saves nothing");
  CHECK(net_get_state() == NET_STATE_FAILED && !strcmp(net_last_error(), "wrong password"), "connect: failure visible to the UI");
  net_tick(t += 20 * 60000);
  CHECK(F.begins.size() == 1, "connect: a failed typed network is not retried on its own");
  net_connect("Cafe \"Wifi\"", "correct-horse");
  net_tick(t += 10);
  F.link = NET_LINK_UP;
  net_tick(t += 1000);
  CHECK(F.stores >= 1 && F.nvs.n == 1 && !strcmp(F.nvs.saved[0].ssid, "Cafe \"Wifi\"") &&
        !strcmp(F.nvs.saved[0].pass, "correct-horse"), "connect: saved after it joined");
  CHECK(F.nvs.mode == NET_MODE_SYNC && net_get_mode() == NET_MODE_SYNC, "connect: a successful join from OFF switches to SYNC");
  net_connect("x", "short");
  CHECK(net_get_state() == NET_STATE_FAILED && strstr(net_last_error(), "8-63"), "connect: an impossible password fails at once");
}

static void test_stay_mode() {
  uint32_t t = 1000;
  reset(NET_MODE_STAY, {saved("Desk", "password1")});
  net_tick(t);
  F.link = NET_LINK_UP;
  net_tick(t += 100);
  F.result = result_ok(NET_JOB_TIME | NET_JOB_TFR | NET_JOB_ADSB | NET_JOB_TILES, 1790000000, t);
  F.done = true;
  net_tick(t += 100);
  CHECK(F.leaves == 0 && F.hold && net_get_state() == NET_STATE_CONNECTED, "stay: stays associated after the fetch, hop held");
  char line[120];
  net_status_line(line, sizeof(line));
  CHECK(!strcmp(line, "CONNECTED to Desk (ch 6)"), "stay: SYSTEM line");
  net_tick(t += 5000);
  CHECK(F.job_reqs.size() == 1, "stay: no fetch before 10 s");
  net_tick(t += 5000);
  CHECK(F.job_reqs.size() == 2 && F.job_reqs[1] == NET_JOB_ADSB, "stay: ADS-B every 10 s");
  F.result = result_ok(0);
  F.result.failed = NET_JOB_ADSB;
  snprintf(F.result.err, sizeof(F.result.err), "ADS-B: HTTP 503");
  F.done = true;
  net_tick(t += 100);
  net_tick(t += 10000);
  CHECK(F.job_reqs.size() == 2, "stay: a failing ADS-B source backs off (not every 10 s)");
  net_tick(t += 50000);
  CHECK(F.job_reqs.size() == 3 && F.job_reqs[2] == NET_JOB_ADSB, "stay: retried after 1 min");
  F.result = result_ok(NET_JOB_ADSB);
  F.done = true;
  net_tick(t += 100);
  // The link drops.
  F.link = NET_LINK_DOWN;
  net_tick(t += 100);
  CHECK(has_line("\"state\":\"lost\"") && F.begins.size() == 2, "stay: a dropped link is noticed and rejoined at once");
  F.link = NET_LINK_NO_AP;
  net_tick(t += 1000);
  CHECK(net_get_state() == NET_STATE_FAILED && !F.hold, "stay: rejoin failed, hop resumes");
  net_tick(t += 59000);
  CHECK(F.begins.size() == 2, "stay: rejoin backs off 1 min");
  net_tick(t += 1000);
  CHECK(F.begins.size() == 3, "stay: rejoin after 1 min");
  F.link = NET_LINK_UP;
  net_tick(t += 100);
  CHECK(net_get_state() == NET_STATE_CONNECTED && F.running, "stay: back online, ADS-B due at once");
  F.result = result_ok(NET_JOB_ADSB);
  F.done = true;
  net_tick(t += 100);
  // Mode OFF while a fetch runs: cancel, then leave.
  net_sync_now();
  net_tick(t += 100);
  CHECK(F.running, "stay: SYNC NOW starts a fetch while online");
  CHECK(F.job_reqs.back() == (NET_JOB_TIME | NET_JOB_TFR | NET_JOB_ADSB), "stay: SYNC NOW runs every job");
  net_set_mode(NET_MODE_OFF);
  net_tick(t += 100);
  CHECK(F.cancels == 1 && F.hold, "off: the running fetch is cancelled first");
  F.result = result_ok(0);
  F.result.failed = NET_JOB_TIME | NET_JOB_TFR | NET_JOB_ADSB;
  F.done = true;
  int leaves = F.leaves;
  net_tick(t += 100);
  CHECK(F.leaves == leaves + 1 && !F.hold && net_get_state() == NET_STATE_DISCONNECTED, "off: then leaves, hop resumes");
  size_t b = F.begins.size();
  net_tick(t += 3600000);
  CHECK(F.begins.size() == b && F.nvs.mode == NET_MODE_OFF, "off: no automatic joins, mode stored");
  net_sync_now();
  net_tick(t += 100);
  CHECK(F.begins.size() == b + 1, "off: SYNC NOW still runs one window");
}

static void test_scan_and_pick() {
  uint32_t t = 1000;
  reset(NET_MODE_OFF, {saved("Home", "password1"), saved("Barn", "password2")});
  net_scan_start();
  CHECK(net_is_scanning(), "scan: scanning as soon as asked");
  net_tick(t);
  CHECK(F.scan_starts == 1 && F.hold, "scan: started with the hop held");
  char line[120];
  net_status_line(line, sizeof(line));
  CHECK(!strcmp(line, "SCANNING, Remote ID Wi-Fi paused"), "scan: SYSTEM line says the sniffer pauses");
  ScannedNetwork a = { "Barn", -70, 3, 11, false }, b = { "Guest", -50, 0, 1, false },
                 c = { "Barn", -60, 3, 6, false }, h = { "", -40, 3, 1, false };
  F.nets = { a, b, c, h };
  F.scan_result = 0;
  net_tick(t += 2000);
  uint8_t n = 0;
  const ScannedNetwork* s = net_get_scanned(&n);
  CHECK(!net_is_scanning() && !F.hold, "scan: done, hop resumes");
  CHECK(n == 2 && !strcmp(s[0].ssid, "Guest") && !strcmp(s[1].ssid, "Barn") && s[1].rssi == -60 && s[1].channel == 6,
        "scan: hidden dropped, duplicates keep the strongest, strongest first");
  CHECK(s[1].saved && !s[0].saved, "scan: saved networks marked");
  // Two saved networks: a sync picks the strongest one in sight.
  F.scan_result = NET_SCAN_RUNNING;
  net_sync_now();
  net_tick(t += 100);
  CHECK(F.scan_starts == 2 && F.begins.empty(), "pick: two saved networks, scan first");
  F.scan_result = 0;
  net_tick(t += 2000);
  CHECK(F.begins.size() == 1 && F.begins[0] == "Barn/password2", "pick: joins the saved network in sight");
  // Scan failure is reported, and the hop resumes.
  F.link = NET_LINK_UP;
  net_tick(t += 100);
  F.result = result_ok(NET_JOB_TIME);
  F.done = true;
  net_tick(t += 100);
  F.scan_ok = false;
  net_scan_request(net__mask(1));
  net_tick(t += 100);
  CHECK(!net_is_scanning() && !F.hold && has_line("{\"type\":\"wifi_scan_done\",\"n\":0,\"err\":\"scan failed\"}", 1),
        "scan: a failed scan answers and releases the hop");
  CHECK(!strcmp(F.nvs.saved[0].ssid, "Barn") && F.stores >= 1, "pick: the joined network moves to the front of the saved list");
}

static void test_host_commands() {
  uint32_t t = 1000;
  reset(NET_MODE_SYNC, {});
  net_tick(t);
  // wifi_status from USB: allowed, answered on USB only.
  net_host_line("wifi_status", "{\"cmd\":\"wifi_status\"}", 0);
  CHECK(has_line("{\"type\":\"wifi_status\",\"state\":\"idle\",\"mode\":\"sync\",\"every_min\":15", 0) &&
        count_lines("wifi_status", 1) == 0, "cmd: wifi_status answers the asker only");
  // wifi_join over USB without setup: refused.
  net_host_line("wifi_join", "{\"cmd\":\"wifi_join\",\"ssid\":\"Home\",\"psk\":\"password1\"}", 0);
  CHECK(has_line("{\"type\":\"wifi_err\",\"cmd\":\"wifi_join\",\"reason\":\"refused over USB", 0), "cmd: wifi_join refused over plain USB");
  net_tick(t += 10);
  CHECK(F.begins.empty(), "cmd: and nothing joined");
  // Over the bonded BLE link: a password with quotes and a backslash, and a
  // decoy "psk" inside the SSID.
  F.lines.clear();
  net_host_line("wifi_join", "{\"cmd\":\"wifi_join\",\"ssid\":\"a\\\",\\\"psk\\\":\\\"x\",\"psk\":\"p\\\"q\\\\r\\u00e9stuv\"}", 1);
  net_tick(t += 10);
  CHECK(F.begins.size() == 1 && F.begins[0] == "a\",\"psk\":\"x/p\"q\\r\xc3\xa9stuv", "cmd: JSON strings unescaped exactly");
  CHECK(has_line("\"state\":\"connecting\"", 1) && count_lines("wifi_status", 0) == 0, "cmd: connecting reply to BLE only");
  CHECK(has_line("\"ssid\":\"a\\\",\\\"psk\\\":\\\"x\"", 1), "cmd: the SSID is escaped on the way out");
  F.link = NET_LINK_UP;
  net_tick(t += 100);
  CHECK(has_line("\"state\":\"connected\"", 1) && has_line("\"ip\":\"192.168.1.42\",\"ch\":6,\"rssi\":-61", 1),
        "cmd: connected reply with ip, channel, rssi");
  F.result = result_ok(NET_JOB_TIME | NET_JOB_TFR | NET_JOB_ADSB | NET_JOB_TILES, 1790000000, t);
  F.done = true;
  net_tick(t += 100);
  // wifi_scan from BLE: wifi_net lines then wifi_scan_done, to BLE only.
  F.lines.clear();
  ScannedNetwork a = { "Home", -55, 3, 6, false }, b = { "Open", -70, 0, 11, false };
  F.nets = { a, b };
  F.scan_result = 0;
  net_host_line("wifi_scan", "{\"cmd\":\"wifi_scan\"}", 1);
  net_tick(t += 10);
  net_tick(t += 10);
  CHECK(has_line("{\"type\":\"wifi_net\",\"ssid\":\"Home\",\"rssi\":-55,\"secure\":true,\"saved\":false,\"ch\":6}", 1) &&
        has_line("{\"type\":\"wifi_net\",\"ssid\":\"Open\",\"rssi\":-70,\"secure\":false,\"saved\":false,\"ch\":11}", 1) &&
        has_line("{\"type\":\"wifi_scan_done\",\"n\":2}", 1) && count_lines("wifi_net", 0) == 0,
        "cmd: wifi_scan answers wifi_net lines and wifi_scan_done to the asker");
  // wifi_mode
  F.lines.clear();
  net_host_line("wifi_mode", "{\"cmd\":\"wifi_mode\",\"mode\":\"stay\",\"every_min\":30}", 1);
  CHECK(net_get_mode() == NET_MODE_STAY && net_get_every_min() == 30 && F.nvs.mode == NET_MODE_STAY &&
        F.nvs.every_min == 30, "cmd: wifi_mode sets and stores mode and interval");
  CHECK(has_line("\"mode\":\"stay\",\"every_min\":30", 1), "cmd: wifi_mode answers with the status");
  net_host_line("wifi_mode", "{\"cmd\":\"wifi_mode\",\"mode\":\"sync\",\"every_min\":1}", 1);
  CHECK(net_get_every_min() == NET_EVERY_MIN_MIN, "cmd: every_min clamped to 5");
  net_host_line("wifi_mode", "{\"cmd\":\"wifi_mode\",\"mode\":\"fast\"}", 1);
  CHECK(has_line("{\"type\":\"wifi_err\",\"cmd\":\"wifi_mode\",\"reason\":\"bad mode\"}", 1), "cmd: a bad mode is refused");
  // wifi_forget
  F.lines.clear();
  net_host_line("wifi_forget", "{\"cmd\":\"wifi_forget\",\"ssid\":\"nope\"}", 1);
  CHECK(has_line("\"reason\":\"not saved\"", 1), "cmd: forgetting an unknown network is an error");
  CHECK(F.nvs.n == 1, "cmd: (one network saved)");
  net_host_line("wifi_forget", "{\"cmd\":\"wifi_forget\",\"ssid\":\"a\\\",\\\"psk\\\":\\\"x\"}", 1);
  CHECK(F.nvs.n == 0 && has_line("\"saved\":[]", 1), "cmd: wifi_forget removes it and answers with the status");
  // USB with the SYSTEM screen's setup open: allowed, for 5 minutes.
  F.lines.clear();
  net_serial_setup(true);
  net_host_line("wifi_join", "{\"cmd\":\"wifi_join\",\"ssid\":\"Lab\",\"psk\":\"\"}", 0);
  net_tick(t += 100);
  CHECK(F.begins.back() == "Lab/", "cmd: USB allowed while setup is open (open network)");
  net_tick(t += NET_SERIAL_SETUP_MS);
  net_host_line("wifi_mode", "{\"cmd\":\"wifi_mode\",\"mode\":\"off\"}", 0);
  CHECK(has_line("refused over USB", 0), "cmd: USB refused again after 5 minutes");
  net_host_line("wifi_join", "{\"cmd\":\"wifi_join\",\"ssid\":\"x\",\"psk\":\"short\"}", 1);
  CHECK(has_line("{\"type\":\"wifi_err\",\"cmd\":\"wifi_join\",\"reason\":\"password must be 8-63 characters\"}", 1),
        "cmd: an impossible password is refused before joining");
  CHECK(!net_host_line("log_get", "{\"cmd\":\"log_get\"}", 0), "cmd: other commands are not ours");
}

static void test_hold_and_wrap() {
  // millis() wraps in the middle of the schedule.
  uint32_t t = 0xFFFFFFFFu - 60000u;
  reset(NET_MODE_SYNC, {saved("Home", "password1")});
  net_tick(t);
  F.link = NET_LINK_UP;
  net_tick(t += 100);
  F.result = result_ok(NET_JOB_TIME | NET_JOB_TFR | NET_JOB_ADSB | NET_JOB_TILES, 1790000000, t);
  F.done = true;
  net_tick(t += 100);
  uint32_t start = 0xFFFFFFFFu - 60000u;
  net_tick(start + 10 * 60000);
  CHECK(F.begins.size() == 1, "wrap: no window early across the millis() wrap");
  net_tick(start + 15 * 60000);
  CHECK(F.begins.size() == 2, "wrap: the window comes on time across the wrap");
  CHECK(F.hold, "wrap: held during the window");
  int calls = F.hold_calls;
  net_tick(start + 15 * 60000 + 10);
  CHECK(F.hold_calls == calls, "hold: not toggled every tick");
}

static void test_update_map_and_forget_builtin() {
  uint32_t t = 1000;
  NetSaved b = saved("Secret", "password9");
  b.builtin = true;
  reset(NET_MODE_SYNC, {b});
  net_tick(t);
  F.link = NET_LINK_UP;
  net_tick(t += 100);
  F.result = result_ok(NET_JOB_TIME | NET_JOB_TFR | NET_JOB_ADSB | NET_JOB_TILES, 1790000000, t);
  F.result.tiles_left = 1;   // the automatic budget ran out
  F.done = true;
  net_tick(t += 100);
  CHECK(F.stores == 0, "builtin: joining the wifi_secrets.h network writes nothing to NVS");
  net_update_map();
  net_tick(t += 100);
  F.link = NET_LINK_UP;
  net_tick(t += 100);
  CHECK(F.job_reqs.size() == 2 && (F.job_reqs[1] & NET_JOB_TILES) && F.budgets[1] == 0xFFFF,
        "map: UPDATE MAP runs the tile job without a budget");
  F.result = result_ok(NET_JOB_TILES);
  F.result.tiles_new = 40;
  F.done = true;
  net_tick(t += 100);
  CHECK(has_line("\"tiles\":40,\"tiles_left\":0"), "map: the synced line reports the tiles");
  net_tick(t += 16 * 60000);
  F.link = NET_LINK_UP;
  net_tick(t += 100);
  CHECK(!(F.job_reqs.back() & NET_JOB_TILES), "map: a complete area is not fetched again for a week");
  F.result = result_ok(NET_JOB_ADSB);
  F.done = true;
  net_tick(t += 100);
  CHECK(net_forget("Secret") && F.nvs.builtin_off && F.nvs.n == 0, "builtin: forgetting it is remembered in NVS");
  char line[120];
  net_status_line(line, sizeof(line));
  CHECK(!strcmp(line, "NOT SET UP, no network saved"), "builtin: status after forgetting");
}

static void test_forget_and_switch() {
  uint32_t t = 1000;
  reset(NET_MODE_STAY, {saved("Desk", "password1"), saved("Phone", "password2")});
  ScannedNetwork d = { "Desk", -50, 3, 6, false }, p = { "Phone", -70, 3, 1, false };
  F.nets = { d, p };
  F.scan_result = 0;
  net_tick(t);                    // pick scan starts
  net_tick(t += 100);             // done: Desk is strongest
  CHECK(F.begins.size() == 1 && F.begins[0] == "Desk/password1", "switch: STAY picks the strongest saved network");
  F.link = NET_LINK_UP;
  net_tick(t += 100);
  F.result = result_ok(NET_JOB_TIME | NET_JOB_TFR | NET_JOB_ADSB | NET_JOB_TILES, 1790000000, t);
  F.done = true;
  net_tick(t += 100);
  CHECK(net_forget() && F.nvs.n == 1 && !strcmp(F.nvs.saved[0].ssid, "Phone"), "forget: no name forgets the network in use");
  net_tick(t += 100);
  CHECK(F.leaves == 1, "forget: leaves it");
  net_tick(t += 100);
  CHECK(F.begins.size() == 2 && F.begins[1] == "Phone/password2", "switch: STAY joins the other saved network at once");
  // Mode STAY -> SYNC while online: leave, keep the schedule (no instant new window).
  F.link = NET_LINK_UP;
  net_tick(t += 100);
  F.result = result_ok(NET_JOB_ADSB);
  F.done = true;
  net_tick(t += 100);
  net_set_mode(NET_MODE_SYNC);
  net_tick(t += 100);
  size_t b = F.begins.size();
  net_tick(t += 1000);
  CHECK(!F.hold && F.begins.size() == b, "mode: STAY -> SYNC leaves and waits for the next window");
  net_update_map();
  reset(NET_MODE_SYNC, {});
  net_update_map();
  net_tick(t += 100);
  CHECK(F.begins.empty() && !F.hold, "map: UPDATE MAP with no network saved does nothing");
  // Beacon mode: only load + emit. Screens and commands answer; nothing joins.
  F = Fake();
  F.nvs.n = 1; F.nvs.saved[0] = saved("Home", "password1"); F.nvs.mode = NET_MODE_SYNC; F.nvs.every_min = 15;
  NetOps o = {};
  o.load = f_load; o.emit = f_emit;
  net_sync_init(&o);
  net_scan_start();
  net_connect("Home", NULL);
  net_tick(t += 100);
  CHECK(!net_is_scanning() && net_get_state() == NET_STATE_FAILED && !strcmp(net_last_error(), "Wi-Fi is off in this mode"),
        "beacon mode: a scan ends at once and a join fails with a reason");
  net_tick(t += 3600000);
  CHECK(net_saved_count() == 1 && F.begins.empty(), "beacon mode: saved networks shown, never joined");
}

static void test_no_position() {
  uint32_t t = 1000;
  reset(NET_MODE_SYNC, {saved("Home", "password1")});
  g_have_pos = false;
  net_tick(t);
  F.link = NET_LINK_UP;
  net_tick(t += 100);
  NetJobResult r = result_ok(NET_JOB_TIME, 1790000000, t);
  r.skipped = NET_JOB_TFR | NET_JOB_ADSB | NET_JOB_TILES;
  r.no_position = true;
  snprintf(r.err, sizeof(r.err), "%s", NET_NO_POSITION_TEXT);
  F.result = r;
  F.done = true;
  net_tick(t += 100);
  char line[120];
  net_status_line(line, sizeof(line));
  CHECK(!strcmp(line, "no position: set home from the app or wait for GPS") && net_no_position(),
        "position: none -> said once on the SYSTEM line (not as a TFR error)");
  CHECK(has_line("\"position\":false,\"err\":\"no position: set home from the app or wait for GPS\""),
        "position: the synced line says so");
  CHECK(net_is_clock_synced(), "position: the clock still syncs without one");
  F.lines.clear();
  net_host_line("wifi_status", "{\"cmd\":\"wifi_status\"}", 1);
  CHECK(has_line("\"reason\":\"no position: set home from the app or wait for GPS\"", 1) && has_line("\"position\":false", 1),
        "position: wifi_status carries it");
  net_tick(t += 30000);
  CHECK(F.begins.size() == 1, "position: no retry window while there is none");
  g_have_pos = true;   // the app sends set_home, or the GPS gets a fix
  net_tick(t += 100);
  CHECK(F.begins.size() == 2 && !net_no_position(), "position: a new window as soon as one is known");
  F.link = NET_LINK_UP;
  net_tick(t += 100);
  CHECK(F.job_reqs.size() == 2 && (F.job_reqs[1] & (NET_JOB_TFR | NET_JOB_ADSB | NET_JOB_TILES)) ==
        (NET_JOB_TFR | NET_JOB_ADSB | NET_JOB_TILES), "position: and it fetches TFR, ADS-B and tiles");
}

static void test_phone_pause() {
  uint32_t t = 1000;
  reset(NET_MODE_SYNC, {saved("Home", "password1")});
  // Mid-join: the phone connects -> the join is dropped, the hop released.
  net_tick(t);
  CHECK(F.begins.size() == 1 && F.hold, "phone: (an automatic join under way)");
  g_phone = true;
  net_tick(t += 100);
  CHECK(F.leaves == 1 && !F.hold && net_get_state() == NET_STATE_DISCONNECTED && net_is_paused(),
        "phone: connecting drops an automatic join and releases the hop at once");
  CHECK(has_line("{\"type\":\"net\",\"state\":\"paused\",\"ssid\":\"Home\",\"reason\":\"phone\"}"), "phone: a net paused line");
  char line[120];
  net_status_line(line, sizeof(line));
  CHECK(!strcmp(line, "Wi-Fi paused: phone connected"), "phone: SYSTEM line");
  F.lines.clear();
  net_host_line("wifi_status", "{\"cmd\":\"wifi_status\"}", 1);
  CHECK(has_line("\"paused\":\"phone\"", 1), "phone: wifi_status says paused:phone");
  net_tick(t += 60 * 60000);
  CHECK(F.begins.size() == 1 && !F.hold, "phone: no automatic window for an hour while connected");
  // The phone leaves: 10 s grace, then the overdue window.
  g_phone = false;
  net_tick(t += 100);
  CHECK(has_line("\"state\":\"resumed\"") && !net_is_paused(), "phone: resumed line on disconnect");
  net_tick(t += 5000);
  CHECK(F.begins.size() == 1, "phone: nothing inside the 10 s grace");
  g_phone = true;               // a quick reconnect inside the grace
  net_tick(t += 1000);
  g_phone = false;
  net_tick(t += 1000);
  net_tick(t += 9000);
  CHECK(F.begins.size() == 1, "phone: a quick reconnect restarts the grace");
  net_tick(t += 1100);
  CHECK(F.begins.size() == 2 && F.hold, "phone: after the grace the overdue window runs");
  // Mid-fetch: cancelled, station left, hop released at once; the worker drains.
  F.link = NET_LINK_UP;
  net_tick(t += 100);
  CHECK(F.running, "phone: (a fetch under way)");
  int leaves = F.leaves;
  F.lines.clear();
  g_phone = true;
  net_tick(t += 100);
  CHECK(F.cancels == 1 && F.leaves == leaves + 1 && !F.hold && net_get_state() == NET_STATE_DISCONNECTED,
        "phone: a fetch is cancelled and the station leaves without waiting for the worker");
  CHECK(F.lines.size() == 2 && F.lines[0].second.find("\"state\":\"paused\"") != std::string::npos &&
        F.lines[1].second.find("\"state\":\"idle\"") != std::string::npos,
        "phone: paused, then idle at once (the station has left)");
  net_scan_start();   // a person asks meanwhile: waits for the worker
  net_tick(t += 100);
  CHECK(F.scan_starts == 0, "phone: nothing new until the worker has stopped");
  // The worker stops at its next check: TIME had finished, TFR was cut, the
  // rest never started. Cut jobs are reported as cancelled, not failed.
  F.result = result_ok(NET_JOB_TIME, 1790000000, t);
  F.result.cancelled = NET_JOB_TFR | NET_JOB_ADSB | NET_JOB_TILES;
  snprintf(F.result.err, sizeof(F.result.err), "TFR: cancelled");
  F.done = true;
  net_tick(t += 100);
  CHECK(F.leaves == leaves + 1 && net_is_clock_synced(), "phone: the drained result is kept (clock), no second leave");
  CHECK(has_line("\"ok\":[\"time\"],\"failed\":[],\"cancelled\":[\"tfr\",\"adsb\",\"tiles\"]") &&
        has_line("\"phone\":\"cancelled\""), "phone: the late report says the pause cancelled the rest");
  CHECK(!g_net.job_wait[1] && !g_net.job_wait[2] && !g_net.job_wait[3] && !g_net.job_fails[1],
        "phone: cancelled jobs are not backed off as failures");
  net_tick(t += 100);
  CHECK(F.scan_starts == 1 && F.hold, "phone: a person's SCAN still runs while connected");
  F.nets = {};
  F.scan_result = 0;
  net_tick(t += 100);
  CHECK(!F.hold, "phone: and releases the hop when done");
  // Manual SYNC NOW while connected: runs to its end, then leaves.
  net_sync_now();
  net_tick(t += 100);
  CHECK(F.begins.size() == 3, "phone: SYNC NOW still joins while connected");
  net_status_line(line, sizeof(line));
  CHECK(!strcmp(line, "CONNECTING to Home"), "phone: the SYSTEM line shows the manual join");
  F.link = NET_LINK_UP;
  net_tick(t += 100);
  CHECK(F.running && F.hold, "phone: and fetches");
  F.result = result_ok(NET_JOB_TIME | NET_JOB_TFR | NET_JOB_ADSB);
  F.done = true;
  net_tick(t += 100);
  CHECK(!F.hold && net_get_state() == NET_STATE_DISCONNECTED, "phone: then leaves");
  // A phone wifi_join while connected runs too.
  net_host_line("wifi_join", "{\"cmd\":\"wifi_join\",\"ssid\":\"Lab\",\"psk\":\"password9\"}", 1);
  net_tick(t += 100);
  CHECK(F.begins.back() == "Lab/password9", "phone: wifi_join from the phone runs while connected");
  F.link = NET_LINK_UP;
  net_tick(t += 100);
  F.result = result_ok(NET_JOB_ADSB);
  F.done = true;
  net_tick(t += 100);
  CHECK(!F.hold && F.nvs.n == 2 && !strcmp(F.nvs.saved[0].ssid, "Lab"), "phone: joined, saved, left");

  // STAY: the phone connecting lets go of the access point; leaving rejoins after the grace.
  reset(NET_MODE_STAY, {saved("Desk", "password1")});
  net_tick(t = 1000);
  F.link = NET_LINK_UP;
  net_tick(t += 100);
  F.result = result_ok(NET_JOB_TIME | NET_JOB_TFR | NET_JOB_ADSB | NET_JOB_TILES, 1790000000, t);
  F.done = true;
  net_tick(t += 100);
  CHECK(F.hold && F.leaves == 0, "stay+phone: (associated)");
  g_phone = true;
  net_tick(t += 100);
  CHECK(F.leaves == 1 && !F.hold && net_get_state() == NET_STATE_DISCONNECTED, "stay+phone: the station disconnects, hop runs");
  net_tick(t += 60000);
  CHECK(F.begins.size() == 1, "stay+phone: no rejoin while the phone is there");
  // A mode change from the phone (to STAY) still joins, then leaves again.
  net_set_mode(NET_MODE_SYNC);
  net_host_line("wifi_mode", "{\"cmd\":\"wifi_mode\",\"mode\":\"stay\"}", 1);
  net_tick(t += 100);
  CHECK(F.begins.size() == 2, "stay+phone: wifi_mode stay from the phone joins once");
  F.link = NET_LINK_UP;
  net_tick(t += 100);
  F.result = result_ok(NET_JOB_ADSB);
  F.done = true;
  net_tick(t += 100);
  CHECK(!F.hold && F.leaves == 2, "stay+phone: and does not stay while the phone is connected");
  g_phone = false;
  net_tick(t += 100);
  net_tick(t += 9000);
  CHECK(F.begins.size() == 2, "stay+phone: grace after the phone leaves");
  net_tick(t += 1100);
  CHECK(F.begins.size() == 3 && F.hold, "stay+phone: then STAY rejoins");
  // STAY after a person's CONNECT: the manual window ends when STAY goes
  // online, so STAY's own 10 s ADS-B fetches are cancelled by a phone.
  reset(NET_MODE_STAY, {saved("Desk", "password1")});
  net_connect("Desk", NULL);
  net_tick(t = 1000);
  F.link = NET_LINK_UP;
  net_tick(t += 100);
  F.result = result_ok(NET_JOB_TIME | NET_JOB_TFR | NET_JOB_ADSB | NET_JOB_TILES, 1790000000, t);
  F.done = true;
  net_tick(t += 100);
  net_tick(t += NET_ADSB_EVERY_MS);
  CHECK(F.running && F.job_reqs.size() == 2 && F.job_reqs[1] == NET_JOB_ADSB, "stay+phone: (STAY's own ADS-B fetch under way)");
  g_phone = true;
  net_tick(t += 100);
  CHECK(F.cancels == 1 && !F.hold && F.leaves == 1, "stay+phone: that fetch is cancelled, not run to its end as the CONNECT's");
  // The hardware case: the worker had finished just before the phone
  // connected; its report is only read after the pause.
  reset(NET_MODE_SYNC, {saved("Home", "password1")});
  net_tick(t = 1000);
  F.link = NET_LINK_UP;
  net_tick(t += 100);
  F.result = result_ok(NET_JOB_TIME | NET_JOB_TFR | NET_JOB_ADSB | NET_JOB_TILES, 1790000000, t);
  F.done = true;   // done, not yet polled
  F.lines.clear();
  g_phone = true;
  net_tick(t += 100);
  CHECK(F.lines.size() == 3 && F.lines[0].second.find("\"state\":\"paused\"") != std::string::npos &&
        F.lines[1].second.find("\"state\":\"idle\"") != std::string::npos &&
        F.lines[2].second.find("\"state\":\"synced\"") != std::string::npos &&
        F.lines[2].second.find("\"phone\":\"completed before pause\"") != std::string::npos &&
        F.lines[2].second.find("\"cancelled\"") == std::string::npos,
        "phone: a fetch done before the pause is reported as completed before it");
  CHECK(!F.hold && F.leaves == 1, "phone: (and the station left once)");
  // Mode OFF: nothing to pause.
  reset(NET_MODE_OFF, {saved("Home", "password1")});
  g_phone = true;
  net_tick(t += 100);
  net_status_line(line, sizeof(line));
  CHECK(!net_is_paused() && !strcmp(line, "OFF") && !has_line("paused"), "phone: mode OFF shows OFF, not paused");
}

// ---------------------------------------------------------------------------
// net_parse.h

static void test_json() {
  char out[40];
  const char* obj = "{\"a\":{\"ssid\":\"inner\"},\"x\":\"has \\\"ssid\\\": inside\",\"ssid\":\"caf\\u00e9 \\ud83d\\ude00\",\"n\":-12.5}";
  CHECK(net_json_get_str(obj, "ssid", out, sizeof(out)) && !strcmp(out, "caf\xc3\xa9 \xf0\x9f\x98\x80"),
        "json: top-level member only, \\u and surrogate pairs as UTF-8");
  double d = 0;
  CHECK(net_json_get_num(obj, "n", &d) && d == -12.5, "json: number member");
  CHECK(!net_json_get_str(obj, "n", out, sizeof(out)), "json: a number is not a string");
  char tiny[4];
  CHECK(!net_json_get_str(obj, "ssid", tiny, sizeof(tiny)), "json: too long for the buffer is refused, not cut");
  CHECK(!net_json_find("{\"a\":1,", "b") && !net_json_find("not json", "a"), "json: malformed input finds nothing");
  char esc[64];
  net_json_esc(esc, sizeof(esc), "q\"b\\n\x01" "\xc3\xa9");
  CHECK(!strcmp(esc, "q\\\"b\\\\n\\u0001\xc3\xa9"), "json: escaping quotes, backslashes, control bytes; UTF-8 kept");
  CHECK(net_pass_ok("") && net_pass_ok("12345678") && !net_pass_ok("1234567") &&
        net_pass_ok("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef") &&
        !net_pass_ok("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeg"), "json: WPA passphrase rules");
}

struct Collect { std::vector<std::string> objs; };
static void collect(void* ctx, const char* o, size_t n) { ((Collect*)ctx)->objs.push_back(std::string(o, n)); }

static void test_split() {
  std::string body = read_file("tests/vectors/net/adsb_lol_point.json");
  char buf[2048];
  std::vector<std::string> ref;
  for (size_t chunk : { (size_t)1, (size_t)7, (size_t)333, body.size() }) {
    Collect c;
    NetJsonSplit sp;
    net_split_init(&sp, "ac", buf, sizeof(buf), collect, &c);
    for (size_t i = 0; i < body.size(); i += chunk)
      net_split_feed(&sp, body.data() + i, std::min(chunk, body.size() - i));
    if (ref.empty()) ref = c.objs;
    char name[80];
    snprintf(name, sizeof(name), "split: chunks of %zu give the same %zu objects, complete", chunk, ref.size());
    CHECK(c.objs == ref && ref.size() == 11 && sp.complete && sp.skipped == 0, name);
  }
  CHECK(ref[0].rfind("{\"hex\":\"a98f2d\"", 0) == 0 && ref[0].back() == '}', "split: an object is whole");
  Collect c;
  NetJsonSplit sp;
  char small[300];
  net_split_init(&sp, "ac", small, sizeof(small), collect, &c);
  net_split_feed(&sp, body.data(), body.size());
  CHECK(sp.skipped > 0 && c.objs.size() + sp.skipped == 11, "split: objects too big for the buffer are skipped and counted");
  NetJsonSplit cut;
  net_split_init(&cut, "ac", buf, sizeof(buf), NULL, NULL);
  net_split_feed(&cut, body.data(), body.size() / 2);
  CHECK(cut.found && !cut.complete, "split: a body cut short is not complete");
  const char* xml = "<?xml version=\"1.0\"?><ows:ExceptionReport>ORA-13200</ows:ExceptionReport>";
  NetJsonSplit bad;
  net_split_init(&bad, "features", buf, sizeof(buf), NULL, NULL);
  net_split_feed(&bad, xml, strlen(xml));
  CHECK(!bad.found && !bad.complete, "split: the FAA's XML error page is not an (empty) answer");
  const char* nested = "{\"x\":{\"ac\":[{\"no\":1}]},\"ac\":[{\"a\":\"}]\"},{\"b\":[1,{\"c\":2}]}]}";
  Collect cn;
  NetJsonSplit sn;
  net_split_init(&sn, "ac", buf, sizeof(buf), collect, &cn);
  net_split_feed(&sn, nested, strlen(nested));
  CHECK(cn.objs.size() == 2 && cn.objs[0] == "{\"a\":\"}]\"}" && cn.objs[1] == "{\"b\":[1,{\"c\":2}]}",
        "split: only the top-level member; brackets in strings and nesting handled");
}

static void test_adsb() {
  std::string body = read_file("tests/vectors/net/adsb_lol_point.json");
  TrafficAircraft ac[16];
  double dist[16];
  NetAdsbSet set = {};
  set.ac = ac; set.dist = dist; set.cap = 16; set.lat = 37.62; set.lon = -122.38; set.now_ms = 100000;
  char buf[2048];
  NetJsonSplit sp;
  net_split_init(&sp, "ac", buf, sizeof(buf), net_adsb_on_obj, &set);
  net_split_feed(&sp, body.data(), body.size());
  CHECK(set.seen == 11 && set.n == 11, "adsb: every aircraft with a position kept (all within 60 s)");
  const TrafficAircraft* a = &ac[0];
  CHECK(!strcmp(a->hex, "a98f2d") && !strcmp(a->callsign, "FFT4158") && !strcmp(a->type, "A321"),
        "adsb: hex, trimmed callsign, type");
  CHECK(fabs(a->alt_geom_m - 8725 * 0.3048) < 1e-6 && fabs(a->alt_baro_m - 8425 * 0.3048) < 1e-6,
        "adsb: altitudes in metres (geometric and pressure kept apart)");
  CHECK(fabs(a->gs_mps - 283.2 * 1852.0 / 3600.0) < 1e-6 && fabs(a->track_deg - 147.54) < 1e-9 &&
        fabs(a->vs_mps - 2624 * 0.3048 / 60.0) < 1e-9, "adsb: speed m/s, track, geometric rate preferred");
  CHECK(a->squawk == 1736 && !a->emergency && a->seen_ms == 100000 - 417, "adsb: squawk, emergency, position age");
  bool tisb = false, ground = false;
  for (int i = 0; i < set.n; i++) {
    if (!strcmp(ac[i].hex, "a5668e")) tisb = true;
    if (isnan(ac[i].alt_baro_m) && isnan(ac[i].alt_geom_m)) ground = true;
  }
  CHECK(tisb, "adsb: a ~ (non-ICAO) address keeps its hex digits");
  CHECK(ground, "adsb: alt_baro \"ground\" and no alt_geom read as unknown heights");
  TrafficAircraft x;
  CHECK(!net_adsb_parse_ac("{\"hex\":\"abc123\",\"seen\":1}", 0, &x), "adsb: no position, dropped");
  CHECK(!net_adsb_parse_ac("{\"hex\":\"abc123\",\"lat\":1,\"lon\":2,\"seen_pos\":61}", 100000, &x), "adsb: position older than 60 s, dropped");
  CHECK(net_adsb_parse_ac("{\"hex\":\"ABC123\",\"lat\":1,\"lon\":2,\"seen_pos\":0,\"squawk\":\"7700\",\"emergency\":\"general\",\"baro_rate\":-640}", 5000, &x) &&
        !strcmp(x.hex, "abc123") && x.squawk == 7700 && x.emergency && fabs(x.vs_mps + 640 * 0.3048 / 60) < 1e-9 &&
        isnan(x.alt_geom_m) && isnan(x.track_deg), "adsb: emergency, squawk 7700, baro rate fallback, missing fields NaN");
  // A cap smaller than the answer keeps the nearest.
  TrafficAircraft few[3];
  double fd[3];
  NetAdsbSet s3 = {};
  s3.ac = few; s3.dist = fd; s3.cap = 3; s3.lat = 37.62; s3.lon = -122.38; s3.now_ms = 100000;
  NetJsonSplit sp3;
  net_split_init(&sp3, "ac", buf, sizeof(buf), net_adsb_on_obj, &s3);
  net_split_feed(&sp3, body.data(), body.size());
  double maxk = 0, minrest = 1e18;
  for (int i = 0; i < 3; i++) maxk = fmax(maxk, fd[i]);
  for (int i = 0; i < set.n; i++) {
    bool kept = false;
    for (int k = 0; k < 3; k++) kept |= !strcmp(few[k].hex, ac[i].hex);
    if (!kept) minrest = fmin(minrest, dist[i]);
  }
  CHECK(s3.n == 3 && maxk <= minrest, "adsb: over the cap, the nearest are kept");
  // Into traffic.h: the set installs.
  g_traffic_observer = {37.62, -122.38, 5.0};
  traffic_ingest(ac, set.n, 100000, 100000);
  CHECK(g_traffic_have && g_traffic_count == 11, "adsb: traffic_ingest takes the set");
}

static NetRing g_ring;   // 26 KB: not on the stack

static bool outline_contains(const NetPoly* p, double lat, double lon, double lat_c, double lon_c) {
  // Move the point ~5 m toward the centre: a vertex exactly on the outline
  // may round either way once stored as float (the board's TFR table is float).
  double dy = lat_c - lat, dx = lon_c - lon, d = hypot(dx, dy);
  if (d <= 0) return net_poly_contains(p, lat, lon);
  return net_poly_contains(p, lat + dy / d * 5e-5, lon + dx / d * 5e-5);
}

static void test_tfr() {
  std::string sf = read_file("tests/vectors/net/faa_tfr_bbox_sf.json");
  NetPoly polys[16];
  double dist[16];
  NetTfrSet set = {};
  set.poly = polys; set.dist = dist; set.cap = 16; set.max_pts = 24;
  set.lat = 37.7749; set.lon = -122.4194; set.radius_m = 200000; set.ring = &g_ring;
  static char obj[16384];
  NetJsonSplit sp;
  net_split_init(&sp, "features", obj, sizeof(obj), net_tfr_on_obj, &set);
  for (size_t i = 0; i < sf.size(); i += 500) net_split_feed(&sp, sf.data() + i, std::min((size_t)500, sf.size() - i));
  CHECK(sp.complete && set.features == 7 && set.n == 5, "tfr: the SF bbox answer: 7 features, 5 within 200 km");
  bool id = false, near = false;
  for (int i = 0; i < set.n; i++) {
    id |= !strcmp(polys[i].id, "6/3475-1-FDC-F");
    near |= !strcmp(polys[i].id, "6/2518-1-FDC-F") && dist[i] > 40000 && dist[i] < 46000;
  }
  CHECK(near, "tfr: distance from home to the outline");
  CHECK(id, "tfr: ids are NOTAM_KEY cut to 14 like the Mac app");
  bool fits = true;
  for (int i = 0; i < set.n; i++) fits &= polys[i].n >= 3 && polys[i].n <= 24;
  CHECK(fits, "tfr: every polygon fits the board's 24 points");
  // DC: the 72/73-point SFRA pieces must be reduced without cutting inside.
  std::string dc = read_file("tests/vectors/net/faa_tfr_bbox_dc.json");
  NetTfrSet dset = set;
  dset.n = 0; dset.features = 0; dset.rings = 0; dset.lat = 38.9; dset.lon = -77.0;
  NetJsonSplit sd;
  net_split_init(&sd, "features", obj, sizeof(obj), net_tfr_on_obj, &dset);
  net_split_feed(&sd, dc.data(), dc.size());
  CHECK(sd.complete && dset.n == 6, "tfr: the DC answer: 6 polygons");
  // Re-parse each big ring and check every original vertex is inside its outline.
  bool big_ok = true;
  int big = 0;
  const char* p = dc.c_str();
  const char* fs = net_json_find(p, "features");
  const char* q = net_json_ws(fs + 1);
  while (*q == '{') {
    const char* e = net_json_skip(q);
    std::string feat(q, e - q);
    const char* geo = net_json_find(feat.c_str(), "geometry");
    const char* co = net_json_find(geo, "coordinates");
    NetRing* r = &g_ring;
    net_geo_ring(net_json_ws(co + 1), r);
    if (r->n > 24) {
      big++;
      std::vector<double> lat(r->y, r->y + r->n), lon(r->x, r->x + r->n);
      NetPoly out;
      net_poly_fit(r, 24, &out);
      double clat = 0, clon = 0;
      for (int i = 0; i < out.n; i++) { clat += out.lat[i]; clon += out.lon[i]; }
      clat /= out.n; clon /= out.n;
      for (size_t i = 0; i < lat.size(); i++) big_ok &= outline_contains(&out, lat[i], lon[i], clat, clon);
      big_ok &= out.n <= 24;
    }
    q = net_json_ws(e);
    if (*q == ',') q = net_json_ws(q + 1);
  }
  CHECK(big == 6 && big_ok, "tfr: the 36- to 73-point outlines fit in 24 points and contain every original vertex");
  // A 30 NM circle of 88 points: the 24-gon hugs it (never inside, < 1.2% out).
  NetRing* r = &g_ring;
  r->n = 88;
  double R = 30 * 1852.0, lat0 = 38.0, lon0 = -120.0;
  std::vector<double> clat, clon;
  for (int i = 0; i < 88; i++) {
    double a = 2 * M_PI * i / 88;
    r->y[i] = lat0 + R * cos(a) / 111195.0;
    r->x[i] = lon0 + R * sin(a) / (111195.0 * cos(lat0 * M_PI / 180));
    clat.push_back(r->y[i]); clon.push_back(r->x[i]);
  }
  NetPoly c;
  CHECK(net_poly_fit(r, 24, &c) && c.n == 24, "tfr: circle fitted to 24 points");
  bool inside = true;
  double worst = 0;
  for (int i = 0; i < 88; i++) inside &= outline_contains(&c, clat[i], clon[i], lat0, lon0);
  for (int i = 0; i < c.n; i++) worst = fmax(worst, traffic_distance_m(lat0, lon0, c.lat[i], c.lon[i]) / R - 1);
  CHECK(inside && worst < 0.012, "tfr: circle outline contains the circle, corners within 1.2%");
  // A concave L: its hull.
  double L[][2] = { {0, 0}, {0, 3}, {1, 3}, {1, 1}, {3, 1}, {3, 0} };
  r->n = 0;
  for (int k = 0; k < 30; k++) {   // 5 points per edge -> 30 points
    const double* a = L[k / 5];
    const double* b = L[(k / 5 + 1) % 6];
    double f = (k % 5) / 5.0;
    r->y[r->n] = 40 + (a[1] + (b[1] - a[1]) * f) * 0.01;
    r->x[r->n] = -100 + (a[0] + (b[0] - a[0]) * f) * 0.01;
    r->n++;
  }
  std::vector<double> ly(r->y, r->y + 30), lx(r->x, r->x + 30);
  NetPoly l;
  bool ok = net_poly_fit(r, 24, &l);
  bool all = ok;
  for (int i = 0; i < 30; i++) all &= outline_contains(&l, ly[i], lx[i], 40.012, -99.988);
  CHECK(all && l.n <= 24 && net_poly_contains(&l, 40.015, -99.985), "tfr: a concave outline grows to its hull (never inside)");
  char url[400];
  net_url_tfr(url, sizeof(url), 37.7749, -122.4194);
  CHECK(strstr(url, "&bbox=-124.6949,35.9763,-120.1439,39.5735,EPSG:4326") != NULL, "tfr: bbox is lon,lat,lon,lat (the order the FAA accepts)");
  net_url_adsb(url, sizeof(url), 37.62, -122.38, 10000);
  CHECK(!strcmp(url, "https://api.adsb.lol/v2/point/37.6200/-122.3800/6"), "adsb: URL, 10 km asks for 6 NM (rounded up)");
  CHECK(net_adsb_nm(9260) == 5 && net_adsb_nm(9261) == 6 && net_adsb_nm(30000) == 17, "adsb: km to whole NM, rounded up");
}

static void test_ntp() {
  uint8_t req[48];
  net_ntp_request(req, 0x11223344, 0x55667788);
  CHECK(req[0] == 0x23 && req[40] == 0x11 && req[47] == 0x88, "ntp: client request, v4 mode 3, our transmit time");
  uint8_t rep[48] = {0};
  rep[0] = 0x24; rep[1] = 2;
  memcpy(rep + 24, req + 40, 8);
  uint32_t sec = 1790000000u + 2208988800u;
  rep[40] = sec >> 24; rep[41] = sec >> 16; rep[42] = sec >> 8; rep[43] = sec;
  rep[44] = 0x80;   // .5 s
  uint32_t u = 0;
  uint16_t ms = 0;
  CHECK(net_ntp_parse(rep, 48, 0x11223344, 0x55667788, &u, &ms) && u == 1790000000u && ms == 500, "ntp: a server reply decodes");
  CHECK(!net_ntp_parse(rep, 48, 0x11223344, 0x55667789, &u, &ms), "ntp: a reply to someone else's request is refused");
  uint8_t bad[48];
  memcpy(bad, rep, 48); bad[1] = 0;
  CHECK(!net_ntp_parse(bad, 48, 0x11223344, 0x55667788, &u, &ms), "ntp: stratum 0 (kiss of death) refused");
  memcpy(bad, rep, 48); bad[0] = 0xE4;
  CHECK(!net_ntp_parse(bad, 48, 0x11223344, 0x55667788, &u, &ms), "ntp: unsynchronised server (LI 3) refused");
  memcpy(bad, rep, 48); bad[40] = 0xE0; bad[41] = 0; bad[42] = 0; bad[43] = 0;
  CHECK(!net_ntp_parse(bad, 48, 0x11223344, 0x55667788, &u, &ms), "ntp: a time before 2024 refused");
  CHECK(!net_ntp_parse(rep, 47, 0x11223344, 0x55667788, &u, &ms), "ntp: short packet refused");
}

static void test_tiles() {
  char url[128];
  net_url_tile(url, sizeof(url), 15, 5241, 12665);
  CHECK(!strcmp(url, "https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Dark_Gray_Base/MapServer/tile/15/12665/5241"),
        "tiles: Esri World Dark Gray, z/y/x (row before column)");
  // The defaults the fetch asks tile_plan.h for (tests/tile_plan_test.cpp has the rest).
  CHECK(NET_TILE_KM_DEFAULT == 3 && TILE_PLAN_ZMIN == 12 && TILE_PLAN_ZMAX == 15, "tiles: 3 km, zooms 12-15 by default");
}

static void test_adsb_area() {
  double home_lat = 37.8, home_lon = -122.4;
  NetArea a = net_adsb_area(home_lat, home_lon, NULL, NULL, 0, 10000, 30000);
  CHECK(a.lat == home_lat && a.lon == home_lon && a.radius_m == 10000, "area: no drones: home, the set radius");
  double dl[3], dn[3];
  // A drone 2 km out: still home.
  dl[0] = home_lat + 2000 / 111195.0; dn[0] = home_lon;
  a = net_adsb_area(home_lat, home_lon, dl, dn, 1, 10000, 30000);
  CHECK(a.lat == home_lat && a.radius_m == 10000, "area: a drone within 3 km keeps home as the centre");
  // A drone 8 km east: centre between them, radius so the drone has 9 km.
  dl[0] = home_lat; dn[0] = home_lon + 8000 / (111195.0 * cos(home_lat * M_PI / 180));
  a = net_adsb_area(home_lat, home_lon, dl, dn, 1, 10000, 30000);
  double to_home = traffic_distance_m(a.lat, a.lon, home_lat, home_lon);
  double to_drone = traffic_distance_m(a.lat, a.lon, dl[0], dn[0]);
  CHECK(fabs(to_home - 4000) < 20 && fabs(to_drone - 4000) < 20, "area: a drone 8 km out moves the centre halfway");
  CHECK(fabs(a.radius_m - 13000) < 20, "area: radius gives the drone 9 km (4 + 9 = 13 km)");
  // Drones spread wide: capped at 30 km.
  dl[1] = home_lat + 40000 / 111195.0; dn[1] = home_lon;
  dl[2] = home_lat - 5000 / 111195.0; dn[2] = home_lon;
  a = net_adsb_area(home_lat, home_lon, dl, dn, 3, 10000, 30000);
  CHECK(a.radius_m == 30000, "area: never more than 30 km");
  // A small setting with one far drone still covers the drone.
  dl[0] = home_lat + 4000 / 111195.0; dn[0] = home_lon;
  a = net_adsb_area(home_lat, home_lon, dl, dn, 1, 5000, 30000);
  CHECK(traffic_distance_m(a.lat, a.lon, dl[0], dn[0]) + 9000 <= a.radius_m + 1, "area: every live drone has 9 km around it");
  // Parsed aircraft outside the radius are dropped.
  std::string body = read_file("tests/vectors/net/adsb_lol_point.json");
  TrafficAircraft ac[16];
  double dist[16];
  NetAdsbSet set = {};
  set.ac = ac; set.dist = dist; set.cap = 16; set.lat = 37.62; set.lon = -122.38; set.now_ms = 100000;
  set.max_m = 10000;
  char buf[2048];
  NetJsonSplit sp;
  net_split_init(&sp, "ac", buf, sizeof(buf), net_adsb_on_obj, &set);
  net_split_feed(&sp, body.data(), body.size());
  bool within = set.n > 0 && set.n < 11;
  for (int i = 0; i < set.n; i++) within &= dist[i] <= 10000;
  CHECK(within, "area: aircraft beyond the radius are not kept");
}

static void test_radius_config() {
  reset(NET_MODE_SYNC, {saved("Home", "password1")});
  CHECK(net_get_adsb_radius_km() == 10 && net_get_tile_radius_km() == 3, "config: defaults 10 km ADS-B, 3 km map");
  net_set_adsb_radius_km(2);
  CHECK(net_get_adsb_radius_km() == 5 && F.nvs.adsb_km == 5, "config: ADS-B clamped to 5 km and stored");
  net_set_adsb_radius_km(99);
  CHECK(net_get_adsb_radius_km() == 30, "config: ADS-B at most 30 km");
  F.lines.clear();
  net_host_line("wifi_config", "{\"cmd\":\"wifi_config\",\"adsb_km\":12,\"tile_km\":6}", 1);
  CHECK(net_get_adsb_radius_km() == 12 && net_get_tile_radius_km() == 6 && F.nvs.tile_km == 6 &&
        has_line("\"adsb_km\":12,\"tile_km\":6", 1), "config: wifi_config sets both and answers wifi_status");
  net_host_line("wifi_config", "{\"cmd\":\"wifi_config\",\"tile_km\":4}", 0);
  CHECK(net_get_tile_radius_km() == 6 && has_line("refused over USB", 0), "config: refused over plain USB");
  // The window carries the radii; the plan's max radius caps the setting.
  uint32_t t = 1000;
  net_tick(t);
  F.link = NET_LINK_UP;
  net_tick(t += 100);
  NetJobResult r = result_ok(NET_JOB_TIME | NET_JOB_TFR | NET_JOB_ADSB | NET_JOB_TILES, 1790000000, t);
  r.adsb_radius_m = 13000;
  r.have_plan = true;
  tile_plan_make(&r.plan, 37.8, -122.4, 6000, 0x5E0000, 0, NULL, 0);
  r.tile_max_m = 9000;
  r.tiles_left = 0;
  F.result = r;
  F.done = true;
  net_tick(t += 100);
  CHECK(has_line("\"adsb_km\":13.0") && has_line("\"map\":\"Map: 6 km z12-15; ") && has_line("\"tile_max_km\":9.00"),
        "config: the synced line reports the ADS-B radius and the map plan");
  TilePlan pl;
  CHECK(net_tile_plan(&pl) && pl.total == r.plan.total && net_get_tile_radius_max_km() == 9.0, "config: net_tile_plan and the max radius");
  net_set_tile_radius_km(20);
  CHECK(net_get_tile_radius_km() == 9, "config: the map setting stops at what fits");
  double keep_max = g_net.tile_max_m;
  g_net.tile_max_m = 800;   // a plan on a nearly full flash: not even 1 km fits
  net_set_tile_radius_km(5);
  CHECK(net_get_tile_radius_km() == 1, "config: under 1 km of room the setting stays at 1 km, not 30");
  g_net.tile_max_m = keep_max;
  F.lines.clear();
  net_host_line("wifi_status", "{\"cmd\":\"wifi_status\"}", 1);
  CHECK(has_line("\"tile_max_km\":9.00", 1), "config: wifi_status carries tile_max_km");
  // A shrunk plan / a full store shows on the SYSTEM line.
  t += 16 * 60000;
  net_tick(t);
  F.link = NET_LINK_UP;
  net_tick(t += 100);
  r = result_ok(NET_JOB_ADSB | NET_JOB_TILES);
  r.have_plan = true;
  tile_plan_make(&r.plan, 37.8, -122.4, 10000, 0x5E0000, 200 * 1024, NULL, 0);
  r.storage_full = true;
  r.tiles_left = 12;
  F.result = r;
  F.done = true;
  net_tick(t += 100);
  char line[140];
  net_status_line(line, sizeof(line));
  CHECK(!strncmp(line, "Map: 10 km z12-14, ", 19) && strstr(line, "storage full"), "config: SYSTEM line shows the shrunk map and a full store");
  CHECK(has_line("\"storage_full\":true"), "config: the synced line says storage_full");
}

int main(void) {
  test_sync_window();
  test_clock_rules();
  test_join_failures();
  test_connect_saves_only_on_success();
  test_stay_mode();
  test_scan_and_pick();
  test_host_commands();
  test_hold_and_wrap();
  test_update_map_and_forget_builtin();
  test_forget_and_switch();
  test_no_position();
  test_phone_pause();
  test_adsb_area();
  test_radius_config();
  test_json();
  test_split();
  test_adsb();
  test_tfr();
  test_ntp();
  test_tiles();
  if (g_fails) printf("%d FAILED\n", g_fails); else printf("all net checks passed\n");
  return g_fails ? 1 : 0;
}
