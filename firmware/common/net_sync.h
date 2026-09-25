// net_sync.h — the T5's Wi-Fi: saved networks, the sync state machine that
// shares the one 2.4 GHz radio with Remote ID sniffing, the wifi_* host
// commands, and the API the T5 screen uses. docs/plans/mobile-app-and-t5-wifi.md
// §4.2 (the state machine), §4.3 (settings, phone provisioning), §4.1 (jobs).
//
// The logic here never touches the radio, the clock, NVS or HTTP directly:
// it calls a NetOps table the sketch fills in (net_esp_wifi_ops() below for
// Wi-Fi/NVS, net_fetch.h for the HTTPS jobs, the sketch for the RTC and the
// host link). tests/net_test.cpp drives this same code with fake ops.
//
// THE STATE MACHINE (one sync "window" holds the channel hop the whole time)
//
//   IDLE --(window due | SYNC NOW | UPDATE MAP | CONNECT | STAY mode)-->
//     [PICK: a ~2 s scan when 2+ networks are saved; strongest saved one seen,
//            else the saved ones in turn]
//     JOIN: begin(), 15 s; early fail on "network not found"/"wrong password"
//     FETCH: the due jobs on a worker task (net_fetch.h): TIME (SNTP), TFR,
//            ADS-B, TILES; the loop keeps running, it only polls
//     SYNC mode: LEAVE -> IDLE.  STAY mode: ONLINE (associated; ADS-B every
//            NET_ADSB_EVERY_MS (15 s), TFR/clock every 15 min; a dropped
//            link rejoins at once, then backs off)
//   Join failures back off 1, 2, 5, 15 min (never longer than the SYNC
//   interval); each job backs off on its own the same way. An HTTP 429
//   holds that job for max(Retry-After, its back-off) ("rate limited, N s").
//
//   Modes (NVS "orwifi"/"mode"): OFF (no automatic joins; SYNC NOW and a
//   CONNECT still work, and a successful CONNECT from OFF switches to SYNC),
//   SYNC (a window every 5-60 min, default 15), STAY (associated; Remote ID
//   Wi-Fi limited to the access point's channel, BLE unaffected).
//
// SAVED NETWORKS: up to 5 in NVS "orwifi" (n, s0..s4, p0..p4), most recently
// joined first, plain text (see README). A network is saved only after it
// joined. firmware/common/wifi_secrets.h (untracked, optional) supplies one
// more when nothing is saved; forgetting it sets "nobuiltin".
//
// PHONE CONNECTED: while a phone is on an encrypted BLE link
// (NetOps.phone_connected, ble_link_peer_secure() on the T5) no automatic
// window starts; one in progress is dropped at once (join abandoned, fetch
// cancelled, station left, hop released, the worker drains in NP_DRAIN) and
// STAY lets go of the access point: "paused", then "idle". The drained
// worker's report still follows as "synced", marked "phone":"cancelled" (the
// jobs it cut short listed in "cancelled", not "failed", and not backed off)
// or "phone":"completed before pause" (nothing was cut: only the report came
// after the pause). The promiscuous sniffer and the hop never
// stop. What a person asks for still runs (SCAN, CONNECT/wifi_join, SYNC NOW,
// UPDATE MAP, a mode change that joins), then leaves. When the phone goes,
// automatic windows resume after a 10 s grace (a window that fell due
// meanwhile runs then). Shown as net_is_paused(), "Wi-Fi paused: phone
// connected", "paused":"phone" in wifi_status, and net lines "paused"
// (+"reason":"phone") / "resumed".
//
// HOST COMMANDS (net_host_line; replies go to the asking transport only)
//   {"cmd":"wifi_status"}
//       -> a wifi_status line (below)
//   {"cmd":"wifi_scan"}
//       -> {"type":"wifi_net","ssid":"Home","rssi":-58,"secure":true,"saved":true,"ch":6}
//          per network (strongest first, hidden and duplicate SSIDs dropped, max 16),
//          then {"type":"wifi_scan_done","n":4}  (with "err":"scan failed" on failure)
//   {"cmd":"wifi_join","ssid":"Home","psk":"secret"}   (psk "": open; absent: the saved one)
//       -> wifi_status with "state":"connecting" now, then "connected" or
//          "failed" + "reason" (wrong password | network not found | no IP address
//          | timed out | could not connect | cancelled). Saved only on success.
//   {"cmd":"wifi_forget","ssid":"Home"}                    -> wifi_status
//   {"cmd":"wifi_mode","mode":"off|sync|stay","every_min":15}  -> wifi_status
//   {"cmd":"wifi_config","adsb_km":10,"tile_km":3}  (either or both; clamped:
//       ADS-B 5-30 km, map 1 km to what the flash holds; a stored map radius
//       above that is cut to it, and kept, when a tile plan arrives) -> wifi_status
//   A refused or malformed command: {"type":"wifi_err","cmd":"wifi_join","reason":"..."}
//   wifi_join/forget/mode/config need a bonded BLE link, or USB while the board's
//   SYSTEM screen has Wi-Fi setup open (net_serial_setup(); 5 min), so a USB
//   cable alone cannot change the networks. Build with
//   -DNET_SERIAL_PROVISIONING=1 to allow USB always (bench use).
//
//   wifi_status: {"type":"wifi_status","state":"off|idle|connecting|connected|failed",
//     "mode":"off|sync|stay","every_min":15,"ssid":"Home","ip":"192.168.1.5","ch":6,
//     "rssi":-60,"reason":"wrong password","scanning":false,"syncing":false,
//     "clock":true,"position":true,"tfr_n":3,"ac_n":14,"adsb_km":10,"tile_km":3,
//     "tile_max_km":14.75,"paused":"phone",
//     "last_sync":1790000000,"adsb_age_s":12,
//     "saved":["Home","Hangar"]}
//     (ssid/ip/ch/rssi only while connecting/connected; reason only when set;
//     paused only while a phone pauses automatic Wi-Fi; tile_max_km (the
//     largest map radius the flash holds, from the last tile plan),
//     last_sync, adsb_age_s only when known.)
//
// BROADCAST STATUS LINES (every transport): {"type":"net","state":"paused",
//   "reason":"phone"} / "resumed" / "connecting",
//   "ssid":..} / "connected" (+ip, ch, rssi, clock) / "failed" (+reason) /
//   "synced" (+ok, failed lists, tfr, ac, tiles, tiles_left, heap_int, heap_blk,
//   heap_tls, position, err; adsb_km when ADS-B was asked for; map (the plan,
//   "Map: 3 km z12-15; 0.8 MB of 11.9 MB"), map_tiles, map_have, tile_max_km,
//   storage_full when a tile job ran; "cancelled":[jobs] when a cancel cut
//   jobs short; "phone":"cancelled" | "completed before pause" when a phone
//   paused the window first) / "lost" / "idle". heap_int/heap_blk: internal
//   heap free and its largest block before the first HTTPS request (or at the
//   end of the fetch when none ran); heap_tls: free with a TLS session open
//   (bytes; 0: no TLS ran). position false: no home position, so TFR, ADS-B
//   and tiles were skipped; err then reads NET_NO_POSITION_TEXT.
//
// Threading: everything here runs on the loop task (net_tick, the UI's
// calls, host commands). Only net_fetch.h's worker runs elsewhere, and it
// talks to this file through jobs_start/jobs_poll.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>
#include <stdio.h>
#include <math.h>
#include <time.h>
#include "net_parse.h"

#define NET_MAX_SSID_LEN 32
#define NET_MAX_PASS_LEN 64
#define NET_MAX_NETWORKS 16
#define NET_MAX_SAVED    5

#define NET_JOIN_TIMEOUT_MS   15000u
#define NET_SCAN_TIMEOUT_MS   15000u
#define NET_EVERY_MIN_DEFAULT 15
#define NET_EVERY_MIN_MIN     5
#define NET_EVERY_MIN_MAX     60
#define NET_CLOCK_EVERY_MS    (15u * 60u * 1000u)
#define NET_TFR_EVERY_MS      (15u * 60u * 1000u)
// STAY mode's ADS-B cadence (SYNC: every window). adsb.lol answered HTTP
// 429 after four fetches 10 s apart; 15 s stays under its limit, and a 429
// still holds the job for max(Retry-After, the back-off), never shorter.
#define NET_ADSB_EVERY_MS     15000u
#define NET_RATE_LIMIT_MIN_MS 60000u               // an HTTP 429 without Retry-After holds this long
#define NET_RATE_LIMIT_MAX_S  3600u                // a Retry-After longer than this is cut to it
#define NET_TILES_EVERY_MS    (7u * 24u * 3600u * 1000u)
#define NET_TILE_BUDGET_AUTO  8                    // new tiles per automatic window (~4 s)
#define NET_SKIP_RETRY_MS     60000u               // a job skipped (no position...) retries after
#define NET_FETCH_GUARD_MS    120000u              // cancel a fetch (without tiles) running longer
#define NET_DUE_SLACK_MS      60000u               // a 15-min job is due at 14 min (windows vary in length)
#define NET_SERIAL_SETUP_MS   (5u * 60u * 1000u)
#define NET_RESUME_GRACE_MS   10000u               // after the phone leaves, before an automatic window
// Said once, wherever the sync status shows, when there is no home position
// (no GPS fix, nothing from the app, nothing saved): TFR, ADS-B and tiles
// all need one.
#define NET_NO_POSITION_TEXT  "no position: set home from the app or wait for GPS"
#ifndef NET_SERIAL_PROVISIONING
#define NET_SERIAL_PROVISIONING 0
#endif

typedef enum {
  NET_MODE_OFF  = 0,
  NET_MODE_SYNC = 1,
  NET_MODE_STAY = 2
} NetMode;

typedef enum {
  NET_STATE_DISCONNECTED = 0,
  NET_STATE_CONNECTING   = 1,
  NET_STATE_CONNECTED    = 2,
  NET_STATE_FAILED       = 3
} NetState;

typedef struct {
  char    ssid[NET_MAX_SSID_LEN + 1];
  int8_t  rssi;
  uint8_t auth_mode;   // wifi_auth_mode_t: 0 open, 1 WEP, 2 WPA, 3 WPA2, 4 WPA/WPA2, 6 WPA3, ...
  uint8_t channel;
  bool    saved;       // one of the saved networks
} ScannedNetwork;

typedef struct {
  char ssid[NET_MAX_SSID_LEN + 1];
  char pass[NET_MAX_PASS_LEN + 1];
  bool builtin;        // from wifi_secrets.h, never written to NVS
} NetSaved;

