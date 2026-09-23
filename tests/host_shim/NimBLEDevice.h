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
  void setMinInterval(uint32_t) {} void setMaxInterval(uint32_t) {}
  void setAddress(const NimBLEAddress& a) { addr = a; }
  void setLegacyAdvertising(bool b) { legacy = b; }
  void setData(const uint8_t* d, size_t n) { data.assign(d, d + n); }
  uint8_t pri, sec; bool legacy = false; NimBLEAddress addr; std::vector<uint8_t> data; };
struct AdvStartRec { uint8_t inst; NimBLEExtAdvertisement adv; uint32_t at; };
class NimBLEExtAdvertising { public:
  bool active[2] = {false, false}; NimBLEExtAdvertisement inst_data[2]; std::vector<AdvStartRec> starts;
  int stop_all_calls = 0, stop_inst_calls[2] = {0, 0};
  bool setInstanceData(uint8_t i, NimBLEExtAdvertisement& a) { inst_data[i] = a; return true; }
  bool start(uint8_t i, int = 0, int = 0) { active[i] = true; starts.push_back({i, inst_data[i], g_millis}); return true; }
  bool stop(uint8_t i) { stop_inst_calls[i]++; active[i] = false; return true; }
  bool stop() { stop_all_calls++; active[0] = active[1] = false; return true; }
  bool isActive(uint8_t i) { return active[i]; }
  bool isAdvertising() { return active[0] || active[1]; } };
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
  static void init(const char*) {} static void setPower(int) {}
  static NimBLEExtAdvertising* getAdvertising() { return &adv; } static NimBLEScan* getScan() { return &scan; } };
