// orecchino_sensecap — ASTM F3411 (Open Drone ID) Remote ID sniffer
// Target: Seeed SenseCAP Indicator D1 series (ESP32-S3 + 480x480 LCD)
// Same radio core and serial JSON contract as orecchino_fw, plus an
// on-device track table and drone console rendered on the panel.
//
// Receives Broadcast Remote ID on:
//   * WiFi beacons        — vendor IE, OUI FA:0B:BC, type 0x0D
//   * WiFi NAN SDF        — public action frames, WFA OUI 50:6F:9A / NAN,
//                           service org.opendroneid.remoteid
//   * Bluetooth LE        — service data UUID 0xFFFA, app code 0x0D.
//                           Legacy BT4 ADV plus BT5 extended advertising on
//                           both 1M and coded (long-range) PHY, via
//                           NimBLE-Arduino with CONFIG_BT_NIMBLE_EXT_ADV=1
//                           (see build_opt.h)
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
#include <NimBLEDevice.h>
#include <LittleFS.h>
#include "mbedtls/base64.h"
#include "esp_rom_crc.h"
#include "tracker.h"
#include "display.h"

#define FW_NAME    "orecchino"
#define FW_VERSION "0.3.0"
#define FW_BOARD   "sensecap-indicator"

// ---------------------------------------------------------------- event queue

enum RidSrc : uint8_t { SRC_WIFI_BEACON = 0, SRC_WIFI_NAN = 1, SRC_BLE = 2 };
static const char* SRC_NAMES[] = { "wifi", "nan", "ble" };

// One ODID message is 25 B; a full message pack is 2 + 9*25 = 227 B.
typedef struct {
  uint8_t src;
  uint8_t mac[6];
  int8_t  rssi;
  uint8_t chan;
  uint8_t phy;   // BLE only: 1 = 1M, 2 = 2M, 3 = coded (long range), 0 = n/a
  uint8_t len;
  uint8_t data[232];
} RidEvt;

// TFR polygons pushed by the host app. Defined up here so the Arduino
// preprocessor's hoisted prototypes see the type.
#define TFR_MAX     16
#define TFR_PTS_MAX 24
struct TfrPoly {
  uint8_t n;
  float   lat[TFR_PTS_MAX], lon[TFR_PTS_MAX];
  char    id[16];
};

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
static volatile uint32_t s_cnt_rid_wifi    = 0;  // per-path match counters:
static volatile uint32_t s_cnt_rid_nan     = 0;  // "why no NAN?" is the
static volatile uint32_t s_cnt_rid_ble     = 0;  // first field question
static volatile uint32_t s_cnt_pfail       = 0;  // matched but failed decode
static volatile uint32_t s_cnt_dropped     = 0;
static volatile uint8_t  s_cur_chan        = 6;
static bool s_ble_ok  = false;
static bool s_ble_ext = false;

// Callbacks run in the WiFi / Bluedroid task context: copy out and return.
static void enqueue_rid(uint8_t src, const uint8_t* mac, int8_t rssi,
                        uint8_t chan, uint8_t phy, const uint8_t* odid, int len) {
  if (len < 25 || !s_q) return;
  if (src == SRC_WIFI_BEACON) s_cnt_rid_wifi++;
  else if (src == SRC_WIFI_NAN) s_cnt_rid_nan++;
  else s_cnt_rid_ble++;
  RidEvt e;
  e.src  = src;
  memcpy(e.mac, mac, 6);
  e.rssi = rssi;
  e.chan = chan;
  e.phy  = phy;
  if (len > (int)sizeof(e.data)) len = sizeof(e.data);
  e.len  = len;
  memcpy(e.data, odid, len);
  if (xQueueSend(s_q, &e, 0) != pdTRUE) s_cnt_dropped++;
}

// ------------------------------------------------------------- WiFi sniffing