typedef struct {
  NetSaved saved[NET_MAX_SAVED];
  uint8_t  n;
  uint8_t  mode;
  uint8_t  every_min;
  bool     builtin_off;
  uint8_t  adsb_km;      // ADS-B query radius around home (5-30; NVS "adsb_km")
  uint8_t  tile_km;      // map area radius (1-30, shrunk to fit; NVS "tile_km")
} NetConfig;

typedef enum {
  NET_LINK_PENDING = 0,   // joining, nothing decisive yet
  NET_LINK_ASSOC,         // associated, no IP address yet
  NET_LINK_UP,            // associated with an IP address
  NET_LINK_DOWN,          // not associated
  NET_LINK_NO_AP,         // the network was not found
  NET_LINK_AUTH_FAIL      // rejected: wrong password
} NetLink;

#define NET_SCAN_RUNNING (-1)
#define NET_SCAN_FAILED  (-2)

enum {
  NET_JOB_TIME  = 1,
  NET_JOB_TFR   = 2,
  NET_JOB_ADSB  = 4,
  NET_JOB_TILES = 8
};
#define NET_JOB_COUNT 4

typedef struct {
  uint32_t jobs;
  uint16_t tile_budget;   // new tiles at most; 0xFFFF: all (UPDATE MAP)
  double   adsb_radius_m; // the ADS-B radius set (widened around far drones, <= 30 km)
  double   tile_radius_m; // the map radius set (the plan shrinks it to fit)
} NetJobReq;

typedef struct {
  uint32_t ok, failed, skipped;   // NET_JOB_* bits
  uint32_t cancelled;             // cut short or never started by a cancel: not failures (no back-off)
  uint32_t rate_limited;          // answered HTTP 429 (also in failed): held for Retry-After at least
  uint32_t retry_after_s;         // the first 429's Retry-After in seconds (0: none given)
  uint32_t utc;                   // TIME: the server's time...
  uint32_t utc_at_ms;             // ...at this millis()
  uint16_t tfr_n, ac_n;
  uint16_t tiles_new, tiles_left; // tiles_left 0: the area is complete
  uint32_t heap_free, heap_block; // internal heap before the first HTTPS request (0 unknown)
  uint32_t heap_tls;              // internal heap free with a TLS session open (0: no TLS ran)
  bool     no_position;           // TFR/ADS-B/tiles skipped: no home position
  double   adsb_lat, adsb_lon, adsb_radius_m;   // where ADS-B was asked for (radius 0: not)
  bool     have_plan;             // TILES: the plan it worked to
  TilePlan plan;
  double   tile_max_m;            // the largest map radius this flash holds (z12-15)
  bool     storage_full;          // TILES stopped at the 1 MB reserve
  char     err[64];               // the first failure (or skip) in words
} NetJobResult;

typedef struct {
  void     (*setup)(void);
  void     (*begin)(const char* ssid, const char* pass);   // pass "" for open
  void     (*leave)(void);            // disconnect, keep the sniffer running
  NetLink  (*link)(void);
  bool     (*scan_start)(void);
  int      (*scan_poll)(ScannedNetwork* out, int max);     // NET_SCAN_* or a count
  void     (*ip)(char* out, size_t n);
  int      (*rssi)(void);
  uint8_t  (*channel)(void);
  void     (*hop_hold)(bool hold);    // rx_hop_hold
  void     (*load)(NetConfig* c);
  void     (*store)(const NetConfig* c);
  bool     (*jobs_start)(const NetJobReq* req);
  bool     (*jobs_poll)(NetJobResult* out);                // true once, when done
  void     (*jobs_cancel)(void);
  void     (*set_utc)(uint32_t utc);  // system clock + RTC + log clock
  uint32_t (*utc_now)(void);          // 0 when the clock is not set
  void     (*emit)(uint8_t dst, const char* line, size_t n);  // dst: HostSrc, 255 all
  bool     (*have_position)(void);    // a home position is known (GPS, app or saved)
  bool     (*phone_connected)(void);  // a phone on an encrypted BLE link: pause automatic Wi-Fi
} NetOps;

// NP_DRAIN: the station has left (phone connected) while the fetch worker
// winds down to a safe point; the hop is already released.
enum { NP_IDLE = 0, NP_JOIN, NP_FETCH, NP_ONLINE, NP_DRAIN };

#define NET_DST_ALL 255

typedef struct {
  NetOps   ops;
  bool     have_ops;
  uint32_t now;
  NetConfig cfg;
  uint8_t  phase;
  NetState state;
  // the join in progress
  char     j_ssid[NET_MAX_SSID_LEN + 1];
  char     j_pass[NET_MAX_PASS_LEN + 1];
  bool     j_new;           // credentials not saved yet (saved on success)
  uint8_t  j_reply;         // transports waiting for the outcome (bit per HostSrc)
  uint32_t j_start;
  uint8_t  rot;             // next saved network to try when none is seen
  // requests from the UI / host commands, served by net_tick
  bool     rq_join;
  char     rq_ssid[NET_MAX_SSID_LEN + 1];
  char     rq_pass[NET_MAX_PASS_LEN + 1];
  bool     rq_new;
  uint8_t  rq_reply;
  bool     rq_scan;
  uint8_t  scan_reply;
  bool     rq_sync, rq_tiles, rq_leave, force_jobs;
  // scanning
  bool     scanning, scan_pick;
  uint32_t scan_start;
  ScannedNetwork scanned[NET_MAX_NETWORKS];
  uint8_t  n_scanned;
  // the link
  char     ssid[NET_MAX_SSID_LEN + 1];   // joined / being joined
  char     ip[16];
  uint8_t  ch;
  char     err[64];         // why the last join failed ("" after a success)
  char     fetch_err[64];   // why the last fetch job failed
  bool     no_position;     // the last fetch had no home position
  uint8_t  fails;
  bool     sched;           // next_try is meaningful
  uint32_t next_try, window_start;
  bool     hold;
  // jobs
  bool     clock_synced;
  uint32_t clock_ms, last_sync_utc;
  bool     tfr_ok;   uint32_t tfr_ms;   uint16_t tfr_n;
  bool     adsb_ok;  uint32_t adsb_ms;  uint16_t ac_n;
  bool     adsb_tried; uint32_t adsb_try_ms;
  bool     tiles_ok; uint32_t tiles_ms;
  uint8_t  job_fails[NET_JOB_COUNT];
  bool     job_wait[NET_JOB_COUNT];
  uint32_t job_retry[NET_JOB_COUNT];
  uint32_t fetch_start, fetch_jobs;
  bool     fetch_cancel;
  uint32_t heap_free, heap_block, heap_tls;
  bool     serial_setup;
  uint32_t serial_setup_until;
  // phone pause
  bool     paused;          // a phone is connected (encrypted BLE)
  bool     resume_wait;     // the phone left: automatic windows wait until resume_at
  uint32_t resume_at;
  bool     win_manual;      // this window was asked for by a person (CONNECT, SYNC NOW...)
  // the map
  bool     have_plan;
  TilePlan plan;
  double   tile_max_m;      // 0 unknown
  bool     storage_full;
  double   adsb_radius_m;   // last ADS-B query radius (0 none yet)
} NetSm;

// Tile job progress, written by the fetch worker (net_fetch.h).
inline volatile uint16_t g_net_tiles_done = 0;
inline volatile uint16_t g_net_tiles_total = 0;
inline volatile bool     g_net_tiles_running = false;

static inline NetSm net__initial() {
  NetSm g;
  memset(&g, 0, sizeof(g));
  g.cfg.mode = NET_MODE_SYNC;
  g.cfg.every_min = NET_EVERY_MIN_DEFAULT;
  g.cfg.adsb_km = NET_ADSB_KM_DEFAULT;
  g.cfg.tile_km = NET_TILE_KM_DEFAULT;
  g.state = NET_STATE_DISCONNECTED;
  return g;
}

// One copy for every file that includes this header (the sketch and the UI).
inline NetSm g_net = net__initial();

// ---------------------------------------------------------------------------
// Internals

static inline uint8_t net__mask(uint8_t src) { return src < 8 ? (uint8_t)(1u << src) : 0; }

static inline void net__emit(uint8_t dst, const char* line, size_t n) {
  if (g_net.ops.emit && n) g_net.ops.emit(dst, line, n);
}
static inline void net__emit_mask(uint8_t mask, const char* line, size_t n) {
  for (uint8_t s = 0; s < 8; s++)
    if (mask & (1u << s)) net__emit(s, line, n);
}

static inline void net__hold(bool on) {
  if (g_net.hold == on) return;
  g_net.hold = on;
  if (g_net.ops.hop_hold) g_net.ops.hop_hold(on);
}

/// Copy s into out (n bytes), cut if it has to be, always terminated.
static inline void net__copy(char* out, size_t n, const char* s) {
  size_t k = 0;
  if (!n) return;
  for (; s && s[k] && k + 1 < n; k++) out[k] = s[k];
  out[k] = 0;
}

static inline const char* net_mode_name(NetMode m) {
  return m == NET_MODE_OFF ? "off" : m == NET_MODE_STAY ? "stay" : "sync";
}

static inline void net__store() {
  if (g_net.ops.store) g_net.ops.store(&g_net.cfg);
}

static inline int net__saved_index(const char* ssid) {
  for (int i = 0; i < g_net.cfg.n; i++)
    if (!strcmp(g_net.cfg.saved[i].ssid, ssid)) return i;
  return -1;
}

/// Put (ssid, pass) first in the saved list (most recently joined first).
static inline bool net__save_front(const char* ssid, const char* pass, bool builtin) {
  NetConfig* c = &g_net.cfg;
  int i = net__saved_index(ssid);
  if (i == 0 && !strcmp(c->saved[0].pass, pass) && c->saved[0].builtin == builtin) return false;
  NetSaved s;
  memset(&s, 0, sizeof(s));
  net__copy(s.ssid, sizeof(s.ssid), ssid);
  net__copy(s.pass, sizeof(s.pass), pass);
  s.builtin = builtin;
  int last = (i >= 0) ? i : (c->n < NET_MAX_SAVED ? c->n : NET_MAX_SAVED - 1);
  for (int k = last; k > 0; k--) c->saved[k] = c->saved[k - 1];
  c->saved[0] = s;
  if (i < 0 && c->n < NET_MAX_SAVED) c->n++;
  return true;
}

