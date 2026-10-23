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

`gpu/eagl/test/eagl_test.m` links the shim by path and runs 34 checks (exit status = failures; `--bench`, `--dump FILE.ppm`):

* ES2 and ES3 contexts: create, make current, FBO + `renderbufferStorage:fromDrawable:` (fake `CAEAGLLayer` stand-in), shader compile/link (GLSL ES 1.00 and 3.00),
  clear + triangle, `presentRenderbuffer:` delivers a 128x128 BGRA IOSurface; apex pixel red at the **top**, below the triangle blue, corner blue (orientation, swizzle, alpha).
* `attachImage:toCoreSurface:invertedRender:` + `glFinish` fills the IOSurface top-down; `texImageIOSurface:` (BGRA to RGBA, `invert:YES` flips); sharegroup visibility
  of textures (shared and unrelated context); ES1 context + fixed-function call.

**[phone, 2026-10-23]** `RESULT: 34 passed, 0 failed`; GL_VERSION `OpenGL ES 3.1 Mesa 25.0.7`, GL_RENDERER `softpipe`; IOSurface creation/locking works from an arm64e tool. Rendered frame
checked visually (red triangle on blue). Speed on one SDM845 core: 128x128 triangle + readback + present about 1 ms/frame; **750x1334 full-screen textured quad + present
about 560 ms/frame** (softpipe is a reference rasteriser: usable for correctness, not for compositing a UI; that is what phase E is for).

## What is NOT done / known gaps

0. The phone test ran once (two pushes of about 14 MB to `/var/root/gpu-eagl/`) before the coordinator paused phone writes (xnu-11215 hangs and corrupts userdata). Treat that directory as untrusted and delete it when the phone is usable again; no further device tests were done.

1. **Not injected anywhere.** The system framework is unchanged; QuartzCore/backboardd still use their own (Metal-backed, no device) OpenGLES. Whether QuartzCore's GLES renderer is
   enabled without `CA_ENABLE_OGL` on 22H352 is still unverified (see `METAL_ADRENO630.md` b3).
2. **`getMacroContextPrivate` returns a zeroed 256-byte block.** Apple's `EAGLMacroContext` is the GL "macro" context (dispatch table pointers used by inlined GL calls). If
   CoreAnimation calls GL through it instead of the `gl*` exports, that structure must be reverse engineered from `GLEngine`/QuartzCore callers (next analysis step before injection).
3. `attachImage:` takes a GL object name (`Q`): the shim guesses renderbuffer vs texture with `glIsTexture/glIsRenderbuffer`; the real semantics (e.g. mipmap level, MSAA) are unverified.
4. ES2 contexts report GL_VERSION ES 3.1 (Mesa gives the highest); Apple reports 2.0 for ES2 contexts. `MESA_GLES_VERSION_OVERRIDE` could cap it per process.
5. Not implemented (forward to a logging stub): Apple fence extension (`glGenFencesAPPLE`, `glSetFenceAPPLE`, ...), `glResolveMultisampleFramebufferAPPLE`, matrix-palette OES
   (`glCurrentPaletteMatrixOES`, ...), `glFinishObjectAPPLE`/`glTestObjectAPPLE`. The exact list is printed with `EAGL_SHIM_DEBUG=1` ([phone] run pending, phone went offline).
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
