// The SenseCAP driver (sx1262_sweep.cpp there) with the control lines on
// plain GPIO instead of an I2C expander — so a bin costs ~0.4 ms, not 1.4.
#include "sx1262_sweep.h"
#include "board_t5.h"
#include <SPI.h>

// SX126x command opcodes (datasheet ch. 13)
#define OP_SET_STANDBY    0x80
#define OP_SET_RX         0x82
#define OP_SET_RF_FREQ    0x86
#define OP_CALIBRATE      0x89
#define OP_SET_PKT_TYPE   0x8A
#define OP_SET_MOD_PARAMS 0x8B
#define OP_SET_DIO2_RF_SW 0x9D
#define OP_SET_DIO3_TCXO  0x97
#define OP_CAL_IMAGE      0x98
#define OP_GET_STATUS     0xC0
#define OP_GET_RSSI_INST  0x15
#define OP_GET_DEV_ERRORS 0x17
#define OP_CLR_DEV_ERRORS 0x07

static bool s_ok = false, s_tried = false;
static uint32_t s_lo = SX_SWEEP_LO_HZ, s_hi = SX_SWEEP_HI_HZ;
static SPIClass s_spi(FSPI);
static const SPISettings SPI_CFG(4000000, MSBFIRST, SPI_MODE0);
static uint8_t s_last_op_status = 0;

static bool wait_busy(uint32_t timeout_ms = 10) {
  uint32_t t0 = millis();
  while (digitalRead(PIN_LORA_BUSY) == HIGH) {
    if (millis() - t0 > timeout_ms) {
      Serial.printf("[SX1262] wait_busy TIMEOUT (%u ms, BUSY=1)\n", timeout_ms);
      return false;
    }
  }
  return true;
}

static bool xfer(uint8_t op, const uint8_t* args, int n_args,
                 uint8_t* out, int n_out, bool wait = true) {
  if (wait && !wait_busy()) {
    Serial.printf("[SX1262] BUSY wait failed before op 0x%02X\n", op);
    return false;
  }
  digitalWrite(PIN_LORA_CS, LOW);
  s_spi.beginTransaction(SPI_CFG);
  s_last_op_status = s_spi.transfer(op);
  for (int i = 0; i < n_args; i++) s_spi.transfer(args[i]);
  for (int i = 0; i < n_out; i++) out[i] = s_spi.transfer(0);
  s_spi.endTransaction();
  digitalWrite(PIN_LORA_CS, HIGH);
  return true;
}
static bool cmd(uint8_t op, const uint8_t* args, int n) {
  return xfer(op, args, n, nullptr, 0);
}

static void hard_reset() {
  digitalWrite(PIN_LORA_RST, LOW);
  delay(5);
  digitalWrite(PIN_LORA_RST, HIGH);
  delay(10);
  wait_busy(100);
}

static const uint8_t STDBY_RC[1]   = {0x00};
static const uint8_t STDBY_XOSC[1] = {0x01};

void sx1262_sweep_reset_tried() {
  s_tried = false;
  s_ok = false;
}

