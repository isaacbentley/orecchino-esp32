// epdiy, reduced to a 4-bit framebuffer the T5 drawing code can paint.
#pragma once
#include "Arduino.h"
typedef struct { int x, y, width, height; } EpdRect;
enum EpdDrawMode { MODE_GC16 = 1, MODE_GL16 = 2, MODE_DU = 4 };
enum EpdDrawError { EPD_DRAW_SUCCESS = 0, EPD_DRAW_EMPTY_LINE_QUEUE = 0x400 };
enum EpdRotation { EPD_ROT_LANDSCAPE = 0 };
typedef struct { int dummy; } EpdWaveform;
typedef struct { int dummy; } EpdBoardDefinition;
typedef struct { int dummy; } EpdDisplay_t;
extern const EpdWaveform* EPD_BUILTIN_WAVEFORM;
extern EpdBoardDefinition epd_board_v7;
extern EpdDisplay_t ED047TC1;
#define EPD_LUT_1K 1
#define EPD_W 960
#define EPD_H 540
static inline int epd_width() { return EPD_W; }
static inline int epd_height() { return EPD_H; }
static inline EpdRect epd_full_screen() { EpdRect r = {0, 0, EPD_W, EPD_H}; return r; }
static inline void epd_init(const EpdBoardDefinition*, const EpdDisplay_t*, int) {}
static inline void epd_set_vcom(uint16_t) {}
static inline void epd_set_rotation(enum EpdRotation) {}
static inline void epd_poweron() {}
static inline void epd_poweroff() {}
inline int g_epd_clears = 0;
static inline void epd_clear() { g_epd_clears++; }
static inline float epd_ambient_temperature() { return 25; }
static inline void epd_draw_pixel(int x, int y, uint8_t color, uint8_t* fb) {
  if (x < 0 || x >= EPD_W || y < 0 || y >= EPD_H) return;
  uint8_t* p = &fb[y * (EPD_W / 2) + x / 2];
  if (x & 1) *p = (*p & 0x0F) | (color & 0xF0); else *p = (*p & 0xF0) | (color >> 4);
}
static inline void epd_fill_rect(EpdRect r, uint8_t c, uint8_t* fb) {
  for (int y = r.y; y < r.y + r.height; y++) for (int x = r.x; x < r.x + r.width; x++) epd_draw_pixel(x, y, c, fb);
}
static inline void epd_draw_rect(EpdRect r, uint8_t c, uint8_t* fb) {
  for (int x = r.x; x < r.x + r.width; x++) { epd_draw_pixel(x, r.y, c, fb); epd_draw_pixel(x, r.y + r.height - 1, c, fb); }
  for (int y = r.y; y < r.y + r.height; y++) { epd_draw_pixel(r.x, y, c, fb); epd_draw_pixel(r.x + r.width - 1, y, c, fb); }
}
static inline void epd_draw_line(int x0, int y0, int x1, int y1, uint8_t c, uint8_t* fb) {
  int dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1, dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1, err = dx + dy;
  for (;;) { epd_draw_pixel(x0, y0, c, fb); if (x0 == x1 && y0 == y1) break; int e2 = 2 * err; if (e2 >= dy) { err += dy; x0 += sx; } if (e2 <= dx) { err += dx; y0 += sy; } }
}
static inline void epd_draw_circle(int cx, int cy, int r, uint8_t c, uint8_t* fb) {
  int x = r, y = 0, err = 1 - r;
  while (x >= y) {
    epd_draw_pixel(cx + x, cy + y, c, fb); epd_draw_pixel(cx + y, cy + x, c, fb); epd_draw_pixel(cx - y, cy + x, c, fb); epd_draw_pixel(cx - x, cy + y, c, fb);
    epd_draw_pixel(cx - x, cy - y, c, fb); epd_draw_pixel(cx - y, cy - x, c, fb); epd_draw_pixel(cx + y, cy - x, c, fb); epd_draw_pixel(cx + x, cy - y, c, fb);
    y++; if (err < 0) err += 2 * y + 1; else { x--; err += 2 * (y - x) + 1; }
  }
}
static inline void epd_fill_circle(int cx, int cy, int r, uint8_t c, uint8_t* fb) {
  for (int y = -r; y <= r; y++) for (int x = -r; x <= r; x++) if (x * x + y * y <= r * r) epd_draw_pixel(cx + x, cy + y, c, fb);
}
#include "epd_highlevel.h"
