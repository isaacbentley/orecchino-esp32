// Host tests for the fuel-gauge and charger code (firmware/common/bq27220.h,
// bq27220_profiles.h, axp2101.h, bq25896.h) against simulated chips. The BQ27220 fake
// models what provisioning depends on: the sealed / unsealed / full-access
// states and their keys, CONFIG UPDATE mode, data-memory block reads, writes
// that only land with the right checksum and length, and RESET reloading
// the defaults. The tests pin what a bench cannot show: the exact bytes a
// data-memory write puts on the bus, that a chip already holding the
// profile is never written, and that no failure leaves the gauge in CONFIG
// UPDATE (where it stops counting) or unsealed.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
#include <stdio.h>
#include <string.h>
#include <vector>
#include "bq27220.h"
#include "bq27220_profiles.h"
#include "axp2101.h"
#include "bq25896.h"

static int g_fails = 0;
#define CHECK(c, name) do { if (c) printf("ok   %s\n", name); else { printf("FAIL %s\n", name); g_fails++; } } while (0)

using bq27220::Param;
using bq27220::Result;
constexpr size_t kT5N = sizeof bq27220::kT5EpdProfile / sizeof(Param);
constexpr size_t kTEmbedN = sizeof bq27220::kTEmbedProfile / sizeof(Param);

// ---------------------------------------------------------------- fake BQ27220

struct Xfer { bool write; uint8_t reg; std::vector<uint8_t> data; };

// How the T5's own gauge behaved on the bench (2026-09-22), and the fake's
// defaults: a RESET lands well after the command with INITCOMP never seen
// low (writes 0.2 s after it were wiped, writes 3 s after it held), and
// data-memory reads return junk for a while after EXIT_CFG_UPDATE_REINIT
// (~4.5 s on the T5; fine by the next boot).
struct FakeGauge {
  // how this chip behaves
  bool present = true;
  uint16_t device_id = 0x0220;
  uint16_t key1 = 0x0414, key2 = 0x3672;
  bool reseal_on_reset = false;
  int nack_status_after_reset = 0;   // OperationStatus reads that NACK after RESET
  uint32_t reset_lag_ms = 1500;      // a RESET lands this long after the command
  uint32_t reset_ms = 2000;          // ...and re-initialises for this long
  bool reset_hides_initcomp = true;  // ...without INITCOMP ever reading low
  uint32_t junk_after_exit_ms = 4500;   // DM reads are junk this long after EXIT
  bool seal_on_exit = false;         // EXIT_CFG_UPDATE also re-seals
  int fail_checksum_write = -1;      // this checksum write (0-based) NACKs
  uint16_t ignores_addr = 0;         // writes here are accepted but never land
  // state
  uint8_t sec = 3;                   // 3 sealed, 2 unsealed, 1 full access
  bool initcomp = true, cfgupdate = false;
  uint8_t batt_id = 0;
  uint8_t dm[0x400] = {};            // data memory 0x9000..0x93FF, big-endian values
  uint8_t defaults[0x400] = {};
  int nacks = 0;
  uint32_t now_ms = 0;               // simulated time: advanced only by sleeps
  int64_t reset_at = -1, reset_done_at = -1, junk_until = -1;
  uint16_t prev_control = 0;
  uint16_t sel = 0;
  uint8_t pending[32] = {};
  size_t pending_n = 0;
  uint8_t mac_data[32] = {};
  int commits = 0, rejects = 0, resets = 0, checksum_writes = 0;
  int soc = 54, mv = 4110, ma = 250;
  uint16_t remaining = 810, cycles = 3, soh = 97, batt_status = 0x0201;
  uint16_t op_flags = 0;             // OperationStatus bits besides SEC/INITCOMP/CFGUPDATE (VDQ, EDV2)
  uint32_t slept_ms = 0;
  std::vector<Xfer> log;
};
static FakeGauge G;