// Backoff after the k-th consecutive failure: 1, 2, 5, 15 min.
static inline uint32_t net__backoff_ms(uint8_t k) {
  static const uint16_t min[4] = { 1, 2, 5, 15 };
  uint8_t i = k == 0 ? 0 : (uint8_t)(k - 1);
  if (i > 3) i = 3;
  return (uint32_t)min[i] * 60000u;
}

/// A Retry-After header's value in seconds: "120" -> 120 (cut to
/// NET_RATE_LIMIT_MAX_S); an HTTP-date, or nothing, -> 0 (the caller's
/// minimum applies; the board's clock may not be set to compare a date).
static inline uint32_t net_retry_after_s(const char* v) {
  if (!v) return 0;
  while (*v == ' ' || *v == '\t') v++;
  uint32_t s = 0;
  const char* p = v;
  for (; *p >= '0' && *p <= '9'; p++) {
    s = s * 10 + (uint32_t)(*p - '0');
    if (s > NET_RATE_LIMIT_MAX_S) s = NET_RATE_LIMIT_MAX_S;
  }
  if (p == v) return 0;
  while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;
  return *p ? 0 : s;   // digits followed by anything else: a date ("Wed, 21 Oct...")
}

static inline size_t net__status_json(char* out, size_t n) {
  NetSm& g = g_net;
  const char* st;
  switch (g.state) {
    case NET_STATE_CONNECTING: st = "connecting"; break;
    case NET_STATE_CONNECTED:  st = "connected"; break;
    case NET_STATE_FAILED:     st = "failed"; break;
    default: st = g.cfg.mode == NET_MODE_OFF ? "off" : "idle"; break;
  }
  size_t k = (size_t)snprintf(out, n, "{\"type\":\"wifi_status\",\"state\":\"%s\",\"mode\":\"%s\",\"every_min\":%u",
                              st, net_mode_name((NetMode)g.cfg.mode), (unsigned)g.cfg.every_min);
  char esc[6 * NET_MAX_SSID_LEN + 1];
  if (k < n && (g.state == NET_STATE_CONNECTING || g.state == NET_STATE_CONNECTED)) {
    net_json_esc(esc, sizeof(esc), g.ssid);
    k += (size_t)snprintf(out + k, n - k, ",\"ssid\":\"%s\"", esc);
    if (k < n && g.state == NET_STATE_CONNECTED) {
      int rssi = g.ops.rssi ? g.ops.rssi() : -127;
      k += (size_t)snprintf(out + k, n - k, ",\"ip\":\"%s\",\"ch\":%u,\"rssi\":%d", g.ip, (unsigned)g.ch, rssi);
    }
  }
  const char* reason = g.err[0] ? g.err : g.fetch_err;
  if (k < n && reason[0]) {
    net_json_esc(esc, sizeof(esc), reason);
    k += (size_t)snprintf(out + k, n - k, ",\"reason\":\"%s\"", esc);
  }
  if (k < n)
    k += (size_t)snprintf(out + k, n - k, ",\"scanning\":%s,\"syncing\":%s,\"clock\":%s,\"position\":%s,\"tfr_n\":%u,\"ac_n\":%u",
                          g.scanning ? "true" : "false", g.phase == NP_FETCH ? "true" : "false",
                          g.clock_synced ? "true" : "false", g.no_position ? "false" : "true",
                          (unsigned)g.tfr_n, (unsigned)g.ac_n);
  if (k < n)
    k += (size_t)snprintf(out + k, n - k, ",\"adsb_km\":%u,\"tile_km\":%u", (unsigned)g.cfg.adsb_km,
                          (unsigned)g.cfg.tile_km);
  if (k < n && g.tile_max_m > 0)
    k += (size_t)snprintf(out + k, n - k, ",\"tile_max_km\":%.2f", g.tile_max_m / 1000.0);
  if (k < n && g.paused && g.cfg.mode != NET_MODE_OFF)
    k += (size_t)snprintf(out + k, n - k, ",\"paused\":\"phone\"");
  if (k < n && g.last_sync_utc)
    k += (size_t)snprintf(out + k, n - k, ",\"last_sync\":%lu", (unsigned long)g.last_sync_utc);
  if (k < n && g.adsb_ok)
    k += (size_t)snprintf(out + k, n - k, ",\"adsb_age_s\":%lu", (unsigned long)((g.now - g.adsb_ms) / 1000u));
  if (k < n) k += (size_t)snprintf(out + k, n - k, ",\"saved\":[");
  for (int i = 0; i < g.cfg.n && k < n; i++) {
    net_json_esc(esc, sizeof(esc), g.cfg.saved[i].ssid);
    k += (size_t)snprintf(out + k, n - k, "%s\"%s\"", i ? "," : "", esc);
  }
  if (k < n) k += (size_t)snprintf(out + k, n - k, "]}\n");
  return k < n ? k : 0;   // a line that did not fit is not sent at all
}

static inline void net__reply_status(uint8_t mask) {
  if (!mask) return;
  char line[1024];
  size_t n = net__status_json(line, sizeof(line));
  net__emit_mask(mask, line, n);
}

static inline void net__reply_err(uint8_t src, const char* cmd, const char* reason) {
  char line[160];
  int n = snprintf(line, sizeof(line), "{\"type\":\"wifi_err\",\"cmd\":\"%s\",\"reason\":\"%s\"}\n", cmd, reason);
  if (n > 0 && n < (int)sizeof(line)) net__emit(src, line, (size_t)n);
}

static inline void net__broadcast(const char* state, const char* extra) {
  char line[800], esc[6 * NET_MAX_SSID_LEN + 1];
  net_json_esc(esc, sizeof(esc), g_net.ssid);
  int n = snprintf(line, sizeof(line), "{\"type\":\"net\",\"state\":\"%s\",\"ssid\":\"%s\"%s}\n",
                   state, esc, extra ? extra : "");
  if (n > 0 && n < (int)sizeof(line)) net__emit(NET_DST_ALL, line, (size_t)n);
}

/// A usable WPA passphrase: empty (open), 8-63 characters, or 64 hex digits.
static inline bool net_pass_ok(const char* p) {
  size_t n = strlen(p);
  if (n == 0) return true;
  if (n >= 8 && n <= 63) return true;
  if (n != 64) return false;
  for (size_t i = 0; i < n; i++) {
    char c = p[i];
    if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) return false;
  }
  return true;
}

// -- scanning

static inline void net__scan_done(int r);
static inline void net__join_begin(const char* ssid, const char* pass, bool is_new, uint8_t reply);

static inline void net__scan_begin(bool pick) {
  NetSm& g = g_net;
  g.scanning = true;
  g.scan_pick = pick;
  g.scan_start = g.now;
  g.n_scanned = 0;
  if (!pick) g.rq_scan = false;
  net__hold(true);   // the scan tunes the radio itself
  if (!g.ops.scan_start || !g.ops.scan_start()) net__scan_done(NET_SCAN_FAILED);
}

static inline void net__scan_done(int r) {
  NetSm& g = g_net;
  g.scanning = false;
  g.n_scanned = 0;
  if (r > 0) {
    ScannedNetwork raw[NET_MAX_NETWORKS];
    int m = r > NET_MAX_NETWORKS ? NET_MAX_NETWORKS : r;
    memcpy(raw, g.scanned, sizeof(ScannedNetwork) * (size_t)m);   // scan_poll wrote here
    for (int i = 0; i < m; i++) {
      if (!raw[i].ssid[0]) continue;                // hidden
      int dup = -1;
      for (int k = 0; k < g.n_scanned; k++)
        if (!strcmp(g.scanned[k].ssid, raw[i].ssid)) { dup = k; break; }
      if (dup >= 0) {
        if (raw[i].rssi > g.scanned[dup].rssi) g.scanned[dup] = raw[i];
        continue;
      }
      g.scanned[g.n_scanned++] = raw[i];
    }
    // strongest first (insertion sort; 16 at most)
    for (int i = 1; i < g.n_scanned; i++) {
      ScannedNetwork t = g.scanned[i];
      int k = i - 1;
      while (k >= 0 && g.scanned[k].rssi < t.rssi) { g.scanned[k + 1] = g.scanned[k]; k--; }
      g.scanned[k + 1] = t;
    }
    for (int i = 0; i < g.n_scanned; i++) g.scanned[i].saved = net__saved_index(g.scanned[i].ssid) >= 0;
  }
  if (g.scan_reply) {
    char line[256], esc[6 * NET_MAX_SSID_LEN + 1];
    for (int i = 0; i < g.n_scanned; i++) {
      const ScannedNetwork* s = &g.scanned[i];
      net_json_esc(esc, sizeof(esc), s->ssid);
      int n = snprintf(line, sizeof(line),
                       "{\"type\":\"wifi_net\",\"ssid\":\"%s\",\"rssi\":%d,\"secure\":%s,\"saved\":%s,\"ch\":%u}\n",
                       esc, (int)s->rssi, s->auth_mode ? "true" : "false", s->saved ? "true" : "false",
                       (unsigned)s->channel);
      if (n > 0 && n < (int)sizeof(line)) net__emit_mask(g.scan_reply, line, (size_t)n);
    }
    int n = snprintf(line, sizeof(line), "{\"type\":\"wifi_scan_done\",\"n\":%u%s}\n", (unsigned)g.n_scanned,
                     r < 0 ? ",\"err\":\"scan failed\"" : "");
    net__emit_mask(g.scan_reply, line, (size_t)n);
    g.scan_reply = 0;
  }
  if (g.scan_pick) {
    g.scan_pick = false;
    // The strongest saved network in sight, else the saved ones in turn
    // (it may be hidden, or the scan missed it).
    int best = -1;
    for (int i = 0; i < g.n_scanned && best < 0; i++) {
      int k = net__saved_index(g.scanned[i].ssid);
      if (k >= 0) best = k;
    }
    if (best < 0 && g.cfg.n) best = g.rot % g.cfg.n;
    if (best >= 0 && g.phase == NP_IDLE && !g.rq_join && !g.rq_leave && !(g.paused && !g.win_manual))
      net__join_begin(g.cfg.saved[best].ssid, g.cfg.saved[best].pass, false, 0);
  }
}

static inline void net__scan_poll() {
  NetSm& g = g_net;
  int r = g.ops.scan_poll ? g.ops.scan_poll(g.scanned, NET_MAX_NETWORKS) : NET_SCAN_FAILED;
  if (r == NET_SCAN_RUNNING) {
    if (g.now - g.scan_start < NET_SCAN_TIMEOUT_MS) return;
    r = NET_SCAN_FAILED;
  }
  net__scan_done(r);
}

// -- joining and leaving

