# Plan: Orecchino mobile app (iOS + Android) and T5 Wi-Fi

Status: largely built (see section 0). Written 2026-09-23 against commit
`5f03ffc`; section 0 records what was built, where it differs from the
text below, and what is left. Where the two disagree, the code and section
0 are right; the rest of the plan is kept as the design it was built from.
Audience: an engineer or LLM who will build this without the conversation
that produced it. Everything needed is in this file or in the repository;
where a fact was not verified, it says so.

Two deliverables share one protocol:

1. **A phone app** (one codebase for iOS and Android) that connects to any
   Orecchino receiver over Bluetooth LE, gives it the phone's location and
   time, reads its history of detections, and shows live contacts.
2. **Wi-Fi on the T5 e-paper board**, joined from the board's own touch
   screen (or from the phone), used to fetch flight restrictions (TFRs),
   nearby manned aircraft (ADS-B, from the internet) and map tiles, and to
   set its clock.

Read first: `README.md` (what every board does), `firmware/common/rx_core.h`
(the receiver core and the JSON line protocol), `firmware/common/match_log.h`
(the history), `firmware/orecchino_t5epd/ui_epd.cpp` (the T5 UI),
`app/Sources/Orecchino/` (the Mac app, the reference client).

---

## 0. Status (updated 2026-09-23)

| Milestone | State | Where |
| --- | --- | --- |
| M1 BLE link | Built | `host_link.h` (routing, `HostSrc`, feed), `ble_link.h` (NUS + info service, pairing, rings, notify task, fake transport for host tests); `feed` / `feed_status`; `ble_drop`, `ble_rx_drop` in `hb`; T5 passkey screen (`rx_hook_pairing`) |
| M2 History, incremental | Built, differently | Still the 48-record NVS ring (`match_log.h`), now with a `seq` per record (`LOG_VERSION` 2, v1 converted on load); `log_get` `since` / `after_utc`, `log_done` `next` / `oldest`; no LittleFS log (below) |
| M3-M4 Phone app | Built | `mobile/` (see `mobile/README.md`, including its follow-ups) |
| M5 T5 Wi-Fi core | Built | `net_sync.h` (state machine, modes, `wifi_*` commands), `net_fetch.h` (HTTPS jobs on a worker task), `net_parse.h` (streaming parsers, URLs), `rx_hop_hold()` in `rx_core.h`; host tests `tests/net_test.cpp` |
| M6 T5 Wi-Fi UI | Built | WI-FI section on SYSTEM, networks screen, keyboard, joining/result screens in `ui_epd.cpp`; render scenes in `tests/t5_render_test.cpp` |
| M7 ADS-B and tiles on the T5 | Built | ADS-B through `net_fetch.h` + `traffic.h` (no separate `adsb.h`); tile fetch in `net_fetch.h` (no `tile_fetch.h`) |
| M8 App polish and release | Partly | Notifications, Wi-Fi over BLE, accessibility done; store metadata, TestFlight / Play track, export and the history timeline not done |
| M9 Traffic alerts | Built, on the T5 only among boards | `traffic.h` + `tests/vectors/traffic/` + `tests/traffic_test.cpp`; `TrafficRules.swift`, `traffic_rules.dart`; T5 drawing; Mac app (`TrafficService.swift`, `TrafficNotifier.swift`, `TrafficViews.swift`, menu bar extra) |

The hardware acceptance tests (B1-B4, the M4-M7 and M9 field tests) are
not recorded in the repository.

**Changed from the plan while building it:**

- **No LittleFS match log** (section 3.4's LittleFS log was not
  written). The NVS ring of 48 kept its size, gained a `seq`, and is saved
  at most every 10 minutes (was once a minute) plus at the explicit save
  points (T5 power-off, mode switch), to spare the flash. The incremental
  protocol (`since`, `after_utc`, `seq`, `next`, `oldest`) is as planned;
  live contacts are sent with `"active":true,"seq":null`, and a cursor
  above `total` means the log was cleared. The home position is saved in
  NVS too (`orhome`, source `"saved"` until a fresh one arrives).
- **Fixed, published passkey.** Every board pairs with passkey 123456
  (DisplayOnly IO capability; the T5 shows it, the others do not need to).
  It encrypts the link against passers-by, not a determined attacker, and
  the T5's pairing screen says so. A peer that has not paired within 10 s
  is dropped. The headless stick does not use Just Works with a 2-minute
  window, and there is no "Forget phones" item yet.
- **TFR limits unchanged** (16 polygons x 24 points). Instead of raising
  them, the Mac (`TFRShape.swift`) and the T5 (`net_poly_fit`) send the 16
  nearest TFRs, each as a polygon of at most 24 points that *encloses* the
  real outline (erring outward, never cutting inside).
- **No ArduinoJson.** The T5 parses the FAA and adsb.lol answers with a
  streaming splitter (`NetJsonSplit`, one object at a time in a 16 KB PSRAM
  buffer) and small field readers; SNTP is a plain UDP query.
- **The FAA WFS bbox is lon0,lat0,lon1,lat1** (section 4.1 fixed): the
  lat-first order returns an ORA-13200 error page. **adsb.lol's radius is
  in nautical miles**, verified; the T5 and the Mac ask for 17 NM (31.5 km,
  just over the rules' 30 km horizon).
- **TLS memory.** Every HTTPS request first checks the internal heap (at
  least 40 KB free and an 18 KB block, `NET_TLS_MIN_FREE` /
  `NET_TLS_MIN_BLOCK`); below that the job fails with "low memory" in
  words. The `synced` status line reports `heap_int`, `heap_blk` and
  `heap_tls`.
- **Wi-Fi mode default is SYNC**, not Off, but nothing joins until a
  network is saved (the SYSTEM line reads `NOT SET UP, no network saved`).
  The window scans only when two or more networks are saved. Up to 8 new
  tiles per automatic window; UPDATE MAP fetches all missing ones.
  `firmware/common/wifi_secrets.h` (git-ignored; copy
  `wifi_secrets.example.h`) can supply a development network.
- **Wi-Fi commands over USB** are refused unless the SYSTEM screen's Wi-Fi
  setup was opened in the last 5 minutes (`net_serial_setup`), or the
  build sets `-DNET_SERIAL_PROVISIONING=1`. Refusals are `wifi_err` lines.
- **Keyboard**: five rows of 84x60 px keys with digits always on top, SHIFT
  (once for one capital, twice for caps lock) and a `#+=` symbol layer,
  rather than four rows with a separate 123 layer.
- **Traffic rules, choices §8 left open** (all documented at the top of
  `traffic.h` and pinned by the vectors): aircraft reported on the ground
  (`"alt_baro":"ground"`, wire `"gnd":1`) never raise LOW or CONVERGING;
  one within 1 km of a drone is raised as a *caution* with the words
  `, AIRCRAFT ON GROUND`, not a warning; emergencies are still raised.
  The count shown on every surface (`near_count`) is **airborne** aircraft
  within 3 km; ground ones are counted separately. If NEAR and CONVERGING
  both hold, the pair shows NEAR. Hysteresis runs on the wall clock (20 s
  outside 1.3 km / 200 m), never on evaluation counts.
- **`traffic` lines** carry a top-level `t` and `age_s`, and each set ends
  with `traffic_done` (which installs an empty set when no lines came
  before it). Only boards built with `ORECCHINO_TRAFFIC` take them (the
  T5, which lists `traffic` in its `caps`); the T-Embed and SenseCAP do
  not have traffic alerts yet.
- **Signed with the test key** is its own authentication state, `test_key`
  (shown `TEST KEY`), not `id_valid`; `-DORECCHINO_TRUST_TEST_KEY` restores
  the old behaviour for UI testing.
- **Header position source**: the T5 still shows `APP POS` for a position
  from either app (or the saved one); `PHONE POS` was not added, and a GPS
  fix and an app's `set_home` simply overwrite each other (no 2-minute
  preference for GPS).

