# Poco F1 display: backlight fade, MDP hardware scaling, zero-copy scanout (patch 0126)

Patch `xnu/patches/0126-beryllium-fb-hw-scaler.patch` (diff against `research/bt125/xnu` = 0001-0125 applied; `git apply --check` verified on a fresh copy; the six touched files compile with `tools/xnu-cc.py` and every new extern resolves in the objects). **Not booted.** Everything is gated by a boot-arg; every log line starts with `SWEET FB:` (SMMU/SPMI helpers: `SWEET SMMU:` / `SWEET SPMI:`). Files: `iokit/Kernel/arm/SweetFramebuffer.cpp` (AppleCLCD), `SweetSurface.cpp/.h`, `bsd/dev/sweet_spmi.c/.h`, `bsd/dev/sweet_smmu.c`.

Sources used: mainline Linux `qcom-wled.c`, `dpu_hw_util.c` (`dpu_hw_setup_scaler3`), `dpu_hw_sspp.c`, `dpu_plane.c` (`_dpu_plane_setup_scaler3`), `spmi-pmic-arb.c` (v5 channel layout, in `research/linux-src`), `docs/TOPAZ_REVIEW.md` section 3/5, and the boot probe in `logs/boot-0116hw.txt`. The Linux DPU/WLED sources are not in the tree; facts were read from upstream and are tagged below where they were not re-checked on hardware.

Boot-arg summary (Poco F1 only; `sweetfb_blfade` default 1, all others default off):

| boot-arg | meaning |
|---|---|
| `sweetfb_blfade=1/0` | WLED backlight ramp on display off/on (default 1); 0 = pixel fallback |
| `sweetfb_hw=1` | VIG0 QSEED3 scales a canvas-sized back buffer (implies `sweetfb_flip=1`; if `sweetfb_scale` is not given, fit = 1) |
| `sweetfb_hwpe=0` | do not write the SSPP pixel-extension registers (diagnostic variant) |
| `sweetfb_zc=1` | zero-copy scanout (needs `sweetfb_hw=1`); implies `sweetfb_smmu=1` |
| `sweetfb_smmu=1/2` | read-only dump of the MDP SMMU streams 0x880/0xc80: 1 = SMR/S2CR/CBAR/CBA2R, 2 = also the context-bank registers |

## 1. Backlight fade (`sweetfb_blfade`)

Power off (`RequestPowerChange(0)`) used to fade pixels: 6 steps, each rewriting the whole 10 MB write-combined framebuffer with volatile read-modify-write (uncached reads), which painted the screen in bands. Now:

- **WLED** = PMI8998, SPMI SID 3 (`pmi8998.dtsi`: `reg = <0xd800>, <0xd900>`; beryllium: `qcom,num-strings = <2>`). Offsets from Linux `qcom-wled.c` (WLED4), verified in the source, not on the phone:
  - control module `0xd800`: `MOD_EN` +0x46 bit 7 (read only here, never written);
  - sink `0xd900`: `BRIGHT(n)` = +0x57 + 0x10*n, 16-bit little endian, max 0xfff (strings 0, 1 -> 0xd957/0xd958 and 0xd967/0xd968); `SYNC` +0x47: write 0x00 then 0x0f (`GENMASK(max_string_count - 1, 0)`, WLED4 = 4 strings) to latch.