static inline void net__join_begin(const char* ssid, const char* pass, bool is_new, uint8_t reply) {
  NetSm& g = g_net;
  net__copy(g.j_ssid, sizeof(g.j_ssid), ssid);
  net__copy(g.j_pass, sizeof(g.j_pass), pass);
  net__copy(g.ssid, sizeof(g.ssid), ssid);
  g.j_new = is_new;
  g.j_reply = reply;
  g.j_start = g.now;
  g.window_start = g.now;
  g.phase = NP_JOIN;
  g.state = NET_STATE_CONNECTING;
  g.ip[0] = 0;
  g.ch = 0;
  net__hold(true);   // before the radio moves to the access point's channel
  if (g.ops.begin) g.ops.begin(g.j_ssid, g.j_pass);
  net__reply_status(reply);
  net__broadcast("connecting", NULL);
}

static inline void net__leave() {
  NetSm& g = g_net;
  if (g.ops.leave) g.ops.leave();
  g.phase = NP_IDLE;
  g.win_manual = false;   // the window a person asked for ends here
  if (g.state != NET_STATE_FAILED) g.state = NET_STATE_DISCONNECTED;
  g.ip[0] = 0;
  g.ch = 0;
}

static inline void net__join_fail(const char* reason) {
  NetSm& g = g_net;
  net__leave();
  g.state = NET_STATE_FAILED;
  net__copy(g.err, sizeof(g.err), reason);
  if (!g.j_new) {   // a saved network: back off (a typed one just reports)
    g.fails++;
    g.rot++;
    uint32_t d = net__backoff_ms(g.fails);
    uint32_t every = (uint32_t)g.cfg.every_min * 60000u;
    if (g.cfg.mode == NET_MODE_SYNC && d > every) d = every;
    g.next_try = g.now + d;
    g.sched = true;
  }
  net__reply_status(g.j_reply);
  g.j_reply = 0;
  char extra[160], esc[100];
  net_json_esc(esc, sizeof(esc), reason);
  snprintf(extra, sizeof(extra), ",\"reason\":\"%s\"", esc);
  net__broadcast("failed", extra);
}

static inline uint32_t net__due();
static inline void net__fetch_begin(uint32_t jobs);
static inline void net__after_window();

static inline void net__joined() {
  NetSm& g = g_net;
  g.state = NET_STATE_CONNECTED;
  g.phase = NP_ONLINE;
  g.err[0] = 0;
  g.fails = 0;
  g.rot = 0;
  if (g.ops.ip) g.ops.ip(g.ip, sizeof(g.ip));
  g.ch = g.ops.channel ? g.ops.channel() : 0;
  int bi = net__saved_index(g.j_ssid);
  bool builtin = bi >= 0 && g.cfg.saved[bi].builtin && !g.j_new;
  bool changed = net__save_front(g.j_ssid, g.j_pass, builtin);
  if (g.j_new && g.cfg.mode == NET_MODE_OFF) { g.cfg.mode = NET_MODE_SYNC; changed = true; }
  if (changed) net__store();
  g.j_new = false;
  g.sched = true;
  g.next_try = g.window_start + (uint32_t)g.cfg.every_min * 60000u;
  net__reply_status(g.j_reply);
  g.j_reply = 0;
  char extra[160];
  int rssi = g.ops.rssi ? g.ops.rssi() : -127;
  snprintf(extra, sizeof(extra), ",\"ip\":\"%.*s\",\"ch\":%u,\"rssi\":%d,\"clock\":%s",
           (int)sizeof(g.ip) - 1, g.ip, (unsigned)g.ch, rssi, g.clock_synced ? "true" : "false");
  net__broadcast("connected", extra);
  uint32_t jobs = net__due();
  if (jobs) net__fetch_begin(jobs);
  else net__after_window();
}

static inline void net__join_poll() {
  NetSm& g = g_net;
  if (g.rq_join || g.rq_leave) {   // superseded by a new CONNECT, or mode OFF
    uint8_t reply = g.j_reply;
    g.j_reply = 0;
    net__leave();
    g.state = NET_STATE_DISCONNECTED;
    if (reply) {
      net__copy(g.err, sizeof(g.err), "cancelled");
      net__reply_status(reply);
      g.err[0] = 0;
    }
    return;
  }
  NetLink l = g.ops.link ? g.ops.link() : NET_LINK_PENDING;
  if (l == NET_LINK_UP) { net__joined(); return; }
  if (l == NET_LINK_NO_AP) { net__join_fail("network not found"); return; }
  if (l == NET_LINK_AUTH_FAIL) { net__join_fail("wrong password"); return; }
  if (g.now - g.j_start >= NET_JOIN_TIMEOUT_MS)
    net__join_fail(l == NET_LINK_ASSOC ? "no IP address" : l == NET_LINK_DOWN ? "could not connect" : "timed out");
}

// -- jobs

static inline bool net__job_ready(int k) {
  return !g_net.job_wait[k] || (int32_t)(g_net.now - g_net.job_retry[k]) >= 0;
}

/// The jobs due now (NET_JOB_* bits).
static inline uint32_t net__due() {
  NetSm& g = g_net;
  uint32_t j = 0;
  uint32_t now = g.now;
  bool force = g.force_jobs;
  // Job times are the start of the fetch that did them; the slack keeps a
  // 15-min job in step with 15-min windows whose joins take varying time.
  if (force || (net__job_ready(0) && (!g.clock_synced || now - g.clock_ms + NET_DUE_SLACK_MS >= NET_CLOCK_EVERY_MS)))
    j |= NET_JOB_TIME;
  if (force || (net__job_ready(1) && (!g.tfr_ok || now - g.tfr_ms + NET_DUE_SLACK_MS >= NET_TFR_EVERY_MS)))
    j |= NET_JOB_TFR;
  if (force || (net__job_ready(2) && (!g.adsb_tried || now - g.adsb_try_ms >= NET_ADSB_EVERY_MS))) j |= NET_JOB_ADSB;
  // UPDATE MAP lifts a back-off when asked (net_update_map), but a hold
  // set since (a tile source's 429) keeps even that waiting.
  if (net__job_ready(3) && (g.rq_tiles || !g.tiles_ok || now - g.tiles_ms >= NET_TILES_EVERY_MS))
    j |= NET_JOB_TILES;
  return j;
}

static inline void net__fetch_done(const NetJobResult* r);

static inline void net__fetch_begin(uint32_t jobs) {
  NetSm& g = g_net;
  NetJobReq req;
  req.jobs = jobs;
  req.tile_budget = g.rq_tiles ? 0xFFFF : NET_TILE_BUDGET_AUTO;
  req.adsb_radius_m = g.cfg.adsb_km * 1000.0;
  req.tile_radius_m = g.cfg.tile_km * 1000.0;
  g.force_jobs = false;
  g.rq_sync = false;
  g.phase = NP_FETCH;
  g.fetch_start = g.now;
  g.fetch_jobs = jobs;
  g.fetch_cancel = false;
  if (jobs & NET_JOB_ADSB) { g.adsb_tried = true; g.adsb_try_ms = g.now; }
  if (!g.ops.jobs_start || !g.ops.jobs_start(&req)) {
    NetJobResult r;
    memset(&r, 0, sizeof(r));
    r.failed = jobs;
    net__copy(r.err, sizeof(r.err), "fetch could not start");
    net__fetch_done(&r);
  }
}

static inline void net__job_outcome(const NetJobResult* r, int k, uint32_t bit) {
  NetSm& g = g_net;
  if (r->ok & bit) {
    g.job_fails[k] = 0;
    g.job_wait[k] = false;
  } else if (r->failed & bit) {
    if (g.job_fails[k] < 255) g.job_fails[k]++;
    g.job_wait[k] = true;
    g.job_retry[k] = g.now + net__backoff_ms(g.job_fails[k]);
  } else if (r->skipped & bit) {
    g.job_wait[k] = true;
    g.job_retry[k] = g.now + NET_SKIP_RETRY_MS;
  }
}

/// A map radius setting within what the flash holds: 1 km to the last
/// plan's tile_max_m (up to 30 km before any plan).
static inline uint8_t net__tile_km_fit(uint8_t km) {
  uint8_t top = NET_TILE_KM_MAX;
  if (g_net.tile_max_m > 0 && g_net.tile_max_m / 1000.0 < top) top = (uint8_t)(g_net.tile_max_m / 1000.0);
  if (km > top) km = top;
  if (km < NET_TILE_KM_MIN) km = NET_TILE_KM_MIN;
  return km;
}

