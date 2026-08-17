// orecchino_fw — ASTM F3411 (Open Drone ID) Remote ID sniffer
// Target: Seeed Studio XIAO ESP32-C3 (esp32:esp32:XIAO_ESP32C3)
//
// Receives Broadcast Remote ID on:
//   * WiFi beacons        — vendor IE, OUI FA:0B:BC, type 0x0D
//   * WiFi NAN SDF        — public action frames, WFA OUI 50:6F:9A / NAN,
//                           service org.opendroneid.remoteid
//   * Bluetooth LE        — service data UUID 0xFFFA, app code 0x0D
//                           (legacy ADV; extended/long-range only if the
//                           NimBLE build has BLE_EXT_ADV — the stock Arduino
//                           core does not, and compliant transmitters send
//                           legacy BT4 frames alongside BT5 anyway)
//
// Output: one JSON object per line on the native USB CDC serial port.
//   {"type":"boot", ...}   once at startup
//   {"type":"rid",  ...}   one per decoded Remote ID transmission
//   {"type":"hb",   ...}   heartbeat with counters every 2 s

#include <Arduino.h>
#include <WiFi.h>
#include <stdarg.h>
#include "sdkconfig.h"
#include "esp_wifi.h"
#include <BLEDevice.h>
#include <BLEScan.h>
#include <BLEAdvertisedDevice.h>

#define FW_NAME    "orecchino"
#define FW_VERSION "0.1.0"

// ---------------------------------------------------------------- event queue

enum RidSrc : uint8_t { SRC_WIFI_BEACON = 0, SRC_WIFI_NAN = 1, SRC_BLE = 2 };
static const char* SRC_NAMES[] = { "wifi", "nan", "ble" };

// One ODID message is 25 B; a full message pack is 2 + 9*25 = 227 B.
typedef struct {
  uint8_t src;
  uint8_t mac[6];
  int8_t  rssi;
  uint8_t chan;
  uint8_t len;
  uint8_t data[232];
} RidEvt;

// Decoded state for one UAS, filled from whichever messages were received.
// Defined up here so the Arduino preprocessor's hoisted prototypes see it.
typedef struct {
  bool    has_basic[2];
  uint8_t id_type[2], ua_type[2];
  char    uas_id[2][41];

  bool    has_loc;
  uint8_t status, height_ref;
  float   dir, speed, vspeed;
  double  lat, lon;
  float   alt_baro, alt_geo, height;
  uint8_t h_acc, v_acc, baro_acc, spd_acc, ts_acc;
  float   ts;

  bool    has_self;
  uint8_t self_type;
  char    self_desc[24];

  bool    has_sys;
  uint8_t op_loc_type, class_type;
  double  op_lat, op_lon;
  uint16_t area_count;
  float   area_radius, area_ceiling, area_floor;
  uint8_t cat_eu, class_eu;
  float   op_alt;
  uint32_t sys_ts;   // seconds since 2019-01-01 00:00 UTC

  bool    has_op;
  uint8_t op_id_type;
  char    op_id[21];
} OdidUas;

static QueueHandle_t s_q;
static volatile uint32_t s_cnt_wifi_frames = 0;
static volatile uint32_t s_cnt_ble_advs    = 0;
static volatile uint32_t s_cnt_rid         = 0;
static volatile uint32_t s_cnt_dropped     = 0;
static volatile uint8_t  s_cur_chan        = 6;
static bool s_ble_ok  = false;
static bool s_ble_ext = false;

// Callbacks run in the WiFi / Bluedroid task context: copy out and return.
static void enqueue_rid(uint8_t src, const uint8_t* mac, int8_t rssi,
                        uint8_t chan, const uint8_t* odid, int len) {
  if (len < 25 || !s_q) return;
  RidEvt e;
  e.src  = src;
  memcpy(e.mac, mac, 6);
  e.rssi = rssi;
  e.chan = chan;
  if (len > (int)sizeof(e.data)) len = sizeof(e.data);
  e.len  = len;
  memcpy(e.data, odid, len);
  if (xQueueSend(s_q, &e, 0) != pdTRUE) s_cnt_dropped++;
}