- Start (`blInit`): read both brightness words, MOD_EN and SYNC (log). Armed only if brightness is non-zero and MOD_EN bit 7 is set.
- Off: 12 steps, one per vsync tick (about 200 ms), `level = as_found * pos^2 / 144` (gamma-ish), each step = two 2-byte brightness writes + sync toggle. The values "as found" are re-read at the start of each ramp, so whatever is on the panel is what is restored. On: after the latest frame was presented (`fDirty` consumed) the ramp goes back up, the last step writes the exact bytes read earlier (raw 16-bit, including any upper bits).
- Read-back at steps 11, 1, 0 and 12: a write that does not read back, a refused write, or an SPMI timeout aborts the fade: the original bytes are written back (best effort), `fBlOK` is cleared and the screen goes black through the fallback.
- **Fallback** (`blackout`): one `memset` of ABL's framebuffer plus, when page flipping, a flip back to frame 0 (hardware scaler programming is restored; zero-copy holds released). Used for `sweetfb_blfade=0`, sweet, any SPMI problem. No more pixel fade.
- **SPMI write support** (`sweet_spmi_write`, new): pmic-arb v5 read/write channel `0x0c600000 + 0x10000 * APID` (one 4 KiB page mapped per APID, max 4), `CMD +0x00 = (0<<27 EXT_WRITEL) | (addr&0xff)<<4 | (len-1)`, `WDATA0 +0x10`, `STATUS +0x08` (bit0 done, 0x0e error). Refused unless the APID's owner in the ownership table (cfg `+0x700 + 4*APID`) is EE 0 (`qcom,ee = <0>`), with a one-time log `SWEET SPMI: APID n ... owned by EE m: write refused`. Whitelist: SID 3 only, Poco F1 only, addresses 0xd947 (1 byte), 0xd957/0xd967 (1-2 bytes), 0xd958/0xd968 (1 byte). The read whitelist gained SID 3 peripherals 0xd8/0xd9. `sweet_spmi_init` now takes a lock (battery and framebuffer start from different threads).
- Not done on purpose: the panic hook does not touch the WLED (it would need the SPMI lock). A panic while the display is "off" shows the text on a dark panel.

Expected log lines:

```
SWEET FB: WLED brightness string0 0x0xxx string1 0x0xxx, MOD_EN 0x80, SYNC 0x..
SWEET FB: backlight fade armed: 12 steps, power off ramps WLED down, on restores 0x.../0x... exactly
SWEET FB: display off
SWEET FB: backlight ramp down from 0x.../0x...
SWEET FB: backlight off (0x0000/0x0000)
SWEET FB: display on
SWEET FB: backlight restored (0x.../0x...)
```
Failure signatures: `SWEET SPMI: ... write refused`, `SWEET SPMI: write sid=3 addr=... status ...`, `SWEET FB: WLED string n wrote .., reads ..`, `SWEET FB: backlight fade failed at a step; ... pixel fallback`, `SWEET FB: display off: screen black in one step`.

## 2. MDP hardware scaling (`sweetfb_hw=1`)

Boot probe facts (boot 0116hw): ABL scans VIG0 (`SRC0_ADDR` 0x9d400000, stride 0x10e0, size 0x08c60438 = 1080x2246, format 0x000237ff = alpha-enabled 8888, `SRC_OP_MODE` 0x80000000 = PE override), QSEED3 v0x1003 with OP_MODE 0 on VIG0, `CTL0 layer0 0x01000005` (bit 24 = mixer border out), `LM0 out 0x08c60438`.

Decision (`hwSetup`, pure arithmetic): VIG pipe, QSEED3 version 0x1002/0x1003, `fScale` 1 or 2 (crop has nothing to scale), canvas <= 2560 wide, ratios < 4x. Destination rectangle = exactly what the CPU scaler and the touch mapping use: `dstW = logicalW * num/den`, `dstH` likewise, at (`fPadX`, `fPadY`). Fit @2x (750x1624): 1037x2246 at (21,0); fit @3x (1125x2436): 1037x2246 at (21,0).

Buffers: with the scaler, frames 1 and 2 hold the canvas 1:1, stride `fHwStride = roundup(canvasW*4, 64)` (@2x 3008, @3x 4544; 64-aligned like the IOSurface rows, so the copy is one `memcpy` of `h*stride`), in the splash carve-out spaced by the canvas size: `0x9d400000` (ABL, frame 0), `+10 MiB`, `+21 MiB` (@3x; end +31.6 MiB < +36 MiB). Both are zeroed. `present()` -> `presentCanvas()` copies each layer at its logical rect (no per-pixel math, no `fXMap`).

