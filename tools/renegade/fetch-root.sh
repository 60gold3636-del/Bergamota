#!/bin/bash
# Download the iOS 18.7.8 iPhone11,8 root dmg + SystemOS + AppOS cryptex dmgs (about 8.3 GB) and decrypt the two AEA ones.
# Needs ~20 GB free (the .aea files are deleted after decryption). Output: research/ios18/ipsw/22H352__iPhone11,8/*.dmg
set -euo pipefail
cd "$(dirname "$0")/../.."
D=research/ios18/ipsw; mkdir -p $D
ipsw download ipsw --device iPhone11,8 --version 18.7.8 --pattern '^094-(31934|32062|32850)-020\.dmg(\.aea)?$' --flat -y -o $D
python3 tools/remotezip.py "$(ipsw download ipsw --device iPhone11,8 --version 18.7.8 --urls | tail -1)" BuildManifest.plist $D >/dev/null
for a in $D/22H352__iPhone11,8/*.aea; do ipsw fw aea "$a" -o "$D/22H352__iPhone11,8" && rm -f "$a"; done
ls -l $D/22H352__iPhone11,8