**Left to do:** "Forget phones" on each board; traffic on the T-Embed and
SenseCAP; the phone app's follow-ups (`mobile/README.md`); NVS encryption
for saved Wi-Fi passwords; the hardware acceptance runs.

---

## 1. Ground truth about the existing system

(As of `5f03ffc`, before this plan was built; section 0 says what changed.)

These are facts about the code as it stands. Do not re-derive them; do not
break them.

- **Boards.** T5 E-Paper S3 Pro (ESP32-S3, 16 MB flash, 8 MB PSRAM, 960x540
  e-paper, touch, GPS, RTC, LittleFS 13 MB partition), T-Embed CC1101
  (ESP32-S3, 320x170 LCD, knob, no touch), SenseCAP Indicator (ESP32-S3,
  LittleFS 5.8 MB), Waveshare AMOLED (ESP32-C6), XIAO ESP32-C3 USB stick (headless), XIAO
  ESP32-C3 test beacon (`orecchino_tx`, transmit only). Build commands for
  each are in `tools/flash_*.sh` and the README.
- **Receiver core.** `rx_core.h` decodes Remote ID from Wi-Fi beacons, Wi-Fi
  NAN and BLE (4 legacy, 5 extended, 1M and coded PHY) on a FreeRTOS task,
  hops Wi-Fi channels 6/1/6/11 on an `esp_timer`, keeps a track table
  (`tracker.h`, `TRK_MAX` 16), and writes one JSON object per line to
  `Serial`. On device builds with extended advertising (every sketch sets
  `CONFIG_BT_NIMBLE_EXT_ADV=1` in `build_opt.h`) BLE scanning is done
  directly on NimBLE's GAP layer (`ble_gap_ext_disc`, `rx_gap_event`); the
  `NimBLEScan` path remains only as the fallback for builds without it.
- **LittleFS.** The T5, T-Embed and AMOLED all have a 13 MB `littlefs`
  partition in their `partitions.csv`, and the SenseCAP 5.8 MB, but only the
  T5 and SenseCAP mount it today (through `tile_store.h`). The T-Embed and
  AMOLED sketches must call `LittleFS.begin(true)` before using it.
- **Radio sharing.** An ESP32 has one 2.4 GHz radio. Wi-Fi promiscuous
  sniffing and BLE scanning already share it (BLE window 30 ms per 100 ms).
  **Joining a Wi-Fi network fixes the Wi-Fi channel to the access point's**,
  so while associated the board hears Wi-Fi Remote ID on that one channel
  only. BLE keeps scanning but now shares airtime with the association and
  any traffic on it, so expect fewer BLE detections too; measure it. This is
  the central constraint of the Wi-Fi work (section 4.2).
- **Line protocol** (host -> board, one JSON object per line):
  `set_time {utc}`, `set_home {lat, lon}`, `tfr_clear`, `tfr_add {id, pts}`,
  `fs_ls` / `fs_rm` / `fs_begin` / `fs_data` / `fs_end` (tile store, T5 and
  SenseCAP), `log_get`, `log_clear`. Board -> host: `boot`, `hb` (every
  2 s), `rid` (per decoded frame, repeats of an identical frame at most
  once a second per path), `time` (the T5's reply to `set_time`, sent by
  its `rx_hook_host_line` in `orecchino_t5epd.ino`), `log`,
  `log_done`, `log_cleared`, tile-sync replies. The exact fields are in the
  README's "Data format" section and in `app/Sources/Orecchino/RidMessage.swift`.
- **Every JSON line is written with one `Serial.write`**, because the decode
  task and the loop both write; keep that rule for any new transport.
- **Match log.** `match_log.h`: one fixed 60-byte `LogRec` per contact that
  expired or was evicted, 48 in an NVS ring, saved at most once a minute;
  `log_get` streams held records oldest first, then live contacts
  (`"active":true`), then `log_done {n, live, total, clock}`.
- **TFR limits on the board.** `TFR_MAX` 16 polygons, `TFR_PTS_MAX` 24 points
  (`rx_core.h`). The FAA feed today has shapes up to 88 points.
- **TFR source used by the Mac app.** FAA GeoServer WFS:
  `https://tfr.faa.gov/geoserver/TFR/ows?service=WFS&version=1.1.0&request=GetFeature&typeName=TFR:V_TFR_LOC&outputFormat=application/json`
  (see `TFRService.swift`). Measured 2026-09-23: 110 KB, 92 features,
  2,878 points in total.
- **Map tiles.** CARTO `dark_all`, `https://basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png`,
  zooms 11-15, stored on the board at `/tiles/{z}/{x}/{y}.png`
  (`tile_store.h`); the T5 re-tones the dark style into greys (`map_tone`).
  Attribution: "© OpenStreetMap contributors, © CARTO".
- **ADS-B source (new).** `https://api.adsb.lol/v2/point/{lat}/{lon}/{radius}`
  answered without a key on 2026-09-23: `{"ac":[...],"now","total",...}`,
  69 aircraft within 25 around San Francisco, 28.7 KB. Per-aircraft fields
  include `hex, flight, r, t, lat, lon, alt_baro, alt_geom, gs, track,
  baro_rate, squawk, emergency, category, seen, seen_pos`. The radius unit
  is nautical miles (the readsb API convention; **verify** before relying on
  it). `api.airplanes.live` returned 403 to a plain request; do not depend
  on it. Make the URL configurable.
- **Tests.** `tests/run_tests.sh` runs everything: C decoder vectors, the
  cores against host shims (`tests/host_shim/`), the T5 and T-Embed screen
  renderers (they fail on colliding or off-screen text), and the Swift app
  tests. New firmware code must be testable on the host the same way:
  keep logic in header-only functions that do not call the radio directly.
- **House rules** (from the repo owner): update docs in the same commit as
  the code; README and every linked doc must stay accurate; commit messages
  without a `Co-Authored-By` footer; run the Gemini review skill before
  committing when working in this repo with Claude Code.

---

## 2. Scope and non-goals

In scope:

- A BLE link on every receiver board (T5, T-Embed, SenseCAP, AMOLED, USB
  stick): the phone sees live contacts, reads the history, and pushes its
  location, time and TFRs.
- A durable, larger history on boards with LittleFS (T5, T-Embed, AMOLED),
  with an incremental "give me everything since N" read.
- A Flutter app for iOS 16+ and Android 10+ (API 29+).
- On the T5 only: Wi-Fi settings on the device (scan, join with an on-screen
  keyboard, forget, mode), and a sync job that fetches the time, TFRs,
  ADS-B and map tiles; ADS-B aircraft drawn on the table plot, the map and
  the side view.

Not in scope (say so if asked): uploading detections to a cloud service;
receiving ADS-B over the air (the boards have no 1090 MHz radio); Wi-Fi on
the T-Embed (no keyboard: provisioning from the phone could come later);
the test beacon (`orecchino_tx`); the Mac app beyond keeping it working.

---

## 3. The BLE link (firmware, all receivers)

### 3.1 Transport

Use the **Nordic UART Service (NUS)** layout so generic tools (nRF Connect,
LightBlue) can test it and every BLE library supports it:

