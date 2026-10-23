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
| `renegade hfs SIMG …` | `hfsx.py` | Reads the sparse root image in place: `ls`, `cat`, `get`, `find`, `dsc` |
| `renegade sparse IN OUT` | `img2simg.py` / `simg2img.py` | Converts between raw and Android sparse images, with `--consume` for tight disks |

`root_tweaks18.py` holds the first-boot changes to the root (Setup skip, activation, SSH, staged system apps, ...). `dsctools/` symbolicates and disassembles the rewritten shared cache. The kernel half lives in Heartwood: patch 0131 (`sweetarm64e=1`) loads arm64e binaries, and 0141 emulates FJCVTZS, which has no 1:1 rewrite. Details and history are in `docs/IOS18_PORT.md`.
