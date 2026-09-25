// Output routing for Orecchino's JSON lines: USB serial and the BLE link.
//
// Every line has a destination, passed by whoever writes it:
//   * a reply goes back to the host that asked -- the HostSrc its command
//     arrived on, handed down explicitly. Never a global "current requester":
//     the decode task writes rid lines while the loop answers a command, and
//     a shared value would send one task's lines where the other's belong.
//   * everything else is a broadcast (SRC_ALL): serial always, and a BLE
//     peer when it asked for the live feed (rid, hb lines) or, for any other
//     broadcast (boot, net status), whenever it is subscribed.
// host_print/host_printf/host_write are broadcasts; the *_to forms reply.
//
// No writer waits on a host. Each sink has a ring drained by a task of its
// own (usb_tx here, ble_tx in ble_link.h): a host that stops reading -- the
// Mac app closes the port while the cable stays in, and HWCDC::write then
// blocks up to 2 s per call under the backpressure -- fills the ring, and
// the policy in host_outq_put decides what to lose: the live feed at once,
// a reply after one bounded wait. Nothing on the detection path ever sees
// the wait.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <Arduino.h>
#include "ext_ram.h"
#include <stdint.h>
#include <stddef.h>
#include <stdarg.h>
#include <string.h>

enum HostSrc : uint8_t {
  SRC_SERIAL = 0,
  SRC_BLE_BONDED = 1,
  SRC_ALL = 255
};

#define HOST_LINE_MAX    1024   // longest line host_printf formats
#define HOST_CTL_WAIT_MS 250    // longest a reply waits for room in a sink's ring

/// What a line is to a sink's ring: the live feed (rid, hb) is dropped the
/// moment the ring is full; a reply or log record waits for room once; the
/// last line of a reply (log_done) waits even when the ring has stalled, so
/// a client hears how its reply ended.
enum HostLineKind : uint8_t { HOST_FEED = 0, HOST_REPLY = 1, HOST_REPLY_FINAL = 2 };

// ---------------------------------------------------- a sink's output ring
// The policy is transport-free (the ring operation is a function pointer)
// so the host tests run it against a stalled sink. `stalled` remembers that
// a reply timed out: the replies after it go without waiting until one fits
// again, so a dead host costs the loop one wait, not one per line. Reply
// drops are counted on their own so emit_log can tell a client its reply
// was cut (log_done "err":"dropped").
typedef bool (*HostRingSend)(void* ring, const uint8_t* line, size_t n, uint32_t wait_ms);
struct HostOutQ {
  HostRingSend       send;
  void*              ring;
  volatile bool      stalled;
  volatile uint32_t  drops;         // every line dropped
  volatile uint32_t  reply_drops;   // of which replies and log records
};

static inline bool host_outq_put(HostOutQ* q, const uint8_t* line, size_t n, HostLineKind kind) {
  if (!q->send || !q->ring) return false;
  uint32_t wait = 0;
  if (kind == HOST_REPLY_FINAL || (kind == HOST_REPLY && !q->stalled)) wait = HOST_CTL_WAIT_MS;
  if (q->send(q->ring, line, n, wait)) {
    if (kind != HOST_FEED) q->stalled = false;
    return true;
  }
  q->drops += 1;
  if (kind != HOST_FEED) {
    q->stalled = true;
    q->reply_drops += 1;
  }
  return false;
}

// ------------------------------------------------------------- USB serial
#if defined(ESP_PLATFORM)
#include <freertos/FreeRTOS.h>
#include <freertos/ringbuf.h>
#include <freertos/task.h>

static bool usb_ring_send(void* ring, const uint8_t* line, size_t n, uint32_t wait_ms) {
  return xRingbufferSend((RingbufHandle_t)ring, line, n, pdMS_TO_TICKS(wait_ms)) == pdTRUE;
}
static HostOutQ s_usb_q = { usb_ring_send, nullptr, false, 0, 0 };

