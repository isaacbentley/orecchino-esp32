// Host-side tests for the shared radio cores, built against the shims in
// tests/host_shim. They pin the state transitions the unit tests in
// odid_test.c cannot reach: one aircraft staying one contact across several
// addresses, Authentication pages assembled across frames, the transmitter's
// format fields reaching the encoder, its off switches actually silencing
// the BLE advertising sets, and its transmit schedule replayed the way a
// receiver sees it, against ASTM F3411-22a's rates. Also the host protocol:
// where each line goes (USB, BLE), the match log's sync cursor, and what a
// host may not do (paths out of /tiles, absurd numbers).
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
#define FW_BOARD "host"
#include "Arduino.h"
#include "tx_core.h"
#include "rx_core.h"
#include "odid_build.h"
#include "odid_auth.h"
#include "ui_common.h"
#include "tile_path.h"

static int g_fails = 0;
#define CHECK(c, name) do { if (c) printf("ok   %s\n", name); else { printf("FAIL %s\n", name); g_fails++; } } while (0)

static const uint8_t M1[6] = {2, 0, 0x5E, 0x7E, 0x57, 0x11};
static const uint8_t M2[6] = {2, 0, 0x5E, 0x7E, 0x57, 0x22};
static const uint8_t M3[6] = {2, 0, 0x5E, 0x7E, 0x57, 0x33};

// ------------------------------------------------------------- tracker.h

static void test_tracker(void) {
  memset(g_tracks, 0, sizeof g_tracks);
  bool c;
  tracker_upsert(M1, "A", 1000, &c);      // BLE Basic ID
  tracker_upsert(M2, "A", 2000, &c);      // Wi-Fi Basic ID, other address
  tracker_upsert(M1, nullptr, 3000, &c);  // BLE Location: no ID to match on
  CHECK(tracker_count() == 1, "tracker: BLE basic, WiFi basic, BLE location -> one contact");
  tracker_upsert(M2, nullptr, 4000, &c);
  CHECK(tracker_count() == 1, "tracker: WiFi location from the other address -> still one");
  for (int i = 0; i < 8; i++) tracker_upsert(i & 1 ? M2 : M1, nullptr, 5000 + i * 100, &c);
  CHECK(tracker_count() == 1, "tracker: alternating addresses -> still one");
  tracker_upsert(M3, "A", 9000, &c);      // a third address (NAN)
  tracker_upsert(M1, nullptr, 9100, &c);
  tracker_upsert(M2, nullptr, 9200, &c);
  tracker_upsert(M3, nullptr, 9300, &c);
  CHECK(tracker_count() == 1, "tracker: three addresses -> one contact");
  // The remembered list stays oldest-first, so eviction drops the address
  // unused longest: after six addresses, the first two have gone.
  const uint8_t M4[6] = {2,0,0x5E,0x7E,0x57,0x44}, M5[6] = {2,0,0x5E,0x7E,0x57,0x55}, M6[6] = {2,0,0x5E,0x7E,0x57,0x66};
  tracker_upsert(M4, "A", 9400, &c); tracker_upsert(M5, "A", 9500, &c);
  tracker_upsert(M2, nullptr, 9600, &c);    // M2 comes back: it is now the newest
  tracker_upsert(M6, "A", 9700, &c);        // sixth address: the oldest (M1) is evicted, not M2
  Track* t = &g_tracks[0];
  bool has_m2 = false, has_m1 = false;
  for (int m = 0; m < t->alt_mac_count; m++) { if (!memcmp(t->alt_macs[m], M2, 6)) has_m2 = true; if (!memcmp(t->alt_macs[m], M1, 6)) has_m1 = true; }
  CHECK(tracker_count() == 1 && has_m2 && !has_m1, "tracker: eviction drops the address unused longest");

  memset(g_tracks, 0, sizeof g_tracks);
  tracker_upsert(M1, "X", 100, &c);
  tracker_upsert(M1, "Y", 200, &c);
  CHECK(tracker_count() == 2, "tracker: two UAS IDs on one address stay two contacts");
}

// ------------------------------------------------------------- tx_core.h

static void run_ticks(int n) { for (int k = 0; k < n; k++) { g_millis += 2; tx_tick(g_millis); } }
static void run_ms(uint32_t ms) { run_ticks((int)(ms / 2)); }

static int tx_pid_of(const uint8_t* addr, bool ble) {
  for (int i = 0; i < P_COUNT; i++) {
    uint8_t a[6];
    memcpy(a, PATHS[i].mac, 6);
    if (ble) a[0] |= 0xC0;
    if (!memcmp(a, addr, 6)) return i;
  }
  return -1;
}

// Which ODID messages one payload carried, as bits: 0 Basic ID, 1 Location,
// 2 Authentication, 3 Self ID, 4 System, 5 Operator ID.
static unsigned odid_kinds(const uint8_t* d, int len, bool* ok, OdidUas* u) {
  *ok = odid_decode_payload(d, len, u);
  unsigned k = 0;
  if (u->has_basic[0]) k |= 1u;
  if (u->has_loc) k |= 2u;
  if (u->has_auth) k |= 4u;
  if (u->has_self) k |= 8u;
  if (u->has_sys) k |= 16u;
  if (u->has_op) k |= 32u;
  return k;
}

// The longest wait for each message kind, per path, over a window: the gap
// from the window's start to the first one and from the last to its end
// count too, so a kind that never came reads as the whole window.
struct TxGaps {
  uint32_t last[P_COUNT][6], worst[P_COUNT][6];
  int seen[P_COUNT];            // payloads that decoded
  int bad[P_COUNT];             // payloads that did not
  void start(uint32_t t0) {
    for (int p = 0; p < P_COUNT; p++) { for (int k = 0; k < 6; k++) { last[p][k] = t0; worst[p][k] = 0; } seen[p] = bad[p] = 0; }
  }
  void add(int p, unsigned kinds, uint32_t at, bool ok) {
    if (p < 0) return;
    if (!ok) { bad[p]++; return; }
    seen[p]++;
    for (int k = 0; k < 6; k++)
      if (kinds & (1u << k)) { worst[p][k] = std::max(worst[p][k], at - last[p][k]); last[p][k] = at; }
  }
  void finish(uint32_t t1) {
    for (int p = 0; p < P_COUNT; p++) for (int k = 0; k < 6; k++) worst[p][k] = std::max(worst[p][k], t1 - last[p][k]);
  }
  uint32_t loc(int p) const { return worst[p][1]; }
  uint32_t statics(int p) const { return std::max(std::max(worst[p][0], worst[p][3]), std::max(worst[p][4], worst[p][5])); }
};

// Every Wi-Fi frame captured in [t0, t1): the ODID payload of each beacon
// or NAN service discovery frame, by path. Also checks the frames' own
// fields: the Authentication variants verify (or, AUTHBAD, do not), and a
// NAN SDF names the cluster its sync beacon announced.
struct TxWifiScan { int frames[P_COUNT] = {0}; int sync = 0; int auth_ok = 0, auth_wrong = 0; bool cluster_ok = true; uint16_t beacon_tu[P_COUNT] = {0}; };
static TxWifiScan tx_scan_wifi(TxGaps* g, uint32_t t0, uint32_t t1) {
  TxWifiScan s;
  uint8_t cluster[6] = {0};
  for (size_t i = 0; i < g_wifi_tx.size(); i++) {
    uint32_t at = g_wifi_tx_at[i];
    if (at < t0 || at >= t1) continue;
    const std::vector<uint8_t>& f = g_wifi_tx[i];
    int pid = tx_pid_of(&f[10], false);
    const uint8_t* odid = nullptr; int n = 0;
    if (f[0] == 0x80) {
      s.beacon_tu[pid < 0 ? 0 : pid] = (uint16_t)(f[32] | (f[33] << 8));
      for (size_t o = 36; o + 2 <= f.size() && o + 2 + f[o + 1] <= f.size(); o += 2 + f[o + 1]) {
        const uint8_t* ie = &f[o];
        if (ie[0] != 0xDD) continue;
        if (ie[1] >= 5 && ie[2] == 0xFA && ie[3] == 0x0B && ie[4] == 0xBC && ie[5] == 0x0D) { odid = ie + 7; n = ie[1] - 5; }
        if (ie[1] >= 4 && ie[2] == 0x50 && ie[3] == 0x6F && ie[4] == 0x9A && ie[5] == 0x13) { s.sync++; memcpy(cluster, &f[16], 6); }
      }
    } else if (f[0] == 0xD0) {
      if (memcmp(&f[16], cluster, 6) != 0) s.cluster_ok = false;
      static const uint8_t SVC[6] = {0x88, 0x69, 0x19, 0x9D, 0x92, 0x09};
      for (size_t o = 24; o + 12 < f.size(); o++)
        if (!memcmp(&f[o], SVC, 6)) { n = f[o + 9] - 1; odid = &f[o + 11]; break; }
    }
    if (!odid) continue;
    s.frames[pid]++;
    bool ok; OdidUas u;
    unsigned k = odid_kinds(odid, n, &ok, &u);
    g->add(pid, k, at, ok);
    if (pid == P_AUTH || pid == P_AUTHBAD) {
      int want = pid == P_AUTH ? ODID_AUTH_TEST_KEY : ODID_AUTH_INVALID;
      if (odid_verify_auth(&u) == want) s.auth_ok++; else s.auth_wrong++;
    }
  }
  return s;
}