// ------------------------------------------------------------- WiFi sniffing

// Hop list biased toward channel 6, the Open Drone ID default.
static const uint8_t HOP[] = { 6, 1, 11, 6, 2, 7, 6, 3, 12, 6, 4, 8, 6, 5, 13, 6, 9, 10 };
static const uint32_t HOP_DWELL_MS = 175;

static void wifi_cb(void* buf, wifi_promiscuous_pkt_type_t type) {
  if (type != WIFI_PKT_MGMT) return;
  const wifi_promiscuous_pkt_t* p = (const wifi_promiscuous_pkt_t*)buf;
  int len = (int)p->rx_ctrl.sig_len - 4;  // strip FCS
  const uint8_t* d = p->payload;
  if (len < 24) return;
  s_cnt_wifi_frames++;

  uint8_t fc0 = d[0];
  if ((fc0 & 0x0C) != 0x00) return;  // management frames only
  uint8_t stype = fc0 & 0xF0;
  const uint8_t* sa = d + 10;        // SA in mgmt header

  if (stype == 0x80) {
    // Beacon: 24 B header + 12 B fixed params, then IEs.
    int off = 36;
    while (off + 2 <= len) {
      uint8_t id = d[off], l = d[off + 1];
      if (off + 2 + l > len) break;
      const uint8_t* ie = d + off + 2;
      // Vendor specific, ASD-STAN OUI FA:0B:BC, type 0x0D, then [counter][ODID]
      if (id == 221 && l >= 30 &&
          ie[0] == 0xFA && ie[1] == 0x0B && ie[2] == 0xBC && ie[3] == 0x0D) {
        enqueue_rid(SRC_WIFI_BEACON, sa, p->rx_ctrl.rssi, p->rx_ctrl.channel,
                    ie + 5, l - 5);
      }
      off += 2 + l;
    }
  } else if (stype == 0xD0) {
    // Action frame — look for a NAN service discovery frame.
    const uint8_t* b = d + 24;
    int blen = len - 24;
    if (blen < 12) return;
    if (b[0] != 0x04 || b[1] != 0x09) return;                  // public action / vendor
    if (b[2] != 0x50 || b[3] != 0x6F || b[4] != 0x9A) return;  // WFA OUI
    if (b[5] != 0x13) return;                                  // NAN
    // Service ID = SHA256("org.opendroneid.remoteid")[0..5]
    static const uint8_t SVC[6] = { 0x88, 0x69, 0x19, 0x9D, 0x92, 0x09 };
    for (int i = 6; i + 12 < blen; i++) {
      if (memcmp(b + i, SVC, 6) != 0) continue;
      // service_id[6], instance, requestor, control, info_len, counter, ODID...
      uint8_t info_len = b[i + 9];
      int n = (info_len > 0) ? info_len - 1 : 0;
      int avail = blen - (i + 11);
      if (n > avail) n = avail;
      enqueue_rid(SRC_WIFI_NAN, sa, p->rx_ctrl.rssi, p->rx_ctrl.channel,
                  b + i + 11, n);
      break;
    }
  }
}

static void wifi_start_sniffer() {
  WiFi.mode(WIFI_STA);
  WiFi.disconnect();
  delay(100);
  wifi_promiscuous_filter_t filt = {};
  filt.filter_mask = WIFI_PROMIS_FILTER_MASK_MGMT;
  esp_wifi_set_promiscuous_filter(&filt);
  esp_wifi_set_promiscuous_rx_cb(&wifi_cb);
  esp_wifi_set_promiscuous(true);
  esp_wifi_set_channel(HOP[0], WIFI_SECOND_CHAN_NONE);
  s_cur_chan = HOP[0];
}

// -------------------------------------------------------------- BLE scanning

