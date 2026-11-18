#!/bin/bash
# Pack San Francisco raster map tiles into LittleFS and flash to LilyGO T5 E-Paper S3 Pro.
# Partition offset: 0x310000, Size: 0xCF0000 (from firmware/orecchino_t5epd/partitions.csv)
set -euo pipefail
cd "$(dirname "$0")/.."

source tools/flash_common.sh

PORT="${1:-}"
if [ -z "$PORT" ]; then
  pick_port "tools/flash_t5_tiles.sh /dev/cu.usbmodemXXXX" /dev/cu.usbmodem* || exit 1
fi

DATA="firmware/orecchino_sensecap/data"
if [ ! -d "$DATA/tiles" ] && [ -d "$HOME/Library/Application Support/Orecchino/tiles" ]; then
  mkdir -p "$DATA"
  cp -R "$HOME/Library/Application Support/Orecchino/tiles" "$DATA/"
fi

OFFSET=0x310000
SIZE=0xCF0000   # 13,565,952 bytes (partitions.csv littlefs)

MKLFS="$(find "$HOME/Library/Arduino15/packages/esp32/tools/mklittlefs" -name mklittlefs 2>/dev/null | sort -V | tail -n 1 || which mklittlefs || true)"
ESPTOOL="$(find "$HOME/Library/Arduino15/packages/esp32/tools/esptool_py" -name esptool 2>/dev/null | sort -V | tail -n 1 || which esptool || true)"

if [ -z "$MKLFS" ] || [ ! -x "$MKLFS" ]; then
  echo "Error: mklittlefs not found in Arduino15 tools."
  exit 1
fi
if [ -z "$ESPTOOL" ] || [ ! -x "$ESPTOOL" ]; then
  echo "Error: esptool not found."
  exit 1
fi

echo "Packing $DATA into LittleFS image (size $SIZE bytes)..."
IMG="$(mktemp -t orecchino_t5_fs.bin)"
trap 'rm -f "$IMG"' EXIT   # a failed or interrupted flash must not strand the 13 MB image
"$MKLFS" -c "$DATA" -b 4096 -p 256 -s $((SIZE)) "$IMG"

quit_app

echo "Flashing LittleFS image to $PORT at offset $OFFSET..."
"$ESPTOOL" --chip esp32s3 -p "$PORT" -b 921600 --before default_reset --after hard_reset write_flash "$OFFSET" "$IMG"

echo "San Francisco map tiles successfully flashed to T5 LittleFS!"