static uint16_t dm16(uint16_t addr) {
  return (uint16_t)(G.dm[addr - 0x9000] << 8 | G.dm[addr - 0x9000 + 1]);
}
static void put(uint8_t* mem, uint16_t addr, uint8_t size, uint16_t v) {
  if (size == 1) { mem[addr - 0x9000] = (uint8_t)v; return; }
  mem[addr - 0x9000] = (uint8_t)(v >> 8);
  mem[addr - 0x9000 + 1] = (uint8_t)v;
}
static bool holds(const Param* ps, size_t n) {
  for (size_t i = 0; i < n; i++) {
    uint16_t got = ps[i].size == 1 ? G.dm[ps[i].addr - 0x9000] : dm16(ps[i].addr);
    if (got != ps[i].value) return false;
  }
  return true;
}

// A RESET in progress: at reset_at the defaults come back and INITCOMP
// drops; at reset_done_at INITCOMP returns. Checked on every bus access.
static void tick(void) {
  if (G.reset_at >= 0 && G.now_ms >= G.reset_at) {
    G.reset_at = -1;
    memcpy(G.dm, G.defaults, sizeof G.dm);
    if (!G.reset_hides_initcomp) G.initcomp = false;
    G.cfgupdate = false; G.batt_id = 0;
    G.nacks = G.nack_status_after_reset;
    if (G.reseal_on_reset) G.sec = 3;
  }
  if (G.reset_at < 0 && G.reset_done_at >= 0 && G.now_ms >= G.reset_done_at) {
    G.reset_done_at = -1;
    G.initcomp = true;
  }
}

static void control(uint16_t sub) {
  uint16_t prev = G.prev_control;
  G.prev_control = sub;
  switch (sub) {
    case 0x0001:   // DEVICE_NUMBER -> MACData
      G.mac_data[0] = (uint8_t)G.device_id; G.mac_data[1] = (uint8_t)(G.device_id >> 8);
      return;
    case 0x0030: G.sec = 3; return;                       // SEALED
    case 0x0041:                                          // RESET
      if (G.sec == 3) return;
      G.resets++;
      G.reset_at = G.now_ms + G.reset_lag_ms;
      G.reset_done_at = G.reset_at + G.reset_ms;
      return;
    case 0x0091: case 0x0092:                             // EXIT_CFG_UPDATE(_REINIT)
      G.cfgupdate = false;
      G.junk_until = G.now_ms + G.junk_after_exit_ms;
      if (G.seal_on_exit) G.sec = 3;
      return;
    case 0xFFFF: if (G.sec == 2 && prev == 0xFFFF) G.sec = 1; return;
    default:
      if (G.sec == 3 && prev == G.key1 && sub == G.key2) G.sec = 2;
      return;
  }
}

static bool fake_write(uint8_t reg, const uint8_t* d, size_t n) {
  G.log.push_back({ true, reg, std::vector<uint8_t>(d, d + n) });
  if (!G.present) return false;
  tick();
  if (reg == 0x00 && n == 2) { control((uint16_t)(d[0] | d[1] << 8)); return true; }
  if (reg == 0x3E && n >= 2) {
    uint16_t a = (uint16_t)(d[0] | d[1] << 8);
    if (a < 0x4000) {                                     // a MAC subcommand
      // ENTER_CFG_UPDATE: needs the chip unsealed and done initialising
      if (a == 0x0090 && G.sec != 3 && G.initcomp) G.cfgupdate = true;
      return true;
    }
    G.sel = a;
    G.pending_n = n - 2;
    memcpy(G.pending, d + 2, n - 2);
    if (n == 2) {                                         // a block read
      if (G.sec == 3) memset(G.mac_data, 0xA5, sizeof G.mac_data);   // refused
      else if (G.now_ms < G.junk_until)                   // still re-initialising
        for (size_t i = 0; i < sizeof G.mac_data; i++) G.mac_data[i] = (uint8_t)(i & 1);
      else memcpy(G.mac_data, &G.dm[a - 0x9000], sizeof G.mac_data);
    }
    return true;
  }
  if (reg == 0x60 && n == 2) {
    if (G.checksum_writes++ == G.fail_checksum_write) return false;
    uint8_t sum = (uint8_t)(G.sel & 0xFF) + (uint8_t)(G.sel >> 8);
    for (size_t i = 0; i < G.pending_n; i++) sum += G.pending[i];
    bool ok = G.pending_n > 0 && G.cfgupdate && G.sec != 3 && G.initcomp &&
              d[0] == (uint8_t)(0xFF - sum) && d[1] == (uint8_t)(G.pending_n + 4);
    if (ok && G.sel != G.ignores_addr) { memcpy(&G.dm[G.sel - 0x9000], G.pending, G.pending_n); G.commits++; }
    else if (ok) G.commits++;
    else G.rejects++;
    G.pending_n = 0;
    return true;
  }
  return true;
}

