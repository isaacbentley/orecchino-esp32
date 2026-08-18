// orecchino_tx — ASTM F3411 Remote ID *test beacon* for bench-testing the
// orecchino receivers. Target: Seeed XIAO ESP32-C3.
//
// THIS IS TEST EQUIPMENT, NOT A COMPLIANT REMOTE ID TRANSMITTER. It flies
// five synthetic aircraft, one per transmit path, and broadcasts each on
// exactly one path so a receiver's contact list doubles as a path checklist:
//
//   UAS ID                 path
//   ORECCHINO-TEST-WIFI    WiFi beacon, vendor IE (ASD-STAN OUI), channel 6
//   ORECCHINO-TEST-NAN     WiFi NAN service discovery frame, channel 6
//   ORECCHINO-TEST-BLE5    BLE 5 extended advertising, 1M PHY
//   ORECCHINO-TEST-BLELR   BLE 5 extended advertising, coded PHY (long range)
//   ORECCHINO-TEST-BLE4    BLE 4 legacy advertising (31 B, one message/adv)
//
// The five orbit centres sit on a 200 m (~1/8 mile) ring around the home
// point at 72-degree intervals, each at its own altitude, so they are
// clearly separated on a receiver's map. The IDs are obviously synthetic by
// design so a stray capture can never be mistaken for a real aircraft. Mind
// local rules on what you transmit.
//
// Serial commands (one per line, 115200):
//   s              status (per-path transmit counters and positions)
//   go / stop      start or pause transmitting
//   e              toggle emergency status (exercises the alert path)
//   h <lat> <lon>  move the home point
//   r <m>          separation ring radius in metres (default 200)
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

#include <Arduino.h>
#include <WiFi.h>
#include <NimBLEDevice.h>
#include "esp_wifi.h"
#include "../common/odid_build.h"

#define TX_NAME      "orecchino-tx"
#define TX_VERSION   "0.2.0"
#define WIFI_CHANNEL 6      // Open Drone ID default / NAN social channel
#define BEACON_MS    300    // WiFi beacon, ~3 Hz
#define NAN_MS       400    // WiFi NAN SDF
#define BLE_MS       500    // per BLE instance
#define ORBIT_M      50.0   // each aircraft's own little circle

// ---------------------------------------------------------------- paths

enum TxPathId { P_WIFI = 0, P_NAN, P_BLE5, P_BLELR, P_BLE4, P_COUNT };

typedef struct {
  const char* uas_id;
  const char* self_desc;
  const char* op_id;
  double      bearing_deg;  // where this aircraft's orbit centre sits
  double      alt_m;
  uint8_t     mac[6];       // WiFi SA / BLE advertising address
} TxPath;

static const TxPath PATHS[P_COUNT] = {
  { "ORECCHINO-TEST-WIFI",  "TEST path=WIFI-BEACON", "TEST-OP-WIFI",
    0.0,   60.0, {0x02, 0x00, 0x5E, 0x7E, 0x57, 0x01} },
  { "ORECCHINO-TEST-NAN",   "TEST path=WIFI-NAN",    "TEST-OP-NAN",
    72.0,  75.0, {0x02, 0x00, 0x5E, 0x7E, 0x57, 0x02} },
  { "ORECCHINO-TEST-BLE5",  "TEST path=BLE5-1M",     "TEST-OP-BLE5",
    144.0, 90.0, {0x02, 0x00, 0x5E, 0x7E, 0x57, 0x03} },
  { "ORECCHINO-TEST-BLELR", "TEST path=BLE5-CODED",  "TEST-OP-BLELR",
    216.0, 105.0, {0x02, 0x00, 0x5E, 0x7E, 0x57, 0x04} },
  { "ORECCHINO-TEST-BLE4",  "TEST path=BLE4-LEGACY", "TEST-OP-BLE4",
    288.0, 120.0, {0x02, 0x00, 0x5E, 0x7E, 0x57, 0x05} },
};