static inline void net__fetch_done(const NetJobResult* r) {
  NetSm& g = g_net;
  uint32_t now = g.now;
  const bool drained = g.phase == NP_DRAIN;   // a phone paused this window: already left
  if ((r->ok & NET_JOB_TIME) && r->utc >= NET_UTC_MIN) {
    // Only a real server answer counts; the clock may have looked set already.
    uint32_t utc = r->utc + (now - r->utc_at_ms + 500u) / 1000u;
    if (g.ops.set_utc) g.ops.set_utc(utc);
    g.clock_synced = true;
    g.clock_ms = g.fetch_start;
  }
  if (r->ok & NET_JOB_TFR) { g.tfr_ok = true; g.tfr_ms = g.fetch_start; g.tfr_n = r->tfr_n; }
  if (r->ok & NET_JOB_ADSB) { g.adsb_ok = true; g.adsb_ms = now; g.ac_n = r->ac_n; }
  if (r->ok & NET_JOB_TILES) {
    if (r->tiles_left == 0) {
      g.tiles_ok = true;
      g.tiles_ms = g.fetch_start;
      g.rq_tiles = false;
    }
  }
  // A cancel is no failure (a phone, a new CONNECT, mode OFF: the jobs stay
  // due, no back-off), except the fetch guard's: a fetch that hung that long failed.
  NetJobResult o = *r;
  if (g.fetch_cancel && !drained && !g.rq_join && !g.rq_leave) o.failed |= o.cancelled;
  if (o.failed & NET_JOB_TILES) g.rq_tiles = false;   // an UPDATE MAP that failed is reported, not retried forever
  for (int k = 0; k < NET_JOB_COUNT; k++) net__job_outcome(&o, k, 1u << k);
  // HTTP 429: the source asked for a pause. Hold the job for its Retry-After
  // (NET_RATE_LIMIT_MIN_MS at least), or the back-off if that is longer, so
  // STAY's cadence never runs into the limit again at once.
  const char* err = r->err;
  char rate_err[64];
  if (r->rate_limited) {
    static const char* const jobs[NET_JOB_COUNT] = { "CLOCK", "TFR", "ADS-B", "MAP" };
    uint32_t ra_ms = (r->retry_after_s > NET_RATE_LIMIT_MAX_S ? NET_RATE_LIMIT_MAX_S : r->retry_after_s) * 1000u;
    bool said = false;
    for (int k = 0; k < NET_JOB_COUNT; k++) {
      if (!(r->rate_limited & (1u << k))) continue;
      uint32_t hold = g.job_wait[k] && (int32_t)(g.job_retry[k] - now) > 0 ? g.job_retry[k] - now : 0;
      if (hold < NET_RATE_LIMIT_MIN_MS) hold = NET_RATE_LIMIT_MIN_MS;
      if (hold < ra_ms) hold = ra_ms;
      g.job_wait[k] = true;
      g.job_retry[k] = now + hold;
      if (!said) {
        snprintf(rate_err, sizeof(rate_err), "%s: rate limited, %lu s", jobs[k], (unsigned long)(hold / 1000u));
        err = rate_err;
        said = true;
      }
    }
  }
  if (r->heap_free) { g.heap_free = r->heap_free; g.heap_block = r->heap_block; }
  if (r->heap_tls) g.heap_tls = r->heap_tls;
  g.no_position = r->no_position;
  if (r->have_plan) {
    g.have_plan = true;
    g.plan = r->plan;
    if (r->tile_max_m > 0) g.tile_max_m = r->tile_max_m;
    g.storage_full = r->storage_full;
    // A stored radius the flash cannot hold is cut to what does, and kept:
    // the next plan starts from it instead of shrinking 30 km in 250 m steps.
    uint8_t km = net__tile_km_fit(g.cfg.tile_km);
    if (km != g.cfg.tile_km) { g.cfg.tile_km = km; net__store(); }
  }
  if (r->adsb_radius_m > 0) g.adsb_radius_m = r->adsb_radius_m;
  // A failure, or a job skipped for a reason worth showing ("TFR: no
  // position"), or a source that asked for a pause.
  if (r->failed || r->skipped || r->cancelled || r->rate_limited) net__copy(g.fetch_err, sizeof(g.fetch_err), err);
  else g.fetch_err[0] = 0;
  if (r->ok && g.ops.utc_now) {
    uint32_t u = g.ops.utc_now();
    if (u) g.last_sync_utc = u;
  }
  // {"type":"net","state":"synced",...}
  static const char* const names[NET_JOB_COUNT] = { "time", "tfr", "adsb", "tiles" };
  char extra[640], esc[100];
  size_t k = 0;
  for (int pass = 0; pass < 3; pass++) {
    uint32_t bits = pass == 0 ? r->ok : pass == 1 ? r->failed : r->cancelled;
    if (pass == 2 && !bits) break;   // "cancelled" only when a cancel cut something
    k += (size_t)snprintf(extra + k, sizeof(extra) - k, ",\"%s\":[",
                          pass == 0 ? "ok" : pass == 1 ? "failed" : "cancelled");
    bool first = true;
    for (int j = 0; j < NET_JOB_COUNT && k < sizeof(extra); j++)
      if (bits & (1u << j)) {
        k += (size_t)snprintf(extra + k, sizeof(extra) - k, "%s\"%s\"", first ? "" : ",", names[j]);
        first = false;
      }
    if (k < sizeof(extra)) k += (size_t)snprintf(extra + k, sizeof(extra) - k, "]");
  }
  net_json_esc(esc, sizeof(esc), err);
  if (k < sizeof(extra))
    snprintf(extra + k, sizeof(extra) - k,
             ",\"tfr\":%u,\"ac\":%u,\"tiles\":%u,\"tiles_left\":%u,\"heap_int\":%lu,\"heap_blk\":%lu,\"heap_tls\":%lu,\"position\":%s,\"err\":\"%s\"",
             (unsigned)r->tfr_n, (unsigned)r->ac_n, (unsigned)r->tiles_new, (unsigned)r->tiles_left,
             (unsigned long)r->heap_free, (unsigned long)r->heap_block, (unsigned long)r->heap_tls,
             r->no_position ? "false" : "true", esc);
  if (r->have_plan || r->adsb_radius_m > 0) {
    size_t e = strlen(extra);
    if (r->adsb_radius_m > 0 && e < sizeof(extra))
      e += (size_t)snprintf(extra + e, sizeof(extra) - e, ",\"adsb_km\":%.1f", r->adsb_radius_m / 1000.0);
    if (r->have_plan && e < sizeof(extra)) {
      char map[96];
      tile_plan_describe(&r->plan, map, sizeof(map));
      snprintf(extra + e, sizeof(extra) - e, ",\"map\":\"%s\",\"map_tiles\":%u,\"map_have\":%u,\"tile_max_km\":%.2f%s",
               map, (unsigned)r->plan.total, (unsigned)r->plan.present, r->tile_max_m / 1000.0,
               r->storage_full ? ",\"storage_full\":true" : "");
    }
  }
  if (drained) {   // the report comes after "paused": say what the pause did to it
    size_t e = strlen(extra);
    if (e < sizeof(extra))
      snprintf(extra + e, sizeof(extra) - e, ",\"phone\":\"%s\"",
               r->cancelled ? "cancelled" : "completed before pause");
  }
  net__broadcast("synced", extra);
  if (drained) { g.phase = NP_IDLE; return; }   // already left (phone connected)
  if (g.rq_join || g.rq_leave) { net__leave(); return; }
  net__after_window();
}

static inline void net__fetch_poll() {
  NetSm& g = g_net;
  if (!g.fetch_cancel && (g.rq_join || g.rq_leave ||
                          (!(g.fetch_jobs & NET_JOB_TILES) && g.now - g.fetch_start >= NET_FETCH_GUARD_MS))) {
    if (g.ops.jobs_cancel) g.ops.jobs_cancel();
    g.fetch_cancel = true;
  }
  NetJobResult r;
  memset(&r, 0, sizeof(r));
  if (g.ops.jobs_poll && g.ops.jobs_poll(&r)) net__fetch_done(&r);
}

static inline void net__after_window() {
  NetSm& g = g_net;
  if (g.cfg.mode == NET_MODE_STAY && !g.rq_leave && !g.paused) {
    g.phase = NP_ONLINE;
    g.win_manual = false;   // STAY's own fetches from here on are automatic
    return;
  }
  net__leave();
  net__broadcast("idle", NULL);
}

static inline void net__online_poll() {
  NetSm& g = g_net;
  if (g.rq_join || g.rq_leave || g.cfg.mode != NET_MODE_STAY || g.paused) {
    net__leave();
    net__broadcast("idle", NULL);
    return;
  }
  NetLink l = g.ops.link ? g.ops.link() : NET_LINK_DOWN;
  if (l != NET_LINK_UP) {   // link lost: rejoin at once, back off if that fails
    net__leave();
    net__copy(g.err, sizeof(g.err), "link lost");
    net__broadcast("lost", NULL);
    g.sched = true;
    g.next_try = g.now;
    return;
  }
  uint32_t jobs = net__due();
  if (jobs) net__fetch_begin(jobs);
}

static inline void net__idle() {
  NetSm& g = g_net;
  g.rq_leave = false;
  if (!g.ops.begin) {   // no station (the T5 in beacon mode): answer, never join
    if (g.rq_join) {
      g.rq_join = false;
      g.state = NET_STATE_FAILED;
      net__copy(g.err, sizeof(g.err), "Wi-Fi is off in this mode");
      net__reply_status(g.rq_reply);
      g.rq_reply = 0;
    }
    if (g.rq_scan) net__scan_begin(false);   // fails at once: no scan_start
    g.rq_sync = g.rq_tiles = false;
    return;
  }
  if (g.rq_join) {
    g.rq_join = false;
    g.win_manual = true;
    net__join_begin(g.rq_ssid, g.rq_pass, g.rq_new, g.rq_reply);
    g.rq_reply = 0;
    return;
  }
  if (g.rq_scan) { net__scan_begin(false); return; }
  if (!g.cfg.n) { g.rq_sync = g.rq_tiles = false; return; }   // nothing to join
  if (g.resume_wait && !g.paused && (int32_t)(g.now - g.resume_at) >= 0) g.resume_wait = false;
  // SYNC: when the window is due. STAY: whenever not connected, unless
  // saved networks are failing (then the back-off decides). Neither while a
  // phone is connected, nor in the grace after it leaves.
  bool due = g.cfg.mode != NET_MODE_OFF && !g.paused && !g.resume_wait &&
             ((g.cfg.mode == NET_MODE_STAY && g.fails == 0) || !g.sched || (int32_t)(g.now - g.next_try) >= 0);
  if (!due && !g.rq_sync) return;
  g.win_manual = g.rq_sync;   // SYNC NOW / UPDATE MAP / a mode change: runs even with a phone connected
  g.rq_sync = false;
  if (g.cfg.n >= 2) net__scan_begin(true);   // pick the strongest saved network
  else net__join_begin(g.cfg.saved[0].ssid, g.cfg.saved[0].pass, false, 0);
}

// ---------------------------------------------------------------------------
// API (loop task). The UI and the host commands only file requests; net_tick
// acts on them, so the radio is driven from one place.

/// Install the ops and load the saved networks and mode from NVS.
static inline void net_sync_init(const NetOps* ops) {
  g_net = net__initial();
  if (ops) { g_net.ops = *ops; g_net.have_ops = true; }
  if (g_net.ops.setup) g_net.ops.setup();
  if (g_net.ops.load) g_net.ops.load(&g_net.cfg);
  if (g_net.cfg.mode > NET_MODE_STAY) g_net.cfg.mode = NET_MODE_SYNC;
  if (g_net.cfg.every_min < NET_EVERY_MIN_MIN || g_net.cfg.every_min > NET_EVERY_MIN_MAX)
    g_net.cfg.every_min = NET_EVERY_MIN_DEFAULT;
  if (g_net.cfg.n > NET_MAX_SAVED) g_net.cfg.n = NET_MAX_SAVED;
  if (g_net.cfg.adsb_km < NET_ADSB_KM_MIN || g_net.cfg.adsb_km > NET_ADSB_KM_MAX) g_net.cfg.adsb_km = NET_ADSB_KM_DEFAULT;
  if (g_net.cfg.tile_km < NET_TILE_KM_MIN || g_net.cfg.tile_km > NET_TILE_KM_MAX) g_net.cfg.tile_km = NET_TILE_KM_DEFAULT;
  if (g_net.ops.hop_hold) g_net.ops.hop_hold(false);
}