// NAN is spec-locked to the channel 6 social channel, so park there 75% of
// the time; brief visits to 1 and 11 cover beacon RID on the rest of the
// band (20 MHz-wide channels on 5 MHz spacing: {1,6,11} hears everything).
typedef struct { uint8_t chan; uint16_t dwell_ms; } HopSlot;
static const HopSlot HOP[] = { {6, 600}, {1, 200}, {6, 600}, {11, 200} };
static const size_t HOP_N = sizeof(HOP) / sizeof(HOP[0]);

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

  if (stype == 0x80 || stype == 0x50) {
    // Beacon or probe response: 24 B header + 12 B fixed params, then IEs.
    int off = 36;
    while (off + 2 <= len) {
      uint8_t id = d[off], l = d[off + 1];
      if (off + 2 + l > len) break;
      const uint8_t* ie = d + off + 2;
      // Vendor specific, type 0x0D, then [counter][ODID].
      // OUIs: FA:0B:BC (ASD-STAN) and 90:3A:E6 (Parrot), same payload.
      if (id == 221 && l >= 30 && ie[3] == 0x0D &&
          ((ie[0] == 0xFA && ie[1] == 0x0B && ie[2] == 0xBC) ||
           (ie[0] == 0x90 && ie[1] == 0x3A && ie[2] == 0xE6))) {
        enqueue_rid(SRC_WIFI_BEACON, sa, p->rx_ctrl.rssi, p->rx_ctrl.channel,
                    0, ie + 5, l - 5);
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
                  0, b + i + 11, n);
      break;
    }
  }
}

static void wifi_start_sniffer() {
  WiFi.mode(WIFI_STA);
  WiFi.disconnect();
  esp_wifi_set_ps(WIFI_PS_NONE);  // modem sleep gates promiscuous RX
  delay(100);
  wifi_promiscuous_filter_t filt = {};
  filt.filter_mask = WIFI_PROMIS_FILTER_MASK_MGMT;
  esp_wifi_set_promiscuous_filter(&filt);
  esp_wifi_set_promiscuous_rx_cb(&wifi_cb);
  esp_wifi_set_promiscuous(true);
  esp_wifi_set_channel(HOP[0].chan, WIFI_SECOND_CHAN_NONE);
  s_cur_chan = HOP[0].chan;
}

// -------------------------------------------------------------- BLE scanning

static void handle_adv(const uint8_t* addr, int rssi, uint8_t phy,
                       const uint8_t* data, int len) {
  s_cnt_ble_advs++;
  int i = 0;
  while (i + 1 < len) {
    uint8_t l = data[i];             // AD length: type byte + payload
    if (l == 0 || i + 1 + l > len) break;
    uint8_t t = data[i + 1];
    if (l >= 30) {
      const uint8_t* sd = data + i + 2;
      // Service Data 16-bit, UUID 0xFFFA (ASTM), app code 0x0D — or the
      // draft-era manufacturer-specific layout, mfg code 0x0200, same 0x0D.
      bool svc = t == 0x16 && sd[0] == 0xFA && sd[1] == 0xFF && sd[2] == 0x0D;
      bool mfg = t == 0xFF && sd[0] == 0x00 && sd[1] == 0x02 && sd[2] == 0x0D;
      if (svc || mfg) {
        // sd[3] = message counter, sd+4 = ODID message or pack
        enqueue_rid(SRC_BLE, addr, rssi, 0, phy, sd + 4, l - 5);
      }
    }
    i += 1 + l;
  }
}

static NimBLEScan* s_scan = nullptr;

class RidScanCallbacks : public NimBLEScanCallbacks {
  void onResult(const NimBLEAdvertisedDevice* dev) override {
    uint8_t mac[6];
    const uint8_t* v = dev->getAddress().getVal();  // NimBLE: LSB first
    for (int i = 0; i < 6; i++) mac[i] = v[5 - i];
    uint8_t phy = 0;
#if CONFIG_BT_NIMBLE_EXT_ADV
    phy = dev->getPrimaryPhy();                     // 1 = 1M, 3 = coded
    if (dev->getSecondaryPhy() == 3) phy = 3;       // payload rode long range
#endif
    const std::vector<uint8_t>& p = dev->getPayload();
    handle_adv(mac, dev->getRSSI(), phy, p.data(), (int)p.size());
  }

  void onScanEnd(const NimBLEScanResults&, int) override {
    if (s_scan) s_scan->start(0, false, true);  // forever means forever
  }
};

