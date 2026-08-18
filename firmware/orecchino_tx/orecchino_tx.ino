// orecchino_tx — ASTM F3411 Remote ID *test beacon* for bench-testing the
// orecchino receivers. Target: Seeed XIAO ESP32-C3.
//
// THIS IS TEST EQUIPMENT, NOT A COMPLIANT REMOTE ID TRANSMITTER. It flies a
// synthetic aircraft in a circle around a configurable home point and
// broadcasts it two ways, both of which the receivers decode:
//   * WiFi beacon  — vendor IE, ASD-STAN OUI FA:0B:BC, type 0x0D, channel 6
//   * Bluetooth LE — service data UUID 0xFFFA, app code 0x0D (BT4 legacy,
//                    plus BT5 extended when the NimBLE build has EXT_ADV)
//
// The UAS ID is fixed to an obviously-synthetic serial (ORECCHINO-TEST-*)
// and Self ID says so, so a stray capture can never be mistaken for a real
// aircraft. Do not fly this near operations that consume Remote ID, and
// mind local rules on what you transmit.
//
// Serial commands (one per line, 115200):
//   s            status
//   go / stop    start or pause transmitting
//   e            toggle emergency status (exercises the alert path)
//   h <lat> <lon>  move the home point (drone orbits it)
//   r <m>        orbit radius in metres
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later

#include <Arduino.h>
#include <WiFi.h>
#include <NimBLEDevice.h>
#include "esp_wifi.h"
#include "../common/odid_build.h"

#define TX_NAME      "orecchino-tx"
#define TX_VERSION   "0.1.0"
#define WIFI_CHANNEL 6          // Open Drone ID default / NAN social channel
#define BEACON_MS    300        // ~3 Hz, comfortably inside the 1 Hz minimum
#define BLE_ADV_MS   500

// Each transmit path flies its own synthetic aircraft with the path named
// in its UAS ID, Self ID and operator ID. Receivers key tracks by UAS ID,
// so WiFi and BLE show up as two separate contacts — which path is (or
// isn't) getting through is then obvious on the receiver's own screen.
// The orbits are phase-offset so the markers never sit on top of each other.
#if CONFIG_BT_NIMBLE_EXT_ADV
#define BLE_TAG "BLE5"
#else
#define BLE_TAG "BLE4"
#endif

typedef struct {
  const char* uas_id;
  const char* self_desc;
  const char* op_id;
  double      phase;      // radians of orbit offset
  double      alt_m;      // separate altitudes read clearly in the list
} TxPath;

static const TxPath PATH_WIFI = {
  "ORECCHINO-TEST-WIFI", "TEST beacon path=WIFI", "TEST-OP-WIFI", 0.0, 60.0
};
static const TxPath PATH_BLE = {
  "ORECCHINO-TEST-" BLE_TAG, "TEST beacon path=" BLE_TAG,
  "TEST-OP-" BLE_TAG, M_PI, 90.0
};

// Flight sim defaults: Crissy Field, 400 m orbit at 60 m AGL.
static double s_home_lat = 37.8039;
static double s_home_lon = -122.4640;
static double s_radius_m = 400.0;
static double s_alt_m    = 60.0;
static double s_speed_ms = 8.0;

static bool s_running   = true;
static bool s_emergency = false;
static uint8_t s_msg_counter = 0;
static uint32_t s_tx_wifi = 0, s_tx_ble = 0;

// ------------------------------------------------------------ flight model

static void current_state(OdidTxState* s, uint32_t now_ms, const TxPath* path) {
  // Angular rate that keeps the ground speed honest for the radius.
  double omega = s_speed_ms / s_radius_m;             // rad/s
  double ang = fmod(now_ms / 1000.0 * omega + path->phase, 2 * M_PI);

  double m_per_deg_lat = 111111.0;
  double m_per_deg_lon = m_per_deg_lat * cos(s_home_lat * M_PI / 180.0);

  memset(s, 0, sizeof(*s));
  s->uas_id    = path->uas_id;
  s->ua_type   = 2;                                   // multirotor
  s->status    = s_emergency ? 3 : 2;                 // emergency / airborne
  s->lat       = s_home_lat + (s_radius_m * sin(ang)) / m_per_deg_lat;
  s->lon       = s_home_lon + (s_radius_m * cos(ang)) / m_per_deg_lon;
  s->alt_geo_m = (float)(path->alt_m + 22.0);         // ~geoid offset here
  s->height_m  = (float)path->alt_m;
  s->speed_ms  = (float)s_speed_ms;
  s->vspeed_ms = (float)(0.5 * sin(ang * 2));         // gentle bob
  // Tangent to the circle, clockwise from north.
  s->dir_deg   = (float)fmod(360.0 + 90.0 - ang * 180.0 / M_PI, 360.0);
  s->ts_s      = (float)fmod(now_ms / 1000.0, 3600.0);
  s->self_desc = path->self_desc;
  s->op_lat    = s_home_lat;
  s->op_lon    = s_home_lon;
  s->op_alt_m  = 12.0f;
  s->op_id     = path->op_id;
}

