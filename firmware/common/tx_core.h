// Orecchino test-beacon core — a Remote ID transmitter for bench-testing
// receivers. One engine for every board: ten aircraft across five air
// interfaces and five format variants, each its own contact so a receiver's
// list is a capability report; real Ed25519 Authentication with a published
// test key (and one deliberately corrupted signature). A board sketch
// includes this header and calls tx_begin() / tx_tick(); a UI drives the
// per-path enable mask through the tx_* accessors at the end.
//
// This is test equipment. It is not a compliant Remote ID transmitter, its
// identities say so on the air, and it must only be run where you are
// allowed to radiate on 2.4 GHz for testing.
#pragma once
#include <Arduino.h>
#include <WiFi.h>
#include <NimBLEDevice.h>
#include "esp_wifi.h"
#include "odid_build.h"
#include "odid_auth.h"

#define TX_NAME      "orecchino-tx"
#define TX_VERSION   "0.3.0"
#define WIFI_CHANNEL 6      // Open Drone ID default / NAN social channel
#define BEACON_MS    300    // WiFi beacon, ~3 Hz
#define NAN_MS       400    // WiFi NAN SDF
#define BLE_MS       500    // per BLE instance
#define ORBIT_M      50.0   // each aircraft's own little circle

// ---------------------------------------------------------------- paths

// Five transports plus four format variants. Every variant is its own
// aircraft, so a receiver's contact list is a capability report: whatever
// is missing names the thing that receiver cannot decode. The format
// variants all ride the WiFi beacon, the most reliable transport, so the
// format is the only thing under test.
enum TxPathId {
  P_WIFI = 0, P_NAN, P_BLE5, P_BLELR, P_BLE4,   // transports
  P_V0, P_SINGLE, P_DUAL, P_AUTH, P_AUTHBAD,    // formats (WiFi beacon)
  P_COUNT
};

enum TxCarrier { C_BEACON = 0, C_NAN, C_BLE_EXT, C_BLE_CODED, C_BLE_LEGACY };
enum TxFormat  { F_PACK = 0, F_SINGLE };

typedef struct {
  const char* uas_id;
  const char* self_desc;
  const char* op_id;
  uint8_t     carrier;      // TxCarrier
  uint8_t     format;       // TxFormat
  uint8_t     proto_ver;    // 0 = F3411-19, 2 = F3411-22
  const char* caa_id;       // non-null adds a second Basic ID
  bool        with_auth;    // append paginated Authentication messages
  double      bearing_deg;  // where this aircraft's orbit centre sits
  double      alt_m;
  uint8_t     mac[6];       // WiFi SA / BLE advertising address
} TxPath;

