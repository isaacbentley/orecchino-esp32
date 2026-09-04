#include "ring.h"
#include "board_tembed.h"
#include "driver/rmt_tx.h"
#include "driver/rmt_encoder.h"

// WS2812 timing at a 10 MHz RMT tick (100 ns): 0 = 0.4 us high / 0.85 low,
// 1 = 0.8 high / 0.45 low, reset >50 us low.
static rmt_channel_handle_t s_chan = nullptr;
static rmt_encoder_handle_t s_enc = nullptr;
static uint8_t s_grb[LED_COUNT * 3];

void ring_begin() {
  rmt_tx_channel_config_t cc = {};
  cc.gpio_num = (gpio_num_t)PIN_LED_DATA;
  cc.clk_src = RMT_CLK_SRC_DEFAULT;
  cc.resolution_hz = 10000000;
  cc.mem_block_symbols = 64;
  cc.trans_queue_depth = 2;
  if (rmt_new_tx_channel(&cc, &s_chan) != ESP_OK) return;
  rmt_bytes_encoder_config_t be = {};
  be.bit0.level0 = 1; be.bit0.duration0 = 4; be.bit0.level1 = 0; be.bit0.duration1 = 8;
  be.bit1.level0 = 1; be.bit1.duration0 = 8; be.bit1.level1 = 0; be.bit1.duration1 = 4;
  be.flags.msb_first = 1;
  if (rmt_new_bytes_encoder(&be, &s_enc) != ESP_OK) return;
  rmt_enable(s_chan);
  ring_off();
}

static void show() {
  if (!s_chan) return;
  rmt_transmit_config_t tc = {};
  rmt_transmit(s_chan, s_enc, s_grb, sizeof(s_grb), &tc);
  rmt_tx_wait_all_done(s_chan, 20);
  delayMicroseconds(60);  // latch
}

static void set(int i, uint8_t r, uint8_t g, uint8_t b) {
  s_grb[i * 3] = g; s_grb[i * 3 + 1] = r; s_grb[i * 3 + 2] = b;
}

void ring_off() {
  memset(s_grb, 0, sizeof(s_grb));
  show();
}

void ring_tick(uint32_t now, uint8_t alert, float level) {
  static uint32_t last = 0;
  if (now - last < 40) return;  // 25 fps is plenty for a breath
  last = now;
  if (alert == 0) { ring_off(); return; }
  // Lit count follows RSSI; the last LED fades in so the meter is smooth.
  float lit = 1.0f + level * (LED_COUNT - 1);
  float phase;
  uint8_t r, g, b;
  if (alert == 2) {                     // hard red pulse, 1.5 Hz
    phase = 0.5f + 0.5f * sinf(now * 2 * PI / 660.0f);
    phase = 0.25f + 0.75f * phase;
    r = (uint8_t)(90 * phase); g = 0; b = 0;
  } else {                              // slow amber breath, 0.4 Hz
    phase = 0.5f + 0.5f * sinf(now * 2 * PI / 2500.0f);
    phase = 0.15f + 0.85f * phase;
    r = (uint8_t)(40 * phase); g = (uint8_t)(22 * phase); b = 0;
  }
  for (int i = 0; i < LED_COUNT; i++) {
    float k = lit - i;
    k = k < 0 ? 0 : (k > 1 ? 1 : k);
    set(i, (uint8_t)(r * k), (uint8_t)(g * k), (uint8_t)(b * k));
  }
  show();
}
