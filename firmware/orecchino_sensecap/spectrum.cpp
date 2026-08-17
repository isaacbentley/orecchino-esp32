// Spectrum analyzer easter egg, v0: UI mock on synthetic data.
//
// Two panes on the shared 480x480 canvas: 2.4 GHz packet-energy bars per
// Wi-Fi channel (with BLE advertising-channel ticks) over a scrolling
// waterfall, and a 850-930 MHz swept spectrum (128 bins) with peak hold
// over its own waterfall. The sim fakes what the real feeds will produce:
// channel humps + bursts up top, FHSS hoppers, steady sub-GHz carriers and
// an occasional slow chirp below. Amplitudes are 0..255 ~ -115..-45 dBm.
#include "spectrum.h"

#ifdef ORECCHINO_DISPLAY

#include <Arduino_GFX_Library.h>
#include <math.h>

#define RGB565(r, g, b) ((uint16_t)((((r) & 0xF8) << 8) | (((g) & 0xFC) << 3) | ((b) >> 3)))
static const uint16_t C_BG    = RGB565(0x07, 0x09, 0x0E);
static const uint16_t C_TEXT  = RGB565(0xE2, 0xE8, 0xF0);
static const uint16_t C_MUTED = RGB565(0x8A, 0x99, 0xAD);
static const uint16_t C_GRID  = RGB565(0x1A, 0x20, 0x2C);
static const uint16_t C_BLE   = RGB565(0x35, 0xD0, 0xBA);
static const uint16_t C_PEAK  = RGB565(0xE8, 0x9A, 0x4A);

// Geometry: header, 2.4 GHz pane (bars + waterfall), sub-GHz pane
// (trace + waterfall). All panes share x 16..464.
#define PX0        16
#define PW         448
#define A_BASE     160   // 2.4 GHz bar baseline
#define A_H        120
#define A_WF_Y     184
#define A_WF_ROWS  62
#define N_CH       14
#define B_BASE     384   // sub-GHz trace baseline
#define B_H        112
#define B_WF_Y     404
#define B_WF_ROWS  74
#define N_BIN      128   // 850-930 MHz, 0.625 MHz/bin
#define FRAME_MS   80

static uint16_t s_lut[64];

static float   s_a24[N_CH];                  // 2.4 GHz channel level
static float   s_burst24[N_CH];              // decaying burst overlay
static uint8_t s_pk24[N_CH];                 // peak hold
static uint8_t s_wfa[A_WF_ROWS][N_CH];
static int     s_wfa_head;
static bool    s_ble_on[3];

static uint8_t s_swp[N_BIN];                 // current sub-GHz sweep
static float   s_pkb[N_BIN];                 // peak hold (decaying)
static uint8_t s_wfb[B_WF_ROWS][N_BIN];
static int     s_wfb_head;
struct Hopper { int bin; int life; float amp; };
static Hopper   s_hop[4];
static bool     s_chirp_on;
static float    s_chirp_pos;
static uint32_t s_chirp_next;
static uint32_t s_t0, s_last_frame;

static void build_lut() {
  // black -> violet -> magenta -> orange -> yellow -> white ("inferno"-ish)
  static const uint8_t A[7][3] = {
    {0, 0, 4}, {28, 8, 64}, {122, 28, 96}, {204, 66, 48},
    {246, 146, 28}, {252, 220, 108}, {255, 255, 236}
  };
  for (int i = 0; i < 64; i++) {
    float f = i * 6.0f / 63.0f;
    int k = (int)f;
    if (k > 5) k = 5;
    float u = f - k;
    uint8_t r = (uint8_t)(A[k][0] + (A[k + 1][0] - A[k][0]) * u);
    uint8_t g = (uint8_t)(A[k][1] + (A[k + 1][1] - A[k][1]) * u);
    uint8_t b = (uint8_t)(A[k][2] + (A[k + 1][2] - A[k][2]) * u);
    s_lut[i] = RGB565(r, g, b);
  }
}

static inline int mhz_bin(float mhz) { return (int)((mhz - 850.0f) / 0.625f + 0.5f); }

static void add_peak(uint8_t* v, int n, float c, float amp, float w) {
  int lo = (int)(c - 3 * w), hi = (int)(c + 3 * w) + 1;
  if (lo < 0) lo = 0;
  if (hi > n - 1) hi = n - 1;
  for (int b = lo; b <= hi; b++) {
    float d = (b - c) / w;
    int nv = v[b] + (int)(amp * expf(-d * d));
    v[b] = nv > 255 ? 255 : (uint8_t)nv;
  }
}