static bool ble_start_scanner() {
  NimBLEDevice::init("");
  s_scan = NimBLEDevice::getScan();
  if (!s_scan) return false;
  static RidScanCallbacks cb;
  // duplicates on: repeated advertisements carry fresh Location messages
  s_scan->setScanCallbacks(&cb, true);
  s_scan->setActiveScan(false);
  s_scan->setDuplicateFilter(0);
  s_scan->setMaxResults(0);  // callbacks only — nothing stored, nothing leaks
  s_scan->setInterval(50);   // ms
  s_scan->setWindow(25);     // ms — leave air time for WiFi coex
#if CONFIG_BT_NIMBLE_EXT_ADV
  s_ble_ext = true;          // scanning 1M + coded PHY (SCAN_ALL default)
#endif
  return s_scan->start(0 /* forever */, false, true);
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
  if (e->src == SRC_BLE && e->phy)
    jput(",\"phy\":\"%s\"", e->phy == 3 ? "coded" : (e->phy == 2 ? "2m" : "1m"));

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
                "\"rid\":%lu,\"rid_w\":%lu,\"rid_n\":%lu,\"rid_b\":%lu,"
                "\"pfail\":%lu,\"dropped\":%lu,\"ch\":%u,\"ble\":%s,\"ble_ext\":%s,"
                "\"heap\":%lu}\n",
                (unsigned long)millis(),
                (unsigned long)s_cnt_wifi_frames, (unsigned long)s_cnt_ble_advs,
                (unsigned long)s_cnt_rid, (unsigned long)s_cnt_rid_wifi,
                (unsigned long)s_cnt_rid_nan, (unsigned long)s_cnt_rid_ble,
                (unsigned long)s_cnt_pfail, (unsigned long)s_cnt_dropped,
                s_cur_chan, s_ble_ok ? "true" : "false",
                s_ble_ext ? "true" : "false",
                (unsigned long)ESP.getFreeHeap());
}

// -------------------------------------------------- RP2040 link (buzzer)
// The Indicator's second MCU owns the buzzer (and sensors). Seeed's stock
// RP2040 firmware speaks COBS-framed packets on the S3<->RP2040 UART:
// TX=19 RX=20 @115200, PKT_TYPE_CMD_BEEP_ON=0xA1 with uint32 on-time ms.

static size_t cobs_encode_buf(const uint8_t* in, size_t len, uint8_t* out) {
  size_t wi = 1, code_i = 0;
  uint8_t code = 1;
  for (size_t ri = 0; ri < len; ri++) {
    uint8_t b = in[ri];
    if (b == 0) {
      out[code_i] = code;
      code_i = wi++;
      code = 1;
    } else {
      out[wi++] = b;
      if (++code == 0xFF) {
        out[code_i] = code;
        code_i = wi++;
        code = 1;
      }
    }
  }
  out[code_i] = code;
  return wi;
}

static void rp2040_cmd(uint8_t type, uint32_t val) {
  uint8_t raw[5] = { type };
  memcpy(raw + 1, &val, 4);
  uint8_t enc[12];
  size_t n = cobs_encode_buf(raw, 5, enc);
  enc[n++] = 0x00;
  Serial1.write(enc, n);
}

static uint8_t  s_beeps_left = 0;
static uint32_t s_next_beep_ms = 0;

static void beep_pattern(uint8_t n) { s_beeps_left = n; }

static void beep_tick(uint32_t now) {
  if (s_beeps_left && (int32_t)(now - s_next_beep_ms) >= 0) {
    rp2040_cmd(0xA1 /* BEEP_ON */, 90);
    s_beeps_left--;
    s_next_beep_ms = now + 220;
  }
}

// ---------------------------------------------- host context (home + TFRs)
// Orecchino.app pushes the operator's location for ranging and nearby FAA
// TFR polygons (refreshed on connect and daily). Held in RAM; the app
// re-pushes on every connection.

bool   g_home_set = false;
double g_home_lat = 0, g_home_lon = 0;

static TfrPoly s_tfrs[TFR_MAX];
static uint8_t s_tfr_n = 0;