static bool fake_read(uint8_t reg, uint8_t* out, size_t n) {
  G.log.push_back({ false, reg, {} });
  if (!G.present) return false;
  tick();
  uint16_t v = 0;
  switch (reg) {
    case 0x3A:
      if (G.nacks > 0) { G.nacks--; return false; }
      v = (uint16_t)(G.sec << 1 | (G.initcomp ? 0x20 : 0) | (G.cfgupdate ? 0x400 : 0) | G.op_flags);
      break;
    case 0x00: v = G.batt_id; break;                      // CONTROL_STATUS
    case 0x40: memcpy(out, G.mac_data, n); return true;
    case 0x3C: v = dm16(0x929F); break;
    case 0x12: v = dm16(0x929D); break;
    case 0x2C: v = (uint16_t)G.soc; break;
    case 0x08: v = (uint16_t)G.mv; break;
    case 0x0C: v = (uint16_t)(int16_t)G.ma; break;
    case 0x0A: v = G.batt_status; break;
    case 0x10: v = G.remaining; break;
    case 0x2A: v = G.cycles; break;
    case 0x2E: v = G.soh; break;
  }
  out[0] = (uint8_t)v;
  if (n > 1) out[1] = (uint8_t)(v >> 8);
  return true;
}
static void fake_sleep(uint32_t ms) { G.slept_ms += ms; G.now_ms += ms; }
static const bq27220::Io kIo = { fake_write, fake_read, fake_sleep };

// A chip on TI-style defaults: the board profile except four entries, the
// way a never-configured gauge differs (capacity, gauging bits, deadband).
template <size_t N> static void fresh(const Param (&p)[N]) {
  G = FakeGauge();
  memset(G.defaults, 0x5A, sizeof G.defaults);
  for (size_t i = 0; i < N; i++) put(G.defaults, p[i].addr, p[i].size, p[i].value);
  put(G.defaults, 0x929D, 2, 3000);
  put(G.defaults, 0x929F, 2, 3000);
  put(G.defaults, 0x929B, 2, 0x0000);
  put(G.defaults, 0x91DE, 1, 5);
  memcpy(G.dm, G.defaults, sizeof G.dm);
}

static bool wrote(uint8_t reg, std::vector<uint8_t> bytes) {
  for (const Xfer& x : G.log) if (x.write && x.reg == reg && x.data == bytes) return true;
  return false;
}
// A data-memory write: address and value to 0x3E, then the very next write
// is checksum and length to 0x60.
static bool dm_pair(std::vector<uint8_t> addr_value, std::vector<uint8_t> sum_len) {
  for (size_t i = 0; i < G.log.size(); i++) {
    if (!(G.log[i].write && G.log[i].reg == 0x3E && G.log[i].data == addr_value)) continue;
    for (size_t j = i + 1; j < G.log.size(); j++)
      if (G.log[j].write) return G.log[j].reg == 0x60 && G.log[j].data == sum_len;
  }
  return false;
}
static int writes_to(uint8_t reg) {
  int k = 0;
  for (const Xfer& x : G.log) if (x.write && x.reg == reg) k++;
  return k;
}

// ------------------------------------------------------------------- BQ27220