/// A phone connected (encrypted BLE) or left. Connected: automatic Wi-Fi
/// stops at once (the sniffer and the hop carry on): a join is abandoned,
/// a fetch is cancelled and the station leaves without waiting for the
/// worker (NP_DRAIN; a tile in flight is a temp file, never renamed), STAY
/// lets go of the access point. A window a person asked for runs to its end,
/// then leaves. Left: automatic windows resume after NET_RESUME_GRACE_MS, at
/// once if one fell due meanwhile.
static inline void net__phone(bool on) {
  NetSm& g = g_net;
  if (on == g.paused) return;
  g.paused = on;
  if (!on) {
    g.resume_wait = true;
    g.resume_at = g.now + NET_RESUME_GRACE_MS;
    if (g.cfg.mode != NET_MODE_OFF) net__broadcast("resumed", NULL);
    return;
  }
  g.resume_wait = false;
  if (g.cfg.mode != NET_MODE_OFF) net__broadcast("paused", ",\"reason\":\"phone\"");
  switch (g.phase) {
    case NP_JOIN:
      if (!g.win_manual) {
        net__leave();
        g.state = NET_STATE_DISCONNECTED;
        net__broadcast("idle", NULL);
      }
      break;
    case NP_FETCH:
      if (!g.win_manual) {
        if (!g.fetch_cancel && g.ops.jobs_cancel) g.ops.jobs_cancel();
        g.fetch_cancel = true;
        net__leave();
        g.phase = NP_DRAIN;
        net__broadcast("idle", NULL);   // the worker's own report follows ("phone":...)
      }
      break;
    case NP_ONLINE:
      net__leave();
      net__broadcast("idle", NULL);
      break;
    default:
      break;
  }
}

/// The state machine; call every loop iteration with millis().
static inline void net_tick(uint32_t now) {
  NetSm& g = g_net;
  g.now = now;
  if (!g.have_ops) return;
  net__phone(g.ops.phone_connected && g.ops.phone_connected());
  if (g.serial_setup && (int32_t)(now - g.serial_setup_until) >= 0) g.serial_setup = false;
  if (g.no_position && g.ops.have_position && g.ops.have_position()) {
    // A position arrived (GPS fix, the app): fetch what needed one now.
    g.no_position = false;
    if (g.fetch_err[0] && !strcmp(g.fetch_err, NET_NO_POSITION_TEXT)) g.fetch_err[0] = 0;
    for (int k = 1; k < NET_JOB_COUNT; k++) if (!g.job_fails[k]) g.job_wait[k] = false;
    if (g.cfg.mode != NET_MODE_OFF) g.sched = false;   // an automatic window, now
  }
  if (g.scanning) net__scan_poll();
  switch (g.phase) {
    case NP_JOIN:   net__join_poll(); break;
    case NP_FETCH:
    case NP_DRAIN:  net__fetch_poll(); break;
    case NP_ONLINE: net__online_poll(); break;
    default: break;
  }
  if (g.phase == NP_ONLINE && g.rq_scan && !g.scanning) net__scan_begin(false);
  if (g.phase == NP_IDLE && !g.scanning) net__idle();
  if ((g.phase == NP_IDLE || g.phase == NP_DRAIN) && !g.scanning) net__hold(false);
}

/// Start a scan of the networks around ("scanning, Remote ID Wi-Fi paused":
/// the hop stops for ~2 s). Results: net_get_scanned() once !net_is_scanning().
static inline void net_scan_request(uint8_t reply_mask) {
  NetSm& g = g_net;
  g.scan_reply |= reply_mask;
  if (!g.scanning) g.rq_scan = true;
}
static inline void net_scan_start() { net_scan_request(0); }
static inline bool net_is_scanning() { return g_net.scanning || g_net.rq_scan; }
static inline const ScannedNetwork* net_get_scanned(uint8_t* out_count) {
  if (out_count) *out_count = g_net.n_scanned;
  return g_net.scanned;
}

static inline bool net__request_join(const char* ssid, const char* pass, uint8_t reply, const char** why) {
  NetSm& g = g_net;
  size_t sl = ssid ? strlen(ssid) : 0;
  if (sl == 0 || sl > NET_MAX_SSID_LEN) { *why = "bad ssid"; return false; }
  bool is_new = pass != NULL;
  if (!pass) {   // CONNECT on a saved network: its password; else an open one
    int i = net__saved_index(ssid);
    pass = i >= 0 ? g.cfg.saved[i].pass : "";
    is_new = i < 0;
  }
  if (strlen(pass) > NET_MAX_PASS_LEN || !net_pass_ok(pass)) {
    *why = "password must be 8-63 characters";
    return false;
  }
  if (g.rq_join && g.rq_reply && g.rq_reply != reply) {   // an earlier request never started
    uint8_t old = g.rq_reply;
    g.rq_reply = 0;
    for (uint8_t s = 0; s < 8; s++) if (old & (1u << s)) net__reply_err(s, "wifi_join", "superseded");
  }
  net__copy(g.rq_ssid, sizeof(g.rq_ssid), ssid);
  net__copy(g.rq_pass, sizeof(g.rq_pass), pass);
  g.rq_new = is_new;
  g.rq_reply = reply;
  g.rq_join = true;
  return true;
}

/// Join `ssid` now as a test: saved only if it joins, then the usual sync
/// (or STAY). pass NULL: the saved password (or an open network); "" open.
/// True: queued (net_tick starts it). False: refused at once, state FAILED
/// with the reason in net_last_error() (a password that cannot be right).
static inline bool net_connect(const char* ssid, const char* pass) {
  const char* why = NULL;
  if (!net__request_join(ssid, pass, 0, &why)) {
    g_net.state = NET_STATE_FAILED;
    net__copy(g_net.err, sizeof(g_net.err), why);
    return false;
  }
  return true;
}

/// Forget a saved network (NULL: the one in use or last joined). Leaves it
/// if connected. False when it was not saved.
static inline bool net_forget(const char* ssid = NULL) {
  NetSm& g = g_net;
  if (!ssid || !ssid[0]) ssid = g.state == NET_STATE_CONNECTED ? g.ssid : (g.cfg.n ? g.cfg.saved[0].ssid : "");
  int i = net__saved_index(ssid);
  if (i < 0) return false;
  bool active = (g.phase != NP_IDLE) && !strcmp(g.ssid, ssid);
  if (g.cfg.saved[i].builtin) g.cfg.builtin_off = true;
  for (int k = i; k + 1 < g.cfg.n; k++) g.cfg.saved[k] = g.cfg.saved[k + 1];
  g.cfg.n--;
  memset(&g.cfg.saved[g.cfg.n], 0, sizeof(NetSaved));
  net__store();
  for (int k = 0; k < g.n_scanned; k++)
    if (!strcmp(g.scanned[k].ssid, ssid)) g.scanned[k].saved = false;
  if (active) g.rq_leave = true;
  if (g.state == NET_STATE_FAILED && !g.cfg.n) { g.state = NET_STATE_DISCONNECTED; g.err[0] = 0; }
  g.rot = 0;
  return true;
}

static inline NetMode net_get_mode() { return (NetMode)g_net.cfg.mode; }
static inline uint8_t net_get_every_min() { return g_net.cfg.every_min; }

/// OFF / SYNC / STAY, stored in NVS. OFF leaves at once; STAY joins at once;
/// SYNC (from OFF) syncs at once.
static inline void net_set_mode(NetMode mode, uint8_t every_min = 0) {
  NetSm& g = g_net;
  if (mode > NET_MODE_STAY) return;
  if (every_min) {
    if (every_min < NET_EVERY_MIN_MIN) every_min = NET_EVERY_MIN_MIN;
    if (every_min > NET_EVERY_MIN_MAX) every_min = NET_EVERY_MIN_MAX;
  }
  bool changed = g.cfg.mode != mode || (every_min && every_min != g.cfg.every_min);
  NetMode old = (NetMode)g.cfg.mode;
  g.cfg.mode = (uint8_t)mode;
  if (every_min) g.cfg.every_min = every_min;
  if (changed) net__store();
  if (mode == NET_MODE_OFF && (g.phase != NP_IDLE || g.scanning)) g.rq_leave = true;
  // From OFF, or into STAY: go now. STAY -> SYNC keeps the schedule.
  if (mode != old && (old == NET_MODE_OFF || mode == NET_MODE_STAY)) {
    g.sched = false;
    g.fails = 0;
    g.rq_sync = true;   // a person asked: runs even with a phone connected
  }
}

static inline NetState net_get_state() { return g_net.state; }

/// Why the last join failed (wrong password, network not found, no IP
/// address, timed out, link lost...), else the last fetch failure (or
/// NET_NO_POSITION_TEXT), else "".
static inline const char* net_last_error() { return g_net.err[0] ? g_net.err : g_net.fetch_err; }

/// Sync now: join (if not connected) and run every job.
static inline void net_sync_now() {
  g_net.rq_sync = true;
  g_net.force_jobs = true;
}

/// Fetch the map tiles around home that are missing (UPDATE MAP): now,
/// whatever the tile job's back-off.
static inline void net_update_map() {
  g_net.rq_tiles = true;
  g_net.rq_sync = true;
  g_net.job_wait[3] = false;
}

