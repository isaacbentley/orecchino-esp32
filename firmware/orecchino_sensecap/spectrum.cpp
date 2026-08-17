// Spectrum analyzer easter egg, live version.
//
// Two panes on the shared 480x480 canvas.
//   2.4 GHz: per-Wi-Fi-channel packet energy (avg RSSI of frames heard while
//   the sniffer dwells there; the sketch sweeps ch 1-13 evenly in this mode
//   with the BLE scanner paused for clean airtime), over a scrolling
//   waterfall. Packet energy, not an FFT — quiet channels decay, loud glow.
//   Sub-GHz: true swept spectrum from the SX1262 — 128 bins, tap-to-zoom
//   spans from 80 MHz down to 1.25 MHz with RBW to match, ~2.7 sweeps/s,
//   peak hold, and a waterfall row per completed sweep. The display window
//   auto-ranges in dBm per sweep, since the floor drops with each zoom.
// The 2.4 GHz pane maps a fixed -115..-45 dBm window (RBW never changes).
#include "spectrum.h"

#ifdef ORECCHINO_DISPLAY

#include <Arduino_GFX_Library.h>
#include <math.h>
#include "sx1262_sweep.h"

#define RGB565(r, g, b) ((uint16_t)((((r) & 0xF8) << 8) | (((g) & 0xFC) << 3) | ((b) >> 3)))
static const uint16_t C_BG    = RGB565(0x07, 0x09, 0x0E);
static const uint16_t C_TEXT  = RGB565(0xE2, 0xE8, 0xF0);
static const uint16_t C_MUTED = RGB565(0x8A, 0x99, 0xAD);
static const uint16_t C_GRID  = RGB565(0x1A, 0x20, 0x2C);
static const uint16_t C_PEAK  = RGB565(0xE8, 0x9A, 0x4A);
static const uint16_t C_DANGER = RGB565(0xE0, 0x5A, 0x5A);

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
// 28 bins x ~1.35 ms (incl. the max-hold double RSSI read) = ~38 ms of
// sweep per 80 ms frame: a full 128-bin pass every ~5 frames (~2.7
// sweeps/s). C-UAS is paused in this mode, so the loop has the time.
#define SWEEP_STEPS_PER_FRAME 28
// Zoom: span/4 per level, 80 MHz down to 1.25 MHz; RBW follows in the
// driver (467 kHz down to 9.7 kHz bins at max zoom).
#define ZOOM_MAX   3
#define BAND_LO_HZ 850000000UL
#define BAND_HI_HZ 930000000UL

static uint16_t s_lut[64];

// ---- live feeds (written from Wi-Fi / NimBLE task context)
static volatile bool     s_on = false;
static volatile int32_t  s_wsum[N_CH + 1];  // indexed by channel 1..14
static volatile uint16_t s_wcnt[N_CH + 1];
static volatile uint8_t  s_dwell_ch = 0;

// ---- view state
static float   s_a24[N_CH];                  // 2.4 GHz channel level
static uint8_t s_pk24[N_CH];                 // peak hold
static uint8_t s_wfa[A_WF_ROWS][N_CH];
static int     s_wfa_head;

static int8_t  s_swp[N_BIN];                 // current sub-GHz sweep, dBm
static float   s_pkb[N_BIN];                 // peak hold, dBm (decaying)
static int8_t  s_wfb[B_WF_ROWS][N_BIN];      // waterfall history, dBm
static int     s_wfb_head;
static int     s_sweep_cursor;
static bool    s_radio_ok;
static uint32_t s_last_frame;
static uint8_t  s_zoom;                      // 0..ZOOM_MAX
static uint32_t s_center_hz = 890000000UL;

// Auto-ranging reference levels: narrower RBW drops the noise floor ~6 dB
// per zoom level, so a fixed display window buries the trace. Each
// completed sweep re-derives the window (floor = 15th percentile - 4 dB,
// top = peak + 6 dB, >= 36 dB total) and the display eases toward it; a
// span change snaps immediately. The waterfall stores dBm too, so history
// rescales with the window instead of freezing at an old calibration.
static float s_ref_lo = -115, s_ref_hi = -45;
static bool  s_ref_snap = true;

