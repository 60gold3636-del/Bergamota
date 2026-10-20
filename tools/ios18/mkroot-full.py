#!/usr/bin/env python3
"""Build the FULL iOS 18.7.8 (iPhone11,8, 22H352) root as a flashable HFS+ image for the userdata partition.

  mkroot-full.py [--ipsw-dir DIR] [--out IMG] [--size 20g] [--stages copy,macho,cache,tweaks,seal] [--simg OUT.simg]

No sudo. Stages (each one can be re-run on the same image; the image stays in --out between stages):
  copy    attach the IPSW volumes read-only (OS dmg, SystemOS cryptex, AppOS cryptex; decrypt them first with
          tools/ios18/fetch-root.sh), newfs_hfs -s (case-sensitive, NOT journaled: hfsroot_owners.py edits the
          catalog), mount the image as the user, ditto OS-cryptex and App-cryptex FIRST and the OS volume on top
          (root files win), layout fixes (cache at /System/Library/Caches/com.apple.dyld, /System/Cryptexes/*
          -> merged view), owner/mode map of everything (lstat of the mounted IPSW volumes, owners on)
  macho   pacstrip + ad-hoc codesign (entitlements kept) of every Mach-O, in parallel, hard links kept
  cache   tools/ios18/pacstrip_cache.py over the dyld shared cache (code sections, signature page hashes)
  tweaks  the iOS 16 first-boot tweaks (root_tweaks18.py = sweet-root-tweaks.py) + iOS 18 launchd bring-up jobs
  seal    unmount, hfsroot_owners.py (real owners/modes, the rest root:wheel), fsck_hfs, offline checks,
          img2simg --consume (the raw image is turned into the .simg, see tools/ios18/img2simg.py)
Disk is tight: every stage checks `df` and stops below 5 GiB free.
"""
import argparse
import os
import shutil
import subprocess
import sys
import time
import unicodedata
from collections import Counter
from multiprocessing import Pool

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, HERE)
import pacstrip  # noqa: E402

MAGICS = {b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'}
MIN_FREE = 5 << 30
W = os.path.join(ROOT, 'research/ios18/full')              # work dir (mount points, map)


def log(*a):
    print(time.strftime('%H:%M:%S'), *a, flush=True)


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, text=True, **kw)


def free_bytes(path=ROOT):
    st = os.statvfs(path)
    return st.f_bavail * st.f_frsize


def need_free(what):
    fb = free_bytes()
    log(f'free disk: {fb / 2**30:.1f} GiB ({what})')
    if fb < MIN_FREE:
        sys.exit(f'STOP: only {fb / 2**30:.1f} GiB free (< 5 GiB) before {what}')


def attach(img, mnt, readonly=True, owners=False):
    os.makedirs(mnt, exist_ok=True)
    cmd = ['hdiutil', 'attach', '-nobrowse', '-mountpoint', mnt]
    if readonly:
        cmd += ['-readonly', '-noverify']
    if owners:
        cmd += ['-owners', 'on']
    # the decrypted IPSW dmgs and the HFS image are raw volumes: CRawDiskImage
    cmd += ['-imagekey', 'diskimage-class=CRawDiskImage']
    out = run(cmd + [img], capture_output=True).stdout
    return out.split()[0]


def detach(dev):
    subprocess.run(['hdiutil', 'detach', dev], capture_output=True)


def find_dmgs(d):
    """OS, SystemOS and AppOS dmgs by BuildManifest path (decrypted names without .aea)."""
    import plistlib
    mf = None
    for c in (os.path.join(d, 'BuildManifest.plist'), os.path.join(os.path.dirname(d), 'BuildManifest.plist')):
        if os.path.exists(c):
            mf = c
            break
    m = plistlib.load(open(mf, 'rb'))['BuildIdentities'][0]['Manifest']
    out = {}
    for key, name in (('OS', 'os'), ('Cryptex1,SystemOS', 'sysos'), ('Cryptex1,AppOS', 'appos')):
        p = m[key]['Info']['Path']
        if p.endswith('.aea'):
            p = p[:-4]
        out[name] = os.path.join(d, p)
    return out


