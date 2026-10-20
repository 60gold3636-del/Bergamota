#!/bin/sh
# Build and ad-hoc sign sweetnetcfg for iOS 16 -> research/sweetnet/sweetnetcfg
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=$here/../../research/sweetnet
mkdir -p "$out"
xcrun -sdk iphoneos clang -arch arm64 -mios-version-min=16.0 -O2 -Wall \
	-framework CoreFoundation "$here/sweetnetcfg.c" -o "$out/sweetnetcfg"
codesign -s - -f --entitlements "$here/entitlements.plist" "$out/sweetnetcfg"
ls -l "$out/sweetnetcfg"