// ---------------------------------------------------------------- WiFi TX

// 802.11 beacon with the ODID vendor IE appended. Built once, patched with
// a fresh payload each transmission.
static uint8_t s_beacon[256];
static int     s_beacon_len = 0;
static int     s_odid_off = 0;    // where the ODID pack starts

static const char* SSID_STR = "ORECCHINO-TEST";
static const uint8_t TX_MAC[6] = {0x02, 0x00, 0x5E, 0x7E, 0x57, 0x01};  // locally administered

static void build_beacon_template() {
  uint8_t* p = s_beacon;
  int i = 0;
  // 802.11 management header: beacon, no flags
  p[i++] = 0x80; p[i++] = 0x00;
  p[i++] = 0x00; p[i++] = 0x00;                       // duration
  for (int k = 0; k < 6; k++) p[i++] = 0xFF;          // DA broadcast
  memcpy(p + i, TX_MAC, 6); i += 6;                   // SA
  memcpy(p + i, TX_MAC, 6); i += 6;                   // BSSID
  p[i++] = 0x00; p[i++] = 0x00;                       // seq (driver fills)
  // fixed params: timestamp, interval, caps
  memset(p + i, 0, 8); i += 8;
  p[i++] = 0x64; p[i++] = 0x00;                       // beacon interval 100 TU
  p[i++] = 0x00; p[i++] = 0x00;                       // capability info
  // SSID IE
  int ssid_len = strlen(SSID_STR);
  p[i++] = 0x00; p[i++] = (uint8_t)ssid_len;
  memcpy(p + i, SSID_STR, ssid_len); i += ssid_len;
  // Supported rates IE (1, 2, 5.5, 11 Mbps)
  p[i++] = 0x01; p[i++] = 0x04;
  p[i++] = 0x82; p[i++] = 0x84; p[i++] = 0x8B; p[i++] = 0x96;
  // DS parameter set
  p[i++] = 0x03; p[i++] = 0x01; p[i++] = WIFI_CHANNEL;
  // Vendor specific IE: OUI FA:0B:BC, type 0x0D, counter, then the pack
  p[i++] = 0xDD;
  p[i++] = (uint8_t)(4 + 1 + 128);                    // OUI+type + counter + pack
  p[i++] = 0xFA; p[i++] = 0x0B; p[i++] = 0xBC; p[i++] = 0x0D;
  p[i++] = 0;                                         // message counter
  s_odid_off = i;
  i += 128;                                           // pack written per TX
  s_beacon_len = i;
}

static void tx_wifi(const uint8_t* pack, int pack_len) {
  if (pack_len != 128) return;
  s_beacon[s_odid_off - 1] = s_msg_counter;
  memcpy(s_beacon + s_odid_off, pack, pack_len);
  if (esp_wifi_80211_tx(WIFI_IF_STA, s_beacon, s_beacon_len, false) == ESP_OK)
    s_tx_wifi++;
}

// ----------------------------------------------------------------- BLE TX

// Only one advertising type exists per build — the other name isn't even
// declared when CONFIG_BT_NIMBLE_EXT_ADV flips.
#if CONFIG_BT_NIMBLE_EXT_ADV
static NimBLEExtAdvertising* s_ext_adv = nullptr;
#else
static NimBLEAdvertising* s_adv = nullptr;
#endif

static void ble_begin() {
  NimBLEDevice::init("");
  NimBLEDevice::setPower(9);  // dBm, keep the bench link healthy
#if CONFIG_BT_NIMBLE_EXT_ADV
  s_ext_adv = NimBLEDevice::getAdvertising();
#else
  s_adv = NimBLEDevice::getAdvertising();
#endif
}

