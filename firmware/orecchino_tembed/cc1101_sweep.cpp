#include "cc1101_sweep.h"
#include "board_tembed.h"
#include <SPI.h>

// CC1101 register / strobe map (datasheet §29)
#define R_IOCFG0    0x02
#define R_FSCTRL1   0x0B
#define R_FREQ2     0x0D
#define R_MDMCFG4   0x10
#define R_MDMCFG2   0x12
#define R_MCSM0     0x18
#define R_FOCCFG    0x19
#define R_AGCCTRL2  0x1B
#define R_FREND1    0x21
#define R_FSCAL3    0x23
#define R_FSCAL2    0x24
#define R_FSCAL1    0x25
#define R_FSCAL0    0x26
#define R_TEST2     0x2C
#define R_TEST1     0x2D
#define R_TEST0     0x2E
#define S_SRES      0x30
#define S_SRX       0x34
#define S_SIDLE     0x36
#define R_PARTNUM   0x30
#define R_VERSION   0x31
#define R_RSSI      0x34
#define R_MARCSTATE 0x35
#define BURST       0x40
#define READ        0x80
#define STATUS      0xC0   // status registers read with burst bit set

static bool s_ok = false, s_tried = false;
static SPIClass s_spi(HSPI);
static const SPISettings CFG(6500000, MSBFIRST, SPI_MODE0);

static inline void cs(bool low) { digitalWrite(PIN_CC_CS, low ? LOW : HIGH); }

static uint8_t strobe(uint8_t s) {
  s_spi.beginTransaction(CFG);
  cs(true);
  uint8_t st = s_spi.transfer(s);
  cs(false);
  s_spi.endTransaction();
  return st;
}
static void wr(uint8_t reg, uint8_t v) {
  s_spi.beginTransaction(CFG);
  cs(true);
  s_spi.transfer(reg);
  s_spi.transfer(v);
  cs(false);
  s_spi.endTransaction();
}
static uint8_t rd_status(uint8_t reg) {
  s_spi.beginTransaction(CFG);
  cs(true);
  s_spi.transfer(reg | STATUS);
  uint8_t v = s_spi.transfer(0);
  cs(false);
  s_spi.endTransaction();
  return v;
}

// Sweep plan: three contiguous tuning ranges, bins allocated by width.
struct Band { uint32_t lo, hi; uint8_t sw0, sw1; };
static const Band BANDS[] = {
  { 300000000UL, 348000000UL, LOW,  HIGH },  // 315 path
  { 387000000UL, 464000000UL, HIGH, HIGH },  // 433 path
  { 779000000UL, 928000000UL, HIGH, LOW  },  // 868/915 path
};
static const int N_BANDS = 3;
static uint32_t s_total_hz = 0;

static void band_of_bin(int i, int* bi, uint32_t* hz) {
  uint64_t pos = (uint64_t)s_total_hz * i / CC_SWEEP_BINS;
  for (int b = 0; b < N_BANDS; b++) {
    uint32_t w = BANDS[b].hi - BANDS[b].lo;
    if (pos < w) { *bi = b; *hz = BANDS[b].lo + (uint32_t)pos + w / (2 * CC_SWEEP_BINS); return; }
    pos -= w;
  }
  *bi = N_BANDS - 1; *hz = BANDS[N_BANDS - 1].hi;
}

uint32_t cc1101_bin_hz(int i) { int b; uint32_t hz; band_of_bin(i, &b, &hz); return hz; }

bool cc1101_sweep_begin() {
  if (s_tried) return s_ok;
  s_tried = true;
  for (int b = 0; b < N_BANDS; b++) s_total_hz += BANDS[b].hi - BANDS[b].lo;

  pinMode(PIN_SD_CS, OUTPUT);  digitalWrite(PIN_SD_CS, HIGH);
  pinMode(PIN_CC_CS, OUTPUT);  digitalWrite(PIN_CC_CS, HIGH);
  pinMode(PIN_CC_SW0, OUTPUT); pinMode(PIN_CC_SW1, OUTPUT);
  s_spi.begin(PIN_SPI_SCK, PIN_SPI_MISO, PIN_SPI_MOSI, -1);

  // Manual reset sequence (datasheet §19.1.2): CS pulse, then SRES.
  cs(true); delayMicroseconds(10); cs(false); delayMicroseconds(40);
  strobe(S_SRES);
  delay(2);
  uint8_t part = rd_status(R_PARTNUM), ver = rd_status(R_VERSION);
  if (part != 0x00 || (ver != 0x14 && ver != 0x04)) return false;  // no chip

  wr(R_IOCFG0,   0x2E);  // GDO0 high-Z
  wr(R_FSCTRL1,  0x06);  // IF 152 kHz
  wr(R_MDMCFG4,  0x0C);  // RX BW 812 kHz — one bin is ~1.2-4.9 MHz anyway
  wr(R_MDMCFG2,  0x30);  // ASK/OOK, no sync — we only want the RSSI
  wr(R_MCSM0,    0x18);  // auto-cal on IDLE->RX, 149 us PO timeout
  wr(R_FOCCFG,   0x16);
  wr(R_AGCCTRL2, 0x07);  // max LNA/DVGA gain: RSSI floor as low as it goes
  wr(R_FREND1,   0x56);
  wr(R_FSCAL3,   0xE9); wr(R_FSCAL2, 0x2A); wr(R_FSCAL1, 0x00); wr(R_FSCAL0, 0x1F);
  wr(R_TEST2,    0x81); wr(R_TEST1,  0x35); wr(R_TEST0,  0x09);
  s_ok = true;
  return true;
}

static void tune(uint32_t hz) {
  uint32_t f = (uint32_t)(((uint64_t)hz << 16) / 26000000ULL);
  s_spi.beginTransaction(CFG);
  cs(true);
  s_spi.transfer(R_FREQ2 | BURST);
  s_spi.transfer((uint8_t)(f >> 16));
  s_spi.transfer((uint8_t)(f >> 8));
  s_spi.transfer((uint8_t)f);
  cs(false);
  s_spi.endTransaction();
}

void cc1101_sweep_chunk(int8_t* bins, int* cursor, int steps) {
  if (!s_ok) return;
  static int cur_band = -1;
  for (int s = 0; s < steps; s++) {
    int i = *cursor, b; uint32_t hz;
    band_of_bin(i, &b, &hz);
    strobe(S_SIDLE);
    if (b != cur_band) {
      cur_band = b;
      digitalWrite(PIN_CC_SW0, BANDS[b].sw0);
      digitalWrite(PIN_CC_SW1, BANDS[b].sw1);
    }
    tune(hz);
    strobe(S_SRX);          // IDLE->RX runs the synth calibration (~720 us)
    delayMicroseconds(850);
    // Two reads ~100 us apart, max-held: catches bursts a single sample misses.
    int8_t r1 = (int8_t)rd_status(R_RSSI);
    delayMicroseconds(100);
    int8_t r2 = (int8_t)rd_status(R_RSSI);
    int8_t raw = r1 > r2 ? r1 : r2;
    int dbm = raw / 2 - 74;
    bins[i] = (int8_t)(dbm < -127 ? -127 : dbm);
    *cursor = (i + 1) % CC_SWEEP_BINS;
  }
}

void cc1101_sweep_stop() {
  if (s_ok) strobe(S_SIDLE);
}