static inline const char* net_get_ip() { return g_net.state == NET_STATE_CONNECTED ? g_net.ip : ""; }
static inline const char* net_get_ssid() { return g_net.ssid; }
static inline uint8_t net_get_channel() { return g_net.state == NET_STATE_CONNECTED ? g_net.ch : 0; }
/// Unix time of the last window in which a job succeeded, 0 never.
static inline uint32_t net_get_last_sync() { return g_net.last_sync_utc; }
/// True once an SNTP server answered (not merely a clock that looks set).
static inline bool net_is_clock_synced() { return g_net.clock_synced; }
/// ADS-B query radius around home, km (5-30, stored). A live drone more than
/// 3 km out widens the query around it (net_adsb_area), up to 30 km.
static inline uint8_t net_get_adsb_radius_km() { return g_net.cfg.adsb_km; }
static inline void net_set_adsb_radius_km(uint8_t km) {
  if (km < NET_ADSB_KM_MIN) km = NET_ADSB_KM_MIN;
  if (km > NET_ADSB_KM_MAX) km = NET_ADSB_KM_MAX;
  if (km != g_net.cfg.adsb_km) { g_net.cfg.adsb_km = km; net__store(); }
}
/// The largest map radius (km) this board's flash holds at z12-15, from the
/// last tile plan; 0 until a tile sync has planned (then allow up to 30).
static inline double net_get_tile_radius_max_km() { return g_net.tile_max_m / 1000.0; }
/// Map area radius around home, km (1 to what fits, stored). UPDATE MAP and
/// the automatic fills use it; a plan that does not fit shrinks z15 first.
static inline uint8_t net_get_tile_radius_km() { return g_net.cfg.tile_km; }
static inline void net_set_tile_radius_km(uint8_t km) {
  km = net__tile_km_fit(km);
  if (km != g_net.cfg.tile_km) { g_net.cfg.tile_km = km; net__store(); }
}
/// The last tile plan (per-zoom radius, tile counts, estimated bytes, flash
/// total/free); false before the first tile sync.
static inline bool net_tile_plan(TilePlan* out) {
  if (g_net.have_plan && out) *out = g_net.plan;
  return g_net.have_plan;
}
/// "Map: 6 km z12-14, 3 km z15; 2.9 MB of 5.0 MB" ("" before a plan); adds
/// ", storage full" when the last sync stopped at the reserve.
static inline void net_tile_plan_line(char* out, size_t n) {
  if (!n) return;
  out[0] = 0;
  if (!g_net.have_plan) return;
  tile_plan_describe(&g_net.plan, out, n);
  size_t k = strlen(out);
  if (g_net.storage_full && k < n) snprintf(out + k, n - k, ", storage full");
}

/// Automatic Wi-Fi is paused because a phone is connected over BLE (the
/// phone's own data takes over; SCAN, CONNECT, SYNC NOW, UPDATE MAP still run).
static inline bool net_is_paused() { return g_net.paused && g_net.cfg.mode != NET_MODE_OFF; }
/// The last sync had no home position to fetch TFRs, ADS-B and tiles for.
static inline bool net_no_position() { return g_net.no_position; }
/// Seconds since this board's own ADS-B fetch last succeeded; NAN never.
static inline double net_adsb_age_s() {
  return g_net.adsb_ok ? (double)(g_net.now - g_net.adsb_ms) / 1000.0 : NAN;
}
static inline int net_saved_count() { return g_net.cfg.n; }

/// Allow wifi_join/forget/mode over USB for 5 minutes (the SYSTEM screen's
/// Wi-Fi setup is open), or stop allowing it.
static inline void net_serial_setup(bool on) {
  g_net.serial_setup = on;
  g_net.serial_setup_until = g_net.now + NET_SERIAL_SETUP_MS;
}

/// One line for the SYSTEM screen, plain ASCII, cut to fit `out`.
static inline void net_status_line(char* out, size_t n) {
  NetSm& g = g_net;
  if (!n) return;
  char ssid[NET_MAX_SSID_LEN + 1];
  net__copy(ssid, sizeof(ssid), g.ssid);
  if (g.scanning && !g.scan_pick) { traffic_textf(out, n, "SCANNING, Remote ID Wi-Fi paused"); return; }
  if (net_is_paused() && (g.phase == NP_IDLE || g.phase == NP_DRAIN) && !g.scan_pick) {
    snprintf(out, n, "Wi-Fi paused: phone connected");
    return;
  }
  if (g.phase == NP_JOIN || g.scan_pick) {
    traffic_textf(out, n, "CONNECTING to %s", g.phase == NP_JOIN ? ssid : "saved network");
    return;
  }
  if (g.phase == NP_FETCH) {
    if (g_net_tiles_running)
      traffic_textf(out, n, "MAP %u/%u via %s", (unsigned)g_net_tiles_done, (unsigned)g_net_tiles_total, ssid);
    else
      traffic_textf(out, n, "SYNCING via %s (ch %u)", ssid, (unsigned)g.ch);
    return;
  }
  if (g.phase == NP_ONLINE) {
    if (g.no_position) traffic_textf(out, n, "CONNECTED to %s, " NET_NO_POSITION_TEXT, ssid);
    else traffic_textf(out, n, "CONNECTED to %s (ch %u)", ssid, (unsigned)g.ch);
    return;
  }
  if (g.state == NET_STATE_FAILED) {
    if (g.sched && g.cfg.mode != NET_MODE_OFF && g.cfg.n) {
      uint32_t left = (int32_t)(g.next_try - g.now) > 0 ? (g.next_try - g.now + 59999u) / 60000u : 0;
      traffic_textf(out, n, "FAILED: %s, retry in %lu min", g.err, (unsigned long)left);
    } else {
      traffic_textf(out, n, "FAILED: %s", g.err);
    }
    return;
  }
  if (!g.cfg.n) { traffic_textf(out, n, "%s, no network saved", g.cfg.mode == NET_MODE_OFF ? "OFF" : "NOT SET UP"); return; }
  if (g.cfg.mode == NET_MODE_OFF) { traffic_textf(out, n, "OFF"); return; }
  if (g.no_position) { traffic_textf(out, n, "%s", NET_NO_POSITION_TEXT); return; }
  const char* head = g.cfg.mode == NET_MODE_STAY ? "STAY CONNECTED" : "SYNC";
  char when[16] = "";
  if (g.last_sync_utc) {
    time_t t = (time_t)g.last_sync_utc;
    struct tm tm;
    gmtime_r(&t, &tm);
    snprintf(when, sizeof(when), "%02d:%02dZ", tm.tm_hour, tm.tm_min);
  }
  if (g.have_plan && (g.plan.shrunk || g.storage_full) && !g.fetch_err[0]) {
    net_tile_plan_line(out, n);
    return;
  }
  if (g.cfg.mode == NET_MODE_SYNC) {
    if (!when[0]) traffic_textf(out, n, "SYNC every %u min, not yet", (unsigned)g.cfg.every_min);
    else if (g.fetch_err[0]) traffic_textf(out, n, "SYNC every %u min, last %s, %s", (unsigned)g.cfg.every_min, when, g.fetch_err);
    else traffic_textf(out, n, "SYNC every %u min, last %s ok", (unsigned)g.cfg.every_min, when);
  } else {
    traffic_textf(out, n, "%s, reconnecting", head);
  }
}

/// wifi_* host commands (see the header comment). True when `cmd` was one.
/// src is the HostSrc the line came from; replies go only there.
static inline bool net_host_line(const char* cmd, const char* line, uint8_t src) {
  if (strncmp(cmd, "wifi_", 5) != 0) return false;
  NetSm& g = g_net;
  uint8_t mask = net__mask(src);
  bool trusted = src == 1 /* SRC_BLE_BONDED */ || g.serial_setup || NET_SERIAL_PROVISIONING;
  if (!strcmp(cmd, "wifi_status")) { net__reply_status(mask); return true; }
  if (!strcmp(cmd, "wifi_scan")) { net_scan_request(mask); return true; }
  bool is_join = !strcmp(cmd, "wifi_join"), is_forget = !strcmp(cmd, "wifi_forget"),
       is_mode = !strcmp(cmd, "wifi_mode"), is_config = !strcmp(cmd, "wifi_config");
  if (!is_join && !is_forget && !is_mode && !is_config) { net__reply_err(src, "wifi", "unknown command"); return true; }
  if (!trusted) {
    net__reply_err(src, cmd, "refused over USB: open Wi-Fi setup on the board, or use a paired phone");
    return true;
  }
  char ssid[NET_MAX_SSID_LEN + 1] = {0};
  if (is_join) {
    char psk[NET_MAX_PASS_LEN + 1] = {0};
    if (!net_json_get_str(line, "ssid", ssid, sizeof(ssid)) || !ssid[0]) {
      net__reply_err(src, cmd, "bad ssid");
      return true;
    }
    // psk absent or null: the saved password (or an open network).
    const char* pv = net_json_find(line, "psk");
    bool has_psk = pv && *pv == '"';
    if (has_psk && !net_json_get_str(line, "psk", psk, sizeof(psk))) {
      net__reply_err(src, cmd, "password too long");
      return true;
    }
    const char* why = NULL;
    if (!net__request_join(ssid, has_psk ? psk : NULL, mask, &why)) { net__reply_err(src, cmd, why); return true; }
    return true;   // wifi_status connecting / connected / failed follow from net_tick
  }
  if (is_config) {   // {"cmd":"wifi_config","adsb_km":10,"tile_km":3}: either or both, clamped
    double v = 0;
    bool any = false;
    if (net_json_get_num(line, "adsb_km", &v)) { net_set_adsb_radius_km((uint8_t)(v < 1 ? 1 : v > 255 ? 255 : v)); any = true; }
    if (net_json_get_num(line, "tile_km", &v)) { net_set_tile_radius_km((uint8_t)(v < 1 ? 1 : v > 255 ? 255 : v)); any = true; }
    if (!any) { net__reply_err(src, cmd, "nothing to set"); return true; }
    net__reply_status(mask);
    return true;
  }
  if (is_forget) {
    if (!net_json_get_str(line, "ssid", ssid, sizeof(ssid)) || !net_forget(ssid)) {
      net__reply_err(src, cmd, "not saved");
      return true;
    }
    net__reply_status(mask);
    return true;
  }
  char m[8] = {0};
  if (!net_json_get_str(line, "mode", m, sizeof(m))) { net__reply_err(src, cmd, "bad mode"); return true; }
  NetMode mode;
  if (!strcmp(m, "off")) mode = NET_MODE_OFF;
  else if (!strcmp(m, "sync")) mode = NET_MODE_SYNC;
  else if (!strcmp(m, "stay")) mode = NET_MODE_STAY;
  else { net__reply_err(src, cmd, "bad mode"); return true; }
  double every = 0;
  uint8_t ev = 0;
  if (net_json_get_num(line, "every_min", &every)) {
    if (every < 1 || every > 1440) { net__reply_err(src, cmd, "every_min out of range"); return true; }
    ev = (uint8_t)(every > 255 ? 255 : every);
  }
  net_set_mode(mode, ev);
  net__reply_status(mask);
  return true;
}

