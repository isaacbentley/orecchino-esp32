// Orecchino test-beacon core — a Remote ID transmitter for bench-testing
// receivers. One engine for every board: ten aircraft across five air
// interfaces and five format variants, each its own contact so a receiver's
// list is a capability report; real Ed25519 Authentication with a published
// test key (and one deliberately corrupted signature). A board sketch
// includes this header and calls tx_begin() / tx_tick(); a UI drives the
// per-path enable mask and the rate through the tx_* accessors at the end.
//
// On the boards the radios are driven by a task of their own (tx_task), so a
// screen that holds the loop -- an e-paper refresh takes up to 1.5 s --
// never holds a transmission back. The loop only reads the serial console
// and prints the status line.
//
// This is test equipment. It is not a compliant Remote ID transmitter, its
// identities say so on the air, and it must only be run where you are
// allowed to radiate on 2.4 GHz for testing.
#pragma once
#include <Arduino.h>
#include <WiFi.h>
#include <Preferences.h>
#include <NimBLEDevice.h>
#include <stdarg.h>
#include "esp_wifi.h"
#include "odid_build.h"
#include "odid_auth.h"
#if defined(ESP_PLATFORM)
#include <sys/time.h>
#include "esp_timer.h"
#endif

#define TX_NAME      "orecchino-tx"
#define TX_VERSION   "0.4.0"
#define WIFI_CHANNEL 6      // Open Drone ID default / NAN social channel
#define ORBIT_M      50.0   // each aircraft's own little circle
#define TX_WIFI_QDBM 80     // Wi-Fi TX power in 0.25 dBm: 20 dBm, the chip's maximum
#define TX_BLE_DBM   20     // BLE TX power: +20 dBm, the ESP32-C3/S3 maximum

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

// ---------------------------------------------------------------- rates

// ASTM F3411-22a asks a broadcast transmitter for the dynamic (Location)
// message at least once a second and each static message (Basic ID, Self
// ID, System, Operator ID) at least every 3 s, on every transport it uses.
// SPEC is comfortably inside that, with headroom for a receiver that hops
// channels (ours listens on channel 6 for 1.2 s of every 1.6) or scans BLE
// 30 ms in 100. SLOW is the old quiet bench mode: every path once every 5 s.
typedef struct {
  uint16_t pack_ms;      // Wi-Fi beacon: one message pack per path
  uint16_t single_ms;    // Wi-Fi SINGLE: one message per frame, odid_single_seq order
  uint16_t nan_ms;       // Wi-Fi NAN service discovery frame (message pack)
  uint16_t nan_sync_ms;  // NAN synchronisation beacon
  uint16_t ext_itvl_ms;  // BLE5 1M advertising interval (a pack every event)
  uint16_t lr_itvl_ms;   // BLE5 coded advertising interval
  uint16_t ext_data_ms;  // a fresh pack (new Location) into a BLE5 set
  uint16_t leg_itvl_ms;  // BLE4 legacy advertising interval
  uint16_t leg_msg_ms;   // BLE4: how long each rotated message stays on air
  uint16_t share_ms;     // BLE5 1M and coded sharing one set: each one's turn
} TxRate;
enum { TX_RATE_SPEC = 0, TX_RATE_SLOW = 1 };
static const TxRate TX_RATES[2] = {
  { 250, 125, 250, 500, 100, 150, 250, 50, 200, 500 },
  { 5000, 5000, 5000, 5000, 5000, 5000, 5000, 5000, 5000, 2500 },
};

// Flight sim defaults: Crissy Field.
static double s_home_lat = 37.8039;
static double s_home_lon = -122.4640;
static double s_ring_m   = 201.0;   // 1/8 mile between the aircraft
static double s_speed_ms = 8.0;

// Written by the UI and the console, read by the radio task: single bytes,
// so each read sees a whole value. The radio task reconciles the radios
// with them within one pass (2 ms).
static volatile bool    s_running   = true;
static volatile bool    s_enabled[P_COUNT] = { true, true, true, true, true, true, true, true, true, true };
static volatile bool    s_emergency = false;
static volatile uint8_t s_rate      = TX_RATE_SPEC;

static uint8_t  s_counter[P_COUNT] = {0};         // ODID message counter, per path
static volatile uint32_t s_tx[P_COUNT]      = {0}; // payloads put on the air
static volatile uint32_t s_err[P_COUNT]     = {0}; // failed attempts
static volatile uint32_t s_last_ok[P_COUNT] = {0}; // millis() of the last success

// Radio health, reported on the status line.
static bool     s_txw_ok = false, s_txb_ok = false;
static volatile uint32_t s_wifi_err = 0;          // esp_wifi_80211_tx refused a frame
static volatile int      s_wifi_rc  = 0;          // ...and its last error code
static volatile uint32_t s_wifi_done_ok = 0, s_wifi_done_fail = 0;  // driver's TX-done reports
static volatile int      s_wifi_rate = -1;        // wifi_phy_rate_t of the last frame (0 = 1 Mbps)
static volatile uint32_t s_nan_sync = 0;          // NAN sync beacons sent
static volatile uint8_t  s_ch = 0;                // channel read back from the driver
static volatile uint32_t s_ch_fix = 0;            // times it had drifted and was put back
static volatile uint32_t s_ble_restarts = 0;      // in-place data updates that needed a restart
static volatile uint32_t s_err_n = 0;             // every failure, all paths
static char s_err_line[160] = {0};                // the last one, as a tx_err line

