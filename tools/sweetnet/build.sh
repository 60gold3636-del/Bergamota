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
# LaunchServices register tool for sideloaded apps (tools/sweet-install-ipa.sh)
xcrun -sdk iphoneos clang -arch arm64 -mios-version-min=16.0 -O2 -fobjc-arc \
	-framework Foundation "$here/sweetuicache.m" -o "$out/sweetuicache"
codesign -s - -f --entitlements "$here/uicache.entitlements" "$out/sweetuicache"

# sweetmetrics (Bergamota live metrics, docs/BERGAMOTA_METRICS.md): iOS 18, arm64e, then `renegade strip --sign`
# (pacstrip) so the kernel without pointer authentication runs it. Output: research/sweetnet/ios18/sweetmetrics
if [ "${IOS18:-1}" = 1 ]; then
	out18=$out/ios18
	mkdir -p "$out18"
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall \
		-framework CoreFoundation -framework IOKit "$here/sweetmetrics.c" -o "$out18/sweetmetrics"
	codesign -s - -f --entitlements "$here/entitlements.plist" "$out18/sweetmetrics"
	"$here/../renegade/renegade" strip --sign "$out18/sweetmetrics"
	ls -l "$out18/sweetmetrics"
fi
