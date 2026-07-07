#!/bin/sh
# Run `swift test` using only the Command Line Tools (no full Xcode needed).
#
# The CLT ships Swift Testing, but its `swift test` doesn't wire up the
# framework search paths on its own (unlike Xcode's toolchain). This script
# adds them. Once the Xcode license is accepted, plain `swift test` works and
# this script is unnecessary.
set -eu

CLT=/Library/Developer/CommandLineTools
FW="$CLT/Library/Developer/Frameworks"
INTEROP="$CLT/Library/Developer/usr/lib"

exec env DEVELOPER_DIR="$CLT" swift test \
    -Xswiftc -F -Xswiftc "$FW" \
    -Xlinker -F -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$INTEROP" \
    "$@"