static bool poly_contains(const TfrPoly* p, double lat, double lon) {
  bool in = false;
  for (int i = 0, j = p->n - 1; i < p->n; j = i++) {
    if (((p->lat[i] > lat) != (p->lat[j] > lat)) &&
        (lon < (double)(p->lon[j] - p->lon[i]) * (lat - p->lat[i]) /
                       (double)(p->lat[j] - p->lat[i]) + p->lon[i]))
      in = !in;
  }
  return in;
}

static bool tfr_lookup(double lat, double lon, char* id, size_t idsz) {
  for (int i = 0; i < s_tfr_n; i++) {
    if (poly_contains(&s_tfrs[i], lat, lon)) {
      strncpy(id, s_tfrs[i].id, idsz - 1);
      id[idsz - 1] = 0;
      return true;
    }
  }
  return false;
}

// ----------------------------------------------------- host tile-sync link
// Line-based protocol so Orecchino.app can push map tiles over the same
// serial port the JSON feed uses. Chunks are base64 in JSON lines, acked
// one at a time; files are CRC32-verified. Writes are restricted to /tiles.

static File     s_fs_file;
static uint32_t s_fs_crc = 0;
static uint32_t s_fs_last_ms = 0;   // display pauses while a sync is active
static uint32_t s_fs_files_done = 0;

bool fs_sync_busy(uint32_t now) { return now - s_fs_last_ms < 2000; }

static void fs_world_px(double lat, double lon, int z, double* wx, double* wy) {
  double n = 256.0 * (double)(1L << z);
  *wx = (lon + 180.0) / 360.0 * n;
  double rad = lat * M_PI / 180.0;
  *wy = (1.0 - log(tan(rad) + 1.0 / cos(rad)) / M_PI) / 2.0 * n;
}

// Storage self-management: when a write needs room, drop the least valuable
// tile — highest zoom first (cheapest to lose), then farthest from where
// the map is currently looking. The renderer tolerates missing tiles.
static bool evict_one_tile() {
  double clat, clon;
  bool has_center = display_map_center(&clat, &clon);
  char victim[80] = "";
  double best = -1;
  File root = LittleFS.open("/tiles");
  if (!root) return false;
  for (File zd = root.openNextFile(); zd; zd = root.openNextFile()) {
    if (!zd.isDirectory()) continue;
    int z = atoi(zd.name());
    double cwx = 0, cwy = 0;
    if (has_center) fs_world_px(clat, clon, z, &cwx, &cwy);
    for (File xd = zd.openNextFile(); xd; xd = zd.openNextFile()) {
      if (!xd.isDirectory()) continue;
      long x = atol(xd.name());
      for (File f = xd.openNextFile(); f; f = xd.openNextFile()) {
        if (f.isDirectory()) continue;
        long y = atol(f.name());
        double score = (double)z * 1e12;
        if (has_center) {
          double dx = ((double)x + 0.5) * 256 - cwx;
          double dy = ((double)y + 0.5) * 256 - cwy;
          score += dx * dx + dy * dy;
        } else {
          score += (double)x + (double)y;
        }
        if (score > best) {
          best = score;
          snprintf(victim, sizeof(victim), "/tiles/%d/%ld/%s", z, x, f.name());
        }
      }
    }
  }
  if (!victim[0]) return false;
  LittleFS.remove(victim);
  Serial.printf("{\"type\":\"fs_evict\",\"p\":\"%s\"}\n", victim);
  return true;
}

static bool json_field_str(const char* line, const char* key, char* out, size_t n) {
  char pat[24];
  snprintf(pat, sizeof(pat), "\"%s\":\"", key);
  const char* p = strstr(line, pat);
  if (!p) return false;
  p += strlen(pat);
  size_t o = 0;
  while (*p && *p != '"' && o + 1 < n) out[o++] = *p++;
  out[o] = 0;
  return *p == '"';
}

static bool json_field_u32(const char* line, const char* key, uint32_t* out) {
  char pat[24];
  snprintf(pat, sizeof(pat), "\"%s\":", key);
  const char* p = strstr(line, pat);
  if (!p) return false;
  *out = strtoul(p + strlen(pat), nullptr, 10);
  return true;
}

static bool json_field_dbl(const char* line, const char* key, double* out) {
  char pat[24];
  snprintf(pat, sizeof(pat), "\"%s\":", key);
  const char* p = strstr(line, pat);
  if (!p) return false;
  *out = strtod(p + strlen(pat), nullptr);
  return true;
}

