#!/bin/bash
# Run the full test suite: host-side C decoder tests + Swift app tests.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== ODID decoder (C, golden vectors from opendroneid/wireshark-dissector)"
cc -std=c11 -Wall -Wextra -O2 tests/odid_test.c -o /tmp/orecchino_odid_test
/tmp/orecchino_odid_test

echo "== App tests (swift-testing)"
cd app
# The CLT's swiftbuild backend intermittently loses macro-plugin resolution
# on incremental builds; a clean build always works.
if ! swift build --build-tests; then
  echo "(incremental build hit the CLT macro-resolution bug; retrying clean)"
  rm -rf .build
  swift build --build-tests
fi
# CommandLineTools quirk: the Testing runtime isn't on the test bundle's
# search path; PackageFrameworks/ is, so link it in and invoke the helper
# directly. (With full Xcode, plain `swift test` works instead.)
CLT=/Library/Developer/CommandLineTools
P=.build/out/Products/Debug/PackageFrameworks
mkdir -p "$P"
ln -sf "$CLT/Library/Developer/Frameworks/Testing.framework" "$P/"
ln -sf "$CLT"/Library/Developer/usr/lib/*.dylib "$P/"
"$CLT/usr/libexec/swift/pm/swiftpm-testing-helper" \
  --test-bundle-path "$PWD/.build/out/Products/Debug/OrecchinoTests.xctest/Contents/MacOS/OrecchinoTests" \
  --testing-library swift-testing
