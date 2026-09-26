// TI BQ25896 charger (the T5 E-Paper S3 Pro): its fast-charge current.
// At power-on it charges at 2048 mA, sized for a far bigger cell than the
// T5's 1500 mAh one. set_charge_current() sets the host's value, and first
// switches the I2C watchdog off: in host mode, a watchdog that expires
// (40 s by default without a WD_RST) returns every register to its
// power-on value, so a current written once would be lost a minute later.
// Register facts: TI's BQ25896 datasheet (SLUSC76), REG04 ICHG and REG07
// WATCHDOG. Header-only and transport-agnostic, so tests/gauge_test.cpp
// runs it against a simulated register file.
#pragma once
#include <stdint.h>

namespace bq25896 {

constexpr uint8_t kAddr = 0x6B;

// Single-register access; false on any bus error.
struct Io {
  bool (*read)(uint8_t reg, uint8_t* v);
  bool (*write)(uint8_t reg, uint8_t v);
};

namespace detail {
constexpr uint8_t REG_ICHG = 0x04,       // bits 6:0: 64 mA steps; bit 7 EN_PUMPX
                  REG_TIMER = 0x07;      // bits 5:4 WATCHDOG (00 off, 01 40 s, 10 80 s, 11 160 s)
constexpr uint8_t ICHG_MASK = 0x7F, WATCHDOG_MASK = 0x30;
constexpr int ICHG_STEP_MA = 64, ICHG_MAX_MA = 3008;
}  // namespace detail

// The fast-charge current the chip is set to, mA (a code past 3008 mA
// charges at 3008); -1 when it does not answer.
inline int charge_current_ma(const Io& io) {
  uint8_t v;
  if (!io.read(detail::REG_ICHG, &v)) return -1;
  int ma = (v & detail::ICHG_MASK) * detail::ICHG_STEP_MA;
  return ma > detail::ICHG_MAX_MA ? detail::ICHG_MAX_MA : ma;
}

// Set the fast-charge current to the step at or below `ma` (the chip's
// steps are 64 mA; at most 3008 mA), watchdog off first. Each register is
// read-modify-write, so their other bits (EN_PUMPX, termination, the
// safety timer) stay as they are, and nothing is written when the chip
// already holds the value. True once both read back as asked.
inline bool set_charge_current(const Io& io, int ma) {
  using namespace detail;
  if (ma < 0) ma = 0;
  if (ma > ICHG_MAX_MA) ma = ICHG_MAX_MA;
  uint8_t t, c;
  if (!io.read(REG_TIMER, &t)) return false;
  if ((t & WATCHDOG_MASK) && !io.write(REG_TIMER, (uint8_t)(t & ~WATCHDOG_MASK))) return false;
  if (!io.read(REG_ICHG, &c)) return false;
  uint8_t want = (uint8_t)((c & ~ICHG_MASK) | (ma / ICHG_STEP_MA));
  if (c != want && !io.write(REG_ICHG, want)) return false;
  return io.read(REG_TIMER, &t) && !(t & WATCHDOG_MASK) && io.read(REG_ICHG, &c) && c == want;
}

}  // namespace bq25896
