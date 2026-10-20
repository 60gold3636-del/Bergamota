# iOS 18 port: stage 1 (one arm64e command-line tool with iOS 18's own dyld and libSystem)

Branch `ios18`. Background and instruction counts: `docs/IOS18_FEASIBILITY.md`. This document is the "what was done / how to run / how to read a failure / what comes next" for the first proof of concept.

Status: everything below was verified **statically** on the Mac (rewriter output disassembled, signatures checked, kernel patch compiled and applied to the bt130 tree). **Nothing has been run on the phone** (not allowed in this session): the run-time statements are predictions, tagged [U].

## 1. What the PoC is

`/var/root/ios18poc/bin/expr 6 '*' 7` on the iOS 16.7.16 userland of the Poco F1, over SSH, where `expr` is the real iOS 18.7.8 (22H352) arm64e binary, launched by the **iOS 18 `/usr/lib/dyld`**, which loads **iOS 18's libSystem and its 115 dependencies from disk** (no shared cache), all statically rewritten to ARMv8.0 (no PAC), on the current xnu-8796 kernel plus patch 0131. Success = prints `42`, exit status 0.

### Where the iOS 18 binaries come from (the finding that made this cheap)
* The IPSW's root dmg (6.5 GB) is AEA-encrypted: not downloaded (limit 6 GB).
* The **restore ramdisk** (`094-32147-020.dmg`, 176 MB, IMG4 -> plain APFS, not encrypted, extracted by `ipsw img4 im4p extract`, mounted with `hdiutil attach -imagekey diskimage-class=CRawDiskImage`) is a complete on-disk iOS 18 userland: `/usr/lib/dyld`, `/usr/lib/libSystem.B.dylib` plus all of `/usr/lib/system/*.dylib`, libobjc, libc++, libswiftCore, CoreFoundation, Foundation, ... (103+ dylibs, **real chained fixups, no dyld shared cache**), and tools `/bin/{cat,expr,ln,mkdir,mv,rm}`, `/usr/bin/sed`. All thin arm64e (cpusubtype `0x80000002`, PAC ABI version 0).
* So there is no need for the cache: the ramdisk dylibs are the "flat directory of dylibs".
* Dylibs extracted from the shared cache (`ipsw dyld extract`) were tested and are **not loadable**: no rebase/bind info (LC_DYLD_CHAINED_FIXUPS absent), cross-image pointers are already resolved to cache addresses. That route would need a fixup reconstructor. Not used.
* The dyld inside the cache (0x1a9648000) is not usable as a file either (segments packed at unaligned cache addresses, ADRPs depend on that layout).

Note the dependency closure is bigger than "libSystem": libSystem -> libdispatch -> libobjc -> **libswiftCore -> CoreFoundation/Foundation -> ICU, Security, Network, ...** (116 dylibs, 143 MB with the tools). That is the real iOS 18 link graph; weak dependencies (libRosetta, libobjc-env) are absent on disk and skipped.

## 2. Decisions

