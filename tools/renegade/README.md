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
| `renegade jb fetch\|stage\|live\|remove\|status` | `jailbreak.py` | Optional jailbreak userland (below); `mkroot-full.py` stage `jb`, off by default |
| `renegade hfs SIMG …` | `hfsx.py` | Reads the sparse root image in place: `ls`, `cat`, `get`, `find`, `dsc` |
| `renegade sparse IN OUT` | `img2simg.py` / `simg2img.py` | Converts between raw and Android sparse images, with `--consume` for tight disks |

`root_tweaks18.py` holds the first-boot changes to the root (Setup skip, activation, SSH, staged system apps, ...). `dsctools/` symbolicates and disassembles the rewritten shared cache. The kernel half lives in Heartwood: patch 0131 (`sweetarm64e=1`) loads arm64e binaries, and 0141 emulates FJCVTZS, which has no 1:1 rewrite. Details and history are in `docs/IOS18_PORT.md`.

## Jailbreak userland

Optional and off by default: `renegade jb` stages a rootless Procursus userland, Sileo and TrollStore. Nothing downloaded is executed on the Mac (only unpacked), no third-party binary is committed (downloads are cached in the git-ignored `research/jb/`), and every download is checked against the SHA-256 pinned in `jailbreak.py`.

| Component | Pinned version | SHA-256 | Licence | Source |
| --- | --- | --- | --- | --- |
| Procursus rootless bootstrap | `bootstraps/1900/bootstrap-iphoneos-arm64.tar.zst` (2024-06-10) | `8354c3aa1ecdad8ebc47d9a76dfca6f830a2b757278068bd33b98bf1d638a9cb` | Procursus 0BSD; packages keep their own (GPL-2/3+, ISC, BSD, MIT), see `/var/jb/usr/share/doc/*/copyright` | https://apt.procurs.us/bootstraps/1900/ , https://github.com/ProcursusTeam/Procursus |
| Sileo | 2.5.1 `org.coolstar.sileo_2.5.1_iphoneos-arm64.deb` | `8e3c90e5a7d32f4ca207a0ac30d3cfa8a13dca86a2b4e11cb3f9e5c68d7bc97a` (same as in the Procursus `Packages`) | BSD-4-Clause | https://github.com/Sileo/Sileo (there is no `Sileo-Team/Sileo`) |
| TrollStore | 2.1.1 `TrollStore.tar` | `144dc741d1b74d582c861e6ed504ddced3745724e216e3de79ab7d37b27d0551` | MIT; `RootHelper/uicache.m` BSD-4-Clause | https://github.com/opa334/TrollStore |
| ldid (for TrollStore's signing) | v2.1.5-procursus7-new | `b6aa4018e7ef3df9ee3fee5889d162649719109521c5a2136ca98a81fccdf52a` | AGPL-3.0 | https://github.com/opa334/ldid |

Commands: `renegade jb fetch` (download + verify), `stage` (unpack into `research/jb/stage/` with `manifest.tsv` = owner/mode of every path), `live [--dry-run DIR] [--reinstall]` (install over SSH, or only unpack the install tar into DIR), `remove`, `status`. `live` and `remove` write to the device and need `RENEGADE_JB_LIVE_OK=1`. In the image build use `renegade root --stages copy,macho,cache,tweaks,jb,seal,verify,simg` or `RENEGADE_JB=1`.

* **Layout.** The root is ours, so `/var/jb` is a plain directory on the root volume (no `/private/preboot/<hash>/jb-XXXX` symlink). Sileo is `/var/jb/Applications/Sileo.app`, registered with `/usr/local/bin/sweetuicache`; its `giveMeRoot` helper is setuid root. Sileo is entered in the dpkg database by `jailbreak.py` (what `dpkg -i` would write). apt points at `https://apt.procurs.us/ 2000 main` (the rootless suite for iOS 17/18).
* **Mach-O.** The Procursus, Sileo and TrollStore binaries are plain arm64 and run as they are; any arm64e slice goes through `pacstrip` and is re-signed ad hoc. The upstream signatures are ldid-style (macOS `codesign` cannot read or replace them), so the entitlement blob is parsed by `jailbreak.py`, the signature is cut off and the binary is signed ad hoc again with the same entitlements. TrollStore's three Mach-Os are re-signed this way, because its upstream signatures rely on the CoreTrust bug and carry a borrowed App Store identifier; this kernel accepts ad hoc.
* **TrollStore.** Installed the upstream way, on the phone, by `trollstorehelper install-trollstore` run as root over SSH (no persona spawn needed from our side), which creates the app container and registers the app; then `install-ldid` so TrollStore can sign IPAs. `/var/jb/usr/share/renegade-jb/postinstall.sh` does the on-device part (Procursus `prep_bootstrap.sh` minus the password prompt, Sileo and TrollStore registration) and is run by `live` over SSH, or once by the first-boot LaunchDaemon `org.bergamota.renegade-jb` in image builds.
* **Remove.** `renegade jb remove` unregisters Sileo, runs `trollstorehelper uninstall-trollstore` and deletes `/var/jb`. Apps installed through TrollStore stay (they are user data).

