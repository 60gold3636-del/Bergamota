#!/bin/bash
# Push the iOS 18 proof-of-concept bundle to the phone and run an iOS 18 arm64e tool with iOS 18's dyld.
# Needs: kernel patch 0131 booted with boot-arg sweetarm64e=1, SSH over USB (tools/sweet-mac-nat.sh not required
# for the phone link itself: 192.168.7.2, root, key auth). Nothing here touches the phone's own system files:
# everything lives under /var/root/ios18poc.
#
#   tools/ios18/run-poc.sh                  push (if changed) + run `expr 6 * 7` with dyld diagnostics
#   tools/ios18/run-poc.sh --quiet          same without the DYLD_PRINT_* diagnostics
#   tools/ios18/run-poc.sh --no-push        do not copy the bundle
#   tools/ios18/run-poc.sh -- CMD ARGS...   run another tool of the bundle, e.g. -- cat /etc/hosts
#   env: SWEET_HOST (default root@192.168.7.2), BUNDLE (default research/ios18poc)
set -uo pipefail
cd "$(dirname "$0")/../.."
HOST=${SWEET_HOST:-root@192.168.7.2}
BUNDLE=${BUNDLE:-research/ios18poc}
DIR=/var/root/ios18poc
mkdir -p research/ios18
PUSH=1; DIAG=1
while [ $# -gt 0 ]; do
	case $1 in
	--no-push) PUSH=0 ;;
	--quiet) DIAG=0 ;;
	--) shift; break ;;
	*) break ;;
	esac
	shift
done
if [ $# -eq 0 ]; then set -- expr 6 '*' 7; fi
[ -x "$BUNDLE/dyld" ] || { echo "no bundle in $BUNDLE: run tools/ios18/fetch-ramdisk.sh and tools/ios18/mkbundle.py (docs/IOS18_PORT.md)" >&2; exit 1; }
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8 $HOST"

echo "== phone: $($SSH 'uname -a' 2>&1)"
BA=$($SSH 'sysctl -n kern.bootargs 2>/dev/null' 2>&1)
echo "== boot-args: $BA"
case "$BA" in *sweetarm64e=1*) ;; *) echo "!! boot-args lack sweetarm64e=1: the kernel will refuse the arm64e exec (EBADARCH / 'Bad CPU type')" ;; esac

if [ $PUSH = 1 ]; then
	SUM=$(cat "$BUNDLE/MANIFEST.txt" | shasum | cut -c1-16)-$(stat -f %m "$BUNDLE/dyld")-$(stat -f %m "$BUNDLE/bin/expr")
	if [ "$($SSH "cat $DIR/.stamp 2>/dev/null")" != "$SUM" ]; then
		echo "== pushing $(du -sh "$BUNDLE" | cut -f1) to $HOST:$DIR"
		COPYFILE_DISABLE=1 tar --uid 0 --gid 0 --no-xattrs -C "$BUNDLE" -cf - . |
			$SSH "rm -rf $DIR && mkdir -p $DIR && cd $DIR && tar -xf - && chmod -R go-w . && echo '$SUM' > .stamp" ||
			{ echo "push failed" >&2; exit 1; }
	else
		echo "== bundle already on the phone (stamp $SUM)"
	fi
fi

ENVV="DYLD_LIBRARY_PATH=$DIR/lib"
if [ $DIAG = 1 ]; then
	# DYLD_PRINT_* are honoured only if the AMFI stand-in granted AMFI_DYLD_OUTPUT_ALLOW_PRINT_VARS (0x10).
	ENVV="$ENVV DYLD_PRINT_TO_STDERR=1 DYLD_PRINT_ENV=1 DYLD_PRINT_SEARCHING=1 DYLD_PRINT_LIBRARIES=1 DYLD_PRINT_LOADERS=1 DYLD_PRINT_SEGMENTS=1 DYLD_PRINT_INITIALIZERS=1"
fi
TOOL=$1; shift
ARGS=
for a in "$@"; do ARGS="$ARGS '$a'"; done
echo "== running: $TOOL$ARGS"
$SSH "cd $DIR && env $ENVV $DIR/bin/$TOOL$ARGS; echo \"== exit status \$?\"" 2>&1 | tee research/ios18/last-run.txt
echo "== kernel side (last lines mentioning exec/AMFI/sweet arm64e), if dmesg exists on the phone:"
$SSH "dmesg 2>/dev/null | grep -iE 'arm64e|AMFI|not running|cs_|Killed|EXC_' | tail -n 15" 2>&1
echo "== done; see docs/IOS18_PORT.md for how to read a failure (research/ios18/last-run.txt has the output)"