void spectrum_reset(uint32_t now) {
  build_lut();
  memset(s_a24, 0, sizeof(s_a24));
  memset(s_burst24, 0, sizeof(s_burst24));
  memset(s_pk24, 0, sizeof(s_pk24));
  memset(s_wfa, 0, sizeof(s_wfa));
  memset(s_swp, 0, sizeof(s_swp));
  memset(s_pkb, 0, sizeof(s_pkb));
  memset(s_wfb, 0, sizeof(s_wfb));
  s_wfa_head = s_wfb_head = 0;
  for (auto& h : s_hop) h = {(int)random(mhz_bin(902), mhz_bin(928)), (int)random(1, 4), 0};
  s_chirp_on = false;
  s_chirp_next = now + 4000;
  s_t0 = now;
  s_last_frame = 0;
}

static void step_sim(uint32_t now) {
  float t = (now - s_t0) * 0.001f;

  // --- sub-GHz sweep: noise floor + steady carriers + FHSS + rare chirp
  for (int i = 0; i < N_BIN; i++) {
    int v = 16 + (int)random(0, 10) + (int)(6.0f * sinf(i * 0.11f + t * 0.9f));
    s_swp[i] = v < 0 ? 0 : (uint8_t)v;
  }
  add_peak(s_swp, N_BIN, mhz_bin(868.1f), 100 + 40 * sinf(t * 0.7f), 1.0f);
  add_peak(s_swp, N_BIN, mhz_bin(869.5f), 70 + 30 * sinf(t * 1.3f + 2), 1.0f);
  for (auto& h : s_hop) {
    if (--h.life <= 0) {
      h.bin = (int)random(mhz_bin(902), mhz_bin(928));
      h.life = (int)random(2, 5);
      h.amp = 150 + random(0, 80);
    }
    add_peak(s_swp, N_BIN, h.bin, h.amp, 1.2f);
  }
  if (s_chirp_on) {
    add_peak(s_swp, N_BIN, s_chirp_pos, 210, 2.5f);
    s_chirp_pos += 4.0f;
    if (s_chirp_pos > N_BIN + 8) {
      s_chirp_on = false;
      s_chirp_next = now + 8000 + random(0, 9000);
    }
  } else if (now >= s_chirp_next) {
    s_chirp_on = true;
    s_chirp_pos = -8;
  }
  s_wfb_head = (s_wfb_head + 1) % B_WF_ROWS;
  memcpy(s_wfb[s_wfb_head], s_swp, N_BIN);
  for (int i = 0; i < N_BIN; i++) {
    if (s_swp[i] > s_pkb[i]) s_pkb[i] = s_swp[i];
    else s_pkb[i] -= 0.4f;
  }

  // --- 2.4 GHz: AP humps on 1/6/11, adjacent bleed, sporadic bursts
  static const float PH[3] = {0.0f, 2.1f, 4.2f};
  float hump[N_CH] = {0};
  for (int k = 0; k < 3; k++) {
    int c = k * 5;  // channels 1, 6, 11
    float a = 90 + 50 * sinf(t * (0.5f + 0.2f * k) + PH[k]) + random(0, 30);
    hump[c] += a;
    if (c > 0) hump[c - 1] += a * 0.45f;
    if (c < N_CH - 1) hump[c + 1] += a * 0.45f;
  }
  for (int i = 0; i < N_CH; i++) {
    s_burst24[i] *= 0.72f;
    if (random(0, 100) < 2) s_burst24[i] += 140 + random(0, 80);
    float v = 15 + random(0, 12) + hump[i] + s_burst24[i];
    s_a24[i] = v > 255 ? 255 : v;
    uint8_t u = (uint8_t)s_a24[i];
    if (u > s_pk24[i]) s_pk24[i] = u;
    else if (s_pk24[i] > 1) s_pk24[i] -= 2;
  }
  s_wfa_head = (s_wfa_head + 1) % A_WF_ROWS;
  for (int i = 0; i < N_CH; i++) s_wfa[s_wfa_head][i] = (uint8_t)s_a24[i];
  for (int k = 0; k < 3; k++)
    if (random(0, 100) < 25) s_ble_on[k] = !s_ble_on[k];
}

