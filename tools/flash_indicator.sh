#!/bin/bash
# Compile + flash the SenseCAP Indicator target. Quits Orecchino.app first —
# it auto-connects to the CH340 port and its reads corrupt esptool transfers.
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${1:?usage: flash_indicator.sh /dev/cu.usbserialXXXX}"
# LoopCore=1 keeps the app (decode/render/touch) off core 0, where the WiFi
# and BLE stacks live — radios never wait on a map redraw.
FQBN="esp32:esp32:esp32s3:FlashMode=qio,FlashSize=8M,PartitionScheme=custom,PSRAM=opi,CPUFreq=240,UploadSpeed=460800,CDCOnBoot=default,LoopCore=1,EventsCore=1"

pkill -9 -x Orecchino 2>/dev/null || true
sleep 1
arduino-cli compile --jobs 2 --libraries firmware/libraries -b "$FQBN" firmware/orecchino_sensecap
arduino-cli upload -b "$FQBN" -p "$PORT" firmware/orecchino_sensecap
echo "Flashed. Reopen the app with: open app/build/Orecchino.app"
