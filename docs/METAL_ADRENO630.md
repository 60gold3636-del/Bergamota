# Metal + CoreAnimation GPU acceleration on the Adreno 630 (Poco F1, iOS 18.7.8, SDM845)

Status: research and design, 2026-10-23. Nothing here was run on the phone. Evidence tags: **[V]** read in our own 22H352 binaries or in the cited
source this session; **[I]** inferred; **[M]** from memory, not re-checked. Third-party content was treated as data and nothing from it was built or run.
Names: the bootloader is Enxerto (`enxerto/`), the patcher Renegade (`tools/renegade`), our kernel Heartwood.

Supporting material (all under `research/metal-a630/`): `ios18-metal-findings.md` (iOS 18 evidence with addresses), `a6xx-kernel-and-userspace.md`
(what a minimal A630 kernel driver and Turnip/freedreno submission do, from Linux/Mesa), `snapintosh-notes.md` (licences, kext/bundle/air2ir3
architecture), `lists/` (class/method/selector lists), `tools/` (offline scripts), `hackios-xnu-kernel-ext/` (clone of the user-suggested repo, section (f)).
Older related docs: `GPU_A630_BRINGUP.md` (stages 1-7 of patch 0103), `GPU_RESEARCH.md`, `GPU_PHASE0_DISCOVERY.md` (iOS 16 discovery analysis).

## 0. Summary

1. **iOS 18 CoreAnimation does not need a Metal device.** QuartzCore 22H352 still contains a CPU rasterizer and the render server falls back
   Metal -> OpenGL ES (EAGLContext) -> software. A missing `MTLDevice` is therefore **not** by itself the reason for the black screen.
2. **Do not register a half-implemented Metal device ("null Metal device" as a phase 0).** CA tries Metal first; a non-nil device that cannot do a
   render pass makes CA stay on the Metal path and draw nothing. Either no device (today, software path) or a complete one.
3. **Recommended first GPU phase: OpenGL ES for the render server, not Metal.** iOS 18 QuartzCore still drives an `EAGLContext` with the same private
   selectors as iOS 16, so a replacement EAGL library over Mesa freedreno (userland) + an msm-DRM-shaped kernel client (our driver) gives CA GPU compositing without
   a Metal driver. A project on the same XNU (xnu-8796, Adreno 642L) has demonstrated this on hardware (section (f)). Metal for apps is a later, much larger phase.
4. The kernel bring-up (power/GMU/HFI/SMMU/zap/CP) is common to both routes and is the real critical path; patch 0103 already reaches GX on and
   needs only the zap shader files for stage 6.

## (a) Can iOS 18 CoreAnimation render without a Metal device?

**Yes, in principle: there is a software renderer, and it is what runs when both Metal and GLES are unavailable.** Evidence (details and
addresses in `research/metal-a630/ios18-metal-findings.md` section 3):

* **[V]** Strings in QuartzCore: `sw renderer doesn't support tiling`, `image is too large for software renderer, ignoring`, `SW renderer invalid destination
  format %c%c%c%c`; code at QuartzCore+0x21cd6c accepts the destination fourcc `BGRA` (our IOMFB surfaces are BGRA), `A008/L008/L555/L565`.
* **[V]** The lazy software-renderer constructor at 0x1849d11b0 allocates the renderer state and logs `CoreAnimation: Software renderer! Simulating crash!`
  and `CoreAnimation: Failed to initialize Metal or OpenGLES contexts!`, then **returns the renderer**: it is a diagnostic log, not an abort.
* **[V]** Metal is obtained with `MTLCreateSystemDefaultDevice` (4 call sites; `MTLCopyAllDevices` unused). `CAMetalLayer nextDrawable` with a nil device
  returns nil with a log line; there is no assertion.
* **[V]** backboardd has no Metal code of its own; it renders only through QuartzCore.
* **[V by observation, iOS 16]** NOTES: iOS 16.7.16 on this phone already renders the whole UI (lock screen, Safari pages) through the software path with no
  MTLDevice (`IOAcceleratorES` -> 0 services).