// Replay the advertising sets as a controller runs them: an event at start
// and every interval after, carrying whatever data the set held then,
// until it is stopped. Counts events per path into `events`.
static void tx_scan_ble(TxGaps* g, uint32_t t0, uint32_t t1, int* events, int* legacy_bad) {
  const std::vector<AdvLogRec>& L = NimBLEDevice::adv.log;
  for (int inst = 0; inst < NimBLEExtAdvertising::N; inst++) {
    bool on = false;
    double next = 0, itvl = 1;
    NimBLEExtAdvertisement cur;
    auto emit_until = [&](double t) {
      while (on && next < t) {
        uint32_t at = (uint32_t)next;
        if (at >= t0 && at < t1) {
          int pid = tx_pid_of(cur.addr.v, true);
          if (pid >= 0) events[pid]++;
          if (cur.legacy && cur.data.size() != 31) (*legacy_bad)++;
          bool ok = cur.data.size() > 6 && cur.data[1] == 0x16 && cur.data[2] == 0xFA && cur.data[3] == 0xFF && cur.data[4] == 0x0D;
          OdidUas u;
          unsigned k = ok ? odid_kinds(cur.data.data() + 6, (int)cur.data.size() - 6, &ok, &u) : 0;
          g->add(pid, k, at, ok);
        }
        next += itvl;
      }
    };
    for (const AdvLogRec& r : L) {
      if (r.inst != inst) continue;
      emit_until(r.at);
      if (r.kind == 'S') { on = true; cur = r.adv; itvl = r.adv.itvl * 0.625; next = r.at; }
      else if (r.kind == 'X') on = false;
      else if (r.kind == 'D') cur.data = r.adv.data;
    }
    emit_until(t1);
  }
}

// F3411-22a on one path: Location at least once a second, each static
// message at least every 3 s, and every payload decodable.
static bool tx_path_meets_spec(const TxGaps& g, int p) {
  return g.seen[p] > 0 && g.bad[p] == 0 && g.loc(p) <= 1000 && g.statics(p) <= 3000;
}

// Run 30 s with every path on and check every path against the spec, the
// way a receiver would see it. Prints the measured worst gaps.
static void tx_check_spec_schedule(const char* label) {
  for (int i = 0; i < P_COUNT; i++) tx_set_enabled(i, true);
  run_ms(2000);                                   // settle: every set up
  uint32_t t0 = g_millis, t1 = t0 + 30000;
  g_wifi_tx.clear(); g_wifi_tx_at.clear();
  NimBLEDevice::adv.log.clear();
  uint32_t err0 = s_err_n;
  // The sets already on air carry on: seed the replay with them.
  for (int k = 0; k < NimBLEExtAdvertising::N; k++)
    if (NimBLEDevice::adv.active[k]) NimBLEDevice::adv.log.push_back({t0, (uint8_t)k, 'S', NimBLEDevice::adv.inst_data[k]});
  run_ms(30000);
  TxGaps g; g.start(t0);
  TxWifiScan w = tx_scan_wifi(&g, t0, t1);
  int ev[P_COUNT] = {0}, legacy_bad = 0;
  tx_scan_ble(&g, t0, t1, ev, &legacy_bad);
  g.finish(t1);
  bool all = true;
  char name[96];
  for (int p = 0; p < P_COUNT; p++) {
    printf("     %-9s %-20s %5d payloads/30 s  Location max gap %4u ms  statics max gap %4u ms\n",
           label, PATHS[p].uas_id, g.seen[p], (unsigned)g.loc(p), (unsigned)g.statics(p));
    if (!tx_path_meets_spec(g, p)) all = false;
  }
  snprintf(name, sizeof name, "tx %s: every path decodes, Location every <= 1 s, each static message every <= 3 s", label);
  CHECK(all, name);
  snprintf(name, sizeof name, "tx %s: AUTH verifies under the test key in every frame, AUTHBAD never does", label);
  CHECK(w.auth_ok > 200 && w.auth_wrong == 0, name);
  snprintf(name, sizeof name, "tx %s: NAN sync beacon about twice a second, SDFs name its cluster", label);
  CHECK(w.sync >= 55 && w.sync <= 65 && w.cluster_ok, name);
  snprintf(name, sizeof name, "tx %s: Wi-Fi packs 4 Hz, SINGLE 8 Hz, NAN 4 Hz per path", label);
  CHECK(w.frames[P_WIFI] >= 118 && w.frames[P_WIFI] <= 121 && w.frames[P_AUTH] >= 118 && w.frames[P_SINGLE] >= 238 &&
        w.frames[P_SINGLE] <= 241 && w.frames[P_NAN] >= 118 && w.frames[P_NAN] <= 121, name);
  snprintf(name, sizeof name, "tx %s: beacon interval field says what the path keeps (244 TU, SINGLE 122)", label);
  CHECK(w.beacon_tu[P_WIFI] == 244 && w.beacon_tu[P_SINGLE] == 122, name);
  snprintf(name, sizeof name, "tx %s: BLE4 is a 31-byte legacy advertisement, ~20 events/s", label);
  CHECK(legacy_bad == 0 && ev[P_BLE4] >= 570 && ev[P_BLE4] <= 610, name);
  snprintf(name, sizeof name, "tx %s: no transmit errors", label);
  CHECK(s_err_n == err0, name);
}

