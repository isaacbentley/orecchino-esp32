#!/bin/bash
# Pack firmware/orecchino_sensecap/data into a LittleFS image and flash it
# to the tile partition (offset/size from partitions.csv).
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${1:?usage: pack_fs.sh /dev/cu.usbmodemXXXX}"
DATA=firmware/orecchino_sensecap/data
OFFSET=0x210000
SIZE=0x5E0000   # keep in sync with firmware/orecchino_sensecap/partitions.csv

MKLFS=$(ls ~/Library/Arduino15/packages/esp32/tools/mklittlefs/*/mklittlefs | tail -1)
ESPTOOL=$(ls ~/Library/Arduino15/packages/esp32/tools/esptool_py/*/esptool | tail -1)

IMG=$(mktemp -t orecchino_fs)
"$MKLFS" -c "$DATA" -b 4096 -p 256 -s $((SIZE)) "$IMG"
"$ESPTOOL" --chip esp32s3 -p "$PORT" write-flash "$OFFSET" "$IMG"
rm -f "$IMG"
echo "flashed $(du -h "$DATA" | tail -1 | cut -f1) of data to $OFFSET"