def walk_owners(mnt, table):
    """lstat() of everything under mnt into table[relpath NFD] = (uid, gid, perm bits)."""
    n = 0
    for root, dirs, files in os.walk(mnt):
        rel = os.path.relpath(root, mnt)
        rel = '' if rel == '.' else rel
        for name in dirs + files:
            p = os.path.join(root, name)
            try:
                st = os.lstat(p)
            except OSError:
                continue
            r = (rel + '/' + name) if rel else name
            if '\t' in r or '\n' in r:
                continue
            table[unicodedata.normalize('NFD', r)] = (st.st_uid, st.st_gid, st.st_mode & 0o7777)
            n += 1
    st = os.lstat(mnt)
    table[''] = (st.st_uid, st.st_gid, st.st_mode & 0o7777)
    return n


def write_map(table, path):
    with open(path, 'w', encoding='utf-8', errors='surrogateescape') as f:
        for k in sorted(table):
            u, g, m = table[k]
            f.write(f'{k}\t{u}\t{g}\t{m:o}\n')


def load_map(path):
    t = {}
    for line in open(path, encoding='utf-8', errors='surrogateescape'):
        k, u, g, m = line.rstrip('\n').split('\t')
        t[k] = (int(u), int(g), int(m, 8))
    return t


# --- stage: copy ----------------------------------------------------------------------------------------------------
def apparent_size(mnt):
    tot = 0
    for r, d, fs in os.walk(mnt):
        for f in fs:
            try:
                st = os.lstat(os.path.join(r, f))
            except OSError:
                continue
            if (st.st_mode & 0o170000) == 0o100000:
                tot += st.st_size
    return tot


EXCLUDE = {
    # path -> why (disk is tight: 5 GiB free floor on the 27 GiB Mac while the 7 GiB OS dmg is still attached)
    'usr/standalone/update': 'OTA update ramdisk firmware, 206 MB',
    'System/Library/NanoTimeKit': 'Apple Watch face resources, 284 MB',
}


def copy_tree(src, dst, rel=''):
    """ditto src -> dst, minus EXCLUDE (directories on the way to an excluded path are made by hand)."""
    ex = [e for e in EXCLUDE if e == rel or e.startswith(rel + '/')] if rel else list(EXCLUDE)
    if not ex:
        r = subprocess.run(['ditto', '--nohfsCompression', '--nopreserveHFSCompression', '--noextattr', '--noqtn',
                            '--norsrc', '--noacl', src, dst], capture_output=True, text=True)
        return r.returncode, r.stderr
    err, rc = '', 0
    os.makedirs(dst, exist_ok=True)
    shutil.copymode(src, dst)
    for n in sorted(os.listdir(src)):
        crel = (rel + '/' + n) if rel else n
        if crel in EXCLUDE:
            continue
        s2, d2 = os.path.join(src, n), os.path.join(dst, n)
        if os.path.islink(s2):                      # ditto would FOLLOW a symlink given as the source
            if os.path.lexists(d2):
                os.unlink(d2)
            os.symlink(os.readlink(s2), d2)
            continue
        if os.path.isdir(s2):
            r, e = copy_tree(s2, d2, crel)
        else:
            x = subprocess.run(['ditto', '--nohfsCompression', '--nopreserveHFSCompression', '--noextattr', '--noqtn',
                                '--norsrc', '--noacl', s2, d2], capture_output=True, text=True)
            r, e = x.returncode, x.stderr
        rc |= r
        err += e
    return rc, err


