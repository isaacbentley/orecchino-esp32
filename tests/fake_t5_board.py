#!/usr/bin/env python3
"""A stand-in for the T5's serial side, on a pseudo-terminal.

Used by tests/flash_clock_test.sh. Prints the pty's path, then behaves like
the firmware: a heartbeat every half second, and an answer to
{"cmd":"set_time","utc":N} shaped by MODE:

  ok          {"type":"time",...,"set":true,"rtc":"<N as ISO>"}   the chip took it
  null        ... "rtc":null        running clock set, chip missing or failed
  old         no "rtc" field        firmware from before the chip readback
  refuse      "set":false           date out of range
  stale       "rtc":"2025-01-06T07:18:21Z"   chip kept its old time
  drop-first  ignores the first set_time, answers the second like ok
  late        says nothing for 1.5 s (booting), then behaves like ok
  silent      never says anything (still in the download loader)

Usage: fake_t5_board.py MODE [SECONDS_TO_LIVE]
"""
import os
import re
import select
import sys
import time
import tty

mode = sys.argv[1]
live = float(sys.argv[2]) if len(sys.argv) > 2 else 30.0

master, slave = os.openpty()
tty.setraw(slave)            # no echo, no CR/LF translation: bytes as sent
os.set_blocking(master, False)
print(os.ttyname(slave), flush=True)

def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))

def send(line):
    try:
        os.write(master, line.encode() + b"\n")
    except BlockingIOError:
        pass                 # nobody reading and the queue is full: drop, like the board

start = time.time()
quiet_until = start + (1.5 if mode == "late" else 0.0)
next_hb = quiet_until
buf = b""
sets = 0
while time.time() - start < live:
    now = time.time()
    if mode != "silent" and now >= next_hb:
        send('{"type":"hb","up":%d}' % int((now - start) * 1000))
        next_hb = now + 0.5
    ready, _, _ = select.select([master], [], [], 0.05)
    if not ready:
        continue
    try:
        buf += os.read(master, 4096)
    except (BlockingIOError, OSError):
        continue
    while b"\n" in buf:
        line, buf = buf.split(b"\n", 1)
        m = re.search(rb'"cmd":"set_time","utc":(\d+)', line)
        if not m or mode == "silent" or time.time() < quiet_until:
            continue
        sets += 1
        u = int(m.group(1))
        if mode == "drop-first" and sets == 1:
            continue
        if mode == "old":
            send('{"type":"time","utc":%d,"set":true}' % u)
        elif mode == "null":
            send('{"type":"time","utc":%d,"set":true,"rtc":null}' % u)
        elif mode == "refuse":
            send('{"type":"time","utc":%d,"set":false,"rtc":null}' % u)
        elif mode == "stale":
            send('{"type":"time","utc":%d,"set":true,"rtc":"2025-01-06T07:18:21Z"}' % u)
        else:
            send('{"type":"time","utc":%d,"set":true,"rtc":"%s"}' % (u, iso(u)))
