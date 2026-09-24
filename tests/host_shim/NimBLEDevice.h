#pragma once
#include "Arduino.h"
#include "sdkconfig.h"
#define BLE_ADDR_PUBLIC 0
#define BLE_ADDR_RANDOM 1
#define BLE_HCI_LE_PHY_1M 1
#define BLE_HCI_LE_PHY_2M 2
#define BLE_HCI_LE_PHY_CODED 3
class NimBLEAddress { public: uint8_t v[6] = {0}; uint8_t type = 0; NimBLEAddress() {} NimBLEAddress(const uint8_t* b, uint8_t t) { memcpy(v, b, 6); type = t; } const uint8_t* getVal() const { return v; } };
class NimBLEExtAdvertisement { public:
  NimBLEExtAdvertisement(uint8_t p = 1, uint8_t s = 1) : pri(p), sec(s) {}
  void setConnectable(bool) {} void setScannable(bool) {}
  void setMinInterval(uint32_t v) { itvl = v; } void setMaxInterval(uint32_t v) { itvl_max = v; }
  void setTxPower(int8_t d) { tx_power = d; }
  void setAddress(const NimBLEAddress& a) { addr = a; }
  void setLegacyAdvertising(bool b) { legacy = b; }
  void setData(const uint8_t* d, size_t n) { data.assign(d, d + n); }
  uint8_t pri, sec; bool legacy = false; NimBLEAddress addr; std::vector<uint8_t> data;
  uint32_t itvl = 0, itvl_max = 0; int8_t tx_power = 127; };

// Advertising sets as NimBLE and the ESP controller behave: a running set
// cannot be reconfigured (EBUSY), stop() for all sets refuses while any set
// runs (ble_gap_ext_adv_clear), a running set's data can be replaced in
// place (ble_gap_ext_adv_set_data), and the controller grants `max_sets`.
// Every start, stop and data swap is logged with the time, so a test can
// replay the advertising events that went on air.
struct AdvStartRec { uint8_t inst; NimBLEExtAdvertisement adv; uint32_t at; };
struct AdvLogRec { uint32_t at; uint8_t inst; char kind; NimBLEExtAdvertisement adv; };  // kind: S start, X stop, D data
class NimBLEExtAdvertising { public:
  static const int N = 4;
  int max_sets = 3;
  bool active[N] = {false, false, false, false}, configured[N] = {false, false, false, false};
  bool fail_set_data = false;
  NimBLEExtAdvertisement inst_data[N]; std::vector<AdvStartRec> starts; std::vector<AdvLogRec> log;
  int stop_all_calls = 0, stop_inst_calls[N] = {0, 0, 0, 0};
  bool setInstanceData(uint8_t i, NimBLEExtAdvertisement& a) {
    if (i >= max_sets || active[i]) return false;
    inst_data[i] = a; configured[i] = true; return true; }
  bool start(uint8_t i, int = 0, int max_events = 0) {
    if (i >= max_sets || !configured[i]) return false;
    active[i] = true; starts.push_back({i, inst_data[i], g_millis});
    if (max_events == 0) log.push_back({g_millis, i, 'S', inst_data[i]});
    return true; }
  bool stop(uint8_t i) {
    if (i >= max_sets) return false;
    stop_inst_calls[i]++; if (active[i]) log.push_back({g_millis, i, 'X', inst_data[i]});
    active[i] = false; return true; }
  bool stop() {   // ble_gap_ext_adv_clear: EBUSY while any set is advertising
    stop_all_calls++;
    for (int i = 0; i < N; i++) if (active[i]) return false;
    return true; }
  bool isActive(uint8_t i) { return active[i]; }
  bool isAdvertising() { for (int i = 0; i < N; i++) if (active[i]) return true; return false; }
  void reset(int sets) { *this = NimBLEExtAdvertising(); max_sets = sets; } };

struct os_mbuf { std::vector<uint8_t> d; };
static inline struct os_mbuf* ble_hs_mbuf_from_flat(const void* buf, uint16_t len) {
  os_mbuf* m = new os_mbuf; m->d.assign((const uint8_t*)buf, (const uint8_t*)buf + len); return m; }

class NimBLEAdvertisedDevice { public: NimBLEAddress a; int rssi = -50; uint8_t pphy = 1, sphy = 0; std::vector<uint8_t> payload;
  const NimBLEAddress& getAddress() const { return a; } int getRSSI() const { return rssi; }
  uint8_t getPrimaryPhy() const { return pphy; } uint8_t getSecondaryPhy() const { return sphy; }
  const std::vector<uint8_t>& getPayload() const { return payload; } };
class NimBLEScanResults {};
class NimBLEScanCallbacks { public: virtual ~NimBLEScanCallbacks() {} virtual void onResult(const NimBLEAdvertisedDevice*) {} virtual void onScanEnd(const NimBLEScanResults&, int) {} };
class NimBLEScan { public: NimBLEScanCallbacks* cb = nullptr; bool running = false;
  void setScanCallbacks(NimBLEScanCallbacks* c, bool) { cb = c; } void setActiveScan(bool) {} void setDuplicateFilter(int) {} void setMaxResults(int) {} void setInterval(int) {} void setWindow(int) {}
  bool start(int, bool, bool) { running = true; return true; } bool stop() { running = false; return true; } };
class NimBLEDevice { public: static NimBLEExtAdvertising adv; static NimBLEScan scan;
  static bool init(const char*) { return true; } static void setPower(int) {}
  static NimBLEExtAdvertising* getAdvertising() { return &adv; } static NimBLEScan* getScan() { return &scan; } };

// ble_gap_ext_adv_set_data: new data for a configured set, running or not
// (legacy sets: 31 bytes at most). Consumes the mbuf, as NimBLE does.
static inline int ble_gap_ext_adv_set_data(uint8_t i, struct os_mbuf* m) {
  NimBLEExtAdvertising& a = NimBLEDevice::adv;
  int rc = 0;
  if (i >= a.max_sets || !a.configured[i] || a.fail_set_data) rc = 3;
  else if (a.inst_data[i].legacy && m->d.size() > 31) rc = 3;
  else {
    a.inst_data[i].data = m->d;
    if (a.active[i]) a.log.push_back({g_millis, i, 'D', a.inst_data[i]});
  }
  delete m;
  return rc;
}