| Question | Choice | Why |
| --- | --- | --- |
| How does iOS 18 dyld avoid the cache? | **It does not need a switch.** `DYLD_SHARED_REGION=avoid` exists only for the simulator in dyld-1286 (`DyldProcessConfig.cpp`: "only support DYLD_SHARED_REGION=avoid on simulator"). On a device dyld asks the kernel's shared region (`__shared_region_check_np`), validates the magic (`dyld_v1  arm64e`) and, if nothing compatible is there, runs without a cache (loads from disk). Our region holds the iOS 16 arm64 cache; its magic differs, so dyld reports "existing shared cache in memory is not compatible" and goes cache-less. | read from dyld-1286.10 source (`SharedCacheRuntime.cpp: reuseExistingCache`) [V read, U run] |
| How are the dylibs found? | **`DYLD_LIBRARY_PATH=/var/root/ios18poc/lib`** for dylibs and **`DYLD_FRAMEWORK_PATH=/var/root/ios18poc/Frameworks`** for frameworks (dyld does not apply DYLD_LIBRARY_PATH to `X.framework/X` install names: first run failed on CoreFoundation; `mkbundle.py` now lays frameworks out as `Frameworks/X.framework/...`, weak dependencies are included when the ramdisk has them, missing ones are reported; 0 hard dependencies are missing)  + kernel `LC_LOAD_DYLINKER` of each tool rewritten to `/var/root/ios18poc/dyld` (load commands repacked into header slack by `pacstrip.py --dylinker`). | Simplest: no install-name edits (the load commands have no room for longer paths), nothing outside `/var/root/ios18poc`. A chroot would need a chroot binary (toybox build has none) and /dev. |
| Why does that need the kernel? | dyld asks `amfi_check_dyld_policy_self` = `__sandbox_ms("AMFI", 0x5a, &{input, &output})` (disassembled in 22H352 dyld at 0x287c8). Our "AMFI" policy answered ENOPOLICY = "restricted": **no DYLD_\* env vars, no `@` paths, no DYLD_PRINT_\***. 0131 answers op 0x5a with all `AMFI_DYLD_OUTPUT_ALLOW_*` bits (0x3ff), only for arm64e processes and only with `sweetarm64e=1`. | `docs/EXTENSION_POINTS_2.md` already recorded the ENOPOLICY behaviour. |
| arm64e kept, or cpusubtype changed to arm64? | **Keep arm64e** and patch the kernel. `pacstrip.py --subtype arm64` exists as an experiment but is not recommended. | (1) Chained fixups: the format is selected by `dyld_chained_starts_in_image.pointer_format` inside the file, so an arm64 subtype would not break auth-fixup parsing; that part is neutral. (2) But an arm64-subtype process shares the iOS 16 shared region; iOS 18 dyld would then try to adopt the iOS 16 cache. (3) dyld's arch grading: arm64e dyld + arm64 main executable = "keys off", which accepts the arm64e dylibs, so it can work, yet it silently differs from the real configuration and from what stage 2 (arm64e cache) needs. (4) The kernel patch is 40 lines and gated. (5) The AMFI answer is needed in any case. |
| Resign | ad hoc, `codesign -f -s -` with the original entitlements re-applied (as `tools/sweet-install-ipa.sh` does). The kernel's AMFI stand-in (0025/0036) validates the blob structure only. | [U] depends on the stand-in accepting every page hash set |

## 3. What is in the branch

| File | Purpose |
| --- | --- |
| `tools/ios18/pacstrip.py` | The rewriter. 4 bytes for 4 bytes, only executable sections, LC_DATA_IN_CODE skipped, fat arm64 slices handled. Table in its docstring (same as feasibility 3.1): RETAA/B -> `ret`; BR/BLR(AA/AB, Z or register) -> `br/blr Xn`; LDRAA/B -> `ldr` (pre-index/offset, `ldur` for small negatives); PACI*/PACD*/AUTI*/AUTD*/XPAC* -> `nop`; PACGA -> `eor Xd,Xn,Xm,ror #k` (k depends on the registers, `mov Xd,Xn` when the modifier is SP); hint space untouched; FJCVTZS counted and printed (file offsets), left alone. `--scan` counts only, `--sign` re-signs, `--dylinker PATH` rewrites LC_LOAD_DYLINKER. Pure Python, no dependencies, ~1 s per large dylib. |
| `tools/ios18/fetch-ramdisk.sh` | Downloads only the restore ramdisk member of the IPSW (range requests via `tools/remotezip.py`), extracts IMG4, mounts it read-only. |
| `tools/ios18/mkbundle.py` | Dependency closure of the chosen tools -> `research/ios18poc/{dyld,lib/,bin/,MANIFEST.txt}`; runs pacstrip + codesign on every Mach-O. |
| `tools/ios18/run-poc.sh` | Pushes the bundle (tar over SSH, skipped when unchanged) and runs the tool with the dyld diagnostics. |
| `xnu/patches/0131-ios18-arm64e-exec.patch` | Kernel patch (below). Applies on top of 0001-0130 (checked with `patch -p1` and `git apply --check` on `research/bt130/xnu`; the three files compile with `tools/xnu-cc.py`). |

