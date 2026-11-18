#pragma once
// Host stand-in for bitbank2's JPEGDEC: enough for ui_epd.cpp to compile in
// the render harness, where LittleFS (the shim) holds no tiles. The real
// decoder is tested on real tiles by tests/tile_image_test.cpp.
#include "Arduino.h"
enum { RGB565_LITTLE_ENDIAN = 0, RGB565_BIG_ENDIAN, RGB8888, EIGHT_BIT_GRAYSCALE };
typedef struct { int x, y, iWidth, iHeight, iBpp; uint16_t* pPixels; void* pUser; } JPEGDRAW;
typedef int (JPEG_DRAW_CALLBACK)(JPEGDRAW*);
class JPEGDEC { public:
  int openRAM(uint8_t*, int, JPEG_DRAW_CALLBACK*) { return 0; }
  void setPixelType(int) {}
  int getWidth() { return 256; } int getHeight() { return 256; }
  int decode(int, int, int) { return 0; } void close() {} };