static inline uint8_t sub_lvl(int dbm) {
  int v = (int)((dbm - s_ref_lo) * 255.0f / (s_ref_hi - s_ref_lo));
  return v < 0 ? 0 : (v > 255 ? 255 : (uint8_t)v);
}

static void clear_sub_data() {
  memset(s_swp, 0x81, sizeof(s_swp));        // 0x81 = -127 dBm
  memset(s_wfb, 0x81, sizeof(s_wfb));
  for (int i = 0; i < N_BIN; i++) s_pkb[i] = -127;
  s_wfb_head = 0;
  s_sweep_cursor = 0;
  s_ref_snap = true;
}

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

// ---- feed entry points (sketch side)

bool spectrum_active() { return s_on; }

void spectrum_feed_wifi(uint8_t chan, int8_t rssi) {
  if (!s_on || chan < 1 || chan > N_CH) return;
  s_wsum[chan] += rssi;
  s_wcnt[chan]++;
}

void spectrum_set_wifi_channel(uint8_t chan) { s_dwell_ch = chan; }

// ---- sub-GHz zoom

static uint32_t span_hz() { return 80000000UL >> (2 * s_zoom); }  // /4 per level

static void apply_span() {
  uint32_t half = span_hz() / 2;
  if (s_center_hz < BAND_LO_HZ + half) s_center_hz = BAND_LO_HZ + half;
  if (s_center_hz > BAND_HI_HZ - half) s_center_hz = BAND_HI_HZ - half;
  sx1262_sweep_set_span(s_center_hz - half, s_center_hz + half, N_BIN);
  // Old span's data is meaningless at the new tuning — start clean.
  clear_sub_data();
}

void spectrum_tap(int x, int y) {
  if (!s_on || !s_radio_ok) return;
  // [-] control in the sub-GHz header: zoom back out
  if (x >= 414 && y >= 246 && y <= 276) {
    if (s_zoom) {
      s_zoom--;
      apply_span();
    }
    return;
  }
  // tap in the trace: zoom in x4 on that frequency (re-center at max zoom)
  if (y >= B_BASE - B_H && y <= B_BASE && x >= PX0 && x < PX0 + PW) {
    uint32_t sp = span_hz();
    uint32_t lo = s_center_hz - sp / 2;
    s_center_hz = lo + (uint32_t)((uint64_t)(x - PX0) * sp / PW);
    if (s_zoom < ZOOM_MAX) s_zoom++;
    apply_span();
  }
}

// ---- lifecycle

void spectrum_reset(uint32_t now) {
  build_lut();
  memset(s_a24, 0, sizeof(s_a24));
  memset(s_pk24, 0, sizeof(s_pk24));
  memset(s_wfa, 0, sizeof(s_wfa));
  clear_sub_data();
  s_ref_lo = -115;
  s_ref_hi = -45;
  s_wfa_head = 0;
  for (int i = 0; i <= N_CH; i++) { s_wsum[i] = 0; s_wcnt[i] = 0; }
  s_last_frame = 0;
  s_radio_ok = sx1262_sweep_begin();
  s_zoom = 0;
  s_center_hz = 890000000UL;
  if (s_radio_ok) apply_span();
  s_on = true;
  (void)now;
}

void spectrum_stop() {
  s_on = false;
  sx1262_sweep_stop();
}

// ---- per-frame update

static inline uint8_t rssi_level(int dbm) {
  int v = (dbm + 115) * 255 / 70;  // -115..-45 dBm -> 0..255
  return v < 0 ? 0 : (v > 255 ? 255 : (uint8_t)v);
}

