#!/bin/bash
# SPDX-License-Identifier: MIT
# Cross-build Mesa 25.0.7 (official release tag, no third-party code) for iOS arm64e: OSMesa frontend + gallium softpipe,
# GLES1/GLES2/GLES3 contexts through our one-hunk osmesa.c patch. No LLVM, no X11/Wayland/GBM/EGL/GLX.
#   GPU_EAGL_WORK=/some/scratch/dir gpu/eagl/mesa/build-mesa.sh      (needs ~1.6 GB; Xcode with the iphoneos SDK;
#                                                                     brew install meson bison; python mako/pyyaml in a venv)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${GPU_EAGL_WORK:?set GPU_EAGL_WORK}"
TAG="${MESA_TAG:-mesa-25.0.7}"
ARCH="${ARCH:-arm64e}"
mkdir -p "$WORK"; cd "$WORK"
if [ ! -d venv ]; then
  python3 -m venv venv
  ./venv/bin/pip -q install mako pyyaml packaging setuptools meson
fi
export PATH="$WORK/venv/bin:$PATH"
if [ ! -d mesa ]; then
  git clone -q --depth 1 --branch "$TAG" https://gitlab.freedesktop.org/mesa/mesa.git mesa
  git -C mesa apply "$HERE/0001-osmesa-es-profile.patch"
fi
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
BISON="$(brew --prefix bison)/bin/bison"
CROSS="$WORK/ios-$ARCH.cross"
cat > "$CROSS" <<EOT
[binaries]
c = ['xcrun','--sdk','iphoneos','clang','-arch','$ARCH']
cpp = ['xcrun','--sdk','iphoneos','clang++','-arch','$ARCH']
objc = ['xcrun','--sdk','iphoneos','clang','-arch','$ARCH']
ar = ['xcrun','--sdk','iphoneos','ar']
strip = ['xcrun','--sdk','iphoneos','strip']
ranlib = ['xcrun','--sdk','iphoneos','ranlib']
bison = '$BISON'

[built-in options]
c_args = ['-miphoneos-version-min=18.0','-isysroot','$SDK']
cpp_args = ['-miphoneos-version-min=18.0','-isysroot','$SDK']
c_link_args = ['-miphoneos-version-min=18.0','-isysroot','$SDK']
cpp_link_args = ['-miphoneos-version-min=18.0','-isysroot','$SDK']

[host_machine]
system = 'darwin'
subsystem = 'ios'
cpu_family = 'aarch64'
cpu = '$ARCH'
endian = 'little'

[properties]
needs_exe_wrapper = true
EOT
BLD="$WORK/build-${ARCH/arm64e/a64e}"
if [ ! -d "$BLD" ]; then
  (cd mesa && meson setup "$BLD" --cross-file "$CROSS" --buildtype=release \
    -Dgallium-drivers=softpipe -Dvulkan-drivers= -Dllvm=disabled \
    -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dplatforms= \
    -Dosmesa=true -Dopengl=true -Dgles1=enabled -Dgles2=enabled -Dshared-glapi=enabled \
    -Dvalgrind=disabled -Dlibunwind=disabled -Dzstd=disabled -Dxmlconfig=disabled -Dbuild-tests=false \
    -Dglvnd=disabled -Dlmsensors=disabled -Dgallium-opencl=disabled -Dgallium-rusticl=false \
    -Dshader-cache=disabled -Dprefix=/)
fi
ninja -C "$BLD"
ls -l "$BLD/src/gallium/targets/osmesa/libOSMesa.8.dylib"