bool sx1262_sweep_begin() {
  if (s_tried) return s_ok;
  s_tried = true;

  Serial.println("[SX1262] Initializing LoRa RF sweep driver...");

  // Disengage ESP32-S3 RTC pad hold on reset line if waking from sleep
  gpio_hold_dis((gpio_num_t)PIN_LORA_RST);
  gpio_deep_sleep_hold_dis();

  pinMode(PIN_SD_CS, OUTPUT);    digitalWrite(PIN_SD_CS, HIGH);
  pinMode(PIN_LORA_CS, OUTPUT);  digitalWrite(PIN_LORA_CS, HIGH);
  pinMode(PIN_LORA_RST, OUTPUT); digitalWrite(PIN_LORA_RST, HIGH);
  pinMode(PIN_LORA_BUSY, INPUT);
  pinMode(PIN_LORA_IRQ, INPUT);

  s_spi.begin(PIN_SPI_SCLK, PIN_SPI_MISO, PIN_SPI_MOSI, -1);

  Serial.printf("[SX1262] Pre-reset: BUSY=%d, IRQ=%d\n",
                digitalRead(PIN_LORA_BUSY), digitalRead(PIN_LORA_IRQ));

  hard_reset();

  Serial.printf("[SX1262] Post-reset: BUSY=%d, IRQ=%d\n",
                digitalRead(PIN_LORA_BUSY), digitalRead(PIN_LORA_IRQ));

  bool stdby_cmd = cmd(OP_SET_STANDBY, STDBY_RC, 1);
  uint8_t st = 0;
  bool st_ok = xfer(OP_GET_STATUS, nullptr, 0, &st, 1);
  Serial.printf("[SX1262] Probe: stdby_cmd=%d, get_st_ok=%d, st_data=0x%02X, op_ret=0x%02X\n",
                stdby_cmd, st_ok, st, s_last_op_status);

  // In SX126x, status may be returned during NOP data byte (st) or during opcode (s_last_op_status)
  uint8_t chip_status = (st != 0x00 && st != 0xFF) ? st : s_last_op_status;
  if (chip_status == 0x00 || chip_status == 0xFF) {
    Serial.printf("[SX1262] No radio response detected (status=0x%02X)\n", chip_status);
    return false;
  }
  Serial.printf("[SX1262] Radio detected! Status: 0x%02X (mode=%d, cmd=%d)\n",
                chip_status, (chip_status >> 4) & 0x07, (chip_status >> 1) & 0x07);

  // 1. Set regulator to DCDC (LilyGO T5 S3 has DCDC inductor)
  static const uint8_t REG_DCDC[1] = {0x01};
  cmd(0x96 /* OP_SET_REGULATOR_MODE */, REG_DCDC, 1);

  // 2. Clear sticky errors before configuring oscillator
  static const uint8_t CLR[2] = {0x00, 0x00};
  cmd(OP_CLR_DEV_ERRORS, CLR, 2);

  // 3. Try configuring TCXO on DIO3 (10 ms startup delay = 640 * 15.625 us = 0x000280)
  // LilyGO factory examples use RadioLib default tcxoVoltage = 1.6V (code 0x00).
  // We test 1.6V, 1.8V (0x02), and 2.4V (0x04) to guarantee oscillator lock.
  const uint8_t tcxo_voltages[] = {0x00 /* 1.6V */, 0x02 /* 1.8V */, 0x04 /* 2.4V */};
  bool xosc_ready = false;
  uint8_t cur_mode = 0;

  for (uint8_t v_code : tcxo_voltages) {
    cmd(OP_SET_STANDBY, STDBY_RC, 1);
    uint8_t tcxo_cmd[4] = {v_code, 0x00, 0x02, 0x80};
    cmd(OP_SET_DIO3_TCXO, tcxo_cmd, 4);
    cmd(OP_SET_STANDBY, STDBY_XOSC, 1);
    delay(15);
    wait_busy(50);

    uint8_t chk_st = 0;
    xfer(OP_GET_STATUS, nullptr, 0, &chk_st, 1);
    cur_mode = (chk_st >> 4) & 0x07;
    Serial.printf("[SX1262] TCXO test (voltage code 0x%02X): status=0x%02X (mode=%d, cmd=%d)\n",
                  v_code, chk_st, cur_mode, (chk_st >> 1) & 0x07);
    if (cur_mode == 3 /* STDBY_XOSC */) {
      xosc_ready = true;
      Serial.printf("[SX1262] TCXO locked successfully with voltage code 0x%02X!\n", v_code);
      break;
    }
  }

  if (!xosc_ready) {
    // If TCXO did not start on any voltage, try standard crystal (XTAL)
    Serial.println("[SX1262] TCXO failed to lock; attempting XTAL fallback...");
    hard_reset();
    cmd(OP_SET_STANDBY, STDBY_RC, 1);
    cmd(OP_SET_STANDBY, STDBY_XOSC, 1);
    delay(15);
    wait_busy(50);
    uint8_t chk_st = 0;
    xfer(OP_GET_STATUS, nullptr, 0, &chk_st, 1);
    cur_mode = (chk_st >> 4) & 0x07;
    Serial.printf("[SX1262] XTAL fallback status: 0x%02X (mode=%d)\n", chk_st, cur_mode);
  }

  // 4. Clear any errors accumulated during clock start, then calibrate
  cmd(OP_CLR_DEV_ERRORS, CLR, 2);
  static const uint8_t CAL_ALL[1] = {0x7F};
  cmd(OP_CALIBRATE, CAL_ALL, 1);
  delay(10);
  wait_busy(100);

  uint8_t err[3] = {0};  // status, errors MSB, errors LSB
  xfer(OP_GET_DEV_ERRORS, nullptr, 0, err, 3);
  Serial.printf("[SX1262] Device errors after cal: 0x%02X 0x%02X 0x%02X\n", err[0], err[1], err[2]);

  // 5. RF Switch on DIO2
  static const uint8_t RFSW[1] = {0x01};  // DIO2 drives the antenna switch
  cmd(OP_SET_DIO2_RF_SW, RFSW, 1);

  // 6. Modulation & Packet Type
  static const uint8_t GFSK[1] = {0x00};
  cmd(OP_SET_PKT_TYPE, GFSK, 1);
  // 250 kb/s, no shaping, 467 kHz RX bandwidth (~one 625 kHz bin), 50 kHz fdev
  static const uint8_t MOD[8] = {0x00, 0x10, 0x00, 0x00, 0x09, 0x00, 0xCC, 0xCD};
  cmd(OP_SET_MOD_PARAMS, MOD, 8);

  // 7. Image calibration for 848-932 MHz (MHz/4: 212, 233)
  static const uint8_t IMG[2] = {212, 233};
  cmd(OP_CAL_IMAGE, IMG, 2);
  wait_busy(50);

  // 8. Park in XOSC standby: per-bin hops then skip oscillator restart
  cmd(OP_CLR_DEV_ERRORS, CLR, 2);
  cmd(OP_SET_STANDBY, STDBY_XOSC, 1);
  wait_busy(20);

  uint8_t final_st = 0;
  xfer(OP_GET_STATUS, nullptr, 0, &final_st, 1);
  s_ok = (((final_st >> 4) & 0x07) == 3);
  Serial.printf("[SX1262] Sweep initialization %s! (status=0x%02X, mode=%d)\n",
                s_ok ? "COMPLETE (READY)" : "FAILED (not in XOSC)", final_st, (final_st >> 4) & 0x07);
  return s_ok;
}

