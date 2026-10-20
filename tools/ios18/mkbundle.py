#!/usr/bin/env python3
"""Build the iOS 18 proof-of-concept bundle from an iOS 18 restore-ramdisk root.

  mkbundle.py RAMDISK_ROOT OUTDIR [--bin NAME ...] [--install-dir /var/root/ios18poc]

The restore ramdisk of an iOS 18 IPSW (IMG4 -> APFS) is a complete on-disk userland: /usr/lib/dyld, a flat
set of libSystem dylibs WITHOUT a shared cache, and a few command-line tools (/bin/cat, /bin/expr, ...), all
arm64e. This script copies the dependency closure of the chosen tools into

  OUTDIR/dyld               the iOS 18 dyld (kernel-loaded dynamic linker)
  OUTDIR/lib/*.dylib        flat directory of every dylib (for DYLD_LIBRARY_PATH; leaf names are unique)
  OUTDIR/bin/NAME           the tools; LC_LOAD_DYLINKER rewritten to <install-dir>/dyld

rewrites every Mach-O with pacstrip.py and re-signs it ad hoc (entitlements kept).
"""
import argparse
import os
import shutil
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PACSTRIP = os.path.join(HERE, 'pacstrip.py')
LC_LOAD_DYLIB, LC_LOAD_WEAK, LC_REEXPORT, LC_LAZY, LC_UPWARD = 0xC, 0x80000018, 0x8000001F, 0x20, 0x80000023


def deps(path):
    b = open(path, 'rb').read()
    ncmds = struct.unpack_from('<I', b, 16)[0]
    off, out = 32, []
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', b, off)
        if cmd in (LC_LOAD_DYLIB, LC_REEXPORT, LC_LAZY, LC_UPWARD):    # weak dependencies may be absent
            s = struct.unpack_from('<I', b, off + 8)[0]
            out.append(b[off + s:off + size].split(b'\0')[0].decode())
        off += size
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('root')
    ap.add_argument('out')
    ap.add_argument('--bin', action='append', default=None)
    ap.add_argument('--install-dir', default='/var/root/ios18poc')
    ap.add_argument('--no-sign', action='store_true')
    a = ap.parse_args()
    bins = a.bin or ['expr', 'cat', 'mkdir', 'ln']
    if os.path.exists(a.out):
        shutil.rmtree(a.out)
    os.makedirs(a.out + '/bin')
    os.makedirs(a.out + '/lib')

    todo, seen, libs = [os.path.join(a.root, 'bin', b) for b in bins], set(), {}
    while todo:
        f = todo.pop()
        for d in deps(f):
            if d in seen:
                continue
            seen.add(d)
            src = os.path.join(a.root, d.lstrip('/'))
            if not os.path.exists(src):
                print(f'warning: {d} (needed by {os.path.basename(f)}) is not in the ramdisk', file=sys.stderr)
                continue
            leaf = os.path.basename(d)
            assert leaf not in libs, f'leaf name clash: {d} vs {libs[leaf]}'
            libs[leaf] = d
            todo.append(src)
    print(f'{len(bins)} tools, {len(libs)} dylibs')

    files = []
    shutil.copy(os.path.join(a.root, 'usr/lib/dyld'), a.out + '/dyld')
    files.append((a.out + '/dyld', []))
    for leaf, d in libs.items():
        shutil.copy(os.path.join(a.root, d.lstrip('/')), a.out + '/lib/' + leaf)
        files.append((a.out + '/lib/' + leaf, []))
    for b in bins:
        shutil.copy(os.path.join(a.root, 'bin', b), a.out + '/bin/' + b)
        files.append((a.out + '/bin/' + b, ['--dylinker', a.install_dir + '/dyld']))
    for p, extra in files:
        os.chmod(p, 0o755)
        cmd = [sys.executable, '-I', PACSTRIP] + extra + ([] if a.no_sign else ['--sign']) + [p]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode:
            sys.exit(f'{p}: {r.stdout}{r.stderr}')
    with open(a.out + '/MANIFEST.txt', 'w') as f:
        for leaf, d in sorted(libs.items()):
            f.write(f'lib/{leaf}  <- {d}\n')
    print('bundle written to', a.out)


if __name__ == '__main__':
    main()