static void handle_adv(const uint8_t* addr, int rssi, const uint8_t* data, int len) {
  s_cnt_ble_advs++;
  int i = 0;
  while (i + 1 < len) {
    uint8_t l = data[i];             // AD length: type byte + payload
    if (l == 0 || i + 1 + l > len) break;
    uint8_t t = data[i + 1];
    // Service Data 16-bit, UUID 0xFFFA (ASTM), app code 0x0D
    if (t == 0x16 && l >= 30) {
      const uint8_t* sd = data + i + 2;
      if (sd[0] == 0xFA && sd[1] == 0xFF && sd[2] == 0x0D) {
        // sd[3] = message counter, sd+4 = ODID message or pack
        enqueue_rid(SRC_BLE, addr, rssi, 0, sd + 4, l - 5);
      }
    }
    i += 1 + l;
  }
}

static BLEScan* s_scan = nullptr;

class RidAdvCallbacks : public BLEAdvertisedDeviceCallbacks {
  void onResult(BLEAdvertisedDevice dev) override {
    uint8_t mac[6] = {0};
    unsigned b[6];
    if (sscanf(dev.getAddress().toString().c_str(),
               "%02x:%02x:%02x:%02x:%02x:%02x",
               &b[0], &b[1], &b[2], &b[3], &b[4], &b[5]) == 6)
      for (int i = 0; i < 6; i++) mac[i] = (uint8_t)b[i];
    handle_adv(mac, dev.getRSSI(), dev.getPayload(), (int)dev.getPayloadLength());
  }
};

static bool ble_start_scanner() {
  BLEDevice::init("");
  s_scan = BLEDevice::getScan();
  if (!s_scan) return false;
  static RidAdvCallbacks cb;
  // duplicates on: repeated advertisements carry fresh Location messages.
  // shouldParse off: we read the raw payload; parsing allocates Strings
  // per advertisement and starves the heap.
  s_scan->setAdvertisedDeviceCallbacks(&cb, true, false);
  s_scan->setActiveScan(false);
  s_scan->setInterval(50);  // ms
  s_scan->setWindow(25);    // ms — leave air time for WiFi coex
  return s_scan->start(0 /* forever */, nullptr, false);
}

// BLEScan allocates one stored device per unique address and only frees on
// clearResults(); random advertiser addresses rotate constantly, so without
// this the heap is exhausted in under a minute. stop() first so the NimBLE
// host task cannot race the clear. The few-ms gap every cycle is harmless.
static void ble_maintain() {
  static uint32_t last = 0;
  if (!s_scan || millis() - last < 5000) return;
  last = millis();
  s_scan->stop();
  s_scan->clearResults();
  s_scan->start(0, nullptr, false);
}

// ------------------------------------------------------------- ODID decoding
// ASTM F3411 / Open Drone ID broadcast messages: 25 bytes each.
// Header byte: (message type << 4) | protocol version.