static void fs_mkdirs(const char* path) {
  char tmp[72];
  strncpy(tmp, path, sizeof(tmp) - 1);
  tmp[sizeof(tmp) - 1] = 0;
  for (char* p = tmp + 1; *p; p++) {
    if (*p == '/') {
      *p = 0;
      LittleFS.mkdir(tmp);
      *p = '/';
    }
  }
}

static void fs_ls_walk(File dir, uint32_t* n) {
  for (File f = dir.openNextFile(); f; f = dir.openNextFile()) {
    if (f.isDirectory()) {
      fs_ls_walk(f, n);
    } else {
      Serial.printf("{\"type\":\"fs_f\",\"p\":\"%s\",\"s\":%u}\n",
                    f.path(), (unsigned)f.size());
      (*n)++;
    }
  }
}

static void handle_host_line(char* line, uint32_t now) {
  char cmd[16];
  if (!json_field_str(line, "cmd", cmd, sizeof(cmd))) return;
  s_fs_last_ms = now;

  if (!strcmp(cmd, "fs_info")) {
    Serial.printf("{\"type\":\"fs_info\",\"total\":%u,\"used\":%u}\n",
                  (unsigned)LittleFS.totalBytes(), (unsigned)LittleFS.usedBytes());
  } else if (!strcmp(cmd, "fs_ls")) {
    uint32_t n = 0;
    File root = LittleFS.open("/tiles");
    if (root) fs_ls_walk(root, &n);
    Serial.printf("{\"type\":\"fs_ls_done\",\"n\":%u}\n", (unsigned)n);
  } else if (!strcmp(cmd, "fs_begin")) {
    char path[72];
    if (!json_field_str(line, "p", path, sizeof(path)) ||
        strncmp(path, "/tiles/", 7) != 0) {
      Serial.println("{\"type\":\"fs_err\",\"msg\":\"bad path\"}");
      return;
    }
    if (s_fs_file) s_fs_file.close();
    uint32_t size = 0;
    json_field_u32(line, "size", &size);
    uint32_t needed = size + 16384;  // block-granularity + metadata margin
    while (LittleFS.totalBytes() - LittleFS.usedBytes() < needed) {
      if (!evict_one_tile()) {
        Serial.println("{\"type\":\"fs_err\",\"msg\":\"full\"}");
        return;
      }
    }
    fs_mkdirs(path);
    s_fs_file = LittleFS.open(path, "w");
    s_fs_crc = 0;
    if (!s_fs_file) {
      Serial.println("{\"type\":\"fs_err\",\"msg\":\"open failed\"}");
      return;
    }
    Serial.println("{\"type\":\"ack\",\"q\":0}");
  } else if (!strcmp(cmd, "fs_data")) {
    uint32_t seq = 0;
    json_field_u32(line, "q", &seq);
    const char* p = strstr(line, "\"b64\":\"");
    if (!s_fs_file || !p) {
      Serial.println("{\"type\":\"fs_err\",\"msg\":\"no file/data\"}");
      return;
    }
    p += 7;
    const char* e = strchr(p, '"');
    if (!e) return;
    static uint8_t raw[1024];
    size_t rawlen = 0;
    if (mbedtls_base64_decode(raw, sizeof(raw), &rawlen, (const uint8_t*)p,
                              e - p) != 0) {
      Serial.println("{\"type\":\"fs_err\",\"msg\":\"b64\"}");
      return;
    }
    s_fs_file.write(raw, rawlen);
    s_fs_crc = esp_rom_crc32_le(s_fs_crc, raw, rawlen);
    Serial.printf("{\"type\":\"ack\",\"q\":%u}\n", (unsigned)seq);
  } else if (!strcmp(cmd, "fs_end")) {
    uint32_t want = 0;
    json_field_u32(line, "crc", &want);
    if (!s_fs_file) return;
    char path[72];
    strncpy(path, s_fs_file.path(), sizeof(path) - 1);
    path[sizeof(path) - 1] = 0;
    s_fs_file.close();
    if (want == s_fs_crc) {
      s_fs_files_done++;
      Serial.printf("{\"type\":\"fs_ok\",\"p\":\"%s\"}\n", path);
    } else {
      LittleFS.remove(path);
      Serial.printf("{\"type\":\"fs_err\",\"msg\":\"crc\",\"p\":\"%s\"}\n", path);
    }
  } else if (!strcmp(cmd, "fs_rm")) {
    char path[72];
    if (json_field_str(line, "p", path, sizeof(path)) &&
        strncmp(path, "/tiles/", 7) == 0) {
      LittleFS.remove(path);
      Serial.printf("{\"type\":\"fs_ok\",\"p\":\"%s\"}\n", path);
    }
  } else if (!strcmp(cmd, "set_home")) {
    if (json_field_dbl(line, "lat", &g_home_lat) &&
        json_field_dbl(line, "lon", &g_home_lon))
      g_home_set = true;
  } else if (!strcmp(cmd, "tfr_clear")) {
    s_tfr_n = 0;
  } else if (!strcmp(cmd, "tfr_add")) {
    if (s_tfr_n >= TFR_MAX) return;
    TfrPoly* poly = &s_tfrs[s_tfr_n];
    poly->n = 0;
    json_field_str(line, "id", poly->id, sizeof(poly->id));
    const char* q = strstr(line, "\"pts\":[");
    if (!q) return;
    q += 7;
    while (poly->n < TFR_PTS_MAX) {
      q = strchr(q, '[');
      if (!q) break;
      q++;
      char* end;
      double la = strtod(q, &end);
      if (end == q) break;
      q = strchr(end, ',');
      if (!q) break;
      q++;
      double lo = strtod(q, &end);
      if (end == q) break;
      poly->lat[poly->n] = (float)la;
      poly->lon[poly->n] = (float)lo;
      poly->n++;
      q = strchr(end, ']');
      if (!q) break;
      q++;
    }
    if (poly->n >= 3) s_tfr_n++;
  }
}

