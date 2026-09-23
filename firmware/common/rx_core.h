// Orecchino receiver core — ASTM F3411 (Open Drone ID) Remote ID sniffer.
//
// One engine for every board: Wi-Fi beacon + NAN sniffing, BLE 4/5 (1M and
// coded PHY) scanning, ODID decode + Authentication verification, the
// on-device track table, and the JSON line protocol the desktop app
// speaks. A board sketch defines FW_BOARD, includes this header, and calls
// rx_begin() / rx_tick(); anything board-specific (screen, buzzer, spectrum
// view, tile store) hangs off the weak rx_hook_* functions below.
//
// Receives Broadcast Remote ID on:
//   * WiFi beacons        — vendor IE, OUI FA:0B:BC, type 0x0D
//   * WiFi NAN SDF        — public action frames, WFA OUI 50:6F:9A / NAN,
//                           service org.opendroneid.remoteid
//   * Bluetooth LE        — service data UUID 0xFFFA, app code 0x0D.
//                           Legacy BT4 ADV plus BT5 extended advertising on
//                           both 1M and coded (long-range) PHY, via
//                           NimBLE-Arduino with CONFIG_BT_NIMBLE_EXT_ADV=1
//                           (see each sketch's build_opt.h)
//
// Output: one JSON object per line on the serial port.
//   {"type":"boot", ...}   once at startup
//   {"type":"rid",  ...}   per decoded Remote ID frame; a frame repeated
//                          unchanged is reported at most once a second
//   {"type":"hb",   ...}   heartbeat with counters every 2 s
//   {"type":"log",  ...}   match log records, on {"cmd":"log_get"}
//
// Timing. On the device nothing on the detection path waits for the
// sketch's loop(): the radio callbacks queue matched frames, a decode task
// blocks on that queue and handles each frame as it lands, and an esp_timer
// hops the Wi-Fi channel. loop() only reads host lines, expires contacts,
// saves the match log and copies the track table for the screen, so a slow
// e-paper refresh no longer delays or drops a detection. Every JSON line
// goes out in a single Serial write (each write is atomic across tasks).
// The host tests build without ESP_PLATFORM and run the same code
// synchronously from rx_tick().
#pragma once
#include <Arduino.h>
#include <WiFi.h>
#include <stdarg.h>
#include "sdkconfig.h"
#include "esp_wifi.h"
#include <NimBLEDevice.h>
#include "odid_decode.h"
#include "odid_verify.h"
#include "tracker.h"
#include "match_log.h"

#ifndef RX_ASYNC                 // a sketch may force the synchronous path
#if defined(ESP_PLATFORM)
#define RX_ASYNC 1
#else
#define RX_ASYNC 0
#endif
#endif
#if defined(ESP_PLATFORM)
#include "esp_timer.h"
#include <sys/time.h>
#endif

#define FW_NAME    "orecchino"
#define FW_VERSION "0.5.0"
#ifndef FW_BOARD
#error "define FW_BOARD before including rx_core.h"
#endif

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
  char    ssid[33];   // beacon SSID (DJI puts "RID-" + serial there); empty for NAN and BLE
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
static volatile uint32_t s_cnt_pfail       = 0;  // matched but failed decode
static volatile uint32_t s_cnt_dropped     = 0;
uint32_t                 g_seen_count      = 0;  // unique drones since boot
Track                    g_tracks[TRK_MAX];      // what the screens read
#if RX_ASYNC
static Track             s_live[TRK_MAX];        // the decode task's table
Track*                   g_trk_live        = s_live;
static SemaphoreHandle_t s_mx;                   // guards s_live, TFRs, home, log
#define RX_LOCK()   xSemaphoreTake(s_mx, portMAX_DELAY)
#define RX_UNLOCK() xSemaphoreGive(s_mx)
#else
Track*                   g_trk_live        = g_tracks;
#define RX_LOCK()   ((void)0)
#define RX_UNLOCK() ((void)0)
#endif
static volatile uint32_t s_live_gen        = 0;  // bumped on every table change
static volatile uint8_t  s_cur_chan        = 6;
static bool s_ble_ok  = false;
static bool s_ble_ext = false;


// ------------------------------------------------------------------ hooks
// Boards implement these to add a screen, a buzzer, a spectrum view, a tile
// store. A sketch that defines any of them defines ORECCHINO_BOARD_HOOKS
// before including this header and provides all four; a headless build
// gets the no-op defaults below. (They share the sketch's translation
// unit, so weak linkage cannot do the job.)

/// Every promiscuous frame's energy (Wi-Fi task context: be quick).
void rx_hook_wifi_frame(uint8_t chan, int8_t rssi);
/// True while something else owns the radios (spectrum view): the core
/// stops hopping, drops matches, and leaves the BLE scanner down. Called
/// from the radio callbacks and the hop timer, so it must be a plain read:
/// no locks, no drawing.
bool rx_hook_paused();
/// A host line the core does not recognise. Return true if handled.
bool rx_hook_host_line(const char* cmd, char* line, uint32_t now);
/// A track was updated. `tfr_entered` fires once per incursion.
void rx_hook_track(Track* t, bool created, bool tfr_entered);

