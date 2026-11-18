// Big buffers off the internal heap. The S3 boards carry 8 MB of PSRAM
// while their ~320 KB of internal RAM is what the Wi-Fi driver, the BT
// controller and mbedTLS need, so tables and line buffers that are only
// touched by tasks (never from an ISR or with the cache off) live out there.
// Boards without PSRAM (XIAO C3, C6 AMOLED) fall back to the internal heap.
//
// EXT_RAM_BSS_ATTR would be the static way, but the prebuilt Arduino
// sdkconfig does not enable it; allocating at start-up works everywhere.
// Safe from static initialisers: the prebuilt sdkconfig brings PSRAM up
// before C++ constructors run (CONFIG_SPIRAM_BOOT_INIT).
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <Arduino.h>
#include <stdlib.h>
#if defined(ESP_PLATFORM)
#include <esp_heap_caps.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/ringbuf.h>
#include <freertos/idf_additions.h>
#endif

/// Zeroed block, in PSRAM when the board has it.
static inline void* ext_calloc(size_t n) {
#if defined(ESP_PLATFORM) && defined(CONFIG_SPIRAM)
  void* p = heap_caps_calloc(1, n, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  if (p) return p;
#endif
  return calloc(1, n);
}
template <typename T> static inline T* ext_new(size_t count = 1) {
  return (T*)ext_calloc(sizeof(T) * count);
}

/// True when ext_calloc lands in PSRAM (sizes buffers that would be too
/// costly in internal RAM).
static inline bool ext_ram_is_psram() {
#if defined(ESP_PLATFORM) && defined(CONFIG_SPIRAM)
  return heap_caps_get_total_size(MALLOC_CAP_SPIRAM) > 0;
#else
  return false;
#endif
}

#if defined(ESP_PLATFORM)
/// A FreeRTOS queue whose storage is in PSRAM when there is some.
static inline QueueHandle_t ext_queue(UBaseType_t n, UBaseType_t item) {
#if defined(CONFIG_SPIRAM)
  QueueHandle_t q = xQueueCreateWithCaps(n, item, MALLOC_CAP_SPIRAM);
  if (q) return q;
#endif
  return xQueueCreate(n, item);
}
/// A no-split ring buffer: `psram_size` in PSRAM, else `internal_size`
/// from the internal heap.
static inline RingbufHandle_t ext_ring(size_t psram_size, size_t internal_size) {
#if defined(CONFIG_SPIRAM)
  RingbufHandle_t rb = xRingbufferCreateWithCaps(psram_size, RINGBUF_TYPE_NOSPLIT, MALLOC_CAP_SPIRAM);
  if (rb) return rb;
#endif
  (void)psram_size;
  return xRingbufferCreate(internal_size, RINGBUF_TYPE_NOSPLIT);
}
#else
static inline QueueHandle_t ext_queue(size_t n, size_t item) { return xQueueCreate(n, item); }
#endif