static void test_provision_fresh(void) {
  fresh(bq27220::kT5EpdProfile);
  bq27220::Report r = bq27220::provision(kIo, bq27220::kT5EpdProfile, kT5N);
  CHECK(r.result == Result::Provisioned, "bq27220: a chip on defaults is provisioned");
  CHECK(r.design_mah_before == 3000 && r.full_mah_before == 3000 && r.mismatched == 4,
        "bq27220: the report says what the chip held before");
  CHECK(holds(bq27220::kT5EpdProfile, kT5N), "bq27220: every profile entry reads back");
  CHECK(G.rejects == 0 && G.commits == (int)kT5N, "bq27220: no write rejected for checksum or length");
  CHECK(G.sec == 3 && !G.cfgupdate, "bq27220: left sealed and out of CONFIG UPDATE");
  CHECK(G.resets == 0 && !r.reset,
        "bq27220: rewritten in place, no RESET (on this chip a late RESET wipes the new values)");
  G.now_ms += 60000;                             // long after: the late-reset hazard has passed
  CHECK(holds(bq27220::kT5EpdProfile, kT5N) && bq27220::design_capacity_mah(kIo) == 1500 &&
        bq27220::full_capacity_mah(kIo) == 1500,
        "bq27220: ...and it still holds a minute later: DesignCapacity() and FullChargeCapacity() 1500 mAh");
  CHECK(G.slept_ms < 6000, "bq27220: a rewrite waits under 6 s");
  CHECK(r.mismatched_in_cfg == 0 && r.verify_ms == 2500 && r.bad_count == 0,
        "bq27220: the report shows the writes landed, and read back once the junk passed");

  // The bytes on the bus, worked by hand from the protocol.
  CHECK(wrote(0x00, { 0x14, 0x04 }) && wrote(0x00, { 0x72, 0x36 }), "bq27220: unseal keys 0x0414 then 0x3672");
  CHECK(wrote(0x3E, { 0x90, 0x00 }), "bq27220: ENTER_CFG_UPDATE through the MAC register");
  CHECK(dm_pair({ 0x9F, 0x92, 0x05, 0xDC }, { 0xED, 0x06 }),
        "bq27220: Design Capacity 1500 -> 9F 92 05 DC, checksum ED, length 6");
  CHECK(dm_pair({ 0x9B, 0x92, 0x0D, 0x31 }, { 0x94, 0x06 }),
        "bq27220: Gauging Configuration 0x0D31 -> checksum 94");
  CHECK(dm_pair({ 0xB1, 0x92, 0x09 }, { 0xB3, 0x05 }),
        "bq27220: one-byte TC = 9 -> 92B1 09, checksum B3, length 5");
  CHECK(wrote(0x00, { 0x91, 0x00 }) && wrote(0x00, { 0x30, 0x00 }), "bq27220: EXIT_CFG_UPDATE_REINIT, then SEALED");
}

static void test_already_right(void) {
  fresh(bq27220::kT5EpdProfile);
  bq27220::provision(kIo, bq27220::kT5EpdProfile, kT5N);
  G.log.clear(); G.resets = 0; G.commits = 0; G.slept_ms = 0;
  bq27220::Report r = bq27220::provision(kIo, bq27220::kT5EpdProfile, kT5N);
  CHECK(r.result == Result::Ok && r.mismatched == 0, "bq27220: a chip holding the profile reports ok");
  CHECK(G.commits == 0 && G.resets == 0 && writes_to(0x60) == 0 && !wrote(0x3E, { 0x90, 0x00 }),
        "bq27220: ...and is never reset or written");
  CHECK(G.sec == 3, "bq27220: ...and is sealed again");
  CHECK(G.slept_ms < 150, "bq27220: the every-boot check waits under 150 ms");
}

static void test_forced_rewrites(void) {
  fresh(bq27220::kT5EpdProfile);
  for (const Param& p : bq27220::kT5EpdProfile) put(G.dm, p.addr, p.size, p.value);
  G.sec = 1; G.cfgupdate = true;                 // a boot that died mid-update
  bq27220::Report r = bq27220::provision(kIo, bq27220::kT5EpdProfile, kT5N);
  CHECK(r.result == Result::Provisioned && r.mismatched == -1 && G.resets == 1 && r.reset,
        "bq27220: left in CONFIG UPDATE -> reset and rewritten");
  G.now_ms += 60000;
  CHECK(holds(bq27220::kT5EpdProfile, kT5N), "bq27220: ...and the late RESET landed before the writes, not after");
  CHECK(!G.cfgupdate && G.sec == 3, "bq27220: ...and out of it, sealed");

  fresh(bq27220::kT5EpdProfile);
  for (const Param& p : bq27220::kT5EpdProfile) put(G.dm, p.addr, p.size, p.value);
  G.initcomp = false;                            // stuck initialising
  r = bq27220::provision(kIo, bq27220::kT5EpdProfile, kT5N);
  CHECK(r.result == Result::Provisioned && G.resets == 1 && G.initcomp,
        "bq27220: stuck initialising -> reset recovers it");

  fresh(bq27220::kT5EpdProfile);
  for (const Param& p : bq27220::kT5EpdProfile) put(G.dm, p.addr, p.size, p.value);
  G.batt_id = 2;                                 // another battery profile selected
  r = bq27220::provision(kIo, bq27220::kT5EpdProfile, kT5N);
  CHECK(r.result == Result::Provisioned && G.resets == 1 && G.batt_id == 0,
        "bq27220: another profile slot selected -> reset and rewritten");
}