static void step_live() {
  // 2.4 GHz: drain the accumulators. Rise instantly, fall slowly — the
  // sniffer only hears one channel at a time, so off-dwell bars persist.
  for (int ch = 1; ch <= N_CH; ch++) {
    int32_t sum = s_wsum[ch];
    uint16_t cnt = s_wcnt[ch];
    s_wsum[ch] = 0;
    s_wcnt[ch] = 0;
    float* a = &s_a24[ch - 1];
    if (cnt) {
      uint8_t lvl = rssi_level((int)(sum / (int32_t)cnt));
      if (lvl > *a) *a = lvl;
      else *a = *a * 0.90f + lvl * 0.10f;
    } else if (ch == s_dwell_ch) {
      *a *= 0.80f;  // we are listening right there and it is silent
    } else {
      *a *= 0.985f;  // stale — decay gently until the sweep returns
    }
    uint8_t u = (uint8_t)s_a24[ch - 1];
    if (u > s_pk24[ch - 1]) s_pk24[ch - 1] = u;
    else if (s_pk24[ch - 1] > 0) s_pk24[ch - 1]--;
  }
  s_wfa_head = (s_wfa_head + 1) % A_WF_ROWS;
  for (int i = 0; i < N_CH; i++) s_wfa[s_wfa_head][i] = (uint8_t)s_a24[i];

  // Sub-GHz: advance the real sweep; push a waterfall row per completed pass.
  if (s_radio_ok) {
    int before = s_sweep_cursor;
    sx1262_sweep_chunk(s_swp, N_BIN, &s_sweep_cursor, SWEEP_STEPS_PER_FRAME);
    if (s_sweep_cursor < before) {  // wrapped: one full sweep done
      s_wfb_head = (s_wfb_head + 1) % B_WF_ROWS;
      memcpy(s_wfb[s_wfb_head], s_swp, N_BIN);
      // Auto-range from this completed sweep: histogram over the chip's
      // -127..0 dBm range, floor at the 15th percentile.
      uint8_t hist[128] = {0};
      int peak = -127;
      for (int i = 0; i < N_BIN; i++) {
        hist[s_swp[i] + 127]++;
        if (s_swp[i] > peak) peak = s_swp[i];
      }
      int cum = 0, floor_dbm = -127;
      for (int d = 0; d < 128; d++) {
        cum += hist[d];
        if (cum >= N_BIN * 15 / 100) { floor_dbm = d - 127; break; }
      }
      float tlo = floor_dbm - 4;
      float thi = peak + 6 > 0 ? 0 : peak + 6;
      if (thi - tlo < 36) thi = tlo + 36;  // keep noise texture ~10% tall
      if (s_ref_snap) {
        s_ref_snap = false;
        s_ref_lo = tlo;
        s_ref_hi = thi;
      } else {  // ease over ~3 sweeps so the window doesn't pump
        s_ref_lo += (tlo - s_ref_lo) * 0.3f;
        s_ref_hi += (thi - s_ref_hi) * 0.3f;
      }
    }
    for (int i = 0; i < N_BIN; i++) {
      if (s_swp[i] > s_pkb[i]) s_pkb[i] = s_swp[i];
      else s_pkb[i] -= 0.05f;  // ~0.6 dB/s peak-hold decay
    }
  }
}

// ---- render