static void poll_host_serial(uint32_t now) {
  static char buf[1600];
  static int len = 0;
  while (Serial.available()) {
    char c = (char)Serial.read();
    if (c == '\n' || c == '\r') {
      if (len > 0) {
        buf[len] = 0;
        handle_host_line(buf, now);
        len = 0;
      }
    } else if (len < (int)sizeof(buf) - 1) {
      buf[len++] = c;
    } else {
      len = 0;  // oversized line: drop
    }
  }
}

// ------------------------------------------------------------- track ingest

uint32_t g_seen_count = 0;

static void tracker_ingest(const RidEvt* e, const OdidUas* u, uint32_t now) {
  const char* uas = (u->has_basic[0] && u->uas_id[0][0]) ? u->uas_id[0] : nullptr;
  bool created = false;
  Track* t = tracker_upsert(e->mac, uas, now, &created);
  if (created) g_seen_count++;
  t->rssi = e->rssi;
  if (e->rssi > t->peak_rssi) t->peak_rssi = e->rssi;
  t->src_mask |= (uint8_t)(1u << e->src);
  if (u->has_loc) {
    t->status = u->status;
    if (u->lat != 0 || u->lon != 0) {
      t->has_pos = true;
      t->lat = u->lat;
      t->lon = u->lon;
    }
    if (u->height > -999) {
      t->height = u->height;
      if (isnan(t->max_height) || u->height > t->max_height)
        t->max_height = u->height;
    }
    if (u->speed >= 0) t->speed = u->speed;
    if (u->dir >= 0 && u->dir <= 360) t->heading = u->dir;
    if (t->has_pos) {
      bool was = t->in_tfr;
      t->in_tfr = tfr_lookup(t->lat, t->lon, t->tfr_id, sizeof(t->tfr_id));
      if (t->in_tfr) t->tfr_ever = true;
      if (t->in_tfr && !was) beep_pattern(3);  // three short: TFR incursion
    }
  }
}

