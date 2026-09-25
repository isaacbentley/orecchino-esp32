// Bluetooth Low Energy (BLE) link for Orecchino receivers.
//
// Exposes the Nordic UART Service (NUS) and Orecchino Device Info Service.
// Transmits framed JSON lines via notifications and receives command lines
// via RX characteristic writes, sharing handle_host_line() with serial.
//
// Threading. NimBLE calls onWrite on its own host task (5 KB of stack, and
// the task that also delivers BLE scan reports), so a command is never run
// there: complete lines are copied into a ring and ble_link_poll(), from
// rx_tick() on the loop task, runs them exactly as a serial line runs. Going
// out, lines wait in two rings drained by a small notify task: replies and
// log records ahead of the live feed (rid, hb), which is dropped when the
// phone cannot keep up. A reply waits for room once (host_link.h's
// HOST_CTL_WAIT_MS); a peer that stops reading then loses replies too, and
// emit_log tells it so (log_done "err":"dropped").
//
// Security. The passkey is the fixed, public 123456 (a deliberate choice:
// the link protects against passers-by, not a determined attacker). Nothing
// flows to or from a peer until its link is encrypted AND authenticated --
// paired with the passkey, not Just Works: NimBLE only asks for MITM
// protection, and a peer declaring NoInputNoOutput would otherwise get an
// encrypted, bonded link that never showed the code. Such a pairing is
// refused (bond deleted, peer dropped), the RX characteristic and the CCCD
// need an authenticated link, and a peer that has not paired within
// BLE_PAIR_DEADLINE_MS is dropped so it cannot sit on the only connection.
//
// Layout. Everything that decides what happens -- the line assembler, the
// encryption gate, the enqueue policy, the connection state and the pairing
// deadline -- is transport-free and shared by the device and the host
// tests; only the radio differs (NimBLE below, a fake at the end).
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "host_link.h"
#include "ext_ram.h"
#include <stdint.h>
#include <string.h>

#define BLE_NUS_SVC_UUID   "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define BLE_NUS_RX_UUID    "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
#define BLE_NUS_TX_UUID    "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

#define BLE_INFO_SVC_UUID  "0A1B0001-5E1D-4F0E-9C7B-4F52454343A1"
#define BLE_INFO_CHR_UUID  "0A1B0002-5E1D-4F0E-9C7B-4F52454343A1"

#define BLE_PASSKEY          123456
#define BLE_LINE_MAX         1600    // longest host line (a TFR polygon, a tile chunk)
#define BLE_PAIR_DEADLINE_MS 10000   // connected but not encrypted for longer: drop
#define BLE_IDLE_MS          10000   // no command or reply for this long: slow link

// Forward declaration of host line handler with source attribution
void handle_host_line(char* line, uint32_t now, HostSrc src);

// ------------------------------------------------ link state (any transport)

static volatile bool     s_ble_connected = false;
static volatile bool     s_ble_subscribed = false;
static volatile bool     s_ble_encrypted = false;
static volatile bool     s_ble_authenticated = false;   // paired with the passkey, not Just Works
static volatile uint32_t s_ble_conn_ms = 0;        // when the peer connected
static volatile uint32_t s_ble_active_ms = 0;      // last command in or reply out
static volatile uint32_t s_ble_send_drops = 0;     // lines given up on the air (notify refused)
static volatile uint32_t s_ble_rx_drops = 0;       // incoming lines dropped (ring full, too long)
// Outgoing rings, replies ahead of the feed (host_link.h has the policy);
// the transport fills in the ring operation and its ring.
static HostOutQ          s_ble_ctl_q  = { nullptr, nullptr, false, 0, 0 };
static HostOutQ          s_ble_feed_q = { nullptr, nullptr, false, 0, 0 };
// A complete command line into the ring the loop drains; false when it
// does not fit. Wake the drain task after a line was queued.
static bool (*s_ble_rx_deliver)(const char* line, size_t n) = nullptr;
static void (*s_ble_tx_kick)() = nullptr;
// Line assembly for RX writes: touched only on the NimBLE host task.
static char*             s_ble_rx_line = nullptr;
static int               s_ble_rx_len = 0;
static bool              s_ble_rx_overlong = false;

