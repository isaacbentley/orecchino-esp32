#!/bin/bash
# Compile + flash the LilyGO T5 E-Paper S3 Pro target. Quits Orecchino.app
# first — it auto-connects to serial ports and its reads corrupt esptool.
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${1:?usage: flash_t5epd.sh /dev/cu.usbmodemXXXX}"
FQBN="esp32:esp32:esp32s3:FlashMode=dio,FlashSize=16M,PartitionScheme=custom,PSRAM=opi,CPUFreq=240,CDCOnBoot=cdc,LoopCore=1,EventsCore=1"

pkill -9 -x Orecchino 2>/dev/null || true
sleep 1
arduino-cli compile --jobs 2 --libraries firmware/libraries -b "$FQBN" firmware/orecchino_t5epd
arduino-cli upload -b "$FQBN" -p "$PORT" firmware/orecchino_t5epd
echo "Flashed. This board parks in its bootloader after a USB reset:"
echo "  power-cycle it now (switch on, BOOT untouched) to start the firmware."
echo "Reopen the app with: open app/build/Orecchino.app"
