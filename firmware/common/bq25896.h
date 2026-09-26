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
constexpr uint8_t REG_IINLIM = 0x00,     // bits 5:0: input limit, 100 mA + 50 mA steps
                  REG_ICHG = 0x04,       // bits 6:0: 64 mA steps; bit 7 EN_PUMPX
                  REG_VREG = 0x06,       // bits 7:2: termination voltage, 3840 mV + 16 mV steps
                  REG_TIMER = 0x07,      // bits 5:4 WATCHDOG (00 off, 01 40 s, 10 80 s, 11 160 s)
                  REG_STATUS = 0x0B,     // bits 4:3 CHRG_STAT
                  REG_PART = 0x14;       // bits 5:3 PN, bits 1:0 DEV_REV
constexpr uint8_t ICHG_MASK = 0x7F, WATCHDOG_MASK = 0x30;
constexpr int ICHG_STEP_MA = 64, ICHG_MAX_MA = 3008;
}  // namespace detail

// A BQ25896 answering at kAddr, not another part at the same address:
// REG14's PN (bits 5:3) is 000 and its DEV_REV (bits 1:0) 10, as the T5's
// chip reads (0x46). Nothing is written to a chip that fails this.
inline bool identify(const Io& io) {
  uint8_t v;
  return io.read(detail::REG_PART, &v) && ((v >> 3) & 7) == 0 && (v & 3) == 2;
}

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
// already holds the value, so calling it again later (the boards do, every
// minute, in case the chip lost its registers) costs only reads. False,
// writing nothing, when identify() fails. True once both read back as asked.
inline bool set_charge_current(const Io& io, int ma) {
  using namespace detail;
  if (!identify(io)) return false;
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

// A charge as the chip sees it: where it is (CHRG_STAT), the fast-charge
// current, the termination voltage and the input limit it works to.
struct State {
  const char* charging;   // "not_charging", "pre_charge", "fast" or "done"
  int ichg_ma, vreg_mv, iinlim_ma;
  int part;               // REG14 raw (PN, DEV_REV)
};
// False when the chip does not answer.
inline bool state(const Io& io, State* s) {
  using namespace detail;
  static const char* const kStat[] = { "not_charging", "pre_charge", "fast", "done" };
  uint8_t in, vr, st, pn;
  int ichg = charge_current_ma(io);
  if (ichg < 0 || !io.read(REG_IINLIM, &in) || !io.read(REG_VREG, &vr) || !io.read(REG_STATUS, &st) ||
      !io.read(REG_PART, &pn))
    return false;
  s->part = pn;
  s->charging = kStat[(st >> 3) & 3];
  s->ichg_ma = ichg;
  s->vreg_mv = 3840 + ((vr >> 2) & 0x3F) * 16;
  s->iinlim_ma = 100 + (in & 0x3F) * 50;
  return true;
}

}  // namespace bq25896