#ifndef ORECCHINO_BOARD_HOOKS
void rx_hook_wifi_frame(uint8_t, int8_t) {}
bool rx_hook_paused() { return false; }
bool rx_hook_host_line(const char*, char*, uint32_t) { return false; }
void rx_hook_track(Track*, bool, bool) {}
#endif

// Callbacks run in the WiFi / Bluedroid task context: copy out and return.
static void enqueue_rid(uint8_t src, const uint8_t* mac, int8_t rssi,
                        uint8_t chan, uint8_t phy, const uint8_t* odid, int len,
                        const char* ssid) {
  if (len < 25 || !s_q || rx_hook_paused()) return;
  RidEvt e;
  e.src  = src;
  memcpy(e.mac, mac, 6);
  e.rssi = rssi;
  e.chan = chan;
  e.phy  = phy;
  e.ssid[0] = 0;
  if (ssid) { strncpy(e.ssid, ssid, sizeof(e.ssid) - 1); e.ssid[sizeof(e.ssid) - 1] = 0; }
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
  const wifi_promiscuous_pkt_t* p = (const wifi_promiscuous_pkt_t*)buf;
  rx_hook_wifi_frame(p->rx_ctrl.channel, p->rx_ctrl.rssi);
  if (type != WIFI_PKT_MGMT) return;
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
    char ssid[33];         // the SSID element comes first, so it is known by the vendor element
    ssid[0] = 0;
    while (off + 2 <= len) {
      uint8_t id = d[off], l = d[off + 1];
      if (off + 2 + l > len) break;
      const uint8_t* ie = d + off + 2;
      if (id == 0 && l <= 32) { memcpy(ssid, ie, l); ssid[l] = 0; }
      // Vendor specific, type 0x0D, then [counter][ODID pack or GB 46750 packet].
      // OUIs: FA:0B:BC (ASD-STAN) and 90:3A:E6 (Parrot), same payload.
      if (id == 221 && l >= 30 && ie[3] == 0x0D &&
          ((ie[0] == 0xFA && ie[1] == 0x0B && ie[2] == 0xBC) ||
           (ie[0] == 0x90 && ie[1] == 0x3A && ie[2] == 0xE6))) {
        enqueue_rid(SRC_WIFI_BEACON, sa, p->rx_ctrl.rssi, p->rx_ctrl.channel,
                    0, ie + 5, l - 5, ssid);
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
                  0, b + i + 11, n, nullptr);
      break;
    }
  }
}

static void rx_set_channel(uint8_t ch) {
  s_cur_chan = ch;
  esp_wifi_set_channel(ch, WIFI_SECOND_CHAN_NONE);
}

#if RX_ASYNC
// Channel hopping on an esp_timer: dwell times hold even while the loop is
// busy drawing. While a board hook has the radios (spectrum view) the timer
// just checks back every 50 ms and leaves the channel to the sketch.
static esp_timer_handle_t s_hop_timer;
static size_t s_hop_idx = 0;
static void hop_cb(void*) {
  uint32_t next_ms = 50;
  if (!rx_hook_paused()) {
    s_hop_idx = (s_hop_idx + 1) % HOP_N;
    rx_set_channel(HOP[s_hop_idx].chan);
    next_ms = HOP[s_hop_idx].dwell_ms;
  }
  esp_timer_start_once(s_hop_timer, (uint64_t)next_ms * 1000);
}
#endif

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
        enqueue_rid(SRC_BLE, addr, rssi, 0, phy, sd + 4, l - 5, nullptr);
      }
    }
    i += 1 + l;
  }
}

#if defined(ESP_PLATFORM) && CONFIG_BT_NIMBLE_EXT_ADV
// Straight on NimBLE's GAP layer rather than through NimBLEScan: that class
// builds a NimBLEAdvertisedDevice (a heap object with a copy of the payload)
// for every advertiser in range, searches its result list on every report
// and frees the object again -- per phone, watch and tag, dozens a second,
// almost none of them Remote ID. Here a report is scanned where it lies;
// only an extended advertisement that arrives in fragments is copied, into
// a small fixed table, until its last fragment lands.

struct BleFrag { bool used; uint8_t addr[6], sid; uint16_t len; uint32_t ms; uint8_t data[256]; };
static BleFrag s_frag[4];
static bool    s_ble_scanning = false;
static void    rx_ble_scan(bool on);

static void ble_report(const ble_addr_t* a, int rssi, uint8_t phy, const uint8_t* data, int len) {
  uint8_t mac[6];
  for (int i = 0; i < 6; i++) mac[i] = a->val[5 - i];   // NimBLE keeps addresses LSB first
  handle_adv(mac, rssi, phy, data, len);
}