// UAS IDs must be <= 20 characters: the ODID Basic ID field is 20
// bytes and the encoder truncates silently.
static const TxPath PATHS[P_COUNT] = {
  // --- transports, all v2 message packs
  { "ORECCHINO-TX-WIFI",  "TEST path=WIFI-BEACON", "TEST-OP-WIFI",
    C_BEACON, F_PACK, 2, nullptr, false,
    0.0,   60.0,  {0x02, 0x00, 0x5E, 0x7E, 0x57, 0x01} },
  { "ORECCHINO-TX-NAN",   "TEST path=WIFI-NAN",    "TEST-OP-NAN",
    C_NAN, F_PACK, 2, nullptr, false,
    40.0,  75.0,  {0x02, 0x00, 0x5E, 0x7E, 0x57, 0x02} },
  { "ORECCHINO-TX-BLE5",  "TEST path=BLE5-1M",     "TEST-OP-BLE5",
    C_BLE_EXT, F_PACK, 2, nullptr, false,
    80.0,  90.0,  {0x02, 0x00, 0x5E, 0x7E, 0x57, 0x03} },
  { "ORECCHINO-TX-BLELR", "TEST path=BLE5-CODED",  "TEST-OP-BLELR",
    C_BLE_CODED, F_PACK, 2, nullptr, false,
    120.0, 105.0, {0x02, 0x00, 0x5E, 0x7E, 0x57, 0x04} },
  { "ORECCHINO-TX-BLE4",  "TEST path=BLE4-LEGACY", "TEST-OP-BLE4",
    C_BLE_LEGACY, F_SINGLE, 2, nullptr, false,
    160.0, 120.0, {0x02, 0x00, 0x5E, 0x7E, 0x57, 0x05} },

  // --- format variants on the WiFi beacon
  // F3411-19 (protocol version 0): receivers that hardcode v2 miss this.
  { "ORECCHINO-TX-V0",    "TEST fmt=F3411-19-v0",  "TEST-OP-V0",
    C_BEACON, F_PACK, 0, nullptr, false,
    200.0, 135.0, {0x02, 0x00, 0x5E, 0x7E, 0x57, 0x06} },
  // One 25-byte message per frame instead of a pack — receivers that only
  // parse message packs miss this.
  { "ORECCHINO-TX-SINGLE","TEST fmt=SINGLE-MSG",   "TEST-OP-SINGLE",
    C_BEACON, F_SINGLE, 2, nullptr, false,
    240.0, 150.0, {0x02, 0x00, 0x5E, 0x7E, 0x57, 0x07} },
  // Two Basic IDs: serial plus CAA registration.
  { "ORECCHINO-TX-DUAL",  "TEST fmt=DUAL-BASIC-ID","TEST-OP-DUAL",
    C_BEACON, F_PACK, 2, "CAA-REG-TEST-0001", false,
    280.0, 165.0, {0x02, 0x00, 0x5E, 0x7E, 0x57, 0x08} },
  // Paginated Authentication messages in the pack — the message most
  // transmitters skip and most receivers have never been fed.
  { "ORECCHINO-TX-AUTH",  "TEST fmt=AUTH-SIGNED",  "TEST-OP-AUTH",
    C_BEACON, F_PACK, 2, nullptr, true,
    280.0, 180.0, {0x02, 0x00, 0x5E, 0x7E, 0x57, 0x09} },
  // Same, but the signature is deliberately corrupted — a receiver that
  // verifies signatures should reject this one and accept the other. If it
  // shows both as equally valid, it is not really checking.
  { "ORECCHINO-TX-AUTHBAD", "TEST fmt=AUTH-BADSIG","TEST-OP-AUTHBAD",
    C_BEACON, F_PACK, 2, nullptr, true,
    320.0, 195.0, {0x02, 0x00, 0x5E, 0x7E, 0x57, 0x0A} },
};

// Flight sim defaults: Crissy Field.
static double s_home_lat = 37.8039;
static double s_home_lon = -122.4640;
static double s_ring_m   = 201.0;   // 1/8 mile between the aircraft
static double s_speed_ms = 8.0;

static bool s_running   = true;
static bool s_enabled[P_COUNT] = { true, true, true, true, true, true, true, true, true, true };
static bool s_emergency = false;
static uint8_t  s_counter[P_COUNT] = {0};
static uint32_t s_tx[P_COUNT] = {0};

// ------------------------------------------------------------ flight model

static void current_state(OdidTxState* s, uint32_t now_ms, int pid) {
  const TxPath* p = &PATHS[pid];
  double omega = s_speed_ms / ORBIT_M;
  double ang = fmod(now_ms / 1000.0 * omega, 2 * M_PI);

  double m_lat = 111111.0;
  double m_lon = m_lat * cos(s_home_lat * M_PI / 180.0);
  double br = p->bearing_deg * M_PI / 180.0;
  // Orbit centre: out along the separation ring, then the small circle.
  double cx = s_ring_m * sin(br), cy = s_ring_m * cos(br);

  memset(s, 0, sizeof(*s));
  s->uas_id    = p->uas_id;
  s->ua_type   = 2;                                  // multirotor
  s->status    = s_emergency ? 3 : 2;                // emergency / airborne
  s->lat       = s_home_lat + (cy + ORBIT_M * sin(ang)) / m_lat;
  s->lon       = s_home_lon + (cx + ORBIT_M * cos(ang)) / m_lon;
  s->alt_geo_m = (float)(p->alt_m + 22.0);           // ~geoid offset here
  s->height_m  = (float)p->alt_m;
  s->speed_ms  = (float)s_speed_ms;
  s->vspeed_ms = (float)(0.5 * sin(ang * 2));
  s->dir_deg   = (float)fmod(360.0 + 90.0 - ang * 180.0 / M_PI, 360.0);
  s->ts_s      = (float)fmod(now_ms / 1000.0, 3600.0);
  s->self_desc = p->self_desc;
  s->op_lat    = s_home_lat;
  s->op_lon    = s_home_lon;
  s->op_alt_m  = 12.0f;
  s->op_id     = p->op_id;
}