### Kernel patch 0131 (everything behind boot-arg `sweetarm64e=1`, keyed on the CPU subtype being arm64e)
1. `bsd/dev/arm/kern_machdep.c grade_binary()`: host `CPU_SUBTYPE_ARM64_V8` accepts `CPU_SUBTYPE_ARM64E` (grade 8, below a real arm64 slice, so iOS 16 fat binaries still pick their arm64 slice; also applies to dyld itself and dylib grading in `mach_loader`). Without the boot-arg: unchanged (arm64e grades 0, exec fails as before).
2. `bsd/kern/kern_exec.c`: `sweet_arm64e_enabled()` / `sweet_proc_is_arm64e()` helpers; apple string `ptrauth_disabled=1` for arm64e execs (what a ptrauth kernel passes when JOP keys are off; dyld's `getMainArchs` reads it). That code is `#if __has_feature(ptrauth_calls)` in xnu, so it did not exist in our build.
3. `bsd/kern/sweet_amfi.c`: "AMFI" policy op 0x5a (dyld policy) as described above.
4. **Not changed** and why: `hw.optional.arm.FEAT_*` already exist in xnu-8796 and answer from the ID registers (`gARM_FEAT_PAuth/PAuth2/FPAC/JSCVT/SHA3/SHA512/FCMA/I8MM/BF16 = 0` on this CPU); the iOS 18-only names (`FEAT_SME`, `FEAT_SME2`, ...) return ENOENT, which callers treat as 0 [U]. `hw.cpusubtype` stays arm64 v8 (reporting arm64e would change the shared-region and fat grading for iOS 16 processes; not needed for the PoC). Shared region: `exec` uses one region for all subtypes (`cpu_subtype = 0` outside the ptrauth block), so the arm64e process sees the iOS 16 cache mapped and ignores it (section 2, row 1).

## 4. Build, boot, run (commands)

```sh
# 0. bundle (once; needs ipsw, Xcode command-line tools; ~180 MB download, 143 MB result)
cd /Users/zesmoi/git/iAndroid/ios-beryllium-ios18
tools/ios18/fetch-ramdisk.sh                     # prints the mountpoint research/ios18/ramdisk/mnt
python3 -I tools/ios18/mkbundle.py research/ios18/ramdisk/mnt research/ios18poc
diskutil eject research/ios18/ramdisk/mnt && rm -f research/ios18/ramdisk/094-* research/ios18/ramdisk/ramdisk.apfs

# 1. kernel with 0131: CI builds branches only by dispatch
git push -u origin ios18                         # you review first
gh workflow run xnu.yml --ref ios18 -R ry-diffusion/ios-beryllium
gh run list -R ry-diffusion/ios-beryllium --branch ios18 -L 1      # note the run id, then
gh run download <ID> -R ry-diffusion/ios-beryllium -n xnu-kernel -D xnu/out-0131

# 2. boot image: same ADT, payload and cmdline as your current image, plus sweetarm64e=1
python3 tools/mkpayload.py xnu/out-0131/kernel.development.sweet shim/out/<current>.adt shim/out/payload-0131.bin \
    --cmdline "<your current cmdline> sweetarm64e=1"
BOARD=beryllium shim/build.sh shim/out/payload-0131.bin && cp shim/out/shim-boot.img shim/out/shim-boot-0131.img
fastboot boot shim/out/shim-boot-0131.img        # then wait for ssh root@192.168.7.2

# 3. run
tools/ios18/run-poc.sh                           # expr 6 '*' 7 with DYLD_PRINT_* diagnostics
tools/ios18/run-poc.sh --quiet -- cat /etc/hosts
```
(The artifact name `xnu-kernel` and the `kernel.development.sweet` file name are from NOTES.md's workflow; use whatever your last `gh run download` used. The worktree has no `shim/out`; either run step 2 in the main checkout with the downloaded kernel, or copy the ADT/payload tools' inputs.)

The cmdline of your current image is in the command that produced `shim/out/shim-boot-0126x3.img` (not recorded in the repo as text; `fastboot`-boot images embed it in the ramdisk payload header: `python3 tools/unpack_bootv2.py` or `unpack_bootimg` shows it).

## 5. Expected output [U]

`run-poc.sh` first prints `uname`, `kern.bootargs` (warns when `sweetarm64e=1` is missing), then the tool output, then an exit status. With the diagnostics on (stderr, `DYLD_PRINT_TO_STDERR=1`) expect, in this order:
1. `dyld[PID]: ...` environment dump (`DYLD_PRINT_ENV`), proving the AMFI answer worked (if the env vars were ignored nothing at all is printed, see 6.2).
2. `DYLD_PRINT_SEARCHING` lines like `  found: "/var/root/ios18poc/lib/libSystem.B.dylib"` (the `DYLD_LIBRARY_PATH` override of `/usr/lib/libSystem.B.dylib`) and an "existing shared cache in memory is not compatible" / "no cache" style line.
3. `DYLD_PRINT_LIBRARIES`/`SEGMENTS` for ~116 images, then `DYLD_PRINT_INITIALIZERS`.
4. `42` and `== exit status 0`.

Cost: loading 116 dylibs without prebuilt loaders: seconds.

## 6. Reading a failure

| Symptom | Meaning / next step |
| --- | --- |
| `Bad CPU type in executable` / `exec format error` (ssh prints errno 86 or 8) | `grade_binary` refused: boot-arg `sweetarm64e=1` missing, or the old kernel is running. `run-poc.sh` prints the boot-args. |
| `Killed: 9` with no dyld output, instantly | Code signature/AMFI. Kernel log (`SWEET AMFI:`, `cs_invalid_page`, `CS_KILLED`): the ad-hoc blob was refused. Try `pacstrip.py --sign` again on that file, check `codesign -v`. |
| `dyld: Library not loaded: /usr/lib/libSystem.B.dylib` (or any `/usr/lib/...`), and with DYLD_PRINT_SEARCHING `Note: DYLD_*_PATH env vars disabled by AMFI` | The 0x5a answer did not reach dyld. Check the kernel log for `SWEET AMFI: expr __mac_syscall("AMFI", 0x5a)` (the existing 0099 code prints each op once); confirm `sweet_proc_is_arm64e` (the process must exec as arm64e). Struct layout assumption: `{u64 input; u64 *output}` at the third argument. |
| `Library not loaded ... (no such file)` for one specific dylib | The dependency was not in the bundle (`MANIFEST.txt` lists what is) or it is a leaf-name clash; mkbundle asserts uniqueness. |
| Signal 4 (SIGILL, exit 132) | A word the rewriter does not cover. Get the PC (kernel log/`ReportCrash`), subtract the slide, `python3 -I tools/ios18/pacstrip.py --scan FILE` and `llvm-objdump -d --mattr=-pauth` around the offset. Known candidates: FJCVTZS (not rewritten), SHA3/SHA512 words in corecrypto and dyld (must be gated by `hw.optional.arm.FEAT_SHA3/SHA512` = 0, which this kernel reports), SB, SVE/SME words in libsystem_platform (gated). |
| Signal 11/10 early, no dyld lines | dyld's `rebaseSelf`/startup: `__DATA_CONST` `mprotect`, `__TPRO_CONST` segment (kernel 8796 ignores the TPRO flag, dyld uses `vm_protect` fallbacks), first syscalls. Run with `DYLD_PRINT_SEGMENTS`; if even that prints nothing the fault is before config. Check the kernel's exception report for the PC and offset in `dyld`. |
| `dyld: ... PAC failure` / `brk #0xc47x` | A pointer was authenticated against a signature that does not exist: an AUT* we turned into NOP is followed by a check we did not expect, or an instruction encoding was missed. The brk immediates are `0xc470`-`0xc473` (key-specific); find the site and its class. |
| Hang | Syscall that blocks (kdebug/`kdp` or `__shared_region_*`), check `kern.bootargs`, `sample`/`spindump` are not in the iOS 16 root; use the kernel log (`tools/sweet-usbnet.sh`). |
| Output but wrong values | PACGA replacement collisions (Foundation/libobjc hashes) or similar; compare with a clean `expr` run of the same operands. |

Collect on failure: `research/ios18/last-run.txt` (written by the script), the UDP kernel log, and the PC/offsets.

## 7. Stage 2 plan: whole rewritten shared cache + slide info v5

Goal: stop using the ramdisk dylibs; run iOS 18's own 4.8 GB `dyld_shared_cache_arm64e` (67 files, 3861 images, slide-info v5), i.e. the prerequisite for launchd/SpringBoard.
1. **2a, no kernel work: private cache.** `DYLD_SHARED_REGION=private DYLD_SHARED_CACHE_DIR=<dir>` is honoured when `AMFI_DYLD_OUTPUT_ALLOW_CUSTOM_SHARED_CACHE` (0x4) is granted (already part of 0x3ff). dyld maps the files itself and applies v5 slide info in userland (`SharedCacheRuntime.cpp rebaseDataPages`, v5 case), signing pointers with PAC instructions that are NOPs after the rewrite. dyld-in-cache restart is disabled in this mode (`DYLD_SHARED_REGION` set), good. Needs: a `pacstrip.py cache DIR` mode: walk every subcache file, map each image's executable sections to file offsets through the mapping tables (`dyld_cache_mapping_info`, subcache entries), rewrite them with the same table, and **fix the code signature of each cache file** (dyld registers it with `F_ADDFILESIGS_RETURN` and checks it covers the file; recompute the CodeDirectory page hashes in place). The cache has no data-in-code info: the false-positive risk is the 1,595 LDRAx "hits" in TextToSpeechMauiSupport and a few others (data); whitelist LDRAA/LDRAB to images known to contain real ones (libc++abi) and spot-check the other classes (done for the feasibility study).
2. **2b, kernel: slide info v5.** Port `vm_shared_region_slide_page_v5` and `vm_shared_region_slide_info_entry_v5` (about 120 lines, xnu-11215.81.4 `osfmk/vm/vm_shared_region.c`; the signing parts are `#if __has_feature(ptrauth_calls)` so on our kernel it just writes `(value & 0x3FFFFFFFF) + value_add + slide`), accept `shared_region_map_and_slide_2_np` with v5 `dyld_cache_slide_info5` (xnu-8796 knows v1-v4) and the new `__map_with_linking_np` call (dyld falls back to in-process linking if it fails, so a stub returning an error is enough at first). Then the system-wide cache works and the on-disk dyld restarts into the cache's own dyld (UUID check in `dyldMain.cpp`), also part of the later userland.
3. FJCVTZS: 474 sites in JavaScriptCore/WebCore. Either an EL1 undefined-instruction emulator (decode `0x1e7e0000|Rn<<5|Rd`, ~15 instructions incl. NZCV Z) or per-site islands; JavaScriptCore's JIT checks `hw.optional.arm.FEAT_JSCVT`, so the JIT already avoids it.
4. launchd and the rest: rewrite `/sbin/launchd` and every executable the same way (the rewriter already handles a Mach-O executable and re-signs), then userland bring-up as in feasibility section 5.
5. Rebase vs backport: stay on xnu-8796 plus 0131 plus the v5 port; revisit if iOS 18 daemons need newer syscalls.

## 8a. First on-device run and the Bus error (patch 0134)
First run (kernel with 0131): dyld honoured the AMFI answer (`DYLD_PRINT_*` output), resolved all 117 images (after the frameworks fix), ran libSystem's initializer and died with `Bus error: 10`, `far` in libdispatch `__AUTH_CONST`. Diagnosis (from `research/ios18/last-run.txt`):
* **No VA overlap**: all 674 distinct segment ranges listed by `DYLD_PRINT_SEGMENTS` were checked, the only "overlap" is `__PAGEZERO` vs the first `__TEXT`. (MobileSystemServices `__AUTH_CONST+0x4e0` has the same offset as libdispatch's by coincidence of the page offset, not the VA.)
* The log line before every data segment is `Setting up kernel page-in linking for <image>`: iOS 18 dyld defaults to `pageInLinkingMode = 2` (not changeable without an internal install: `DYLD_PAGEIN_LINKING=0` is honoured only if `internalInstall()`), so data segments with chained fixups are mapped through `map_with_linking_np` (xnu-8796 has it, `bsd/vm/vm_unix.c`) and the fixups are applied **by the kernel's dyld pager at page-in** (`osfmk/vm/vm_dyld_pager.c fixup_page`).
* That pager handled `DYLD_CHAINED_PTR_ARM64E`, `_USERLAND` and `_USERLAND24` only under `#if defined(HAS_APPLE_PAC)`, which our build does not define. For every arm64e image it printed `unknown pointer_format` (kernel log) and returned `KERN_FAILURE`; the first touch of such a page (here libdispatch `__AUTH_CONST+0x4e0`, `pc` = libdispatch `__TEXT+0x3cc08` right after libSystem's initializer started) is `KERN_MEMORY_ERROR` = SIGBUS code 0x10000000a. Not a rewriter problem.
* **Fix: `xnu/patches/0134-ios18-dyld-pager-arm64e-nopac.patch`**: build `fixupPageAuth64` always and, without PAC, make `signPointer()` the identity (pointers stay unsigned, which is what the rewritten code expects: the AUTx instructions are NOPs). Auth and non-auth rebases/binds are walked exactly as in the PAC build (stride 8, 24-bit ordinals, offset- or vmaddr-based targets). Compiles with `tools/xnu-cc.py`; applies on bt130. It needs a new kernel (CI) but no other change: same bundle, same `tools/ios18/run-poc.sh`. Only arm64e images use these pointer formats, so arm64 processes are unaffected.
* If it still faults, the kernel log now says why: `fixupPageAuth64(): ...` lines.

## 8. Limits of what was verified here
* Rewriter: counted over the whole bundle; re-disassembled with `llvm-objdump` (PAuth on): zero remaining PAC instructions outside hint space in dyld, libobjc, libc++abi, libsystem_c, expr; with PAuth off the only undecodable words are SHA3 (dyld, gated) and data. Signed bundle passes `codesign -v`.
* Not verified: any execution; the AMFI struct layout (read from disassembly); that the kernel's AMFI stand-in accepts the new ad-hoc blobs; behaviour of the iOS 18 libs on this kernel after dyld (syscalls/sysctls/commpage), expected to need more patches (feasibility 5.1).
* Sources: iOS 18.7.8 22H352 IPSW (iPhone11,8), dyld-1286.10 source (`apple-oss-distributions/dyld`), xnu bt130 tree.


## 9. Stage 1b: boot the iOS 18 restore ramdisk itself as the root (launchd 18 as PID 1)

"For fun" version of the bring-up: no phone filesystem, no iOS 16: the kernel mounts the rewritten iOS 18.7.8 restore ramdisk as the root (`rd=md0`) and runs **its** `/sbin/launchd` (arm64e, rewritten, signed) as PID 1 with **its** `/usr/lib/dyld` and libs at their native paths (no DYLD_* env needed: the paths exist; dyld finds no cache and loads from disk).

### Image
* APFS: our xnu-8796 has no APFS (closed kext), so `tools/ios18/mkramdisk-root.sh` converts: stage (`tools/ios18/mkroot.py`: ditto without compression/xattrs, prune, pacstrip --sign of every Mach-O) -> case-sensitive **unjournaled** HFS+ (`newfs_hfs -s`, the kernel's built-in hfs, same as the iOS 16 root) built **without sudo**: attached as a user raw image, populated with ditto, then `tools/ios18/hfsroot_chown.py` sets owner/group of every catalog record to 0:0 in place (the unprivileged Mac user cannot chown; the catalog B-tree leaf walk is 60 lines).
* Pruned: `/usr/standalone` (49 MB firmware), `/usr/local` (restore tools), `Filesystems`, every Mach-O not reachable from `launchd`, `dyld` and `/bin/*` (183 files) -> 125 Mach-O files, **185 MB** image (the ramdisk's ~140 MB of APFS data inflates because decmpfs-compressed files are written uncompressed; the kernel has no decmpfs). Whole boot payload with an existing kernel: **201 MB** (`mkpayload` checked), the ABL fastboot limit is 768 MiB (NOTES).
* Stock LaunchDaemons (restored_external, camera, driverkitd, ...) are removed (`--stock-daemons` keeps them): they would fight over USB and crash-loop. Two jobs are added that print to the console: `org.sweet.ios18.expr` (`/bin/expr 6 * 7` -> `42`) and `org.sweet.ios18.passwd` (`/bin/cat /etc/master.passwd`).

### Build and boot
```sh
cd /Users/zesmoi/git/iAndroid/ios-beryllium-ios18
tools/ios18/fetch-ramdisk.sh                  # mounts research/ios18/ramdisk/mnt
tools/ios18/mkramdisk-root.sh                 # -> research/ios18/ios18-root.hfs (about 1 minute, no sudo)
# kernel: 0131 + 0133 (hw.targettype) + 0134 (dyld pager) must be in the CI build
python3 tools/mkpayload.py xnu/out-NNNN/kernel.development.sweet shim/out/beryllium-hi-3x.adt shim/out/payload-ios18rd.bin \
    --ramdisk research/ios18/ios18-root.hfs \
    --cmdline "debug=0xc serial=3 cpus=8 keepsyms=1 -noprogress rd=md0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin launchd_unsecure_cache=1 wdt=-1 sweetfb_noconsole=1 sweetfb_hz=30 sweetfb_vsync=1 sweetfb_scale=1 sweetfb_flip=1 sweetusb=2 sweetbattery=1 sweetfb_hw=1 sweetarm64e=1 launchd_disable_all_timeouts=1"
BOARD=beryllium shim/build.sh shim/out/payload-ios18rd.bin && cp shim/out/shim-boot.img shim/out/shim-boot-ios18rd.img
tools/sweet-usbnet.sh logs/live-ios18rd.txt &          # kernel log over USB (sweetusb=2)
fastboot boot shim/out/shim-boot-ios18rd.img
```
Differences from the usual cmdline: `rd=md0` instead of `rd=ufsroot0`, no `ufsrw=1 rootrw=1` (userdata is not touched at all), no Wi-Fi/BT/net/sample options; `launchd_disable_all_timeouts=1` is a launchd 18 boot-arg (string in the binary) so slow first launches are not killed. `shim/out/beryllium-hi-3x.adt` is the @3x ADT; use whichever your last image used (the cmdline above is the last image's, `payload-ios18.bin`, minus the changes listed). `sweetarm64e=1` is mandatory.

### What to expect [U], and how to read the log
1. Usual kernel boot, then `BSD root: md0`, `hfs: mounted iOSRoot on device ...`, `SWEET: root volume is not authenticated ...; continuing unsealed`, `load_init_program: /sbin/launchd`.
2. No exec error if grading works (`Bad CPU type` / panic `initproc failed to start` with exec error 86 = boot-arg missing).
3. launchd 18 starts (dyld loads libSystem etc. from `/usr/lib`): first signs on the console are `launchd[1]` lines (it prints to `/dev/console`), then the two jobs print `42` and the passwd file. That would be the whole success criterion: iOS 18 PID 1 runs jobs.
4. Failure modes and where they show: **panic `initproc exited`/`unexpected SIGKILL of launchd`** with namespace/code: 9/0xe = platform check (alien binary, boot-arg `unentitled_ios_sim_launch=1` is in the cmdline), 2/0xa SIGBUS = the pager fixup (should be fixed by 0134; kernel log has `fixupPageAuth64()` or `dyld_pager` lines), 2/0x4 SIGILL = an instruction class the rewriter does not cover (find the pc offset in the Mach-O, `pacstrip.py --scan`), 2/0xb SIGSEGV; code-signing kills (`CS_KILLED`, `cs_invalid_page`) mean an ad-hoc blob was refused. launchd asserts print the message on the console: known one that is handled: `sysctl hw.targettype was not set` (0133 adds the sysctl); likely next ones: `kern.*`/`hw.*` sysctls that do not exist in xnu-8796, `host_set_special_port`/`task_set_exception_ports` policy calls, `sandbox_init` and AMFI selectors other than 0x5a/0x60 (the "SWEET AMFI: ... __mac_syscall("AMFI", 0x..)" lines list every new op once), coalition/memorystatus/`proc_info` flavours, `reboot3`. The panic string and the last 20 kernel log lines are what to send back.
5. launchd 18 in a restore ramdisk wants `/System/Library/LaunchDaemons` plists only; there is no `xpcproxy`, `launchctl`, `logd` etc. in this ramdisk, so `xpc` services that launchd normally spawns for itself may report errors; they are expected noise.
