#pragma once
#include "epdiy.h"
typedef struct { uint8_t* front_fb; uint8_t* back_fb; } EpdiyHighlevelState;
extern uint8_t g_epd_fb[EPD_W * EPD_H / 2];
// Every panel update the drawing code asks for, so a harness can check which
// mode and area a key press or a tap refreshed. g_epd_fail_next makes the
// next update report an underrun, as epdiy does when its feeders fall behind.
struct EpdUpdateLog { int n, gc16; enum EpdDrawMode mode; EpdRect area; };
inline EpdUpdateLog g_epd_log = {0, 0, MODE_GC16, {0, 0, 0, 0}};
inline bool g_epd_fail_next = false;
inline uint8_t g_epd_back[EPD_W * EPD_H / 2];
static inline EpdiyHighlevelState epd_hl_init(const EpdWaveform*) {
  EpdiyHighlevelState s; s.front_fb = g_epd_fb; s.back_fb = g_epd_back; return s;
}
static inline uint8_t* epd_hl_get_framebuffer(EpdiyHighlevelState* s) { return s->front_fb; }
static inline enum EpdDrawError epd_hl_update_area(EpdiyHighlevelState*, enum EpdDrawMode m, int, EpdRect a) {
  g_epd_log.n++; g_epd_log.mode = m; g_epd_log.area = a; if (m == MODE_GC16) g_epd_log.gc16++;
  if (g_epd_fail_next) { g_epd_fail_next = false; return EPD_DRAW_EMPTY_LINE_QUEUE; }
  return EPD_DRAW_SUCCESS;
}
static inline enum EpdDrawError epd_hl_update_screen(EpdiyHighlevelState* s, enum EpdDrawMode m, int t) {
  return epd_hl_update_area(s, m, t, epd_full_screen());
}
static inline void epd_hl_set_all_white(EpdiyHighlevelState* s) { memset(s->front_fb, 0xFF, EPD_W * EPD_H / 2); }
