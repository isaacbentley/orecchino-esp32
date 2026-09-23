// TI BQ27220 fuel gauge (the T5 E-Paper S3 Pro and the T-Embed CC1101):
// read-out, plus the configuration check every boot needs.
//
// The gauge counts charge in and out and reports it against the capacity
// and discharge profile in its data memory. Nothing tells it the board's
// cell unless the host does, and a gauge left on TI's generic profile
// reports a percentage that drifts away from the cell: it moves at the
// wrong rate, then jumps when a voltage threshold corrects it. provision()
// compares the board's profile with the chip on every boot and rewrites
// the chip only when they differ, as the vendors' own firmware does.
//
// Protocol facts: TI's BQ27220 technical reference manual (SLUUBD4), with
// the data-memory write sequence and the delays that work taken from Flipper
// Zero's production driver (TI's manual gets the write sequence wrong).
// Command words are little-endian; data-memory values are big-endian.
// Header-only and transport-agnostic, so tests/gauge_test.cpp runs it
// against a simulated gauge.
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

namespace bq27220 {

constexpr uint8_t kAddr = 0x55;

// Register access on the gauge, and a sleep that may yield to other tasks.
// write/read return false on any bus error.
struct Io {
  bool (*write)(uint8_t reg, const uint8_t* data, size_t n);
  bool (*read)(uint8_t reg, uint8_t* data, size_t n);
  void (*sleep_ms)(uint32_t ms);
};

// One data-memory parameter: its address, width in bytes (1 or 2), value.
struct Param { uint16_t addr; uint8_t size; uint16_t value; };

enum class Result : uint8_t {
  Ok,           // the chip already held this profile; nothing written
  Provisioned,  // the profile was written and read back
  NotFound,     // no answer, or the chip is not a BQ27220
  BusError,     // a read failed midway
  Locked,       // the chip refused the unseal or full-access keys
  WriteFailed,  // written but not read back intact (or CONFIG UPDATE refused)
};

inline const char* result_name(Result r) {
  switch (r) {
    case Result::Ok:          return "ok";
    case Result::Provisioned: return "provisioned";
    case Result::NotFound:    return "not_found";
    case Result::BusError:    return "bus_error";
    case Result::Locked:      return "locked";
    case Result::WriteFailed: return "write_failed";
  }
  return "?";
}

struct Report {
  Result result;
  const char* step;            // where a failure happened, "" otherwise
  int design_mah_before;       // DesignCapacity() before any change, -1 if unread
  int full_mah_before;         // FullChargeCapacity() before any change
  int mismatched;              // profile entries that differed, -1 if not compared
  // A rewrite's details, for the boot log when one goes wrong:
  bool reset;                  // the chip was stuck and got a RESET first
  int mismatched_in_cfg;       // entries wrong just before leaving CONFIG UPDATE
  uint32_t verify_ms;          // how long after re-initialising the profile read back
  int write_errors;            // data-memory writes the chip NACKed
  uint8_t bad_count;           // entries still wrong after the rewrite...
  uint16_t bad_addr[4];        // ...the first few of them,
  uint16_t bad_got[4];         // ...and what they read back as
};

namespace detail {
constexpr uint8_t CMD_CONTROL = 0x00, CMD_VOLTAGE = 0x08, CMD_CURRENT = 0x0C,
                  CMD_FULL_CAP = 0x12, CMD_SOC = 0x2C, CMD_OP_STATUS = 0x3A,
                  CMD_DESIGN_CAP = 0x3C, CMD_MAC = 0x3E, CMD_MAC_DATA = 0x40,
                  CMD_MAC_SUM = 0x60;
constexpr uint16_t SUB_DEVICE_NUMBER = 0x0001, SUB_SEALED = 0x0030,
                   SUB_RESET = 0x0041, SUB_ENTER_CFG_UPDATE = 0x0090,
                   SUB_EXIT_CFG_UPDATE_REINIT = 0x0091,
                   KEY_UNSEAL_1 = 0x0414, KEY_UNSEAL_2 = 0x3672, KEY_FULL = 0xFFFF;
constexpr uint16_t DEVICE_ID = 0x0220;
// OperationStatus(): SEC in bits 1-2, INITCOMP bit 5, CFGUPDATE bit 10.
constexpr uint16_t OS_INITCOMP = 1u << 5, OS_CFGUPDATE = 1u << 10;
enum : uint8_t { SEC_FULL = 1, SEC_UNSEALED = 2, SEC_SEALED = 3 };
inline uint8_t sec(uint16_t op_status) { return (op_status >> 1) & 3; }

inline bool word(const Io& io, uint8_t reg, uint16_t* out) {
  uint8_t b[2];
  if (!io.read(reg, b, 2)) return false;
  *out = (uint16_t)(b[0] | (b[1] << 8));
  return true;
}
inline bool control(const Io& io, uint16_t sub) {
  const uint8_t b[2] = { (uint8_t)(sub & 0xFF), (uint8_t)(sub >> 8) };
  return io.write(CMD_CONTROL, b, 2);
}
inline bool op_status(const Io& io, uint16_t* s) { return word(io, CMD_OP_STATUS, s); }

// Poll OperationStatus() until (status & mask) == want. A read that fails
// (the chip NACKs while it resets) counts as not yet.
inline bool wait_status(const Io& io, uint16_t mask, uint16_t want, uint32_t timeout_ms,
                        uint32_t* waited_ms = nullptr) {
  for (uint32_t waited = 0;; waited += 5) {
    uint16_t s;
    if (op_status(io, &s) && (s & mask) == want) { if (waited_ms) *waited_ms = waited; return true; }
    if (waited >= timeout_ms) { if (waited_ms) *waited_ms = waited; return false; }
    io.sleep_ms(5);
  }
}

inline bool unseal(const Io& io) {
  uint16_t s;
  if (!op_status(io, &s)) return false;
  if (sec(s) != SEC_SEALED) return true;
  control(io, KEY_UNSEAL_1); io.sleep_ms(5);   // keys need ~2.5 ms apart
  control(io, KEY_UNSEAL_2); io.sleep_ms(5);
  return op_status(io, &s) && sec(s) == SEC_UNSEALED;
}
inline bool full_access(const Io& io) {
  uint16_t s;
  if (!op_status(io, &s)) return false;
  if (sec(s) == SEC_FULL) return true;
  if (sec(s) != SEC_UNSEALED) return false;
  control(io, KEY_FULL); io.sleep_ms(5);
  control(io, KEY_FULL); io.sleep_ms(5);
  return op_status(io, &s) && sec(s) == SEC_FULL;
}
inline bool seal(const Io& io) {
  uint16_t s;
  if (!op_status(io, &s)) return false;
  if (sec(s) == SEC_SEALED) return true;
  if (!control(io, SUB_SEALED)) return false;
  io.sleep_ms(1);
  return op_status(io, &s) && sec(s) == SEC_SEALED;
}
// RESET reloads the defaults. On the T5's gauge it lands up to seconds
// after the command without INITCOMP ever visibly dropping, and wipes
// anything written before it lands: writes 0.2 s after the command were
// lost, writes 3 s after it held. So wait it out by the clock (5 s), then
// for INITCOMP.
constexpr uint32_t kResetSettleMs = 5000;
inline bool reset(const Io& io) {
  if (!control(io, SUB_RESET)) return false;
  io.sleep_ms(kResetSettleMs);
  return wait_status(io, OS_INITCOMP, OS_INITCOMP, 4000);
}

inline void value_bytes(const Param& p, uint8_t* out) {   // big-endian
  if (p.size == 1) { out[0] = (uint8_t)p.value; return; }
  out[0] = (uint8_t)(p.value >> 8);
  out[1] = (uint8_t)(p.value & 0xFF);
}
// Select a data-memory address, then read its first bytes from MACData().
inline bool dm_read(const Io& io, uint16_t addr, uint8_t* out, uint8_t size) {
  const uint8_t a[2] = { (uint8_t)(addr & 0xFF), (uint8_t)(addr >> 8) };
  if (!io.write(CMD_MAC, a, 2)) return false;
  io.sleep_ms(1);   // the block takes ~0.5 ms to load
  bool ok = io.read(CMD_MAC_DATA, out, size);
  io.sleep_ms(1);
  return ok;
}
// Address and value to 0x3E onward, then checksum and length to 0x60/0x61:
// the checksum is 0xFF minus the byte sum of address and value; the length
// counts address, value, checksum and length. Only in CONFIG UPDATE mode.
inline bool dm_write(const Io& io, const Param& p) {
  uint8_t b[4] = { (uint8_t)(p.addr & 0xFF), (uint8_t)(p.addr >> 8), 0, 0 };
  value_bytes(p, b + 2);
  const size_t n = 2 + p.size;
  if (!io.write(CMD_MAC, b, n)) return false;
  io.sleep_ms(1);   // fails under ~120 us
  uint8_t sum = 0;
  for (size_t i = 0; i < n; i++) sum += b[i];
  const uint8_t tail[2] = { (uint8_t)(0xFF - sum), (uint8_t)(n + 2) };
  if (!io.write(CMD_MAC_SUM, tail, 2)) return false;
  io.sleep_ms(10);
  return true;
}
// How many entries the chip holds differently; -1 if a read failed. With
// `note`, the first few wrong entries and their read-back land in it.
inline int mismatches(const Io& io, const Param* ps, size_t n, Report* note = nullptr) {
  int bad = 0;
  for (size_t i = 0; i < n; i++) {
    uint8_t want[2] = { 0, 0 }, got[2] = { 0, 0 };
    value_bytes(ps[i], want);
    if (!dm_read(io, ps[i].addr, got, ps[i].size)) return -1;
    if (memcmp(want, got, ps[i].size) == 0) continue;
    if (note && note->bad_count < 4) {
      note->bad_addr[note->bad_count] = ps[i].addr;
      note->bad_got[note->bad_count] = ps[i].size == 1 ? got[0] : (uint16_t)(got[0] << 8 | got[1]);
      note->bad_count++;
    }
    bad++;
  }
  return bad;
}
inline int read_u16(const Io& io, uint8_t reg) {
  uint16_t v;
  return word(io, reg, &v) ? (int)v : -1;
}
inline Report finish(Report r, Result result, const char* step) {
  r.result = result;
  r.step = step;
  return r;
}
}  // namespace detail

// Check the chip against `profile` and rewrite it on any difference. Blocks
// for ~60 ms when the chip already matches, ~5 s when it has to rewrite
// (up to ~13 s when the read-back is slow; 5 s more for a stuck chip's reset). Always leaves the chip sealed and
// out of CONFIG UPDATE mode (the gauge stops counting while in it)
// whenever the bus allows.
inline Report provision(const Io& io, const Param* profile, size_t n) {
  using namespace detail;
  Report r = {};
  r.result = Result::Ok;
  r.step = "";
  r.design_mah_before = r.full_mah_before = r.mismatched = r.mismatched_in_cfg = -1;
  uint16_t id = 0;
  if (!control(io, SUB_DEVICE_NUMBER)) return finish(r, Result::NotFound, "id");
  io.sleep_ms(1);
  if (!word(io, CMD_MAC_DATA, &id) || id != DEVICE_ID) return finish(r, Result::NotFound, "id");
  r.design_mah_before = read_u16(io, CMD_DESIGN_CAP);
  r.full_mah_before = read_u16(io, CMD_FULL_CAP);

  if (!unseal(io)) { seal(io); return finish(r, Result::Locked, "unseal"); }
  uint16_t s = 0, cs = 0;
  if (!op_status(io, &s) || !word(io, CMD_CONTROL, &cs)) {
    seal(io);
    return finish(r, Result::BusError, "status");
  }
  // Stuck initialising, left in CONFIG UPDATE, or on another battery
  // profile: reset it before rewriting. A chip merely holding other values
  // is rewritten in place -- the vendors' drivers reset it too, but a RESET
  // here lands late and can wipe the new values (see reset()).
  r.reset = !(s & OS_INITCOMP) || (s & OS_CFGUPDATE) || (cs & 0x07) != 0;
  if (!r.reset) {
    r.mismatched = mismatches(io, profile, n);
    if (r.mismatched < 0) { seal(io); return finish(r, Result::BusError, "check"); }
    if (r.mismatched == 0) {
      seal(io);
      return r;
    }
  }

  if (r.reset && (!reset(io) || !unseal(io))) { seal(io); return finish(r, Result::BusError, "reset"); }
  if (!full_access(io)) { seal(io); return finish(r, Result::Locked, "full_access"); }
  const uint8_t enter[2] = { (uint8_t)SUB_ENTER_CFG_UPDATE, 0 };
  bool entered = io.write(CMD_MAC, enter, 2) &&
                 wait_status(io, OS_CFGUPDATE, OS_CFGUPDATE, 2000);
  for (size_t i = 0; entered && i < n; i++) if (!dm_write(io, profile[i])) r.write_errors++;
  if (entered) r.mismatched_in_cfg = mismatches(io, profile, n);   // landed at all?
  // Leave CONFIG UPDATE even after a failed write: a gauge left in it stops
  // counting until the next boot notices.
  control(io, SUB_EXIT_CFG_UPDATE_REINIT);
  io.sleep_ms(2000);   // it re-initialises with the new profile
  bool left = wait_status(io, OS_CFGUPDATE, 0, 2000);
  // Data-memory reads return junk for a while after that (on the T5's gauge
  // ~4.5 s after EXIT), so poll for the profile to read back instead of
  // reading once. Access is taken again each time in case re-initialising
  // sealed it.
  int still = -1;
  for (uint32_t waited = 0; left; waited += 500) {
    r.bad_count = 0;
    still = unseal(io) ? mismatches(io, profile, n, &r) : -1;
    if (still == 0) { r.verify_ms = waited; break; }
    if (waited >= 10000) break;
    io.sleep_ms(500);
  }
  seal(io);
  if (!entered) return finish(r, Result::WriteFailed, "cfg_update");
  if (!left) return finish(r, Result::WriteFailed, "exit_cfg_update");
  if (r.write_errors > 0 || still != 0) return finish(r, Result::WriteFailed, "verify");
  r.result = Result::Provisioned;
  return r;
}

// The boot log line for a report: one JSON object, newline-terminated.
inline int report_json(char* out, size_t n, const Report& r, unsigned cell_mah) {
  char bad[48] = "";
  for (uint8_t i = 0; i < r.bad_count && i < 4; i++) {
    size_t used = strlen(bad);
    snprintf(bad + used, sizeof(bad) - used, "%s%04X=%04X", i ? "," : "",
             (unsigned)r.bad_addr[i], (unsigned)r.bad_got[i]);
  }
  return snprintf(out, n,
                  "{\"type\":\"gauge\",\"chip\":\"bq27220\",\"result\":\"%s\",\"step\":\"%s\","
                  "\"cell_mah\":%u,\"was_design_mah\":%d,\"was_full_mah\":%d,\"mismatched\":%d,"
                  "\"reset\":%s,\"write_errors\":%d,\"in_cfg_mismatched\":%d,\"verify_ms\":%u,"
                  "\"bad\":\"%s\"}\n",
                  result_name(r.result), r.step, cell_mah, r.design_mah_before,
                  r.full_mah_before, r.mismatched, r.reset ? "true" : "false", r.write_errors,
                  r.mismatched_in_cfg, (unsigned)r.verify_ms, bad);
}

// Read-outs; -1 when the gauge does not answer.
inline int soc_pct(const Io& io) {
  int v = detail::read_u16(io, detail::CMD_SOC);
  return v > 100 ? 100 : v;
}
inline int voltage_mv(const Io& io) { return detail::read_u16(io, detail::CMD_VOLTAGE); }
inline int full_capacity_mah(const Io& io) { return detail::read_u16(io, detail::CMD_FULL_CAP); }
inline int design_capacity_mah(const Io& io) { return detail::read_u16(io, detail::CMD_DESIGN_CAP); }
// Current() in mA, positive while charging. False when the gauge does not answer.
inline bool current_ma(const Io& io, int* ma) {
  uint16_t v;
  if (!detail::word(io, detail::CMD_CURRENT, &v)) return false;
  *ma = (int16_t)v;
  return true;
}

}  // namespace bq27220
