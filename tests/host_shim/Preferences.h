#pragma once
#include "Arduino.h"
#include <map>
#include <string>
#include <vector>
// In-memory NVS: one store for the whole test run, keyed "namespace/key".
inline std::map<std::string, std::vector<uint8_t>>& shim_nvs() {
  static std::map<std::string, std::vector<uint8_t>> m; return m;
}
class Preferences {
  std::string ns;
  std::string k(const char* key) const { return ns + "/" + key; }
  template <typename T> T get(const char* key, T d) const {
    auto it = shim_nvs().find(k(key));
    if (it == shim_nvs().end() || it->second.size() != sizeof(T)) return d;
    T v; memcpy(&v, it->second.data(), sizeof(T)); return v;
  }
  template <typename T> void put(const char* key, T v) {
    shim_nvs()[k(key)] = std::vector<uint8_t>((const uint8_t*)&v, (const uint8_t*)&v + sizeof(T));
  }
 public:
  bool begin(const char* n, bool = false) { ns = n; return true; } void end() {}
  uint16_t getUShort(const char* key, uint16_t d = 0) { return get(key, d); } void putUShort(const char* key, uint16_t v) { put(key, v); }
  uint8_t getUChar(const char* key, uint8_t d = 0) { return get(key, d); } void putUChar(const char* key, uint8_t v) { put(key, v); }
  uint32_t getULong(const char* key, uint32_t d = 0) { return get(key, d); } void putULong(const char* key, uint32_t v) { put(key, v); }
  size_t getBytesLength(const char* key) { auto it = shim_nvs().find(k(key)); return it == shim_nvs().end() ? 0 : it->second.size(); }
  size_t getBytes(const char* key, void* buf, size_t n) {
    auto it = shim_nvs().find(k(key)); if (it == shim_nvs().end()) return 0;
    size_t c = std::min(n, it->second.size()); memcpy(buf, it->second.data(), c); return c;
  }
  size_t putBytes(const char* key, const void* buf, size_t n) {
    shim_nvs()[k(key)] = std::vector<uint8_t>((const uint8_t*)buf, (const uint8_t*)buf + n); return n;
  }
};
