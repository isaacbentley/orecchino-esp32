// orecchino_fw — ASTM F3411 (Open Drone ID) Remote ID sniffer
// Target: Seeed Studio XIAO ESP32-C3 (esp32:esp32:XIAO_ESP32C3)
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
#include "../common/odid_decode.h"
#include "tracker.h"

#define FW_NAME    "orecchino"
#define FW_VERSION "0.4.1"
#define FW_BOARD   "xiao-esp32c3"

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

// TFR polygons pushed by the host app (defined up here so the hoisted
// prototypes see the type).
#define TFR_MAX     16
#define TFR_PTS_MAX 24
struct TfrPoly {
  uint8_t n;
  float   lat[TFR_PTS_MAX], lon[TFR_PTS_MAX];
  char    id[16];
};

static QueueHandle_t s_q;
static volatile uint32_t s_cnt_wifi_frames = 0;
static volatile uint32_t s_cnt_ble_advs    = 0;
static volatile uint32_t s_cnt_rid         = 0;
static volatile uint32_t s_cnt_rid_wifi    = 0;  // per-path match counters:
static volatile uint32_t s_cnt_rid_nan     = 0;  // "why no NAN?" is the
static volatile uint32_t s_cnt_rid_ble     = 0;  // first field question
static volatile uint32_t s_cnt_pfail       = 0;  // matched but failed decode
static volatile uint32_t s_cnt_dropped     = 0;
static uint32_t          s_seen_count      = 0;  // unique drones since boot
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

// ODID decoding lives in firmware/common/odid_decode.h (shared with
// the host-side unit tests in tests/).

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
    jput(",\"speed\":%.2f,\"dir\":%.0f,\"ts\":%.1f",
         u->speed, u->dir, u->ts);
    if (u->vspeed > -900) jput(",\"vspeed\":%.2f", u->vspeed);
    jput("}");
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
                "\"pfail\":%lu,\"dropped\":%lu,\"seen\":%lu,\"ch\":%u,"
                "\"ble\":%s,\"ble_ext\":%s,\"heap\":%lu}\n",
                (unsigned long)millis(),
                (unsigned long)s_cnt_wifi_frames, (unsigned long)s_cnt_ble_advs,
                (unsigned long)s_cnt_rid, (unsigned long)s_cnt_rid_wifi,
                (unsigned long)s_cnt_rid_nan, (unsigned long)s_cnt_rid_ble,
                (unsigned long)s_cnt_pfail, (unsigned long)s_cnt_dropped,
                (unsigned long)s_seen_count, s_cur_chan,
                s_ble_ok ? "true" : "false", s_ble_ext ? "true" : "false",
                (unsigned long)ESP.getFreeHeap());
}

// ---------------------------------------------- host context (home + TFRs)
// Same line protocol as the SenseCAP target, so the desktop app can treat
// any orecchino receiver identically.

static bool   s_home_set = false;
static double s_home_lat = 0, s_home_lon = 0;
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

static bool json_field_dbl(const char* line, const char* key, double* out) {
  char pat[24];
  snprintf(pat, sizeof(pat), "\"%s\":", key);
  const char* p = strstr(line, pat);
  if (!p) return false;
  *out = strtod(p + strlen(pat), nullptr);
  return true;
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
  enqueue_rid(SRC_WIFI_BEACON, mac, -42, s_cur_chan, 0, d, sizeof(d));
}

// ------------------------------------------------------ track ingest + host

static void tracker_ingest(const RidEvt* e, const OdidUas* u, uint32_t now) {
  const char* uas = (u->has_basic[0] && u->uas_id[0][0]) ? u->uas_id[0] : nullptr;
  bool created = false;
  Track* t = tracker_upsert(e->mac, uas, now, &created);
  if (created) s_seen_count++;
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
      t->in_tfr = tfr_lookup(t->lat, t->lon, t->tfr_id, sizeof(t->tfr_id));
      if (t->in_tfr) t->tfr_ever = true;
    }
  }
}

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

static void handle_host_line(char* line, uint32_t now) {
  if (!strcmp(line, "t")) {  // dev harness: inject a synthetic pack
    inject_test_pack();
    return;
  }
  char cmd[16];
  if (!json_field_str(line, "cmd", cmd, sizeof(cmd))) return;
  if (!strcmp(cmd, "set_home")) {
    if (json_field_dbl(line, "lat", &s_home_lat) &&
        json_field_dbl(line, "lon", &s_home_lon))
      s_home_set = true;
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

// -------------------------------------------------------------------- sketch

void setup() {
  Serial.begin(115200);
  uint32_t t0 = millis();
  while (!Serial && millis() - t0 < 3000) delay(10);

  s_q = xQueueCreate(12, sizeof(RidEvt));
  s_ble_ok = ble_start_scanner();  // bring up BT before promiscuous WiFi
  wifi_start_sniffer();
  s_cur_chan = HOP[0].chan;

  Serial.printf("{\"type\":\"boot\",\"fw\":\"%s\",\"ver\":\"%s\",\"board\":\"%s\","
                "\"ble\":%s,\"ble_ext\":%s}\n",
                FW_NAME, FW_VERSION, FW_BOARD, s_ble_ok ? "true" : "false",
                s_ble_ext ? "true" : "false");
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
    if (odid_decode_payload(e.data, e.len, &u)) {
      s_cnt_rid++;
      emit_rid(&e, &u);
      tracker_ingest(&e, &u, now);
    } else {
      s_cnt_pfail++;
    }
  }

  static uint32_t last_expire = 0;
  if (now - last_expire >= 5000) {
    last_expire = now;
    tracker_expire_emit(now);
  }

  if (now - last_hb >= 2000) {
    last_hb = now;
    emit_heartbeat();
  }
  delay(5);
}
