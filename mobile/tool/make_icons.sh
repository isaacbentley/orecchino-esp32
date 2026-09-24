#!/bin/sh
# make_icons.sh — rasterise the Orecchino icon and launch mark from the SVG
# masters in branding/ into every iOS and Android size. Needs rsvg-convert
# (brew install librsvg) and sips (macOS). Run from mobile/.
#
# Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
set -eu
cd "$(dirname "$0")/.."
B=branding
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# iOS app icons: opaque, no alpha channel (App Store requirement), square
# (iOS applies its own mask).
IOS=ios/Runner/Assets.xcassets/AppIcon.appiconset
opaque() { # size out
  rsvg-convert -w "$1" -h "$1" -b '#04060C' "$B/icon.svg" -o "$T/a.png"
  sips -s format jpeg -s formatOptions best "$T/a.png" --out "$T/a.jpg" >/dev/null
  sips -s format png "$T/a.jpg" --out "$2" >/dev/null
}
for spec in 20x20@1x:20 20x20@2x:40 20x20@3x:60 29x29@1x:29 29x29@2x:58 29x29@3x:87 \
            40x40@1x:40 40x40@2x:80 40x40@3x:120 60x60@2x:120 60x60@3x:180 \
            76x76@1x:76 76x76@2x:152 83.5x83.5@2x:167 1024x1024@1x:1024; do
  opaque "${spec#*:}" "$IOS/Icon-App-${spec%%:*}.png"
done

# iOS launch mark, 160 pt.
L=ios/Runner/Assets.xcassets/LaunchImage.imageset
rsvg-convert -w 160 -h 160 "$B/launch_mark.svg" -o "$L/LaunchImage.png"
rsvg-convert -w 320 -h 320 "$B/launch_mark.svg" -o "$L/LaunchImage@2x.png"
rsvg-convert -w 480 -h 480 "$B/launch_mark.svg" -o "$L/LaunchImage@3x.png"

# Android: legacy icon (rounded square), adaptive layers (108 dp), launch mark.
R=android/app/src/main/res
sed 's|<g id="sky">|<clipPath id="r"><rect width="1024" height="1024" rx="225"/></clipPath><g id="sky" clip-path="url(#r)">|' \
  "$B/icon.svg" > "$T/rounded.svg"
for d in mdpi:1 hdpi:1.5 xhdpi:2 xxhdpi:3 xxxhdpi:4; do
  dens=${d%%:*}; k=${d#*:}
  px() { echo "$1 * $k / 1" | bc; }
  mkdir -p "$R/mipmap-$dens" "$R/drawable-$dens"
  rsvg-convert -w "$(px 48)" -h "$(px 48)" "$T/rounded.svg" -o "$R/mipmap-$dens/ic_launcher.png"
  rsvg-convert -w "$(px 108)" -h "$(px 108)" "$B/icon_foreground.svg" -o "$R/mipmap-$dens/ic_launcher_foreground.png"
  rsvg-convert -w "$(px 108)" -h "$(px 108)" "$B/icon_background.svg" -o "$R/mipmap-$dens/ic_launcher_background.png"
  rsvg-convert -w "$(px 160)" -h "$(px 160)" "$B/launch_mark.svg" -o "$R/drawable-$dens/launch_mark.png"
done
echo "icons written"
