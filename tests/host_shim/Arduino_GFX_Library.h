// Host shim of the slice of Arduino_GFX the T-Embed UI uses: a canvas that
// draws into an RGB565 framebuffer with the same text rules as the library
// (GFX fonts drawn from the baseline, the classic 5x7 font from the top-left,
// wrapping at the right edge, which the library does by default). Every
// print() is reported to UI_TEXT_RUN (when defined) so a test can check
// text runs for collisions and for running off the screen.
#pragma once
#include "Arduino.h"
#include "gfxfont.h"
#include "glcdfont.c"

#ifndef UI_TEXT_RUN
#define UI_TEXT_RUN(x0, y0, x1, y1, s, wrapped) ((void)0)
#endif

class Arduino_DataBus {};
class Arduino_ESP32SPI : public Arduino_DataBus {
 public: Arduino_ESP32SPI(int, int, int, int, int, int = 0) {}
};
#ifndef HSPI
#define HSPI 2
#endif
#define GFX_SKIP_OUTPUT_BEGIN -2

class Arduino_GFX {
 public:
  virtual ~Arduino_GFX() {}
  virtual bool begin(int32_t = 0) { return true; }
  virtual void draw16bitRGBBitmap(int16_t, int16_t, uint16_t*, int16_t, int16_t) {}
};
class Arduino_ST7789 : public Arduino_GFX {
 public: Arduino_ST7789(Arduino_DataBus*, int, int, bool, int, int, int, int, int, int) {}
};

class Arduino_Canvas : public Arduino_GFX {
 public:
  int16_t w, h;
  uint16_t* fb = nullptr;
  Arduino_Canvas(int16_t w_, int16_t h_, Arduino_GFX*) : w(w_), h(h_) {}
  bool begin(int32_t = 0) override { if (!fb) fb = new uint16_t[(size_t)w * h](); return true; }
  uint16_t* getFramebuffer() { return fb; }
  void flush() { flushes++; }
  int flushes = 0;

  void drawPixel(int x, int y, uint16_t c) { if (x >= 0 && y >= 0 && x < w && y < h) fb[y * w + x] = c; }
  void fillRect(int x, int y, int ww, int hh, uint16_t c) {
    for (int j = y; j < y + hh; j++) for (int i = x; i < x + ww; i++) drawPixel(i, j, c);
  }
  void fillScreen(uint16_t c) { fillRect(0, 0, w, h, c); }
  void drawFastVLine(int x, int y, int hh, uint16_t c) { fillRect(x, y, 1, hh, c); }
  void drawFastHLine(int x, int y, int ww, uint16_t c) { fillRect(x, y, ww, 1, c); }
  void drawLine(int x0, int y0, int x1, int y1, uint16_t c) {
    int dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1, dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1, e = dx + dy;
    for (;;) { drawPixel(x0, y0, c); if (x0 == x1 && y0 == y1) break; int e2 = 2 * e;
      if (e2 >= dy) { e += dy; x0 += sx; } if (e2 <= dx) { e += dx; y0 += sy; } }
  }
  void drawCircle(int cx, int cy, int r, uint16_t c) {
    for (int a = 0; a < 360; a++) drawPixel(cx + (int)lround(r * cos(a * M_PI / 180)), cy + (int)lround(r * sin(a * M_PI / 180)), c);
  }
  void fillCircle(int cx, int cy, int r, uint16_t c) {
    for (int y = -r; y <= r; y++) for (int x = -r; x <= r; x++) if (x * x + y * y <= r * r) drawPixel(cx + x, cy + y, c);
  }
  void fillRoundRect(int x, int y, int ww, int hh, int, uint16_t c) { fillRect(x, y, ww, hh, c); }
  void drawRoundRect(int x, int y, int ww, int hh, int, uint16_t c) {
    drawFastHLine(x, y, ww, c); drawFastHLine(x, y + hh - 1, ww, c);
    drawFastVLine(x, y, hh, c); drawFastVLine(x + ww - 1, y, hh, c);
  }

  const GFXfont* gfont = nullptr;
  int16_t cx = 0, cy = 0;
  uint16_t color = 0xFFFF;
  bool wrap = true;
  void setFont(const GFXfont* f) { gfont = f; }
  void setTextSize(int) {}
  void setTextColor(uint16_t c) { color = c; }
  void setCursor(int x, int y) { cx = x; cy = y; }
  void setTextWrap(bool w_) { wrap = w_; }

  size_t print(const char* s) {
    int x0 = 1 << 30, y0 = 1 << 30, x1 = -(1 << 30), y1 = -(1 << 30);
    bool wrapped = false;
    for (const char* p = s; *p; p++) {
      uint8_t c = (uint8_t)*p;
      if (gfont) {
        if (c < gfont->first || c > gfont->last) continue;
        const GFXglyph* g = &gfont->glyph[c - gfont->first];
        if (wrap && cx + g->xOffset + g->width - 1 > w - 1) { cx = 0; cy += gfont->yAdvance; wrapped = true; }
        const uint8_t* bm = gfont->bitmap + g->bitmapOffset;
        int bit = 0; uint8_t bits = 0;
        for (int yy = 0; yy < g->height; yy++) for (int xx = 0; xx < g->width; xx++) {
          if (!(bit++ & 7)) bits = *bm++;
          if (bits & 0x80) drawPixel(cx + g->xOffset + xx, cy + g->yOffset + yy, color);
          bits <<= 1;
        }
        if (g->width && g->height) {
          x0 = std::min(x0, cx + g->xOffset); x1 = std::max(x1, cx + g->xOffset + g->width);
          y0 = std::min(y0, cy + g->yOffset); y1 = std::max(y1, cy + g->yOffset + g->height);
        }
        cx += g->xAdvance;
      } else {
        if (c == '\n') { cx = 0; cy += 8; continue; }
        if (wrap && cx + 6 > w) { cx = 0; cy += 8; wrapped = true; }
        for (int i = 0; i < 5; i++) {
          uint8_t line = font5x7(c, i);
          for (int j = 0; j < 8; j++, line >>= 1) if (line & 1) drawPixel(cx + i, cy + j, color);
        }
        if (c != ' ') { x0 = std::min(x0, (int)cx); x1 = std::max(x1, cx + 5); y0 = std::min(y0, (int)cy); y1 = std::max(y1, cy + 7); }
        cx += 6;
      }
    }
    if (x1 > x0) UI_TEXT_RUN(x0, y0, x1, y1, s, wrapped);
    return strlen(s);
  }
  static uint8_t font5x7(uint8_t c, int i) { return font[c * 5 + i]; }
};