// The Authentication variants carry a real Ed25519 signature over the
// Basic ID message plus the page-0 timestamp, made with a published test
// key (see odid_auth.h). AUTHBAD corrupts it on purpose.

// Build the ODID payload this path transmits: a message pack, optionally
// with Authentication pages appended, or a single rotating message.
static int build_payload(int pid, uint8_t* out, uint32_t now) {
  const TxPath* p = &PATHS[pid];
  OdidTxState s;
  current_state(&s, now, pid);

  if (p->format == F_SINGLE) {
    // Rotate through the message types, one per transmission.
    return odid_build_single(out, &s, now / 1000, (int)(now / 400));
  }

  int n = odid_build_pack(out, &s, now / 1000);
  if (p->with_auth) {
    uint32_t ts = now / 1000;
    uint8_t sig[64];
    odid_auth_sign(sig, out + 3, ts);          // out+3 is the Basic ID msg
    if (pid == P_AUTHBAD) sig[0] ^= 0xFF;      // break it on purpose
    int count = out[2];
    int pages = odid_auth_pages((int)sizeof(sig));
    // All pages or none: page 0 advertises LastPageIndex, so a truncated
    // set promises pages that never arrive and can never verify.
    if (count + pages > ODID_PACK_MAX_MESSAGES) {
      // A path configured with both caa_id and with_auth lands here —
      // say so, in keeping with this tool never failing silently.
      static uint32_t last_note = 0;
      if (now - last_note > 5000) {
        last_note = now;
        Serial.printf("{\"type\":\"tx_err\",\"path\":\"%s\","
                      "\"msg\":\"pack full, auth pages skipped\"}\n",
                      p->uas_id);
      }
      return n;
    }
    for (int pg = 0; pg < pages; pg++) {
      odid_build_auth_page(out + 3 + count * ODID_MSG_SIZE, &s,
                           1 /* UAS ID signature */, pg, sig,
                           (int)sizeof(sig), ts);
      count++;
    }
    out[2] = (uint8_t)count;
    n = 3 + count * ODID_MSG_SIZE;
  }
  return n;
}

// ---------------------------------------------------------------- WiFi TX

static uint8_t s_frame[320];

// 802.11 beacon carrying the ODID vendor IE.
static int build_beacon(const uint8_t* pack, int pack_len, uint8_t counter) {
  const TxPath* p = &PATHS[P_WIFI];
  static const char* SSID_STR = "ORECCHINO-TEST";
  uint8_t* f = s_frame;
  int i = 0;
  f[i++] = 0x80; f[i++] = 0x00;              // beacon
  f[i++] = 0x00; f[i++] = 0x00;              // duration
  for (int k = 0; k < 6; k++) f[i++] = 0xFF; // DA broadcast
  memcpy(f + i, p->mac, 6); i += 6;          // SA
  memcpy(f + i, p->mac, 6); i += 6;          // BSSID
  f[i++] = 0x00; f[i++] = 0x00;              // seq (driver fills)
  memset(f + i, 0, 8); i += 8;               // timestamp
  f[i++] = 0x64; f[i++] = 0x00;              // beacon interval
  f[i++] = 0x00; f[i++] = 0x00;              // capability
  int slen = strlen(SSID_STR);
  f[i++] = 0x00; f[i++] = (uint8_t)slen;
  memcpy(f + i, SSID_STR, slen); i += slen;
  f[i++] = 0x01; f[i++] = 0x04;              // supported rates
  f[i++] = 0x82; f[i++] = 0x84; f[i++] = 0x8B; f[i++] = 0x96;
  f[i++] = 0x03; f[i++] = 0x01; f[i++] = WIFI_CHANNEL;
  f[i++] = 0xDD;                             // vendor specific IE
  f[i++] = (uint8_t)(4 + 1 + pack_len);
  f[i++] = 0xFA; f[i++] = 0x0B; f[i++] = 0xBC; f[i++] = 0x0D;
  f[i++] = counter;
  memcpy(f + i, pack, pack_len); i += pack_len;
  return i;
}