static void test_refusals(void) {
  fresh(bq27220::kT5EpdProfile);
  G.device_id = 0x0421;
  bq27220::Report r = bq27220::provision(kIo, bq27220::kT5EpdProfile, kT5N);
  CHECK(r.result == Result::NotFound && writes_to(0x3E) == 0 && writes_to(0x60) == 0 && G.resets == 0,
        "bq27220: another chip at 0x55 -> not_found, nothing written");

  fresh(bq27220::kT5EpdProfile);
  G.present = false;
  r = bq27220::provision(kIo, bq27220::kT5EpdProfile, kT5N);
  CHECK(r.result == Result::NotFound && G.slept_ms < 10, "bq27220: no chip -> not_found at once");

  fresh(bq27220::kT5EpdProfile);
  G.key1 = 0x1234;                               // keys changed at the factory
  r = bq27220::provision(kIo, bq27220::kT5EpdProfile, kT5N);
  CHECK(r.result == Result::Locked && G.commits == 0 && G.resets == 0 && G.sec == 3,
        "bq27220: unseal refused -> locked, untouched, still sealed");
}

static void test_failures_midway(void) {
  fresh(bq27220::kT5EpdProfile);
  G.fail_checksum_write = 9;
  bq27220::Report r = bq27220::provision(kIo, bq27220::kT5EpdProfile, kT5N);
  CHECK(r.result == Result::WriteFailed && strcmp(r.step, "verify") == 0 && r.write_errors == 1,
        "bq27220: a write NACKs midway -> write_failed at verify, one write error");
  CHECK(!G.cfgupdate && G.sec == 3, "bq27220: ...and the gauge is still out of CONFIG UPDATE, sealed");
  CHECK(G.commits == (int)kT5N - 1, "bq27220: ...with every other entry still written");

  fresh(bq27220::kT5EpdProfile);
  G.ignores_addr = 0x929F;                       // Design Capacity never lands
  r = bq27220::provision(kIo, bq27220::kT5EpdProfile, kT5N);
  CHECK(r.result == Result::WriteFailed && r.write_errors == 0 && r.bad_count == 1 &&
        r.bad_addr[0] == 0x929F && r.bad_got[0] == 3000,
        "bq27220: a value that does not stick is named, with what it reads back as");

  // The RESET paths only run for a stuck chip; "left in CONFIG UPDATE" is one.
  fresh(bq27220::kT5EpdProfile);
  G.sec = 1; G.cfgupdate = true; G.reseal_on_reset = true;
  r = bq27220::provision(kIo, bq27220::kT5EpdProfile, kT5N);
  CHECK(r.result == Result::Provisioned, "bq27220: a RESET that re-seals is unsealed again");

  fresh(bq27220::kT5EpdProfile);
  G.sec = 1; G.cfgupdate = true; G.nack_status_after_reset = 4;
  G.reset_lag_ms = 0; G.reset_hides_initcomp = false;   // Flipper's chips: INITCOMP drops at once
  r = bq27220::provision(kIo, bq27220::kT5EpdProfile, kT5N);
  CHECK(r.result == Result::Provisioned, "bq27220: an immediate RESET, NACKing status reads, is waited out");

  fresh(bq27220::kT5EpdProfile);
  G.sec = 1; G.cfgupdate = true; G.reset_lag_ms = 3000;
  r = bq27220::provision(kIo, bq27220::kT5EpdProfile, kT5N);
  G.now_ms += 60000;
  CHECK(r.result == Result::Provisioned && holds(bq27220::kT5EpdProfile, kT5N),
        "bq27220: a RESET landing 3 s late, INITCOMP never low, is waited out before writing");

  fresh(bq27220::kT5EpdProfile);
  G.sec = 1; G.cfgupdate = true; G.reset_lag_ms = 7000;  // lands after the writes
  r = bq27220::provision(kIo, bq27220::kT5EpdProfile, kT5N);
  CHECK(r.result == Result::WriteFailed && r.bad_count > 0 && !G.cfgupdate && G.sec == 3,
        "bq27220: a RESET landing after the writes is caught by the read-back, never reported ok");

  fresh(bq27220::kT5EpdProfile);
  G.junk_after_exit_ms = 20000;                  // never settles within the poll
  r = bq27220::provision(kIo, bq27220::kT5EpdProfile, kT5N);
  CHECK(r.result == Result::WriteFailed && strcmp(r.step, "verify") == 0 && r.bad_count == 4,
        "bq27220: read-backs that stay junk -> write_failed at verify, entries named");

  fresh(bq27220::kT5EpdProfile);
  G.seal_on_exit = true;
  r = bq27220::provision(kIo, bq27220::kT5EpdProfile, kT5N);
  CHECK(r.result == Result::Provisioned, "bq27220: a chip that re-seals on EXIT is unsealed for the read-back");
}