static void test_tx(void) {
  odid_auth_init();
  uint8_t out[240]; OdidUas u;
  int n = build_payload(P_WIFI, out, 5000);
  CHECK(odid_decode_payload(out, n, &u) && (out[0] & 0x0F) == 2, "tx: P_WIFI pack is protocol v2");
  n = build_payload(P_V0, out, 5000);
  CHECK(odid_decode_payload(out, n, &u) && (out[0] & 0x0F) == 0 && (out[3] & 0x0F) == 0, "tx: P_V0 pack is protocol v0");
  n = build_payload(P_DUAL, out, 5000);
  CHECK(odid_decode_payload(out, n, &u) && out[2] == 6 && u.has_basic[1] && u.id_type[1] == 2 &&
        !strcmp(u.uas_id[1], "CAA-REG-TEST-0001"), "tx: P_DUAL carries serial + CAA Basic IDs");
  int fl = build_beacon(P_DUAL, out, n, 0, 250);
  CHECK(fl > 0 && !memcmp(s_frame + 10, PATHS[P_DUAL].mac, 6) && !memcmp(s_frame + 16, PATHS[P_DUAL].mac, 6),
        "tx: beacon SA/BSSID use the path's own MAC");
  CHECK(s_frame[34] == 0x20 && s_frame[35] == 0x04, "tx: beacon capability is short preamble + short slot, as the reference");
  n = build_payload(P_AUTH, out, 5000);
  CHECK(odid_decode_payload(out, n, &u) && odid_verify_auth(&u) == ODID_AUTH_TEST_KEY,
        "tx: P_AUTH pack verifies under the published test key -> test_key, never id_valid");
  n = build_payload(P_AUTHBAD, out, 5000);
  CHECK(odid_decode_payload(out, n, &u) && odid_verify_auth(&u) == ODID_AUTH_INVALID, "tx: P_AUTHBAD pack verifies invalid");
  n = build_payload(P_AUTH, out, 6000);           // next second: a new signature, not the cached one
  CHECK(odid_decode_payload(out, n, &u) && u.auth_ts == 6 && odid_verify_auth(&u) == ODID_AUTH_TEST_KEY,
        "tx: the cached signature follows the timestamp");

  // ---- three advertising sets: each BLE path has its own
  NimBLEDevice::adv.reset(3);
  shim_nvs().erase("orecchino/tx_rate");
  g_millis = 10000;
  tx_begin();
  CHECK(tx_ble_sets() == 3 && !tx_slow(), "tx: probe finds a third advertising set; spec rate by default");
  tx_check_spec_schedule("3 sets");
  CHECK(s_ble_restarts == 0 && NimBLEDevice::adv.stop_all_calls == 0,
        "tx: 3 sets: payloads are swapped in place, no set is restarted");
  {
    size_t s0 = NimBLEDevice::adv.starts.size();
    run_ms(10000);
    CHECK(NimBLEDevice::adv.starts.size() == s0, "tx: 3 sets: no set is ever restarted while its path stays on");
  }

  // Pause: every set stops (NimBLE's stop-all refuses while a set runs, so
  // each is stopped on its own), nothing radiates, and resume comes back
  // without a single error.
  uint32_t err0 = s_err_n;
  tx_set_running(false);
  run_ticks(2);
  CHECK(!NimBLEDevice::adv.isAdvertising(), "tx: pause stops every advertising set");
  size_t wifi_before = g_wifi_tx.size();
  run_ms(1000);
  CHECK(g_wifi_tx.size() == wifi_before && !NimBLEDevice::adv.isAdvertising(), "tx: nothing radiates while paused");
  tx_set_running(true);
  run_ms(100);
  CHECK(NimBLEDevice::adv.active[0] && NimBLEDevice::adv.active[1] && NimBLEDevice::adv.active[2] && s_err_n == err0,
        "tx: resume brings all three sets back, no errors");
  tx_set_enabled(P_BLE5, false);
  run_ticks(2);
  CHECK(!NimBLEDevice::adv.active[0] && NimBLEDevice::adv.active[1] && NimBLEDevice::adv.active[2],
        "tx: switching BLE5 off stops its set only");
  tx_set_enabled(P_BLELR, false);
  tx_set_enabled(P_BLE4, false);
  run_ticks(2);
  CHECK(!NimBLEDevice::adv.isAdvertising(), "tx: no BLE advertising with all BLE paths off");
  for (int i = 0; i < P_COUNT; i++) tx_set_enabled(i, false);
  wifi_before = g_wifi_tx.size();
  run_ms(1000);
  CHECK(g_wifi_tx.size() == wifi_before, "tx: ALL OFF sends no Wi-Fi frames");

  // ---- the driver refuses frames: counted, reported, retried
  for (int i = 0; i < P_COUNT; i++) tx_set_enabled(i, i == P_WIFI);
  run_ms(1000);
  uint32_t werr = s_wifi_err, sent = s_tx[P_WIFI];
  Serial.out.clear();
  g_wifi_tx_refuse = 3;
  run_ms(5100);
  CHECK(s_wifi_err == werr + 3 && s_err[P_WIFI] >= 3, "tx: refused Wi-Fi frames are counted");
  CHECK(Serial.out.find("\"op\":\"wifi_tx\",\"rc\":257") != std::string::npos &&
        Serial.out.find("\"wifi_err\":" + std::to_string(werr + 3)) != std::string::npos,
        "tx: ...reported as a tx_err line and on the status line");
  CHECK(s_tx[P_WIFI] - sent >= 19, "tx: ...and retried 20 ms later, so the path keeps its rate");
  g_wifi_channel = 11;
  run_ms(1100);
  CHECK(g_wifi_channel == WIFI_CHANNEL && s_ch_fix >= 1, "tx: a channel that drifted is put back on 6");

  // ---- two advertising sets (the C3 controller): BLE4 keeps set 1, BLE5
  // 1M and coded share set 0 in turns, and all three still meet the spec
  NimBLEDevice::adv.reset(2);
  ble_relayout(3);
  CHECK(tx_ble_sets() == 2, "tx: probe falls back to two sets when the controller grants two");
  tx_check_spec_schedule("2 sets");
  {
    // Coded and 1M each hold set 0 for share_ms before handing it over.
    uint32_t shortest = UINT32_MAX; int prev = -1; uint32_t prev_at = 0;
    for (const AdvStartRec& a : NimBLEDevice::adv.starts) {
      if (a.inst != 0) continue;
      int pid = tx_pid_of(a.adv.addr.v, true);
      if (prev >= 0 && pid != prev) shortest = std::min(shortest, a.at - prev_at);
      prev = pid; prev_at = a.at;
    }
    CHECK(shortest != UINT32_MAX && shortest >= TX_RATES[TX_RATE_SPEC].share_ms,
          "tx: 2 sets: 1M and coded take set 0 in turns of 500 ms");
  }

  // ---- a controller that took the probe but then refuses the third set
  NimBLEDevice::adv.reset(3);
  ble_relayout(3);
  for (int i = 0; i < P_COUNT; i++) tx_set_enabled(i, true);
  run_ms(100);
  tx_set_enabled(P_BLE4, false); run_ticks(2);
  NimBLEDevice::adv.max_sets = 2;
  tx_set_enabled(P_BLE4, true);
  run_ms(1000);
  CHECK(tx_ble_sets() == 2 && NimBLEDevice::adv.active[0] && NimBLEDevice::adv.active[1],
        "tx: a third set refused at start falls back to the two-set layout");

  // ---- slow: the old quiet bench rate, once every 5 s per path, saved
  NimBLEDevice::adv.reset(3);
  ble_relayout(3);
  tx_set_slow(true);
  CHECK(shim_nvs().count("orecchino/tx_rate") && shim_nvs()["orecchino/tx_rate"][0] == TX_RATE_SLOW,
        "tx: the slow rate is saved in NVS");
  s_rate = TX_RATE_SPEC;
  tx_begin();
  CHECK(tx_slow(), "tx: ...and restored at boot");
  for (int i = 0; i < P_COUNT; i++) tx_set_enabled(i, true);
  run_ms(10000);
  {
    uint32_t t0 = g_millis, t1 = t0 + 60000;
    g_wifi_tx.clear(); g_wifi_tx_at.clear();
    NimBLEDevice::adv.log.clear();
    for (int k = 0; k < NimBLEExtAdvertising::N; k++)
      if (NimBLEDevice::adv.active[k]) NimBLEDevice::adv.log.push_back({t0, (uint8_t)k, 'S', NimBLEDevice::adv.inst_data[k]});
    run_ms(60000);
    TxGaps g; g.start(t0);
    TxWifiScan w = tx_scan_wifi(&g, t0, t1);
    int ev[P_COUNT] = {0}, legacy_bad = 0;
    tx_scan_ble(&g, t0, t1, ev, &legacy_bad);
    g.finish(t1);
    bool every5 = true;
    for (int p = 0; p < P_COUNT; p++) {
      int k = PATHS[p].carrier == C_BEACON || PATHS[p].carrier == C_NAN ? w.frames[p] : ev[p];
      if (k < 11 || k > 13) every5 = false;
      printf("     slow      %-20s %3d transmissions/min  Location max gap %5u ms\n", PATHS[p].uas_id, k, (unsigned)g.loc(p));
    }
    CHECK(every5, "tx: slow: every path transmits once every 5 s (11-13 a minute)");
    CHECK(g.loc(P_WIFI) <= 5100 && g.loc(P_BLE5) <= 5100 && g.bad[P_BLE4] == 0, "tx: slow: a pack path's Location every 5 s");
  }
  tx_set_slow(false);
  CHECK(!tx_slow() && shim_nvs()["orecchino/tx_rate"][0] == TX_RATE_SPEC, "tx: back to the spec rate, saved");
  run_ms(100);
  CHECK(NimBLEDevice::adv.inst_data[0].itvl == 160 && NimBLEDevice::adv.inst_data[2].itvl == 80,
        "tx: a rate change reconfigures the sets' intervals (100 ms, BLE4 50 ms)");
  // Console: `rate slow` / `rate spec`, `sets 2`.
  Serial.in = "rate slow\nsets 2\n"; Serial.in_pos = 0;
  run_ticks(1);
  CHECK(tx_slow() && tx_ble_sets() == 2, "tx: console `rate slow` and `sets 2` take effect");
  Serial.in = "rate spec\nsets 3\n"; Serial.in_pos = 0;
  run_ticks(1);
  CHECK(!tx_slow() && tx_ble_sets() == 3 && Serial.out.find("\"rate\":\"spec\"") != std::string::npos,
        "tx: ...and `rate spec` / `sets 3` back, on the status line");
}

// ------------------------------------------------------------- rx_core.h