static int rx_gap_event(struct ble_gap_event* ev, void*) {
  if (ev->type == BLE_GAP_EVENT_EXT_DISC) {
    const struct ble_gap_ext_disc_desc& d = ev->ext_disc;
    uint8_t phy = d.prim_phy;                        // 1 = 1M, 3 = coded
    if (d.sec_phy == 3) phy = 3;                     // payload rode long range
    // A fragment continues an assembly for the same advertiser and set.
    // One whose last fragment never came (older than a second) is dropped,
    // not continued: the next advertisement must not land on its tail.
    BleFrag* f = nullptr;
    uint32_t now_ms = millis();
    for (auto& x : s_frag)
      if (x.used && x.sid == d.sid && !memcmp(x.addr, d.addr.val, 6)) {
        if (now_ms - x.ms > 1000) x.used = false; else f = &x;
        break;
      }
    bool more = d.data_status == BLE_GAP_EXT_ADV_DATA_STATUS_INCOMPLETE;
    if (!f && !more) {                               // the common case: one whole report
      ble_report(&d.addr, d.rssi, phy, d.data, d.length_data);
      return 0;
    }
    if (!f) {                                        // first fragment: take a slot (oldest if full)
      for (auto& x : s_frag) if (!x.used || now_ms - x.ms > 1000) { f = &x; break; }
      if (!f) f = &s_frag[0];
      f->used = true; f->sid = d.sid; f->len = 0; f->ms = now_ms;
      memcpy(f->addr, d.addr.val, 6);
    }
    size_t room = sizeof(f->data) - f->len, n = d.length_data < room ? d.length_data : room;
    memcpy(f->data + f->len, d.data, n);
    f->len += n;
    if (!more) {                                     // complete (or truncated): report it
      ble_report(&d.addr, d.rssi, phy, f->data, f->len);
      f->used = false;
    }
  } else if (ev->type == BLE_GAP_EVENT_DISC_COMPLETE) {
    // Forever means forever -- unless a board hook has the radios.
    s_ble_scanning = false;
    if (!rx_hook_paused()) rx_ble_scan(true);
  }
  return 0;
}

static void rx_ble_scan(bool on) {
  if (on && !s_ble_scanning) {
    // Both radios share one 2.4 GHz front end. A 50% BLE duty cycle starved
    // the WiFi paths -- bench-measured 4 beacon matches against 234 BLE in
    // the same window -- so BLE listens 30 ms in every 100 and WiFi gets the
    // rest. Passive, no duplicate filter (repeats carry fresh Location), on
    // both the 1M and the coded (long-range) PHY.
    struct ble_gap_ext_disc_params p = {};
    p.itvl = 160;      // 100 ms, 0.625 ms units
    p.window = 48;     // 30 ms
    p.passive = 1;
    int rc = ble_gap_ext_disc(BLE_OWN_ADDR_PUBLIC, 0 /* forever */, 0, 0 /* no dup filter */,
                              0, 0, &p, &p, rx_gap_event, nullptr);
    s_ble_scanning = rc == 0 || rc == BLE_HS_EALREADY;
  } else if (!on && s_ble_scanning) {
    ble_gap_disc_cancel();
    s_ble_scanning = false;
    for (auto& x : s_frag) x.used = false;
  }
}

static bool ble_start_scanner() {
  NimBLEDevice::init("");
  s_ble_ext = true;          // scanning 1M + coded PHY
  rx_ble_scan(true);
  return s_ble_scanning;
}
#else
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
    // Forever means forever — unless a board hook has the radios.
    if (s_scan && !rx_hook_paused()) s_scan->start(0, false, true);
  }
};

static void rx_ble_scan(bool on) {
  if (!s_scan) return;
  if (on) s_scan->start(0, false, true);
  else s_scan->stop();               // onScanEnd guard keeps it down
}

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
  // Both radios share one 2.4 GHz front end. A 50% BLE duty cycle starved
  // the WiFi paths — bench-measured 4 beacon matches against 234 BLE in the
  // same window — so BLE now listens 30 ms in every 100 and WiFi gets the
  // rest. BLE advertising repeats often enough that 30% still catches it.
  s_scan->setInterval(100);  // ms
  s_scan->setWindow(30);     // ms
#if CONFIG_BT_NIMBLE_EXT_ADV
  s_ble_ext = true;          // scanning 1M + coded PHY (SCAN_ALL default)
#endif
  return s_scan->start(0 /* forever */, false, true);
}

#endif

// ODID decoding lives in firmware/common/odid_decode.h (shared with
// the host-side unit tests in tests/).

// --------------------------------------------------------------- JSON output
// Lines are built by appending into one buffer, numbers by integer
// arithmetic: printf's %f was most of the cost of a line (measured on an
// ESP32-S3: ~233 us per rid line with vsnprintf, of which decoding the
// frame is ~11 us). Non-finite numbers come out as null.

static char  s_jb[1536];        // loop-side lines (log records), built under the lock
static char  s_rid_line[1536];  // the decode task's own: sent after the lock is released
static char* s_jbase = s_jb;
static char* s_jp = s_jb;
static char* s_jlim = s_jb + sizeof(s_jb) - 3;   // room for "}\n\0"

/// Start a line in `buf` (always under RX_LOCK: the cursor is shared).
static inline void jbegin(char* buf, size_t cap) { s_jbase = s_jp = buf; s_jlim = buf + cap - 3; }