/// The only task that writes the JSON lines to Serial: a stalled host holds
/// this one up, nothing else.
static void usb_tx_task(void*) {
  for (;;) {
    size_t n = 0;
    uint8_t* item = (uint8_t*)xRingbufferReceive((RingbufHandle_t)s_usb_q.ring, &n, portMAX_DELAY);
    if (!item) continue;
    Serial.write(item, n);
    vRingbufferReturnItem((RingbufHandle_t)s_usb_q.ring, item);
  }
}

/// Start the USB writer (rx_begin, before the decode task). Until it runs,
/// and on a board where it cannot, lines are written to Serial directly.
static inline void host_link_begin() {
  if (s_usb_q.ring) return;
  // A rid line is up to 1.5 KB and a log reply ~19 KB: 32 KB in PSRAM
  // rides out a few seconds of a slow host; without PSRAM 4 KB holds a
  // couple of lines, which is all a live host ever needs.
  RingbufHandle_t rb = ext_ring(32768, 4096);
  if (!rb) return;
  s_usb_q.ring = rb;
  TaskHandle_t h = nullptr;
  if (xTaskCreate(usb_tx_task, "usb_tx", 2560, nullptr, 2, &h) != pdPASS) {
    s_usb_q.ring = nullptr;   // the ring stays allocated: nothing will ever read it
    return;
  }
#if defined(ARDUINO_USB_MODE) && ARDUINO_USB_MODE && defined(ARDUINO_USB_CDC_ON_BOOT) && ARDUINO_USB_CDC_ON_BOOT
  // Serial is the HW CDC: under host backpressure its write() retries 20
  // times this long before returning short. 100 ms would hold the writer
  // 2 s per line; 20 ms lets it drop a line every 0.4 s and keep the ring
  // moving, so a host that comes back sees fresh lines sooner.
  Serial.setTxTimeoutMs(20);
#endif
}

#else
// Host tests: a sink's ring delivers straight to its destination unless a
// test stops it. `dead` refuses every line (a waited send costs simulated
// time, as the real wait would); `fail_at` refuses the k-th line from now
// only (a ring momentarily full); `room` counts the lines it still takes
// (SIZE_MAX: unlimited).
struct HostMockRing {
  bool   dead;
  int    fail_at;
  size_t room;
  void   (*deliver)(const uint8_t* line, size_t n);
};
static bool host_mock_send(void* ring, const uint8_t* line, size_t n, uint32_t wait_ms) {
  HostMockRing* r = (HostMockRing*)ring;
  bool refuse = r->dead || r->room == 0;
  if (r->fail_at > 0 && --r->fail_at == 0) refuse = true;
  if (refuse) { delay(wait_ms); return false; }
  if (r->room != SIZE_MAX) r->room--;
  r->deliver(line, n);
  return true;
}
static void usb_mock_deliver(const uint8_t* line, size_t n) { Serial.write(line, n); }
static HostMockRing s_usb_mock = { false, 0, SIZE_MAX, usb_mock_deliver };
static HostOutQ s_usb_q = { host_mock_send, &s_usb_mock, false, 0, 0 };
static inline void host_link_begin() {}
/// A host that stopped reading: every serial line is refused.
static inline void host_link_test_stall_usb(bool dead) { s_usb_mock.dead = dead; }
/// The k-th serial line from now is refused (the ring full for a moment).
static inline void host_link_test_usb_fail_at(int k) { s_usb_mock.fail_at = k; }
#endif

/// Serial lines dropped because the USB host stopped reading (the
/// heartbeat's usb_drop).
static inline uint32_t host_usb_drops() { return s_usb_q.drops; }

// ------------------------------------------------------------------ sinks

/// A transport past serial (the BLE link), with the ring its replies go
/// through, so reply drops can be read back per destination.
typedef void (*HostSinkFn)(const uint8_t* line, size_t n, HostLineKind kind);
static HostSinkFn s_host_sinks[2] = { nullptr, nullptr };
static HostOutQ*  s_host_sink_ctl[2] = { nullptr, nullptr };
static size_t     s_host_sink_count = 0;
// Did the BLE peer ask for the live feed? Off until it does, and again
// after every disconnect. Serial always gets it.
static volatile bool s_feed_ble = false;

