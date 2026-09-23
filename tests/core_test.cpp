// Host-side tests for the shared radio cores, built against the shims in
// tests/host_shim. They pin the state transitions the unit tests in
// odid_test.c cannot reach: one aircraft staying one contact across several
// addresses, Authentication pages assembled across frames, the transmitter's
// format fields reaching the encoder, and its off switches actually
// silencing the BLE advertising sets.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
#define FW_BOARD "host"
#include "Arduino.h"
#include "tx_core.h"
#include "rx_core.h"
#include "odid_build.h"
#include "odid_auth.h"

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

static void run_ticks(int n) { for (int k = 0; k < n; k++) { g_millis += 7; tx_tick(g_millis); } }

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
  int fl = build_beacon(P_DUAL, out, n, 0);
  CHECK(fl > 0 && !memcmp(s_frame + 10, PATHS[P_DUAL].mac, 6) && !memcmp(s_frame + 16, PATHS[P_DUAL].mac, 6),
        "tx: beacon SA/BSSID use the path's own MAC");
  n = build_payload(P_AUTH, out, 5000);
  CHECK(odid_decode_payload(out, n, &u) && odid_verify_auth(&u) == ODID_AUTH_ID_VALID, "tx: P_AUTH pack verifies id_valid");
  n = build_payload(P_AUTHBAD, out, 5000);
  CHECK(odid_decode_payload(out, n, &u) && odid_verify_auth(&u) == ODID_AUTH_INVALID, "tx: P_AUTHBAD pack verifies invalid");

  tx_begin();
  for (int i = 0; i < P_COUNT; i++) tx_set_enabled(i, i == P_BLE4);
  NimBLEDevice::adv.starts.clear();
  g_millis = 10000;
  run_ticks(60000 / 7);
  bool seen[6] = {false}; int nb = 0;
  for (auto& r : NimBLEDevice::adv.starts)
    if (r.adv.data.size() > 6) { seen[(r.adv.data[6] >> 4) % 6] = true; nb++; }
  const int per60 = 60000 / TX_PERIOD_MS;
  CHECK(nb >= per60 - 1 && nb <= per60 + 1, "tx: BLE4 sent one advertisement per TX_PERIOD_MS over 60 s");
  CHECK(seen[0] && seen[1] && seen[3] && seen[4] && seen[5], "tx: BLE4 rotated through Basic/Location/Self/System/Operator");

  for (int i = 0; i < P_COUNT; i++) tx_set_enabled(i, true);
  uint32_t sent0[P_COUNT]; memcpy(sent0, s_tx, sizeof sent0);
  size_t start0 = NimBLEDevice::adv.starts.size();
  run_ticks(60000 / 7);
  bool every_5s = true;
  for (int i = 0; i < P_COUNT; i++) {
    uint32_t d = s_tx[i] - sent0[i];
    if (i == P_NAN) d /= 2;   // each NAN transmission is a sync beacon plus the SDF
    if ((int)d < 60000 / TX_PERIOD_MS - 1 || (int)d > 60000 / TX_PERIOD_MS + 1) every_5s = false;
  }
  CHECK(every_5s && TX_PERIOD_MS == 5000, "tx: with every path on, each transmits once every TX_PERIOD_MS (5 s)");
  // Set 1 carries coded and legacy in turn; each must keep it long enough to
  // go out (on air, BLE4 retaking the set 2 ms after BLELR meant BLELR was
  // never heard).
  uint32_t shortest = UINT32_MAX;
  for (size_t i = start0 + 1; i < NimBLEDevice::adv.starts.size(); i++) {
    const AdvStartRec& a = NimBLEDevice::adv.starts[i];
    if (a.inst != 1) continue;
    for (size_t j = i; j-- > start0;) {
      const AdvStartRec& p = NimBLEDevice::adv.starts[j];
      if (p.inst != 1) continue;
      if (p.adv.pri != a.adv.pri || p.adv.legacy != a.adv.legacy) shortest = std::min(shortest, a.at - p.at);
      break;
    }
  }
  CHECK(shortest != UINT32_MAX && shortest >= TX_PERIOD_MS / 2 - 50,
        "tx: coded and legacy each hold the shared set for half a period");
  run_ticks(400);
  CHECK(NimBLEDevice::adv.active[0] && NimBLEDevice::adv.active[1], "tx: both advertising sets active while running");
  tx_set_running(false);
  CHECK(!NimBLEDevice::adv.isAdvertising(), "tx: tx_set_running(false) stops both sets");
  size_t wifi_before = g_wifi_tx.size();
  run_ticks(400);
  CHECK(g_wifi_tx.size() == wifi_before && !NimBLEDevice::adv.isAdvertising(), "tx: nothing radiates while paused");
  tx_set_running(true);
  run_ticks(400);
  CHECK(NimBLEDevice::adv.active[0] && NimBLEDevice::adv.active[1], "tx: sets active again after resume");
  tx_set_enabled(P_BLE5, false);
  CHECK(!NimBLEDevice::adv.active[0], "tx: disabling BLE5 stops set 0");
  run_ticks(400);
  CHECK(!NimBLEDevice::adv.active[0] && NimBLEDevice::adv.active[1], "tx: set 0 stays down, set 1 keeps serving coded/legacy");
  tx_set_enabled(P_BLELR, false);
  run_ticks(400);
  CHECK(NimBLEDevice::adv.active[1], "tx: set 1 still serves BLE4 after BLELR off");
  tx_set_enabled(P_BLE4, false);
  CHECK(!NimBLEDevice::adv.active[1], "tx: disabling the last set-1 path stops set 1");
  run_ticks(400);
  CHECK(!NimBLEDevice::adv.isAdvertising(), "tx: no BLE advertising with all BLE paths off");
  for (int i = 0; i < P_COUNT; i++) tx_set_enabled(i, false);
  wifi_before = g_wifi_tx.size();
  run_ticks(400);
  CHECK(g_wifi_tx.size() == wifi_before, "tx: ALL OFF sends no Wi-Fi frames");
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
  uint8_t pack[240];
  int n = build_signed(pack, false);
  memset(g_tracks, 0, sizeof g_tracks); Serial.out.clear();
  feed(SRC_WIFI_BEACON, M1, pack, n);
  CHECK(by_mac(M1) && by_mac(M1)->auth_state == ODID_AUTH_ID_VALID, "rx: signed pack in one frame -> id_valid");
  CHECK(count_in(Serial.out, "\"state\":\"id_valid\"") == 1, "rx: JSON reports id_valid for the pack");

  memset(g_tracks, 0, sizeof g_tracks); Serial.out.clear();
  uint32_t pf = s_cnt_pfail;
  feed(SRC_BLE, M2, MSG(pack, 0), 25);                              // Basic ID alone
  for (int pg = 0; pg < 4; pg++) feed(SRC_BLE, M2, MSG(pack, 5 + pg), 25);  // one page per frame
  CHECK(s_cnt_pfail == pf, "rx: auth-only frames decode instead of counting as parse failures");
  CHECK(by_mac(M2) && by_mac(M2)->auth_state == ODID_AUTH_ID_VALID, "rx: Basic ID + four single-message pages -> id_valid");
  CHECK(count_in(Serial.out, "\"state\":\"partial\"") == 3 && count_in(Serial.out, "\"state\":\"id_valid\"") == 1,
        "rx: JSON says partial three times, then id_valid");
  feed(SRC_BLE, M2, MSG(pack, 1), 25);                              // Location alone
  CHECK(by_mac(M2)->auth_state == ODID_AUTH_ID_VALID, "rx: a later Location frame keeps the verdict");
  CHECK(count_in(Serial.out, "\"state\":\"id_valid\"") == 2, "rx: ...and its JSON line still carries it");

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
  CHECK(by_mac(M2)->auth_state == ODID_AUTH_ID_VALID, "rx: first set verifies");
  uint8_t pack2[240]; build_signed(pack2, true, 200);            // second set: corrupted, page 0 last
  for (int pg = 1; pg < 4; pg++) feed(SRC_BLE, M2, MSG(pack2, 5 + pg), 25);
  CHECK(by_mac(M2)->auth_state == ODID_AUTH_ID_VALID, "rx: the old verdict holds while the new set is incomplete");
  Serial.out.clear();
  feed(SRC_BLE, M2, MSG(pack2, 5), 25);
  CHECK(by_mac(M2)->auth_state == ODID_AUTH_INVALID && count_in(Serial.out, "\"state\":\"invalid\"") == 1, "rx: the late page 0 completes the new set, which fails as it should");
  uint8_t pack3[240]; build_signed(pack3, false, 300);            // third set: good again, page 0 last
  for (int pg = 1; pg < 4; pg++) feed(SRC_BLE, M2, MSG(pack3, 5 + pg), 25);
  feed(SRC_BLE, M2, MSG(pack3, 5), 25);
  CHECK(by_mac(M2)->auth_state == ODID_AUTH_ID_VALID, "rx: and a good set after a bad one clears it");

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
    jbegin(s_jb, sizeof s_jb); jfix(v, d); *s_jp = 0;
    if (strcmp(s_jb, want)) { printf("     jfix(%g, %d) = %s, printf %s\n", v, d, s_jb, want); same = false; }
  }
  CHECK(same, "json: fixed-point numbers match printf");
  jbegin(s_jb, sizeof s_jb); jfix(NAN, 2); *s_jp = 0;
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
  memset(s_log, 0, sizeof s_log); s_log_n = 0; s_log_head = 0; s_log_total = 0;
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
  CHECK(Serial.out.find("\"uas\":\"ORECCHINO-TX-AUTH\"") != std::string::npos && Serial.out.find("\"clock\":true") != std::string::npos,
        "log: records carry the ID, and log_done says the clock is set");
  Serial.out.clear();
  Serial.in = "{\"cmd\":\"log_clear\"}\n"; Serial.in_pos = 0;
  rx_tick(s_rx_now);
  CHECK(s_log_n == 0 && Serial.out.find("log_cleared") != std::string::npos, "log: log_clear empties it and says so");
}

int main(void) {
  test_tracker();
  test_tx();
  test_rx();
  test_sniffer();
  test_json_and_log();
  if (g_fails) printf("%d FAILED\n", g_fails); else printf("all core checks passed\n");
  return g_fails ? 1 : 0;
}