void sx1262_sweep_set_span(uint32_t lo_hz, uint32_t hi_hz, int n_bins) {
  if (hi_hz <= lo_hz || n_bins <= 0) return;
  s_lo = lo_hz;
  s_hi = hi_hz;
  if (!s_ok) return;
  // Widest GFSK RX bandwidth that fits one bin — narrower RBW also drops
  // the noise floor ~10*log10(BW), so zooming in gains real sensitivity.
  static const struct { uint8_t code; uint32_t hz; } BW[] = {
    {0x09, 467000}, {0x0A, 234300}, {0x0B, 117300}, {0x0C, 58600},
    {0x0D, 29300},  {0x0E, 14600},  {0x0F, 7300},   {0x1F, 4800},
  };
  uint32_t bin = (hi_hz - lo_hz) / n_bins;
  uint8_t code = BW[7].code;
  for (auto& b : BW) {
    if (b.hz <= bin) { code = b.code; break; }
  }
  cmd(OP_SET_STANDBY, STDBY_XOSC, 1);
  uint8_t mod[8] = {0x00, 0x10, 0x00, 0x00, code, 0x00, 0xCC, 0xCD};
  cmd(OP_SET_MOD_PARAMS, mod, 8);
}

void sx1262_sweep_chunk(int8_t* bins, int n, int* cursor, int steps) {
  if (!s_ok || n <= 0 || !cursor || !bins) return;
  static const uint8_t RX_CONT[3] = {0xFF, 0xFF, 0xFF};
  const uint64_t span = s_hi - s_lo;

  for (int s = 0; s < steps; s++) {
    int i = *cursor;
    uint32_t hz = s_lo + (uint32_t)((span * i + span / 2) / n);
    uint32_t frf = (uint32_t)(((uint64_t)hz << 25) / 32000000ULL);
    uint8_t fr[4] = {(uint8_t)(frf >> 24), (uint8_t)(frf >> 16),
                     (uint8_t)(frf >> 8), (uint8_t)frf};

    // On high-speed ESP32-S3 (240MHz), wait for BUSY so radio PLL locks and settles
    xfer(OP_SET_STANDBY, STDBY_XOSC, 1, nullptr, 0, true);
    xfer(OP_SET_RF_FREQ, fr, 4, nullptr, 0, true);
    xfer(OP_SET_RX, RX_CONT, 3, nullptr, 0, true);
    delayMicroseconds(200);  // RX start + settle

    // Two RSSI reads ~150 us apart, max-held: catches FHSS/TDMA bursts
    uint8_t r1[2] = {0}, r2[2] = {0};  // status, rssi
    xfer(OP_GET_RSSI_INST, nullptr, 0, r1, 2, true);
    delayMicroseconds(150);
    xfer(OP_GET_RSSI_INST, nullptr, 0, r2, 2, true);

    if (s == 0) {
      Serial.printf("[SWEEP] bin %d (%u MHz): r1=[st=0x%02X, raw=%u], r2=[st=0x%02X, raw=%u]\n",
                    i, hz / 1000000UL, r1[0], r1[1], r2[0], r2[1]);
    }

    uint8_t raw = r1[1] < r2[1] ? r1[1] : r2[1];  // lower raw = stronger
    int dbm = -(int)raw / 2;
    bins[i] = (int8_t)(dbm < -127 ? -127 : dbm > 0 ? 0 : dbm);
    *cursor = (i + 1) % n;
  }
}

void sx1262_sweep_stop() {
  if (s_ok) cmd(OP_SET_STANDBY, STDBY_RC, 1);
}