| Role | UUID | Properties |
| --- | --- | --- |
| Service | `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` | |
| RX (phone -> board) | `6E400002-B5A3-F393-E0A9-E50E24DCCA9E` | Write, Write Without Response |
| TX (board -> phone) | `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` | Notify |

Plus one read-only characteristic in a second, Orecchino-specific service so
the app can recognise a board before subscribing:

| Role | UUID | Properties |
| --- | --- | --- |
| Service | `0A1B0001-5E1D-4F0E-9C7B-4F52454343A1` (Orecchino info) | |
| Device info | `0A1B0002-5E1D-4F0E-9C7B-4F52454343A1` | Read (JSON) |

Device info value (UTF-8 JSON, under 200 bytes):
`{"fw":"orecchino","ver":"0.7.0","board":"lilygo-t5-epaper-s3-pro","caps":["log","log_since","tfr","wifi","tiles"],"proto":1}`.
`caps` lists what this board supports; the app must hide what is absent.

**Framing.** The TX characteristic carries the same byte stream the serial
port does: JSON lines separated by `\n`. Notifications are consecutive
slices of that stream (each at most `MTU - 3` bytes); the app concatenates
them and splits on `\n`. Writes to RX are the same: command lines ending in
`\n`, possibly split across several writes. BLE delivers notifications in
order on one connection, so no sequence numbers are needed. The MTU is the
phone's to negotiate: the firmware only states its preferred maximum
(`NimBLEDevice::setMTU(517)`); the Android app calls `requestMtu(517)`
after connecting; iOS negotiates by itself (typically 185 or more). Both
ends must work at any value down to 23.

**Output routing.** Add `firmware/common/host_link.h`: a single function
`host_write(const uint8_t* line, size_t n)` that every JSON emitter calls
instead of `Serial.write`. It writes to `Serial` and to any registered sink
(`host_link_add_sink(fn)`, at most 2). It is complete and testable on its
own with only the serial sink; step 2 registers the BLE sink, which
enqueues the line when a phone is subscribed. Keep the one-write-per-line rule:
the BLE queue takes whole lines. The BLE side is a FreeRTOS ring buffer
(`xRingbufferCreate`, 8 KB, `RINGBUF_TYPE_NOSPLIT`) drained by a small task
that sends notifications while `ble_gatts_notify` has room (NimBLE-Arduino:
`NimBLECharacteristic::notify`). If the ring is full, drop the oldest
`rid` line, never a `log` / `log_done` line; count drops in the heartbeat
(`"ble_drop"`).

**Commands over BLE** go to the same `handle_host_line` as serial. Refactor
`poll_host_serial` so both transports feed one line buffer each and share
the handler, and give the handler the line's source:
`handle_host_line(char* line, uint32_t now, HostSrc src)` with
`enum HostSrc { SRC_SERIAL, SRC_BLE_BONDED }`, passed on to
`rx_hook_host_line` (change its signature on every board). Replies go only
to the transport the command came from (a module-level `s_reply_src` set
for the duration of the call and read by `host_write`); live output
(`rid`, `hb`) goes to all. Commands that change credentials
(section 4.3) check `src`.

**Live feed control.** A phone showing only history should not receive
every `rid` line. New command `{"cmd":"feed","on":true|false}` (default off
for BLE, always on for serial). `hb` is always sent.

### 3.2 Advertising, pairing, security

- Advertise connectable legacy advertising, interval 500 ms, name
  `Orecchino-XXXX` (last 2 bytes of the BT MAC), the NUS service UUID in the
  advertisement. Stop advertising while a phone is connected (one phone at a
  time); resume on disconnect.
