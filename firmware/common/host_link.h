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
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <Arduino.h>
#include <stdint.h>
#include <stddef.h>
#include <stdarg.h>
#include <string.h>

enum HostSrc : uint8_t {
  SRC_SERIAL = 0,
  SRC_BLE_BONDED = 1,
  SRC_ALL = 255
};

#define HOST_LINE_MAX 1024   // longest line host_printf formats

/// A transport past serial (the BLE link). `feed` marks a live-feed line
/// (rid, hb): the one kind a sink may drop when it cannot keep up.
typedef void (*HostSinkFn)(const uint8_t* line, size_t n, bool feed);
static HostSinkFn s_host_sinks[2] = { nullptr, nullptr };
static size_t     s_host_sink_count = 0;
// Did the BLE peer ask for the live feed? Off until it does, and again
// after every disconnect. Serial always gets it.
static volatile bool s_feed_ble = false;

/// Register a sink; registering the same one again is a no-op, so a line
/// is never delivered twice.
static inline bool host_link_add_sink(HostSinkFn fn) {
  for (size_t i = 0; i < s_host_sink_count; i++)
    if (s_host_sinks[i] == fn) return true;
  if (s_host_sink_count < 2) {
    s_host_sinks[s_host_sink_count++] = fn;
    return true;
  }
  return false;
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

/// Send one complete line (ending in '\n') to `dst`.
static inline void host_write_to(HostSrc dst, const uint8_t* line, size_t n) {
  if (!line || n == 0) return;
  if (dst == SRC_SERIAL || dst == SRC_ALL) Serial.write(line, n);
  if (dst == SRC_SERIAL) return;
  bool feed = dst == SRC_ALL && host_is_feed_line(line, n);
  if (feed && !s_feed_ble) return;   // the peer did not ask for the feed
  for (size_t i = 0; i < s_host_sink_count; i++)
    if (s_host_sinks[i]) s_host_sinks[i](line, n, feed);
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
