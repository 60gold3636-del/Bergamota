# Renegade

The Bergamota Project's patcher. iOS 18 ships every system binary as **arm64e** (pointer authentication), but the Poco F1's Snapdragon 845 is ARMv8.2 without PAuth. Renegade rewrites the code so it runs anyway, then builds the flashable root image around it. `renegade help` lists the commands.

| Command | Tool | What |
| --- | --- | --- |
| `renegade strip IN [OUT]` / `scan` | `pacstrip.py` | Rewrites one Mach-O 4 bytes for 4 bytes (RETAA→RET, BRAA→BR, LDRAA→LDR, PAC/AUT/XPAC→NOP, PACGA→EOR ROR #13). `--sign` re-signs ad hoc, keeping the identifier, flags and entitlements |
| `renegade cache DIR` | `pacstrip_cache.py` | Does the same over the dyld shared cache (main + sub-caches) and refreshes the CodeDirectory page hashes |
| `renegade fips DIR --patch` | `fips_rehmac.py` | Recomputes corecrypto's FIPS POST HMAC over the rewritten `__text` |
| `renegade fetch` | `fetch-root.sh` | Downloads and decrypts the 22H352 iPhone11,8 root and cryptex dmgs |
| `renegade root` | `mkroot-full.py` | Full root image: stages `copy, macho, cache, tweaks, seal`, no sudo (owners are set in the HFS+ catalog by `hfsroot_owners.py`) |
| `renegade boot` | `mkboot-full.sh` | Enxerto boot image for the root on `userdata` |
| `renegade jb fetch\|stage\|live\|remove\|status` | `jailbreak.py` | Jailbreak userland (below); `mkroot-full.py` stage `jb`, on by default (`--no-jb`) |
| `renegade update SIMG` | `update.py` | Applies the root auto-fixes to a finished image in place, no IPSW needed (below) |
| `renegade hfs SIMG …` | `hfsx.py` | Reads the sparse root image in place: `ls`, `cat`, `get`, `find`, `dsc` |
| `renegade sparse IN OUT` | `img2simg.py` / `simg2img.py` | Converts between raw and Android sparse images, with `--consume` for tight disks |

`root_tweaks18.py` holds the first-boot changes to the root (Setup skip, activation, SSH, staged system apps, ...). `dsctools/` symbolicates and disassembles the rewritten shared cache. The kernel half lives in Heartwood: patch 0131 (`sweetarm64e=1`) loads arm64e binaries, and 0141 emulates FJCVTZS, which has no 1:1 rewrite. Details and history are in `docs/IOS18_PORT.md`.

## Jailbreak userland

On by default in `renegade root` and `renegade update` (opt out with `--no-jb` / `RENEGADE_NO_JB=1`): `renegade jb` stages a rootless Procursus userland, Sileo and TrollStore. Nothing downloaded is executed on the Mac (only unpacked), no third-party binary is committed (downloads are cached in the git-ignored `research/jb/`), and every download is checked against the SHA-256 pinned in `jailbreak.py`.

| Component | Pinned version | SHA-256 | Licence | Source |
| --- | --- | --- | --- | --- |
| Procursus rootless bootstrap | `bootstraps/1900/bootstrap-iphoneos-arm64.tar.zst` (2024-06-10) | `8354c3aa1ecdad8ebc47d9a76dfca6f830a2b757278068bd33b98bf1d638a9cb` | Procursus 0BSD; packages keep their own (GPL-2/3+, ISC, BSD, MIT), see `/var/jb/usr/share/doc/*/copyright` | https://apt.procurs.us/bootstraps/1900/ , https://github.com/ProcursusTeam/Procursus |
| Sileo | 2.5.1 `org.coolstar.sileo_2.5.1_iphoneos-arm64.deb` | `8e3c90e5a7d32f4ca207a0ac30d3cfa8a13dca86a2b4e11cb3f9e5c68d7bc97a` (same as in the Procursus `Packages`) | BSD-4-Clause | https://github.com/Sileo/Sileo (there is no `Sileo-Team/Sileo`) |
| TrollStore | 2.1.1 `TrollStore.tar` | `144dc741d1b74d582c861e6ed504ddced3745724e216e3de79ab7d37b27d0551` | MIT; `RootHelper/uicache.m` BSD-4-Clause | https://github.com/opa334/TrollStore |
| ldid (for TrollStore's signing) | v2.1.5-procursus7-new | `b6aa4018e7ef3df9ee3fee5889d162649719109521c5a2136ca98a81fccdf52a` | AGPL-3.0 | https://github.com/opa334/ldid |

Commands: `renegade jb fetch` (download + verify), `stage` (unpack into `research/jb/stage/` with `manifest.tsv` = owner/mode of every path), `live [--dry-run DIR] [--reinstall]` (install over SSH, or only unpack the install tar into DIR), `remove`, `status`. `live` and `remove` write to the device and need `RENEGADE_JB_LIVE_OK=1`. In the image build the `jb` stage is added before `seal` whenever `tweaks` runs (or give it explicitly: `--stages copy,macho,cache,tweaks,jb,seal,verify,simg`).

* **Layout.** The root is ours, so `/var/jb` is a plain directory on the root volume (no `/private/preboot/<hash>/jb-XXXX` symlink). In image mode it is written to `/private/var/jb`; `/var` stays the symlink to `private/var` (`image_stage` checks this before and after the copy and writes owner entries for `var/jb` only, never for `var`). Sileo is `/var/jb/Applications/Sileo.app`, registered with `/usr/local/bin/sweetuicache`; its `giveMeRoot` helper is setuid root. Sileo is entered in the dpkg database by `jailbreak.py` (what `dpkg -i` would write). apt points at `https://apt.procurs.us/ 2000 main` (the rootless suite for iOS 17/18).
* **Mach-O.** The Procursus, Sileo and TrollStore binaries are plain arm64 and run as they are; any arm64e slice goes through `pacstrip` and is re-signed ad hoc. The upstream signatures are ldid-style (macOS `codesign` cannot read or replace them), so the entitlement blob is parsed by `jailbreak.py`, the signature is cut off and the binary is signed ad hoc again with the same entitlements. TrollStore's three Mach-Os are re-signed this way, because its upstream signatures rely on the CoreTrust bug and carry a borrowed App Store identifier; this kernel accepts ad hoc.
* **TrollStore.** Installed the upstream way, on the phone, by `trollstorehelper install-trollstore` run as root over SSH (no persona spawn needed from our side), which creates the app container and registers the app; then `install-ldid` so TrollStore can sign IPAs. `/var/jb/usr/share/renegade-jb/postinstall.sh` does the on-device part (Procursus `prep_bootstrap.sh` minus the password prompt, Sileo and TrollStore registration) and is run by `live` over SSH, or, in image builds, by the first-boot job `org.bergamota.renegade-firstboot` (below), which runs it once after the apps are registered.
* **Remove.** `renegade jb remove` unregisters Sileo, runs `trollstorehelper uninstall-trollstore` and deletes `/var/jb`. Apps installed through TrollStore stay (they are user data).


## Root auto-fixes (what was done by hand on the phone, baked into the image)

`root_tweaks18.auto()` runs in the `tweaks` stage of `renegade root` and in `renegade update`. Every fix is on by default and has an opt-out (`--no-appreg`, `--no-posterboard`, `--no-bluetooth`, `--no-jb`, or `RENEGADE_NO_<NAME>=1`). Build the on-device tools first: `tools/sweetnet/build.sh` (needs Xcode; output in `research/sweetnet/`, iOS 18 builds in `research/sweetnet/ios18/` are arm64e and go through `pacstrip --sign`).

| Fix | Function | What it does |
| --- | --- | --- |
| App registration | `staged_apps()`, `firstboot()` | Moves `/private/var/staged_system_apps/*.app` to `/Applications` (names kept in `/usr/local/share/renegade/register-apps`), installs `/usr/local/bin/sweetuicache` and the first-boot LaunchDaemon `org.bergamota.renegade-firstboot` (plist in `/System/Library/LaunchDaemons` plus the `launchd.plist` cache entry, like the dropbear job). The job runs `/usr/local/libexec/renegade-firstboot.sh` with `/bin/sh` (dash from the ssh tweak): `sweetuicache /Applications/NAME.app` per listed app, as root (the invocation of `tools/sweet-install-ipa.sh`; there is no other documented one), retrying the first app for up to 10 minutes because registration works only once lsd is up. It then runs the jailbreak post-install if `/var/jb` has one and disables itself with `/private/var/db/.renegade-firstboot-done` (also after 3 incomplete runs). Log: `/private/var/log/renegade-firstboot.log` |
| PosterBoard | `posterboard()` | Installs `/usr/local/lib/sweetfp.dylib` (`tools/sweetnet/sweetfp.m`: keeps NSURLFileProtectionKey in an xattr, since HFS+ has no protection classes and PosterBoard's store migration "from 59 to 61" fails otherwise), adds an `LC_LOAD_DYLIB` to `/Applications/PosterBoard.app/PosterBoard` with `tools/sweetnet/addlc.py` and re-signs it ad hoc keeping identifier `com.apple.PosterBoard`, flags and all entitlements (checked after the signing). The binary is only touched after the dylib is installed |
| Bluetooth | `bluetooth()` | `BT_HCI_TRANSPORT` in bluetoothd's launchd job, the BlueTool stub as `/usr/sbin/BlueTool` (original kept as `BlueTool.orig`), `/usr/local/bin/hcitest`. The ADT half (`/arm-io/bluetooth`, `tools/mkadt.py`) belongs to the boot image |
| Jailbreak | `jailbreak_userland()` | See the section above |

`renegade update` and the build record owners without sudo: `OwnerRecorder` replaces `os.chown`, and ignores the owner of the process, because the image is mounted `noowners` and every file shows as 501:20 (an older build wrote `launchd.plist` as 501:20 that way; `update` puts it back to 0:0).

**Default wallpaper and icon style: not done.** Choosing the Gradient poster (no Metal) and the non-tinted icon style means writing PosterBoard's data store (configuration archives with UUIDs, store version 61, protection xattrs). PosterBoard creates that store itself on first run (now that `sweetfp.dylib` lets the migration finish), and an offline copy could not be tested without the phone. Until that is verified on the device nothing is preselected: the Gradient poster and the default (automatic, not tinted) icon style have to be picked once on the phone (`PRSService`/`PRSPosterUpdate` calls are declared in `tools/sweetnet/sweetposter-prs.h`, `sweetrun-app` runs a script as `mobile` in the user's launchd domain).

## `renegade update`

```
tools/sweetnet/build.sh                              # once: sweetuicache, sweetfp.dylib, BlueTool stub, hcitest
renegade update research/ios18/ios18-root-full.simg [--no-jb] [--no-appreg] [--no-posterboard] [--no-bluetooth] [--check]
```

`simg2img --consume` (the simg is eaten while the raw image is written) -> `hdiutil attach` read-write, no sudo -> the tweak functions (idempotent) -> detach -> `hfs_trim` -> `hfsroot_owners` for the new paths only (everything created since the start, plus the paths chowned on purpose) -> `fsck_hfs -fn` -> `img2simg --consume` back to the `.simg`. Every step checks `df` and stops below 5 GiB free; the preflight (read only, via `hfsx.py`) checks the files the tweaks need, the built tools and, for the jailbreak payload, downloads and stages it before anything is consumed. `--check` stops after the preflight.

If it fails after the simg was consumed, the raw `IMAGE.img` is left next to the zeroed `IMAGE.simg` shell, detached. Fix the cause and run `renegade update IMAGE.img`: it starts at the attach step and writes `IMAGE.simg` at the end. Do not delete the `.img`.
