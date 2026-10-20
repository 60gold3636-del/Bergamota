#!/bin/sh
# Build and ad-hoc sign the on-device tools for iOS 16 -> research/sweetnet/
# (sweetnetcfg, cscheck, hcitest, bluetool-stub; set TOOLS="hcitest" to build a subset)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=$here/../../research/sweetnet
mkdir -p "$out"
for t in ${TOOLS:-sweetnetcfg cscheck hcitest bluetool-stub}; do
	ents=$here/entitlements.plist
	case $t in
	cscheck) frameworks="-framework CoreFoundation -framework Security" ;;
	hcitest) frameworks="" ;;
	bluetool-stub) frameworks=""; ents=$here/bluetool.entitlements ;;
	*) frameworks="-framework CoreFoundation" ;;
	esac
	xcrun -sdk iphoneos clang -arch arm64 -mios-version-min=16.0 -O2 -Wall \
		$frameworks "$here/$t.c" -o "$out/$t"
	codesign -s - -f --entitlements "$ents" "$out/$t"
	ls -l "$out/$t"
done
# LaunchServices register tool for sideloaded apps (tools/sweet-install-ipa.sh)
xcrun -sdk iphoneos clang -arch arm64 -mios-version-min=16.0 -O2 -fobjc-arc \
	-framework Foundation "$here/sweetuicache.m" -o "$out/sweetuicache"
codesign -s - -f --entitlements "$here/uicache.entitlements" "$out/sweetuicache"