// NAN service discovery frame: public action frame carrying a Service
// Descriptor Attribute for org.opendroneid.remoteid, service info =
// [message counter][ODID pack] — the layout the receivers parse.
static int build_nan(const uint8_t* pack, int pack_len, uint8_t counter) {
  const TxPath* p = &PATHS[P_NAN];
  // Destination is the NAN SDF *multicast* address — 0x51, not 0x50. The
  // unicast form is filtered out by receiving MAC hardware even in
  // promiscuous mode. BSSID is the NAN cluster ID. Both verified against
  // opendroneid/wireshark-dissector's odid_wifi_sample.pcap.
  static const uint8_t NAN_DA[6]      = {0x51, 0x6F, 0x9A, 0x01, 0x00, 0x00};
  static const uint8_t NAN_CLUSTER[6] = {0x50, 0x6F, 0x9A, 0x01, 0x01, 0x79};
  // SHA-256("org.opendroneid.remoteid")[0..5]
  static const uint8_t SVC_ID[6] = {0x88, 0x69, 0x19, 0x9D, 0x92, 0x09};
  uint8_t* f = s_frame;
  int i = 0;
  f[i++] = 0xD0; f[i++] = 0x00;                    // action frame
  f[i++] = 0x00; f[i++] = 0x00;                    // duration
  memcpy(f + i, NAN_DA, 6); i += 6;                // DA = SDF multicast
  memcpy(f + i, p->mac, 6); i += 6;                // SA
  memcpy(f + i, NAN_CLUSTER, 6); i += 6;           // BSSID = cluster ID
  f[i++] = 0x00; f[i++] = 0x00;                    // seq
  f[i++] = 0x04;                                   // category: public action
  f[i++] = 0x09;                                   // vendor specific
  f[i++] = 0x50; f[i++] = 0x6F; f[i++] = 0x9A;     // WFA OUI
  f[i++] = 0x13;                                   // NAN SDF
  // Service Descriptor Attribute
  int svc_info_len = 1 + pack_len;                 // counter + pack
  int sda_len = 6 + 1 + 1 + 1 + 1 + svc_info_len;  // after the length field
  f[i++] = 0x03;                                   // attribute ID: SDA
  f[i++] = (uint8_t)(sda_len & 0xFF);
  f[i++] = (uint8_t)(sda_len >> 8);
  memcpy(f + i, SVC_ID, 6); i += 6;
  f[i++] = 0x01;                                   // instance ID
  f[i++] = 0x00;                                   // requestor instance ID
  f[i++] = 0x10;                                   // service control: publish
  f[i++] = (uint8_t)svc_info_len;
  f[i++] = counter;
  memcpy(f + i, pack, pack_len); i += pack_len;
  return i;
}

// Sequence numbers matter twice over: repeating seq 0 from one address
// invites 802.11 duplicate filtering, but letting the driver assign them
// (en_sys_seq) also lets it rewrite header fields — including the source
// address, which would collapse our per-path identities onto one MAC. So
// we number the frames ourselves and hand the driver an untouched header.
// NAN synchronisation beacon. The reference transmitter emits this
// alongside the service discovery frame so receivers can find and track the
// NAN cluster; ESP32 projects that send only the action frame produce
// traffic some receivers never latch onto. Constants from
// opendroneid-core-c wifi.c: cluster ID 50:6F:9A:01:00:FF, WFA OUI with
// NAN OUI type 0x13, master preference 0xFE, random factor 0xEA.
static int build_nan_sync_beacon(uint8_t counter) {
  static const uint8_t CLUSTER_ID[6] = {0x50, 0x6F, 0x9A, 0x01, 0x00, 0xFF};
  const TxPath* p = &PATHS[P_NAN];
  uint8_t* f = s_frame;
  int i = 0;
  f[i++] = 0x80; f[i++] = 0x00;                    // beacon
  f[i++] = 0x00; f[i++] = 0x00;                    // duration
  for (int k = 0; k < 6; k++) f[i++] = 0xFF;       // DA broadcast
  memcpy(f + i, p->mac, 6); i += 6;                // SA
  memcpy(f + i, CLUSTER_ID, 6); i += 6;            // BSSID = cluster ID
  f[i++] = 0x00; f[i++] = 0x00;                    // seq
  memset(f + i, 0, 8); i += 8;                     // timestamp
  f[i++] = 0x00; f[i++] = 0x02;                    // beacon interval 512 TU
  f[i++] = 0x00; f[i++] = 0x00;                    // capability
  f[i++] = 0xDD;                                   // vendor IE
  int ie_len_at = i++;                             // length patched below
  f[i++] = 0x50; f[i++] = 0x6F; f[i++] = 0x9A;     // WFA OUI
  f[i++] = 0x13;                                   // NAN
  // Master indication attribute
  f[i++] = 0x00;
  f[i++] = 0x02; f[i++] = 0x00;                    // length 2
  f[i++] = 0xFE;                                   // master preference
  f[i++] = 0xEA;                                   // random factor
  // Cluster attribute: 6 B cluster ID, 8 B anchor master rank, 1 B hop
  // count, 4 B anchor master beacon transmission time. Length is written
  // from the bytes actually emitted so the two can never disagree.
  f[i++] = 0x01;
  int cl_len_at = i;
  i += 2;                                          // length patched below
  int cl_start = i;
  memcpy(f + i, CLUSTER_ID, 6); i += 6;
  f[i++] = 0xFE; f[i++] = 0xEA;                    // anchor master rank
  for (int k = 0; k < 6; k++) f[i++] = 0x00;       // (rank is 8 bytes)
  f[i++] = 0x00;                                   // hop count
  f[i++] = counter;                                // AMBTT
  f[i++] = 0x00; f[i++] = 0x00; f[i++] = 0x00;
  int cl_len = i - cl_start;
  f[cl_len_at]     = (uint8_t)(cl_len & 0xFF);
  f[cl_len_at + 1] = (uint8_t)(cl_len >> 8);
  // Service ID list attribute
  f[i++] = 0x02;
  f[i++] = 0x06; f[i++] = 0x00;                    // length 6
  f[i++] = 0x88; f[i++] = 0x69; f[i++] = 0x19;     // org.opendroneid.remoteid
  f[i++] = 0x9D; f[i++] = 0x92; f[i++] = 0x09;
  f[ie_len_at] = (uint8_t)(i - ie_len_at - 1);     // IE length = bytes after it
  return i;
}

