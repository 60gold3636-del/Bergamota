#!/bin/sh
# Apply the Bluetooth userland changes to the LIVE phone over SSH (no reflash):
#   tools/sweet-bt-install.sh            install: bluetoothd env + BlueTool stub + hcitest
#   tools/sweet-bt-install.sh -n         dry run: pull and edit launchd.plist on the Mac, show the
#                                        diff, change nothing on the phone
#   tools/sweet-bt-install.sh -u         uninstall: put the backups back
#
# What it does (docs/BT_IOS_TRANSPORT.md, "Phone test order"):
#  1. pulls /System/Library/xpc/launchd.plist (the cache launchd really reads),
#     keeps a copy in research/bt-install/ and on the phone (launchd.plist.pre-bt, written once),
#     sets BT_HCI_TRANSPORT / BT_DEVICE_ADDRESS in the com.apple.bluetoothd job with plistlib
#     (tools/sweet-root-tweaks.py --bt-plist) and pushes it back;
#  2. installs research/sweetnet/bluetool-stub as /usr/sbin/BlueTool, the original is kept as
#     /usr/sbin/BlueTool.orig (written once);
#  3. installs research/sweetnet/hcitest as /usr/local/bin/hcitest.
# launchd reads its cache at boot: reboot afterwards (the kernel needs sweetwlan=2 sweetbt=1 anyway).
# Build the binaries first: TOOLS="hcitest bluetool-stub" tools/sweetnet/build.sh
set -eu
host=${SWEET_HOST:-root@192.168.7.2}
here=$(cd "$(dirname "$0")" && pwd)
net=$here/../research/sweetnet
keep=$here/../research/bt-install
lp=/System/Library/xpc/launchd.plist
mode=install
case ${1:-} in
-n) mode=dry ;;
-u) mode=uninstall ;;
'') ;;
*) echo "usage: sweet-bt-install.sh [-n|-u]" >&2; exit 2 ;;
esac

mkdir -p "$keep"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if [ "$mode" = uninstall ]; then
	ssh "$host" "set -e
		[ -e $lp.pre-bt ] && cat $lp.pre-bt > $lp && echo 'launchd.plist restored'
		[ -e /usr/sbin/BlueTool.orig ] && cp -p /usr/sbin/BlueTool.orig /usr/sbin/BlueTool.new && mv -f /usr/sbin/BlueTool.new /usr/sbin/BlueTool && echo 'BlueTool restored'
		rm -f /usr/local/bin/hcitest; sync"
	echo "done: reboot to make launchd read the restored cache"
	exit 0
fi

for f in "$net/bluetool-stub" "$net/hcitest"; do
	[ -x "$f" ] || { echo "missing $f: run TOOLS=\"hcitest bluetool-stub\" tools/sweetnet/build.sh" >&2; exit 1; }
done

scp -O -q "$host:$lp" "$tmp/launchd.plist"
cp "$tmp/launchd.plist" "$keep/launchd.plist.pulled-$(date +%Y%m%d-%H%M%S)"
python3 "$here/sweet-root-tweaks.py" --bt-plist "$tmp/launchd.plist" "$tmp/launchd.plist.new"
python3 - "$tmp/launchd.plist" "$tmp/launchd.plist.new" <<'PY'
import plistlib, sys
a, b = (plistlib.load(open(p, 'rb'))['LaunchDaemons'] for p in sys.argv[1:3])
for k in b:
    if a.get(k) != b[k]:
        print('changed job', k, b[k].get('EnvironmentVariables'))
PY
if [ "$mode" = dry ]; then
	echo "dry run: nothing changed on the phone"
	exit 0
fi

# launchd.plist: backup once, then overwrite in place (keeps owner and mode)
scp -O -q "$tmp/launchd.plist.new" "$host:/private/var/tmp/launchd.plist.bt"
ssh "$host" "set -e
	[ -e $lp.pre-bt ] || cp -p $lp $lp.pre-bt
	cat /private/var/tmp/launchd.plist.bt > $lp
	rm -f /private/var/tmp/launchd.plist.bt
	[ -e /usr/sbin/BlueTool.orig ] || cp -p /usr/sbin/BlueTool /usr/sbin/BlueTool.orig
	mkdir -p /usr/local/bin"
# BlueTool stub: copy beside, then rename over the old one
scp -O -q "$net/bluetool-stub" "$host:/usr/sbin/BlueTool.new"
scp -O -q "$net/hcitest" "$host:/usr/local/bin/hcitest"
ssh "$host" "set -e
	chown 0:0 /usr/sbin/BlueTool.new /usr/local/bin/hcitest
	chmod 755 /usr/sbin/BlueTool.new /usr/local/bin/hcitest
	mv -f /usr/sbin/BlueTool.new /usr/sbin/BlueTool
	sync"
echo "installed: launchd.plist (backup $lp.pre-bt), BlueTool stub (original BlueTool.orig), /usr/local/bin/hcitest"
echo "reboot the phone so launchd reads the cache; log: /private/var/tmp/bluetool-stub.log"