* **[V]** Metal discovery on 22H352 is unchanged: `IOServiceMatching("IOAcceleratorES")`, property `MetalPluginName`
  (+ optional `MetalPluginClassName`), bundle from `/System/Library/Extensions/<name>.bundle`, `[[cls alloc] initWithAcceleratorPort:svc]`. No service
  -> no device -> CA falls back.

**Consequence for the black screen.** backboardd presents frames (3000+ swaps), so the render loop runs; most likely it runs on the software renderer and the
cause is elsewhere. Candidates, ordered by how cheaply they can be checked (none verified):
1. The swapped IOSurface is not black but the panel copy is: count non-zero pixels of the surface in `SweetFramebuffer` swap (kernel side, no userland change),
   and compare with the panel memory.
2. The surface is black because nothing is committed: SpringBoard's root layer is empty/black (lock screen/wallpaper come from PosterBoard extensions, wallpaper
   `IOSurface`/Metal-backed layers `CAMetalLayer` with nil device draw nothing). Check which processes are alive (PosterBoard, SpringBoard UI services) and their
   crash logs; a black but functioning render server is the expected picture when the wallpaper layer can only be drawn by Metal.
3. The software renderer produces black for a format/colour-space reason (display colour space, `CA_DISPLAY_COLOR_SPACE`-style defaults, alpha 0 background). Dump the
   surface in a non-BGRA-assuming way (alpha channel!).
4. The IOMFB swap structure on iOS 18 carries several layers (detached/clone layers) while our swap path composites only layer 0.
Useful switches seen in QuartzCore (names only, gating unknown, maybe internal-build only; try via backboardd `EnvironmentVariables` in launchd.plist):
`CA_PRINT_TREE`, `CA_PRINT_FRAME_INFO`, `CA_DUMP_FRAMEBUFFERS`, `CA_DUMP_SURFACES`, `CA_ALWAYS_RENDER`, `CA_DISABLE_DETACHED`. There is no `CA_FORCE_SOFTWARE`.