def stage_copy(a, img, rootmnt, dmgs):
    """Per source: owners-on mount (owner map; root-only files are unreadable there), then a noowners mount for
    the copy (every file readable by the user). The cryptexes go in first, the OS volume on top."""
    need_free('copy stage')
    for k, v in dmgs.items():
        if not os.path.exists(v) and k not in (a.skip_sources or '').split(','):
            sys.exit(f'missing {k} dmg {v}: run tools/ios18/fetch-root.sh')
    table = {}
    skip = set(a.skip_sources.split(',')) if a.skip_sources else set()
    if skip:                                     # resume: the image already holds those sources
        if not os.path.ismount(rootmnt):
            attach(img, rootmnt, readonly=False)
    else:
        if os.path.exists(img):
            detach_all(img)
            os.unlink(img)
        run(['mkfile', '-n', a.size, img])
        d = run(['hdiutil', 'attach', '-nomount', '-imagekey', 'diskimage-class=CRawDiskImage', img],
                capture_output=True).stdout.split()[0]
        run(['newfs_hfs', '-s', '-v', 'iOSRoot', d.replace('/disk', '/rdisk')], capture_output=True)
        detach(d)
        attach(img, rootmnt, readonly=False)
    log('image mounted at', rootmnt)
    for name in ('appos', 'sysos', 'os'):
        if name in skip:
            continue
        mnt = os.path.join(W, 'src-' + name)
        dev = attach(dmgs[name], mnt, owners=True)
        n = walk_owners(mnt, table)
        size = apparent_size(mnt) - sum(apparent_size(os.path.join(mnt, e)) for e in EXCLUDE
                                        if os.path.isdir(os.path.join(mnt, e)))
        detach(dev)
        log(f'owner map: {name} {n} entries, {size / 2**30:.2f} GiB apparent')
        if free_bytes() < size + MIN_FREE:
            sys.exit(f'STOP: copying {name} ({size / 2**30:.1f} GiB) would leave < 5 GiB free '
                     f'({free_bytes() / 2**30:.1f} GiB free now)')
        dev = attach(dmgs[name], mnt, owners=False)
        t0 = time.time()
        rc, err = copy_tree(mnt, rootmnt)
        detach(dev)
        lines = [l for l in err.splitlines() if l.strip()]
        # OS-volume symlinks like Frameworks/WebKit.framework -> /System/Cryptexes/OS/... meet the real directory
        # of the merged cryptex: ditto says "Is a directory" and leaves the directory, which is what we want
        real = [l for l in lines if not l.endswith('Is a directory')]
        log(f'ditto {name}: rc={rc} {time.time() - t0:.0f}s, {len(lines)} messages ({len(lines) - len(real)} '
            f'symlink-vs-directory, kept as directories)', '; '.join(real)[:2000])
        if rc and real:
            sys.exit(f'ditto {name} failed')
        prune_after(rootmnt, name)
        if a.delete_sources:
            os.unlink(dmgs[name])
            log('deleted', dmgs[name])
        subprocess.run(['df', '-h', rootmnt, ROOT])
    if skip:
        prev = os.path.join(W, 'owners.tsv')
        old = load_map(prev) if os.path.exists(prev) else {}
        old.update(table)
        table = old
    write_map(table, os.path.join(W, 'owners.tsv'))
    layout_fixes(rootmnt)


def detach_all(img):
    out = subprocess.run(['hdiutil', 'info'], capture_output=True, text=True).stdout
    # detach every device that was attached from this image path
    dev = None
    for line in out.splitlines():
        if line.startswith('image-path') and os.path.abspath(img) in line:
            dev = True
        elif dev and line.startswith('/dev/disk'):
            detach(line.split()[0])
            dev = None
        elif line.startswith('====='):
            dev = None


def prune_after(root, name):
    """Things that are dead weight on the phone (disk is tight, and so is the flash)."""
    if name == 'sysos':
        # 870 MB of local symbols for symbolication; dyld does not read it
        for f in os.listdir(os.path.join(root, 'System/Library/Caches/com.apple.dyld')):
            if f.endswith('.symbols'):
                os.unlink(os.path.join(root, 'System/Library/Caches/com.apple.dyld', f))
                log('removed cache', f)
    if name == 'os':
        shutil.rmtree(os.path.join(root, 'usr/standalone/update'), ignore_errors=True)   # OTA ramdisk firmware, 206 MB