static Track* by_mac(const uint8_t* m) {
  for (auto& t : g_tracks) if (t.used && !memcmp(t.mac, m, 6)) return &t;
  return nullptr;
}

// A signed pack: Basic ID, Location, Self ID, System, Operator ID, then the
// four Authentication pages of an Ed25519 signature over the Basic ID.
static int build_signed(uint8_t* pack, bool corrupt, uint32_t ts = 100) {
  OdidTxState st; memset(&st, 0, sizeof st);
  st.uas_id = "ORECCHINO-TX-AUTH"; st.proto_ver = 2; st.ua_type = 2; st.status = 2;
  st.lat = 37.8; st.lon = -122.4; st.alt_geo_m = 80; st.height_m = 60; st.speed_ms = 5; st.dir_deg = 90;
  st.self_desc = "TEST"; st.op_lat = 37.8; st.op_lon = -122.4; st.op_alt_m = 10; st.op_id = "OP";
  odid_build_pack(pack, &st, ts);
  uint8_t sig[64]; odid_auth_sign(sig, pack + 3, ts);
  if (corrupt) sig[0] ^= 0xFF;
  int count = pack[2], pages = odid_auth_pages(64);
  for (int pg = 0; pg < pages; pg++) odid_build_auth_page(pack + 3 + (count++) * 25, &st, 1, pg, sig, 64, ts);
  pack[2] = (uint8_t)count;
  return 3 + count * 25;
}
#define MSG(pack, i) ((pack) + 3 + (i) * 25)   // i: 0 Basic, 1 Location, 5.. auth pages

static uint32_t s_rx_now = 1000;
static void feed(uint8_t src, const uint8_t* mac, const uint8_t* d, int len) {
  enqueue_rid(src, mac, -40, 6, 0, d, len, nullptr);
  s_rx_now += 50;
  rx_tick(s_rx_now);
}
static size_t count_in(const std::string& h, const char* needle) {
  size_t n = 0, p = 0;
  while ((p = h.find(needle, p)) != std::string::npos) { n++; p += strlen(needle); }
  return n;
}

static void test_rx(void) {
  odid_auth_init();
  rx_begin(nullptr);
  // The app may attach after boot, so the capabilities ride on the boot line
  // and on every fifth heartbeat.
  CHECK(count_in(Serial.out, "\"type\":\"boot\"") == 1 && count_in(Serial.out, "\"caps\":[\"log\",\"log_since\",\"tfr\"") == 1,
        "rx: the boot line carries the capabilities");
  Serial.out.clear();
  for (int i = 0; i < 5; i++) emit_heartbeat();
  CHECK(count_in(Serial.out, "\"type\":\"hb\"") == 5 && count_in(Serial.out, "\"caps\":") == 1,
        "rx: one heartbeat in five carries the capabilities");
  uint8_t pack[240];
  int n = build_signed(pack, false);
  memset(g_tracks, 0, sizeof g_tracks); Serial.out.clear();
  feed(SRC_WIFI_BEACON, M1, pack, n);
  CHECK(by_mac(M1) && by_mac(M1)->auth_state == ODID_AUTH_TEST_KEY, "rx: signed pack in one frame -> test_key");
  CHECK(count_in(Serial.out, "\"state\":\"test_key\"") == 1 && count_in(Serial.out, "id_valid") == 0,
        "rx: JSON reports test_key for the pack, not id_valid");

  memset(g_tracks, 0, sizeof g_tracks); Serial.out.clear();
  uint32_t pf = s_cnt_pfail;
  feed(SRC_BLE, M2, MSG(pack, 0), 25);                              // Basic ID alone
  for (int pg = 0; pg < 4; pg++) feed(SRC_BLE, M2, MSG(pack, 5 + pg), 25);  // one page per frame
  CHECK(s_cnt_pfail == pf, "rx: auth-only frames decode instead of counting as parse failures");
  CHECK(by_mac(M2) && by_mac(M2)->auth_state == ODID_AUTH_TEST_KEY, "rx: Basic ID + four single-message pages -> test_key");
  CHECK(count_in(Serial.out, "\"state\":\"partial\"") == 3 && count_in(Serial.out, "\"state\":\"test_key\"") == 1,
        "rx: JSON says partial three times, then test_key");
  feed(SRC_BLE, M2, MSG(pack, 1), 25);                              // Location alone
  CHECK(by_mac(M2)->auth_state == ODID_AUTH_TEST_KEY, "rx: a later Location frame keeps the verdict");
  CHECK(count_in(Serial.out, "\"state\":\"test_key\"") == 2, "rx: ...and its JSON line still carries it");

  memset(g_tracks, 0, sizeof g_tracks);
  n = build_signed(pack, true);
  feed(SRC_BLE, M2, MSG(pack, 0), 25);
  for (int pg = 0; pg < 4; pg++) feed(SRC_BLE, M2, MSG(pack, 5 + pg), 25);
  CHECK(by_mac(M2) && by_mac(M2)->auth_state == ODID_AUTH_INVALID, "rx: corrupted signature assembled across frames -> invalid");

  // A new signature set whose page 0 arrives after its other pages must not
  // have those pages wiped by that page 0; and its verdict must be its own.
  memset(g_tracks, 0, sizeof g_tracks); n = build_signed(pack, false, 100);
  feed(SRC_BLE, M2, MSG(pack, 0), 25);
  for (int pg = 0; pg < 4; pg++) feed(SRC_BLE, M2, MSG(pack, 5 + pg), 25);
  CHECK(by_mac(M2)->auth_state == ODID_AUTH_TEST_KEY, "rx: first set verifies");
  uint8_t pack2[240]; build_signed(pack2, true, 200);            // second set: corrupted, page 0 last
  for (int pg = 1; pg < 4; pg++) feed(SRC_BLE, M2, MSG(pack2, 5 + pg), 25);
  CHECK(by_mac(M2)->auth_state == ODID_AUTH_TEST_KEY, "rx: the old verdict holds while the new set is incomplete");
  Serial.out.clear();
  feed(SRC_BLE, M2, MSG(pack2, 5), 25);
  CHECK(by_mac(M2)->auth_state == ODID_AUTH_INVALID && count_in(Serial.out, "\"state\":\"invalid\"") == 1, "rx: the late page 0 completes the new set, which fails as it should");
  uint8_t pack3[240]; build_signed(pack3, false, 300);            // third set: good again, page 0 last
  for (int pg = 1; pg < 4; pg++) feed(SRC_BLE, M2, MSG(pack3, 5 + pg), 25);
  feed(SRC_BLE, M2, MSG(pack3, 5), 25);
  CHECK(by_mac(M2)->auth_state == ODID_AUTH_TEST_KEY, "rx: and a good set after a bad one clears it");

  memset(g_tracks, 0, sizeof g_tracks);
  n = build_signed(pack, false);
  feed(SRC_BLE, M1, MSG(pack, 0), 25);          // BLE Basic A
  feed(SRC_WIFI_BEACON, M2, MSG(pack, 0), 25);  // Wi-Fi Basic A from another address
  feed(SRC_BLE, M1, MSG(pack, 1), 25);          // Location-only frames from both
  feed(SRC_WIFI_BEACON, M2, MSG(pack, 1), 25);
  feed(SRC_BLE, M1, MSG(pack, 1), 25);
  CHECK(tracker_count() == 1, "rx: one aircraft on two addresses stays one contact through Location-only frames");
}

static void unhex(const char* h, std::vector<uint8_t>& out) {
  for (int i = 0; h[i] && h[i + 1]; i += 2) { char t[3] = { h[i], h[i + 1], 0 }; out.push_back((uint8_t)strtoul(t, nullptr, 16)); }
}
static void feed_frame(const std::vector<uint8_t>& frame) {
  std::vector<uint8_t> buf(sizeof(wifi_pkt_rx_ctrl_t) + frame.size() + 4);
  wifi_promiscuous_pkt_t* p = (wifi_promiscuous_pkt_t*)buf.data();
  p->rx_ctrl.rssi = -40; p->rx_ctrl.channel = 6; p->rx_ctrl.sig_len = (uint16_t)(frame.size() + 4);   // + FCS
  memcpy(p->payload, frame.data(), frame.size());
  wifi_cb(p, WIFI_PKT_MGMT);
  s_rx_now += 50;
  rx_tick(s_rx_now);
}
static bool json_has(const char* s) { return Serial.out.find(s) != std::string::npos; }

