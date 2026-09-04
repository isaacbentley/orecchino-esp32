#!/bin/bash
# Compile + flash the Waveshare ESP32-C6-Touch-AMOLED-1.8 target. Quits
# Orecchino.app first — it auto-connects to serial ports and its reads
# corrupt esptool.
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${1:?usage: flash_amoled.sh /dev/cu.usbmodemXXXX}"
FQBN="esp32:esp32:esp32c6:FlashSize=16M,PartitionScheme=custom,CDCOnBoot=cdc"

pkill -9 -x Orecchino 2>/dev/null || true
sleep 1
arduino-cli compile --jobs 2 --libraries firmware/libraries -b "$FQBN" firmware/orecchino_amoled
arduino-cli upload -b "$FQBN" -p "$PORT" firmware/orecchino_amoled
echo "Flashed. Reopen the app with: open app/build/Orecchino.app"
