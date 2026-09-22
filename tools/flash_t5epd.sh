#!/bin/bash
# Compile + flash the LilyGO T5 E-Paper S3 Pro target. Quits Orecchino.app
# first — it auto-connects to serial ports and its reads corrupt esptool.
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${1:-}"
if [ -z "$PORT" ]; then
  PORT="$(ls /dev/cu.usbmodem* 2>/dev/null | head -n 1 || true)"
  if [ -z "$PORT" ]; then
    echo "Error: No USB serial device found (/dev/cu.usbmodem*)."
    echo "Usage: tools/flash_t5epd.sh /dev/cu.usbmodemXXXX"
    exit 1
  fi
  echo "Auto-detected port: $PORT"
fi

FQBN="esp32:esp32:esp32s3:FlashMode=dio,FlashSize=16M,PartitionScheme=custom,PSRAM=opi,CPUFreq=240,CDCOnBoot=cdc,LoopCore=1,EventsCore=1"

pkill -9 -x Orecchino 2>/dev/null || true
sleep 1
arduino-cli compile --jobs 2 --libraries firmware/libraries -b "$FQBN" firmware/orecchino_t5epd
arduino-cli upload -b "$FQBN" -p "$PORT" firmware/orecchino_t5epd

echo "Upload complete. Exiting USB download bootloader into firmware..."
ESPTOOL="$(find "$HOME/Library/Arduino15/packages/esp32/tools/esptool_py" -name esptool 2>/dev/null | sort -V | tail -n 1)"
[ -n "$ESPTOOL" ] || ESPTOOL="$(which esptool || true)"   # tail exits 0 on empty input, so fall back explicitly
if [ -n "$ESPTOOL" ] && [ -x "$ESPTOOL" ]; then
  sleep 0.5
  "$ESPTOOL" --chip esp32s3 -p "$PORT" --after watchdog-reset chip-id >/dev/null 2>&1 || true
  sleep 0.5
  echo "ESP32-S3 rebooted successfully. Orecchino firmware is running!"
else
  echo "Warning: esptool not found to trigger auto-reboot; manual reset may be needed."
fi

# Set the board's clock from this computer's. The board has no network, so
# its RTC only ever learns the time here or from the app; the sunset
# backlight and the displayed UTC clock both depend on it. Spoken over the
# serial port in plain shell -- an earlier version used Python and pyserial,
# which is not installed by default, and hid the failure behind 2>/dev/null,
# so every flash silently left the clock wrong.
sync_rtc() {
  local port="$1" epoch reply got cat_pid raw
  raw="$(mktemp -t orecchino_rtc)"
  # Never run stty on this port: the board is an ESP32-S3 on native USB, and
  # touching the control lines resets it -- which lands it in epdiy's
  # board init, where a warm reset can panic on the PCA9555. Opening a
  # cu.* device leaves DTR alone, so a plain read and write are safe.
  cat "$port" > "$raw" 2>/dev/null &
  cat_pid=$!
  # A Ctrl-C during the waits below must not leave a reader holding the
  # port: a stray cat would keep the Mac app from ever opening it.
  trap 'kill "$cat_pid" 2>/dev/null; rm -f "$raw"; exit 130' INT TERM
  sleep 1                                    # let the reader attach first
  epoch="$(date -u +%s)"
  printf '{"cmd":"set_time","utc":%d}\n' "$epoch" 2>/dev/null > "$port" || epoch=""
  if [ -n "$epoch" ]; then
    sleep 1
    # Ask for the status too: set_time answers {"set":true} as soon as it
    # has parsed the command, so only the status line's clock proves it
    # stuck. Its "utc" is the quoted string; set_time's is a bare number,
    # so this pattern can only ever match the status line.
    printf '{"cmd":"status"}\n' 2>/dev/null > "$port" || true
    sleep 3
  fi
  kill "$cat_pid" 2>/dev/null
  wait "$cat_pid" 2>/dev/null || true
  trap - INT TERM
  reply="$(grep -o '"utc":"[^"]*"' "$raw" | tail -1 | cut -d'"' -f4)"
  rm -f "$raw"
  [ -n "$epoch" ] && [ -n "$reply" ] || return 1
  # Compare as epoch seconds. Comparing the formatted minute instead would
  # cry wolf every time the readback crossed a minute boundary, which is
  # several seconds after the set and so a few per cent of all flashes.
  got="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$reply" '+%s' 2>/dev/null)" || got=""
  [ -n "$got" ] || return 1
  if [ "$((got - epoch))" -gt 90 ] || [ "$((epoch - got))" -gt 90 ]; then
    echo "RTC still reads $reply after being set to $(date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ')."
    return 1
  fi
  echo "RTC set and verified: the board reports $reply."
}

echo "Setting the onboard RTC to the current UTC time..."
sleep 2.0
if ! sync_rtc "$PORT"; then
  echo "Warning: could not set the RTC -- the board kept its old clock."
  echo "         Its UTC readout and the automatic sunset backlight will be wrong."
  echo "         Retry with: tools/flash_t5epd.sh $PORT"
fi

echo "Reopen the app with: open app/build/Orecchino.app"