// A real DJI beacon (Light RID Scanner's capture) and a GB 46750-2025
// beacon, through the promiscuous callback: SSID kept and checked, both
// formats decoded to the same track fields, the JSON line saying which.
static void test_sniffer(void) {
  memset(g_tracks, 0, sizeof g_tracks); Serial.out.clear();
  std::vector<uint8_t> dji;
  unhex("80000000ffffffffffff8c1ed90309b28c1ed90309b20000e80c6b2200000000a000210400185249442d3135383146"
        "384442573235423830304233343137dd53fa0bbc0d06f11903011231353831463844425732354238303042333431"
        "370000001120ac1600a3d4ea11cbfe3c48e2089e0879082c04c6250a004109ffeeea1199b73d480100000000000002"
        "0008d774da0d00", dji);
  feed_frame(dji);
  Track* t = by_mac(dji.data() + 10);
  CHECK(t && !strcmp(t->uas, "1581F8DBW25B800B3417"), "sniffer: DJI v1 beacon decodes to its serial");
  CHECK(t && t->has_pos && fabs(t->lat - 30.0602531) < 1e-6 && t->height_ref == 0, "sniffer: position and height reference from the capture");
  CHECK(t && !strcmp(t->ssid, "RID-1581F8DBW25B800B3417") && t->ssid_check == 1 && t->fmt == 1, "sniffer: SSID kept, its serial matches, format ASTM");
  CHECK(json_has("\"proto\":1") && json_has("\"ssid\":\"RID-1581F8DBW25B800B3417\"") && json_has("\"ssid_id_match\":true"), "sniffer: JSON carries proto, ssid and the match");

  std::vector<uint8_t> odd = dji;
  odd[36 + 2 + 23] = '9';                     // the SSID now names ...3419
  memset(g_tracks, 0, sizeof g_tracks); Serial.out.clear();
  feed_frame(odd);
  t = by_mac(dji.data() + 10);
  CHECK(t && t->ssid_check == 2 && json_has("\"ssid_id_match\":false"), "sniffer: an SSID naming another serial is flagged");

  // GB 46750 beacon: header, fixed params, SSID, the vendor element with a counter byte
  std::vector<uint8_t> gb;
  unhex("80000000ffffffffffff8c1ed90309c38c1ed90309c30000" "0000000000000000" "6400" "0000", gb);
  const char* ssid = "RID-1581FANLC258U029RTN6";
  gb.push_back(0); gb.push_back((uint8_t)strlen(ssid)); gb.insert(gb.end(), ssid, ssid + strlen(ssid));
  std::vector<uint8_t> vend;
  unhex("fa0bbc0d24ff2048fffffe3135383146414e4c433235385530323952544e363030303030303030000101d1823b483bf2eb11"
        "ed0769833b4822f0eb1105001c00284700c2083d0902000c050478acc5529e0103", vend);
  gb.push_back(0xDD); gb.push_back((uint8_t)vend.size()); gb.insert(gb.end(), vend.begin(), vend.end());
  memset(g_tracks, 0, sizeof g_tracks); Serial.out.clear();
  uint32_t pf = s_cnt_pfail;
  feed_frame(gb);
  t = by_mac(gb.data() + 10);
  CHECK(s_cnt_pfail == pf, "sniffer: a GB 46750 frame is not a parse failure");
  CHECK(t && !strcmp(t->uas, "1581FANLC258U029RTN6") && (t->fmt & 2), "sniffer: GB frame decodes to its serial and is marked GB");
  CHECK(t && t->has_pos && fabs(t->lat - 30.0675106) < 1e-6 && fabs(t->lon - 121.1859817) < 1e-6, "sniffer: GB aircraft position");
  CHECK(t && fabs(t->height - 108.0) < 0.01 && fabs(t->speed - 2.8) < 0.01 && t->status == 2, "sniffer: GB height, speed and status");
  CHECK(t && t->ssid_check == 1, "sniffer: GB SSID serial matches");
  CHECK(json_has("\"fmt\":\"gb46750\"") && json_has("\"op_lat\":30.0675643"), "sniffer: JSON says GB and carries the operator position");

  // A pack whose position is the DJI no-fix sentinel yields a track without a position.
  std::vector<uint8_t> nofix = dji;
  for (int i = 0; i < 8; i++) nofix[36 + 26 + 2 + 5 + 3 + 25 + 5 + i] = 0;   // Location lat/lon bytes
  memset(g_tracks, 0, sizeof g_tracks);
  feed_frame(nofix);
  t = by_mac(dji.data() + 10);
  CHECK(t && !t->has_pos, "sniffer: 0,0 is no position");
}

// The fixed-point JSON writer against printf, the duplicate filter, and the
// match log: contacts that end are recorded, survive a save and reload, and
// come back over log_get.
static void test_json_and_log(void) {
  bool same = true;
  const double vals[] = { 0, 1, -1, 37.8039, -122.464, 0.05, 123.456789, 1e-8, -0.0000001, 359.4, 99999.99 };
  for (double v : vals) for (int d = 0; d <= 7; d++) {
    char want[64]; snprintf(want, sizeof want, "%.*f", d, v);
    if (!strcmp(want, "-0") || !strncmp(want, "-0.", 3)) {       // printf keeps the sign of a value that rounds to 0
      bool zero = true; for (const char* c = want + 1; *c; c++) if (*c != '0' && *c != '.') zero = false;
      if (zero) memmove(want, want + 1, strlen(want));
    }
    jbegin(s_jb, JLINE_MAX); jfix(v, d); *s_jp = 0;
    if (strcmp(s_jb, want)) { printf("     jfix(%g, %d) = %s, printf %s\n", v, d, s_jb, want); same = false; }
  }
  CHECK(same, "json: fixed-point numbers match printf");
  jbegin(s_jb, JLINE_MAX); jfix(NAN, 2); *s_jp = 0;
  CHECK(!strcmp(s_jb, "null"), "json: a non-finite number is null, not nan");

  uint8_t pack[240];
  int n = build_signed(pack, false);
  memset(g_tracks, 0, sizeof g_tracks); Serial.out.clear();
  feed(SRC_WIFI_BEACON, M1, MSG(pack, 1), 25);
  feed(SRC_WIFI_BEACON, M1, MSG(pack, 1), 25);
  feed(SRC_WIFI_BEACON, M1, MSG(pack, 1), 25);
  CHECK(count_in(Serial.out, "\"type\":\"rid\"") == 1, "json: an unchanged frame repeated within a second is reported once");
  CHECK(by_mac(M1) && by_mac(M1)->msgs == 3, "json: ...but every repeat still updates the contact");
  s_rx_now += 1000;
  feed(SRC_WIFI_BEACON, M1, MSG(pack, 1), 25);
  CHECK(count_in(Serial.out, "\"type\":\"rid\"") == 2, "json: ...and again after a second");
  feed(SRC_WIFI_BEACON, M1, MSG(pack, 0), 25);
  CHECK(count_in(Serial.out, "\"type\":\"rid\"") == 3, "json: a different frame is reported at once");
  feed(SRC_BLE, M1, MSG(pack, 0), 25);
  CHECK(count_in(Serial.out, "\"type\":\"rid\"") == 4, "json: the same frame on another source is reported at once");
  CHECK(Serial.out.find("\"lat\":37.8000000") != std::string::npos && Serial.out.find("\"dir\":90,") != std::string::npos,
        "json: location fields keep their precision");
  (void)n;

  // Match log.
  log_clear();
  memset(g_tracks, 0, sizeof g_tracks); Serial.out.clear();
  Serial.in = "{\"cmd\":\"set_time\",\"utc\":1790000000}\n"; Serial.in_pos = 0;
  uint32_t set_ms = s_rx_now;
  rx_tick(s_rx_now);
  feed(SRC_WIFI_BEACON, M1, MSG(pack, 0), 25);    // Basic ID: ORECCHINO-TX-AUTH
  uint32_t first = s_rx_now;
  feed(SRC_WIFI_BEACON, M1, MSG(pack, 1), 25);    // Location
  s_rx_now += TRK_EXPIRE_MS + 10000;
  rx_tick(s_rx_now);
  CHECK(tracker_count() == 0 && s_log_n == 1, "log: an expired contact becomes a record");
  const LogRec* r = log_at(0);
  CHECK(!strcmp(r->uas, "ORECCHINO-TX-AUTH") && r->src_mask == 1 && r->lat_e5 == 3780000 && r->max_height == 60,
        "log: the record keeps ID, source, position and height");
  CHECK(r->first_utc == 1790000000 - set_ms / 1000 + first / 1000 && r->last_utc >= r->first_utc,
        "log: times are wall-clock once set_time has arrived");
  s_rx_now += LOG_SAVE_MS + 1;
  rx_tick(s_rx_now);                              // debounced save
  CHECK(!s_log_dirty, "log: saved to NVS after it settles");
  memset(s_log, 0, LOG_BYTES); s_log_n = 0; s_log_head = 0; s_log_total = 0;
  log_load();
  CHECK(s_log_n == 1 && !strcmp(log_at(0)->uas, "ORECCHINO-TX-AUTH"), "log: a reload restores it");

  // Evictions are recorded too: fill the table past TRK_MAX.
  for (int i = 0; i < TRK_MAX + 2; i++) {
    uint8_t m[6] = { 0x02, 0, 0, 0, 0x10, (uint8_t)i };
    bool c; tracker_upsert(m, nullptr, s_rx_now + i, &c);
  }
  CHECK(s_log_n == 3, "log: a contact evicted for room is recorded");

  Serial.out.clear();
  Serial.in = "{\"cmd\":\"log_get\"}\n"; Serial.in_pos = 0;
  rx_tick(s_rx_now);
  CHECK(count_in(Serial.out, "\"type\":\"log\"") == 3 + TRK_MAX && count_in(Serial.out, "\"active\":true") == TRK_MAX &&
        Serial.out.find("\"type\":\"log_done\",\"n\":3,\"live\":16") != std::string::npos,
        "log: log_get sends every record, the live contacts, then log_done");
  CHECK(count_in(Serial.out, "\"seq\":null") == TRK_MAX && json_has("\"next\":3,") && json_has("\"oldest\":0}"),
        "log: live contacts carry no seq, and next counts only ended records");
  CHECK(Serial.out.find("\"uas\":\"ORECCHINO-TX-AUTH\"") != std::string::npos && Serial.out.find("\"clock\":true") != std::string::npos,
        "log: records carry the ID, and log_done says the clock is set");
  { int held = 0; uint32_t age = 0; rx_log_stats(&held, &age);
    CHECK(held == 3 && age != UINT32_MAX, "log: a screen sees how many records there are and how old the oldest is"); }
  Serial.out.clear();
  Serial.in = "{\"cmd\":\"log_clear\"}\n"; Serial.in_pos = 0;
  rx_tick(s_rx_now);
  CHECK(s_log_n == 0 && count_in(Serial.out, "\"type\":\"log_cleared\"") == 1, "log: log_clear empties it and says so");
  CHECK(!s_log_dirty, "log: a clear is written to NVS at once, not at the next timed save");
  log_load();
  CHECK(s_log_n == 0 && s_log_total == 0, "log: after a reload the cleared log stays empty");
  // The screens' CLEAR HISTORY (T5 SYSTEM, T-Embed menu) is the same call.
  s_log_n = 1; s_log_dirty = true; Serial.out.clear();
  rx_log_clear_all();
  CHECK(s_log_n == 0 && !s_log_dirty && count_in(Serial.out, "log_cleared") == 1, "log: rx_log_clear_all clears, saves and broadcasts");
}