def layout_fixes(root):
    for junk in ('.Spotlight-V100', '.fseventsd', '.Trashes', '.DocumentRevisions-V100', '.TemporaryItems'):
        shutil.rmtree(os.path.join(root, junk), ignore_errors=True)
    # The OS volume's /System/Cryptexes/{OS,App} point at ../../private/preboot/Cryptexes/{OS,App}, the mount
    # points of the cryptexes. The kernel has no cryptex mounting and the cryptex files are merged into the
    # root instead, so those two names become symlinks to / (cryptex path /System/Library/X == root path
    # /System/Library/X): /System/Cryptexes/OS/System/Library/Caches/com.apple.dyld is the real cache dir.
    cr = os.path.join(root, 'private/preboot/Cryptexes')
    os.makedirs(cr, exist_ok=True)
    for n in ('OS', 'App'):
        p = os.path.join(cr, n)
        if os.path.lexists(p):
            os.unlink(p)
        os.symlink('../../..', p)
    dyld = os.path.join(root, 'System/Library/Caches/com.apple.dyld')
    assert os.path.exists(os.path.join(dyld, 'dyld_shared_cache_arm64e')), 'no dyld cache in the root'
    log('layout: cache at /System/Library/Caches/com.apple.dyld,', len(os.listdir(dyld)), 'files; cryptex mount points -> /')


# --- stage: macho ---------------------------------------------------------------------------------------------------
def macho_worker(path):
    try:
        with open(path, 'rb') as f:
            if f.read(4) not in MAGICS:
                return path, None, None
        buf = bytearray(open(path, 'rb').read())
        orig = bytes(buf)
        counts, fj = Counter(), []
        for base in pacstrip.slices(buf):
            pacstrip.process_slice(buf, base, True, False, os.path.basename(path), counts, fj)
        if bytes(buf) == orig:
            return path, 'clean', dict(counts)
        os.chmod(path, os.stat(path).st_mode | 0o200)
        with open(path, 'wb') as f:
            f.write(buf)
        pacstrip.sign(path)
        return path, 'rewritten', dict(counts)
    except BaseException as e:             # report, keep going
        return path, 'FAILED: ' + str(e)[:300], None


def stage_macho(a, root):
    need_free('macho stage')
    skip_prefix = os.path.join(root, 'System/Library/Caches/com.apple.dyld')
    inode_first, links, files = {}, [], []
    for r, dirs, fs in os.walk(root):
        if r.startswith(skip_prefix):
            dirs[:] = []
            continue
        for f in fs:
            p = os.path.join(r, f)
            try:
                st = os.lstat(p)
            except OSError:
                continue
            if not (st.st_mode & 0o170000) == 0o100000 or st.st_size < 32:
                continue
            key = (st.st_dev, st.st_ino)
            if key in inode_first:
                links.append((inode_first[key], p))
                continue
            inode_first[key] = p
            files.append(p)
    log(f'{len(files)} regular files ({len(links)} extra hard links) to inspect')
    t0 = time.time()
    stats, failed = Counter(), []
    totals = Counter()
    rewritten = set()
    with Pool(a.jobs) as pool:
        for i, (p, status, counts) in enumerate(pool.imap_unordered(macho_worker, files, chunksize=16)):
            if status is None:
                continue
            stats[status.split(':')[0]] += 1
            if status.startswith('FAILED'):
                failed.append((p, status))
            elif status == 'rewritten':
                rewritten.add(p)
                totals.update(counts)
            if i % 20000 == 0:
                log(f'  {i}/{len(files)} {dict(stats)}')
    # hard links: codesign may have replaced the inode, re-link
    relinked = 0
    for first, other in links:
        if first in rewritten:
            os.unlink(other)
            os.link(first, other)
            relinked += 1
    log(f'macho: {dict(stats)}, {relinked} hard links re-linked, {time.time() - t0:.0f}s')
    log('rewritten classes:', ', '.join(f'{k}={v}' for k, v in sorted(totals.items())))
    for p, s in failed[:40]:
        log('  ', p, s)
    if failed:
        open(os.path.join(W, 'macho-failed.txt'), 'w').write('\n'.join(f'{p}\t{s}' for p, s in failed))
        log(f'{len(failed)} failures listed in research/ios18/full/macho-failed.txt')