// Expire cold tracks, emitting a detection record for the host's archive.
static void tracker_expire_emit(uint32_t now) {
  for (int i = 0; i < TRK_MAX; i++) {
    Track* t = &g_tracks[i];
    if (!t->used || now - t->last_ms <= TRK_EXPIRE_MS) continue;
    char mh[12] = "null";
    if (!isnan(t->max_height)) snprintf(mh, sizeof(mh), "%d", (int)t->max_height);
    Serial.printf("{\"type\":\"track_end\",\"uas\":\"%s\","
                  "\"mac\":\"%02X:%02X:%02X:%02X:%02X:%02X\","
                  "\"first_ms\":%lu,\"last_ms\":%lu,\"peak_rssi\":%d,"
                  "\"max_height\":%s,\"tfr\":%s}\n",
                  t->uas, t->mac[0], t->mac[1], t->mac[2], t->mac[3],
                  t->mac[4], t->mac[5], (unsigned long)t->first_ms,
                  (unsigned long)t->last_ms, t->peak_rssi, mh,
                  t->tfr_ever ? "true" : "false");
    t->used = false;
  }
}

// -------------------------------------------------------------------- sketch

void setup() {
  Serial.begin(460800);  // real UART via CH340 — 4x faster tile sync
  Serial1.begin(115200, SERIAL_8N1, 20 /* RX */, 19 /* TX */);  // RP2040 link
  uint32_t t0 = millis();
  while (!Serial && millis() - t0 < 3000) delay(10);

  // Format-on-fail: a virgin device self-provisions — the app's tile sync
  // fills an empty filesystem, no esptool image needed.
  LittleFS.begin(true, "/littlefs", 10, "littlefs");

  s_q = xQueueCreate(12, sizeof(RidEvt));
  s_ble_ok = ble_start_scanner();  // bring up BT before promiscuous WiFi
  wifi_start_sniffer();
  s_cur_chan = HOP[0].chan;

  bool disp = display_begin();
  Serial.printf("{\"type\":\"boot\",\"fw\":\"%s\",\"ver\":\"%s\",\"board\":\"%s\","
                "\"ble\":%s,\"ble_ext\":%s,\"display\":%s}\n",
                FW_NAME, FW_VERSION, FW_BOARD, s_ble_ok ? "true" : "false",
                s_ble_ext ? "true" : "false", disp ? "true" : "false");
}

void loop() {
  static uint32_t last_hop = 0, last_hb = 0;
  static size_t hop_idx = 0;
  uint32_t now = millis();

  if (now - last_hop >= HOP[hop_idx].dwell_ms) {
    last_hop = now;
    hop_idx = (hop_idx + 1) % HOP_N;
    s_cur_chan = HOP[hop_idx].chan;
    esp_wifi_set_channel(s_cur_chan, WIFI_SECOND_CHAN_NONE);
  }

  poll_host_serial(now);

  RidEvt e;
  while (xQueueReceive(s_q, &e, 0) == pdTRUE) {
    OdidUas u;
    if (decode_payload(e.data, e.len, &u)) {
      s_cnt_rid++;
      emit_rid(&e, &u);
      tracker_ingest(&e, &u, now);
    } else {
      s_cnt_pfail++;
    }
  }

  display_tick(now);
  beep_tick(now);

  // During a tile sync the map pauses; show transfer progress instead of a
  // frozen frame.
  static uint32_t sync_files = 0;
  static bool was_syncing = false;
  if (fs_sync_busy(now)) {
    was_syncing = true;
    sync_files = s_fs_files_done;
    display_sync_status(sync_files);
  } else if (was_syncing) {
    was_syncing = false;
    s_fs_files_done = 0;
    display_force_redraw();
  }

  static uint32_t last_draw = 0;
  if (now - last_draw >= 1000 && !fs_sync_busy(now)) {
    last_draw = now;
    tracker_expire_emit(now);
    DisplayStats st;
    st.wifi_frames = s_cnt_wifi_frames;
    st.ble_advs    = s_cnt_ble_advs;
    st.rid         = s_cnt_rid;
    st.dropped     = s_cnt_dropped;
    st.channel     = s_cur_chan;
    st.ble_ok      = s_ble_ok;
    st.ble_ext     = s_ble_ext;
    st.heap        = ESP.getFreeHeap();
    display_render(g_tracks, TRK_MAX, st, now);
  }

  if (now - last_hb >= 2000) {
    last_hb = now;
    emit_heartbeat();
  }
  delay(5);
}
