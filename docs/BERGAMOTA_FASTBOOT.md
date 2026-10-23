# Bergamota fastboot (Enxerto speaks fastboot itself)

Files: `enxerto/usb_power.c` (cold-boot power-up), `enxerto/usb_dwc3.c` (polled DWC3 device driver), `enxerto/fastboot.c` (protocol core, host-testable),
`enxerto/bergamota.c` (glue: screen, buffer, boot, reset), `enxerto/fastboot_test.c` (host test, runs from `build.sh`).
Hooks: `enxerto.c` (usb_power_up + entry), `loader.c` (`loader_check`, `loader_boot_payload`, `loader_has_payload`), `fdt.c` (`fdt_chosen_prop`), `build.sh`.
Status: compiles and the protocol test passes; **nothing here has run on hardware.**

## Entry
`usb_power_up()` runs on every boot (no-op when GDSC + clocks are on). Then fastboot starts when
- the boot.img cmdline has `bergamota.fastboot=1` (`BERGAMOTA=1 enxerto/build.sh` adds it), or
- the flag is absent and the ABL ramdisk holds no SWEETXNU payload (plain `build.sh`).

`bergamota.fastboot=0` (`BERGAMOTA=0`) keeps the old loader/diagnostics path. If fastboot cannot start (USB init error, no buffer) the reason is
shown for 30 s and the old path continues (a payload in the ramdisk still boots). `bergamota.smmu=0` skips the SMMU step (debug).

## Controller bring-up (copy of what finally worked in xnu: sweet_usb.c `sweetusbfix=7` + sweet_smmu.c)
MMU off, Device memory, polled, event interrupt masked. After `fastboot boot`, ABL leaves GDSC/clocks on but the QUSB2 PHY powered down
(PWR_CTRL1 0x23, POWER_DOWN set); every earlier xnu attempt that only "took over the halted core" timed out in SETEPCONFIG (NOTES).
1. Check GCC USB30_PRIM GDSCR bit31 and CBCRs (master, cfg-noc) before touching DWC3 (a gated block hangs the bus); best-effort enable otherwise.
2. QSCRATCH GENERAL_CFG: PIPE clock from UTMI clock (dwc3_qcom_select_utmi_clk).
3. QUSB2 PWR_CTRL1: clear POWER_DOWN, set CLAMP_N_EN (0x22), wait 250 us and PLL_STATUS lock.
4. Linux core soft reset (GCTL.CORESOFTRESET + both PHYSOFTRST, 100 ms), DCTL.CSFTRST, then restore ABL's GCTL with RAMCLKSEL = 0.
5. HS quirks (GUCTL1 bit17, DCTL INITU1/2ENA = 0, GUSB2PHYCFG SUSPHY/ENBLSLPM = 0), GUCTL1 bit26.
6. apps_smmu (0x15000000): stream 0x740 (DT `iommus = <&apps_smmu 0x740 0>`) -> a stage-1 context bank that identity-maps DRAM
   0x80000000..0x27fffffff (Normal NC), exactly as sweet_smmu.c. Under the Qualcomm hypervisor an unmapped stream faults and the first DMA resets the SoC.
   An existing exact SMR is retargeted, otherwise a free one is used; the originals are restored by `usb_dwc3_stop()`.
7. Our event buffer (4 KiB in the image), DEVTEN = reset/disconnect/connect-done, DEVSPD = HS, ep0 config, DALEPENA, SETUP TRB.
8. QSCRATCH VBUS override (HS_PHY_CTRL bits 20/28, SS_PHY_CTRL bit 24), then DCTL.RUN_STOP.
Control transfers follow Linux ep0.c (status stage on XferNotReady). Descriptors: VID 0x18d1 PID 0x4ee0, bcdUSB 2.00, one interface class 0xff/0x42/0x03,
bulk IN 0x81 and OUT 0x01, 512 B (high speed), strings "Bergamota" / "Bergamota fastboot" / serial "bergamota0001", device qualifier answered, others STALLed.
Bus reset/disconnect ends all transfers, returns ep0 to SETUP and tells the protocol layer (`FB_LINK_LOST`, which forgets any download).

## DMA, memory and caches
- TRBs, event buffer, setup/command/response buffers: static arrays in the Enxerto image, aligned to 4 KiB at run time (the image is linked at 0). Same memory xnu's
  DMA used (kernel DRAM, inside the SMMU identity map), far from the kernel destination.