/// The link is encrypted and was authenticated by the passkey.
static inline bool ble_link_secure() { return s_ble_encrypted && s_ble_authenticated; }
static inline bool ble_link_ready() {
  return s_ble_connected && s_ble_subscribed && ble_link_secure();
}
/// A phone is connected on a secure (passkey-paired) link: the T5 pauses
/// its own Wi-Fi syncs while this holds (net_sync.h).
static inline bool ble_link_peer_secure() { return s_ble_connected && ble_link_secure(); }
static inline uint32_t ble_link_drops() { return s_ble_ctl_q.drops + s_ble_feed_q.drops + s_ble_send_drops; }
static inline uint32_t ble_link_rx_drops() { return s_ble_rx_drops; }

/// The host link's sink: nothing leaves for a peer that is not connected,
/// subscribed and encrypted.
static void ble_sink_enqueue(const uint8_t* line, size_t n, HostLineKind kind) {
  if (!ble_link_ready() || n == 0) return;
  if (kind == HOST_FEED) {
    host_outq_put(&s_ble_feed_q, line, n, kind);   // a full ring drops it: a newer frame replaces it
  } else if (host_outq_put(&s_ble_ctl_q, line, n, kind)) {
    s_ble_active_ms = millis();
  }
  if (s_ble_tx_kick) s_ble_tx_kick();
}

/// Bytes as the RX characteristic received them. `secure` is the link's
/// state as the stack reports it for this write: not encrypted and
/// authenticated, and the bytes are ignored (WRITE_AUTHEN should already
/// stop them). A line past BLE_LINE_MAX - 1 is dropped whole rather than
/// run as a truncated command; a complete line the ring cannot take is
/// counted.
static void ble_rx_bytes(const uint8_t* data, size_t n, bool secure) {
  if (!secure || !s_ble_rx_line) return;
  for (size_t i = 0; i < n; i++) {
    char c = (char)data[i];
    if (c == '\n' || c == '\r') {
      if (s_ble_rx_overlong) {
        s_ble_rx_drops += 1;
      } else if (s_ble_rx_len > 0) {
        s_ble_rx_line[s_ble_rx_len] = 0;
        if (!s_ble_rx_deliver || !s_ble_rx_deliver(s_ble_rx_line, (size_t)s_ble_rx_len + 1))
          s_ble_rx_drops += 1;
        s_ble_active_ms = millis();
      }
      s_ble_rx_len = 0;
      s_ble_rx_overlong = false;
    } else if (s_ble_rx_len < BLE_LINE_MAX - 1) {
      s_ble_rx_line[s_ble_rx_len++] = c;
    } else {
      s_ble_rx_overlong = true;   // drop the whole line, not a truncated command
    }
  }
}

static inline void ble_link_on_connect(uint32_t now, bool encrypted, bool authenticated) {
  s_ble_rx_len = 0;
  s_ble_rx_overlong = false;
  s_ble_encrypted = encrypted;
  s_ble_authenticated = authenticated;
  s_ble_conn_ms = now;
  s_ble_active_ms = now;
  s_ble_connected = true;
}

static inline void ble_link_on_disconnect() {
  s_ble_connected = false;
  s_ble_subscribed = false;
  s_ble_encrypted = false;
  s_ble_authenticated = false;
  s_ble_rx_len = 0;                        // a half-written command dies with the link
  s_ble_rx_overlong = false;
  s_ble_ctl_q.stalled = false;
  host_set_feed(SRC_BLE_BONDED, false);   // the next peer asks for itself
}

/// Connected but still not paired past the deadline: drop it.
static inline bool ble_pair_overdue(uint32_t now) {
  return s_ble_connected && !ble_link_secure() && (int32_t)(now - s_ble_conn_ms) > BLE_PAIR_DEADLINE_MS;
}

/// Busy (a sync or the feed) wants the fast connection parameters.
static inline bool ble_link_busy(uint32_t now) {
  return s_feed_ble || (int32_t)(now - s_ble_active_ms) < BLE_IDLE_MS;
}

#if defined(ESP_PLATFORM)
#include <esp_mac.h>
#include <NimBLEDevice.h>
#include <freertos/FreeRTOS.h>
#include <freertos/ringbuf.h>
#include <freertos/task.h>

// Not in NimBLE's public headers: the permissions every CCCD is registered
// with (ble_gatts.c). Set before the server starts so subscribing needs an
// encrypted link, like every other write.
extern "C" void ble_gatts_set_clt_cfg_perm_flags(uint8_t flags);

