#pragma once
#include "epdiy.h"
typedef struct { uint8_t* front_fb; } EpdiyHighlevelState;
extern uint8_t g_epd_fb[EPD_W * EPD_H / 2];
static inline EpdiyHighlevelState epd_hl_init(const EpdWaveform*) { EpdiyHighlevelState s; s.front_fb = g_epd_fb; return s; }
static inline uint8_t* epd_hl_get_framebuffer(EpdiyHighlevelState* s) { return s->front_fb; }
static inline void epd_hl_update_screen(EpdiyHighlevelState*, enum EpdDrawMode, int) {}
static inline void epd_hl_update_area(EpdiyHighlevelState*, enum EpdDrawMode, int, EpdRect) {}
static inline void epd_hl_set_all_white(EpdiyHighlevelState* s) { memset(s->front_fb, 0xFF, EPD_W * EPD_H / 2); }
