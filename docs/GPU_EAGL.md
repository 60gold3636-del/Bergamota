# GPU_EAGL: replacement OpenGLES.framework over Mesa (phases A + B of `METAL_ADRENO630.md`)

Status 2026-10-23, branch `gpu-eagl`. Everything below marked **[phone]** was run on the Poco F1 (iOS 18.7.8 22H352 on Heartwood xnu-11215) with the test tool only;
the system OpenGLES.framework was not touched and nothing runs inside backboardd yet.

## What this is

`gpu/eagl/` is our own implementation of the userland half of the GLES route:

```
app / QuartzCore (later)            gpu/eagl/src/eagl.m   EAGLContext, EAGLSharegroup, drawable + IOSurface glue (ObjC, MIT)
  gl* C entry points  ----------->  gpu/eagl/src/gl_stubs.c  457 generated trampolines, one per export of the real framework
                                    gpu/eagl/src/gl_resolve.c  fills the trampoline table from Mesa's glapi dispatcher
                                    gpu/eagl/src/osm.c         the only file that includes <GL/osmesa.h>
                                         |
                                    libOSMesa.8.dylib  (Mesa 25.0.7, gallium softpipe, OSMesa frontend, no LLVM)
                                         |   phase E: the same frontend over gallium freedreno (a6xx) + an msm-DRM user client
                                    IOSurface (BGRA) handed to CoreAnimation / IOMobileFramebuffer
```