static RingbufHandle_t         s_ble_rx_rb = nullptr;    // command lines, to the loop
static TaskHandle_t            s_ble_tx_task = nullptr;
static NimBLEServer*           s_ble_server = nullptr;
static NimBLECharacteristic*   s_ble_tx_char = nullptr;
static volatile uint16_t       s_ble_conn_id = BLE_HS_CONN_HANDLE_NONE;
static volatile uint16_t       s_ble_itvl_ms = 50;       // current connection interval
static volatile bool           s_ble_fast = true;        // fast connection parameters asked for

// Weak hook for pairing display on boards with a screen. Called on the
// NimBLE host task: set a flag and draw from the loop.
extern "C" __attribute__((weak)) void rx_hook_pairing(uint32_t passkey, bool show);

static bool ble_ring_send(void* ring, const uint8_t* line, size_t n, uint32_t wait_ms) {
  return xRingbufferSend((RingbufHandle_t)ring, line, n, pdMS_TO_TICKS(wait_ms)) == pdTRUE;
}
static bool ble_rx_ring_deliver(const char* line, size_t n) {
  return xRingbufferSend(s_ble_rx_rb, line, n, 0) == pdTRUE;
}
static void ble_tx_kick() {
  if (s_ble_tx_task) xTaskNotifyGive(s_ble_tx_task);
}

/// Notify one line in MTU-sized slices. NimBLE refuses a notification when
/// its mbuf pool is empty (12 + 24 blocks, shared with scanning); a slice is
/// retried a connection interval later rather than skipped, since a missing
/// slice corrupts the line and the one after it.
static void ble_send_line(const uint8_t* p, size_t n) {
  uint16_t conn = s_ble_conn_id;
  size_t mtu = s_ble_server ? s_ble_server->getPeerMTU(conn) : 23;
  size_t chunk_max = (mtu > 3) ? (mtu - 3) : 20;
  size_t off = 0;
  while (off < n) {
    size_t chunk = n - off;
    if (chunk > chunk_max) chunk = chunk_max;
    int tries = 0;
    while (!s_ble_tx_char->notify(p + off, chunk, conn)) {
      if (!ble_link_ready() || ++tries > 60) {   // ~3 s at 50 ms: give the line up
        s_ble_send_drops += 1;
        return;
      }
      vTaskDelay(pdMS_TO_TICKS(s_ble_itvl_ms > 7 ? s_ble_itvl_ms : 8));
    }
    off += chunk;
  }
}

static void ble_notify_task(void*) {
  for (;;) {
    ulTaskNotifyTake(pdTRUE, portMAX_DELAY);   // asleep until a line or a disconnect
    for (;;) {
      RingbufHandle_t rb = (RingbufHandle_t)s_ble_ctl_q.ring;
      size_t n = 0;
      uint8_t* item = (uint8_t*)xRingbufferReceive(rb, &n, 0);
      if (!item) { rb = (RingbufHandle_t)s_ble_feed_q.ring; item = (uint8_t*)xRingbufferReceive(rb, &n, 0); }
      if (!item) break;
      if (ble_link_ready() && s_ble_tx_char) ble_send_line(item, n);   // else: flushed
      vRingbufferReturnItem(rb, item);
    }
  }
}

static void ble_start_adv() {
#if CONFIG_BT_NIMBLE_EXT_ADV
  NimBLEDevice::getAdvertising()->start(0);
#else
  NimBLEDevice::getAdvertising()->start();
#endif
}

static void ble_stop_adv() {
#if CONFIG_BT_NIMBLE_EXT_ADV
  NimBLEDevice::getAdvertising()->stop(0);
#else
  NimBLEDevice::getAdvertising()->stop();
#endif
}

// Connection parameters (1.25 ms units). Fast while a sync or the feed runs;
// slow with latency when idle, which spares the shared 2.4 GHz front end and
// the battery. Both sets are inside Apple's accessory rules.
static void ble_conn_params(uint16_t conn, bool fast) {
  if (!s_ble_server) return;
  if (fast) s_ble_server->updateConnParams(conn, 24, 40, 0, 400);    // 30-50 ms, 4 s timeout
  else      s_ble_server->updateConnParams(conn, 80, 160, 4, 600);   // 100-200 ms, latency 4, 6 s
  s_ble_fast = fast;
}

