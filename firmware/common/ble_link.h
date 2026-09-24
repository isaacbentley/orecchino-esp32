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
// log records (never dropped; their producer waits for room instead) ahead
// of the live feed (rid, hb), which is dropped when the phone cannot keep up.
//
// Security. The passkey is the fixed, public 123456 (a deliberate choice:
// the link protects against passers-by, not a determined attacker). Nothing
// flows to a peer until its link is encrypted, subscribing needs encryption
// too, and a peer that has not paired within BLE_PAIR_DEADLINE_MS is dropped
// so it cannot sit on the only connection slot.
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
static RingbufHandle_t         s_ble_ctl_rb = nullptr;   // replies and log records, to the peer
static RingbufHandle_t         s_ble_feed_rb = nullptr;  // rid / hb lines, to the peer
static TaskHandle_t            s_ble_tx_task = nullptr;
static NimBLEServer*           s_ble_server = nullptr;
static NimBLECharacteristic*   s_ble_tx_char = nullptr;
static volatile bool           s_ble_connected = false;
static volatile bool           s_ble_subscribed = false;
static volatile bool           s_ble_encrypted = false;
static volatile uint16_t       s_ble_conn_id = BLE_HS_CONN_HANDLE_NONE;
static volatile uint32_t       s_ble_conn_ms = 0;        // when the peer connected
static volatile uint32_t       s_ble_active_ms = 0;      // last command in or reply out
static volatile uint16_t       s_ble_itvl_ms = 50;       // current connection interval
static volatile bool           s_ble_fast = true;        // fast connection parameters asked for
static volatile bool           s_ble_ctl_stalled = false;
static volatile uint32_t       s_ble_drops = 0;          // outgoing lines dropped
static volatile uint32_t       s_ble_rx_drops = 0;       // incoming lines dropped (ring full, too long)
// Line assembly for RX writes: touched only on the NimBLE host task.
static char*                   s_ble_rx_line = nullptr;
static int                     s_ble_rx_len = 0;
static bool                    s_ble_rx_overlong = false;

// Weak hook for pairing display on boards with a screen. Called on the
// NimBLE host task: set a flag and draw from the loop.
extern "C" __attribute__((weak)) void rx_hook_pairing(uint32_t passkey, bool show);

static inline bool ble_link_ready() {
  return s_ble_connected && s_ble_subscribed && s_ble_encrypted;
}