static void test_readouts(void) {
  fresh(bq27220::kT5EpdProfile);
  G.soc = 54; G.mv = 4110; G.ma = -320;
  int ma = 0;
  CHECK(bq27220::soc_pct(kIo) == 54 && bq27220::voltage_mv(kIo) == 4110, "bq27220: SOC and voltage");
  CHECK(bq27220::current_ma(kIo, &ma) && ma == -320, "bq27220: current is signed (negative discharging)");
  G.soc = 250;
  CHECK(bq27220::soc_pct(kIo) == 100, "bq27220: SOC above 100 clamps");
  // The whole state, each value from its own register (distinct numbers,
  // so a swapped register shows).
  G.soc = 54; G.remaining = 810; G.cycles = 3; G.soh = 97;
  G.batt_status = 0x0001; G.op_flags = 0;
  bq27220::State s = bq27220::state(kIo);
  CHECK(s.soc_pct == 54 && s.mv == 4110 && s.ma_ok && s.ma == -320 && s.remaining_mah == 810 &&
        s.full_mah == dm16(0x929D) && s.design_mah == dm16(0x929F) && s.cycles == 3 && s.soh_pct == 97,
        "bq27220: state reads SOC, mV, mA, remaining, full, design, cycles and health from their registers");
  CHECK(s.battery_status == 0x0001 && !s.full && !s.vdq && !s.edv2 && (s.operation_status & 0x20),
        "bq27220: mid-discharge: no learning flag set, OperationStatus raw (INITCOMP)");
  // The learning cycle's milestones, each from its own bit: FC in
  // BatteryStatus, then VDQ and EDV2 in OperationStatus.
  G.batt_status = 0x0200;
  s = bq27220::state(kIo);
  CHECK(s.full && !s.vdq && !s.edv2, "bq27220: BatteryStatus bit 9 is the full charge");
  G.batt_status = 0x0001; G.op_flags = 0x10;
  s = bq27220::state(kIo);
  CHECK(!s.full && s.vdq && !s.edv2, "bq27220: OperationStatus bit 4 is a qualified discharge");
  G.op_flags = 0x18;
  s = bq27220::state(kIo);
  CHECK(s.vdq && s.edv2, "bq27220: OperationStatus bit 3 is the low threshold reached");
  G.ma = -1;
  s = bq27220::state(kIo);
  CHECK(s.ma_ok && s.ma == -1, "bq27220: -1 mA is a reading, not a failure");
  G.op_flags = 0;
  G.present = false;
  CHECK(bq27220::soc_pct(kIo) == -1 && bq27220::voltage_mv(kIo) == -1 && !bq27220::current_ma(kIo, &ma),
        "bq27220: no answer -> -1");
  s = bq27220::state(kIo);
  CHECK(s.soc_pct == -1 && s.mv == -1 && !s.ma_ok && s.remaining_mah == -1 && s.full_mah == -1 &&
        s.design_mah == -1 && s.cycles == -1 && s.soh_pct == -1 && s.battery_status == -1 &&
        s.operation_status == -1 && !s.full && !s.vdq && !s.edv2,
        "bq27220: state with no answer: every value -1, the current unread, no flag set");
}

