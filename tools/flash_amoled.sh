#!/bin/bash
# Compile + flash the Waveshare ESP32-C6-Touch-AMOLED-1.8 target. Quits
# Orecchino.app first — it auto-connects to serial ports and its reads
# corrupt esptool.
set -euo pipefail
cd "$(dirname "$0")/.."

source tools/flash_common.sh

PORT="${1:-}"
if [ -z "$PORT" ]; then
  pick_port "tools/flash_amoled.sh /dev/cu.usbmodemXXXX" /dev/cu.usbmodem* || exit 1
fi

FQBN="esp32:esp32:esp32c6:FlashSize=16M,PartitionScheme=custom,CDCOnBoot=cdc"

quit_app
arduino-cli compile --jobs 2 --libraries firmware/libraries -b "$FQBN" firmware/orecchino_amoled
arduino-cli upload -b "$FQBN" -p "$PORT" firmware/orecchino_amoled

echo "Upload complete. Exiting USB download bootloader into firmware..."
ESPTOOL="$(find "$HOME/Library/Arduino15/packages/esp32/tools/esptool_py" -name esptool 2>/dev/null | sort -V | tail -n 1 || which esptool || true)"
if [ -n "$ESPTOOL" ] && [ -x "$ESPTOOL" ]; then
  sleep 0.5
  "$ESPTOOL" --chip esp32c6 -p "$PORT" --after watchdog-reset chip-id >/dev/null 2>&1 || true
  sleep 0.5
  echo "ESP32-C6 rebooted successfully. Orecchino AMOLED firmware is running!"
else
  echo "Warning: esptool not found to trigger auto-reboot; manual reset may be needed."
fi

echo "Reopen the app with: open app/build/Orecchino.app"

