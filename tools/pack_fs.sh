#!/bin/bash
# Pack firmware/orecchino_sensecap/data into a LittleFS image and flash it
# to the tile partition (offset/size from partitions.csv).
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${1:?usage: pack_fs.sh /dev/cu.usbmodemXXXX}"
DATA=firmware/orecchino_sensecap/data
OFFSET=0x210000
SIZE=0x5E0000   # keep in sync with firmware/orecchino_sensecap/partitions.csv

# The newest installed version of each esp32 core tool (one directory per
# version under tools/<name>/).
TOOLS=~/Library/Arduino15/packages/esp32/tools
MKLFS=$(find "$TOOLS/mklittlefs" -mindepth 2 -maxdepth 2 -name mklittlefs | sort | tail -n 1)
ESPTOOL=$(find "$TOOLS/esptool_py" -mindepth 2 -maxdepth 2 -name esptool | sort | tail -n 1)
[ -n "$MKLFS" ] && [ -n "$ESPTOOL" ] || { echo "mklittlefs/esptool not found under $TOOLS; install the esp32 core first" >&2; exit 1; }

IMG=$(mktemp -t orecchino_fs)
trap 'rm -f "$IMG"' EXIT   # also when mklittlefs or esptool fails
"$MKLFS" -c "$DATA" -b 4096 -p 256 -s $((SIZE)) "$IMG"
"$ESPTOOL" --chip esp32s3 -p "$PORT" write-flash "$OFFSET" "$IMG"
echo "flashed $(du -h "$DATA" | tail -1 | cut -f1) of data to $OFFSET"