// The radio task and the loop share the flight model (home, ring) and the
// error line. On the host there is no task and the lock is a no-op.
#if defined(ESP_PLATFORM)
#define TX_TASK 1
static SemaphoreHandle_t s_tx_mx = nullptr;
static inline void tx_lock()   { if (s_tx_mx) xSemaphoreTake(s_tx_mx, portMAX_DELAY); }
static inline void tx_unlock() { if (s_tx_mx) xSemaphoreGive(s_tx_mx); }
#else
#define TX_TASK 0
static inline void tx_lock() {}
static inline void tx_unlock() {}
#endif
static bool s_task_running = false;

static void tx_note_err(int pid, const char* op, int rc) {
  if (pid >= 0 && pid < P_COUNT) s_err[pid] += 1;
  s_err_n += 1;
  snprintf(s_err_line, sizeof(s_err_line),
           "{\"type\":\"tx_err\",\"path\":\"%s\",\"op\":\"%s\",\"rc\":%d,\"errors\":%lu}\n",
           (pid >= 0 && pid < P_COUNT) ? PATHS[pid].uas_id : "-", op, rc,
           (unsigned long)s_err_n);
}

// Keep a fixed cadence: the next slot is one period after the last, unless
// we have fallen more than a period behind, when it restarts from now.
static inline void tx_advance(uint32_t* last, uint32_t period, uint32_t now) {
  *last = (now - *last < 2 * period) ? *last + period : now;
}

// ------------------------------------------------------------ flight model

// ODID timestamps (System, Authentication) count seconds from 2019-01-01
// 00:00 UTC. Once the wall clock is set (a host's set_time, an RTC) they
// use it; before that uptime, which a receiver shows as early January 2019
// -- plainly "clock not set" rather than a plausible wrong date.
#define ODID_EPOCH_UTC 1546300800UL
#if !defined(ESP_PLATFORM)
static uint32_t s_tx_test_utc = 0;   // host tests stand in for time()
#endif
static uint32_t tx_wall_utc() {
#if defined(ESP_PLATFORM)
  time_t t = time(nullptr);
  return t > (time_t)(ODID_EPOCH_UTC + 86400) ? (uint32_t)t : 0;
#else
  return s_tx_test_utc;
#endif
}
static uint32_t tx_odid_ts(uint32_t now_ms) {
  uint32_t utc = tx_wall_utc();
  return utc ? utc - ODID_EPOCH_UTC : now_ms / 1000;
}
// Location timestamp: seconds past the hour, to the tenth the message
// carries (several Locations go out each second).
static float tx_hour_s(uint32_t now_ms) {
#if defined(ESP_PLATFORM)
  struct timeval tv;
  gettimeofday(&tv, nullptr);
  if (tv.tv_sec > (time_t)(ODID_EPOCH_UTC + 86400))
    return (float)(tv.tv_sec % 3600) + (float)tv.tv_usec / 1e6f;
#else
  if (s_tx_test_utc) return (float)(s_tx_test_utc % 3600);
#endif
  return (float)fmod(now_ms / 1000.0, 3600.0);
}

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
  s->caa_id    = p->caa_id;
  s->proto_ver = p->proto_ver;
  s->ua_type   = 2;                                  // multirotor
  s->status    = s_emergency ? 3 : 2;                // emergency / airborne
  s->lat       = s_home_lat + (cy + ORBIT_M * sin(ang)) / m_lat;
  s->lon       = s_home_lon + (cx + ORBIT_M * cos(ang)) / m_lon;
  s->alt_geo_m = (float)(p->alt_m + 22.0);           // ~geoid offset here
  s->height_m  = (float)p->alt_m;
  s->speed_ms  = (float)s_speed_ms;
  s->vspeed_ms = (float)(0.5 * sin(ang * 2));
  s->dir_deg   = (float)fmod(360.0 + 90.0 - ang * 180.0 / M_PI, 360.0);
  s->ts_s      = tx_hour_s(now_ms);
  s->self_desc = p->self_desc;
  s->op_lat    = s_home_lat;
  s->op_lon    = s_home_lon;
  s->op_alt_m  = 12.0f;
  s->op_id     = p->op_id;
}

// The Authentication variants carry a real Ed25519 signature over the
// Basic ID message plus the page-0 timestamp, made with a published test
// key (see odid_auth.h). AUTHBAD corrupts it on purpose. The Basic ID never
// changes and the timestamp only once a second, so each path signs once a
// second however often it transmits (a signature costs milliseconds).
static uint8_t  s_sig[2][64];
static uint32_t s_sig_ts[2];
static bool     s_sig_ok[2] = { false, false };
static const uint8_t* tx_auth_sig(int pid, const uint8_t* basic_id, uint32_t ts) {
  int k = pid == P_AUTHBAD ? 1 : 0;
  if (!s_sig_ok[k] || s_sig_ts[k] != ts) {
    odid_auth_sign(s_sig[k], basic_id, ts);
    if (pid == P_AUTHBAD) s_sig[k][0] ^= 0xFF;   // break it on purpose
    s_sig_ts[k] = ts;
    s_sig_ok[k] = true;
  }
  return s_sig[k];
}

