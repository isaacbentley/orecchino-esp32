#pragma once
#include "Arduino.h"
#define PNG_SUCCESS 0
#define PNG_RGB565_LITTLE_ENDIAN 0
typedef struct { int iWidth; int y; } PNGDRAW;
typedef struct { int dummy; } PNGFILE;
typedef void* (*PNG_OPEN_CALLBACK)(const char*, int32_t*);
typedef void (*PNG_CLOSE_CALLBACK)(void*);
typedef int32_t (*PNG_READ_CALLBACK)(PNGFILE*, uint8_t*, int32_t);
typedef int32_t (*PNG_SEEK_CALLBACK)(PNGFILE*, int32_t);
typedef int (*PNG_DRAW_CALLBACK)(PNGDRAW*);
class PNG { public:
  int open(const char*, PNG_OPEN_CALLBACK, PNG_CLOSE_CALLBACK, PNG_READ_CALLBACK, PNG_SEEK_CALLBACK, PNG_DRAW_CALLBACK) { return 1; }
  int getWidth() { return 256; } int decode(void*, int) { return 0; } void close() {}
  void getLineAsRGB565(PNGDRAW*, uint16_t*, int, uint32_t) {} };