// A pairing refused for not using the code: its bond is deleted where the
// refusal happens and again once the link is down, in case the stack
// stored the keys after the authentication callback returned.
static NimBLEAddress s_ble_refused_addr;
static bool          s_ble_refused = false;

class OrecchinoServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo) override {
    (void)pServer;
    s_ble_conn_id = connInfo.getConnHandle();
    ble_link_on_connect(millis(), connInfo.isEncrypted(), connInfo.isAuthenticated());
    ble_conn_params(connInfo.getConnHandle(), true);
    ble_stop_adv();
    // Ask for pairing now rather than when the peer first touches an
    // encrypted attribute, so the pairing deadline is fair.
    NimBLEDevice::startSecurity(connInfo.getConnHandle());
  }

  void onDisconnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo, int reason) override {
    (void)pServer; (void)connInfo; (void)reason;
    ble_link_on_disconnect();
    s_ble_conn_id = BLE_HS_CONN_HANDLE_NONE;
    if (s_ble_refused) { s_ble_refused = false; NimBLEDevice::deleteBond(s_ble_refused_addr); }
    ble_tx_kick();   // flush what was queued
    if (rx_hook_pairing) rx_hook_pairing(0, false);
    ble_start_adv();
  }

  uint32_t onPassKeyDisplay() override {
    if (rx_hook_pairing) rx_hook_pairing(BLE_PASSKEY, true);
    return BLE_PASSKEY;
  }

  void onAuthenticationComplete(NimBLEConnInfo& connInfo) override {
    if (rx_hook_pairing) rx_hook_pairing(0, false);
    if (!connInfo.isEncrypted() || !connInfo.isAuthenticated()) {
      // Failed, or a Just Works pairing that never showed the passkey: no
      // bond to come back on (deleted now and again after the disconnect),
      // and no connection.
      s_ble_refused_addr = connInfo.getIdAddress();
      s_ble_refused = true;
      NimBLEDevice::deleteBond(s_ble_refused_addr);
      NimBLEDevice::getServer()->disconnect(connInfo.getConnHandle());
      return;
    }
    s_ble_encrypted = true;
    s_ble_authenticated = true;
  }

  void onConnParamsUpdate(NimBLEConnInfo& connInfo) override {
    uint32_t ms = connInfo.getConnInterval() * 5u / 4u;
    s_ble_itvl_ms = (uint16_t)(ms < 8 ? 8 : ms);
  }
};

/// One object for both NUS characteristics: RX delivers writes, TX reports
/// its subscription.
class NusCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* pChar, NimBLEConnInfo& connInfo) override {
    NimBLEAttValue val = pChar->getValue();
    ble_rx_bytes(val.data(), val.length(), connInfo.isEncrypted() && connInfo.isAuthenticated());
  }

  void onSubscribe(NimBLECharacteristic* pChar, NimBLEConnInfo& connInfo, uint16_t subValue) override {
    (void)pChar; (void)connInfo;
    s_ble_subscribed = (subValue != 0);
  }
};