// The tables themselves: a transposed digit here is a wrong gauge for good.
template <size_t N> static bool profile_sane(const Param (&p)[N], uint16_t cell_mah) {
  int dod = 0, edv = 0;
  uint16_t last_dod = 0xFFFF, last_edv = 0, design = 0, full = 0, cfg = 0;
  for (size_t i = 0; i < N; i++) {
    if (p[i].size != 1 && p[i].size != 2) return false;
    if (p[i].addr < 0x9000 || p[i].addr + p[i].size > 0x9400) return false;
    if (p[i].size == 1 && p[i].value > 0xFF) return false;
    for (size_t j = 0; j < i; j++) if (p[j].addr == p[i].addr) return false;
    if (p[i].addr >= 0x92BD && p[i].addr <= 0x92D1) {        // Start DOD 0..100%: falling
      if (p[i].value >= last_dod) return false;
      last_dod = p[i].value; dod++;
    }
    if (p[i].addr == 0x92B4 || p[i].addr == 0x92B7 || p[i].addr == 0x92BA) {   // EDV0..2: rising
      if (p[i].value <= last_edv) return false;
      last_edv = p[i].value; edv++;
    }
    if (p[i].addr == 0x929F) design = p[i].value;
    if (p[i].addr == 0x929D) full = p[i].value;
    if (p[i].addr == 0x929B) cfg = p[i].value;
  }
  return dod == 11 && edv == 3 && design == cell_mah && full == cell_mah && cfg == 0x0D31;
}

static void test_profiles(void) {
  CHECK(profile_sane(bq27220::kT5EpdProfile, 1500) && kT5N == 28,
        "profiles: T5 -- 1500 mAh, falling DOD table, rising EDVs, no duplicates");
  CHECK(profile_sane(bq27220::kTEmbedProfile, 1300) && kTEmbedN == 34,
        "profiles: T-Embed -- 1300 mAh, same checks");
  fresh(bq27220::kTEmbedProfile);
  bq27220::Report r = bq27220::provision(kIo, bq27220::kTEmbedProfile, kTEmbedN);
  CHECK(r.result == Result::Provisioned && holds(bq27220::kTEmbedProfile, kTEmbedN) && G.rejects == 0,
        "profiles: T-Embed provisions and reads back");
}

// ------------------------------------------------------------------- AXP2101

static uint8_t A[256];
static bool a_present = true;
static int a_writes = 0;
static bool a_read(uint8_t r, uint8_t* v) { if (!a_present) return false; *v = A[r]; return true; }
static bool a_write(uint8_t r, uint8_t v) { if (!a_present) return false; A[r] = v; a_writes++; return true; }
static const axp2101::Io kPmu = { a_read, a_write };

static void test_axp2101(void) {
  memset(A, 0, sizeof A);
  A[0x18] = 0x02; A[0x30] = 0x0C; A[0x68] = 0x00; A[0x10] = 0x77;
  CHECK(axp2101::begin(kPmu), "axp2101: begin answers");
  CHECK(A[0x68] == 0x01 && A[0x18] == 0x0A && A[0x30] == 0x0D && A[0x10] == 0x77,
        "axp2101: detection, gauge and VBAT ADC bits set, other bits and registers kept");
  a_writes = 0;
  axp2101::begin(kPmu);
  CHECK(a_writes == 0, "axp2101: nothing written when already on");

  A[0x00] = 0x00; A[0xA4] = 80;
  CHECK(axp2101::batt_pct(kPmu) == -1, "axp2101: no battery present -> -1, whatever 0xA4 holds");
  A[0x00] = 0x08;
  CHECK(axp2101::batt_pct(kPmu) == 80, "axp2101: battery present -> 0xA4");
  A[0xA4] = 0xFF;
  CHECK(axp2101::batt_pct(kPmu) == -1, "axp2101: out-of-range percentage -> -1");
  a_present = false;
  CHECK(axp2101::batt_pct(kPmu) == -1 && !axp2101::begin(kPmu), "axp2101: no answer -> -1");
  a_present = true;
}