- **Coexistence with scanning.** The core's BLE scan uses `ble_gap_ext_disc`
  with interval 100 ms / window 30 ms and its own event callback, while the
  server (NimBLE-Arduino's `NimBLEServer`) registers its own GAP handlers
  for advertising and connections. The NimBLE host keeps separate callbacks
  per GAP procedure, so they should coexist, but NimBLE-Arduino assumes it
  owns the GAP layer and this combination is untested here: **make it the
  first thing built and tried on hardware** (a spike before task 2). If it
  misbehaves, fall back to `NimBLEScan` for scanning (it is still in
  `rx_core.h`) and accept its per-advertiser cost. Use a connection interval
  of 30-50 ms, latency 0, supervision timeout 4 s. Verify on hardware that
  Remote ID BLE detections per minute drop by less than 20% with a phone
  connected (acceptance test B3).
- **Pairing.** LE Secure Connections with bonding. Boards with a screen
  (T5, T-Embed, SenseCAP, AMOLED) use IO capability *DisplayOnly*: the board
  shows a 6-digit passkey full-screen while pairing, the phone asks for it.
  *As built:* every board, the headless USB stick included, uses the fixed,
  published passkey 123456 (a deliberate choice; see §0). Store up to 4 bonds (NimBLE default store); a
  "Forget phones" item goes in each board's settings or menu.
- Characteristics require an encrypted link (`NIMBLE_PROPERTY::READ_ENC`,
  `WRITE_ENC`, and encrypted notify). Without a bond the phone can see the
  board but not use it.

### 3.3 Location and time from the phone

The app sends, on connect and then every 60 s while connected:
`{"cmd":"set_time","utc":<unix s>}` and
`{"cmd":"set_home","lat":<deg>,"lon":<deg>,"acc":<m>,"src":"phone"}`.
The existing handlers accept this; add the optional `acc`/`src` fields
(store them; show "PHONE POS" in the T5 header where it now shows
`APP POS`). A board with its own GPS fix (T5) keeps preferring GPS when the
GPS fix is newer than 2 minutes.

### 3.4 History: bigger and incremental

- *(Not built; see section 0.)* The plan was a LittleFS log for boards
  with LittleFS (T5, T-Embed, AMOLED), 8 MB of version-2 records rotated
  between two files. What was built instead: a version-2 `LogRec` (the 60
  bytes plus a `uint32_t seq`, 64 bytes; `LOG_VERSION` 2, the v1 ring
  converted on load) in the same 48-record NVS ring on every board, with
  writes kept on the loop (never the decode task) and debounced.
- `log_get` keeps its meaning (everything held, then live, then `log_done`).
  New: `{"cmd":"log_get","since":<seq>}` returns only records with
  `seq >= since`. `log_done` gains `"next":<seq>` (the value to send as
  `since` next time) and `"oldest":<seq>` (so the app can tell it missed
  records that rotated out).
- Record lines gain `"seq":<n>`; keep `"i"` for the Mac app until it is
  updated, then drop it.
- Throughput: at MTU 247 a 400-byte record line is two notifications; plan
  on ~40 records/s. 131,072 records would take an hour: the first sync of a
  full log should offer "last 7 days" (filter by `last_utc` on the board:
  `{"cmd":"log_get","since":0,"after_utc":<s>}`).

### 3.5 Firmware tasks (BLE), in order

0. Hardware spike: a `NimBLEServer` with the NUS service running beside the
   raw `ble_gap_ext_disc` scan on a T5, with a phone connected for 10
   minutes (section 3.2). Decide raw GAP or `NimBLEScan` before going on.
1. `host_link.h` with the serial sink only, and refactor every
   `Serial.write`/`printf` of a JSON line in `rx_core.h`, `tile_store.h` and
   the board sketches to go through it; add `HostSrc`. Host test: the shim's
   `MockSerial` still sees identical output (`tests/core_test.cpp` stays
   green).
2. `ble_link.h`: NUS + info service, advertising, pairing, the notify ring
   and task, RX line assembly into `handle_host_line`. Guard with
   `#if defined(ESP_PLATFORM)`; on the host build provide a fake transport so
   tests can inject command lines and read notifications.
3. `feed` command, reply routing, `ble_drop` counter.
4. Passkey screen on each board with a display (a hook
   `rx_hook_pairing(uint32_t passkey, bool show)`), and a "Forget phones"
   menu item.
5. `seq` in `match_log.h`, `since`/`after_utc`/`next`/`oldest` (built without a LittleFS log; section 0).
6. Bump `FW_VERSION` (0.7.0 as built); update the README "Data format" section and
   this plan's status.

---

## 4. T5 Wi-Fi

### 4.1 What it fetches

| Job | Source | Frequency | Stored as |
| --- | --- | --- | --- |
| Clock | SNTP `pool.ntp.org` (fallback `time.google.com`) | each sync | system clock + RTC chip (`periph_set_utc_time_host`) |
| TFRs | FAA WFS (section 1) with `&bbox=<lon0>,<lat0>,<lon1>,<lat1>,EPSG:4326` (longitude first; verified: lat-first returns an ORA-13200 error page) around home, 200 km | every 15 min | the core's TFR table (built: limits kept at 16 x 24, each TFR fitted as an enclosing polygon; section 0) |
| ADS-B | adsb.lol `v2/point/{lat}/{lon}/17` (radius in NM, verified) | every 10 s in STAY mode; else each sync window | built: 64 staged in PSRAM by `net_fetch.h`, handed to `traffic_ingest()` (32 kept within 30 km, dropped after 60 s) |
| Map tiles | CARTO `dark_all` | on demand ("Update map") and weekly | `/tiles/{z}/{x}/{y}.png` via `tile_store.h` |

All HTTPS. Use `WiFiClientSecure` with the Mozilla root bundle compiled in
(`esp_crt_bundle_attach`); never `setInsecure()`.

**TLS memory is the first thing to prove.** The prebuilt Arduino SDK sets
`CONFIG_MBEDTLS_INTERNAL_MEM_ALLOC=y`, so a TLS handshake needs roughly
30-45 KB of *internal* RAM, which epdiy and the radio stacks also use. Before
building the jobs, measure `heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL)`
on the T5 in receiver mode, then do one HTTPS GET to the FAA endpoint; record
both in the PR. If it fails: fetch with the promiscuous sniffer and BLE scan
paused for the window (they hold buffers), reduce `SSL_IN/OUT` record sizes
with `mbedtls_ssl_conf_max_frag_len`, and as the last resort let the phone
fetch and push TFRs and ADS-B over BLE (the app already fetches them). Parse JSON with
ArduinoJson 7 using a PSRAM allocator, and a filter so only needed
fields are kept (built instead: a streaming splitter in `net_parse.h`, no
ArduinoJson; section 0) (the FAA feed is 110 KB; the ADS-B answer ~30 KB). Tiles
stream straight to LittleFS; do not buffer whole files in RAM.

### 4.2 Sharing the radio: the sync state machine

New `firmware/common/net_sync.h` (header-only, logic separated from the
radio so it can run on the host with a fake network):

```
IDLE --(timer | "Sync now" | layer needs data)--> HOLD
HOLD: stop channel hopping (new rx_core API: rx_hop_hold(true));
      Remote ID decoding continues on the current channel
  --> SCAN: passive scan (~2 s); pick the saved network with the strongest
      signal; if none is seen, try saved networks in order of last success
  --> JOIN: WiFi.begin(chosen network), timeout 15 s
  --> TIME: SNTP, timeout 5 s (skip if synced < 1 h ago)
  --> FETCH: run due jobs in order TFR, ADS-B, tiles (each with its own timeout)
  --> LEAVE: WiFi.disconnect(false, false); rx_hop_hold(false)
  --> IDLE (record result per job; next due times)
Any failure: LEAVE, back off (1, 2, 5, 15 min), show the reason in the UI.
```

Three user-selectable **Wi-Fi modes** (stored in NVS):

- **Off.** No Wi-Fi at all (default).
- **Sync.** A sync window every 15 minutes (configurable 5-60), plus on
  demand. Typical window 5-10 s: Remote ID Wi-Fi coverage drops to one
  channel for about 1% of the time. ADS-B refreshes only at sync time.
- **Stay connected.** Associate and stay. Live ADS-B every 10 s. Remote ID
  Wi-Fi reception is then limited to the access point's channel (BLE is
  unaffected); the footer shows `WI-FI CH 6 ONLY` (or whichever) so the user
  knows. This is the mode for a board on a desk next to its router.

`rx_hop_hold(bool)` is new: it stops the hop timer without setting the
paused state (which drops matches). Implement in `rx_core.h` next to
`hop_cb`.

### 4.3 Wi-Fi settings on the T5 screen

Entry: SYSTEM screen (`draw_diagnostics` in `ui_epd.cpp`) gets a new
section **WI-FI** between MODE & POWER and HARDWARE: a status line
(`OFF`, `SYNC every 15 min, last 12:04Z ok`, `CONNECTED to Home (ch 6)`,
or the last error in words), and buttons **NETWORKS**, **MODE**, **SYNC
NOW**, **UPDATE MAP**. Keep the rest of SYSTEM as it is; the render test
must stay free of collisions (`tests/t5_render_test.cpp`, add scenes).

**Networks screen** (full screen, e-paper):

- A list of up to 8 networks from a scan (`WiFi.scanNetworks(async)`,
  started when the screen opens; the scan takes ~2 s and pauses sniffing,
  say so: "scanning, Remote ID Wi-Fi paused"). Each row: SSID (fitted),
  signal as 4 bars drawn with rects, a lock glyph for secured, "SAVED" chip
  for known ones. Hidden networks: a row "Other network..." opens the
  keyboard for the SSID too.
- Tap a saved network: **CONNECT**, **FORGET**. Tap a new one: the keyboard.
- Up to 5 saved networks in NVS (`Preferences` namespace `orwifi`, keys
  `n`, `s0..s4`, `p0..p4`). Passwords are stored in plain NVS: say so in the
  README; enabling NVS encryption is a later task.

**On-screen keyboard** (the novel part on e-paper):

- Four rows of keys, 10 per row, each ~84x60 px, in the bottom 300 px;
  the text field above shows the entry with a caret; the password is shown
  as typed (e-paper, private device) with a SHOW/HIDE toggle.
- Layers: lower, UPPER (shift, one-shot; double-tap locks), 123, #+=.
  Keys: letters, digits, `. - _ @ ! ? # $ % & * ( ) / : ;` and space,
  backspace, DONE, CANCEL.
- **Refresh strategy:** each key press updates only the text field with a
  partial refresh in `MODE_DU` (fast, ~260 ms, 1-bit: right for black text
  on white, but not DC-balanced, so it ghosts), and briefly inverts the
  pressed key with `MODE_DU` so the press is visible. The full keyboard
  is drawn once with `MODE_GC16` when it opens and when the layer changes.
  After 20 partial updates, a `MODE_GL16` clean-up of the field only.
  Use `refresh_area()` in `ui_epd.cpp`, which already implements these modes.
- Touch targets: accept the key under the touch point's centre; ignore
  touches during a refresh (`epd` busy) rather than queueing them, to avoid
  doubled letters.
- DONE starts a connection test (JOIN with a 15 s timeout, then LEAVE unless
  mode is Stay connected); success saves the network; failure shows the
  reason (`wrong password`, `network not found`, `no IP address`), mapped
  from `WiFi.status()` / disconnect reason codes.