/// `caps_json` is the capability list for the Device Info characteristic
/// (a JSON array), true to what this board handles.
static void ble_link_init(const char* board_name, const char* caps_json) {
  if (s_ble_server) return;   // once
  s_ble_rx_line = (char*)ext_calloc(BLE_LINE_MAX);
  // Commands arrive in bursts (a TFR push is 16 lines of ~1 KB) while the
  // loop may be inside a 1.5 s e-paper refresh; boards without PSRAM get
  // less and drop what does not fit (counted in the heartbeat).
  s_ble_rx_rb   = ext_ring(24576, 6144);
  s_ble_ctl_q   = { ble_ring_send, ext_ring(16384, 4096), false, 0, 0 };
  s_ble_feed_q  = { ble_ring_send, ext_ring(8192, 3072), false, 0, 0 };
  s_ble_rx_deliver = ble_rx_ring_deliver;
  s_ble_tx_kick = ble_tx_kick;

  uint8_t mac[6];
  esp_read_mac(mac, ESP_MAC_BT);
  char adv_name[32];
  snprintf(adv_name, sizeof(adv_name), "Orecchino-%02X%02X", mac[4], mac[5]);

  NimBLEDevice::init(adv_name);
  NimBLEDevice::setDeviceName(adv_name);
  NimBLEDevice::setMTU(517);

  // Security: LE Secure Connections with bonding, MITM protection by the
  // fixed passkey (every board, with a screen or not: see the top of this
  // file). The MITM request alone is advisory (BLE_SM_LVL is 0), so the
  // attributes themselves demand an authenticated link, and
  // onAuthenticationComplete refuses a pairing that did not use the code.
  NimBLEDevice::setSecurityAuth(true, true, true);
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_DISPLAY_ONLY);
  ble_gatts_set_clt_cfg_perm_flags(BLE_ATT_F_READ | BLE_ATT_F_WRITE | BLE_ATT_F_WRITE_ENC | BLE_ATT_F_WRITE_AUTHEN);

  s_ble_server = NimBLEDevice::createServer();
  s_ble_server->setCallbacks(new OrecchinoServerCallbacks());
  static NusCallbacks nus_cb;

  // 1. Nordic UART Service
  NimBLEService* nus = s_ble_server->createService(BLE_NUS_SVC_UUID);
  s_ble_tx_char = nus->createCharacteristic(BLE_NUS_TX_UUID, NIMBLE_PROPERTY::NOTIFY);
  s_ble_tx_char->setCallbacks(&nus_cb);

  NimBLECharacteristic* rx_char = nus->createCharacteristic(
    BLE_NUS_RX_UUID,
    NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR | NIMBLE_PROPERTY::WRITE_ENC | NIMBLE_PROPERTY::WRITE_AUTHEN
  );
  rx_char->setCallbacks(&nus_cb);

  // 2. Orecchino Info Service: readable before pairing, so a phone can tell
  // an Orecchino from any other NUS device first.
  NimBLEService* info = s_ble_server->createService(BLE_INFO_SVC_UUID);
  NimBLECharacteristic* dev_info = info->createCharacteristic(
    BLE_INFO_CHR_UUID,
    NIMBLE_PROPERTY::READ
  );
  char info_json[220];
  snprintf(info_json, sizeof(info_json),
           "{\"fw\":\"orecchino\",\"ver\":\"" FW_VERSION "\",\"board\":\"%s\",\"caps\":%s,\"proto\":1}",
           board_name, caps_json);
  dev_info->setValue((uint8_t*)info_json, strlen(info_json));
  s_ble_server->start();   // registers both services: before any GAP procedure

  // Advertising
#if CONFIG_BT_NIMBLE_EXT_ADV
  NimBLEExtAdvertisement advData;
  advData.setLegacyAdvertising(true);
  advData.setConnectable(true);
  advData.setScannable(true);
  // Legacy advertising carries 31 bytes: flags + the 128-bit NUS UUID is
  // 21, so the name goes in the scan response.
  advData.addServiceUUID(BLE_NUS_SVC_UUID);
  advData.setMinInterval(800); // 500 ms (800 * 0.625)
  advData.setMaxInterval(800);
  NimBLEExtAdvertisement scanResp;
  scanResp.setLegacyAdvertising(true);
  scanResp.setName(adv_name);
  NimBLEDevice::getAdvertising()->setInstanceData(0, advData);
  NimBLEDevice::getAdvertising()->setScanResponseData(0, scanResp);
  NimBLEDevice::getAdvertising()->start(0);
#else
  NimBLEAdvertising* pAdv = NimBLEDevice::getAdvertising();
  pAdv->setName(adv_name);
  pAdv->addServiceUUID(BLE_NUS_SVC_UUID);
  pAdv->setMinInterval(800); // 500 ms (800 * 0.625)
  pAdv->setMaxInterval(800);
  pAdv->start();
#endif

  // Register with host link
  host_link_add_sink(ble_sink_enqueue, &s_ble_ctl_q);

  // Drain task: sleeps on its notification, so an idle link costs nothing.
  xTaskCreate(ble_notify_task, "ble_tx", 3072, nullptr, 2, &s_ble_tx_task);
}