static int16_t rd_i16(const uint8_t* p) { return (int16_t)(p[0] | (p[1] << 8)); }
static uint16_t rd_u16(const uint8_t* p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static int32_t rd_i32(const uint8_t* p) {
  return (int32_t)((uint32_t)p[0] | ((uint32_t)p[1] << 8) |
                   ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24));
}
static uint32_t rd_u32(const uint8_t* p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
         ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static float decode_alt(uint16_t raw) { return raw * 0.5f - 1000.0f; }  // -1000 = unknown

// Copy a fixed-width ASCII field, trimming NULs/trailing space, sanitising
// anything that would break a JSON string.
static void copy_text(char* dst, size_t dstsz, const uint8_t* src, size_t n) {
  size_t o = 0;
  for (size_t i = 0; i < n && o + 1 < dstsz; i++) {
    uint8_t c = src[i];
    if (c == 0) break;
    if (c < 0x20 || c > 0x7E || c == '"' || c == '\\') c = '.';
    dst[o++] = (char)c;
  }
  while (o > 0 && dst[o - 1] == ' ') o--;
  dst[o] = 0;
}

static void decode_msg(const uint8_t* m, OdidUas* u) {
  uint8_t type = m[0] >> 4;
  switch (type) {
    case 0x0: {  // Basic ID
      int slot = u->has_basic[0] ? 1 : 0;
      if (u->has_basic[0] && u->id_type[0] == (m[1] >> 4)) slot = 0;  // refresh
      u->has_basic[slot] = true;
      u->id_type[slot] = m[1] >> 4;
      u->ua_type[slot] = m[1] & 0x0F;
      if (u->id_type[slot] == 3) {  // UTM UUID: binary, hex-encode
        char* o = u->uas_id[slot];
        for (int i = 0; i < 20; i++) { sprintf(o, "%02x", m[2 + i]); o += 2; }
      } else {
        copy_text(u->uas_id[slot], sizeof(u->uas_id[slot]), m + 2, 20);
      }
      break;
    }
    case 0x1: {  // Location / Vector
      u->has_loc = true;
      u->status     = m[1] >> 4;
      u->height_ref = (m[1] >> 2) & 1;
      uint8_t ew    = (m[1] >> 1) & 1;
      uint8_t mult  = m[1] & 1;
      u->dir    = (m[2] <= 180) ? (float)m[2] + (ew ? 180.0f : 0.0f) : -1.0f;
      u->speed  = (m[3] == 255) ? -1.0f
                : (mult ? m[3] * 0.75f + 63.75f : m[3] * 0.25f);
      u->vspeed = (int8_t)m[4] * 0.5f;
      u->lat = rd_i32(m + 5) * 1e-7;
      u->lon = rd_i32(m + 9) * 1e-7;
      u->alt_baro = decode_alt(rd_u16(m + 13));
      u->alt_geo  = decode_alt(rd_u16(m + 15));
      u->height   = decode_alt(rd_u16(m + 17));
      u->v_acc    = m[19] >> 4;
      u->h_acc    = m[19] & 0x0F;
      u->baro_acc = m[20] >> 4;
      u->spd_acc  = m[20] & 0x0F;
      uint16_t ts = rd_u16(m + 21);
      u->ts     = (ts == 0xFFFF) ? -1.0f : ts * 0.1f;
      u->ts_acc = m[23] & 0x0F;
      break;
    }
    case 0x3: {  // Self ID
      u->has_self  = true;
      u->self_type = m[1];
      copy_text(u->self_desc, sizeof(u->self_desc), m + 2, 23);
      break;
    }
    case 0x4: {  // System
      u->has_sys     = true;
      u->op_loc_type = m[1] & 0x03;
      u->class_type  = (m[1] >> 2) & 0x07;
      u->op_lat = rd_i32(m + 2) * 1e-7;
      u->op_lon = rd_i32(m + 6) * 1e-7;
      u->area_count   = rd_u16(m + 10);
      u->area_radius  = m[12] * 10.0f;
      u->area_ceiling = decode_alt(rd_u16(m + 13));
      u->area_floor   = decode_alt(rd_u16(m + 15));
      u->cat_eu   = m[17] >> 4;
      u->class_eu = m[17] & 0x0F;
      u->op_alt = decode_alt(rd_u16(m + 18));
      u->sys_ts = rd_u32(m + 20);
      break;
    }
    case 0x5: {  // Operator ID
      u->has_op = true;
      u->op_id_type = m[1];
      copy_text(u->op_id, sizeof(u->op_id), m + 2, 20);
      break;
    }
    default:
      break;  // 0x2 Auth and unknown types: ignored
  }
}

// Accepts either a single message or a message pack (type 0xF).
static bool decode_payload(const uint8_t* d, int len, OdidUas* u) {
  memset(u, 0, sizeof(*u));
  if (len < 25) return false;
  uint8_t type = d[0] >> 4;
  bool any = false;
  if (type == 0xF) {
    if (len < 3 || d[1] != 25) return false;
    int n = d[2];
    if (n > 9) n = 9;
    for (int i = 0; i < n; i++) {
      const uint8_t* m = d + 3 + i * 25;
      if (3 + (i + 1) * 25 > len) break;
      if ((m[0] >> 4) <= 0x5) { decode_msg(m, u); any = true; }
    }
  } else if (type <= 0x5) {
    decode_msg(d, u);
    any = true;
  }
  return any && (u->has_basic[0] || u->has_loc || u->has_sys ||
                 u->has_self || u->has_op);
}

// --------------------------------------------------------------- JSON output

static char s_jb[1536];
static int  s_jl;

static void jput(const char* fmt, ...) {
  if (s_jl >= (int)sizeof(s_jb) - 1) return;
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(s_jb + s_jl, sizeof(s_jb) - s_jl, fmt, ap);
  va_end(ap);
  if (n > 0) s_jl = min(s_jl + n, (int)sizeof(s_jb) - 1);
}

static void emit_rid(const RidEvt* e, const OdidUas* u) {
  s_jl = 0;
  jput("{\"type\":\"rid\",\"src\":\"%s\",\"mac\":\"%02X:%02X:%02X:%02X:%02X:%02X\","
       "\"rssi\":%d", SRC_NAMES[e->src], e->mac[0], e->mac[1], e->mac[2],
       e->mac[3], e->mac[4], e->mac[5], e->rssi);
  if (e->chan) jput(",\"ch\":%u", e->chan);

  if (u->has_basic[0] || u->has_basic[1]) {
    jput(",\"basic_id\":[");
    bool first = true;
    for (int i = 0; i < 2; i++) {
      if (!u->has_basic[i]) continue;
      jput("%s{\"id_type\":%u,\"ua_type\":%u,\"uas_id\":\"%s\"}",
           first ? "" : ",", u->id_type[i], u->ua_type[i], u->uas_id[i]);
      first = false;
    }
    jput("]");
  }
  if (u->has_loc) {
    jput(",\"loc\":{\"status\":%u,\"lat\":%.7f,\"lon\":%.7f", u->status, u->lat, u->lon);
    jput(",\"alt_geo\":%.1f,\"alt_baro\":%.1f,\"height\":%.1f,\"height_ref\":%u",
         u->alt_geo, u->alt_baro, u->height, u->height_ref);
    jput(",\"speed\":%.2f,\"vspeed\":%.2f,\"dir\":%.0f,\"ts\":%.1f}",
         u->speed, u->vspeed, u->dir, u->ts);
  }
  if (u->has_self)
    jput(",\"self_id\":{\"desc_type\":%u,\"desc\":\"%s\"}", u->self_type, u->self_desc);
  if (u->has_sys) {
    jput(",\"system\":{\"op_lat\":%.7f,\"op_lon\":%.7f,\"op_alt\":%.1f",
         u->op_lat, u->op_lon, u->op_alt);
    jput(",\"op_loc_type\":%u,\"area_count\":%u,\"ts\":%lu}",
         u->op_loc_type, u->area_count, (unsigned long)u->sys_ts);
  }
  if (u->has_op)
    jput(",\"op_id\":{\"id_type\":%u,\"id\":\"%s\"}", u->op_id_type, u->op_id);
  jput("}");
  Serial.println(s_jb);
}

static void emit_heartbeat() {
  Serial.printf("{\"type\":\"hb\",\"up\":%lu,\"wifi_frames\":%lu,\"ble_advs\":%lu,"
                "\"rid\":%lu,\"dropped\":%lu,\"ch\":%u,\"ble\":%s,\"ble_ext\":%s,"
                "\"heap\":%lu}\n",
                (unsigned long)millis(),
                (unsigned long)s_cnt_wifi_frames, (unsigned long)s_cnt_ble_advs,
                (unsigned long)s_cnt_rid, (unsigned long)s_cnt_dropped,
                s_cur_chan, s_ble_ok ? "true" : "false",
                s_ble_ext ? "true" : "false",
                (unsigned long)ESP.getFreeHeap());
}

// ----------------------------------------------------------------- self-test

static void wr_i32(uint8_t* p, int32_t v) {
  p[0] = v & 0xFF; p[1] = (v >> 8) & 0xFF;
  p[2] = (v >> 16) & 0xFF; p[3] = (v >> 24) & 0xFF;
}
static void wr_u16(uint8_t* p, uint16_t v) { p[0] = v & 0xFF; p[1] = v >> 8; }

// Sending 't' over serial injects a synthetic ODID message pack through the
// normal enqueue -> decode -> JSON path, so the full chain (minus RF) can be
// exercised without a transmitting drone.
static void inject_test_pack() {
  uint8_t d[3 + 3 * 25] = {0};
  d[0] = 0xF2;  // message pack, protocol v2
  d[1] = 25;
  d[2] = 3;

  uint8_t* m = d + 3;         // Basic ID: serial number, multirotor
  m[0] = 0x02;
  m[1] = 0x12;
  memcpy(m + 2, "ORECCHINO-TEST-01", 17);

  m = d + 3 + 25;             // Location: airborne, 90 deg, 5 m/s
  m[0] = 0x12;
  m[1] = 0x20;
  m[2] = 90;
  m[3] = 20;
  m[4] = 0;
  wr_i32(m + 5, 378039000);   // 37.8039 N
  wr_i32(m + 9, -1224640000); // 122.4640 W
  wr_u16(m + 13, 2190);       // baro alt 95 m
  wr_u16(m + 15, 2200);       // geo alt 100 m
  wr_u16(m + 17, 2120);       // height 60 m
  m[19] = 0x35; m[20] = 0x33;
  wr_u16(m + 21, 12000);      // 20 min past the hour
  m[23] = 0x05;

  m = d + 3 + 50;             // System: operator location
  m[0] = 0x42;
  m[1] = 0x01;                // dynamic operator location
  wr_i32(m + 2, 378030000);
  wr_i32(m + 6, -1224650000);
  wr_u16(m + 10, 1);          // area count
  wr_u16(m + 18, 2030);       // operator alt 15 m
  wr_i32(m + 20, 238000000);  // system timestamp

  const uint8_t mac[6] = {0x02, 0x00, 0x5E, 0x7E, 0x57, 0x01};
  enqueue_rid(SRC_WIFI_BEACON, mac, -42, s_cur_chan, d, sizeof(d));
}

// -------------------------------------------------------------------- sketch

void setup() {
  Serial.begin(115200);
  uint32_t t0 = millis();
  while (!Serial && millis() - t0 < 3000) delay(10);

  s_q = xQueueCreate(12, sizeof(RidEvt));
  s_ble_ok = ble_start_scanner();  // bring up BT before promiscuous WiFi
  wifi_start_sniffer();

  Serial.printf("{\"type\":\"boot\",\"fw\":\"%s\",\"ver\":\"%s\",\"ble\":%s,"
                "\"ble_ext\":%s}\n",
                FW_NAME, FW_VERSION, s_ble_ok ? "true" : "false",
                s_ble_ext ? "true" : "false");
}

void loop() {
  static uint32_t last_hop = 0, last_hb = 0;
  static size_t hop_idx = 0;
  uint32_t now = millis();

  if (now - last_hop >= HOP_DWELL_MS) {
    last_hop = now;
    hop_idx = (hop_idx + 1) % sizeof(HOP);
    s_cur_chan = HOP[hop_idx];
    esp_wifi_set_channel(s_cur_chan, WIFI_SECOND_CHAN_NONE);
  }

  while (Serial.available()) {
    if (Serial.read() == 't') inject_test_pack();
  }

  RidEvt e;
  while (xQueueReceive(s_q, &e, 0) == pdTRUE) {
    OdidUas u;
    if (decode_payload(e.data, e.len, &u)) {
      s_cnt_rid++;
      emit_rid(&e, &u);
    }
  }

  if (now - last_hb >= 2000) {
    last_hb = now;
    emit_heartbeat();
  }
  ble_maintain();
  delay(5);
}