static void ble_sink_enqueue(const uint8_t* line, size_t n, bool feed) {
  if (!ble_link_ready() || !s_ble_ctl_rb || n == 0) return;
  if (feed) {
    // The live feed is the only thing dropped: a newer frame replaces it.
    if (xRingbufferSend(s_ble_feed_rb, line, n, 0) != pdTRUE) s_ble_drops += 1;
  } else {
    // Replies and log records wait for room (the producer is the loop).
    // A peer that stops reading must not stall the loop line after line:
    // after one timeout the rest go without waiting until one fits again.
    TickType_t wait = s_ble_ctl_stalled ? 0 : pdMS_TO_TICKS(1000);
    if (xRingbufferSend(s_ble_ctl_rb, line, n, wait) == pdTRUE) {
      s_ble_ctl_stalled = false;
      s_ble_active_ms = millis();
    } else {
      s_ble_ctl_stalled = true;
      s_ble_drops += 1;
    }
  }
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
        s_ble_drops += 1;
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
      RingbufHandle_t rb = s_ble_ctl_rb;
      size_t n = 0;
      uint8_t* item = (uint8_t*)xRingbufferReceive(rb, &n, 0);
      if (!item) { rb = s_ble_feed_rb; item = (uint8_t*)xRingbufferReceive(rb, &n, 0); }
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

class OrecchinoServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo) override {
    (void)pServer;
    s_ble_rx_len = 0;
    s_ble_rx_overlong = false;
    s_ble_encrypted = connInfo.isEncrypted();
    s_ble_conn_id = connInfo.getConnHandle();
    s_ble_conn_ms = millis();
    s_ble_active_ms = s_ble_conn_ms;
    s_ble_connected = true;
    ble_conn_params(connInfo.getConnHandle(), true);
    ble_stop_adv();
    // Ask for pairing now rather than when the peer first touches an
    // encrypted attribute, so the pairing deadline is fair.
    NimBLEDevice::startSecurity(connInfo.getConnHandle());
  }

  void onDisconnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo, int reason) override {
    (void)pServer; (void)connInfo; (void)reason;
    s_ble_connected = false;
    s_ble_subscribed = false;
    s_ble_encrypted = false;
    s_ble_conn_id = BLE_HS_CONN_HANDLE_NONE;
    s_ble_rx_len = 0;                        // a half-written command dies with the link
    s_ble_rx_overlong = false;
    s_ble_ctl_stalled = false;
    host_set_feed(SRC_BLE_BONDED, false);   // the next peer asks for itself
    if (s_ble_tx_task) xTaskNotifyGive(s_ble_tx_task);   // flush what was queued
    if (rx_hook_pairing) rx_hook_pairing(0, false);
    ble_start_adv();
  }

  uint32_t onPassKeyDisplay() override {
    if (rx_hook_pairing) rx_hook_pairing(BLE_PASSKEY, true);
    return BLE_PASSKEY;
  }

  void onAuthenticationComplete(NimBLEConnInfo& connInfo) override {
    if (rx_hook_pairing) rx_hook_pairing(0, false);
    if (!connInfo.isEncrypted()) {
      NimBLEDevice::getServer()->disconnect(connInfo.getConnHandle());
      return;
    }
    s_ble_encrypted = true;
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
    if (!connInfo.isEncrypted() || !s_ble_rx_line) return;   // WRITE_ENC should already stop it
    NimBLEAttValue val = pChar->getValue();
    for (size_t i = 0; i < val.length(); i++) {
      char c = (char)val[i];
      if (c == '\n' || c == '\r') {
        if (s_ble_rx_overlong) {
          s_ble_rx_drops += 1;
        } else if (s_ble_rx_len > 0) {
          s_ble_rx_line[s_ble_rx_len] = 0;
          if (xRingbufferSend(s_ble_rx_rb, s_ble_rx_line, s_ble_rx_len + 1, 0) != pdTRUE)
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
  s_ble_ctl_rb  = ext_ring(16384, 4096);
  s_ble_feed_rb = ext_ring(8192, 3072);

  uint8_t mac[6];
  esp_read_mac(mac, ESP_MAC_BT);
  char adv_name[32];
  snprintf(adv_name, sizeof(adv_name), "Orecchino-%02X%02X", mac[4], mac[5]);

  NimBLEDevice::init(adv_name);
  NimBLEDevice::setDeviceName(adv_name);
  NimBLEDevice::setMTU(517);

  // Security: LE Secure Connections with bonding, MITM protection by the
  // fixed passkey (every board, with a screen or not: see the top of this file).
  NimBLEDevice::setSecurityAuth(true, true, true);
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_DISPLAY_ONLY);
  ble_gatts_set_clt_cfg_perm_flags(BLE_ATT_F_READ | BLE_ATT_F_WRITE | BLE_ATT_F_WRITE_ENC);

  s_ble_server = NimBLEDevice::createServer();
  s_ble_server->setCallbacks(new OrecchinoServerCallbacks());
  static NusCallbacks nus_cb;

  // 1. Nordic UART Service
  NimBLEService* nus = s_ble_server->createService(BLE_NUS_SVC_UUID);
  s_ble_tx_char = nus->createCharacteristic(BLE_NUS_TX_UUID, NIMBLE_PROPERTY::NOTIFY);
  s_ble_tx_char->setCallbacks(&nus_cb);

  NimBLECharacteristic* rx_char = nus->createCharacteristic(
    BLE_NUS_RX_UUID,
    NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR | NIMBLE_PROPERTY::WRITE_ENC
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
  host_link_add_sink(ble_sink_enqueue);

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
  if (!s_ble_encrypted) {
    if ((int32_t)(now - s_ble_conn_ms) > BLE_PAIR_DEADLINE_MS && s_ble_server)
      s_ble_server->disconnect(conn);
    return;
  }
  bool busy = s_feed_ble || (int32_t)(now - s_ble_active_ms) < BLE_IDLE_MS;
  if (busy != s_ble_fast) ble_conn_params(conn, busy);
}

static inline bool ble_link_connected() { return s_ble_connected; }
/// A phone is connected on an encrypted (paired) link: the T5 pauses its
/// own Wi-Fi syncs while this holds (net_sync.h).
static inline bool ble_link_peer_secure() { return s_ble_connected && s_ble_encrypted; }
static inline uint32_t ble_link_drops() { return s_ble_drops; }
static inline uint32_t ble_link_rx_drops() { return s_ble_rx_drops; }

#else
// ============================================================================
// Host Shim / Mock BLE Transport for host tests. Same contract as the
// device: lines reach the peer only while connected, subscribed and
// encrypted; received lines wait for ble_link_poll() (rx_tick); a full feed
// queue drops feed lines only.
// ============================================================================
#include <deque>
#include <string>
#include <vector>

static bool s_mock_connected = false;
static bool s_mock_subscribed = false;
static bool s_mock_encrypted = false;
static uint32_t s_mock_drops = 0;
static size_t s_mock_feed_room = SIZE_MAX;   // feed lines the "radio" will still take
static std::vector<std::string> s_mock_tx_lines;
static std::deque<std::string> s_mock_rx_q;
static std::string s_mock_rx_buf;

static void mock_ble_sink(const uint8_t* line, size_t n, bool feed) {
  if (!s_mock_connected || !s_mock_subscribed || !s_mock_encrypted || n == 0) return;
  if (feed) {
    if (s_mock_feed_room == 0) { s_mock_drops++; return; }
    if (s_mock_feed_room != SIZE_MAX) s_mock_feed_room--;
  }
  s_mock_tx_lines.emplace_back((const char*)line, n);
}

static inline void ble_link_init(const char*, const char*) {
  host_link_add_sink(mock_ble_sink);
}

static inline void ble_link_poll(uint32_t now) {
  while (!s_mock_rx_q.empty()) {
    std::string l = s_mock_rx_q.front();
    s_mock_rx_q.pop_front();
    handle_host_line(&l[0], now, SRC_BLE_BONDED);
  }
}

static inline bool ble_link_connected() { return s_mock_connected; }
static inline bool ble_link_peer_secure() { return s_mock_connected && s_mock_encrypted; }
static inline uint32_t ble_link_drops() { return s_mock_drops; }
static inline uint32_t ble_link_rx_drops() { return 0; }

// Test inspection hooks
static inline void ble_link_test_set_connected(bool conn) {
  s_mock_connected = conn;
  if (!conn) {   // what onDisconnect does
    s_mock_subscribed = false;
    s_mock_encrypted = false;
    s_mock_rx_buf.clear();
    host_set_feed(SRC_BLE_BONDED, false);
  }
}
static inline void ble_link_test_set_subscribed(bool sub) { s_mock_subscribed = sub; }
static inline void ble_link_test_set_encrypted(bool enc) { s_mock_encrypted = enc; }
static inline void ble_link_test_set_feed_room(size_t n) { s_mock_feed_room = n; }
static inline const std::vector<std::string>& ble_link_test_get_tx() { return s_mock_tx_lines; }
static inline void ble_link_test_clear_tx() { s_mock_tx_lines.clear(); }

/// Bytes as the RX characteristic would receive them; complete lines are
/// queued, not handled, until the next ble_link_poll().
static inline void ble_link_test_inject_rx(const char* data, size_t len) {
  for (size_t i = 0; i < len; i++) {
    char c = data[i];
    if (c == '\n' || c == '\r') {
      if (!s_mock_rx_buf.empty() && s_mock_rx_buf.size() < BLE_LINE_MAX) s_mock_rx_q.push_back(s_mock_rx_buf);
      s_mock_rx_buf.clear();
    } else {
      s_mock_rx_buf += c;
    }
  }
}
#endif