// ------------------------------------------------ host link: USB and BLE

static size_t tx_count_in(const char* needle) {
  size_t n = 0;
  for (auto& l : ble_link_test_get_tx()) n += count_in(l, needle);
  return n;
}
static void ble_cmd(const char* line) {
  ble_link_test_inject_rx(line, strlen(line));
}

static void test_host_link_and_ble(void) {
  // rx_begin (test_rx) registered the BLE sink; a second init -- the old
  // test did one -- must not register it twice and deliver every line twice.
  ble_link_init("host-test", RX_CAPS);
  CHECK(s_host_sink_count == 1, "ble: the sink is registered once however often init runs");
  ble_link_test_set_connected(true);
  ble_link_test_set_subscribed(true);
  ble_link_test_set_encrypted(true);
  ble_link_test_clear_tx();
  Serial.out.clear();

  // A received line is queued, not run on the BLE task: nothing happens
  // until the loop's rx_tick drains it.
  ble_cmd("{\"cmd\":\"feed\",\"on\":false}\n");
  CHECK(ble_link_test_get_tx().empty() && Serial.out.empty(), "ble: a received command waits for the loop");
  ble_link_poll(s_rx_now);
  CHECK(Serial.out.find("feed_status") == std::string::npos, "ble: BLE command reply does not leak to Serial");
  CHECK(ble_link_test_get_tx().size() == 1 && tx_count_in("\"feed_status\"") == 1 && tx_count_in("\"on\":false") == 1,
        "ble: exactly one feed_status reply, to BLE");

  // With the feed off, broadcasts of the feed go to Serial only.
  ble_link_test_clear_tx(); Serial.out.clear();
  host_printf("{\"type\":\"rid\",\"uas\":\"TEST-UAS\"}\n");
  host_printf("{\"type\":\"hb\",\"up\":1}\n");
  CHECK(count_in(Serial.out, "\"type\":\"rid\"") == 1 && count_in(Serial.out, "\"type\":\"hb\"") == 1,
        "feed: Serial receives rid and hb broadcasts");
  CHECK(ble_link_test_get_tx().empty(), "feed: BLE receives neither while its feed is off");

  // A BLE log_get answers BLE alone, while a frame decoded in the same pass
  // still goes out on Serial: the reply's destination is the command's, not
  // a global the decode path could read.
  ble_link_test_clear_tx(); Serial.out.clear();
  uint8_t pack[240]; build_signed(pack, false);
  ble_cmd("{\"cmd\":\"log_get\"}\n");
  feed(SRC_WIFI_BEACON, M3, MSG(pack, 1), 25);
  const auto& tx = ble_link_test_get_tx();
  CHECK(count_in(Serial.out, "\"type\":\"rid\"") == 1 && Serial.out.find("log_done") == std::string::npos,
        "route: the rid line reaches Serial, the log reply does not");
  CHECK(!tx.empty() && tx.back().find("\"type\":\"log_done\"") != std::string::npos && tx_count_in("log_done") == 1 &&
        tx_count_in("\"type\":\"rid\"") == 0, "route: BLE gets the log records then one log_done, and no rid");
  bool all_log = true;
  for (size_t i = 0; i + 1 < tx.size(); i++) if (tx[i].find("\"type\":\"log\"") == std::string::npos) all_log = false;
  CHECK(all_log, "route: every BLE line before log_done is a log record, in order, none twice");

  // Feed on: each rid broadcast reaches BLE exactly once.
  ble_cmd("{\"cmd\":\"feed\",\"on\":true}\n");
  ble_link_poll(s_rx_now);
  CHECK(host_get_feed(SRC_BLE_BONDED) == true, "feed: BLE feed is now on");
  ble_link_test_clear_tx();
  host_printf("{\"type\":\"rid\",\"uas\":\"TEST-UAS\"}\n");
  CHECK(ble_link_test_get_tx().size() == 1, "feed: BLE receives one rid broadcast when its feed is on");

  // A peer that cannot keep up loses feed lines, never replies or records.
  ble_link_test_clear_tx();
  ble_link_test_set_feed_room(1);
  uint32_t drops0 = ble_link_drops();
  host_printf("{\"type\":\"rid\",\"uas\":\"A\"}\n");
  host_printf("{\"type\":\"rid\",\"uas\":\"B\"}\n");
  ble_cmd("{\"cmd\":\"log_get\"}\n");
  ble_link_poll(s_rx_now);
  CHECK(tx_count_in("\"type\":\"rid\"") == 1 && ble_link_drops() == drops0 + 1, "ble: a full link drops the second rid line");
  CHECK(tx_count_in("log_done") == 1, "ble: ...but still delivers the log reply");
  ble_link_test_set_feed_room(SIZE_MAX);

  // Nothing reaches a link that is not encrypted; a disconnect forgets the feed.
  ble_link_test_clear_tx();
  ble_link_test_set_encrypted(false);
  host_printf("{\"type\":\"boot\",\"fw\":\"x\"}\n");
  host_printf("{\"type\":\"rid\",\"uas\":\"TEST-UAS\"}\n");
  CHECK(ble_link_test_get_tx().empty(), "ble: an unencrypted peer receives nothing");
  ble_link_test_set_connected(false);
  CHECK(!host_get_feed(SRC_BLE_BONDED), "ble: a disconnect turns the feed off for the next peer");
  ble_link_test_set_connected(true); ble_link_test_set_subscribed(true); ble_link_test_set_encrypted(true);
  host_printf("{\"type\":\"rid\",\"uas\":\"TEST-UAS\"}\n");
  CHECK(ble_link_test_get_tx().empty(), "ble: ...so a new peer gets no rid until it asks");

  // Location push over BLE updates home location
  ble_cmd("{\"cmd\":\"set_home\",\"lat\":37.7749,\"lon\":-122.4194,\"alt\":15.0,\"acc\":3.5,\"src\":\"ble\"}\n");
  ble_link_poll(s_rx_now);
  CHECK(fabs(g_home_lat - 37.7749) < 0.0001 && fabs(g_home_lon - (-122.4194)) < 0.0001,
        "home: location push updates coordinates");
  CHECK(fabs(g_home_acc - 3.5f) < 0.01f && !strcmp(g_home_src, "ble"),
        "home: accuracy and source set");

  // Channel hop hold
  rx_hop_hold(true);
  CHECK(rx_hop_is_held(), "hop: channel hop held when set");
  rx_hop_hold(false);
  CHECK(!rx_hop_is_held(), "hop: channel hop hold cleared");
  ble_link_test_set_connected(false);
}