/// Register a sink; registering the same one again is a no-op, so a line
/// is never delivered twice.
static inline bool host_link_add_sink(HostSinkFn fn, HostOutQ* ctl) {
  for (size_t i = 0; i < s_host_sink_count; i++)
    if (s_host_sinks[i] == fn) return true;
  if (s_host_sink_count < 2) {
    s_host_sink_ctl[s_host_sink_count] = ctl;
    s_host_sinks[s_host_sink_count++] = fn;
    return true;
  }
  return false;
}

/// Replies and log records dropped on the way to `dst` so far. A producer
/// reads it before and after a reply to learn whether the reply was cut.
static inline uint32_t host_reply_drops(HostSrc dst) {
  uint32_t n = 0;
  if (dst == SRC_SERIAL || dst == SRC_ALL) n += s_usb_q.reply_drops;
  if (dst != SRC_SERIAL)
    for (size_t i = 0; i < s_host_sink_count; i++)
      if (s_host_sink_ctl[i]) n += s_host_sink_ctl[i]->reply_drops;
  return n;
}

static inline void host_set_feed(HostSrc src, bool on) {
  if (src == SRC_BLE_BONDED) s_feed_ble = on;
}

static inline bool host_get_feed(HostSrc src) {
  if (src == SRC_BLE_BONDED) return s_feed_ble;
  return true; // serial feed is always on
}

/// rid frames and heartbeats: the live feed, recognised by the line's own
/// type so every producer is classified the same way.
static inline bool host_is_feed_line(const uint8_t* line, size_t n) {
  return (n >= 13 && memcmp(line, "{\"type\":\"rid\"", 13) == 0) ||
         (n >= 12 && memcmp(line, "{\"type\":\"hb\"", 12) == 0);
}

/// Send one complete line (ending in '\n') to `dst`. `final` marks the
/// last line of a reply (HOST_REPLY_FINAL above).
static inline void host_write_to(HostSrc dst, const uint8_t* line, size_t n, bool final = false) {
  if (!line || n == 0) return;
  bool feed = dst == SRC_ALL && host_is_feed_line(line, n);
  HostLineKind kind = feed ? HOST_FEED : (final ? HOST_REPLY_FINAL : HOST_REPLY);
  if (dst == SRC_SERIAL || dst == SRC_ALL) {
    if (s_usb_q.ring) host_outq_put(&s_usb_q, line, n, kind);
    else Serial.write(line, n);   // before rx_begin (boot lines, the TX-mode console)
  }
  if (dst == SRC_SERIAL) return;
  if (feed && !s_feed_ble) return;   // the peer did not ask for the feed
  for (size_t i = 0; i < s_host_sink_count; i++)
    if (s_host_sinks[i]) s_host_sinks[i](line, n, kind);
}

static inline void host_write(const uint8_t* line, size_t n) { host_write_to(SRC_ALL, line, n); }

static inline void host_print_to(HostSrc dst, const char* s) {
  if (s) host_write_to(dst, (const uint8_t*)s, strlen(s));
}
static inline void host_print(const char* s) { host_print_to(SRC_ALL, s); }

static inline void host_vprintf_to(HostSrc dst, const char* fmt, va_list ap) {
  char buf[HOST_LINE_MAX];
  int n = vsnprintf(buf, sizeof(buf), fmt, ap);
  // vsnprintf returns the length it wanted, not what it wrote. A line that
  // did not fit is dropped whole: cut short it would lose its '\n' and run
  // into the next one.
  if (n <= 0 || n >= (int)sizeof(buf)) return;
  host_write_to(dst, (const uint8_t*)buf, (size_t)n);
}

static inline void host_printf_to(HostSrc dst, const char* fmt, ...) __attribute__((format(printf, 2, 3)));
static inline void host_printf_to(HostSrc dst, const char* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  host_vprintf_to(dst, fmt, ap);
  va_end(ap);
}

static inline void host_printf(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
static inline void host_printf(const char* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  host_vprintf_to(SRC_ALL, fmt, ap);
  va_end(ap);
}