static void draw(Arduino_Canvas* cv) {
  cv->fillScreen(C_BG);
  cv->setFont(nullptr);

  cv->setTextSize(2);
  cv->setTextColor(C_TEXT);
  cv->setCursor(PX0, 4);
  cv->print("RF SPECTRUM");
  cv->setTextSize(1);
  cv->setTextColor(C_MUTED);
  cv->setCursor(464 - 22 * 6, 8);
  cv->print("SIM - press btn: exit");

  // ---- 2.4 GHz pane
  cv->setCursor(PX0, 28);
  cv->print("2.4 GHz  Wi-Fi ch 1-14 / BLE adv");
  for (int i = 0; i < N_CH; i++) {
    int x = PX0 + (i * PW) / N_CH + 3;
    int v = (int)s_a24[i];
    int h = v * A_H / 255;
    if (h > 0) {
      cv->fillRect(x, A_BASE - h, 26, h, s_lut[10 + (v * 53) / 255]);
      if (h > 2) cv->fillRect(x, A_BASE - h, 26, 2, s_lut[56]);
    }
    int ph = s_pk24[i] * A_H / 255;
    if (ph > 1) cv->fillRect(x, A_BASE - ph - 1, 26, 2, C_PEAK);
    cv->setTextColor(C_MUTED);
    cv->setCursor(x + (i < 9 ? 10 : 7), A_BASE + 4);
    cv->print(i + 1);
  }
  // BLE advertising channels 37/38/39 at 2402/2426/2480 MHz on the band axis
  static const float BLE_MHZ[3] = {2402, 2426, 2480};
  for (int k = 0; k < 3; k++) {
    int x = PX0 + (int)((BLE_MHZ[k] - 2400.0f) * PW / 83.5f);
    cv->fillRect(x - 2, A_BASE + 16, 5, 5, s_ble_on[k] ? C_BLE : C_GRID);
  }
  for (int r = 0; r < A_WF_ROWS; r++) {
    const uint8_t* row = s_wfa[(s_wfa_head - r + A_WF_ROWS) % A_WF_ROWS];
    int y = A_WF_Y + r;
    for (int i = 0; i < N_CH; i++)
      cv->fillRect(PX0 + (i * PW) / N_CH + 3, y, 26, 1, s_lut[row[i] >> 2]);
  }

  cv->drawFastHLine(0, 252, 480, C_GRID);

  // ---- sub-GHz pane
  cv->setTextColor(C_MUTED);
  cv->setCursor(PX0, 258);
  cv->print("850-930 MHz sweep  0.625 MHz/bin");
  for (int g = 1; g < 4; g++)  // verticals at 870/890/910
    cv->drawFastVLine(PX0 + g * PW / 4, B_BASE - B_H, B_H, C_GRID);
  for (int g = 1; g < 4; g++)
    cv->drawFastHLine(PX0, B_BASE - g * B_H / 4, PW, C_GRID);
  for (int i = 0; i < N_BIN; i++) {
    int x = PX0 + (i * PW) / N_BIN;
    int v = s_swp[i];
    int h = v * B_H / 255;
    if (h > 0) cv->fillRect(x, B_BASE - h, 3, h, s_lut[8 + (v * 55) / 255]);
    int ph = (int)s_pkb[i] * B_H / 255;
    if (ph > 1) cv->fillRect(x, B_BASE - ph - 1, 3, 1, C_PEAK);
  }
  static const char* FL[5] = {"850", "870", "890", "910", "930"};
  for (int g = 0; g < 5; g++) {
    int x = PX0 + g * PW / 4 - (g == 0 ? 0 : (g == 4 ? 18 : 9));
    cv->setCursor(x, B_BASE + 4);
    cv->print(FL[g]);
  }
  for (int r = 0; r < B_WF_ROWS; r++) {
    const uint8_t* row = s_wfb[(s_wfb_head - r + B_WF_ROWS) % B_WF_ROWS];
    int y = B_WF_Y + r;
    for (int i = 0; i < N_BIN; i++)
      cv->fillRect(PX0 + (i * PW) / N_BIN, y, 3, 1, s_lut[row[i] >> 2]);
  }

  cv->flush();
}

void spectrum_tick(Arduino_Canvas* cv, uint32_t now) {
  if (now - s_last_frame < FRAME_MS) return;
  s_last_frame = now;
  step_sim(now);
  draw(cv);
}

#else  // !ORECCHINO_DISPLAY

void spectrum_reset(uint32_t) {}
void spectrum_tick(Arduino_Canvas*, uint32_t) {}

#endif