// ------------------------------------------------ what a host may not do

static void serial_cmd(const char* line) {
  Serial.in = line; Serial.in_pos = 0;
  rx_tick(s_rx_now);
}

static void test_host_input_limits(void) {
  // host_printf: a line longer than its buffer is dropped whole (it used to
  // be sent with vsnprintf's wanted length: a read past the buffer).
  Serial.out.clear();
  std::string big(3000, 'x');
  host_printf("{\"type\":\"x\",\"s\":\"%s\"}\n", big.c_str());
  CHECK(Serial.out.empty(), "limits: an over-long host_printf line is dropped, not over-read");

  // set_time: 0, negative, before 2024, past uint32, NaN all refused.
  uint32_t before = s_utc_at_boot;
  const char* bad_times[] = { "0", "-5", "1000000", "1e20", "nan" };
  for (const char* v : bad_times) {
    char l[80]; snprintf(l, sizeof l, "{\"cmd\":\"set_time\",\"utc\":%s}\n", v);
    serial_cmd(l);
  }
  CHECK(s_utc_at_boot == before, "limits: set_time refuses 0, negative, pre-2024, huge and NaN");
  serial_cmd("{\"cmd\":\"set_time\",\"utc\":1790000000}\n");
  CHECK(log_utc(s_rx_now) == 1790000000, "limits: ...and takes a real time");

  // set_home: out of range or NaN leaves home alone.
  double lat0 = g_home_lat, lon0 = g_home_lon;
  serial_cmd("{\"cmd\":\"set_home\",\"lat\":91,\"lon\":10}\n");
  serial_cmd("{\"cmd\":\"set_home\",\"lat\":nan,\"lon\":10}\n");
  serial_cmd("{\"cmd\":\"set_home\",\"lat\":10,\"lon\":-181}\n");
  serial_cmd("{\"cmd\":\"set_home\",\"lat\":10}\n");
  CHECK(g_home_lat == lat0 && g_home_lon == lon0, "limits: set_home ignores NaN, out-of-range and half positions");

  // log_get: a cursor past 2^32 is clamped, not undefined behaviour.
  Serial.out.clear();
  serial_cmd("{\"cmd\":\"log_get\",\"since\":1e30,\"after_utc\":-4}\n");
  CHECK(json_has("\"type\":\"log_done\""), "limits: log_get with an absurd cursor still answers");

  // Tile paths: only /tiles/<z>/<x>/<y>.png may be written.
  CHECK(tile_path_ok("/tiles/14/2620/6332.png") && tile_path_ok("/tiles/0/0/0.png") &&
        tile_path_ok("/tiles/14/2620/6332.jpg"), "tiles: z/x/y.png and .jpg accepted");
  const char* bad_paths[] = { "/tiles/../log/x", "/tiles/14/2620/../../x.png", "/tiles/14/2620/6332.png.bak",
                              "/tiles/123/1/1.png", "/tilesX/1/1/1.png", "/tiles/1/1/1.png/", "/tiles/a/1/1.png",
                              "/tiles/1/1/.png", "tiles/1/1/1.png", "/log/records.bin", "/tiles/1/1/1.jpeg",
                              "/tiles/1/1/1.l.png", "/tiles/.src", "" };
  bool none = true;
  for (const char* p : bad_paths) if (tile_path_ok(p)) { printf("     accepted %s\n", p); none = false; }
  CHECK(none, "tiles: traversal, extra suffixes and non-digits refused for writing");
  CHECK(tile_rm_path_ok("/tiles/14/2620/6332.png") && tile_rm_path_ok("/tiles/.DS_Store"),
        "tiles: a stray file inside /tiles may be removed");
  CHECK(!tile_rm_path_ok("/tiles/../log/records.bin") && !tile_rm_path_ok("/tiles/14/../../x") &&
        !tile_rm_path_ok("/tiles//x") && !tile_rm_path_ok("/tiles/") && !tile_rm_path_ok("/tiles/a b") &&
        !tile_rm_path_ok("/tiles/14/.."), "tiles: ...but nothing that climbs out");
  CHECK(tile_bytes_needed(20000, 6u << 20) == 20000 + TILE_FS_MARGIN, "tiles: a tile needs its size plus the margin");
  CHECK(tile_bytes_needed(0, 6u << 20) == 0 && tile_bytes_needed(TILE_FILE_MAX + 1, 6u << 20) == 0 &&
        tile_bytes_needed(UINT32_MAX, 6u << 20) == 0 && tile_bytes_needed(200000, 100000) == 0,
        "tiles: empty, huge, 4 GB and larger-than-the-disk files refused (no wrap, no evict-all)");
}

// ------------------------------------------------ timestamps across tasks

static void test_wrap(void) {
  // The decode task stamps with its own millis(), which can be newer than
  // the `now` the loop read at the top of its pass.
  memset(g_tracks, 0, sizeof g_tracks);
  bool c;
  tracker_upsert(M1, "W", 50000, &c);
  CHECK(tracker_expire(49990) == 0 && tracker_count() == 1, "wrap: a contact stamped after the loop's now is not expired");
  CHECK(tracker_expire(50000 + TRK_EXPIRE_MS + 1) == 1, "wrap: ...and still expires on time");
  Track t; memset(&t, 0, sizeof t); t.used = true; t.last_ms = 70000;
  CHECK(!ui_stale(&t, 69990) && ui_stale(&t, 70000 + UI_ACTIVE_MS + 1), "wrap: ui_stale is not fooled either");
  bool dirty = s_log_dirty; uint32_t dms = s_log_dirty_ms;
  s_log_dirty = true; s_log_dirty_ms = 80000;
  CHECK(!log_due(79990) && log_due(80000 + LOG_SAVE_MS), "wrap: a log save stamped after now is not overdue");
  s_log_dirty = dirty; s_log_dirty_ms = dms;
}

// ------------------------------------------------ match log sync protocol

static void end_contact(const uint8_t* mac, const char* id) {
  bool c;
  RX_LOCK();
  Track* t = tracker_upsert(mac, id, s_rx_now, &c);
  trk_on_end(t);
  t->used = false;
  RX_UNLOCK();
}
static std::string log_get(const char* args) {
  Serial.out.clear();
  char l[128]; snprintf(l, sizeof l, "{\"cmd\":\"log_get\"%s}\n", args);
  serial_cmd(l);
  return Serial.out;
}