static void tx_wifi_frame(int pid, int len) {
  if (len <= 0) return;
  static uint16_t seq[P_COUNT] = {0};
  uint16_t s = (uint16_t)(++seq[pid] & 0x0FFF);
  s_frame[22] = (uint8_t)(s << 4);          // seq ctrl: frag 0, seq low
  s_frame[23] = (uint8_t)(s >> 4);          // seq high
  if (esp_wifi_80211_tx(WIFI_IF_STA, s_frame, len, false) == ESP_OK)
    s_tx[pid]++;
}

// ----------------------------------------------------------------- BLE TX

#if !CONFIG_BT_NIMBLE_EXT_ADV
#error "orecchino_tx needs CONFIG_BT_NIMBLE_EXT_ADV=1 (see build_opt.h)"
#endif

static NimBLEExtAdvertising* s_adv = nullptr;
// The precompiled BLE controller only grants two advertising sets, so the
// three BLE flavours time-share them: 1M keeps set 0, while coded (long
// range) and legacy alternate on set 1. Each transmission fully
// reconfigures its set, so a receiver still sees all three.
static const uint8_t INST[3] = {0, 1, 1};   // BLE5 1M, BLE5 coded, BLE4 legacy
static const int     INST_PATH[3] = {P_BLE5, P_BLELR, P_BLE4};

static void ble_begin() {
  NimBLEDevice::init("");
  NimBLEDevice::setPower(9);
  s_adv = NimBLEDevice::getAdvertising();
}

// Service Data AD: [len][0x16][FA][FF][0x0D][counter][ODID...]
static int build_ble_ad(uint8_t* out, const uint8_t* odid, int odid_len,
                        uint8_t counter) {
  int payload = 4 + odid_len;              // FA FF 0D counter + data
  out[0] = (uint8_t)(1 + payload);         // AD length (type + payload)
  out[1] = 0x16;                           // service data, 16-bit UUID
  out[2] = 0xFA; out[3] = 0xFF;            // UUID 0xFFFA little-endian
  out[4] = 0x0D;                           // ODID application code
  out[5] = counter;
  memcpy(out + 6, odid, odid_len);
  return 2 + payload;
}

