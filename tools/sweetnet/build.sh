#!/bin/sh
# Build and ad-hoc sign the on-device tools for iOS 16 -> research/sweetnet/
# (sweetnetcfg, cscheck, hcitest, bluetool-stub, sweetreboot; set TOOLS="hcitest" to build a subset; sweetreboot = reboot-to-fastboot, kernel 0137)
# iOS 18: also research/sweetnet/ios18/{sweetuicache,sweetfp.dylib} (arm64e + pacstrip --sign)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=$here/../../research/sweetnet
mkdir -p "$out"
for t in ${TOOLS:-sweetnetcfg cscheck hcitest bluetool-stub sweetreboot}; do
	ents=$here/entitlements.plist
	case $t in
	cscheck) frameworks="-framework CoreFoundation -framework Security" ;;
	hcitest|sweetreboot) frameworks="" ;;
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

# iOS 18 (Renegade): arm64e builds that the kernel without pointer authentication runs after
# `renegade strip --sign` (pacstrip). Output: research/sweetnet/ios18/ (set IOS18=0 to skip)
if [ "${IOS18:-1}" = 1 ]; then
	out18=$out/ios18
	pacstrip=$here/../renegade/pacstrip.py
	mkdir -p "$out18"
	# sweetuicache: LaunchServices registration, run by the first-boot job (root_tweaks18.firstboot)
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -fobjc-arc \
		-framework Foundation "$here/sweetuicache.m" -o "$out18/sweetuicache"
	codesign -s - -f --entitlements "$here/uicache.entitlements" "$out18/sweetuicache"
	python3 -I "$pacstrip" --sign "$out18/sweetuicache"
	# sweetfp.dylib: NSURLFileProtectionKey shim, linked into PosterBoard (root_tweaks18.posterboard)
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -fobjc-arc -dynamiclib \
		-install_name /usr/local/lib/sweetfp.dylib -framework Foundation \
		"$here/sweetfp.m" -o "$out18/sweetfp.dylib"
	codesign -s - -f "$out18/sweetfp.dylib"
	python3 -I "$pacstrip" --sign "$out18/sweetfp.dylib"
	ls -l "$out18"
fi