static void test_log_sync(void) {
  log_clear();
  memset(g_tracks, 0, sizeof g_tracks);
  serial_cmd("{\"cmd\":\"set_time\",\"utc\":1790000000}\n");
  end_contact(M1, "SEQ-0");
  end_contact(M2, "SEQ-1");
  s_rx_now += 100000;
  end_contact(M3, "SEQ-2");
  bool c; tracker_upsert(M1, "LIVE", s_rx_now, &c);   // one contact still in the table

  std::string o = log_get("");
  CHECK(json_has("\"seq\":0,") && json_has("\"seq\":1,") && json_has("\"seq\":2,") && count_in(o, "\"seq\":null") == 1,
        "sync: ended records are numbered 0..2, the live contact is not");
  CHECK(json_has("\"total\":3,") && json_has("\"next\":3,") && json_has("\"oldest\":0}") && json_has("\"live\":1,"),
        "sync: log_done says next = total = 3 (live not counted), oldest 0");

  o = log_get(",\"since\":2");
  CHECK(count_in(o, "\"type\":\"log\"") == 2 && json_has("\"uas\":\"SEQ-2\"") && json_has("\"uas\":\"LIVE\"") &&
        !json_has("SEQ-1"), "sync: since=2 sends record 2 and the live contact");
  o = log_get(",\"since\":3");
  CHECK(count_in(o, "\"type\":\"log\"") == 1 && json_has("\"uas\":\"LIVE\""), "sync: since=next sends only what is live");

  // The live contact ends: the client's cursor (3) picks up its final record.
  RX_LOCK();
  for (int i = 0; i < TRK_MAX; i++) if (g_trk_live[i].used) { trk_on_end(&g_trk_live[i]); g_trk_live[i].used = false; }
  RX_UNLOCK();
  o = log_get(",\"since\":3");
  CHECK(count_in(o, "\"type\":\"log\"") == 1 && json_has("\"seq\":3,") && json_has("\"uas\":\"LIVE\"") &&
        json_has("\"next\":4,"), "sync: once it ends, the next sync gets it with seq 3");

  // after_utc: only records last heard at or after that second.
  uint32_t cut = log_at(2)->last_utc;
  o = log_get((",\"after_utc\":" + std::to_string(cut)).c_str());
  CHECK(!json_has("SEQ-0") && !json_has("SEQ-1") && json_has("SEQ-2") && json_has("\"uas\":\"LIVE\""),
        "sync: after_utc drops records heard before it");

  // More than the ring holds: oldest moves up with the rotation.
  for (int i = 0; i < LOG_MAX; i++) { uint8_t m[6] = {2, 0, 0, 0, 0x20, (uint8_t)i}; end_contact(m, nullptr); }
  o = log_get(",\"since\":0");
  char want[48]; snprintf(want, sizeof want, "\"oldest\":%u}", (unsigned)(s_log_total - LOG_MAX));
  CHECK(json_has(want) && count_in(o, "\"type\":\"log\"") == LOG_MAX, "sync: oldest = total - LOG_MAX once the ring has rotated");

  // An explicit flush saves at once (power-off, mode switch).
  end_contact(M2, "FLUSH");
  CHECK(s_log_dirty, "flush: a new record is pending");
  rx_log_flush();
  memset(s_log, 0, LOG_BYTES); s_log_n = 0; s_log_head = 0; s_log_total = 0;
  log_load();
  CHECK(!s_log_dirty && s_log_n == LOG_MAX && !strcmp(log_at(LOG_MAX - 1)->uas, "FLUSH"), "flush: rx_log_flush writes it to NVS");

  // v1 migration: numbers follow history order, not ring slots.
  {
    std::vector<LogRecV1> v1(LOG_MAX);
    memset(v1.data(), 0, sizeof(LogRecV1) * LOG_MAX);
    const int head = 5, n = 10; const uint32_t total = 100;
    for (int k = 0; k < n; k++) snprintf(v1[(head - n + k + LOG_MAX) % LOG_MAX].uas, 24, "V1-%d", k);
    Preferences p; p.begin("orlog", false);
    p.putUChar("ver", 1); p.putBytes("recs", v1.data(), sizeof(LogRecV1) * LOG_MAX);
    p.putUChar("head", head); p.putUChar("n", n); p.putULong("total", total); p.end();
    log_load();
    bool ok = s_log_n == n && s_log_total == total;
    for (int k = 0; k < n && ok; k++) {
      char id[8]; snprintf(id, sizeof id, "V1-%d", k);
      if (log_at(k)->seq != total - n + (uint32_t)k || strcmp(log_at(k)->uas, id)) ok = false;
    }
    CHECK(ok, "log: v1 records migrate with seq = total - n + k, oldest first");
  }
  log_clear();
  s_rx_now += LOG_SAVE_MS + 1;
  rx_tick(s_rx_now);   // the clear reaches NVS
}

// ------------------------------------------------ encoder limits, IDs, keys

static void test_odid_extras(void) {
  OdidTxState st; memset(&st, 0, sizeof st);
  st.uas_id = "X"; st.proto_ver = 2; st.lat = 37.8; st.lon = -122.4; st.alt_geo_m = 100; st.height_m = 50;
  uint8_t m[25]; OdidUas u;
  st.vspeed_ms = 70;
  odid_build_location(m, &st);
  memset(&u, 0, sizeof u); odid_decode_msg(m, &u);
  bool up = fabsf(u.vspeed - 62.0f) < 0.01f;
  st.vspeed_ms = -70;
  odid_build_location(m, &st);
  memset(&u, 0, sizeof u); odid_decode_msg(m, &u);
  CHECK(up && fabsf(u.vspeed + 62.0f) < 0.01f, "odid: vertical speed beyond 62 m/s is clamped, not wrapped");
  CHECK((m[20] >> 4) == 0, "odid: baro accuracy unknown while baro altitude is");

  // Wall-clock timestamps once the clock is set.
  s_tx_test_utc = 1790000000;
  uint8_t out[240];
  int n = build_payload(P_AUTH, out, 5000);
  memset(&u, 0, sizeof u);
  bool dec = odid_decode_payload(out, n, &u);
  CHECK(dec && u.has_sys && u.sys_ts == 1790000000u - 1546300800u, "tx: System timestamp is wall-clock seconds since 2019");
  CHECK(dec && u.auth_ts == 1790000000u - 1546300800u && odid_verify_auth(&u) == ODID_AUTH_TEST_KEY,
        "tx: ...and so is the signed Authentication timestamp, which still verifies");
  s_tx_test_utc = 0;

  // Specific Session ID (type 4) is binary: hex, all 20 bytes.
  memset(m, 0, sizeof m);
  m[0] = 0x02; m[1] = (4 << 4) | 2;
  for (int i = 0; i < 20; i++) m[2 + i] = (uint8_t)(i == 3 ? 0 : 0xA0 + i);
  memset(&u, 0, sizeof u); odid_decode_msg(m, &u);
  CHECK(strlen(u.uas_id[0]) == 40 && !strncmp(u.uas_id[0], "a0a1a200a4", 10), "odid: session ID decodes to 40 hex digits, NUL and all");

  CHECK(!strcmp(odid_auth_state_name(ODID_AUTH_TEST_KEY), "test_key") && !strcmp(track_auth_badge(ODID_AUTH_TEST_KEY), "TEST") &&
        strstr(ui_auth_text(ODID_AUTH_TEST_KEY), "TEST KEY") && ui_auth_color(ODID_AUTH_TEST_KEY) == C_MUTED,
        "auth: the test key has its own neutral name, badge and colour");
}

// Home survives a reboot; NVS is written on the first fix and after a move
// of more than 500 m, at most every 10 minutes.
static void test_home_persist(void) {
  shim_nvs().erase("orhome/lat"); shim_nvs().erase("orhome/lon");
  s_home_saved_lat = NAN; s_home_saved_lon = NAN; s_home_saved_recent = false;
  g_millis = 1000000;
  rx_set_home(37.80, -122.46, "app");
  Preferences p; p.begin("orhome", true);
  CHECK(p.getDouble("lat", 0) == 37.80 && p.getDouble("lon", 0) == -122.46, "home: the first fix is saved");
  rx_set_home(37.801, -122.46, "gps");                       // ~110 m away
  CHECK(p.getDouble("lat", 0) == 37.80, "home: a move under 500 m is not written");
  g_millis += 60000; rx_set_home(37.81, -122.46, "gps");     // ~1.1 km, a minute later
  CHECK(p.getDouble("lat", 0) == 37.80, "home: a big move within 10 minutes waits");
  g_millis += 600000; rx_set_home(37.81, -122.46, "gps");
  CHECK(p.getDouble("lat", 0) == 37.81, "home: a big move after 10 minutes is written");
  g_home_set = false; g_home_lat = g_home_lon = 0;
  home_load();
  CHECK(g_home_set && g_home_lat == 37.81 && g_home_lon == -122.46 && strcmp(g_home_src, "saved") == 0,
        "home: a reboot restores the saved home, marked saved");
  rx_set_home(37.811, 179.9999, "gps"); rx_set_home(37.811, -179.9999, "gps");
  CHECK(g_home_lon == -179.9999, "home: the antimeridian is not a 36,000 km move");
}

int main(void) {
  test_tracker();
  test_tx();
  test_rx();
  test_sniffer();
  test_json_and_log();
  test_host_link_and_ble();
  test_host_input_limits();
  test_wrap();
  test_log_sync();
  test_odid_extras();
  test_home_persist();
  if (g_fails) printf("%d FAILED\n", g_fails); else printf("all core checks passed\n");
  return g_fails ? 1 : 0;
}