static uint32_t s_single_idx[P_COUNT] = {0};

// Build the ODID payload this path transmits: a message pack, optionally
// with Authentication pages appended, or the next single message of the
// odid_single_seq rotation (Location every other one).
static int build_payload(int pid, uint8_t* out, uint32_t now) {
  const TxPath* p = &PATHS[pid];
  OdidTxState s;
  current_state(&s, now, pid);

  if (p->format == F_SINGLE)
    return odid_build_single(out, &s, tx_odid_ts(now), odid_single_seq(s_single_idx[pid]++));

  int n = odid_build_pack(out, &s, tx_odid_ts(now));
  if (p->with_auth) {
    uint32_t ts = tx_odid_ts(now);
    const uint8_t* sig = tx_auth_sig(pid, out + 3, ts);   // out+3 is the Basic ID msg
    int count = out[2];
    int pages = odid_auth_pages(64);
    // All pages or none: page 0 advertises LastPageIndex, so a truncated
    // set promises pages that never arrive and can never verify. A path
    // configured with both caa_id and with_auth lands here -- say so, in
    // keeping with this tool never failing silently.
    if (count + pages > ODID_PACK_MAX_MESSAGES) {
      tx_note_err(pid, "pack_full_auth_skipped", 0);
      return n;
    }
    for (int pg = 0; pg < pages; pg++) {
      odid_build_auth_page(out + 3 + count * ODID_MSG_SIZE, &s,
                           1 /* UAS ID signature */, pg, sig, 64, ts);
      count++;
    }
    out[2] = (uint8_t)count;
    n = 3 + count * ODID_MSG_SIZE;
  }
  return n;
}

// ---------------------------------------------------------------- WiFi TX

static uint8_t s_frame[320];

// NAN cluster ID, as opendroneid-core-c (wifi.c) uses it: the BSSID of the
// synchronisation beacon and of the service discovery frame alike, so a
// receiver that follows the cluster keeps the frames that carry the data.
static const uint8_t NAN_CLUSTER[6] = {0x50, 0x6F, 0x9A, 0x01, 0x00, 0xFF};

static uint64_t tx_tsf_us() {
#if defined(ESP_PLATFORM)
  return (uint64_t)esp_timer_get_time();
#else
  return (uint64_t)millis() * 1000ULL;
#endif
}
static void put_tsf(uint8_t* f) {
  uint64_t t = tx_tsf_us();
  for (int k = 0; k < 8; k++) f[k] = (uint8_t)(t >> (8 * k));
}