// Service Data AD structure: [len][0x16][FA][FF][0x0D][counter][pack...]
static void tx_ble(const uint8_t* pack, int pack_len) {
  if (pack_len != 128) return;
  static uint8_t sd[4 + 128];
  sd[0] = 0xFA; sd[1] = 0xFF;        // UUID 0xFFFA, little-endian
  sd[2] = 0x0D;                      // ODID application code
  sd[3] = s_msg_counter;
  memcpy(sd + 4, pack, pack_len);

#if CONFIG_BT_NIMBLE_EXT_ADV
  // BT5 extended advertising carries the whole 132-byte pack in one PDU.
  NimBLEExtAdvertisement adv(BLE_HCI_LE_PHY_1M, BLE_HCI_LE_PHY_1M);
  adv.setConnectable(false);
  adv.setScannable(false);
  uint8_t raw[3 + sizeof(sd)];
  raw[0] = (uint8_t)(1 + sizeof(sd));   // AD length
  raw[1] = 0x16;                        // Service Data - 16-bit UUID
  memcpy(raw + 2, sd, sizeof(sd));
  adv.setData(raw, 2 + sizeof(sd));
  s_ext_adv->setInstanceData(0, adv);
  if (s_ext_adv->start(0)) s_tx_ble++;
#else
  // BT4 legacy: 31-byte payload cap, so send one 25-byte message per
  // advertisement, rotating through the pack (what real BT4-only
  // transmitters do).
  static int rot = 0;
  const uint8_t* msg = pack + 3 + (rot % 5) * ODID_MSG_SIZE;
  rot++;
  uint8_t one[4 + ODID_MSG_SIZE];
  one[0] = 0xFA; one[1] = 0xFF; one[2] = 0x0D; one[3] = s_msg_counter;
  memcpy(one + 4, msg, ODID_MSG_SIZE);
  NimBLEAdvertisementData data;
  data.setServiceData(NimBLEUUID((uint16_t)0xFFFA),
                      std::vector<uint8_t>(one, one + sizeof(one)));
  s_adv->stop();
  s_adv->setAdvertisementData(data);
  s_adv->start();
  s_tx_ble++;
#endif
}

// ---------------------------------------------------------------- control

static void print_status() {
  OdidTxState w, b;
  current_state(&w, millis(), &PATH_WIFI);
  current_state(&b, millis(), &PATH_BLE);
  Serial.printf("{\"type\":\"tx_status\",\"fw\":\"%s\",\"ver\":\"%s\","
                "\"running\":%s,\"emergency\":%s,"
                "\"paths\":[{\"path\":\"wifi\",\"uas_id\":\"%s\",\"lat\":%.6f,"
                "\"lon\":%.6f,\"height\":%.0f,\"tx\":%lu},"
                "{\"path\":\"%s\",\"uas_id\":\"%s\",\"lat\":%.6f,\"lon\":%.6f,"
                "\"height\":%.0f,\"tx\":%lu}],"
                "\"home\":[%.6f,%.6f],\"radius_m\":%.0f,\"speed\":%.1f,"
                "\"ch\":%d}\n",
                TX_NAME, TX_VERSION, s_running ? "true" : "false",
                s_emergency ? "true" : "false",
                PATH_WIFI.uas_id, w.lat, w.lon, (double)w.height_m,
                (unsigned long)s_tx_wifi,
                BLE_TAG, PATH_BLE.uas_id, b.lat, b.lon, (double)b.height_m,
                (unsigned long)s_tx_ble,
                s_home_lat, s_home_lon, s_radius_m, s_speed_ms, WIFI_CHANNEL);
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
      s_radius_m = r;
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
  build_beacon_template();

  ble_begin();

  Serial.printf("{\"type\":\"tx_boot\",\"fw\":\"%s\",\"ver\":\"%s\","
                "\"paths\":[\"%s\",\"%s\"],\"note\":\"TEST BEACON - not a "
                "compliant Remote ID transmitter\"}\n",
                TX_NAME, TX_VERSION, PATH_WIFI.uas_id, PATH_BLE.uas_id);
  print_status();
}

void loop() {
  uint32_t now = millis();
  poll_serial();

  static uint32_t last_wifi = 0, last_ble = 0, last_status = 0;
  if (s_running) {
    uint8_t pack[160];
    OdidTxState s;
    if (now - last_wifi >= BEACON_MS) {
      last_wifi = now;
      current_state(&s, now, &PATH_WIFI);
      tx_wifi(pack, odid_build_pack(pack, &s, now / 1000));
      s_msg_counter++;
    }
    if (now - last_ble >= BLE_ADV_MS) {
      last_ble = now;
      current_state(&s, now, &PATH_BLE);
      tx_ble(pack, odid_build_pack(pack, &s, now / 1000));
    }
  }

  if (now - last_status >= 5000) {
    last_status = now;
    print_status();
  }
  delay(2);
}