**What would make CA draw if the SW path really draws nothing:** the only GPU-less lever is not registering a Metal device (today). A real fix needs either (b1) the GLES
route or (b2) a complete Metal device. A `null`/CPU Metal device is not a shortcut (point 2 of the summary): it would need the full MTLDevice/queue/pipeline/texture
plumbing (Apple's A12 driver is 59 classes, ~1,300 methods; `lists/ios18-agxmetala12-classes-methods.txt`) plus a CPU rasterizer for CA's Metal shaders.

## (b) Architecture

### b0. Layers

```
backboardd/SpringBoard (QuartzCore render server)
   |-- Metal route:  Metal.framework -> <our>Metal.bundle (_MTLDevice subclass: IOGPUMetalDevice-derived) -> IOGPU.framework -> IOConnect* -> kernel IOGPU-compatible service
   |-- GLES route:   EAGLContext replacement dylib (libredwood-gl style) -> Mesa gallium freedreno (a6xx) -> msm-DRM-shaped IOKit user client
   `-- software:     CA::OGL SW rasterizer (works today)
kernel (Heartwood, xnu-8796 now / xnu-11215 later): A630 driver  = power/GMU/HFI | SMMU CB + IOVA allocator | zap via PAS | CP ring/SQE | irq + fences | BO manager
                                                  + IOKit face: service named for the route (IOAcceleratorES, MetalPluginName) + user client
display: SweetFramebuffer (AppleCLCD stand-in): IOSurface swap -> panel (unchanged; separable from the renderer)
```

### b1. Kernel part

* **a6xx bring-up** (common to all routes): reimplement from the facts in `a6xx-kernel-and-userspace.md` (Linux is GPL-2.0: do not copy code). Patch 0103 has stages
  1-7 (CX GDSC, GMU RCG, GMU firmware boot, HFI v1 ACKs, GX via OOB, PAS zap, CP). Hardware state reached on the phone: GMU boots, HFI up, GX on, RBBM_STATUS readable;
  stage 6 waits for the zap files. New findings of this study that change plan details: a630 uses **VBIF** (not GBIF), has no `hw_apriv`, no preemption; RPTR
  shadow goes through `CP_WHERE_AM_I` (needs SQE >= 0x190, local file is 0x207); `RBBM_SECVID_TSB_*` writes are safe before the zap and only `RBBM_SECVID_TRUST_CNTL`
  (0xf400) must be avoided; the GPU SMMU walker must use 4 KiB granules even though iOS userland pages are 16 KiB; a single global pagetable avoids the
  `qcom_scm_set_gpu_smmu_aperture` call and `CP_SMMU_TABLE_UPDATE`; the a630 GMU does no bus scaling so the CPU must vote DDR bandwidth.
* **IOKit face** for the Metal route: an `IOAcceleratorES`-matching IOService (class derived from an `IOAcceleratorES` stand-in; closed IOGPUFamily headers do not exist
  for xnu-8796 or 11215, so we declare the class ourselves) publishing `MetalPluginName` (+ `MetalPluginClassName`), a user client answering IOServiceOpen type `1|(opts<<16)`
  and selectors 6, 2 (0x218 B out), 0 (0x40 B out), 4 (0x20 B out) exactly as `-[IOGPUMetalDevice initWithAcceleratorPort:options:]` demands (verified at
  0x21c1ce608 on 22H352; table in `ios18-metal-findings.md` section 2), then queue/buffer/fence/event selectors (sels 7..55 and traps 0..6, listed in
  `lists/ios18-iogpu-iokit-callsites.txt`) plus shared-memory command-buffer segments (`IOGPUMetalCommandBufferStorage`, `IOGPUMetalDeviceShmem`) and kernel command
  lists (`eIOGPUSegmentListShmemHeaderTypeKernelCommandList`). **Open item: the A12 kernel half (`IOGPUDeviceUserClient` dispatch table, event-machine layout)
  lives in the iOS 18 kernelcache and was not decoded here**; Snapintosh's table is macOS 27 (type 5, different selector numbers) and cannot be reused as is.
* **Memory:** BOs = wired `IOBufferMemoryDescriptor`s mapped into the GPU SMMU context (patch 0103 stage 7 already has page-table code); IOSurface-backed textures need
  `IOSurface` memory entered into the same context (hackios does this: `surfaceBuffer()`, section (f)). Non-coherent: CPU cache maintenance on submit.
* **Fences/interrupts:** CP timestamp (`CACHE_FLUSH_TS` to a memptr) + condvar; GPU/GMU/HFI IRQs through our GIC; polling is an acceptable first step (hackios polls 5x/ms).
* **Security/sandbox:** our MAC stand-ins permit `IOServiceOpen`; keep the Apple class names (`AGXDeviceUserClient`, `IOGPUDeviceUserClient`) to stay compatible with real
  profiles if sandboxing is ever tightened.

### b2. User part, Metal route (phase 4+)

* **Bundle:** our own `<Name>.bundle` (arm64e, built with the same ad-hoc signing Renegade applies), principal class a subclass of `IOGPUMetalDevice` (preferably) or `_MTLDevice`,
  loaded via the service's `MetalPluginName`. Apple's `AGXMetalA12` cannot be reused: it emits A12 GPU ISA (`AGXCompilerCore`), and its principal class is a deliberate dead end
  (`AGXPrincipalDevice` returns nil; the kernel sets `MetalPluginClassName=AGXA12Device`).
* **Classes to provide** (derived from `lists/ios18-agxmetala12-classes.txt`, which is Apple's own implementation list): Device, CommandQueue, CommandBuffer, Render/Compute/Blit
  encoders, RenderPipeline, ComputePipeline, DepthStencilState, Sampler, Buffer, Texture(+Layout), Heap, Library/Function plumbing from `Metal.framework` (generic), Event/Fence,
  IndirectArgumentEncoder; ICB, ray tracing, mesh, sparse heaps, residency sets, counters are skippable at first (Snapintosh refuses the same set: argument buffers, visible function
  tables, imageblocks, read_write textures; it compiles 32,125/32,136 WindowServer functions, and 18/18 CoreAnimation pipelines, on macOS).
* **What CoreAnimation actually uses** (the minimum viable device): the 18 CA pipelines (`QuartzCore default.metallib`, 1 vertex + 1 fragment each, blend/sampling/filters), IOSurface-backed
  textures (`newTextureWithDescriptor:iosurface:plane:`), render passes with load/store, shared events (render server <-> clients), memoryless/tile attachments (can be disabled
  by device report: `CA_DISABLE_TILE_SHADERS`/`CA_DISABLE_INPLACE_SHADERS` exist as CA switches), and `featureProfile`-style capability reports (Snapintosh's "device-report tuning"
  list is the best map; it is macOS-WindowServer oriented, SpringBoard/backboardd on iOS differ).
* **Shader path:** Apple's `MTLCompiler` produces AIR for the device; air2ir3 (AIR -> LLVM -> NIR -> ir3) compiles it; on iOS the compiler service for the device path must return AIR
  without invoking `AGXCompilerCore`; Snapintosh uses a pass-through plugin trick that exists for the simulator (iOS 18 equivalent unverified, open question). Our pipeline: reuse the MIT front end
  with `--chip` set to the a630 id (Mesa `0x06030001` [M]) and re-derive the binding ABI for a6xx (UBO limits, no preamble push on early a6xx, bindless layout; they are a8xx values today).
* **Alternative to avoid a Metal driver for CA:** the GLES route below; CA's GLES renderer needs only the EAGL selectors plus a GLES 3 implementation.

### b3. User part, GLES route (phase 2-3, recommended first)

* iOS 18 QuartzCore still calls `-[EAGLContext getMacroContextPrivate]`, `attachImage:toCoreSurface:invertedRender:`, `texImageIOSurface:...plane:invert:` and `CAEAGLLayer` [V]. A replacement
  `EAGLContext` implementation injected into backboardd (DYLD interpose/DYLD_INSERT, as the other project's `libredwood-gl` does for 16.5) over Mesa (gallium freedreno or the OSMesa-style
  software fallback for testing) turns CA's GLES renderer into GPU rendering with IOSurface textures. No `_MTLDevice`, no AIR, no IOGPU selectors.
* Kernel face: an **msm-DRM-compatible IOKit user client** (selectors = DRM ioctl numbers: GET_PARAM, GEM_NEW/INFO/CPU_PREP, GEM_SUBMIT, WAIT_FENCE, SUBMITQUEUE_*) so that stock freedreno works through a
  small libdrm shim. This is the smallest userspace/kernel contract that exists for a6xx.
* Unverified on iOS 18: whether CA enables the GLES renderer without `CA_ENABLE_OGL` (string present, usage not decoded), whether the GLES shader table/limits CA expects (the other project
  patches ninety function slots on 16.5) are the same on 22H352, and arm64e/PAC handling of an injected dylib under our platform-binary rules.

### b4. Reuse and licences

| Source | Use | Licence (exact) |
|---|---|---|
| Mesa freedreno: `src/freedreno/{ir3,fdl,vulkan(Turnip),registers,computerator}` | ir3 compiler, a6xx register DB, packet builders, UBWC/layout, kernel-backend interface | MIT (per-file SPDX read) |
| Mesa core `src/compiler/nir`, `src/util` | needed by ir3/air2ir3 | MIT overall; a few vendored util files carry other licences [M]: check per file |
| Linux `drivers/gpu/drm/msm/adreno/*`, `qcom_scm.c`, `mdt_loader.c`, `arm-smmu-qcom.c`, DTs | reference for sequences | GPL-2.0(-only): reimplement from facts, do not copy; `msm_kgsl.h` is GPL-2.0 WITH Linux-syscall-note |
| Linux registers/adreno/*.xml | register DB | MIT |
| Snapintosh umbrella | design reference | MIT **with GPL-2.0 components** (`compat/adreno-ib-tables.h` GPL-2.0-only; QEMU patch GPL-2.0-or-later) |
| SnapAdreno, SnapMetal, air2ir3 | kext skeleton, Metal plug-in structure, AIR->ir3 | MIT (every file); a kext built with the umbrella's table is GPL-2.0; Mesa patches inside air2ir3 keep Mesa's MIT notices |
| UniXNU (NativeAdreno/Turnip patch) | see `GPU_RESEARCH.md` | BSD-2-Clause-Patent (per that doc) |
| hackios-xnu-kernel | design/behaviour reference | APSL 2.0 (repo LICENSE and README "derivative of XNU, APSL 2.0"), see section (f) |
| hackios-xnu-userland (EAGL bridge, AIR->NIR) | design reference | MIT (LICENSE, 2026 OOSEX GANG); Mesa 25.0.7 with their patches fetched at build time |
| Firmware (`a630_gmu.bin`, `a630_sqe.fw`) | linux-firmware `qcom/` | redistributable under `LICENSE.qcom`; the zap image is the phone's own signed file (do not redistribute) |

Reuse by effort/benefit: air2ir3 front end **high** (chip-independent), Mesa ir3 **high**, plug-in class layout **high** as a template (Apple's real list is in our dumps), Snapintosh kext
skeleton **medium** (macOS 27 offsets), Snapintosh PM4 builder **low** (a8xx), Snapintosh/hypervisor-side code **none** (no EL2 monitor on Poco F1).

## (c) Phased plan

"Pre/post migration" refers to the planned move from xnu-8796 to xnu-11215 (section (e)). Efforts are for one developer with the phone; ranges, not promises.

| Phase | Deliverable | Gate | Effort | Needs kernel |
|---|---|---|---|---|
| 0 | **Explain the black screen on the software path.** Count non-zero surface pixels in the swap path, log layer count/formats per swap, check SpringBoard/PosterBoard liveness and crash logs, try `CA_PRINT_TREE`/`CA_DUMP_FRAMEBUFFERS` via launchd env. Keep `IOAcceleratorES` stub empty (no `MetalPluginName`). | a visible frame on the panel from the software renderer | 1-5 days | either (8796 now) |
| 0b | Optional probe: publish `MetalPluginName` with a bundle whose `initWithAcceleratorPort:` logs and **returns nil** (per `GPU_PHASE0_DISCOVERY.md` checklist; gives per-process open/discovery logs; also tests dlopen of an unsigned plug-in) | log shows backboardd/SpringBoard calling it, rendering unchanged | 2-4 days | either (8796 now) |
| 1 | **A630 power + CP ring + clear/blit.** Finish 0103: zap via PAS id 13, SQE, ring, `CP_ME_INIT`, secure-mode exit, fence write; then a PM4 solid fill and a 2D blit into an IOSurface shown by SweetFramebuffer. Requires `a630_zap.*` from the phone's `/vendor/firmware`. | CP timestamp advances; filled buffer shows on the panel; no SMMU faults | 3-8 weeks (the largest unknown is zap/secure CP on SDM845 without JTAG) | either; design for 11215's IOMapper/DMA interfaces from the start |
| 2 | **msm-DRM-shaped user client + Mesa freedreno on iOS** (compute test first, then GLES 3 triangle into an IOSurface) | `gl_test`-style triangle drawn by the Adreno; IOSurface texture sharing works | 4-8 weeks | either |
| 3 | **EAGL replacement for CA (GLES route)** in backboardd: GPU compositing for the render server; keep the software renderer as fallback on device-lost | SpringBoard drawn by the GPU; measurable speed-up vs software | 6-12 weeks (the other project spent a long time on CA's GLES shader slots/`vblur`/groups on 16.5) | either |
| 4 | **Complete Metal device skeleton** (nil-safe, fully functional or not registered): IOGPU-compatible user client, `IOGPUMetalDevice` subclass bundle, buffers/textures/fences/events/queues; compute path via air2ir3+ir3 first (blit/compute), then render passes | `MTLCreateSystemDefaultDevice` returns the device in a test app; 18 CA pipelines compile to a630 | 3-6 months | needs the A12 IOGPU kernel ABI decoded from the kernelcache; best on 11215 |
| 5 | CoreAnimation uses Metal (drop the GLES route or keep as fallback), cross-process shared events, drawables, memory pressure/reset, apps' Metal | SpringBoard/apps rendered by Metal | 3-6+ months, high risk | after migration preferred |

Which can start before the migration: 0, 0b, 1, 2, 3 all work on 8796 (they use IOKit user clients and our own drivers only). Phase 4/5 should target the final kernel to avoid redoing the IOKit
class work; the data-structure work (resource lists, command-buffer segments, shader pipeline, AIR) is kernel-independent and can proceed in userland before.

## (e) xnu-11215 migration: what changes for the GPU plan

(Public source `apple-oss-distributions/xnu`, tags xnu-11215.1.10 .. 11215.81.4; listing checked by `gh api`; the rest [M]/[I].)

* **IOKit plumbing we depend on is still public**: `iokit/Kernel/{IOMapper,IODMACommand,IOMemoryDescriptor,IOUserClient,IOUserServer}.cpp` exist in 11215. IOGPUFamily/IOAccelerator are
  closed in both generations: no headers either way, so the stand-in classes are ours regardless. `IOUserClient` in 11215 has the `IOUserClient2022` dispatch (`externalMethod` with
  `IOExternalMethodDispatch2022`) and the user-client filter hooks; our own user client can stay on `IOExternalMethodDispatch` (old style) and iOS 18's IOGPU.framework only sees selectors.
* **IOMapper**: the right abstraction for the GPU SMMU context bank (an `IOMapper` for the Poco F1 GPU SMMU lets `IODMACommand` produce GPU IOVAs). It is in 8796 as well; design the kernel
  GPU memory manager behind a thin mapper layer so it does not change with the kernel.
* **Exclaves**: the 11215 tree contains `osfmk/kern/exclaves*.c` and `osfmk/arm64/sptm/`; both compile away unless the config enables them (we are a non-SPTM, non-exclave config, like iOS 16's PPL-less
  build). The `mount -P 2` ExclaveOS graft issue in `IOS18_PORT.md` already comes from the userland side of this. No GPU consequence [I].
* **PPL/SPTM**: GPU page tables belong to the SMMU, not the CPU pmap, so PPL/SPTM do not affect an Adreno driver; wired buffers and `pmap_sync_page_attributes_phys`-type cache maintenance
  need to be re-checked on the new pmap (patch 0083 of the other 778G/618 projects fixed a 32-bit truncation in that call on 8796 [from `GPU_RESEARCH.md`]).
* **8796-only assumptions in what was drafted**: patch 0103's `vn_rdwr` firmware loader and `IORegistryEntry` hooks, `xnu/patches` for IOSurface (0046), the iOS-16 selector numbering in
  `GPU_PHASE0_DISCOVERY.md` (the open sequence is identical on 22H352, but the later selector map was not re-derived), Snapintosh notes written for "xnu-8796" in section 7 of snapintosh-notes.md, UniXNU
  references. The IOGPU contract numbers in this document are from the iOS **18** userland, which is the target regardless of kernel version.
* **Dependence on the migration**: none of phases 0-3. Phases 4-5 should be built against the kernel that will ship; decoding the iOS 18 kernelcache IOGPUFamily (which is built for the 11215-generation
  kernel) is easier to validate against 11215 headers than 8796.

## (f) Review of `oosexgang/hackios-xnu-kernel` (user-suggested)

Fetched read-only (`research/hackios-xnu-kernel-ext/repo`, 47 MB, shallow clone; nothing built or run; companion repo `hackios-xnu-userland` read via the GitHub API only).

* **What it is:** "HackiOS" boots **xnu-8796.121.2 (iOS 16.5)** with the **unmodified iOS 16.5 userland** on a **POCO X5 Pro ("redwood", Snapdragon 778G, SC7280-family)** and QEMU. Our kernel generation and approach are the same (their
  README: lock screen, home screen, apps, Wi-Fi, sound, camera work; "Metal for apps in progress").
* **Licence:** kernel repo `LICENSE` = **Apple Public Source License 2.0** (GitHub: NOASSERTION), README: "derivative work of XNU, APSL 2.0"; new files carry no per-file header, so treat them as APSL-2.0 covered
  code (copyleft-ish file-level, compatible with our own xnu-derived patches, but copying needs the APSL notices). Userland repo: **MIT** (2026 OOSEX GANG), Mesa fetched at build time.
* **Relevant content (high):**
  * `xnu/files/bsd/dev/redwood_adreno.c` (4,125 lines): step-by-step in-kernel bring-up of an **Adreno 642L (a6xx GMU-based, same generation as ours)** under Qualcomm's hypervisor: CX GDSC, GMU
    clocks, SMMU contexts, TrustZone PAS zap authentication, GMU firmware + HFI, GX power through the GMU, SQE, ring, first PM4 commands (22 numbered steps, `adreno=N` boot-args), recovery and
    stop. This is the same sequence as our patch 0103 stages and ends past our current wall (zap + CP), done on real hardware. Different SoC (SC7280-family addresses, different gpucc/GCC/SMMU),
    so a reference for ordering and pitfalls, not a drop-in.
  * `xnu/files/iokit/Kernel/RedwoodGPU.cpp` (1,295 lines): an IOService + IOUserClient that exposes **the Linux msm DRM ioctl numbers as selectors** (GET_PARAM, GEM_NEW/INFO/CPU_PREP/SUBMIT, WAIT_FENCE,
    SUBMITQUEUE_*) so that stock Mesa freedreno works through a libdrm stand-in (`tools/mesa/redwood-drm` in the userland repo), plus an IOSurface-backed buffer request; buffers are wired memory in the 3D SMMU
    context, write-combined. Interrupts are not used (polling), no per-client isolation, fences polled. Exactly the contract proposed in b3.
  * Userland (companion repo): `userland/src/eagl.c` (`libredwood-gl.dylib`): an **EAGLContext replacement over Mesa** that CoreAnimation's render server uses
    (`CA::WindowServer::EAGLServer::renderer()` tries Metal, then GLES, then `Server::sw_renderer()`), answering the same selectors we verified in iOS 18 QuartzCore (`getMacroContextPrivate`,
    `attachImage:toCoreSurface:invertedRender:`, `texImageIOSurface:...invert:`); `inject.c` hooks the renderer choice; they patch CA's GLES shader table for functions its GLES renderer lacks.
    `docs/air.md` documents an **AIR -> NIR** frontend (321/456 system metallib modules compile through ir3; 30 verified executing on the phone's Adreno) and notes that the Metal device object graph and kernel
    submission ABI are **not started** there either (AGXMetalA11 = 53 classes/1,158 methods + IOGPU 711 in iOS 16.5).
  * `MiniIOMobileFramebuffer.cpp`, `MiniIOSurface.*`: IOMFB/IOSurface stand-ins (like our SweetFramebuffer/SweetSurface).
* **Not relevant:** loader/UEFI, Wi-Fi (ath11k port on a Linux compat layer), audio, camera, APFS, GIC/PSCI/CPU-freq for a different SoC, QEMU scripts.
* **Fit with xnu-11215:** all code targets xnu-8796.121.2 (`BCM2837` config as base) and iOS 16.5; the driver files are plain kernel C/IOKit using stable KPIs, so they port to 11215 with the same effort as
  our own patches. Nothing in it addresses 11215 or iOS 18 (their QuartzCore/EAGL slot offsets are iOS 16.5 addresses, e.g. `VT_EAGL_SERVER`, `CA_SHADER_TABLE`: they must be re-derived on 22H352).
* **Verdict: useful, as a design proof and cross-check, not as code to merge.** It demonstrates on hardware, under XNU 8796, the exact route recommended here (a6xx bring-up in kernel + msm-DRM client + EAGL
  bridge over freedreno for CoreAnimation), shows what breaks (shader slots, blur, IOSurface sharing, hypervisor limits) and what the zap/PAS step needs. Risks: APSL licence on copied code; different SoC
  (hypervisor-restricted EL1; SDM845 on Poco F1 has the same TZ/zap requirement but our patches 0103 show a different register map); the claim "Adreno drawing the whole UI" was not re-verified by us.

## (d) Risks

1. **Zap shader / secure CP** (largest): without a signed `a630_zap` accepted by TZ the CP stays secure and no GPU use is possible on this phone; SMC convention on SDM845 (probe both SMC32/64); files come from the phone's Android vendor partition.
2. **GMU/HFI/SMMU debugging without JTAG**; silent resets from bad accesses (the 778G project reports hypervisor kills "a quarter of a minute later"); the GPU SMMU must be 4 KiB granule while iOS is 16 KiB.
3. **CoreAnimation's reaction to a non-nil Metal device** (hang/black/crash if any required selector or pipeline is missing; UniXNU saw frozen SpringBoard). Mitigation: nil-or-complete rule; software fallback on device-lost; test with a detached process first.
4. **iOS 18 IOGPU kernel ABI is unknown** (A12 `IOGPUDeviceUserClient` dispatch table and event-machine layout, selector semantics beyond sizes). Mitigation: decode the 22H352 kernelcache IOGPUFamily and the AGX kext; keep GLES route as the first GPU payoff.
5. **GLES route on iOS 18 untested**: gating (`CA_ENABLE_OGL`), CA GLES shader coverage, vibrancy/blur effects, performance of GLES-over-Mesa for the whole UI, arm64e injection. Fallback to software remains available.
6. **Compiler availability for Metal**: the device-path `MTLCompiler` returns A12 code unless a pass-through is possible; air2ir3 is a8xx-tuned (binding ABI, limits) and its C API is at version 2; LLVM version of iOS 18's AIR vs the 22 it parses is unverified.
7. **Licensing posture**: Linux GPL-2.0 sources are references only; Snapintosh umbrella carries a GPL-2.0-only table; hackios code is APSL-2.0.
8. **Performance**: a630 has GMEM tiling and UBWC; first versions will be sysmem/linear only (Snapintosh and the 642L project do the same) and DDR bandwidth voting is the CPU's job on a630.
9. **Kernel migration** may change IOKit behaviours subtly (IOMapper/IODMACommand semantics, user-client filters); keep GPU memory/mapper code behind a small layer.
10. **Disk/CI**: shaders, Mesa and LLVM builds are large; plan builds on the Mac/CI, not on the phone.

## Appendix: reproduction of the iOS 18 findings

`python3 tools/renegade/hfsx.py research/ios18/ios18-root-full.simg dsc $SCRATCH/dsc` (4 GB, delete afterwards), a venv with `capstone`, then
`DSC_DIR=$SCRATCH/dsc python3 research/metal-a630/tools/objc_classlist.py AGXMetalA12.bundle/AGXMetalA12 --methods` and
`... tools/iokit_selectors.py IOGPU.framework/IOGPU`. Outputs are in `research/metal-a630/lists/`.
