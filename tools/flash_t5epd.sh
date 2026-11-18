#!/bin/bash
# Compile + flash the LilyGO T5 E-Paper S3 Pro target, then set its clock.
# Quits Orecchino.app first -- it auto-connects to serial ports and its reads
# corrupt esptool.
#
#   tools/flash_t5epd.sh [PORT]                compile, flash, reboot, set the clock
#   tools/flash_t5epd.sh --clock-only [PORT]   only set the clock
set -euo pipefail

# Set the board's clock from this computer's and confirm its RTC chip holds
# it. The board has no network: its clock is set here, by the Mac app when
# it connects, or by its GPS, and the automatic sunset backlight and the
# UTC readout run off it. The firmware answers set_time with the chip's own
# time, read back after writing -- the time that survives a reset -- so
# that, not the running clock, is what gets checked.
set_clock() {
  local port="$1" raw reader="" epoch="" reply rtc got drift sig
  # A dial-in tty.* node waits in open() for a carrier signal this board
  # never raises; its call-out cu.* twin is the same device without the wait.
  case "$port" in /dev/tty.*) port="/dev/cu.${port#/dev/tty.}" ;; esac

  # One cleanup for every way out. A background job ignores Ctrl-C and
  # Ctrl-\ in a script, so the reader is killed here rather than trusted to
  # die; left running it would split the port's input with the Mac app.
  # Each signal is re-raised after cleanup so the script, and anything
  # running it in a loop, still stops the way it was told to. The traps go
  # in before the capture file is made, so only a signal landing inside the
  # mktemp call itself could strand one.
  raw=""
  stop_reader() {
    if [ -n "$reader" ]; then
      kill "$reader" 2>/dev/null || true
      wait "$reader" 2>/dev/null || true
      reader=""
    fi
  }
  finish() {
    stop_reader
    if [ -n "$raw" ]; then rm -f "$raw" || true; fi
    trap - INT TERM HUP QUIT
  }
  # shellcheck disable=SC2064  # $sig is meant to expand now: each trap re-raises its own signal
  for sig in INT TERM HUP QUIT; do trap "finish; kill -$sig \$\$" "$sig"; done
  # In $TMPDIR (macOS's `mktemp -t` ignores it), so a caller -- the tests --
  # can give each run a directory of its own.
  raw="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/orecchino_rtc.XXXXXXXX")" || { finish; return 1; }

  # Plain opens are enough: on this native USB port the baud rate means
  # nothing, so there is nothing for stty to set. A reset can take the port
  # away for a moment, which ends a reader, so await starts another.
  start_reader() { cat "$port" >> "$raw" 2>/dev/null & reader=$!; }
  await() {  # await <pattern> <seconds>: poll the capture until it matches
    local deadline=$(( SECONDS + $2 ))
    until grep -a -q -e "$1" "$raw" 2>/dev/null; do
      [ "$SECONDS" -lt "$deadline" ] || return 1
      kill -0 "$reader" 2>/dev/null || start_reader
      sleep 0.2
    done
  }

  start_reader
  # Any JSON line -- boot, heartbeat, beacon status -- means the firmware is
  # running and reading; a command sent before that could be lost. (The
  # tests shorten the 20 s wait with T5_CLOCK_WAIT.)
  if ! await '"type":"' "${T5_CLOCK_WAIT:-20}"; then
    finish
    echo "The board did not answer on $port; it may still be in its download loader."
    return 1
  fi
  # One resend: set_time is idempotent, and a line can be lost (in beacon
  # mode two readers share the port).
  for _ in 1 2; do
    if [ ! -c "$port" ]; then
      finish
      echo "$port is not a serial device."
      return 1
    fi
    epoch="$(/bin/date -u +%s)"
    printf '{"cmd":"set_time","utc":%d}\n' "$epoch" 2>/dev/null > "$port" || true
    if await '"type":"time"' 5; then break; fi
  done
  reply="$(grep -a -e '"type":"time"' "$raw" | tail -n 1)"
  finish

  case "$reply" in
    "")
      echo "The board did not answer the clock command." ;;
    *'"set":false'*)
      echo "The board refused $(/bin/date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ') as out of range;"
      echo "is this computer's clock right?" ;;
    *'"rtc":"'*)
      rtc="${reply#*'"rtc":"'}"
      rtc="${rtc%%'"'*}"
      got="$(/bin/date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$rtc" '+%s' 2>/dev/null)" || got=""
      if [ -n "$got" ]; then
        drift=$(( got - epoch ))
        if [ "${drift#-}" -le 90 ]; then
          echo "Clock set: the board's clock chip reads $rtc."
          return 0
        fi
      fi
      echo "The board's clock chip reads $rtc, not $(/bin/date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ')." ;;
    *'"rtc":null'*)
      echo "The board set its running clock, but its clock chip did not take the time,"
      echo "so the next reset will lose it." ;;
    *)
      echo "The board set its running clock, but this firmware cannot report its clock"
      echo "chip; flash the current firmware." ;;
  esac
  return 1
}

# Sourced (the tests do this): stop with only set_clock defined.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

cd "$(dirname "$0")/.."
source tools/flash_common.sh

CLOCK_ONLY=0
if [ "${1:-}" = "--clock-only" ]; then
  CLOCK_ONLY=1
  shift
fi

PORT="${1:-}"
if [ -z "$PORT" ]; then
  pick_port "tools/flash_t5epd.sh [--clock-only] /dev/cu.usbmodemXXXX" /dev/cu.usbmodem* || exit 1
fi

FQBN="esp32:esp32:esp32s3:FlashMode=dio,FlashSize=16M,PartitionScheme=custom,PSRAM=opi,CPUFreq=240,CDCOnBoot=cdc,LoopCore=1,EventsCore=1"

quit_app

if [ "$CLOCK_ONLY" = 0 ]; then
  arduino-cli compile --jobs 2 --libraries firmware/libraries -b "$FQBN" firmware/orecchino_t5epd
  arduino-cli upload -b "$FQBN" -p "$PORT" firmware/orecchino_t5epd

  echo "Upload complete. Exiting USB download bootloader into firmware..."
  # `|| true` inside the substitution: when the esptool_py directory is
  # missing, find fails, pipefail fails the pipeline, and errexit would end
  # the script here, silently, before the fallback below.
  ESPTOOL="$(find "$HOME/Library/Arduino15/packages/esp32/tools/esptool_py" -name esptool 2>/dev/null | sort -V | tail -n 1 || true)"
  [ -n "$ESPTOOL" ] || ESPTOOL="$(which esptool || true)"
  if [ -n "$ESPTOOL" ] && [ -x "$ESPTOOL" ]; then
    sleep 0.5
    if "$ESPTOOL" --chip esp32s3 -p "$PORT" --after watchdog-reset chip-id >/dev/null 2>&1; then
      echo "Rebooted the board into its firmware."
    else
      echo "Warning: esptool could not reboot the board; press its reset button now."
    fi
  else
    echo "Warning: esptool not found to reboot the board; press its reset button now."
  fi
fi

echo "Setting the board's clock to the current UTC time..."
if ! set_clock "$PORT"; then
  echo "Warning: the board's clock is not confirmed, so its UTC readout and automatic"
  echo "         sunset backlight may be wrong. Retry with:"
  echo "         tools/flash_t5epd.sh --clock-only $PORT"
fi

echo "Reopen the app with: open app/build/Orecchino.app"