* **Exports match the real library exactly.** `nm -gU` of the shim equals the export trie of `OpenGLES.framework` in the 22H352 dyld cache: 491 symbols = 457
  `gl*` functions (ES1 + ES2 + ES3 + extensions incl. the `*OES`/`*EXT`/`*APPLE` aliases), `EAGLGetVersion`, `EAGLGetCurrentMacroContextPrivate`,
  `EAGLMemoryNotificationRecycling`, `GLIContextFromEAGLContext`, 9 `GLC*` dispatch functions, 21 `kEAGL*` string constants, `EAGLContext`/`EAGLSharegroup` classes
  (+ `_OBJC_IVAR_$_EAGLContext._private`). The shim has one extra export, `EAGLShimVersionString` (ours). The name list comes from the public SDK `OpenGLES.tbd`
  (`tools/gen_gl_stubs.py`), the comparison with the cache from `tools/dsc_oglinfo.py exports` (names only, nothing from Apple's binary is stored in git).
* **ObjC surface = the real class's method list** (types read from the cache with `tools/dsc_oglinfo.py objc`): `initWithAPI:`, `initWithAPI:sharegroup:`,
  `initWithAPI:properties:`, `initWithAPI:sharedWithCompute:`, `+setCurrentContext:`, `+currentContext`, `renderbufferStorage:fromDrawable:`,
  `presentRenderbuffer:` (+ `atTime:`, `afterMinimumDuration:`), the IOSurface selectors QuartzCore calls
  (`attachImage:toCoreSurface:invertedRender:` is `B36@0:8 Q16 ^{__IOSurface=}24 B32`, `texImageIOSurface:target:internalFormat:width:height:format:type:plane:[invert:]`),
  `getMacroContextPrivate`/`GetMacroContextPrivate`, `setBlockFence:onQueue:`, `setParameter:to:`/`getParameter:to:`, `multiThreaded`, `debugLabel`;
  `EAGLSharegroup` `initWithAPI:`, `APIs`, `getGLIShared`, `debugLabel`.

## How the drawing path works

* Each `EAGLContext` is one OSMesa context created as an **OpenGL ES** context (ES1: API_OPENGLES, ES2/ES3: API_OPENGLES2; Mesa gives the highest ES it supports, softpipe: ES 3.1)
  with a 16x16 dummy default framebuffer (GLES clients never render to it). This needs the one-hunk patch `gpu/eagl/mesa/0001-osmesa-es-profile.patch` (new OSMesa
  profile `0x36`); stock OSMesa can only create desktop GL contexts. Sharegroups map to OSMesa share lists.
* `renderbufferStorage:fromDrawable:` reads `bounds` and `contentsScale` of the drawable (a `CAEAGLLayer`, or anything that answers them) and the colour format
  property, and calls `glRenderbufferStorage` at that pixel size.
* `presentRenderbuffer:` reads the bound renderbuffer back (own scratch FBO, GL state restored), converts RGBA to BGRA, flips to top-down, copies into the next
  IOSurface of a 3-surface pool and sets `drawable.contents = surface` (alpha forced to 255 when `isOpaque`).
* `attachImage:toCoreSurface:invertedRender:` records (renderbuffer-or-texture name, IOSurface, inverted); our `glFlush`/`glFinish` wrappers (installed over the
  Mesa entries of the trampoline table) copy every attached image into its IOSurface. This is the sync point CoreAnimation's GLES renderer needs before it swaps the surface to the display.
* `texImageIOSurface:...` copies the surface pixels (BGRA or RGBA 8888, plane 0) into the bound texture via `glTexImage2D`, optionally flipped (`invert:`).
* Unmapped/unsupported entry points log once (`OpenGLES(shim): glFoo is not implemented`, stderr) and return 0. Debug markers/labels and `glDiscardFramebufferEXT` are no-ops.
  Vendor-suffix aliases (`glBindVertexArrayOES` -> `glBindVertexArray`, `glVertexAttrib4f` -> `...ARB`, ...) are resolved at load time.
* `EAGL_SHIM_DEBUG=1` prints context/drawable/attach events and the list of unresolved entry points.

Copies are CPU copies (softpipe renders in system memory anyway); the IOSurface is never shared with the GPU in this phase.

## Build

Needs Xcode (iphoneos SDK), `brew install meson bison` (meson also in the venv), network for the Mesa clone. Build trees live outside the repo.

```
export GPU_EAGL_WORK=/some/scratch/dir               # ~1.6 GB for Mesa, <200 MB for the rest
gpu/eagl/mesa/build-mesa.sh                          # clone mesa-25.0.7, apply the patch, meson cross build (arm64e), ~4 min on M-series
gpu/eagl/build.sh                                    # shim + tests -> $GPU_EAGL_WORK/out-arm64e/
```

Mesa options (see `build-mesa.sh`): `-Dgallium-drivers=softpipe -Dllvm=disabled -Dosmesa=true -Dgles1=enabled -Dgles2=enabled -Dshared-glapi=enabled
-Dglx/egl/gbm=disabled -Dplatforms=` (EGL cannot be built without a platform; OSMesa is the minimal frontend, it was removed upstream in 25.1, hence the pinned 25.0.7).
llvmpipe was not attempted (needs an LLVM cross build; not practical here).

Binaries are built `-arch arm64e -miphoneos-version-min=18.0` and then rewritten for the A-series-less SDM845:

```
python3 tools/renegade/pacstrip.py --sign FILE       # = renegade strip --sign ; ad-hoc signature is accepted by our kernel
```

Every file needed it (the shim had 457 `braaz` from the trampolines, libOSMesa ~40k PAC instructions). Pushing: `scp -O` to `/var/root/gpu-eagl/` (layout:
`eagl_test`, `libOSMesa.8.dylib`, `OpenGLES.framework/OpenGLES`; the shim's rpath is `@loader_path/..`, the test's `@executable_path`).

`SHIM_INSTALL_NAME=/System/Library/Frameworks/OpenGLES.framework/OpenGLES gpu/eagl/build.sh` produces a shim with the system install name for a future root image; by default
the install name is `@rpath/...` so a test can never accidentally load the system framework.

Sizes (arm64e, after `strip -x`): shim `OpenGLES` 154 KB, `libOSMesa.8.dylib` 13.5 MB (softpipe + GLSL compiler + glapi), `eagl_test` 77 KB.

## Test

`gpu/eagl/test/eagl_test.m` links the shim by path and runs 38 checks (exit status = failures; `--bench`, `--dump FILE.ppm`):

* ES2 and ES3 contexts: create, make current, FBO + `renderbufferStorage:fromDrawable:` (fake `CAEAGLLayer` stand-in), shader compile/link (GLSL ES 1.00 and 3.00),
  clear + triangle, `presentRenderbuffer:` delivers a 128x128 BGRA IOSurface; apex pixel red at the **top**, below the triangle blue, corner blue (orientation, swizzle, alpha).
* `attachImage:toCoreSurface:invertedRender:` + `glFinish` fills the IOSurface top-down; `texImageIOSurface:` (BGRA to RGBA, `invert:YES` flips); sharegroup visibility
  of textures (shared and unrelated context); ES1 context + fixed-function call.

**[phone, 2026-10-23]** `RESULT: 38 passed, 0 failed` (34 before the macro-context checks); GL_VERSION `OpenGL ES 3.1 Mesa 25.0.7`, GL_RENDERER `softpipe`; IOSurface creation/locking works from an arm64e tool. Rendered frame
checked visually (red triangle on blue). Speed on one SDM845 core: 128x128 triangle + readback + present about 1 ms/frame; **750x1334 full-screen textured quad + present
about 560 ms/frame** (softpipe is a reference rasteriser: usable for correctness, not for compositing a UI; that is what phase E is for).

## What is NOT done / known gaps

0. The phone test ran once (two pushes of about 14 MB to `/var/root/gpu-eagl/`) before the coordinator paused phone writes (xnu-11215 hangs and corrupts userdata). Treat that directory as untrusted and delete it when the phone is usable again; no further device tests were done.

1. **Not injected anywhere.** The system framework is unchanged; QuartzCore/backboardd still use their own (Metal-backed, no device) OpenGLES. Whether QuartzCore's GLES renderer is
   enabled without `CA_ENABLE_OGL` on 22H352 is still unverified (see `METAL_ADRENO630.md` b3).
2. ~~`getMacroContextPrivate` zeroed block~~ **done 2026-10-23**: the macro context is populated (section "Macro context" below); QuartzCore's `CARenderer` renders through it on the phone.
3. `attachImage:` takes a GL object name (`Q`): the shim guesses renderbuffer vs texture with `glIsTexture/glIsRenderbuffer`; the real semantics (e.g. mipmap level, MSAA) are unverified.
4. ES2 contexts report GL_VERSION ES 3.1 (Mesa gives the highest); Apple reports 2.0 for ES2 contexts. `MESA_GLES_VERSION_OVERRIDE` could cap it per process.
5. Not implemented (forward to a logging stub), computed statically against Mesa's glapi table (the on-phone `EAGL_SHIM_DEBUG=1` listing could not be run, the phone went offline again): 17 of 457, namely the Apple fence extension (`glGenFencesAPPLE`, `glSetFenceAPPLE`, `glTestFenceAPPLE`, `glFinishFenceAPPLE`, `glDeleteFencesAPPLE`, `glIsFenceAPPLE`), `glFinishObjectAPPLE`, `glTestObjectAPPLE`, `glResolveMultisampleFramebufferAPPLE`, `glGetFramebufferParameteriAPPLE` and the matrix-palette OES set (4). Note `GL_APPLE_fence` is one of the extensions QuartzCore probes (section below).
6. Only 8-bit 4-byte IOSurfaces (BGRA/RGBA, plane 0) for `texImageIOSurface:`; no XR10/wide-colour formats, no YUV planes.
7. `GLC*` dispatch-selection functions are no-ops (they swap the real GLEngine's function tables).
8. Single-threaded softpipe; no `multiThreaded` fast path; `setBlockFence:onQueue:` finishes synchronously.
9. arm64 (non-e) build not produced; the kernel's `sweetarm64e=1` path loads the arm64e slices (this is what the tool ran as).

## Next steps

1. **Freedreno instead of softpipe (phase E), once the kernel msm-DRM user client exists.** Only `libOSMesa` changes: build Mesa with `-Dgallium-drivers=freedreno`
   (a6xx, chip id 0x06030001 for the Adreno 630) and a winsys that talks to the user client instead of `/dev/dri` (the kernel-backend interface of `src/freedreno/drm/` is
   small: bo new/info/cpu_prep, submit, wait-fence, submit-queues, GET_PARAM), keeping the OSMesa-style frontend or moving to a surfaceless `pipe_screen` + `st_api`
   frontend of our own. Our shim keeps working unchanged; the readback copy then becomes a blit/`resource_get_handle` into the IOSurface (UBWC off, linear), which removes
   the CPU copy. Prerequisites: stage 6/7 of `GPU_A630_BRINGUP.md` (zap shader, CP), BO manager + IOVA/SMMU mapping, fences.
2. Decode `EAGLMacroContext` use in QuartzCore 22H352, then inject the shim into a detached test process first, then backboardd (DYLD interpose of the framework path
   or a root-image replacement with `SHIM_INSTALL_NAME`).
3. Confirm the unresolved-entry-point list on the phone and add the missing Apple extensions that apps use (fences).

## How QuartzCore reaches GL (static analysis of 22H352, 2026-10-23)

Method: `tools/renegade/dsctools` + a capstone scan of QuartzCore `__text` (addresses are unslid cache addresses; QuartzCore = 0x18470f000).

1. **CoreAnimation does not call the `gl*` exports; it uses the macro context.** The only caller of `-[EAGLContext getMacroContextPrivate]` is at 0x1848f9728
   (the OGL context constructor, 0x1848f968c). It stores the result at `this+0x840` and then calls `glGetString`-like functions as `(*(ctx+0x3b0))(*(ctx+0), name)`,
   i.e. the CGL macro convention: **`EAGLMacroContext` == `struct _CGLContextObject { GLIContext rend; GLIFunctionDispatch disp; ... }`** (macOS `OpenGL/CGLContext.h`, `gliDispatch.h`):
   `rend` at +0 is passed as the first argument of every call, function pointers start at +8 (slot i at 8+8*i), signature `fn(rend, args...)`.
   Check: slot 117 = `get_string` in the public macOS header = offset 0x3b0, exactly what QuartzCore loads. It then probes `GL_APPLE_fence`, `GL_APPLE_texture_filter_cubic`,
   `GL_APPLE_texture_ycbcr_*`, `GL_APPLE_texture_xr`, `GL_APPLE_tile_order_rot`, `GL_EXT_shader_framebuffer_fetch`, `GL_EXT_texture_filter_anisotropic`, `GL_EXT_texture_lod_bias`,
   `GL_OES_standard_derivatives`, `GL_OES_texture_[half_]float[_linear]`, `GL_IMG_texture_compression_pvrtc`, `GL_KHR_texture_compression_astc_ldr` (strings at 0x184a6a0d7..) through the
   EXTENSIONS string, and honours `CA_DISABLE_WORKAROUNDS`, `CA_MAX_TEXTURE_UNITS`, `CA_MAX_TEXTURE_SIZE`.
2. **Slot map is only partly public.** A scan of all `ldr x8,[ctx,#off]; ldr x0,[ctx]; blr x8` sites finds 49 offsets. The low ones fit the public macOS order and are what a GLES
   renderer needs first (bind_texture, clear, delete/gen_textures, disable/enable, draw_arrays, finish, get_integerv, get_string, pixel_storei, scissor, tex_parameteri/f, viewport,
   active_texture, blend_equation: offsets 0x30..0xab8). Offsets above about 0xbd0 do **not** match the macOS names (e.g. `draw_elements_base_vertex` x28, `program_env_parameter4f_ARB` x10), and
   no slot for `glTexImage2D`, `glUseProgram`, `glUniform*`, framebuffer calls shows up where the public order would put them: Apple's ES extension of the dispatch struct is ordered
   differently (shader/uniform/FBO/VAO functions). **The ES half of the slot map must be decoded from the real GLEngine's table** (the function-pointer array it copies into `disp`),
   or from the call-site argument shapes; it is not in any public header. The shim still returns a zeroed block (`getMacroContextPrivate`), so injected CA would crash on the first call.
   Plan: generate `disp[]` thunks (`fn(rend, a...)` -> `glFoo(a...)`) from `gliDispatch.h` + `CGLMacro.h` for the public part and a decoded table for the rest.
3. **`CA_ENABLE_OGL`:** the single reference (0x1848cf69c, in a CA::OGL object constructor) calls `getenv("CA_ENABLE_OGL")` once and **discards the result** (guard byte only). It does not gate GL
   at that site; no other reference exists. Other switches found: `CA_NO_ACCEL`, `CA_ACCEL_BACKING`, `CA_DISABLE_RENDER`, `CA_PRINT_SHADERS`, `CA_FORCE_GENERIC_SHADERS`, `CA_EMPTY_SHADERS`.
4. **Where the server creates its `EAGLContext` is not found.** QuartzCore has no selector reference to `initWithAPI*`/`sharegroup`, only `getMacroContextPrivate`, `attachImage:...`,
   `texImageIOSurface:...invert:`, `setCurrentContext:`, `API`, `nativeWindow`, `presentRenderbuffer:atTime:`; the renderer-selection code at 0x1849d1140..0x1849d1400 logs
   `Failed to initialize Metal or OpenGLES contexts!` and falls back to the software server. The context is probably created in another image (class refs go through the binding
   tables) or by the public `CARenderer rendererWithEAGLContext:options:` path (`_initWithEAGLContext:options:` at 0x184abdec0 is the callee used by it).

## Proposal: testing the shim under CoreAnimation without touching backboardd/SpringBoard

* **Step 1 (safe, separate process):** a test tool that creates our `EAGLContext`, builds a small CALayer tree and drives `+[CARenderer rendererWithEAGLContext:options:]`
  (`beginFrameAtTime:timeStamp:`, `addUpdateRect:`, `render`, `endFrame`) into an FBO backed by `attachImage:toCoreSurface:invertedRender:`. This exercises exactly `CA::OGL` through the macro
  context (everything in finding 1) with no render server involved, writes only to its own IOSurface, and a crash only kills the tool. Needs QuartzCore in the process
  (library load only) and the macro-context thunks from finding 2. Success criterion: the IOSurface contains the layer colours/image.
* **Step 2 (still isolated):** a tiny app/daemon with a `CAEAGLLayer` in its own `CAContext` is not useful without the live render server, so skip it; instead run a second, private render
  server only if needed (`CA_FORCE_LOCAL_SERVER` exists as a string in QuartzCore: a CA server inside the test process).
* **Step 3 (only after 1-2):** inject into backboardd by a launchd job override, not by replacing files: a copy of the `backboardd` plist in `/Library/LaunchDaemons` (or the existing
  job) with `EnvironmentVariables: DYLD_INSERT_LIBRARIES=/var/root/gpu-eagl/...` plus `DYLD_FRAMEWORK_PATH`; revert = delete the override file (and `launchctl bootout`/reboot). Fallback is
  automatic in CA (Metal -> GLES -> software), so a failing GLES init should land on the software path, but a crash loop must be assumed possible: keep an SSH session and a
  timed revert (`sleep 120; rm override; launchctl ...`) running before the first try. Do not do this until the on-device test of step 1 passes.

## Macro context and CoreAnimation step 1 (done on the phone, 2026-10-23, xnu-8796 ufsdmasync=1)

**Slot map: complete.** Every `gl*` export of the real OpenGLES.framework is a stub `mrs x8,tpidrro_el0; ldr ctx,[x8,#0xf0]` (current GLI context), then
`ldr fn,[ctx,#SLOT]` with the renderer at `[ctx,#0x20]`, argument shift, jump. QuartzCore's pointer is `ctx+0x20`, so macro offset = SLOT - 0x20 (checked against the offsets
QuartzCore uses: bind_texture 0x30, get_string 0x3b0, active_texture 0xab8, tex_parameteri 0x988 ...). `tools/dsc_slotmap.py` reads the 457 slot numbers from the cache and writes
`src/macro_slots.c` (names and numbers only). The earlier doubt about "ES half not in the public order" is resolved this way: Apple's ES functions simply sit at other offsets of
the same struct, and the stubs give them all. `src/macro_ctx.c` builds the block per context (`rend` = our private block, ~0x2200 bytes of slots), each slot a generated forwarder
`ms_glFoo` (drops `rend` by shifting x1..x7 down and tail-calls the Mesa entry); the 11 entry points with 8+ arguments (`glTexImage2D`, `glTexSubImage2D`, `glCopyTexImage2D`,
`glCopyTexSubImage2D`, `glCompressedTexSubImage2D`, the 3D variants, `glBlitFramebuffer`) have C wrappers because their arguments spill to the stack.
`eagl_test` checks it: slot 0x3b0 is glGetString, float arguments after `rend` (`glClearColor`), and a 9-argument `glTexImage2D` through the macro block.

**Injection mechanism (works in a single process).** The system OpenGLES lives in the dyld shared cache; `DYLD_FRAMEWORK_PATH` does not override it (tried: the system library
was loaded). Instead `EAGL_DEFS=-DEAGL_INJECT gpu/eagl/build.sh OUT` builds the shim with classes `BGEAGLContext`/`BGEAGLSharegroup`; its load-time constructor copies every method
(instance and class) into the REAL `EAGLContext`/`EAGLSharegroup` classes with `class_replaceMethod` (both have the single `_private` ivar). Anything that talks to those classes
(QuartzCore included) then reaches our code. The C `gl*` symbols of an app still bind to the system library (they use the thread's own TLS context, which is empty): a client of
the injected shim must reach GL through the macro context (CoreAnimation does) or through the shim's own exports (`dlsym`), as `eagl_ca_test` does.

**Step 1 result [phone].** `test/eagl_ca_test.m` (separate tool, nothing else touched): our context (ES3) + IOSurface-backed FBO (`attachImage:toCoreSurface:`), `+[CARenderer
rendererWithEAGLContext:options:]` on a layer tree (red root, green 128x128 sublayer), `beginFrame/addUpdateRect/render/endFrame`, `glFinish`. Result: `GL error 0`, IOSurface pixel (10,10) =
red and (128,128) = green, no "unmapped slot"/"not implemented" message, `RESULT: 0 failed`. So **CoreAnimation's GLES renderer (CA::OGL) runs on Mesa softpipe through this shim**, including
its extension probing (`GL_APPLE_*` strings are absent from Mesa and CA copes) and shader compilation. Run:

```
EAGL_DEFS=-DEAGL_INJECT gpu/eagl/build.sh $GPU_EAGL_WORK/out-inj      # also builds eagl_ca_test
(strip with pacstrip --sign; push eagl_ca_test, libOSMesa.8.dylib and OpenGLES.framework/OpenGLES keeping the layout; verify sha256 on the phone)
EAGL_INJECT_LIB=/var/root/gpu-eagl-inj/fw/OpenGLES.framework/OpenGLES ./eagl_ca_test
```

Operational notes: (1) delete a binary on the phone before pushing a new build of it: the kernel keeps the old code-signature limits per vnode and dyld then reports "code signature does not
cover entire file"; (2) unresolved entry points are now 14 of 457 (measured on the phone with `EAGL_SHIM_DEBUG=1`): the Apple fence set (6), `glFinishObjectAPPLE`, `glTestObjectAPPLE`,
`glResolveMultisampleFramebufferAPPLE`, `glGetFramebufferParameteriAPPLE`, and the four matrix-palette OES functions; (3) the injection build is for a process we control; backboardd injection stays
a separate, later, reversible step (launchd environment override, see the proposal above).

Not yet exercised by step 1: layers with image contents (`texImageIOSurface:`), shadows/blur/vibrancy shaders, many layers (the 560 ms/frame softpipe cost applies), `CAEAGLLayer` drawables, and the render
server's own use (`CA::WindowServer`, display-link, IOMFB swap). The remaining unknown from the static analysis is where the render server creates its `EAGLContext`.

## CARenderer scenes: results and frame times (256x256 target, softpipe, one SDM845 core; phone, 2026-10-23)

`test/eagl_ca_test.m` renders six scenes through real CA::OGL (separate tool). Checked on the phone with the build before the last two shim changes below:

| scene | result | ms/frame (3-5 frames, noisy) |
|---|---|---|
| 2 solid layers | red + green correct | 50-80 |
| CGImage layer (CA converts it to an IOSurface and calls `texImageIOSurface:...invert:`) | drawn, see orientation below | 31-40 |
| IOSurface as `layer.contents` | drawn | 30 |
| shadow (radius 12) | darkens the neighbourhood, far background untouched | 37-80 |
| `CAFilter gaussianBlur` backgroundFilter (radius 8, 192x192) | blurs the checker edge | 170-240 |
| `CAFilter colorSaturate 0` | desaturates | 260-450 |
| 300 translucent layers, half with corner radius | drawn | 320-540 |

Per-layer cost is a few ms, blur/saturate filters 200-400 ms at 256x256 (full-screen 750x1334 would be about 13x the pixels): softpipe is far from interactive; the numbers are the baseline for phase E.

Findings that changed the shim:
* **Orientation contract.** CA renders with a vertically flipped projection when it calls `attachImage:toCoreSurface:invertedRender:YES`, so the GL framebuffer rows already are the surface rows: the sync must copy WITHOUT flipping for `inverted=YES` (that is what the shim does) and flip for NO. The test therefore passes YES (with NO the whole scene came out mirrored).
* **Texture uploads.** CA calls `texImageIOSurface:...plane:invert:` with `invert:NO` while rendering inverted, and the pictures came out upside down with a plain row copy: the private variant now flips on upload when `invert` is NO (and not when YES); the public variant without `invert` keeps the rows as stored. **These two changes are built and the unit test is updated, but NOT yet run on the phone** (the phone went to fastboot for the xnu-11215 storage test right after the build; no files were left half-pushed: the push script failed at its first SSH command, before any copy). Expected on the next run: `eagl_test` 41 checks pass, `eagl_ca_test` image/IOSurface scenes pass with top green/bottom blue and top red/bottom green.
* Tracing aids added: `EAGL_TRACE=1` (macro-slot calls logged through trace thunks; `EAGLShimSetTrace(1)` toggles printing, `EAGL_TRACE_SHADERS=1` prints shader sources), `EAGL_DUMP=/dir` in `eagl_ca_test` writes each scene as PPM. Shader seen so far: CA's textured fragment shader is plain `texture2D(texture0, texcoord0_0)`; programs are compiled lazily per layer type.
* `texImageIOSurface` now sets complete default texture parameters (LINEAR, CLAMP_TO_EDGE); CA overrides them right after the call.
* Operational: the kernel caches code signatures per vnode, so always `rm` a binary on the phone before pushing a new build (the push scripts do).

## Plan for the backboardd experiment (NOT executed; needs the user's approval)

Goal: let the live render server (backboardd, which draws SpringBoard) load the injected shim, so CoreAnimation's GLES path runs on Mesa. Nothing below has been done.

1. **Files written on the phone** (all new, nothing existing edited or replaced):
   * `/var/root/gpu-eagl-inj/fw/OpenGLES.framework/OpenGLES` and `/var/root/gpu-eagl-inj/fw/libOSMesa.8.dylib` (pacstrip'd, ad-hoc signed, sha256-verified; already the layout used by the tests);
   * `/var/root/gpu-eagl-inj/revert.sh` (the undo, below);
   * the launchd override: a copy of the backboardd job plist with `EnvironmentVariables: DYLD_INSERT_LIBRARIES=/var/root/gpu-eagl-inj/fw/OpenGLES.framework/OpenGLES` (exact file/mechanism depends on how this image launches backboardd: the original plist stays untouched and its sha256 is recorded first; if the only way is editing the original, a `.orig` copy is made before and `revert.sh` copies it back).
2. **What must hold before the first try:** the CoreAnimation scenes above pass on the phone with the flip fixes; an SSH session stays open; the kernel is the stable one (xnu-8796, ufsdmasync=1) and the user has said when the phone can be used.
3. **Auto-revert (dead-man switch):** before touching launchd, start on the phone a detached `sh -c 'sleep 180; /var/root/gpu-eagl-inj/revert.sh'` (nohup, survives the SSH session; cancelled by killing it once the experiment is judged good). `revert.sh` removes the override (or restores the `.orig`), then restarts backboardd (`launchctl kickstart -k` / kill, which launchd respawns) so the next start has no injection. If backboardd crash-loops, the switch still fires; if the whole phone hangs, a power-cycle boots with the override still present, so the override is designed to be useless after a reboot unless re-armed: `DYLD_INSERT_LIBRARIES` points into `/var/root/gpu-eagl-inj` and `revert.sh` is also run once from `/etc` rc-style start? (to be decided with the coordinator; the safest variant is that the override file lives in `/tmp`-like volatile storage or carries a boot-id check so a reboot ignores it).
4. **What the user will see:** at the moment of the restart the screen goes black/blank for a few seconds while backboardd and SpringBoard restart (same as a respring). Then either (a) the normal UI, drawn by softpipe: slow (hundreds of ms per frame, so visibly laggy animations), or (b) a black/frozen screen or a respring loop if CA's GLES path misbehaves; then after at most 3 minutes the dead-man switch restarts backboardd without injection and the software renderer UI returns. SSH is expected to keep working throughout (backboardd is not on the SSH path).
5. **Undo by hand:** `ssh root@192.168.7.2 /var/root/gpu-eagl-inj/revert.sh` (or: delete the override plist / restore `<plist>.orig`, then `killall backboardd`); full cleanup: `rm -rf /var/root/gpu-eagl-inj`. If SSH is unavailable, a normal reboot loads the unmodified system (see item 3 for the volatile-override design).
6. **Success criteria / data collected:** backboardd log lines with `EAGL(shim)` messages (`EAGL_SHIM_DEBUG=1` in the override), whether `Failed to initialize Metal or OpenGLES contexts!` disappears, whether the display shows content, frame time from the swap path. Abort criteria: respring loop, panic, or SSH loss.