/// From the loop: run queued command lines, drop a peer that never paired,
/// and pick the connection parameters.
static void ble_link_poll(uint32_t now) {
  if (!s_ble_rx_rb) return;
  for (int k = 0; k < 32; k++) {
    size_t n = 0;
    char* item = (char*)xRingbufferReceive(s_ble_rx_rb, &n, 0);
    if (!item) break;
    handle_host_line(item, now, SRC_BLE_BONDED);   // item is NUL-terminated
    vRingbufferReturnItem(s_ble_rx_rb, item);
  }
  if (!s_ble_connected) return;
  uint16_t conn = s_ble_conn_id;
  if (!ble_link_secure()) {
    if (ble_pair_overdue(now) && s_ble_server) s_ble_server->disconnect(conn);
    return;
  }
  bool busy = ble_link_busy(now);
  if (busy != s_ble_fast) ble_conn_params(conn, busy);
}

#else
// ============================================================================
// Host tests: the same link on a fake radio. Lines to the peer land in
// s_mock_tx_lines the moment their ring takes them; received bytes go
// through ble_rx_bytes into a queue that waits for ble_link_poll() (rx_tick),
// exactly as the rings on the device.
// ============================================================================
#include <deque>
#include <string>
#include <vector>

static std::vector<std::string> s_mock_tx_lines;
static std::deque<std::string> s_mock_rx_q;

static void mock_ble_deliver(const uint8_t* line, size_t n) { s_mock_tx_lines.emplace_back((const char*)line, n); }
static HostMockRing s_mock_ctl_ring  = { false, 0, SIZE_MAX, mock_ble_deliver };
static HostMockRing s_mock_feed_ring = { false, 0, SIZE_MAX, mock_ble_deliver };
static bool mock_ble_rx_deliver(const char* line, size_t n) {
  (void)n;
  s_mock_rx_q.emplace_back(line);
  return true;
}

static inline void ble_link_init(const char*, const char*) {
  if (!s_ble_rx_line) s_ble_rx_line = (char*)ext_calloc(BLE_LINE_MAX);
  s_ble_ctl_q  = { host_mock_send, &s_mock_ctl_ring, false, 0, 0 };
  s_ble_feed_q = { host_mock_send, &s_mock_feed_ring, false, 0, 0 };
  s_ble_rx_deliver = mock_ble_rx_deliver;
  host_link_add_sink(ble_sink_enqueue, &s_ble_ctl_q);
}

static inline void ble_link_poll(uint32_t now) {
  while (!s_mock_rx_q.empty()) {
    std::string l = s_mock_rx_q.front();
    s_mock_rx_q.pop_front();
    handle_host_line(&l[0], now, SRC_BLE_BONDED);
  }
  if (ble_pair_overdue(now)) ble_link_on_disconnect();   // what the device's disconnect ends in
}

// Test inspection hooks
static inline void ble_link_test_set_connected(bool conn, uint32_t now = 0) {
  if (conn) ble_link_on_connect(now, false, false);
  else ble_link_on_disconnect();
}
static inline void ble_link_test_set_subscribed(bool sub) { s_ble_subscribed = sub; }
/// Paired with the passkey: encrypted and authenticated, as
/// onAuthenticationComplete leaves a good pairing.
static inline void ble_link_test_set_encrypted(bool enc) { s_ble_encrypted = enc; s_ble_authenticated = enc; }
/// A Just Works pairing: encrypted, never authenticated.
static inline void ble_link_test_set_just_works() { s_ble_encrypted = true; s_ble_authenticated = false; }
/// Feed lines the "radio" will still take (SIZE_MAX: every one).
static inline void ble_link_test_set_feed_room(size_t n) { s_mock_feed_ring.room = n; }
/// The reply ring refuses the k-th line from now (full for a moment).
static inline void ble_link_test_ctl_fail_at(int k) { s_mock_ctl_ring.fail_at = k; }
/// The peer stopped reading: the reply ring refuses everything.
static inline void ble_link_test_ctl_dead(bool dead) { s_mock_ctl_ring.dead = dead; }
static inline const std::vector<std::string>& ble_link_test_get_tx() { return s_mock_tx_lines; }
static inline void ble_link_test_clear_tx() { s_mock_tx_lines.clear(); }
static inline bool ble_link_test_connected() { return s_ble_connected; }

/// Bytes as the RX characteristic would receive them from the peer, with
/// the link in the state the test put it; complete lines are queued, not
/// handled, until the next ble_link_poll().
static inline void ble_link_test_inject_rx(const char* data, size_t len) {
  ble_rx_bytes((const uint8_t*)data, len, ble_link_secure());
}
#endif