static void tx_ble(int pid, const uint8_t* payload, int payload_len,
                   uint32_t now) {
  // Set 0 belongs to the 1M flavour; coded and legacy share set 1.
  const uint8_t inst = (pid == P_BLE5) ? 0 : 1;
  const TxPath* p = &PATHS[pid];
  uint8_t ad[6 + 160];
  int ad_len;

  NimBLEExtAdvertisement adv(
      pid == P_BLELR ? BLE_HCI_LE_PHY_CODED : BLE_HCI_LE_PHY_1M,
      pid == P_BLELR ? BLE_HCI_LE_PHY_CODED : BLE_HCI_LE_PHY_1M);
  adv.setConnectable(false);
  adv.setScannable(false);
  // Each aircraft advertises from its own address, like real hardware.
  // Random *static* addresses need their top two bits set; NimBLE takes
  // the bytes LSB-first, so mac[0] is the significant end.
  uint8_t bda[6];
  memcpy(bda, p->mac, 6);
  bda[0] |= 0xC0;
  adv.setAddress(NimBLEAddress(bda, BLE_ADDR_RANDOM));

  // Legacy advertising caps the payload at 31 bytes: 6 of ODID overhead
  // leaves exactly one 25-byte message, never a pack.
  if (pid == P_BLE4) adv.setLegacyAdvertising(true);
  ad_len = build_ble_ad(ad, payload, payload_len, s_counter[pid]);
  adv.setData(ad, ad_len);

  s_adv->stop(inst);
  bool set_ok = s_adv->setInstanceData(inst, adv);
  bool start_ok = set_ok && s_adv->start(inst);
  if (start_ok) {
    s_tx[pid]++;
    s_counter[pid]++;
  } else {
    // Report rather than fail silently — a dead path is the whole point
    // of this tool being able to tell you something is wrong.
    static uint32_t last_err = 0;
    if (now - last_err > 5000) {
      last_err = now;
      Serial.printf("{\"type\":\"tx_err\",\"path\":\"%s\",\"inst\":%u,"
                    "\"set_data\":%s,\"start\":%s}\n",
                    p->uas_id, inst, set_ok ? "true" : "false",
                    start_ok ? "true" : "false");
    }
  }
}

// ---------------------------------------------------------------- control

static void print_status() {
  uint32_t now = millis();
  Serial.printf("{\"type\":\"tx_status\",\"fw\":\"%s\",\"ver\":\"%s\","
                "\"running\":%s,\"emergency\":%s,\"home\":[%.6f,%.6f],"
                "\"ring_m\":%.0f,\"ch\":%d,\"paths\":[",
                TX_NAME, TX_VERSION, s_running ? "true" : "false",
                s_emergency ? "true" : "false", s_home_lat, s_home_lon,
                s_ring_m, WIFI_CHANNEL);
  for (int i = 0; i < P_COUNT; i++) {
    OdidTxState s;
    current_state(&s, now, i);
    Serial.printf("%s{\"uas_id\":\"%s\",\"lat\":%.6f,\"lon\":%.6f,"
                  "\"height\":%.0f,\"tx\":%lu}",
                  i ? "," : "", PATHS[i].uas_id, s.lat, s.lon,
                  (double)s.height_m, (unsigned long)s_tx[i]);
  }
  Serial.println("]}");
}

static void handle_line(char* line) {
  if (!line[0]) return;
  if (!strcmp(line, "s")) {
    print_status();
  } else if (!strcmp(line, "go")) {
    s_running = true;
    Serial.println("{\"type\":\"tx_evt\",\"msg\":\"transmitting\"}");
  } else if (!strcmp(line, "stop")) {
    s_running = false;
    s_adv->stop();
    Serial.println("{\"type\":\"tx_evt\",\"msg\":\"paused\"}");
  } else if (!strcmp(line, "e")) {
    s_emergency = !s_emergency;
    Serial.printf("{\"type\":\"tx_evt\",\"emergency\":%s}\n",
                  s_emergency ? "true" : "false");
  } else if (line[0] == 'h' && line[1] == ' ') {
    double la, lo;
    if (sscanf(line + 2, "%lf %lf", &la, &lo) == 2) {
      s_home_lat = la;
      s_home_lon = lo;
      print_status();
    }
  } else if (line[0] == 'r' && line[1] == ' ') {
    double r = atof(line + 2);
    if (r >= 10 && r <= 20000) {
      s_ring_m = r;
      print_status();
    }
  }
}

static void poll_serial() {
  static char buf[96];
  static int len = 0;
  while (Serial.available()) {
    char c = (char)Serial.read();
    if (c == '\n' || c == '\r') {
      buf[len] = 0;
      handle_line(buf);
      len = 0;
    } else if (len < (int)sizeof(buf) - 1) {
      buf[len++] = c;
    } else {
      len = 0;
    }
  }
}

// ----------------------------------------------------------------- sketch