static void draw(Arduino_Canvas* cv) {
  cv->fillScreen(C_BG);
  cv->setFont(nullptr);

  cv->setTextSize(2);
  cv->setTextColor(C_TEXT);
  cv->setCursor(PX0, 4);
  cv->print("RF SPECTRUM");
  cv->setTextSize(1);
  cv->setTextColor(C_MUTED);
  cv->setCursor(464 - 19 * 6, 8);
  cv->print("press btn to exit");

  // ---- 2.4 GHz pane
  cv->setCursor(PX0, 28);
  cv->print("2.4 GHz  Wi-Fi packet energy  ch 1-14");
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
  for (int r = 0; r < A_WF_ROWS; r++) {
    const uint8_t* row = s_wfa[(s_wfa_head - r + A_WF_ROWS) % A_WF_ROWS];
    int y = A_WF_Y + r;
    for (int i = 0; i < N_CH; i++)
      cv->fillRect(PX0 + (i * PW) / N_CH + 3, y, 26, 1, s_lut[row[i] >> 2]);
  }

  cv->drawFastHLine(0, 252, 480, C_GRID);

  // ---- sub-GHz pane
  uint32_t sp = span_hz();
  uint32_t lo = s_center_hz - sp / 2;
  float bin_khz = sp / (float)N_BIN / 1000.0f;
  char hb[48];
  snprintf(hb, sizeof(hb), "%.1f-%.1f MHz  %.*f kHz/bin  tap:zoom",
           lo / 1e6f, (lo + sp) / 1e6f, bin_khz < 100 ? 1 : 0, bin_khz);
  cv->setTextColor(C_MUTED);
  cv->setCursor(PX0, 258);
  cv->print(hb);
  // [-] zoom-out control (dim at full span)
  cv->drawRoundRect(424, 253, 36, 17, 3, s_zoom ? C_TEXT : C_GRID);
  cv->setTextColor(s_zoom ? C_TEXT : C_GRID);
  cv->setCursor(424 + 15, 258);
  cv->print("-");
  for (int g = 1; g < 4; g++)  // verticals at 870/890/910
    cv->drawFastVLine(PX0 + g * PW / 4, B_BASE - B_H, B_H, C_GRID);
  for (int g = 1; g < 4; g++)
    cv->drawFastHLine(PX0, B_BASE - g * B_H / 4, PW, C_GRID);
  if (!s_radio_ok) {
    cv->setTextColor(C_DANGER);
    cv->setCursor(PX0 + 140, B_BASE - B_H / 2);
    cv->print("SX1262 not responding");
  } else {
    for (int i = 0; i < N_BIN; i++) {
      int x = PX0 + (i * PW) / N_BIN;
      int v = sub_lvl(s_swp[i]);
      int h = v * B_H / 255;
      if (h > 0) cv->fillRect(x, B_BASE - h, 3, h, s_lut[8 + (v * 55) / 255]);
      int ph = sub_lvl((int)s_pkb[i]) * B_H / 255;
      if (ph > 1) cv->fillRect(x, B_BASE - ph - 1, 3, 1, C_PEAK);
    }
    // sweep cursor: where the analyzer is measuring right now
    int cx = PX0 + (s_sweep_cursor * PW) / N_BIN;
    cv->drawFastVLine(cx, B_BASE - B_H, B_H, C_TEXT);
    // reference-level axis: the auto-ranged display window in dBm
    char db[8];
    cv->setTextColor(C_MUTED);
    snprintf(db, sizeof(db), "%d", (int)s_ref_hi);
    cv->setCursor(462 - strlen(db) * 6, B_BASE - B_H + 2);
    cv->print(db);
    snprintf(db, sizeof(db), "%d", (int)s_ref_lo);
    cv->setCursor(462 - strlen(db) * 6, B_BASE - 10);
    cv->print(db);
  }
  cv->setTextColor(C_MUTED);
  for (int g = 0; g < 5; g++) {
    char fb[12];
    float mhz = (lo + (uint64_t)sp * g / 4) / 1e6f;
    snprintf(fb, sizeof(fb),
             sp >= 20000000 ? "%.0f" : (sp >= 5000000 ? "%.1f" : "%.2f"), mhz);
    int w = (int)strlen(fb) * 6;
    int x = PX0 + g * PW / 4 - (g == 0 ? 0 : (g == 4 ? w : w / 2));
    cv->setCursor(x, B_BASE + 4);
    cv->print(fb);
  }
  for (int r = 0; r < B_WF_ROWS; r++) {
    const int8_t* row = s_wfb[(s_wfb_head - r + B_WF_ROWS) % B_WF_ROWS];
    int y = B_WF_Y + r;
    for (int i = 0; i < N_BIN; i++)
      cv->fillRect(PX0 + (i * PW) / N_BIN, y, 3, 1,
                   s_lut[sub_lvl(row[i]) >> 2]);
  }

  cv->flush();
}

void spectrum_tick(Arduino_Canvas* cv, uint32_t now) {
  if (now - s_last_frame < FRAME_MS) return;
  s_last_frame = now;
  step_live();
  draw(cv);
}

#else  // !ORECCHINO_DISPLAY

void spectrum_reset(uint32_t) {}
void spectrum_stop() {}
void spectrum_tick(Arduino_Canvas*, uint32_t) {}
void spectrum_tap(int, int) {}
bool spectrum_active() { return false; }
void spectrum_feed_wifi(uint8_t, int8_t) {}
void spectrum_set_wifi_channel(uint8_t) {}

#endif
