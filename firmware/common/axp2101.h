// X-Powers AXP2101 PMU (the Waveshare C6 AMOLED board): the battery
// percentage from its built-in fuel gauge. The percentage register only
// means something with battery detection and the gauge switched on and a
// battery actually present; begin() switches them on, batt_pct() checks
// presence. Register facts from XPowersLib (MIT) and Waveshare's board
// example. Header-only and transport-agnostic, so tests/gauge_test.cpp
// runs it against a simulated register file.
#pragma once
#include <stdint.h>

namespace axp2101 {

constexpr uint8_t kAddr = 0x34;

// Single-register access; false on any bus error.
struct Io {
  bool (*read)(uint8_t reg, uint8_t* v);
  bool (*write)(uint8_t reg, uint8_t v);
};

namespace detail {
constexpr uint8_t REG_STATUS1 = 0x00,      // bit 3: battery present
                  REG_GAUGE_CTRL = 0x18,   // bit 3: fuel gauge on
                  REG_ADC_CTRL = 0x30,     // bit 0: battery-voltage ADC on
                  REG_BAT_DETECT = 0x68,   // bit 0: battery detection on
                  REG_BAT_PERCENT = 0xA4;  // 0..100
inline bool set_bits(const Io& io, uint8_t reg, uint8_t bits) {
  uint8_t v;
  if (!io.read(reg, &v)) return false;
  if ((v & bits) == bits) return true;
  return io.write(reg, (uint8_t)(v | bits));
}
}  // namespace detail

// Switch on battery detection, the fuel gauge and the battery-voltage ADC
// the gauge reads. Each is one bit set by read-modify-write; the PMU's
// other settings (rails, charger) are left as the board configured them.
inline bool begin(const Io& io) {
  using namespace detail;
  bool ok = set_bits(io, REG_BAT_DETECT, 0x01);
  ok = set_bits(io, REG_GAUGE_CTRL, 0x08) && ok;
  ok = set_bits(io, REG_ADC_CTRL, 0x01) && ok;
  return ok;
}

// Percent 0..100; -1 with no battery, no answer, or an out-of-range value.
inline int batt_pct(const Io& io) {
  using namespace detail;
  uint8_t status, pct;
  if (!io.read(REG_STATUS1, &status) || !(status & 0x08)) return -1;
  if (!io.read(REG_BAT_PERCENT, &pct) || pct > 100) return -1;
  return pct;
}

}  // namespace axp2101
