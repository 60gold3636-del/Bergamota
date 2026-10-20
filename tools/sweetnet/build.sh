#!/bin/sh
# Build and ad-hoc sign the on-device tools for iOS 16 -> research/sweetnet/
# (sweetnetcfg, cscheck; set TOOLS="cscheck" to build a subset)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=$here/../../research/sweetnet
mkdir -p "$out"
for t in ${TOOLS:-sweetnetcfg cscheck}; do
	case $t in
	cscheck) frameworks="-framework CoreFoundation -framework Security" ;;
	*) frameworks="-framework CoreFoundation" ;;
	esac
	xcrun -sdk iphoneos clang -arch arm64 -mios-version-min=16.0 -O2 -Wall \
		$frameworks "$here/$t.c" -o "$out/$t"
	codesign -s - -f --entitlements "$here/entitlements.plist" "$out/$t"
	ls -l "$out/$t"
done
