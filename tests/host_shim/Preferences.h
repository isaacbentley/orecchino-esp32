#pragma once
#include "Arduino.h"
class Preferences { public:
  bool begin(const char*, bool = false) { return true; } void end() {}
  uint16_t getUShort(const char*, uint16_t d = 0) { return d; } void putUShort(const char*, uint16_t) {}
  uint8_t getUChar(const char*, uint8_t d = 0) { return d; } void putUChar(const char*, uint8_t) {} };