static inline void jchar(char c) { if (s_jp < s_jlim) *s_jp++ = c; }
static inline void jraw(const char* s) { while (*s && s_jp < s_jlim) *s_jp++ = *s++; }
static void ju64(uint64_t v) {
  char t[20]; int n = 0;
  do { t[n++] = (char)('0' + v % 10); v /= 10; } while (v);
  while (n) jchar(t[--n]);
}
static inline void juint(uint32_t v) { ju64(v); }
static inline void jint(int32_t v) {
  if (v < 0) { jchar('-'); ju64((uint64_t)(-(int64_t)v)); } else ju64((uint64_t)v);
}
/// Fixed-point with `dec` decimals (0..7), rounded half away from zero.
static void jfix(double v, int dec) {
  static const uint32_t P10[] = { 1, 10, 100, 1000, 10000, 100000, 1000000, 10000000 };
  if (!isfinite(v) || fabs(v) > 1e12) { jraw("null"); return; }
  bool neg = v < 0;
  uint64_t q = (uint64_t)((neg ? -v : v) * P10[dec] + 0.5);
  if (neg && q) jchar('-');
  ju64(q / P10[dec]);
  if (dec) {
    jchar('.');
    uint32_t f = (uint32_t)(q % P10[dec]);
    for (int d = dec - 1; d >= 0; d--) { jchar((char)('0' + (f / P10[d]) % 10)); }
  }
}
static void jmac(const uint8_t* m) {
  static const char H[] = "0123456789ABCDEF";
  for (int i = 0; i < 6; i++) {
    if (i) jchar(':');
    jchar(H[m[i] >> 4]); jchar(H[m[i] & 15]);
  }
}
static inline void jkey(const char* k) { jchar(','); jchar('"'); jraw(k); jraw("\":"); }
static inline void jstrv(const char* v) { jchar('"'); jraw(v); jchar('"'); }
/// Close the object and terminate the line; returns its length.
static size_t jfinish() {
  *s_jp++ = '}'; *s_jp++ = '\n'; *s_jp = 0;
  return (size_t)(s_jp - s_jbase);
}
/// Finish the line and send it in one write.
static void jsend() {
  size_t n = jfinish();
  Serial.write((const uint8_t*)s_jbase, n);
}

/// Format a rid line into s_rid_line; the caller sends it once the track
/// table is unlocked, so a stalled USB host can never hold the loop up.
static size_t format_rid(const RidEvt* e, const OdidUas* u, const Track* t) {
  jbegin(s_rid_line, sizeof(s_rid_line));
  jraw("{\"type\":\"rid\",\"src\":"); jstrv(SRC_NAMES[e->src]);
  jkey("mac"); jchar('"'); jmac(e->mac); jchar('"');
  jkey("rssi"); jint(e->rssi);
  if (e->chan) { jkey("ch"); juint(e->chan); }
  if (e->src == SRC_BLE && e->phy)
    { jkey("phy"); jstrv(e->phy == 3 ? "coded" : (e->phy == 2 ? "2m" : "1m")); }
  // Which wire format spoke, and for a beacon its SSID -- with the verdict
  // when that SSID names a serial (DJI's "RID-" convention).
  if (u->gb46750) { jkey("fmt"); jstrv("gb46750"); }
  else { jkey("proto"); juint(u->proto_ver); }
  if (e->ssid[0]) {
    char s[33]; odid_copy_text(s, sizeof(s), (const uint8_t*)e->ssid, strlen(e->ssid));
    jkey("ssid"); jstrv(s);
    if (t->ssid_check) { jkey("ssid_id_match"); jraw(t->ssid_check == 1 ? "true" : "false"); }
  }

  if (u->has_basic[0] || u->has_basic[1]) {
    jkey("basic_id"); jchar('[');
    bool first = true;
    for (int i = 0; i < 2; i++) {
      if (!u->has_basic[i]) continue;
      if (!first) jchar(',');
      jraw("{\"id_type\":"); juint(u->id_type[i]);
      jkey("ua_type"); juint(u->ua_type[i]);
      jkey("uas_id"); jstrv(u->uas_id[i]);
      jchar('}');
      first = false;
    }
    jchar(']');
  }
  if (u->has_loc) {
    jkey("loc"); jraw("{\"status\":"); juint(u->status);
    jkey("lat"); jfix(u->lat, 7);        jkey("lon"); jfix(u->lon, 7);
    jkey("alt_geo"); jfix(u->alt_geo, 1); jkey("alt_baro"); jfix(u->alt_baro, 1);
    jkey("height"); jfix(u->height, 1);   jkey("height_ref"); juint(u->height_ref);
    jkey("speed"); jfix(u->speed, 2);     jkey("dir"); jfix(u->dir, 0);
    jkey("ts"); jfix(u->ts, 1);
    if (u->vspeed > -900) { jkey("vspeed"); jfix(u->vspeed, 2); }
    jchar('}');
  }
  if (u->has_self) {
    jkey("self_id"); jraw("{\"desc_type\":"); juint(u->self_type);
    jkey("desc"); jstrv(u->self_desc); jchar('}');
  }
  if (u->has_sys) {
    jkey("system"); jraw("{\"op_lat\":"); jfix(u->op_lat, 7);
    jkey("op_lon"); jfix(u->op_lon, 7); jkey("op_alt"); jfix(u->op_alt, 1);
    jkey("op_loc_type"); juint(u->op_loc_type); jkey("area_count"); juint(u->area_count);
    jkey("ts"); juint(u->sys_ts); jchar('}');
  }
  if (u->has_op) {
    jkey("op_id"); jraw("{\"id_type\":"); juint(u->op_id_type);
    jkey("id"); jstrv(u->op_id); jchar('}');
  }
  if (u->has_auth) {
    // The verdict comes from the track: pages are assembled there across
    // frames, and verified once per change rather than once per line.
    jkey("auth"); jraw("{\"type\":"); juint(u->auth_type);
    jkey("len"); juint(u->auth_len); jkey("pages"); juint(u->auth_last_page + 1);
    jkey("state"); jstrv(odid_auth_state_name((OdidAuthState)t->auth_state)); jchar('}');
  }
  return jfinish();
}

