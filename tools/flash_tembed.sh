#!/bin/bash
# Compile + flash the LilyGO T-Embed CC1101 target. Quits Orecchino.app
# first — it auto-connects to serial ports and its reads corrupt esptool.
set -euo pipefail
cd "$(dirname "$0")/.."

source tools/flash_common.sh

PORT="${1:-}"
if [ -z "$PORT" ]; then
  pick_port "tools/flash_tembed.sh /dev/cu.usbmodemXXXX" /dev/cu.usbmodem* || exit 1
fi

# LoopCore=1 keeps the app (decode/render/encoder) off core 0, where the
# WiFi and BLE stacks live. CDCOnBoot: the T-Embed talks over native USB.
FQBN="esp32:esp32:esp32s3:FlashMode=qio,FlashSize=16M,PartitionScheme=custom,PSRAM=opi,CPUFreq=240,CDCOnBoot=cdc,LoopCore=1,EventsCore=1"

quit_app
arduino-cli compile --jobs 2 --libraries firmware/libraries -b "$FQBN" firmware/orecchino_tembed
arduino-cli upload -b "$FQBN" -p "$PORT" firmware/orecchino_tembed

echo "Upload complete. Exiting USB download bootloader into firmware..."
ESPTOOL="$(find "$HOME/Library/Arduino15/packages/esp32/tools/esptool_py" -name esptool 2>/dev/null | sort -V | tail -n 1 || which esptool || true)"
if [ -n "$ESPTOOL" ] && [ -x "$ESPTOOL" ]; then
  sleep 0.5
  "$ESPTOOL" --chip esp32s3 -p "$PORT" --after watchdog-reset chip-id >/dev/null 2>&1 || true
  sleep 0.5
  echo "ESP32-S3 rebooted successfully. Orecchino T-Embed firmware is running!"
else
  echo "Warning: esptool not found to trigger auto-reboot; manual reset may be needed."
fi

echo "Reopen the app with: open app/build/Orecchino.app"

