#!/bin/bash
# Compile + flash the LilyGO T-Embed CC1101 target. Quits Orecchino.app
# first — it auto-connects to serial ports and its reads corrupt esptool.
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${1:?usage: flash_tembed.sh /dev/cu.usbmodemXXXX}"
# LoopCore=1 keeps the app (decode/render/encoder) off core 0, where the
# WiFi and BLE stacks live. CDCOnBoot: the T-Embed talks over native USB.
FQBN="esp32:esp32:esp32s3:FlashMode=qio,FlashSize=16M,PartitionScheme=custom,PSRAM=opi,CPUFreq=240,CDCOnBoot=cdc,LoopCore=1,EventsCore=1"

pkill -9 -x Orecchino 2>/dev/null || true
sleep 1
arduino-cli compile --jobs 2 --libraries firmware/libraries -b "$FQBN" firmware/orecchino_tembed
arduino-cli upload -b "$FQBN" -p "$PORT" firmware/orecchino_tembed
echo "Flashed. Reopen the app with: open app/build/Orecchino.app"