// 802.11 beacon carrying the ODID vendor IE. Header fields as the
// opendroneid reference sets them: a running TSF timestamp, the beacon
// interval this path really keeps, short slot + short preamble capability.
static int build_beacon(int pid, const uint8_t* pack, int pack_len, uint8_t counter,
                        uint32_t interval_ms) {
  const TxPath* p = &PATHS[pid];
  static const char* SSID_STR = "ORECCHINO-TEST";
  uint8_t* f = s_frame;
  int i = 0;
  f[i++] = 0x80; f[i++] = 0x00;              // beacon
  f[i++] = 0x00; f[i++] = 0x00;              // duration
  for (int k = 0; k < 6; k++) f[i++] = 0xFF; // DA broadcast
  memcpy(f + i, p->mac, 6); i += 6;          // SA
  memcpy(f + i, p->mac, 6); i += 6;          // BSSID
  f[i++] = 0x00; f[i++] = 0x00;              // seq (tx_wifi_frame numbers it)
  put_tsf(f + i); i += 8;                    // timestamp
  uint32_t tu = interval_ms * 1000 / 1024;
  if (tu > 0xFFFF) tu = 0xFFFF;
  f[i++] = (uint8_t)(tu & 0xFF); f[i++] = (uint8_t)(tu >> 8);   // beacon interval
  f[i++] = 0x20; f[i++] = 0x04;              // capability: short preamble, short slot
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
  // promiscuous mode. BSSID is the NAN cluster ID.
  static const uint8_t NAN_DA[6] = {0x51, 0x6F, 0x9A, 0x01, 0x00, 0x00};
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

// NAN synchronisation beacon. The reference transmitter emits this
// alongside the service discovery frame so receivers can find and track the
// NAN cluster; ESP32 projects that send only the action frame produce
// traffic some receivers never latch onto. Constants from
// opendroneid-core-c wifi.c: cluster ID 50:6F:9A:01:00:FF, WFA OUI with
// NAN OUI type 0x13, master preference 0xFE, random factor 0xEA, interval
// 512 TU.
static int build_nan_sync_beacon(uint8_t counter) {
  const TxPath* p = &PATHS[P_NAN];
  uint8_t* f = s_frame;
  int i = 0;
  f[i++] = 0x80; f[i++] = 0x00;                    // beacon
  f[i++] = 0x00; f[i++] = 0x00;                    // duration
  for (int k = 0; k < 6; k++) f[i++] = 0xFF;       // DA broadcast
  memcpy(f + i, p->mac, 6); i += 6;                // SA
  memcpy(f + i, NAN_CLUSTER, 6); i += 6;           // BSSID = cluster ID
  f[i++] = 0x00; f[i++] = 0x00;                    // seq
  put_tsf(f + i); i += 8;                          // timestamp
  f[i++] = 0x00; f[i++] = 0x02;                    // beacon interval 512 TU
  f[i++] = 0x20; f[i++] = 0x04;                    // capability, as the reference
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
  memcpy(f + i, NAN_CLUSTER, 6); i += 6;
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

// Sequence numbers matter twice over: repeating seq 0 from one address
// invites 802.11 duplicate filtering, but letting the driver assign them
// (en_sys_seq) also lets it rewrite header fields — including the source
// address, which would collapse our per-path identities onto one MAC. So
// we number the frames ourselves and hand the driver an untouched header.
// A refused frame (no free TX buffer, driver not started) is counted and
// reported, never silently dropped.
static bool tx_wifi_frame(int pid, int len) {
  if (len <= 0) return false;
  static uint16_t seq[P_COUNT] = {0};
  uint16_t s = (uint16_t)(++seq[pid] & 0x0FFF);
  s_frame[22] = (uint8_t)(s << 4);          // seq ctrl: frag 0, seq low
  s_frame[23] = (uint8_t)(s >> 4);          // seq high
  esp_err_t rc = esp_wifi_80211_tx(WIFI_IF_STA, s_frame, len, false);
  if (rc == ESP_OK) return true;
  s_wifi_err += 1;
  s_wifi_rc = (int)rc;
  tx_note_err(pid, "wifi_tx", (int)rc);
  return false;
}

// The driver's own report for each frame it put on the air (Wi-Fi task).
static void tx_wifi_done(const esp_80211_tx_info_t* info) {
  if (!info) return;
  if (info->tx_status == WIFI_SEND_SUCCESS) s_wifi_done_ok += 1;
  else s_wifi_done_fail += 1;
  s_wifi_rate = (int)info->rate;
}

static void tx_path_sent(int pid, uint32_t now) {
  s_tx[pid] += 1;
  s_counter[pid]++;
  s_last_ok[pid] = now;
}

// One Wi-Fi transmission for a beacon or NAN path. True when it went out.
static bool wifi_send(int pid, uint32_t now) {
  const TxRate* r = &TX_RATES[s_rate];
  uint8_t payload[240];
  int n = build_payload(pid, payload, now);
  if (PATHS[pid].carrier == C_NAN) {
    // The sync beacon keeps its own, slower cadence (its advertised
    // interval is 512 TU); the service discovery frame carries the data.
    static uint32_t last_sync = 0;
    static bool synced = false;
    if (!synced || now - last_sync >= r->nan_sync_ms) {
      if (tx_wifi_frame(pid, build_nan_sync_beacon(s_counter[pid]))) {
        s_nan_sync += 1;
        if (!synced) last_sync = now; else tx_advance(&last_sync, r->nan_sync_ms, now);
        synced = true;
      }
    }
    if (!tx_wifi_frame(pid, build_nan(payload, n, s_counter[pid]))) return false;
  } else {
    uint32_t every = PATHS[pid].format == F_SINGLE ? r->single_ms : r->pack_ms;
    if (!tx_wifi_frame(pid, build_beacon(pid, payload, n, s_counter[pid], every))) return false;
  }
  tx_path_sent(pid, now);
  return true;
}

// ----------------------------------------------------------------- BLE TX

#if !CONFIG_BT_NIMBLE_EXT_ADV
#error "tx_core.h needs CONFIG_BT_NIMBLE_EXT_ADV=1 (see build_opt.h)"
#endif

// Advertising sets. With three, each BLE path has its own and is never
// stopped while it is on: the controller repeats it at its interval and
// the payload is swapped in place (a new Location, the next BLE4 message).
// The ESP32-C3's precompiled controller has been seen to grant only two
// (hardware, 2026-09); tx_begin probes, and then BLE4 keeps set 1 to itself
// -- a rotating single-message path needs to be on air all the time -- while
// BLE5 1M and coded, which carry a whole pack every event, take set 0 in
// turns of share_ms.
#define TX_BLE_SETS_MAX 3
typedef struct {
  int8_t   path;       // the path this set is carrying, -1 idle
  bool     active;     // started, as far as NimBLE has told us
  uint8_t  rate;       // the rate its interval was configured for
  uint32_t since_ms;   // when this path took the set
  uint32_t data_ms;    // last payload load
  uint32_t retry_ms;   // after a failure: not before this
} TxBleSet;
static NimBLEExtAdvertising* s_adv = nullptr;
static TxBleSet s_set[TX_BLE_SETS_MAX] = { {-1, false, 0, 0, 0, 0}, {-1, false, 0, 0, 0, 0}, {-1, false, 0, 0, 0, 0} };
static uint8_t  s_ble_sets = 0;   // 3, 2, or 0 without BLE
static const int BLE_PATHS[3] = { P_BLE5, P_BLELR, P_BLE4 };

static int ble_set_of(int pid) {
  if (s_ble_sets >= 3) return pid == P_BLE5 ? 0 : pid == P_BLELR ? 1 : 2;
  return pid == P_BLE4 ? 1 : 0;
}
static uint16_t ble_itvl_ms(int pid, const TxRate* r) {
  return pid == P_BLE4 ? r->leg_itvl_ms : pid == P_BLELR ? r->lr_itvl_ms : r->ext_itvl_ms;
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
static int ble_payload(int pid, uint8_t* ad, uint32_t now) {
  uint8_t odid[240];
  int n = build_payload(pid, odid, now);
  return build_ble_ad(ad, odid, n, s_counter[pid]);
}

// Configure set k for a path: PHYs, interval, address, legacy or not, data.
static bool ble_configure(int k, int pid, const uint8_t* ad, int len) {
  const TxRate* r = &TX_RATES[s_rate];
  const uint8_t phy = pid == P_BLELR ? BLE_HCI_LE_PHY_CODED : BLE_HCI_LE_PHY_1M;
  NimBLEExtAdvertisement adv(phy, phy);
  adv.setConnectable(false);
  adv.setScannable(false);
  uint32_t itvl = (uint32_t)ble_itvl_ms(pid, r) * 8 / 5;   // 0.625 ms units
  adv.setMinInterval(itvl);
  adv.setMaxInterval(itvl);
  adv.setTxPower(TX_BLE_DBM);
  // Each aircraft advertises from its own address, like real hardware.
  // Random *static* addresses need their top two bits set; NimBLE takes
  // the bytes LSB-first, so mac[0] is the significant end.
  uint8_t bda[6];
  memcpy(bda, PATHS[pid].mac, 6);
  bda[0] |= 0xC0;
  adv.setAddress(NimBLEAddress(bda, BLE_ADDR_RANDOM));
  // Legacy advertising caps the payload at 31 bytes: 6 of ODID overhead
  // leaves exactly one 25-byte message, never a pack.
  if (pid == P_BLE4) adv.setLegacyAdvertising(true);
  adv.setData(ad, (size_t)len);
  return s_adv->setInstanceData((uint8_t)k, adv);
}

// Swap the payload of a running set without stopping it: the controller
// takes new data for a set that is advertising (one HCI command, <= 251
// bytes; our largest is 134), so the set never goes quiet.
static bool ble_set_data(int k, const uint8_t* ad, int len) {
  struct os_mbuf* m = ble_hs_mbuf_from_flat(ad, (uint16_t)len);
  if (!m) return false;
  return ble_gap_ext_adv_set_data((uint8_t)k, m) == 0;   // consumes m
}

static bool ble_stop_set(int k) {
  TxBleSet* S = &s_set[k];
  if (!S->active) return true;
  if (!s_adv->stop((uint8_t)k)) return false;
  S->active = false;
  return true;
}

// Give set k to a path: stop it, reconfigure, start. `ad` is its payload.
static void ble_take(int k, int pid, uint32_t now, const uint8_t* ad, int len) {
  TxBleSet* S = &s_set[k];
  if (!ble_stop_set(k)) {
    tx_note_err(pid, "ble_stop", k);
    S->retry_ms = now + 200;
    return;
  }
  bool cfg = ble_configure(k, pid, ad, len);
  if (!cfg) {             // NimBLE may still hold it running: stop, try once more
    s_adv->stop((uint8_t)k);
    cfg = ble_configure(k, pid, ad, len);
  }
  bool on = cfg && s_adv->start((uint8_t)k);
  S->path = (int8_t)pid;
  S->since_ms = now;
  S->data_ms = now;
  S->rate = s_rate;
  if (on) {
    S->active = true;
    tx_path_sent(pid, now);
    return;
  }
  S->active = false;
  S->retry_ms = now + 500;
  tx_note_err(pid, cfg ? "ble_start" : "ble_config", k);
  if (k == 2 && s_ble_sets == 3) {
    // The controller will not run a third set after all: fall back to two.
    s_ble_sets = 2;
    s_set[2].path = -1;
    tx_note_err(pid, "ble_sets_fallback_2", k);
  }
}

// Put a fresh payload into a running set, or restart it if that fails.
static void ble_refresh(int k, int pid, uint32_t now, uint32_t every) {
  TxBleSet* S = &s_set[k];
  uint8_t ad[6 + 240];
  int len = ble_payload(pid, ad, now);
  if (ble_set_data(k, ad, len)) {
    tx_advance(&S->data_ms, every, now);
    tx_path_sent(pid, now);
    return;
  }
  s_ble_restarts += 1;
  ble_take(k, pid, now, ad, len);
}

// One pass over the advertising sets: who should be on each, and whether
// their payload is due.
static void ble_service(uint32_t now) {
  if (!s_adv) return;
  const TxRate* r = &TX_RATES[s_rate];
  for (int k = 0; k < s_ble_sets; k++) {
    TxBleSet* S = &s_set[k];
    int want[3], nw = 0;
    if (s_running)
      for (int j = 0; j < 3; j++)
        if (s_enabled[BLE_PATHS[j]] && ble_set_of(BLE_PATHS[j]) == k) want[nw++] = BLE_PATHS[j];
    if (nw == 0) {                          // nobody: this set goes quiet
      if (S->active && (int32_t)(now - S->retry_ms) >= 0 && !ble_stop_set(k)) {
        tx_note_err(S->path, "ble_stop", k);
        S->retry_ms = now + 200;
      }
      if (!S->active) S->path = -1;
      continue;
    }
    if ((int32_t)(now - S->retry_ms) < 0) continue;
    int cur = -1;
    for (int i = 0; i < nw; i++) if (want[i] == S->path) cur = i;
    int pid = cur < 0 ? want[0]
            : (nw > 1 && now - S->since_ms >= r->share_ms) ? want[(cur + 1) % nw]
            : S->path;
    if (pid != S->path || !S->active || S->rate != s_rate) {
      uint8_t ad[6 + 240];
      int len = ble_payload(pid, ad, now);
      ble_take(k, pid, now, ad, len);
      continue;
    }
    uint32_t every = pid == P_BLE4 ? r->leg_msg_ms : r->ext_data_ms;
    if (now - S->data_ms >= every) ble_refresh(k, pid, now, every);
  }
}

// How many sets the controller will run: configure and start a third with
// a real BLE4 advertisement (one event), then stop it again.
static uint8_t ble_probe_sets() {
  uint8_t ad[6 + 240];
  int len = ble_payload(P_BLE4, ad, millis());
  bool ok = ble_configure(2, P_BLE4, ad, len);
  if (ok) {
    ok = s_adv->start(2, 0, 1);
    s_adv->stop(2);
  }
  return ok ? 3 : 2;
}

// Stop every set (one at a time: NimBLE's stop-all refuses while any set is
// running) and choose the layout again: 2 forces the shared layout, anything
// else probes.
static void ble_relayout(int want) {
  if (!s_adv) return;
  for (int k = 0; k < TX_BLE_SETS_MAX; k++) {
    if (s_set[k].active || k < s_ble_sets) s_adv->stop((uint8_t)k);
    s_set[k].active = false;
    s_set[k].path = -1;
    s_set[k].retry_ms = 0;
  }
  s_ble_sets = want == 2 ? 2 : ble_probe_sets();
}

static void ble_begin() {
  s_txb_ok = NimBLEDevice::init("");
  if (!s_txb_ok) { s_ble_sets = 0; return; }
  NimBLEDevice::setPower(TX_BLE_DBM);
  s_adv = NimBLEDevice::getAdvertising();
  s_ble_sets = s_adv ? ble_probe_sets() : 0;
}

// ---------------------------------------------------------------- the pass

// One pass of the transmitter: at most one Wi-Fi path's frame (round-robin,
// so the shared 2.4 GHz front end is never asked for a burst), then the BLE
// sets. Runs every 2 ms on the radio task (tx_task), or from tx_tick on the
// host.
static void tx_step(uint32_t now) {
  static uint32_t last[P_COUNT] = {0};
  static int rr = 0;
  if (s_running && s_txw_ok) {
    const TxRate* r = &TX_RATES[s_rate];
    for (int k = 0; k < P_COUNT; k++) {
      int pid = (rr + k) % P_COUNT;
      uint8_t c = PATHS[pid].carrier;
      if (!s_enabled[pid] || (c != C_BEACON && c != C_NAN)) continue;
      uint32_t every = c == C_NAN ? r->nan_ms
                     : PATHS[pid].format == F_SINGLE ? r->single_ms : r->pack_ms;
      if (now - last[pid] < every) continue;
      rr = (pid + 1) % P_COUNT;
      if (wifi_send(pid, now)) tx_advance(&last[pid], every, now);
      else last[pid] = now - every + 20;        // refused: try again in 20 ms
      break;
    }
  }
  ble_service(now);

  // The channel is ours alone in beacon mode; check it stays that way.
  static uint32_t last_ch = 0;
  if (s_txw_ok && now - last_ch >= 1000) {
    last_ch = now;
    uint8_t ch = 0;
    wifi_second_chan_t sc;
    if (esp_wifi_get_channel(&ch, &sc) == ESP_OK) {
      s_ch = ch;
      if (ch != WIFI_CHANNEL) {
        esp_wifi_set_channel(WIFI_CHANNEL, WIFI_SECOND_CHAN_NONE);
        s_ch_fix += 1;
      }
    }
  }
}

#if TX_TASK
// Above every application task and the e-paper feeders (19, which spin
// through a whole refresh), below the radio stacks (NimBLE host 21,
// esp_timer 22, Wi-Fi and the BT controller 23). It sleeps 2 ms a pass.
// It lives on core 0 with the radio stacks, not on the loop's core: there,
// waking every 2 ms above the core-1 e-paper feeder, it starved every
// refresh into a "line buffer underrun" (the T5 in test beacon mode kept
// repainting). On the single-core C3 core 0 is the only core anyway.
#ifndef TX_TASK_PRIO
#define TX_TASK_PRIO 20
#endif
#ifndef TX_TASK_CORE
#define TX_TASK_CORE 0
#endif
static void tx_task(void*) {
  for (;;) {
    tx_lock();
    tx_step(millis());
    tx_unlock();
    vTaskDelay(pdMS_TO_TICKS(2) > 0 ? pdMS_TO_TICKS(2) : 1);
  }
}
#endif

// ---------------------------------------------------------------- control

static int tx_cat(char* b, int n, int cap, const char* fmt, ...) {
  if (n >= cap - 1) return n;
  va_list ap;
  va_start(ap, fmt);
  int k = vsnprintf(b + n, (size_t)(cap - n), fmt, ap);
  va_end(ap);
  if (k < 0) return n;
  return n + k < cap ? n + k : cap - 1;
}

static void print_status() {
  static char b[2600];
  uint32_t now = millis();
  int n = 0;
  int8_t pwr = 0;
  esp_wifi_get_max_tx_power(&pwr);
  tx_lock();
  n = tx_cat(b, n, sizeof(b),
             "{\"type\":\"tx_status\",\"fw\":\"%s\",\"ver\":\"%s\","
             "\"running\":%s,\"emergency\":%s,\"rate\":\"%s\",\"home\":[%.6f,%.6f],"
             "\"ring_m\":%.0f,\"ch\":%u,\"ch_fix\":%lu,\"wifi\":%s,\"wifi_dbm\":%.1f,"
             "\"wifi_err\":%lu,\"wifi_rc\":%d,\"wifi_done\":[%lu,%lu],\"wifi_rate\":%d,"
             "\"nan_sync\":%lu,\"ble\":%s,\"ble_sets\":%u,\"ble_on\":[%d,%d,%d],"
             "\"ble_restarts\":%lu,\"errors\":%lu,\"sched\":\"%s\",\"paths\":[",
             TX_NAME, TX_VERSION, s_running ? "true" : "false",
             s_emergency ? "true" : "false", s_rate == TX_RATE_SLOW ? "slow" : "spec",
             s_home_lat, s_home_lon, s_ring_m, (unsigned)s_ch, (unsigned long)s_ch_fix,
             s_txw_ok ? "true" : "false", pwr / 4.0, (unsigned long)s_wifi_err, (int)s_wifi_rc,
             (unsigned long)s_wifi_done_ok, (unsigned long)s_wifi_done_fail, (int)s_wifi_rate,
             (unsigned long)s_nan_sync, s_txb_ok ? "true" : "false", (unsigned)s_ble_sets,
             s_set[0].active ? s_set[0].path : -1, s_set[1].active ? s_set[1].path : -1,
             s_set[2].active ? s_set[2].path : -1, (unsigned long)s_ble_restarts,
             (unsigned long)s_err_n, s_task_running ? "task" : "loop");
  for (int i = 0; i < P_COUNT; i++) {
    OdidTxState s;
    current_state(&s, now, i);
    long age = s_last_ok[i] ? (long)(now - s_last_ok[i]) : -1;
    n = tx_cat(b, n, sizeof(b),
               "%s{\"uas_id\":\"%s\",\"on\":%s,\"lat\":%.6f,\"lon\":%.6f,"
               "\"height\":%.0f,\"tx\":%lu,\"err\":%lu,\"age_ms\":%ld}",
               i ? "," : "", PATHS[i].uas_id, s_enabled[i] ? "true" : "false", s.lat, s.lon,
               (double)s.height_m, (unsigned long)s_tx[i], (unsigned long)s_err[i], age);
  }
  tx_unlock();
  n = tx_cat(b, n, sizeof(b), "]}\n");
  Serial.write((const uint8_t*)b, (size_t)n);
}

static void tx_set_rate(uint8_t rate) {
  s_rate = rate == TX_RATE_SLOW ? TX_RATE_SLOW : TX_RATE_SPEC;
  Preferences p;
  if (p.begin("orecchino", false)) {
    p.putUChar("tx_rate", s_rate);
    p.end();
  }
}

static void handle_line(char* line) {
  if (!line[0]) return;
  if (!strcmp(line, "s")) {
    print_status();
  } else if (!strcmp(line, "go")) {
    s_running = true;
    Serial.println("{\"type\":\"tx_evt\",\"msg\":\"transmitting\"}");
  } else if (!strcmp(line, "stop")) {
    s_running = false;       // the radio task silences every set within a pass
    Serial.println("{\"type\":\"tx_evt\",\"msg\":\"paused\"}");
  } else if (!strcmp(line, "e")) {
    s_emergency = !s_emergency;
    Serial.printf("{\"type\":\"tx_evt\",\"emergency\":%s}\n",
                  s_emergency ? "true" : "false");
  } else if (!strcmp(line, "rate slow") || !strcmp(line, "rate spec")) {
    tx_set_rate(line[5] == 's' && line[6] == 'l' ? TX_RATE_SLOW : TX_RATE_SPEC);
    print_status();
  } else if (!strncmp(line, "sets ", 5)) {
    tx_lock();
    ble_relayout(atoi(line + 5));
    tx_unlock();
    print_status();
  } else if (line[0] == 'h' && line[1] == ' ') {
    double la, lo;
    if (sscanf(line + 2, "%lf %lf", &la, &lo) == 2 &&
        la >= -90 && la <= 90 && lo >= -180 && lo <= 180) {   // odid_build_location's int32 cast
      tx_lock();
      s_home_lat = la;
      s_home_lon = lo;
      tx_unlock();
      print_status();
    }
  } else if (line[0] == 'r' && line[1] == ' ') {
    double r = atof(line + 2);
    if (r >= 10 && r <= 20000) {
      tx_lock();
      s_ring_m = r;
      tx_unlock();
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
  {
    Preferences p;
    uint8_t r = TX_RATE_SPEC;
    if (p.begin("orecchino", true)) { r = p.getUChar("tx_rate", TX_RATE_SPEC); p.end(); }
    s_rate = r == TX_RATE_SLOW ? TX_RATE_SLOW : TX_RATE_SPEC;
  }

  // Station mode, never joined and never scanning: the radio stays on our
  // channel. Power save off before the driver starts too -- Arduino applies
  // its own sleep setting from the STA_START event, after we would have.
  WiFi.setSleep(false);
  s_txw_ok = WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);
  WiFi.disconnect();
  esp_wifi_set_ps(WIFI_PS_NONE);
  esp_wifi_set_max_tx_power(TX_WIFI_QDBM);
  delay(100);
  esp_wifi_set_channel(WIFI_CHANNEL, WIFI_SECOND_CHAN_NONE);
  esp_wifi_register_80211_tx_cb(tx_wifi_done);
  s_ch = WIFI_CHANNEL;

  odid_auth_init();
  ble_begin();

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
  for (int i = 0; i < 32; i++) snprintf(pub_hex + i * 2, 3, "%02x", pub[i]);
  pub_hex[64] = 0;

#if TX_TASK
  if (!s_task_running) {
    s_tx_mx = xSemaphoreCreateMutex();
    if (s_tx_mx &&
        xTaskCreatePinnedToCore(tx_task, "tx_radio", 8192, nullptr, TX_TASK_PRIO, nullptr,
                                TX_TASK_CORE) == pdPASS)
      s_task_running = true;
  }
#endif

  Serial.printf("{\"type\":\"tx_boot\",\"fw\":\"%s\",\"ver\":\"%s\","
                "\"paths\":%d,\"rate\":\"%s\",\"wifi\":%s,\"ble\":%s,\"ble_sets\":%u,"
                "\"sched\":\"%s\",\"selftest\":{\"sign\":%s,\"reject\":%s},"
                "\"auth_pubkey\":\"%s\",\"note\":\"TEST BEACON - not a "
                "compliant Remote ID transmitter\"}\n",
                TX_NAME, TX_VERSION, P_COUNT, s_rate == TX_RATE_SLOW ? "slow" : "spec",
                s_txw_ok ? "true" : "false", s_txb_ok ? "true" : "false",
                (unsigned)s_ble_sets, s_task_running ? "task" : "loop",
                sig_ok ? "true" : "false", rej_ok ? "true" : "false", pub_hex);
  print_status();
}

// The loop's share: the serial console, the status line every 5 s and any
// new failure (at most one tx_err line per 5 s, with the running count).
// Without the radio task (host tests) it also runs the transmitter pass.
static void tx_tick(uint32_t now) {
  poll_serial();
  if (!s_task_running) {
    tx_lock();
    tx_step(now);
    tx_unlock();
  }

  static uint32_t last_status = 0, last_err = 0, err_seen = 0;
  if (now - last_status >= 5000) {
    last_status = now;
    print_status();
  }
  if (s_err_n != err_seen && (err_seen == 0 || now - last_err >= 5000)) {
    char line[sizeof(s_err_line)];
    tx_lock();
    memcpy(line, s_err_line, sizeof(line));
    err_seen = s_err_n;
    tx_unlock();
    last_err = now;
    line[sizeof(line) - 1] = 0;
    Serial.print(line);
  }
}

// ------------------------------------------------------------------- API
// Everything a board UI needs to drive the beacon without knowing how a
// frame is built. The setters only record what is wanted; the radio task
// switches sets on and off to match within a pass.
static inline int         tx_path_count() { return P_COUNT; }
static inline const char* tx_path_id(int i) { return PATHS[i].uas_id; }
static inline const char* tx_path_desc(int i) { return PATHS[i].self_desc; }
static inline bool        tx_enabled(int i) { return i >= 0 && i < P_COUNT && s_enabled[i]; }
static inline void        tx_set_enabled(int i, bool on) { if (i >= 0 && i < P_COUNT) s_enabled[i] = on; }
static inline uint32_t    tx_count(int i) { return s_tx[i]; }
static inline uint32_t    tx_errors(int i) { return s_err[i]; }
static inline bool        tx_running() { return s_running; }
static inline void        tx_set_running(bool on) { s_running = on; }
static inline bool        tx_emergency() { return s_emergency; }
static inline void        tx_set_emergency(bool on) { s_emergency = on; }
/// SLOW: every path once every 5 s (a quiet bench). Otherwise the spec
/// rate. Saved in NVS, so it survives a restart.
static inline bool        tx_slow() { return s_rate == TX_RATE_SLOW; }
static inline void        tx_set_slow(bool on) { tx_set_rate(on ? TX_RATE_SLOW : TX_RATE_SPEC); }
static inline uint8_t     tx_ble_sets() { return s_ble_sets; }
/// Carrier label for a path: "Wi-Fi", "NAN", "BLE5", "BLE LR", "BLE4".
static inline const char* tx_path_carrier(int i) {
  switch (PATHS[i].carrier) {
    case C_BEACON: return "Wi-Fi"; case C_NAN: return "NAN"; case C_BLE_EXT: return "BLE5";
    case C_BLE_CODED: return "BLE LR"; default: return "BLE4";
  }
}