Register programming (`hwProgram`, once when the first canvas frame is scanned; everything is latched by the CTL flush that `scanAddr` does next; VIG0 = MDP + 0x5000, QSEED3 = VIG0 + 0xa00):

| reg | value | source |
|---|---|---|
| VIG0 +0x00 SRC_SIZE, +0x04 SRC_IMG_SIZE | `(canvasH<<16) | canvasW` | dpu_hw_setup_rects_impl; IMG_SIZE per MDP5 (unverified on SDE, harmless) |
| +0x08 SRC_XY | 0 | |
| +0x0c OUT_SIZE / +0x10 OUT_XY | `(dstH<<16)|dstW` / `(dstY<<16)|dstX` | |
| +0x100/0x104/0x108 PE C0, +0x110/0x114/0x118 C1C2, +0x120/0x124/0x128 C3 | LR = TB = 0, REQ_PIXELS = `(h<<16)|w` of the source | dpu_hw_sspp_setup_pe_config with zero extension; skipped with `sweetfb_hwpe=0` |
| QSEED3 +0x90/0x94/0x98/0x9c PHASE_INIT_Y_H/Y_V/UV_H/UV_V (version 0x1002: +0x0c) | 0 | |
| +0x10/0x14 PHASE_STEP_Y_H/V, +0x18/0x1c UV_H/V | `(src << 21) / dst` per axis (24 bit), same on the UV set (alpha channel) | `_dpu_plane_setup_scaler3` mult_frac(1<<21, src, dst) |
| +0x20 PRELOAD | `4 | 3<<8 | 4<<16 | 3<<24` | DPU_QSEED3_DEFAULT_PRELOAD_H/V |
| +0x40 SRC_SIZE_Y_RGB_A, +0x44 SRC_SIZE_UV, +0x48 DST_SIZE | src, src, dst (`(h<<16)|w`) | |
| +0x04 OP_MODE (last) | BIT0 enable, 1<<16 Y/RGB filter bilinear, BIT14 non-DX, BIT31 blend_cfg; if SRC_FORMAT bit 8 (alpha, set on ABL's format): BIT10 + alpha filter bilinear (1<<29; 1<<30 on v0x1002) | `dpu_hw_setup_scaler3`; no detail enhancer, no LUT upload (lut_flag 0), dir_en 0 |
| SRC0_ADDR +0x14, YSTRIDE0 +0x24 | back buffer PA, `fHwStride` | |
| LM0 +0x45008 / +0x45010 BORDER_COLOR | 0, only when the fit leaves margins and the boot border colour is non-zero (`border fix`) | `dpu_hw_lm.c` LM_BORDER_COLOR_0/1 (from memory, unverified) |
| CTL0 +0x2018 FLUSH | `VIG0 BIT0 | CTL BIT17` (| `BIT6` LM_0 with the first flush after a border change) | `dpu_hw_ctl.c` |

LM0 `OUT_SIZE` stays 1080x2246; the margins of a fit come from the mixer border (CTL0 layer0 bit 24 is set by ABL).

Panic and off: before anything is written, `flipSetup` records the boot values of every register above (about 32 entries) plus `SRC0_ADDR`/`YSTRIDE0` in a table; `sweet_fb_panic_hook` replays it (plain MMIO, no locks, address/stride last) and flushes (`BIT6` included when the border was changed), so ABL's frame is scanned 1:1 with the scaler off. The blackout path does the same (`scanTo(0)` restores the geometry when the scaler was on). `waitLatch` waits on the exact flush bits of the last flush.

Expected log lines:

```
SWEET MDP: VIG0 img 0x.. xy 0x.. outxy 0x.. pe c0 .. c12 .. c3 ..        (new probe line, boot values)
SWEET MDP: CTL0 layer0 0x01000005 ... LM0 out 0x08c60438 border 0x........ 0x........
SWEET FB: hw scaler: canvas 750x1624 (stride 3008) -> 1037x2246 at 21,0 in the 1080x2246 panel, phase step 0x... , qseed3 v0x1003, PE regs written, border fix no
SWEET FB: page flipping on VIG0: frames 0x9d400000 0x9de00000 0x9e800000 (... bytes each back buffer, 32 restore regs), hardware scaler
SWEET FB: hw scaler programmed: src 750x1624 dst 1037x2246 at 21,0, qseed3 op 0xa0014401 steps 0x.../0x... (alpha)
```
(op = `BIT0|BIT10|BIT14|1<<16|BIT29|BIT31` = 0xa0014401 with alpha, 0x80014001 without.) Declines: `SWEET FB: hw scaler: ... CPU path / CPU scaling`.

Things that can go wrong (and what the log shows): black screen = something in the scaler/PE programming (try `sweetfb_hwpe=0`; compare the probe line's PE regs); picture shifted/garbled = stride or PE; margins not black = border colour; tearing = latch (`did not latch` line). A panic or reboot restores the unscaled boot frame.

## 3. Zero-copy scanout (`sweetfb_zc=1`, requires `sweetfb_hw=1`) - implemented, engages only if its safety gate passes

**Finding (decisive): on this memory layout it cannot engage.** All RAM xnu owns is above 4 GiB (`0x1_0000_0000 + 0xfcc00000`, NOTES), while `SRC0_ADDR` is a 32-bit register and the MDP's SMMU streams (`iommus = <&apps_smmu 0x880 0x8>, <&apps_smmu 0xc80 0x8>` in sdm845.dtsi / live.dts, `qcom,iommu-earlymap`) are either in bypass (IOVA = PA, still 32 bit) or translated by ABL's context bank, which was set up for the splash region only (the flip buffers at 0x9de00000/0x9e800000 work, i.e. at least +20 MiB of it is mapped; nothing else is known). An identity map via `sweet_smmu_map_sid` does not help: it identity-maps DRAM, but a source above 4 GiB needs a non-identity IOVA window below 4 GiB. So zero-copy needs either (a) xnu owning a low-RAM window (topaz `mkadt --midmem`) or (b) a dedicated SMMU context bank for the MDP SIDs with a per-frame IOVA remap of the surface pages (live switch of a scanning stream = the risky part: any unmapped fetch resets the SoC). Neither is attempted here.

What the patch does instead (all default off, all logged):

1. `sweetfb_smmu=1` (implied by `sweetfb_zc`): `sweet_smmu_probe_sid(0x880|0xc80, level)` reads, **read-only and without creating a bank or an SMR**: sCR0 (USFCFG, CLIENTPD), ID0/ID1, every valid SMR matching the SID under its mask, the S2CR it selects (TRANSLATE/BYPASS/FAULT, context bank) and, level 1, the bank's CBAR/CBA2R; level 2 additionally SCTLR/TTBR0/TCR/TCR2/MAIR0/FSR (those banks belong to ABL/the hypervisor: only read when asked; the SMR/S2CR/CBAR reads are the same kind sweet_smmu already does). Result per stream: 1 bypass, 2 translate, 3 fault, 4 mixed, 0 no match, -1 unreadable. Zero-copy is armed only if both streams are in bypass (`fZcOK`).
2. With `sweetfb_zc=1`, `sweet_surface_want_contiguous(canvas bytes)` makes `SweetSurface` allocate big surfaces with `inTaskWithPhysicalMask(0xfffff000, physically contiguous)`; on this layout the allocation fails once (`SWEET SURF: no contiguous memory below 4 GiB ...`), and surfaces stay scattered (the normal path).
3. The path itself (`zcPresent`): a lone layer, full canvas (0,0,w,h), surface exactly canvas sized, plain 4-byte non-wrapped, 16-byte aligned stride, `getPhysicalSegment` contiguous for the whole used extent, PA 64-byte aligned and `PA + extent <= 4 GiB`, `fZcOK`. Then: `sweet_dma_sync_va` (`dc civac`) over the surface (CoreAnimation drew through the cache), extra in-use hold (state page +0x18), `scanAddr(pa + offset, bytesPerRow)` with the hardware scaler. The held surfaces (up to 4) are released by `zcPoll` once the flush bits are clear, i.e. a later frame is latched (the newest stays held); `blackout`/power-off releases all. Anything else falls back to the copy path with the exact reason logged once (max 6 lines) and cached per surface id.

Expected lines on this hardware:

```
SWEET SMMU: probe sid 0x880: sCR0 0x... (USFCFG . GFIE . CLIENTPD .) ID0 0x... ID1 0x..., N SMRs M CBs
SWEET SMMU: probe sid 0x880: smr i 0x... (id 0x880 mask 0x8) s2cr 0x... type BYPASS|TRANSLATE|FAULT cb n
SWEET SMMU: probe cb n: CBAR 0x... CBA2R 0x...                    (level >= 1, translate only)
SWEET FB: MDP SMMU streams 0x880 -> a, 0xc80 -> b (...)
SWEET FB: zero-copy scanout armed (...); MDP SMMU is NOT verified bypass: every frame will take the copy path
SWEET SURF: no contiguous memory below 4 GiB for N bytes; large surfaces stay scattered (zero-copy scanout cannot engage)
SWEET FB: zero-copy declined for surface N: memory is not physically contiguous      (or "... above 4 GiB ...")
```
The probe output is the real deliverable of step 3: it tells whether (b) is needed and what ABL maps. `SWEET FB: zero-copy scanout of surface ...` would only appear if low contiguous RAM existed.

## 4. Test order

1. **Baseline** (current boot-args, e.g. `sweetfb_flip=1 sweetfb_scale=1`): note the MDP probe lines (new `img/xy/pe` and `border` fields are boot values, keep them).
2. **blfade**: add nothing (default 1). Boot, power button: expect the WLED lines, a ~200 ms ramp, no bands; wake: backlight returns to the same level; check the `backlight restored` line shows the same two words as `backlight ramp down from`. Then `sweetfb_blfade=0` once: screen goes black in one step, no bands. Watch for `write refused` / `reads` mismatch lines (EE ownership or hypervisor).
3. **`sweetfb_hw=1` at @2x** (750x1624 ADT, `sweetfb_scale` unset or 1): expect the `hw scaler:` and `programmed` lines, a 1037-wide picture with black bars, cheaper present. Compare the 21 px bars and touch alignment (HID uses the same pad/ratio). On a black screen retry with `sweetfb_hwpe=0`; panic/reboot restores ABL's frame. Also try `sweetfb_scale=2` (stretch).
4. **`sweetfb_hw=1` at @3x** (1125x2436 ADT, e.g. `beryllium-hi-3x.adt`): same checks; this is the 11 MB buffers case (+10/+21 MiB frames, line width 1125 < 2560).
5. **`sweetfb_smmu=1`** (alone, no zero-copy): read the SMR/S2CR lines. Then `sweetfb_smmu=2` only if level 1 was fine and you want the bank registers.
6. **`sweetfb_zc=1`** (with `sweetfb_hw=1`): expected outcome today is the declined lines above; it must stay on the copy path with an unchanged picture. Treat a picture change or a hang here as a bug.

Reverts: `sweetfb_hw` / `sweetfb_zc` / `sweetfb_smmu` are absent by default; `sweetfb_blfade=0` disables the only default-on part. Risks not testable offline: QSEED3 register semantics (bilinear, alpha bits, PE registers), LM border write (BIT6 flush), EE ownership of the WLED APIDs, and the read of the ABL-owned context banks at `sweetfb_smmu=2`.