#if !defined(ESP_PLATFORM)
// Host tests only (tests/t5_render_test.cpp): set what the screen shows
// without a radio (no ops run). Not in the firmware.
static inline void net_debug_set_scanned(const ScannedNetwork* nets, uint8_t n) {
  if (n > NET_MAX_NETWORKS) n = NET_MAX_NETWORKS;
  if (nets && n) memcpy(g_net.scanned, nets, sizeof(ScannedNetwork) * n);
  g_net.n_scanned = n;
}
/// The link as net_tick would leave it; takes any queued join (as the tick
/// would). ssid NULL keeps the current one; ch only while connected.
static inline void net_debug_set_state(NetState st, const char* ssid, const char* err, uint8_t ch = 0) {
  g_net.state = st;
  g_net.rq_join = false;
  if (ssid) net__copy(g_net.ssid, sizeof(g_net.ssid), ssid);
  net__copy(g_net.err, sizeof(g_net.err), err);
  g_net.ch = st == NET_STATE_CONNECTED ? ch : 0;
}
/// Scanning: true = the scan runs (the tick took the request); false = done.
static inline void net_debug_set_scanning(bool running) {
  g_net.rq_scan = false;
  g_net.scanning = running;
}
/// Replace the saved networks with one (NULL: none) and set mode/interval.
static inline void net_debug_set_saved(const char* ssid, const char* pass, NetMode mode, uint8_t every_min) {
  memset(&g_net.cfg, 0, sizeof(g_net.cfg));
  if (ssid) {
    net__copy(g_net.cfg.saved[0].ssid, sizeof(g_net.cfg.saved[0].ssid), ssid);
    net__copy(g_net.cfg.saved[0].pass, sizeof(g_net.cfg.saved[0].pass), pass);
    g_net.cfg.n = 1;
  }
  g_net.cfg.mode = (uint8_t)mode;
  g_net.cfg.every_min = every_min;
}
static inline void net_debug_set_mode(NetMode mode) { g_net.cfg.mode = (uint8_t)mode; }
static inline void net_debug_set_last_sync(uint32_t utc) { g_net.last_sync_utc = utc; }
#endif  // !ESP_PLATFORM

// ---------------------------------------------------------------------------
// The device's Wi-Fi and NVS ops (net_fetch.h adds the jobs; the sketch the
// clock and the host link).

#if defined(ESP_PLATFORM)
#include <WiFi.h>
#include <Preferences.h>
#include <esp_wifi.h>

// A network to use until one is saved on the device: an optional, untracked
// wifi_secrets.h next to this file defining ORECCHINO_WIFI_SSID and
// ORECCHINO_WIFI_PASS. It is in .gitignore; never commit one.
#if __has_include("wifi_secrets.h")
#include "wifi_secrets.h"
#endif

void rx_hop_hold(bool hold);   // rx_core.h

inline volatile bool    s_net_esp_assoc = false;
inline volatile bool    s_net_esp_got_ip = false;
inline volatile uint8_t s_net_esp_reason = 0;   // last disconnect reason (wifi_err_reason_t)

static void net_esp_event(arduino_event_t* e) {
  switch (e->event_id) {
    case ARDUINO_EVENT_WIFI_STA_CONNECTED:
      s_net_esp_assoc = true;
      break;
    case ARDUINO_EVENT_WIFI_STA_GOT_IP:
      s_net_esp_got_ip = true;
      break;
    case ARDUINO_EVENT_WIFI_STA_LOST_IP:
      s_net_esp_got_ip = false;
      break;
    case ARDUINO_EVENT_WIFI_STA_DISCONNECTED:
      s_net_esp_assoc = false;
      s_net_esp_got_ip = false;
      s_net_esp_reason = e->event_info.wifi_sta_disconnected.reason;
      break;
    default:
      break;
  }
}

static inline void net_esp_setup() {
  // Runs after rx_begin(): the sniffer has already put Wi-Fi in station mode
  // and promiscuous; WiFi.mode()/disconnect() here would stop it.
  WiFi.persistent(false);       // the driver's own copy of the password stays out of NVS
  WiFi.setSleep(false);         // modem sleep while associated gates promiscuous RX
  WiFi.setAutoReconnect(false); // rejoining is the state machine's call (back-off)
  WiFi.onEvent(net_esp_event);
}

static inline void net_esp_begin(const char* ssid, const char* pass) {
  s_net_esp_assoc = false;
  s_net_esp_got_ip = false;
  s_net_esp_reason = 0;
  WiFi.begin(ssid, (pass && pass[0]) ? pass : nullptr);
}

static inline void net_esp_leave() {
  WiFi.disconnect(false, false);
  esp_wifi_set_promiscuous(true);   // idempotent; the sniffer must survive the visit
  s_net_esp_assoc = false;
  s_net_esp_got_ip = false;
}

static inline NetLink net_esp_link() {
  if (s_net_esp_got_ip && WiFi.status() == WL_CONNECTED) return NET_LINK_UP;
  switch (s_net_esp_reason) {
    case WIFI_REASON_NO_AP_FOUND:
    case WIFI_REASON_NO_AP_FOUND_W_COMPATIBLE_SECURITY:
    case WIFI_REASON_NO_AP_FOUND_IN_AUTHMODE_THRESHOLD:
    case WIFI_REASON_NO_AP_FOUND_IN_RSSI_THRESHOLD:
      return NET_LINK_NO_AP;
    case WIFI_REASON_AUTH_FAIL:
    case WIFI_REASON_4WAY_HANDSHAKE_TIMEOUT:
    case WIFI_REASON_HANDSHAKE_TIMEOUT:
    case WIFI_REASON_MIC_FAILURE:
    case WIFI_REASON_802_1X_AUTH_FAILED:
      return NET_LINK_AUTH_FAIL;
    default:
      break;
  }
  if (s_net_esp_assoc) return NET_LINK_ASSOC;
  return s_net_esp_reason ? NET_LINK_DOWN : NET_LINK_PENDING;
}

static inline bool net_esp_scan_start() {
  int16_t r = WiFi.scanNetworks(true /* async */);
  return r == WIFI_SCAN_RUNNING || r >= 0;
}

static inline int net_esp_scan_poll(ScannedNetwork* out, int max) {
  int16_t r = WiFi.scanComplete();
  if (r == WIFI_SCAN_RUNNING) return NET_SCAN_RUNNING;
  if (r < 0) return NET_SCAN_FAILED;
  int m = r > max ? max : r;
  for (int i = 0; i < m; i++) {
    memset(&out[i], 0, sizeof(out[i]));
    snprintf(out[i].ssid, sizeof(out[i].ssid), "%s", WiFi.SSID(i).c_str());
    out[i].rssi = (int8_t)WiFi.RSSI(i);
    out[i].auth_mode = (uint8_t)WiFi.encryptionType(i);
    out[i].channel = (uint8_t)WiFi.channel(i);
  }
  WiFi.scanDelete();
  return m;
}

static inline void net_esp_ip(char* out, size_t n) {
  IPAddress ip = WiFi.localIP();
  snprintf(out, n, "%u.%u.%u.%u", ip[0], ip[1], ip[2], ip[3]);
}
static inline int net_esp_rssi() { return WiFi.RSSI(); }
static inline uint8_t net_esp_channel() { return (uint8_t)WiFi.channel(); }

static inline void net_esp_load(NetConfig* c) {
  Preferences p;
  if (p.begin("orwifi", true)) {
    c->mode = p.getUChar("mode", NET_MODE_SYNC);
    c->every_min = p.getUChar("every", NET_EVERY_MIN_DEFAULT);
    c->builtin_off = p.getUChar("nobuiltin", 0) != 0;
    c->adsb_km = p.getUChar("adsb_km", NET_ADSB_KM_DEFAULT);
    c->tile_km = p.getUChar("tile_km", NET_TILE_KM_DEFAULT);
    uint8_t n = p.getUChar("n", 0);
    if (n > NET_MAX_SAVED) n = NET_MAX_SAVED;
    c->n = 0;
    for (uint8_t i = 0; i < n; i++) {
      char ks[4] = { 's', (char)('0' + i), 0, 0 }, kp[4] = { 'p', (char)('0' + i), 0, 0 };
      NetSaved* s = &c->saved[c->n];
      memset(s, 0, sizeof(*s));
      if (!p.getString(ks, s->ssid, sizeof(s->ssid))) continue;
      if (!s->ssid[0]) continue;
      if (!p.isKey(kp) || !p.getString(kp, s->pass, sizeof(s->pass))) s->pass[0] = 0;
      c->n++;
    }
    p.end();
  }
#if defined(ORECCHINO_WIFI_SSID) && defined(ORECCHINO_WIFI_PASS)
  if (c->n == 0 && !c->builtin_off) {
    NetSaved* s = &c->saved[0];
    memset(s, 0, sizeof(*s));
    snprintf(s->ssid, sizeof(s->ssid), "%s", ORECCHINO_WIFI_SSID);
    snprintf(s->pass, sizeof(s->pass), "%s", ORECCHINO_WIFI_PASS);
    s->builtin = true;
    c->n = 1;
  }
#endif
}

static inline void net_esp_store(const NetConfig* c) {
  Preferences p;
  if (!p.begin("orwifi", false)) return;
  p.putUChar("mode", c->mode);
  p.putUChar("every", c->every_min);
  p.putUChar("nobuiltin", c->builtin_off ? 1 : 0);
  p.putUChar("adsb_km", c->adsb_km);
  p.putUChar("tile_km", c->tile_km);
  uint8_t k = 0;
  for (uint8_t i = 0; i < c->n && i < NET_MAX_SAVED; i++) {
    if (c->saved[i].builtin) continue;
    char ks[4] = { 's', (char)('0' + k), 0, 0 }, kp[4] = { 'p', (char)('0' + k), 0, 0 };
    p.putString(ks, c->saved[i].ssid);
    p.putString(kp, c->saved[i].pass);
    k++;
  }
  for (uint8_t i = k; i < NET_MAX_SAVED; i++) {
    char ks[4] = { 's', (char)('0' + i), 0, 0 }, kp[4] = { 'p', (char)('0' + i), 0, 0 };
    if (p.isKey(ks)) p.remove(ks);
    if (p.isKey(kp)) p.remove(kp);
  }
  p.putUChar("n", k);
  p.end();
}

static inline uint32_t net_esp_utc_now() {
  time_t t = time(nullptr);
  return t >= (time_t)NET_UTC_MIN ? (uint32_t)t : 0;
}

/// The Wi-Fi, NVS and hop parts of the ops (jobs, set_utc and emit: the sketch).
static inline void net_esp_wifi_ops(NetOps* o) {
  o->setup = net_esp_setup;
  o->begin = net_esp_begin;
  o->leave = net_esp_leave;
  o->link = net_esp_link;
  o->scan_start = net_esp_scan_start;
  o->scan_poll = net_esp_scan_poll;
  o->ip = net_esp_ip;
  o->rssi = net_esp_rssi;
  o->channel = net_esp_channel;
  o->hop_hold = rx_hop_hold;
  o->load = net_esp_load;
  o->store = net_esp_store;
  o->utc_now = net_esp_utc_now;
}
#endif  // ESP_PLATFORM