// Flight sim defaults: Crissy Field.
static double s_home_lat = 37.8039;
static double s_home_lon = -122.4640;
static double s_ring_m   = 201.0;   // 1/8 mile between the aircraft
static double s_speed_ms = 8.0;

static bool s_running   = true;
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

static int build_for(int pid, uint8_t* pack, uint32_t now) {
  OdidTxState s;
  current_state(&s, now, pid);
  return odid_build_pack(pack, &s, now / 1000);
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
  static const uint8_t NAN_CLUSTER[6] = {0x50, 0x6F, 0x9A, 0x01, 0x00, 0x00};
  // SHA-256("org.opendroneid.remoteid")[0..5]
  static const uint8_t SVC_ID[6] = {0x88, 0x69, 0x19, 0x9D, 0x92, 0x09};
  uint8_t* f = s_frame;
  int i = 0;
  f[i++] = 0xD0; f[i++] = 0x00;                    // action frame
  f[i++] = 0x00; f[i++] = 0x00;                    // duration
  memcpy(f + i, NAN_CLUSTER, 6); i += 6;           // DA = NAN cluster
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

static void tx_wifi_frame(int pid, int len) {
  if (len > 0 && esp_wifi_80211_tx(WIFI_IF_STA, s_frame, len, false) == ESP_OK)
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

static void tx_ble(int slot, const uint8_t* pack, int pack_len, uint32_t now) {
  const int pid = INST_PATH[slot];
  const uint8_t inst = INST[slot];
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

  if (pid == P_BLE4) {
    // Legacy advertising: 31-byte cap, so rotate one 25-byte message per
    // advertisement — exactly what BT4-only transmitters do.
    adv.setLegacyAdvertising(true);
    int rot = (int)((now / BLE_MS) % 5);
    ad_len = build_ble_ad(ad, pack + 3 + rot * ODID_MSG_SIZE, ODID_MSG_SIZE,
                          s_counter[pid]);
  } else {
    ad_len = build_ble_ad(ad, pack, pack_len, s_counter[pid]);
  }
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

void setup() {
  Serial.begin(115200);
  uint32_t t0 = millis();
  while (!Serial && millis() - t0 < 3000) delay(10);

  WiFi.mode(WIFI_STA);
  WiFi.disconnect();
  esp_wifi_set_ps(WIFI_PS_NONE);
  delay(100);
  esp_wifi_set_channel(WIFI_CHANNEL, WIFI_SECOND_CHAN_NONE);

  ble_begin();

  Serial.printf("{\"type\":\"tx_boot\",\"fw\":\"%s\",\"ver\":\"%s\","
                "\"paths\":%d,\"note\":\"TEST BEACON - not a compliant "
                "Remote ID transmitter\"}\n",
                TX_NAME, TX_VERSION, P_COUNT);
  print_status();
}

void loop() {
  uint32_t now = millis();
  poll_serial();

  static uint32_t last_bcn = 0, last_nan = 0, last_ble[3] = {0, 0, 0};
  if (s_running) {
    uint8_t pack[160];

    if (now - last_bcn >= BEACON_MS) {
      last_bcn = now;
      int n = build_for(P_WIFI, pack, now);
      tx_wifi_frame(P_WIFI, build_beacon(pack, n, s_counter[P_WIFI]++));
    }
    if (now - last_nan >= NAN_MS) {
      last_nan = now;
      int n = build_for(P_NAN, pack, now);
      tx_wifi_frame(P_NAN, build_nan(pack, n, s_counter[P_NAN]++));
    }
    // Stagger the BLE instances so their radio slots don't collide.
    for (int slot = 0; slot < 3; slot++) {
      if (now - last_ble[slot] >= BLE_MS + slot * 60) {
        last_ble[slot] = now;
        int n = build_for(INST_PATH[slot], pack, now);
        tx_ble(slot, pack, n, now);
        break;   // one instance per loop pass
      }
    }
  }

  static uint32_t last_status = 0;
  if (now - last_status >= 5000) {
    last_status = now;
    print_status();
  }
  delay(2);
}