static void tx_begin() {
  WiFi.mode(WIFI_STA);
  WiFi.disconnect();
  esp_wifi_set_ps(WIFI_PS_NONE);
  delay(100);
  esp_wifi_set_channel(WIFI_CHANNEL, WIFI_SECOND_CHAN_NONE);

  ble_begin();
  odid_auth_init();

  // Self-test: sign and verify before claiming to transmit signatures, and
  // publish the public key so a receiver can check us independently.
  uint8_t probe[ODID_MSG_SIZE], sig[64];
  OdidTxState st;
  current_state(&st, 0, P_AUTH);
  odid_build_basic_id(probe, &st);
  odid_auth_sign(sig, probe, 12345);
  bool sig_ok = odid_auth_verify(sig, probe, 12345);
  sig[3] ^= 0xFF;
  bool rej_ok = !odid_auth_verify(sig, probe, 12345);

  char pub_hex[65];
  const uint8_t* pub = odid_auth_pubkey();
  for (int i = 0; i < 32; i++) sprintf(pub_hex + i * 2, "%02x", pub[i]);
  pub_hex[64] = 0;

  Serial.printf("{\"type\":\"tx_boot\",\"fw\":\"%s\",\"ver\":\"%s\","
                "\"paths\":%d,\"selftest\":{\"sign\":%s,\"reject\":%s},"
                "\"auth_pubkey\":\"%s\",\"note\":\"TEST BEACON - not a "
                "compliant Remote ID transmitter\"}\n",
                TX_NAME, TX_VERSION, P_COUNT,
                sig_ok ? "true" : "false", rej_ok ? "true" : "false", pub_hex);
  print_status();
}


static void tx_tick(uint32_t now) {
  poll_serial();

  // One aircraft per loop pass, round-robin, so the shared 2.4 GHz front
  // end is never asked to serve two paths at once. Location must go out at
  // 1 Hz; everything here is comfortably faster.
  static uint32_t last_tx_ms[P_COUNT] = {0};
  static int rr = 0;
  if (s_running) {
    static const uint16_t PATH_MS[P_COUNT] = {
      BEACON_MS, NAN_MS, BLE_MS, 2000, 2000,
      450, 450, 450, 450, 450,
    };
    uint8_t payload[240];
    for (int k = 0; k < P_COUNT; k++) {
      int pid = (rr + k) % P_COUNT;
      if (!s_enabled[pid] || now - last_tx_ms[pid] < PATH_MS[pid]) continue;
      last_tx_ms[pid] = now;
      rr = (pid + 1) % P_COUNT;

      int n = build_payload(pid, payload, now);
      switch (PATHS[pid].carrier) {
        case C_BEACON:
          tx_wifi_frame(pid, build_beacon(payload, n, s_counter[pid]++));
          break;
        case C_NAN:
          // The reference transmitter emits a sync beacon alongside the
          // action frame; receivers that track NAN clusters need it.
          tx_wifi_frame(pid, build_nan_sync_beacon(s_counter[pid]));
          tx_wifi_frame(pid, build_nan(payload, n, s_counter[pid]++));
          break;
        default:
          tx_ble(pid, payload, n, now);
          break;
      }
      break;  // one path per pass
    }
  }

  static uint32_t last_status = 0;
  if (now - last_status >= 5000) {
    last_status = now;
    print_status();
  }
}

// ------------------------------------------------------------------- API
// Everything a board UI needs to drive the beacon without knowing how a
// frame is built.
static int         tx_path_count() { return P_COUNT; }
static const char* tx_path_id(int i) { return PATHS[i].uas_id; }
static const char* tx_path_desc(int i) { return PATHS[i].self_desc; }
static bool        tx_enabled(int i) { return s_enabled[i]; }
static void        tx_set_enabled(int i, bool on) { s_enabled[i] = on; }
static uint32_t    tx_count(int i) { return s_tx[i]; }
static bool        tx_running() { return s_running; }
static void        tx_set_running(bool on) { s_running = on; }
static bool        tx_emergency() { return s_emergency; }
static void        tx_set_emergency(bool on) { s_emergency = on; }
/// Carrier label for a path: "WiFi", "NAN", "BLE5", "BLE LR", "BLE4".
static const char* tx_path_carrier(int i) {
  switch (PATHS[i].carrier) {
    case C_BEACON: return "WiFi"; case C_NAN: return "NAN"; case C_BLE_EXT: return "BLE5";
    case C_BLE_CODED: return "BLE LR"; default: return "BLE4";
  }
}
