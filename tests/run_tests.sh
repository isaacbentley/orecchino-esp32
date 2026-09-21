#!/bin/bash
# Run the full test suite: host-side C decoder tests + Swift app tests.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== Generated make/model tables (tools/uas_models.json -> firmware + app)"
python3 tools/gen_uas_models.py --check

echo "== ODID decoder (C, golden vectors from opendroneid/wireshark-dissector)"
cc -std=c11 -Wall -Wextra -O2 tests/odid_test.c -o /tmp/orecchino_odid_test
/tmp/orecchino_odid_test

echo "== Solar position & sundown engine (C, NOAA algorithms)"
cc -std=c11 -Wall -Wextra -O2 tests/solar_test.c -lm -o /tmp/orecchino_solar_test
/tmp/orecchino_solar_test

echo "== Radio cores (C++ against host shims: contact merge, auth assembly, TX off switches)"
c++ -std=c++17 -g -O1 -fsanitize=address,undefined -Wall -Wno-unused-function \
  -Wno-unused-variable -Wno-deprecated-declarations \
  -I tests/host_shim -I firmware/common -I firmware/libraries/Monocypher/src \
  tests/core_test.cpp tests/host_shim/shim.cpp \
  firmware/libraries/Monocypher/src/monocypher.cpp -o /tmp/orecchino_core_test
/tmp/orecchino_core_test

echo "== T5 e-paper board render (C++ against host shims: fitted text, label placement, selection)"
GFX="$HOME/Documents/Arduino/libraries/Adafruit_GFX_Library"
if [ -d "$GFX/Fonts" ]; then
  c++ -std=c++17 -g -O1 -fsanitize=address,undefined -Wall -Wno-unused-function \
    -Wno-unused-variable -Wno-unused-but-set-variable -Wno-deprecated-declarations \
    -I tests/host_shim -I firmware/common -I firmware/orecchino_t5epd -I "$GFX" \
    tests/t5_render_test.cpp tests/host_shim/shim.cpp -o /tmp/orecchino_t5_render
  T5_OUT=/tmp /tmp/orecchino_t5_render     # scenes land in /tmp/t5_*.pgm
else
  echo "(skipped: Adafruit GFX library with its Fonts/ not found at $GFX)"
fi

echo "== App tests (swift-testing)"
cd app
CLT=/Library/Developer/CommandLineTools
# CLT quirk: the swift-testing macro plugin lives in a testing/ subdirectory
# the build backend doesn't search — name it explicitly. A clean retry also
# covers the backend's intermittent macro-resolution loss on incremental
# builds.
BUILD=(swift build --build-tests
       -Xswiftc -plugin-path
       -Xswiftc "$CLT/usr/lib/swift/host/plugins/testing")
if ! "${BUILD[@]}"; then
  echo "(build failed; retrying clean)"
  rm -rf .build
  "${BUILD[@]}"
fi
# CommandLineTools quirk: the Testing runtime isn't on the test bundle's
# search path; PackageFrameworks/ is, so link it in and invoke the helper
# directly. (With full Xcode, plain `swift test` works instead.)
P=.build/out/Products/Debug/PackageFrameworks
mkdir -p "$P"
ln -sf "$CLT/Library/Developer/Frameworks/Testing.framework" "$P/"
ln -sf "$CLT"/Library/Developer/usr/lib/*.dylib "$P/"
"$CLT/usr/libexec/swift/pm/swiftpm-testing-helper" \
  --test-bundle-path "$PWD/.build/out/Products/Debug/OrecchinoTests.xctest/Contents/MacOS/OrecchinoTests" \
  --testing-library swift-testing