static void emit_heartbeat() {
  Serial.printf("{\"type\":\"hb\",\"up\":%lu,\"wifi_frames\":%lu,\"ble_advs\":%lu,"
                "\"rid\":%lu,\"dropped\":%lu,\"ch\":%u,\"ble\":%s,\"ble_ext\":%s}\n",
                (unsigned long)millis(),
                (unsigned long)s_cnt_wifi_frames, (unsigned long)s_cnt_ble_advs,
                (unsigned long)s_cnt_rid, (unsigned long)s_cnt_dropped, s_cur_chan,
                s_ble_ok ? "true" : "false", s_ble_ext ? "true" : "false");
}

// ---------------------------------------------- host context (home + TFRs)
// Same line protocol as the SenseCAP target, so the desktop app can treat
// any orecchino receiver identically.

bool   g_home_set = false;
double g_home_lat = 0, g_home_lon = 0;
static TfrPoly s_tfrs[TFR_MAX];
// Exposed so a screen can tell "no TFR data has ever arrived" from "no
// match in what the host pushed": an empty table must not read as clear sky.
uint8_t  g_tfr_n      = 0;      // polygons currently held
bool     g_tfr_loaded = false;  // a host has pushed TFR context at least once
uint32_t g_tfr_ms     = 0;      // when it last did (millis)

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
  for (int i = 0; i < g_tfr_n; i++) {
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

// ------------------------------------------------------ track ingest + host

#if RX_ASYNC
// Board hooks run in the loop, never on the decode task: the task notes
// which slot changed and rx_tick() calls the hook against the screen copy.
struct HookEvt { uint8_t slot; bool created, entered; uint32_t first_ms; };
static HookEvt s_hev[16];
static uint8_t s_hev_n = 0;
static void rx_note_track(Track* t, bool created, bool entered) {
  if (!created && !entered) {
    // A plain update: the loop's copy is enough, unless a board wants every
    // update; none does today (the SenseCAP only beeps on TFR entry).
    return;
  }
  if (s_hev_n < sizeof(s_hev) / sizeof(s_hev[0]))
    s_hev[s_hev_n++] = { (uint8_t)(t - s_live), created, entered, t->first_ms };
}
#else
static void rx_note_track(Track* t, bool created, bool entered) {
  rx_hook_track(t, created, entered);
}
#endif

static Track* tracker_ingest(const RidEvt* e, OdidUas* u, uint32_t now) {
  const char* uas = (u->has_basic[0] && u->uas_id[0][0]) ? u->uas_id[0] : nullptr;
  bool created = false;
  Track* t = tracker_upsert(e->mac, uas, now, &created);
  if (created) g_seen_count++;
  if (u->has_basic[0] && u->ua_type[0]) t->ua_type = u->ua_type[0];
  bool entered = false;
  t->rssi = e->rssi;
  if (e->rssi > t->peak_rssi) t->peak_rssi = e->rssi;
  t->src_mask |= (uint8_t)(1u << e->src);
  t->fmt |= u->gb46750 ? 2 : 1;
  // The beacon SSID, kept for the details view and checked: DJI puts
  // "RID-" + serial there, so an SSID serial that disagrees with the Basic
  // ID is a broadcast at odds with itself.
  if (e->ssid[0]) {
    strncpy(t->ssid, e->ssid, sizeof(t->ssid) - 1);
    t->ssid[sizeof(t->ssid) - 1] = 0;
    size_t sl = strlen(e->ssid);
    if (!strncmp(e->ssid, "RID-", 4) && sl >= 8 && sl <= 24 &&   // RID- plus a 4..20 character serial
        u->has_basic[0] && u->id_type[0] == 1) {
      bool alnum = true;
      for (const char* q = e->ssid + 4; *q; q++)
        if (!((*q >= '0' && *q <= '9') || (*q >= 'A' && *q <= 'Z') || (*q >= 'a' && *q <= 'z'))) alnum = false;
      if (alnum) t->ssid_check = strcmp(e->ssid + 4, u->uas_id[0]) == 0 ? 1 : 2;
    }
  }

  // Authentication pages arrive together in a pack or one per frame (BLE4
  // legacy rotates a single message per advertisement), so they are
  // collected per contact. The signature covers the Basic ID bytes, and
  // page 0's timestamp and type name one signature set: a different ID
  // drops everything collected, a new set drops the pages of the old one.
  OdidAuthAssembly* a = &t->auth_asm;
  bool changed = false;
  if (u->has_basic_raw) {
    if (a->has_basic_raw && memcmp(a->basic_raw, u->basic_raw, 25) != 0) {
      memset(a, 0, sizeof(*a));
      t->auth_state = ODID_AUTH_NONE;
    }
    if (!a->has_basic_raw) {
      a->has_basic_raw = true;
      memcpy(a->basic_raw, u->basic_raw, 25);
      changed = true;
    }
  }
  if (u->has_auth) {
    if (u->auth_pages_seen & 1) {
      if ((a->auth_pages_seen & 1) &&
          (a->auth_ts != u->auth_ts || a->auth_type != u->auth_type)) {
        a->auth_pages_seen = 0;
        a->verified = false;
      }
      a->auth_type      = u->auth_type;
      a->auth_last_page = u->auth_last_page;
      a->auth_len       = u->auth_len;
      a->auth_ts        = u->auth_ts;
      memcpy(a->auth_data, u->auth_data, u->auth_len < 17 ? u->auth_len : 17);
    } else if (a->verified) {
      // Pages after a complete, verified set can only belong to the next
      // one, even though its page 0 has not arrived yet: start over, so
      // the page 0 that follows does not discard them.
      a->auth_pages_seen = 0;
      a->verified = false;
    }
    for (int p = 1; p <= 15; p++) {
      if (!(u->auth_pages_seen & (1u << p))) continue;
      int off = 17 + (p - 1) * 23;
      int n = off + 23 > ODID_AUTH_MAX_BYTES ? ODID_AUTH_MAX_BYTES - off : 23;
      if (n > 0) memcpy(a->auth_data + off, u->auth_data + off, n);
    }
    a->has_auth = true;
    a->auth_pages_seen |= u->auth_pages_seen;
    changed = true;
  }
  if (a->has_auth) {
    // Hand the assembled picture back so the JSON line reports it, and
    // verify only when something new arrived: Ed25519 costs milliseconds
    // on an ESP32, which a plain Location frame should not pay.
    u->has_auth        = true;
    u->auth_type       = a->auth_type;
    u->auth_last_page  = a->auth_last_page;
    u->auth_len        = a->auth_len;
    u->auth_ts         = a->auth_ts;
    u->auth_pages_seen = a->auth_pages_seen;
    memcpy(u->auth_data, a->auth_data, sizeof(u->auth_data));
    if (a->has_basic_raw) {
      u->has_basic_raw = true;
      memcpy(u->basic_raw, a->basic_raw, 25);
    }
    if (changed) {
      uint8_t v = (uint8_t)odid_verify_auth(u);
      if (v >= ODID_AUTH_UNKNOWN_KEY) a->verified = true;   // a complete set, whatever it proved
      // While the next set is still arriving, keep the verdict of the last
      // complete one rather than flapping back to "partial" every rotation.
      if (v == ODID_AUTH_PARTIAL && t->auth_state >= ODID_AUTH_UNKNOWN_KEY)
        v = t->auth_state;
      t->auth_state = v;
    }
  }
  if (u->has_loc) {
    t->status = u->status;
    if (u->status == 3) t->emerg_ever = true;
    if (odid_coord_plausible(u->lat, u->lon)) {
      t->has_pos = true;
      t->lat = u->lat;
      t->lon = u->lon;
    }
    if (u->height > -999) {
      t->height = u->height;
      t->height_ref = u->height_ref;
      if (isnan(t->max_height) || u->height > t->max_height)
        t->max_height = u->height;
    }
    if (u->speed >= 0) t->speed = u->speed;
    if (u->dir >= 0 && u->dir <= 360) t->heading = u->dir;
    if (t->has_pos) {
      bool was = t->in_tfr;
      t->in_tfr = tfr_lookup(t->lat, t->lon, t->tfr_id, sizeof(t->tfr_id));
      if (t->in_tfr) t->tfr_ever = true;
      entered = t->in_tfr && !was;
    }
  }
  rx_note_track(t, created, entered);
  return t;
}

void trk_on_end(const Track* t) { log_add(t, millis()); }

/// One match-log record as a JSON line in s_jb (loop only, under the lock).
/// `active` marks a contact still in the table, `i` numbers ended ones.
static size_t format_log_rec(const LogRec* r, int32_t i, bool active) {
  jbegin(s_jb, sizeof(s_jb));
  jraw("{\"type\":\"log\",\"i\":"); jint(i);
  jkey("active"); jraw(active ? "true" : "false");
  jkey("uas"); { char s[25]; odid_copy_text(s, sizeof(s), (const uint8_t*)r->uas, strnlen(r->uas, sizeof(r->uas))); jstrv(s); }
  jkey("mac"); jchar('"'); jmac(r->mac); jchar('"');
  jkey("srcs"); juint(r->src_mask); jkey("fmts"); juint(r->fmt);
  jkey("ua_type"); juint(r->ua_type);
  jkey("first"); juint(r->first_utc); jkey("last"); juint(r->last_utc);
  jkey("dur"); juint(r->dur_s);
  if (r->lat_e5 != INT32_MIN) { jkey("lat"); jfix(r->lat_e5 / 1e5, 5); jkey("lon"); jfix(r->lon_e5 / 1e5, 5); }
  if (r->max_height != INT16_MIN) { jkey("max_h"); jint(r->max_height); }
  jkey("peak_rssi"); jint(r->peak_rssi);
  jkey("auth_state"); jstrv(odid_auth_state_name((OdidAuthState)r->auth_state));
  jkey("tfr"); jraw(r->flags & 1 ? "true" : "false");
  jkey("emerg"); jraw(r->flags & 2 ? "true" : "false");
  jkey("msgs"); juint(r->msgs);
  return jfinish();
}

/// {"cmd":"log_get"}: every held record oldest first, then the contacts
/// still live, then log_done. The records are copied under the lock, then
/// each line is formatted under it (the line cursor is shared with the
/// decode task) and written outside it, so a stalled USB host cannot hold
/// up decoding.
static void emit_log(uint32_t now) {
  static LogRec recs[LOG_MAX + TRK_MAX];
  int n = 0, live = 0;
  RX_LOCK();
  int held = s_log_n;
  uint32_t total = s_log_total;
  bool clock = s_utc_at_boot != 0;
  for (int i = 0; i < held; i++) recs[n++] = *log_at(i);
  for (int i = 0; i < TRK_MAX; i++)
    if (g_trk_live[i].used) { log_fill(&recs[n++], &g_trk_live[i]); live++; }
  RX_UNLOCK();
  int32_t first = (int32_t)(total - held);
  for (int i = 0; i < n; i++) {
    RX_LOCK();
    size_t len = format_log_rec(&recs[i], i < held ? first + i : -1, i >= held);
    RX_UNLOCK();
    Serial.write((const uint8_t*)s_jb, len);
  }
  RX_LOCK();
  jbegin(s_jb, sizeof(s_jb));
  jraw("{\"type\":\"log_done\",\"n\":"); juint(held);
  jkey("live"); jint(live); jkey("total"); juint(total);
  jkey("clock"); jraw(clock ? "true" : "false");
  size_t len = jfinish();
  RX_UNLOCK();
  Serial.write((const uint8_t*)s_jb, len);
  (void)now;
}

static void handle_host_line(char* line, uint32_t now) {
  char cmd[16] = {0};
  if (!json_field_str(line, "cmd", cmd, sizeof(cmd))) {
    if (rx_hook_host_line("", line, now)) return;
    return;
  }
  if (!strcmp(cmd, "set_time")) {   // every board keeps the log's clock;
    double u = 0;                    // a board with an RTC also sets that
    if (json_field_dbl(line, "utc", &u) && u > 0) {
      RX_LOCK(); log_set_utc((uint32_t)u, now); RX_UNLOCK();
#if defined(ESP_PLATFORM)
      // The system clock too: screens run their sunset dimming off time().
      struct timeval tv = { (time_t)u, 0 };
      settimeofday(&tv, nullptr);
#endif
    }
  }
  if (rx_hook_host_line(cmd, line, now)) return;
  if (!strcmp(cmd, "log_get")) { emit_log(now); return; }
  if (!strcmp(cmd, "log_clear")) {
    RX_LOCK(); log_clear(); RX_UNLOCK();
    Serial.print("{\"type\":\"log_cleared\"}\n");
    return;
  }
  RX_LOCK();
  if (!strcmp(cmd, "set_home")) {
    if (json_field_dbl(line, "lat", &g_home_lat) &&
        json_field_dbl(line, "lon", &g_home_lon))
      g_home_set = true;
  } else if (!strcmp(cmd, "tfr_clear")) {
    g_tfr_n = 0;
    g_tfr_loaded = true;
    g_tfr_ms = now;
  } else if (!strcmp(cmd, "tfr_add") && g_tfr_n < TFR_MAX) {
    TfrPoly* poly = &s_tfrs[g_tfr_n];
    poly->n = 0;
    json_field_str(line, "id", poly->id, sizeof(poly->id));
    const char* q = strstr(line, "\"pts\":[");
    if (q) q += 7;
    while (q && poly->n < TFR_PTS_MAX) {
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
    if (poly->n >= 3) {
      g_tfr_n++;
      g_tfr_loaded = true;
      g_tfr_ms = now;
    }
  }
  RX_UNLOCK();
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

// ------------------------------------------------------------- lifecycle

struct RxStats {
  uint32_t wifi_frames, ble_advs, rid, dropped;
  uint8_t  channel;
  bool     ble_ok, ble_ext;
  uint32_t heap;
};

static void rx_stats(RxStats* st) {
  st->wifi_frames = s_cnt_wifi_frames;
  st->ble_advs    = s_cnt_ble_advs;
  st->rid         = s_cnt_rid;
  st->dropped     = s_cnt_dropped;
  st->channel     = s_cur_chan;
  st->ble_ok      = s_ble_ok;
  st->ble_ext     = s_ble_ext;
  st->heap        = ESP.getFreeHeap();
}

/// Widen the promiscuous filter to every frame type (spectrum energy) or
/// back to management only (Remote ID). Pairs with rx_hook_paused().
static void rx_set_wide_filter(bool wide) {
  wifi_promiscuous_filter_t filt = {};
  filt.filter_mask = wide ? (WIFI_PROMIS_FILTER_MASK_MGMT |
                             WIFI_PROMIS_FILTER_MASK_DATA |
                             WIFI_PROMIS_FILTER_MASK_CTRL)
                          : WIFI_PROMIS_FILTER_MASK_MGMT;
  esp_wifi_set_promiscuous_filter(&filt);
}

/// Everything that happens to one queued frame: decode, update the
/// contact, and report it unless it repeats the last report of the same
/// frame from the same source within a second.
static void rx_process(const RidEvt* e, uint32_t now) {
  OdidUas u;
  if (!odid_decode_payload(e->data, e->len, &u)) { s_cnt_pfail++; return; }
  s_cnt_rid++;
  RX_LOCK();
  Track* t = tracker_ingest(e, &u, now);
  s_live_gen++;
  // FNV-1a over the frame, plus what the track adds to the line.
  uint32_t h = 2166136261u;
  for (int i = 0; i < e->len; i++) h = (h ^ e->data[i]) * 16777619u;
  h = (h ^ t->auth_state) * 16777619u;
  h = (h ^ t->ssid_check) * 16777619u;
  uint8_t si = e->src < 3 ? e->src : 0;
  bool repeat = t->emit_hash[si] == h && now - t->emit_ms[si] < 1000;
  size_t n = 0;
  if (!repeat) {
    t->emit_hash[si] = h;
    t->emit_ms[si] = now;
    n = format_rid(e, &u, t);
  }
  RX_UNLOCK();
  // s_rid_line belongs to this task alone, so it is safe to send unlocked.
  if (n) Serial.write((const uint8_t*)s_rid_line, n);
}

#if RX_ASYNC
static void rx_task(void*) {
  RidEvt e;
  for (;;)
    if (xQueueReceive(s_q, &e, portMAX_DELAY) == pdTRUE) rx_process(&e, millis());
}
#endif

/// Bring up the radios and print the boot line. `extra_json` is appended
/// inside the boot object (e.g. ",\"display\":true"), may be null.
static void rx_begin(const char* extra_json) {
  log_load();
  s_q = xQueueCreate(36, sizeof(RidEvt));
#if RX_ASYNC
  s_mx = xSemaphoreCreateMutex();
  // Above loopTask (priority 1) so a frame preempts screen drawing, on the
  // loop's core so the Wi-Fi and BT stacks keep core 0 to themselves.
  xTaskCreatePinnedToCore(rx_task, "rx_decode", 8192, nullptr, 2, nullptr,
                          CONFIG_ARDUINO_RUNNING_CORE);
#endif
  s_ble_ok = ble_start_scanner();  // bring up BT before promiscuous WiFi
  wifi_start_sniffer();
  s_cur_chan = HOP[0].chan;
#if RX_ASYNC
  esp_timer_create_args_t ta = {};
  ta.callback = hop_cb;
  ta.name = "rx_hop";
  esp_timer_create(&ta, &s_hop_timer);
  esp_timer_start_once(s_hop_timer, (uint64_t)HOP[0].dwell_ms * 1000);
#endif
  Serial.printf("{\"type\":\"boot\",\"fw\":\"%s\",\"ver\":\"%s\",\"board\":\"%s\","
                "\"ble\":%s,\"ble_ext\":%s%s}\n",
                FW_NAME, FW_VERSION, FW_BOARD, s_ble_ok ? "true" : "false",
                s_ble_ext ? "true" : "false", extra_json ? extra_json : "");
}

/// One loop pass: host lines, expiry, match-log saves, the screen's copy of
/// the track table, heartbeat. Call from loop() as often as possible; every
/// step self-throttles. (On the host build it also hops and decodes.)
static void rx_tick(uint32_t now) {
  static uint32_t last_hb = 0, last_expire = 0;
  static bool was_paused = false;

  bool paused = rx_hook_paused();
  if (paused != was_paused) {
    was_paused = paused;
    rx_set_wide_filter(paused);
    rx_ble_scan(!paused);
  }
#if !RX_ASYNC
  static uint32_t last_hop = 0;
  static size_t hop_idx = 0;
  if (!paused && now - last_hop >= HOP[hop_idx].dwell_ms) {
    last_hop = now;
    hop_idx = (hop_idx + 1) % HOP_N;
    rx_set_channel(HOP[hop_idx].chan);
  }
#endif

  poll_host_serial(now);

#if !RX_ASYNC
  RidEvt e;
  while (xQueueReceive(s_q, &e, 0) == pdTRUE) rx_process(&e, now);
#endif

  if (now - last_expire >= 5000) {
    last_expire = now;
    RX_LOCK();
    if (tracker_expire(now)) s_live_gen++;
    RX_UNLOCK();
  }

  // Match log: snapshot under the lock, write flash outside it.
  static LogImage s_img;
  bool save = false;
  RX_LOCK();
  if (log_due(now)) { log_snapshot(&s_img); save = true; }
  RX_UNLOCK();
  if (save) log_write(&s_img);

#if RX_ASYNC
  // The screen's copy, refreshed only when the live table moved.
  static uint32_t copied_gen = 0;
  HookEvt hev[16];
  uint8_t hn = 0;
  if (copied_gen != s_live_gen || s_hev_n) {
    RX_LOCK();
    memcpy(g_tracks, s_live, sizeof(g_tracks));
    copied_gen = s_live_gen;
    hn = s_hev_n;
    memcpy(hev, s_hev, hn * sizeof(HookEvt));
    s_hev_n = 0;
    RX_UNLOCK();
  }
  // A slot can change hands between the note and the copy; a hook only
  // ever sees the contact the event was about.
  for (uint8_t i = 0; i < hn; i++) {
    Track* t = &g_tracks[hev[i].slot];
    if (t->used && t->first_ms == hev[i].first_ms) rx_hook_track(t, hev[i].created, hev[i].entered);
  }
#endif

  if (now - last_hb >= 2000) {
    last_hb = now;
    emit_heartbeat();
  }
}