Provisioning from the phone (the app) is the same operation over BLE:
`{"cmd":"wifi_scan"}` -> `{"type":"wifi_net","ssid","rssi","secure"}` lines
then `{"type":"wifi_scan_done","n"}`; `{"cmd":"wifi_join","ssid","psk"}` ->
`{"type":"wifi_status","state":"connected|failed","reason","ip","ch"}`;
`{"cmd":"wifi_forget","ssid"}`; `{"cmd":"wifi_mode","mode":"off|sync|stay","every_min"}`;
`{"cmd":"wifi_status"}`. These require an encrypted (bonded) BLE link and are
refused over serial unless the board is in a new `"setup"` state entered
from the SYSTEM screen (so a USB cable is not a way to read passwords).

### 4.4 ADS-B on the T5

- *(Built as `net_parse.h` + `traffic.h`'s `TrafficAircraft`; no `adsb.h`.)*
  `firmware/common/adsb.h`: parse the adsb.lol answer into
  `struct Aircraft { uint32_t hex; char flight[9]; char type[5]; float lat, lon;
  int32_t alt_ft; float gs_kt, track; uint16_t squawk; uint8_t emergency; uint32_t seen_ms; }`,
  32 max (the same limit as section 8.1), keeping only those with a
  position within 30 km of home.
- Draw them distinctly from drones everywhere (never confusable):
  - **Plot and map:** an outlined diamond with a heading tick, label
    `callsign FL/alt` (e.g. `UAL123 3.2k ft`); grey when older than 30 s.
  - **Side view:** manned aircraft as outlined diamonds on the same
    height-vs-range axes (convert feet to metres); the height scale extends
    to include them up to 1,500 m, then clips with an "above" arrow.
  - **Proximity alert (new, the reason ADS-B is worth having here):** a
    drone and a manned aircraft within 1 km horizontally and 150 m
    vertically (both with positions, heights compared as broadcast, noting
    the drone's height reference) raise an alert `MANNED AIRCRAFT NEAR
    <drone id>`, added to `ui_danger()` reasons and to the glance band.
    Word it as proximity of two reported positions, never as a predicted
    collision.
- Squawk 7500/7600/7700 and `emergency` set: show the word (`HIJACK`,
  `RADIO FAIL`, `EMERGENCY`) next to the label.

### 4.5 Map tiles over Wi-Fi

`tile_store.h` already stores and evicts tiles and reports `fs_*` to the Mac
app. Add `tile_fetch.h` (built inside `net_fetch.h` / `net_parse.h`): compute the tile list around home (as built: a 3 km circle,
zooms 12-15, planned against free flash by `tile_plan.h`, mirrored by
`TileSync.swift` / `TilePlan.swift` and `tools/fetch_tiles.py`,
but centred on the board's position), skip tiles already present, fetch at
most 4 per second with `User-Agent: orecchino/<ver>`, stream each to a
temporary file then rename, stop when free space falls under 1 MB. Progress
appears in the footer as the Mac sync's does ("MAP 120/340"). Respect
CARTO's terms (attribution is already on the map; do not bulk-download
beyond this area).

### 4.6 Firmware tasks (T5 Wi-Fi), in order

1. `rx_hop_hold()`; `net_sync.h` state machine with a fake network in
   `tests/host_shim/` and host tests for every transition, back-off and
   job scheduling.
2. SNTP + RTC; TFR fetch with bbox, parse, raise TFR limits, host test
   parsing a saved copy of the FAA answer (commit a trimmed fixture under
   `tests/vectors/`).
3. ADS-B fetch + `adsb.h` + drawing on plot, map, side view + proximity
   alert; host tests for parsing and the alert rule; render scenes.
4. Wi-Fi section on SYSTEM, networks screen, keyboard; render scenes for
   each keyboard layer, a long SSID, a failed join.
5. Wi-Fi modes and the header indicator.
6. Tile fetch; host test for the tile list and the free-space stop.
7. README: a T5 "Wi-Fi" subsection (modes, what is fetched, the channel
   trade-off, password storage). (Done; no ArduinoJson dependency.)

---

## 5. The phone app

### 5.1 Technology

**Flutter** (Dart 3), one codebase for iOS and Android. Reasons: one UI to
design once; mature BLE (`flutter_blue_plus`), maps (`flutter_map`; as
built, Esri World Dark Gray Canvas tiles, since CARTO now needs a key),
local database (`drift` on SQLite), state (`riverpod`).
Native Swift would reuse the Mac app's code on iOS but double the work for
Android.

Packages (pin exact versions in `pubspec.yaml` at the time of building;
check each is maintained). As built, the app uses plain `ChangeNotifier`
state and a custom-painted radar, so `flutter_riverpod` is not a
dependency; `flutter_map` 8.3.2 and `latlong2` 0.10.1 came with the Live
screen's Map mode:

| Need | Package |
| --- | --- |
| BLE | `flutter_blue_plus` |
| State | `flutter_riverpod` |
| Local DB | `drift`, `sqlite3_flutter_libs` |
| Map | `flutter_map`, `latlong2` |
| Location | `geolocator` |
| Heading (compass) | `flutter_compass` or `sensors_plus` magnetometer + accelerometer |
| Haptics | `flutter/services.dart` `HapticFeedback` |
| Background (Android) | as built: a native Kotlin foreground service on the app's one cached engine (§5.5), not `flutter_foreground_task` (it runs a second engine) |
| Notifications | `flutter_local_notifications` |
| HTTP (TFRs, ADS-B on the phone) | `http` |

Repository layout: a new top-level `mobile/` directory (Flutter project
`orecchino_mobile`), with its own README and tests; the root README links
to it.

### 5.2 Architecture

```
lib/
  main.dart
  core/
    protocol/      line codec (bytes <-> lines), message models, command builders
    ble/           scanner, connection, NUS transport, pairing state
    sync/          history sync engine (since/next cursors per detector)
    location/      phone position + heading, push to detector
    airspace/      TFR + ADS-B fetch on the phone (for the map; pushed to boards)
  data/
    db.dart        drift schema
    repos/         detectors, detections (history), live tracks
  features/
    detectors/     list, pairing, detector detail, Wi-Fi setup (T5)
    live/          radar + list of live contacts
    find/          point-and-find (compass) view
    map/           map with drones, operators, TFRs, ADS-B, history
    history/       timeline + list + filters + export
    settings/
  ui/              theme tokens, shared widgets
test/              unit tests (protocol, sync, alert rules), widget tests, golden tests
integration_test/  against a simulated detector (below)
```

**Models** mirror the firmware exactly: `RidLine` (fields of `rid`),
`Heartbeat`, `LogRecord` (fields of `log`), `LogDone`, `DeviceInfo`,
`WifiNet`, `WifiStatus`. Parse with explicit null handling (a missing field
is unknown, never zero), exactly as `RidMessage.swift` does; port its tests.

**Database** (drift):

- `detectors(id PK = BLE remote id, name, board, fw, ver, caps, last_seen, last_sync_seq, oldest_seq, bonded)`
- `detections(detector_id, seq, uas_id, mac, srcs, fmts, ua_type, first_utc, last_utc, dur_s, lat, lon, max_h, peak_rssi, auth_state, tfr, emerg, msgs, PRIMARY KEY(detector_id, seq))`
- `live_points(detector_id, uas_key, t, lat, lon, height, rssi)` (ring, 24 h)

**Sync engine:** on connect, send `set_time`, `set_home`, then
`log_get since=<last_sync_seq>`; upsert records; on `log_done` store
`next` as `last_sync_seq`; if `oldest > last_sync_seq`, record a gap
("some history rotated out on the detector before this phone synced").
Resume after disconnect from the stored cursor. Background behaviour and
power, as built, are in §5.5.

**Simulated detector** for tests and for building without hardware: a Dart
class implementing the transport interface that plays a scripted stream
(boot, hb, rid lines from `tests/vectors`, a 500-record log) and answers
commands. The app has a hidden "Demo detector" switch (like the Mac app's
demo mode), clearly labelled SIMULATED everywhere it shows.

### 5.3 UI/UX

The app should feel like an instrument, not a dashboard. Principles carried
over from the Mac app and boards (keep them): missing data is blank, never
zero; alerts are words, never colour alone (`EMERGENCY REPORTED`, `ID
SIGNATURE INVALID`, `IN TFR`); `id_valid` means the ID was signed, never
that the position is trustworthy; stale after 60 s everywhere.

Design tokens (dark-first, from `app/Sources/Orecchino/Theme.swift`):
ground `#07090E`, text `#E2E8F0`, muted `#8A99AD`, accent `#35D0BA`,
danger `#E05A5A`, amber `#E0A83A`, ok `#5ECB7A`; a light theme derived for
daylight use with the same roles. Type: a condensed sans for numbers
(tabular figures), a plain sans for text. As built there are two looks
(Detectors > Settings > Theme, `mobile/lib/ui/theme/look.dart`): **Sky**
(the default: night-sky palette, frosted glass over a living aurora, a 3D
sky) and **Flat** (the design mockups' dark palette and IBM Plex type,
flat panels, a top-down radar, no animation); see `mobile/README.md`.

**Navigation:** a bottom bar with four places: **Live**, **Find**,
**History**, **Detectors**. Settings from Detectors.

**Live** (home): a radar centred on the phone, **rotated to the phone's
heading** (the boards cannot do this; the phone has a compass), range rings
auto-scaled, drones as dots with heading ticks, operators as squares joined
by a dashed line, manned aircraft (ADS-B fetched by the phone) as diamonds,
TFR edges as hatched arcs. Below, a sheet with the contact list (drag up for
more): each row the ID, the words for any alert, range and bearing from the
phone, height with its reference, a 60-second signal sparkline, and
"closing 4 m/s" or "opening" as text. Tap a contact: its card.

**Find** (point and find): pick a contact; the screen becomes one large
arrow that points to it as you turn the phone (bearing minus heading), the
range in large type, closing or opening, and a warmer/colder signal trend
for contacts without a position (drives the arrow's opacity instead of its
direction, and says so). Haptic ticks get faster as range falls through 500,
200, 100, 50 m. Works only while a detector is connected and streaming
(`feed on`).

**History:** a horizontal timeline scrubber across the top (the last 24 h
by default, pinch to zoom to 7 days) with one lane per aircraft, bars where
it was heard, red where it declared an emergency, a diamond where it entered
a TFR. Scrubbing replays positions on a map below. Filters: detector,
alerts only, ID contains. Each record opens a card with first/last heard,
duration, sources, peak signal, max height, signature state. Export CSV
(the same columns as the Mac app's `DeviceLog.csv(_:)` in `app/Sources/Orecchino/DeviceLog.swift`) through the share
sheet.

**Detectors:** one card per known detector: board name and picture-free
icon, connection state, battery (from `hb` when it has one), clock set or
not, position source, history count and last sync, a **Sync** button, and
for T5s a **Wi-Fi** row (mode and status) that opens Wi-Fi setup (scan list,
password, mode) over BLE. Pairing flow: scan -> choose -> the board shows a
passkey -> type it -> done, with a clear explanation screen before the
first pairing. Unpaired boards in range are listed with "Pair".

**Alerts:** local notifications for new dangers (emergency, invalid ID
signature, TFR incursion, manned aircraft near a drone), rate-limited to
one per contact per 5 minutes, only while a detector is connected. No
notification ever says "safe".

**Accessibility:** VoiceOver/TalkBack labels on every mark and row (read the
same words the screen shows), Dynamic Type up to XXL without clipping,
contrast 4.5:1 for text in both themes, haptics optional, no information in
colour alone.

### 5.4 Permissions and store requirements

- iOS `Info.plist`: `NSBluetoothAlwaysUsageDescription` ("Connects to your
  Orecchino detectors"), `NSLocationWhenInUseUsageDescription` ("Gives your
  detectors your position so they can show range and bearing"),
  `UIBackgroundModes: bluetooth-central`.
- Android: `BLUETOOTH_SCAN` with `neverForLocation` (API 31+),
  `BLUETOOTH_CONNECT`, `ACCESS_FINE_LOCATION` (for the phone's own position,
  and for scanning on API < 31), `FOREGROUND_SERVICE` +
  `FOREGROUND_SERVICE_CONNECTED_DEVICE` (API 34+), `POST_NOTIFICATIONS`.
  As built, Android also declares `FOREGROUND_SERVICE_LOCATION` and the
  companion-device permissions (`REQUEST_COMPANION_RUN_IN_BACKGROUND`,
  `REQUEST_COMPANION_START_FOREGROUND_SERVICES_FROM_BACKGROUND`,
  `REQUEST_OBSERVE_COMPANION_DEVICE_PRESENCE`); never `dataSync`.
- A privacy statement: the app stores drone and operator positions on the
  phone only; nothing is uploaded. TFR and ADS-B requests go to the FAA and
  adsb.lol with the phone's approximate area.

### 5.5 Power and background (as built)

**Power modes** (Detectors > Settings > Power; one table,
`mobile/lib/core/power/power_policy.dart`, keyed on the mode, whether the
app is in front, and the visible tab):

| | Full | Balanced (default) | Saver |
|---|---|---|---|
| Animation | 30 frames/s, each glass panel its own blur | aurora 24 frames/s at 1/4 resolution, grouped blur | still sky, tint instead of blur |
| Phone BLE scan, in front | low latency | low latency on Live/Find, else balanced | balanced on Live/Find only |
| Phone BLE scan, background (Android) | balanced | low power (balanced for 2 min after a drone) | off |
| Wi-Fi beacons / NAN (Android) | 30 s / on | 60 s in front, 2 min behind / Live and Find only | off |
| ADS-B | every 10 s | 10 s with a live drone or a traffic detector, else 60 s | 30 s with a live drone only |
| Detector feed | on | on: a background digest needs the firmware; the feed stays on until the detector supports it | on (same) |
| Location | high | high on Live/Find, else medium (50 m) | medium; last fix in the background |
| Compass | 15/s on Live/Find | 10/s on Live/Find | Find only |

In every mode ambient motion runs on one shared 24–30 Hz timer (never the
display's vsync) and stops under Reduce Motion, in the background and
under Map mode; the compass has its own throttled listenable (10/s, 2°) so
turning the phone repaints only the sky and Find's pointer; the app
notifies its screens once a second; ADS-B needs a position and backs off
after failures (10 s doubling to 5 minutes). An idle Live screen asks for at
most 30 frames a second in Balanced (a regression test holds it there).

**Android:** "Watch in the background" (off by default) runs a native
foreground service (`OrecchinoWatchService.kt`; types connectedDevice, plus
location when granted) that keeps the app's one cached Flutter engine
(`OrecchinoApplication.kt`) alive with the app closed, so the detector link,
the phone's receiver (at its background duty), the rules and the alerts
carry on. Its notification: "Orecchino watching · 2 drones · conflict watch
on · T5 connected", with Open, Pause 1 h (alerts muted, the phone's receiver
and position resting) and Stop (until the app is opened). It starts only
while the app is on screen. After pairing, the app associates the detector
through CompanionDeviceManager; Android then lets it run and start its
service in the background for that detector, and on Android 12+ wakes it
when the detector comes into range. Reconnecting to an associated detector
is a pending connect (`autoConnect`), not a scan loop; without the
association the old 15 s connect retried 5–60 s apart remains.

**iOS:** `bluetooth-central` plus Core Bluetooth state restoration and a
pending connect (no timeout) to the detector: in the background the iPhone
stays connected to the detector and alerts; the phone's own Remote ID
receiver works only while the app is open (iOS delivers no Remote ID
adverts to a background scan); without a detector there are no background
alerts; swiped away, the app stops until it is opened. The Settings screen
says exactly this.

---

## 6. Milestones and acceptance tests

Each milestone ends with `tests/run_tests.sh` green, the README updated, and
a commit. "Hardware" tests need two boards (a transmitter and a receiver);
the T5 and T-Embed can both run the test beacon.

**M1 — BLE link on the boards.** Sections 3.1-3.3, 3.5 tasks 1-4.
- B1: nRF Connect on a phone pairs with a T5 by passkey, subscribes to TX,
  sends `{"cmd":"feed","on":true}\n` and sees `rid` lines from a test beacon.
- B2: `log_get` over BLE returns the same records as over USB (diff the
  two captures).
- B3: with a phone connected, BLE Remote ID detections per minute from the
  test beacon fall by less than 20% against not connected (10-minute runs).
- B4: an unbonded phone cannot read or write any characteristic.
- Host: command lines injected through the fake BLE transport produce the
  same output as through `MockSerial`.

**M2 — History on flash, incremental.** Section 3.4.
- Host: records survive a simulated power cut after a save; `since` returns
  exactly the records at or after the cursor; rotation keeps the newest;
  `oldest`/`next` are right across a rotation.
- Hardware: 1,000 synthetic records (from a test hook compiled only in a
  test build) sync to nRF Connect in under 30 s at MTU 247.

**M3 — App skeleton with the simulated detector.** Protocol, models, DB,
sync engine, Detectors and History screens, against the simulator.
- Unit tests for the codec (split lines across notifications of every size
  from 20 to 514 bytes), models (port `OrecchinoTests.swift` cases), sync
  (gap detection, resume).
- Golden tests for History at phone and tablet sizes, light and dark.

**M4 — App on real detectors.** BLE transport, pairing, location/time push,
Live and Find.
- Hardware: the phone pairs with T5 and T-Embed; Live shows the test
  beacon's ten aircraft; Find points to one within 30° while walking around
  a transmitter at 50 m (field test, record results in the PR).

**M5 — T5 Wi-Fi core.** Sections 4.2, 4.6 tasks 1-2, 5.
- Host: the state machine's transitions, timeouts and back-off.
- Hardware: in Sync mode the board sets its clock and loads TFRs every 15
  minutes; Remote ID detections of the test beacon over 30 minutes fall by
  less than 3% against Wi-Fi off.

**M6 — T5 Wi-Fi UI.** Section 4.3.
- Render scenes (no collisions): SYSTEM with Wi-Fi section in each state,
  networks list with 8 entries and a 32-character SSID, keyboard in each
  layer, a failed join.
- Hardware: join a WPA2 network by typing a 20-character password on the
  e-paper keyboard in under 90 s; wrong password shows "wrong password".

**M7 — ADS-B and tiles on the T5.** Sections 4.4-4.5.
- Host: parse a saved adsb.lol answer; the proximity rule (inside/outside
  both thresholds, missing heights never alert); tile list and space stop.
- Render scenes: plot, map and side view with 10 aircraft and 8 drones.
- Hardware: with Stay connected, aircraft appear within 20 s; "Update map"
  fills the area around home.

**M8 — App polish and release.** Notifications, Wi-Fi setup over BLE,
export, accessibility pass, store metadata, privacy text. TestFlight and an
internal Play track.

---

## 7. Risks and decisions to confirm

- **One radio.** Stay-connected Wi-Fi costs Remote ID Wi-Fi coverage; Sync
  costs about 1%. The UI must say which mode is on. A second chip removes it
  (see the station feasibility report); out of scope here.
- **BLE airtime.** A phone connection competes with scanning; measure (B3)
  before adding features that stream more.
- **adsb.lol is a community service** with no SLA; keep it configurable,
  cache, and back off on errors. Check its terms before a public release.
- **FAA WFS is not a published API** (it is what tfr.faa.gov's map uses).
  Keep the parser tolerant and the failure visible ("TFRs 3 h old").
- **TLS on the T5** needs internal RAM the display and radios also use
  (section 4.1); if it cannot be made to fit, the phone becomes the T5's
  internet link for TFRs and traffic.
- **ADS-B coverage is incomplete by nature**; the wording rules in 8.2 exist
  so no screen implies otherwise.
- **Passwords in NVS** are readable by anyone with the board and a USB
  cable plus esptool; document it; NVS encryption is follow-up work.
- **iOS background BLE** is limited; the app must not claim continuous
  monitoring when backgrounded.
- **Store review:** an app that shows drone operator positions may draw
  questions; the privacy text should say the data comes from public
  broadcast Remote ID and stays on the phone.

---

## 8. ADS-B traffic alerts on every surface

Manned aircraft positions come from the internet (adsb.lol, section 1) and
are compared with the drones the receivers hear. The alert rules live in one
header, `firmware/common/traffic.h`, ported line for line to the apps
(`TrafficRules.swift`, `traffic_rules.dart`) and tested on the same vectors
(`tests/vectors/traffic/*.json`: aircraft, drones, observer, expected alerts).

### 8.1 Where the aircraft come from

- **T5 on Wi-Fi:** its own fetch (section 4.1).
- **Any board, from an app:** new command
  `{"cmd":"traffic","t":<unix s of the data>,"ac":[{"hex":"a1b2c3","cs":"UAL123","ty":"B738","lat":37.8,"lon":-122.4,"altg_m":820,"altb_ft":2650,"gs_kt":180,"trk":270,"vr_fpm":-640,"sq":"7700","em":1,"age_s":3}, ...]}`,
  at most 6 aircraft per line (8 would come to about 1,500 of the host line
  buffer's 1,600 bytes; send several lines), nearest first, plus `{"cmd":"traffic_done","n":<total>}`.
  The Mac app and the phone send it every 10 s while they have data, so the
  T-Embed and SenseCAP get traffic alerts without Wi-Fi of their own.
- Keep at most 32 aircraft within 30 km of the observer; drop any whose
  position is older than 60 s.

### 8.2 The rules

Definitions: an aircraft *position* is fresh when `seen_pos` (or `age_s`)
is under 30 s; a drone is live when heard within 60 s and has a position.
Heights are compared like with like, and never as though they were:

- Drone height for comparison: the Location message's geodetic altitude
  (`alt_geo`, metres, height above the WGS-84 ellipsoid), with ADS-B
  `alt_geom` (feet, geometric altitude, also above the WGS-84 ellipsoid)
  converted to metres. Same reference, so they compare directly; drone
  `height` (above take-off or ground) is never used for this.
- If either geometric value is missing, the vertical test is **unknown**,
  not passed: the alert is raised with the words `height unknown` instead of
  a separation, never silently dropped and never shown as safe.
- ADS-B `alt_baro` is pressure altitude above mean sea level; it is shown
  (as FL or feet) but not compared with drone heights.

| Class | Condition | Words (all surfaces) |
| --- | --- | --- |
| **Traffic near a drone** (warning) | live drone and fresh aircraft within 1.0 km horizontally and 150 m (500 ft) vertically, or unknown vertical within 1.0 km | `TRAFFIC NEAR DRONE <id>` |
| **Converging** (warning) | closest approach between drone and aircraft, from both velocity vectors (aircraft `gs`/`track`, drone speed/heading), within 60 s and under 500 m horizontally and 150 m vertically; if either velocity is missing this rule is skipped (the proximity rule above still applies) | `TRAFFIC CONVERGING WITH <id>, <n> S` |
| **Low traffic near you** (caution) | fresh aircraft within 3 km of the observer and below observer elevation + 460 m (1,500 ft); observer elevation from GPS (T5), the phone, or the Mac's position; unknown elevation: use 460 m above sea level and say `approx.` | `LOW TRAFFIC <bearing> <km>` |
| **Emergency squawk** (advisory) | `squawk` 7500 / 7600 / 7700 or `emergency` set, within 30 km | `HIJACK` / `RADIO FAILURE` / `EMERGENCY` + callsign |

- **Hysteresis:** an alert clears only when the pair is beyond 1.3 km or
  200 m for 20 s, so it cannot flap.
- **Stale data:** when the newest ADS-B data is older than 30 s, no new
  traffic alert is raised, existing ones show `ADS-B <n> S OLD`, and every
  surface shows `TRAFFIC DATA STALE` instead of a traffic count.
- **Absence is not safety.** Not every aircraft broadcasts ADS-B (gliders,
  some helicopters, older light aircraft), and the feed has gaps. No surface
  ever says "clear", "no traffic" or "safe": the most it says is
  `no ADS-B traffic reported within 3 km`, with the data age.
- **Wording:** these are reported positions, not predictions of collision.
  Never use "collision", "conflict" or "TCAS". Always show the data age.
  The T5 footer's existing `QUIET <n> MIN` is about Remote ID only (no drone
  heard lately); traffic must never reuse that word.
- **Rate limits:** a notification (phone, Mac) at most once per
  drone-aircraft pair per 5 minutes; the on-screen alert stays for as long
  as the condition does.

### 8.3 On the T5 (e-paper)

- **Getting attention on e-paper.** A new *warning* forces a full `MODE_GC16`
  refresh: the panel's black flash is itself the cue, and the only motion an
  e-paper board can make. It also pulses the front light three times
  (`periph_bl_*`), including by day, so it can be noticed across a room.
- **Header:** the black alert header's headline reads the traffic words
  first (`TRAFFIC NEAR DRONE D9A03`), extending `ui_headline()`.
- **Traffic card:** while a warning is active, the plot panel (right side
  of TABLE, where the target card goes today) shows a traffic card: the
  aircraft's callsign and type in the largest type that fits, then
  *relative to the drone* ("1.1 km NE of D9A03, 90 m above it"), its own
  altitude (`2,650 ft`), ground speed, a climb or descent arrow with fpm,
  and `ADS-B 6 s old`. Tapping it opens the drone's details with a
  "Nearest traffic" section.
- **Plot and map:** aircraft as outlined diamonds with a heading tick and a
  label `UAL123 2.6k ft`; a **time ghost** for each: dots at 15, 30, 45 and
  60 s along its projected track, e-paper-friendly because it is static and
  shows where it is going without animation. Drawn under drone marks;
  never filled, so a drone and an aircraft cannot be confused.
- **Side view:** aircraft diamonds on the same axes (their geometric
  altitude above the board's elevation), and for each traffic pair a
  vertical bracket from the drone to the aircraft labelled `Δ 90 m / 300 ft`.
- **Glance mode:** the alert band gains the traffic words
  (`TRAFFIC NEAR DRONE | 1 EMERGENCY`) and the second line gives the nearest
  aircraft (`nearest traffic 2.1 km NE, 1,900 ft`).
- **Header indicator** for the feed itself: `ADS-B 12` (aircraft held),
  `ADS-B STALE`, or nothing when there is no source.
- **Render scenes to add:** table with a traffic card; map and side view
  with 10 aircraft and 8 drones and one pair; glance with traffic; a stale
  feed. Host tests for every rule, hysteresis and the stale suppression.

### 8.4 On the phone

- **Notification** (iOS interruption level *time-sensitive* for warnings,
  *active* otherwise; Android channel "Traffic near drones", high
  importance): title `Traffic near drone D9A03`; body `B738 UAL123 ·
  2,650 ft · 1.1 km NE of the drone · reported 6 s ago`; actions **Show**
  and **Mute 10 min**.
- **Live Activity / Dynamic Island** (iOS 16.1+) while a warning is active:
  compact leading an airplane glyph and `1.1 km`, compact trailing the
  **clock position relative to the phone's heading** (`2 o'clock`),
  the phrasing pilots use for traffic; expanded: callsign and type,
  altitude and trend, separation from the drone, data age. Android: an
  ongoing notification with the same content, updated at most every 5 s.
- **In the app:** on the Live radar, aircraft diamonds with their 60 s
  projection, and between a drone and its traffic a **separation bridge**:
  a capsule joining the two marks, labelled with the horizontal and
  vertical separation, that tightens as they converge. A banner reads the
  same words as the notification plus the clock position. Optional spoken
  callout (off by default, uses the system voice): "Traffic, two o'clock,
  one point one kilometres, two thousand six hundred feet, descending."
  A haptic pattern distinct from drone alerts (three short pulses).
- **Find:** a Traffic mode that points the big arrow at the aircraft
  instead of a drone.
- **As built, power and background:** the phone asks adsb.lol every 10 s
  only while a drone is live or a detector takes traffic (otherwise every
  60 s; Saver: 30 s with drones only; none without a position; backoff to
  5 minutes after failures, never sooner than the usual interval). With the app closed, alerts continue on
  Android while "Watch in the background" runs (its notification carries
  the conflict-watch state), and on iOS while the detector link keeps the
  app awake; ADS-B then runs only as often as those wakes allow (§5.5).

### 8.5 On the Mac app

- `TrafficService.swift`, like `TFRService.swift`: fetch adsb.lol around the
  Mac's position every 10 s while the window is open, keep aircraft for 60 s,
  run `TrafficRules.swift`, and push `traffic` lines to the connected
  receiver (8.1).
- **Map:** a **Traffic** toolbar toggle beside TFR; aircraft drawn with the
  system `airplane` symbol rotated to track, label callsign and altitude,
  60 s projection as a dashed line; drone-aircraft pairs joined by the same
  separation bridge as the phone.
- **Alert strip** (`AlertStrip` in `ContentView.swift`): traffic alerts in
  the same words, above drone alerts, each with "Show" to centre the map on
  the pair.
- **Drone detail card:** a "Nearest traffic" row: `UAL123 B738 · 1.1 km ·
  +90 m · closing`.
- **Notifications** through `UNUserNotificationCenter`, time-sensitive for
  warnings, rate-limited as in 8.2.
- **Menu bar extra** (`MenuBarExtra`): an airplane glyph with the count of
  aircraft within 3 km, drawn filled and in the alert colour while a warning
  is active, so traffic is visible from any app; its menu lists the alerts.
- **Tests:** `TrafficRules` against the shared vectors; the service's
  staleness and push cadence with a fake clock.

### 8.6 Milestone

**M9 — Traffic alerts.** `traffic.h` + vectors + host tests; the `traffic`
command on all receivers; T5 drawing (8.3); Mac app (8.5); phone (8.4, after
M4). Acceptance: the shared vectors pass on all three implementations; on
hardware, a scripted `traffic` feed from the Mac app (a fake aircraft flown
past the test beacon's aircraft) raises `TRAFFIC NEAR DRONE` on the T5, the
T-Embed and the Mac within 12 s of the pair coming within 1 km, and clears
within 30 s of it opening beyond 1.3 km.