// ------------------------------------------------------------------- BQ25896

// A register file with the watchdog that matters: in host mode, when it
// expires, every register goes back to its power-on value.
static uint8_t C[0x15];
static bool c_present = true;
static int c_writes = 0;
static void c_defaults() {
  memset(C, 0, sizeof C);
  C[0x04] = 0x20;   // ICHG 2048 mA, EN_PUMPX off
  C[0x07] = 0x9D;   // EN_TERM, WATCHDOG 40 s, EN_TIMER, 12 h, JEITA_ISET
}
static void c_watchdog_expires() { if (C[0x07] & 0x30) c_defaults(); }
static bool c_read(uint8_t r, uint8_t* v) { if (!c_present || r >= sizeof C) return false; *v = C[r]; return true; }
static bool c_write(uint8_t r, uint8_t v) { if (!c_present || r >= sizeof C) return false; C[r] = v; c_writes++; return true; }
static const bq25896::Io kChg = { c_read, c_write };

static void test_bq25896(void) {
  c_defaults(); c_present = true;
  CHECK(bq25896::charge_current_ma(kChg) == 2048, "bq25896: power-on fast charge reads 2048 mA");
  const uint8_t timer_before = C[0x07];
  CHECK(bq25896::set_charge_current(kChg, 1000), "bq25896: set answers");
  CHECK(bq25896::charge_current_ma(kChg) == 960 && bq25896::charge_current_ma(kChg) <= 1000 &&
        1000 - bq25896::charge_current_ma(kChg) < 64,
        "bq25896: 1000 mA asked -> 960 mA, the 64 mA step at or below it");
  CHECK((C[0x07] & 0x30) == 0 && (C[0x07] & ~0x30) == (timer_before & ~0x30),
        "bq25896: watchdog off, every other REG07 bit (termination, the safety timer) kept");
  c_watchdog_expires();
  CHECK(bq25896::charge_current_ma(kChg) == 960, "bq25896: with the watchdog off, the current outlives its timeout");
  // Without the watchdog step, the same write would not have lasted.
  c_defaults();
  C[0x04] = 0x0F;
  c_watchdog_expires();
  CHECK(bq25896::charge_current_ma(kChg) == 2048, "bq25896: (the model) a live watchdog restores 2048 mA");
  c_defaults();
  C[0x04] = 0xA0;   // EN_PUMPX set
  bq25896::set_charge_current(kChg, 1000);
  CHECK(C[0x04] == 0x8F, "bq25896: EN_PUMPX kept");
  c_writes = 0;
  CHECK(bq25896::set_charge_current(kChg, 1000) && c_writes == 0, "bq25896: nothing written when already set");
  c_defaults();
  CHECK(bq25896::set_charge_current(kChg, 9000) && bq25896::charge_current_ma(kChg) == 3008,
        "bq25896: clamped to the chip's 3008 mA");
  C[0x04] = 0x7F;   // a code past the chip's range: it charges at 3008 mA
  CHECK(bq25896::charge_current_ma(kChg) == 3008, "bq25896: an out-of-range code reads as the 3008 mA it gives");
  c_present = false;
  CHECK(!bq25896::set_charge_current(kChg, 1000) && bq25896::charge_current_ma(kChg) == -1,
        "bq25896: no answer -> false / -1");
  c_present = true;
}

int main(void) {
  test_provision_fresh();
  test_already_right();
  test_forced_rewrites();
  test_refusals();
  test_failures_midway();
  test_readouts();
  test_profiles();
  test_axp2101();
  test_bq25896();
  if (g_fails) printf("%d FAILED\n", g_fails); else printf("all gauge checks passed\n");
  return g_fails ? 1 : 0;
}