# --- stage: cache ---------------------------------------------------------------------------------------------------
def stage_cache(a, root):
    need_free('cache stage')
    d = os.path.join(root, 'System/Library/Caches/com.apple.dyld')
    run([sys.executable, '-I', os.path.join(HERE, 'pacstrip_cache.py'), d, '--jobs', str(a.jobs)])


# --- stage: tweaks --------------------------------------------------------------------------------------------------
MAIN_CHECKOUT = os.path.abspath(os.path.join(ROOT, '..', 'ios-beryllium'))
OWNER_EXTRA = os.path.join(W, 'owners-extra.tsv')
JOB = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>{label}</string>
<key>ProgramArguments</key><array>{args}</array>
<key>RunAtLoad</key><true/>
<key>StandardOutPath</key><string>/dev/console</string>
<key>StandardErrorPath</key><string>/dev/console</string>
<key>EnvironmentVariables</key><dict><key>OS_ACTIVITY_DT_MODE</key><string>YES</string></dict>
</dict></plist>
"""


def stage_tweaks(a, root):
    import importlib.util
    import plistlib
    spec = importlib.util.spec_from_file_location('root_tweaks18', os.path.join(HERE, 'root_tweaks18.py'))
    rt = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(rt)
    rt.SSH_OUT = os.path.join(MAIN_CHECKOUT, 'research/ssh-build/out')
    rt.NETCFG = os.path.join(MAIN_CHECKOUT, 'research/sweetnet/sweetnetcfg')
    rt.REBOOT_TOOL = os.path.join(MAIN_CHECKOUT, 'research/sweetnet/sweetreboot')
    chowned = {}

    def fake_chown(path, uid, gid, **kw):          # no sudo: owners are written into the HFS catalog at seal time
        chowned[os.path.abspath(path)] = (uid, gid)
    rt.os.chown = fake_chown                       # rt.os is the os module: only this process is affected
    try:
        log('--- launchd.plist (PanicOnCrash, CommCenter), containers, usbnet, netcfg, sweetreboot, ssh')
        rt.launchd(root)
        rt.containers(root)
        chowned[os.path.join(root, 'private/var/containers/Bundle')] = (33, 33)
        rt.usbnet(root)
        rt.netcfg(root)
        rt.sweetreboot(root)
        rt.ssh(root)
        rt.audio(root)
        rt.merge_pref(root, 'com.apple.migration', {
            'LastSystemVersion': rt.BUILD, 'DMUserDataDisposition': {'SyntheticDidUpgrade': False, 'buildVersion': rt.BUILD}})
        rt.merge_pref(root, 'com.apple.springboard', {
            'BKNoWatchdogs': True, 'FBLaunchWatchdogExceptions': {'com.apple.purplebuddy': 100.0},
            'MCForceShowCloudConfigurationUI': False})
        rt.merge_pref(root, 'com.apple.purplebuddy', {
            'SetupDone': True, 'SetupFinishedAllSteps': True, 'SetupVersion': 11, 'daemonizeNeedsToRun': False})
        rt.merge_pref(root, 'com.apple.purplebuddy.notbackedup', {
            k: False for k in ('ShouldRunDiagnosticsMiniBuddy', 'ShouldRunHSA2MiniBuddy', 'ShouldRunKeychainSyncMiniBuddy',
                               'ShouldRunMesaMiniBuddy', 'ShouldRunPaymentMiniBuddy', 'ShouldRunStandardMiniBuddy',
                               'SilentICDPUpgrade')})
        rt.merge_pref(root, 'com.apple.managedconfiguration.notbackedup',
                      {'LockdownActivationIndicatesCloudConfigurationAvailable': False})

        # a console job that shows at once whether launchd 18 runs jobs (the full OS has no /bin/expr or /bin/cat:
        # /bin/sh is the dash from the ssh tweak, toybox the rest)
        lpath = os.path.join(root, 'System/Library/xpc/launchd.plist')
        st = os.stat(lpath)
        plist = rt.load(lpath)
        label = 'org.sweet.ios18.hello'
        jpath = f'/System/Library/LaunchDaemons/{label}.plist'
        if os.path.exists(os.path.join(root, 'bin/sh')):
            args = ('/bin/sh', '-c', 'echo "SWEET iOS18 full root: launchd runs jobs, 6*7=$((6*7))"; '
                    '/usr/local/bin/toybox uname -a; /usr/local/bin/toybox cat /etc/master.passwd')
            xml = JOB.format(label=label, args=''.join(f'<string>{x}</string>' for x in args))
            open(os.path.join(root, jpath.lstrip('/')), 'w').write(xml)
            os.chmod(os.path.join(root, jpath.lstrip('/')), 0o644)
            plist['LaunchDaemons'][jpath] = plistlib.loads(xml.encode())
            log('bring-up job', label)
        rt.save(lpath, plist, st.st_uid, st.st_gid, st.st_mode & 0o7777)
    finally:
        pass
    # logd stores and the system keybag of the built-in AppleKeyStore (same as tools/mkiosroot-macos.sh)
    for d in ('private/var/db/diagnostics', 'private/var/db/uuidtext', 'private/var/db/diagnostics/timesync'):
        os.makedirs(os.path.join(root, d), exist_ok=True)
        chowned[os.path.join(root, d)] = (272, 272)
        m = os.path.join(root, d, '.migrated')
        open(m, 'a').close()
        os.chmod(m, 0o644)
        chowned[m] = (272, 272)
    os.chmod(os.path.join(root, 'private/var/db/diagnostics'), 0o751)
    kb = os.path.join(root, 'private/var/keybags')
    os.makedirs(kb, exist_ok=True)
    os.chmod(kb, 0o700)
    kf = os.path.join(kb, 'systembag.kb')
    open(kf, 'w').write('<?xml version="1.0" encoding="UTF-8"?>\n'
                        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
                        '<plist version="1.0"><dict><key>KeyBagKeys</key><data>U1dFRVQ=</data></dict></plist>\n')
    os.chmod(kf, 0o600)
    # wallpapers (task: defaults present)
    for w in ('Library/Wallpaper', 'System/Library/PrivateFrameworks/PosterBoard.framework'):
        log('present:', w, os.path.isdir(os.path.join(root, w)))
    prev = {}
    if os.path.exists(OWNER_EXTRA):                  # idempotent re-runs keep the earlier overrides
        prev = {os.path.join(root, k): v[:2] for k, v in load_map(OWNER_EXTRA).items()}
    prev.update(chowned)
    chowned = prev
    with open(OWNER_EXTRA, 'w') as f:
        for p, (u, g) in sorted(chowned.items()):
            if not os.path.lexists(p):
                continue
            rel = os.path.relpath(p, root)
            if rel.startswith('..') or '\t' in rel:
                continue
            f.write(f'{unicodedata.normalize("NFD", rel)}\t{u}\t{g}\t{os.lstat(p).st_mode & 0o7777:o}\n')
    log(f'{len(chowned)} owner overrides in {OWNER_EXTRA}')


# --- stages: seal / verify / simg -----------------------------------------------------------------------------------
def stage_seal(a, img, rootmnt):
    """Unmount, apply the owner map to the catalog, fsck."""
    if os.path.ismount(rootmnt):
        subprocess.run(['sync'])
        r = subprocess.run(['hdiutil', 'detach', rootmnt], capture_output=True, text=True)
        if r.returncode:
            sys.exit('detach failed: ' + r.stderr)
    run([sys.executable, '-I', os.path.join(HERE, 'hfs_trim.py'), img])        # give freed blocks back to the host
    table = load_map(os.path.join(W, 'owners.tsv'))
    if os.path.exists(OWNER_EXTRA):
        table.update(load_map(OWNER_EXTRA))
    merged = os.path.join(W, 'owners-final.tsv')
    write_map(table, merged)
    run([sys.executable, '-I', os.path.join(HERE, 'hfsroot_owners.py'), img, '--map', merged, '--default-root'])
    d = run(['hdiutil', 'attach', '-nomount', '-imagekey', 'diskimage-class=CRawDiskImage', img],
            capture_output=True).stdout.split()[0]
    try:
        r = subprocess.run(['fsck_hfs', '-fn', d.replace('/disk', '/rdisk')], capture_output=True, text=True)
        log('fsck_hfs -fn rc=', r.returncode, (r.stdout + r.stderr).strip()[-600:])
        if r.returncode:
            sys.exit('fsck_hfs reports errors')
    finally:
        detach(d)


def stage_verify(a, img, rootmnt):
    import random
    dev = attach(img, rootmnt, readonly=True, owners=True)
    ok = True
    try:
        def chk(c, msg):
            nonlocal ok
            log(('OK   ' if c else 'FAIL ') + msg)
            ok = ok and c
        R = rootmnt
        for p in ('sbin/launchd', 'usr/lib/dyld', 'System/Library/CoreServices/SpringBoard.app/SpringBoard',
                  'usr/libexec/xpcproxy', 'System/Library/xpc/launchd.plist', 'Library/Wallpaper/Collections',
                  'System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e', 'bin/sh',
                  'System/Library/CoreServices/SystemVersion.plist'):
            chk(os.path.exists(os.path.join(R, p)), 'exists /' + p)
        n = len(os.listdir(os.path.join(R, 'Library/Wallpaper/Collections')))
        chk(n > 0, f'Library/Wallpaper/Collections has {n} entries')
        pb = os.path.join(R, 'System/Library/PrivateFrameworks/PosterBoard.framework')
        chk(os.path.isdir(pb), 'PosterBoard.framework present')
        cd = os.path.join(R, 'System/Library/Caches/com.apple.dyld')
        files = os.listdir(cd)
        chk(len(files) == 67 - 0 or len(files) >= 66, f'{len(files)} files in the cache dir (no .symbols)')
        st = os.lstat(os.path.join(R, 'sbin/launchd'))
        chk(st.st_uid == 0 and st.st_gid == 0, f'launchd owner {st.st_uid}:{st.st_gid}')
        for rel in ('private/var/mobile', 'private/var/db/diagnostics', 'private/var/keybags/systembag.kb'):
            p = os.path.join(R, rel)
            if os.path.exists(p):
                s2 = os.lstat(p)
                log(f'     /{rel}: {s2.st_uid}:{s2.st_gid} {s2.st_mode & 0o7777:o}')
        # owner map spot check
        table = load_map(os.path.join(W, 'owners-final.tsv'))
        keys = random.Random(1).sample(sorted(table), 3000)
        bad = 0
        for k in keys:
            try:
                s2 = os.lstat(os.path.join(R, k))
            except OSError:
                continue
            if (s2.st_uid, s2.st_gid) != table[k][:2]:
                bad += 1
        chk(bad == 0, f'owner spot check of 3000 paths: {bad} mismatches')
        # compressed files would be fatal (no decmpfs in the kernel)
        r = subprocess.run(['find', R, '-flags', '+compressed', '-print', '-quit'], capture_output=True, text=True)
        chk(not r.stdout.strip(), 'no HFS-compressed files')
        # signatures of a sample of rewritten Mach-Os
        machos = []
        for sub in ('sbin', 'usr/libexec', 'usr/sbin', 'System/Library/CoreServices/SpringBoard.app'):
            for r_, d_, f_ in os.walk(os.path.join(R, sub)):
                for f in f_:
                    p = os.path.join(r_, f)
                    if os.path.isfile(p) and not os.path.islink(p):
                        with open(p, 'rb') as fh:
                            if fh.read(4) in MAGICS:
                                machos.append(p)
        sample = random.Random(2).sample(machos, min(150, len(machos)))
        badsig, resonly = [], []
        for p in sample:
            r = subprocess.run(['codesign', '-v', p], capture_output=True, text=True)
            if r.returncode:
                # bundle resource seals (CodeResources) are not checked by the kernel stand-in; page hashes are
                (resonly if 'resource' in r.stderr else badsig).append(p)
        chk(not badsig, f'codesign -v on {len(sample)} of {len(machos)} Mach-Os: {len(badsig)} bad {badsig[:3]}, '
                        f'{len(resonly)} only with an invalid bundle resource seal')
        # no PAC left in a sample (+ every launchd/dyld/SpringBoard)
        left = Counter()
        for p in sample + [os.path.join(R, 'sbin/launchd'), os.path.join(R, 'usr/lib/dyld')]:
            buf = bytearray(open(p, 'rb').read())
            counts, fj = Counter(), []
            for base in pacstrip.slices(buf):
                pacstrip.process_slice(buf, base, False, False, p, counts, fj)
            for k, v in counts.items():
                if not k.startswith(('FJCVTZS', 'ERETA')):
                    left[k] += v
        chk(not left, f'non-HINT PAC words left in the Mach-O sample (as the rewriter classifies them): {dict(left)}')
        r = subprocess.run([sys.executable, '-I', os.path.join(HERE, 'pacstrip_cache.py'), cd, '--scan', '--verify-sig'],
                           capture_output=True, text=True)
        log(r.stdout[-1800:])
        chk(r.returncode == 0 and 'SIGNATURE MISMATCH' not in r.stdout, 'cache: signatures valid, re-scan finds nothing to rewrite')
        subprocess.run(['df', '-h', rootmnt])
    finally:
        detach(dev)
    if not ok:
        sys.exit('verification FAILED')


def stage_simg(a, img, rootmnt):
    out = a.simg or os.path.splitext(img)[0] + '.simg'
    need_free('simg')
    cmd = [sys.executable, '-I', os.path.join(HERE, 'img2simg.py'), img, out]
    if not a.keep_raw:
        cmd.append('--consume')
    run(cmd)
    log('wrote', out, os.path.getsize(out), 'bytes', '(raw image consumed)' if not a.keep_raw else '')


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--ipsw-dir', default=os.path.join(ROOT, 'research/ios18/ipsw/22H352__iPhone11,8'))
    ap.add_argument('--out', default=os.path.join(ROOT, 'research/ios18/ios18-root-full.img'))
    ap.add_argument('--size', default='20g')
    ap.add_argument('--stages', default='copy,macho,cache,tweaks,seal,verify,simg')
    ap.add_argument('--simg', default=None)
    ap.add_argument('--delete-sources', action='store_true', help='delete each IPSW dmg after it was copied (tight disk)')
    ap.add_argument('--skip-sources', default='', help='copy stage resume: sources already in the image (appos,sysos)')
    ap.add_argument('--keep-raw', action='store_true', help='simg stage: do not punch holes into the raw image')
    ap.add_argument('--jobs', type=int, default=os.cpu_count())
    a = ap.parse_args()
    os.makedirs(W, exist_ok=True)
    rootmnt = os.path.join(W, 'root')
    stages = a.stages.split(',')
    dmgs = find_dmgs(a.ipsw_dir)
    if 'copy' not in stages and stages[0] in ('macho', 'cache', 'tweaks') and not os.path.ismount(rootmnt):
        attach(a.out, rootmnt, readonly=False)
    for s in stages:
        t0 = time.time()
        log('=== stage', s)
        if s == 'copy':
            stage_copy(a, a.out, rootmnt, dmgs)
        elif s == 'macho':
            stage_macho(a, rootmnt)
        elif s == 'cache':
            stage_cache(a, rootmnt)
        elif s == 'tweaks':
            stage_tweaks(a, rootmnt)
        elif s == 'seal':
            stage_seal(a, a.out, rootmnt)
        elif s == 'verify':
            stage_verify(a, a.out, rootmnt)
        elif s == 'simg':
            stage_simg(a, a.out, rootmnt)
        else:
            sys.exit('unknown stage ' + s)
        log(f'=== stage {s} done in {time.time() - t0:.0f}s')


if __name__ == '__main__':
    main()