- Fastboot phase is MMU-off, so CPU accesses are Device and coherent with DMA. The one hazard is dirty lines ABL may have left in memory we DMA into:
  before every download slice the target range is cleaned+invalidated (`dc civac`), after it invalidated (`dc ivac`).
- The cached MMU only comes up inside `loader_boot_payload` (via `mmu_enable_ranges`, which invalidates the payload range again), after `usb_dwc3_stop()` has halted
  the core, zeroed GEVNTADR/emptied the event buffer (nothing may DMA into the image later), restored QSCRATCH and the SMMU entries.
- **Download buffer: 0xb8000000, 1 GiB (to 0xf8000000)**, trimmed at run time around the Enxerto image, the DTB and the ABL initrd.
  Derivation: live DT `memory` = 0x80000000..0x1fd4a0000; every fixed reserved region ends below 0xb0400000 (ramoops 0xb0000000+4 MiB, ramdump_fb 0xaf000000);
  mkadt.py validates its pools inside 0x9f800000..0xfd000000; the real payloads use phys_base 0x100000000, mem_size 0xfcc00000 (the whole upper bank), so the buffer must be
  in the low bank (loader refuses a payload overlapping `[phys_base, +mem_size)`); ABL's own USB event buffer sat at 0xfdfc8000, so stay below 0xfd000000.
  It overlaps xnu's default zero-copy low pool (0xb0400000 + 252 MiB), which xnu only uses after the buffer is dead. `max-download-size` = 0x40000000.
- Bulk OUT: one TRB per transfer of up to 8 MiB straight into the buffer (rounded to 512), the next one queued on completion; the screen is redrawn while a transfer runs.

## Protocol (fastboot.c)
`getvar:` version 0.4, version-bootloader bergamota-1, product beryllium, serialno, secure no, unlocked yes, max-download-size 0x40000000, is-userspace no,
bergamota 1, `getvar:all` (INFO lines + OKAY). `download:<hex>` (DATA, bulk data, OKAY; > max or 0 -> FAIL). `boot`: the download must be an Android boot.img
(v0-v4: take the ramdisk) whose ramdisk is a SWEETXNU payload, or a raw SWEETXNU payload; `loader_check` validates the header, every file range and every destination
(inside `[phys_base, +mem_size)`) **before** OKAY is sent, then `loader_boot_payload(start, end, 1)` runs with the buffer instead of the ABL initrd (it shows the branded boot screen).
`reboot` (restart reason 0x77665501, PSCI SYSTEM_RESET, PS_HOLD fallback), `reboot-bootloader` (IMEM 0x146bf65c = 0x77665500: ABL fastboot), `continue` (= reboot).
`flash`, `erase`, `format`, `set_active`, `oem`, `flashing`, logical-partition and snapshot commands answer FAIL; there is no storage-write code. Link loss drops the session state.
If the loader fails after OKAY the error is shown on the boot screen and the phone resets into ABL fastboot after 20 s.
Screen: USB state, buffer, last command/reply, download MiB, event/setup counters, DWC3/GCTL/QUSB2/SMMU diagnostics (for the first hardware run).

## Cold boot (`usb_power.c`)
On a power-on without fastboot, ABL leaves USB off. `usb_power_up()`: if GDSC/clocks are on, nothing. Otherwise: cfg-noc/aggre/ahb2phy branches, CLKREF_EN, clear GDSC SW_COLLAPSE,
master RCG 66.67 MHz (GPLL0/9; DT core-clk-rate-hs), mock-UTMI/aux RCGs 19.2 MHz (XO), branches, BCR pulses (USB30_PRIM 0xf000, AHB2PHY 0x6a000, QUSB2PHY 0x12000),
the QUSB2 init sequence from live.dts ending with PWR_CTRL1 = 0x22, then reads GSNPSID. Not handled: PHY supplies (vdda18/vdda33/vdd via PMIC/RPMh), the efuse tune correction,
PIPE/QMP SuperSpeed (port is USB 2.0). The GCC offsets of cfg-noc (0x0502c) and aggre are copied from sweet_usb.c (checked on beryllium by the xnu probe only in the "already on" case);
voted-clock enable registers are not used. Treat as best effort.
