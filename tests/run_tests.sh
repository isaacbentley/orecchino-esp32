#!/bin/bash
# Run the full test suite on the host: generated tables, the T5 flash
# script's clock step, the C/C++ firmware cores (decoder, solar, radio
# cores, fuel gauges, traffic rules, T5 and T-Embed rendering), the Mac app
# (swift-testing) and the phone app (flutter test).
#
# A suite that cannot run here prints a SKIP line, and the skips are listed
# again at the end. ORECCHINO_SKIP="render app mobile" skips those suites on
# purpose (CI runs the app and mobile suites in jobs of their own).
#
# Test binaries go in a private temporary directory, so two runs at once
# don't overwrite each other's. Render scenes still land in /tmp for eyes
# (override with T5_OUT / TEMBED_OUT).
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="$(/usr/bin/mktemp -d -t orecchino_tests)"
trap 'rm -rf "$BIN"' EXIT
SKIPS=()
skip() {       # skip SUITE REASON
  echo "SKIP $1: $2"
  SKIPS+=("$1: $2")
}
wanted() {     # wanted SUITE: not listed in ORECCHINO_SKIP
  case " ${ORECCHINO_SKIP:-} " in *" $1 "*) skip "$1" "ORECCHINO_SKIP"; return 1 ;; esac
}

echo "== Generated make/model tables (tools/uas_models.json -> firmware + app)"
python3 tools/gen_uas_models.py --check

echo "== T5 flash script clock step (bash against a fake board on a pty)"
tests/flash_clock_test.sh

echo "== ODID decoder (C, golden vectors from opendroneid/wireshark-dissector)"
cc -std=c11 -Wall -Wextra -O2 tests/odid_test.c -o "$BIN/odid_test"
"$BIN/odid_test"

echo "== Solar position & sundown engine (C, NOAA algorithms)"
cc -std=c11 -Wall -Wextra -O2 tests/solar_test.c -lm -o "$BIN/solar_test"
"$BIN/solar_test"

echo "== Radio cores (C++ against host shims: contact merge, auth assembly, TX off switches)"
c++ -std=c++17 -g -O1 -fsanitize=address,undefined -Wall -Wextra \
  -I tests/host_shim -I firmware/common -I firmware/libraries/Monocypher/src \
  tests/core_test.cpp tests/host_shim/shim.cpp \
  firmware/libraries/Monocypher/src/monocypher.cpp -o "$BIN/core_test"
"$BIN/core_test"

echo "== Fuel gauges (C++ against simulated BQ27220 and AXP2101 chips)"
c++ -std=c++17 -g -O1 -fsanitize=address,undefined -Wall -Wextra \
  -I firmware/common tests/gauge_test.cpp -o "$BIN/gauge_test"
"$BIN/gauge_test"

echo "== Traffic Rules Engine & Alerts (C++ against golden vectors)"
c++ -std=c++17 -g -O1 -fsanitize=address,undefined -Wall -Wextra \
  -I firmware/common tests/traffic_test.cpp -o "$BIN/traffic_test"
"$BIN/traffic_test"

echo "== T5 Wi-Fi (C++: the real net_sync.h state machine on fake radio/clock/fetch ops, wifi_* commands, TFR/ADS-B/SNTP/tile parsing)"
c++ -std=c++17 -g -O1 -fsanitize=address,undefined -Wall -Wextra \
  -I firmware/common tests/net_test.cpp -o "$BIN/net_test"
"$BIN/net_test"

echo "== T5 e-paper board render (C++ against host shims: fitted text, label placement, selection)"
# The real font bitmaps come from the Adafruit GFX library in the Arduino
# sketchbook (arduino-cli's, or ARDUINO_DIRECTORIES_USER's when set).
GFX="${ARDUINO_DIRECTORIES_USER:-$HOME/Documents/Arduino}/libraries/Adafruit_GFX_Library"
if ! wanted render; then
  :
elif [ ! -d "$GFX/Fonts" ]; then
  skip render "Adafruit GFX library with its Fonts/ not found at $GFX"
else
  c++ -std=c++17 -g -O1 -fsanitize=address,undefined -Wall -Wextra \
    -I tests/host_shim -I firmware/common -I firmware/orecchino_t5epd -I "$GFX" \
    tests/t5_render_test.cpp tests/host_shim/shim.cpp -o "$BIN/t5_render"
  T5_OUT="${T5_OUT:-/tmp}" "$BIN/t5_render"            # scenes land in /tmp/t5_*.pgm
  echo "== T-Embed handheld render (C++ against host shims: text on screen and clear, range rate, partial flush)"
  c++ -std=c++17 -g -O1 -fsanitize=address,undefined -Wall -Wextra \
    -I tests/host_shim -I firmware/common -I firmware/orecchino_tembed -I "$GFX" \
    tests/tembed_render_test.cpp tests/host_shim/shim.cpp -o "$BIN/tembed_render"
  TEMBED_OUT="${TEMBED_OUT:-/tmp}" "$BIN/tembed_render"  # scenes land in /tmp/tembed_*.ppm
fi

echo "== App tests (swift-testing)"
if wanted app; then
  (
    cd app
    CLT=/Library/Developer/CommandLineTools
    if [ "$(xcode-select -p 2>/dev/null)" != "$CLT" ]; then
      swift test     # full Xcode: plain `swift test` finds swift-testing itself
    else
      # CLT quirk: the swift-testing macro plugin lives in a testing/
      # subdirectory the build backend doesn't search — name it explicitly.
      # A clean retry also covers the backend's intermittent
      # macro-resolution loss on incremental builds.
      BUILD=(swift build --build-tests
             -Xswiftc -plugin-path
             -Xswiftc "$CLT/usr/lib/swift/host/plugins/testing")
      if ! "${BUILD[@]}"; then
        echo "(build failed; retrying clean)"
        rm -rf .build
        "${BUILD[@]}"
      fi
      # CommandLineTools quirk: the Testing runtime isn't on the test
      # bundle's search path; PackageFrameworks/ is, so link it in and
      # invoke the helper directly.
      P=.build/out/Products/Debug/PackageFrameworks
      mkdir -p "$P"
      ln -sf "$CLT/Library/Developer/Frameworks/Testing.framework" "$P/"
      ln -sf "$CLT"/Library/Developer/usr/lib/*.dylib "$P/"
      "$CLT/usr/libexec/swift/pm/swiftpm-testing-helper" \
        --test-bundle-path "$PWD/.build/out/Products/Debug/OrecchinoTests.xctest/Contents/MacOS/OrecchinoTests" \
        --testing-library swift-testing
    fi
  )
fi

echo "== Mobile app tests (flutter test)"
if ! wanted mobile; then
  :
elif ! command -v flutter >/dev/null 2>&1; then
  skip mobile "flutter not on PATH"
else
  (cd mobile && flutter test)
fi

if [ ${#SKIPS[@]} -gt 0 ]; then
  echo "== Passed, with ${#SKIPS[@]} suite(s) skipped:"
  printf '   SKIP %s\n' "${SKIPS[@]}"
else
  echo "== All suites passed"
fi
