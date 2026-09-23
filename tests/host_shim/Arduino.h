// Host-side shim of the Arduino/ESP32 surface the orecchino cores touch.
#pragma once
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <math.h>
#include <algorithm>
#include <string>
#include <vector>
#include <deque>
using std::min; using std::max;

extern uint32_t g_millis;
static inline uint32_t millis() { return g_millis; }
static inline void delay(uint32_t ms) { g_millis += ms; }
template <typename T, typename L, typename H> static inline T constrain(T v, L lo, H hi) { return v < (T)lo ? (T)lo : (v > (T)hi ? (T)hi : v); }

struct MockSerial {
  std::string out, in; size_t in_pos = 0;
  int printf(const char* fmt, ...) { char b[8192]; va_list ap; va_start(ap, fmt); int n = vsnprintf(b, sizeof b, fmt, ap); va_end(ap); out += b; return n; }
  void println(const char* s) { out += s; out += "\n"; }
  size_t print(const char* s) { out += s; return strlen(s); }
  size_t write(const uint8_t* b, size_t n) { out.append((const char*)b, n); return n; }
  int available() { return (int)(in.size() - in_pos); }
  int read() { return in_pos < in.size() ? (unsigned char)in[in_pos++] : -1; }
};
extern MockSerial Serial;
struct MockESP { uint32_t getFreeHeap() { return 123456; } uint32_t getFreePsram() { return 4000000; } uint32_t getPsramSize() { return 8388608; } };
extern MockESP ESP;

// FreeRTOS queue
struct MockQueue { size_t item, cap; std::deque<std::vector<uint8_t>> q; };
typedef MockQueue* QueueHandle_t;
typedef int BaseType_t;
#define pdTRUE 1
#define pdFALSE 0
static inline QueueHandle_t xQueueCreate(size_t n, size_t item) { auto* q = new MockQueue; q->item = item; q->cap = n; return q; }
static inline BaseType_t xQueueSend(QueueHandle_t q, const void* p, int) { if (q->q.size() >= q->cap) return pdFALSE; q->q.emplace_back((const uint8_t*)p, (const uint8_t*)p + q->item); return pdTRUE; }
static inline BaseType_t xQueueReceive(QueueHandle_t q, void* p, int) { if (q->q.empty()) return pdFALSE; memcpy(p, q->q.front().data(), q->item); q->q.pop_front(); return pdTRUE; }

// ---- extras for the T5 render check
#ifndef PROGMEM
#define PROGMEM
#endif
#define INPUT_PULLUP 2
#define LOW 0
#define HIGH 1
#define PI 3.14159265358979323846
static inline void pinMode(int, int) {}
static inline int digitalRead(int) { return HIGH; }

// ---- extras for the T-Embed render check
#define OUTPUT 1
#define CHANGE 3
#ifndef IRAM_ATTR
#define IRAM_ATTR
#endif
typedef int gpio_num_t;
static inline int gpio_get_level(gpio_num_t) { return 1; }
static inline void digitalWrite(int, int) {}
static inline void attachInterrupt(int, void (*)(), int) {}
static inline bool ledcAttach(int, int, int) { return true; }
static inline bool ledcWrite(int, uint32_t) { return true; }
static inline void* ps_malloc(size_t n) { return malloc(n); }
