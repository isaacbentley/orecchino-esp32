#!/bin/bash
# Run the full test suite: host-side C decoder tests + Swift app tests.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== ODID decoder (C, golden vectors from opendroneid/wireshark-dissector)"
cc -std=c11 -Wall -Wextra -O2 tests/odid_test.c -o /tmp/orecchino_odid_test
/tmp/orecchino_odid_test

echo "== Solar position & sundown engine (C, NOAA algorithms)"
cc -std=c11 -Wall -Wextra -O2 tests/solar_test.c -lm -o /tmp/orecchino_solar_test
/tmp/orecchino_solar_test

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
