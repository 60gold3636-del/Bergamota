# Enxerto

The Bergamota Project's bootloader (*enxerto*, Portuguese for "graft": the piece that joins iOS onto the Poco F1). Bare-metal C and assembly, packed as an Android boot.img that the stock Qualcomm ABL accepts, either flashed to `boot` or sent with `fastboot boot`.

- **Boot**: maps RAM with the MMU and D-cache on, inflates the Heartwood payload (`tools/mkpayload.py --compress`) behind a Bergamota logo and progress bar, cleans the caches and jumps to XNU with the Apple Device Tree. The log stays hidden unless the boot fails (`BOOTLOG=1` shows it).
- **Bergamota fastboot** (`docs/BERGAMOTA_FASTBOOT.md`): its own USB (DWC3) fastboot, serial `bergamota0001`, ~1 GiB downloads, entered with `sweetreboot bergamota` or when there is no payload. It also **flashes** `userdata`, `boot` and `logo` (and nothing else: hard allowlist) with its own UFS write path, raw or Android sparse images, plus `oem hash` for delta flashing (`tools/bergamota-flash.py`).
- **Off-mode charging** (`docs/BERGAMOTA_CHARGE.md`): with `androidboot.mode=charger` it shows the battery from the PMI8998 fuel gauge. Volume Down enters fastboot.

```sh
BOARD=beryllium enxerto/build.sh [payload.bin]   # -> enxerto/out/enxerto-boot.img, bergamota-fastboot.img (what the Mac app boots with `fastboot boot`), charge-test.img, out/preview/*.ppm
```

`build.sh` also runs the host tests: it renders every screen to `out/preview/` and checks the fastboot state machine. Images built before the rename are called `shim/out/shim-boot-*.img`, and Bergamota still lists them.
