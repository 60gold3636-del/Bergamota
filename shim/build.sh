#!/bin/bash
# Build the shim and wrap it in an Android boot.img that ABL accepts.
#   BOARD=sweet (default)  boot.img v2 mirroring the stock PixelOS header, DTB in the header
#   BOARD=beryllium        boot.img v1, Image.gz + appended DTB like the Poco F1 ROM (SDM845 ABL)
# Usage: [BOARD=..] [DTB=..] ./build.sh [payload.bin]
set -euo pipefail
cd "$(dirname "$0")"
BOARD=${BOARD:-sweet}
# Linux cross toolchain if present, else the bare-metal one (Homebrew aarch64-elf-gcc on macOS)
if [ -z "${CROSS:-}" ]; then
	if command -v aarch64-linux-gnu-gcc >/dev/null; then CROSS=aarch64-linux-gnu-; else CROSS=aarch64-elf-; fi
fi
CC=${CROSS}gcc
OBJCOPY=${CROSS}objcopy
READELF=${CROSS}readelf
NM=${CROSS}nm
# BOOTLOG=1 shows the log window at the bottom of the branded boot screen (default: logo only; the
# log is recorded and printed on the text screen when the boot fails).
CFLAGS="-O2 -ffreestanding -nostdlib -fno-pic -mgeneral-regs-only -mstrict-align -fno-stack-protector -Wall -Wextra"
[ "${BOOTLOG:-0}" = 0 ] || CFLAGS="$CFLAGS -DBOOTUI_LOG=1"
case $BOARD in
sweet)		DTB=${DTB:-../dtb/boot_unpacked/dtb} ;;
beryllium)	DTB=${DTB:-../dtb/beryllium/dtb}; CFLAGS="$CFLAGS -DBOARD_BERYLLIUM" ;;
*)		echo "error: unknown BOARD=$BOARD" >&2; exit 1 ;;
esac
[ -f "$DTB" ] || { echo "error: $DTB missing (stock DTB of the phone, see README)" >&2; exit 1; }
mkdir -p out
for f in start.S shim.c console.c bootui.c mmu.c fdt.c loader.c ufs.c inflate.c; do
	$CC $CFLAGS -c $f -o out/${f%.*}.o
done
# The image runs wherever ABL puts it with no relocation pass: only the
# header's image_size (start.o, linked at 0) may be an absolute address.
abs=$($READELF -r out/shim.o out/console.o out/bootui.o out/mmu.o out/fdt.o out/loader.o out/ufs.o out/inflate.o | grep -c ABS64 || true)
[ "$abs" = 0 ] || { echo "error: $abs absolute relocations in C objects" >&2; exit 1; }
$CC $CFLAGS -static -T shim.ld -Wl,--build-id=none -Wl,--no-warn-rwx-segments -Wl,-N \
	out/start.o out/shim.o out/console.o out/bootui.o out/mmu.o out/fdt.o out/loader.o out/ufs.o out/inflate.o -o out/shim.elf -lgcc
$OBJCOPY -O binary out/shim.elf out/Image
# ABL copies the file; pad to image_size so .bss/stacks exist as zeroed bytes.
size=$($NM out/shim.elf | awk '$3=="_end"{print $1}')
python3 -c "import sys; open(sys.argv[1],'r+b').truncate(int(sys.argv[2],16))" out/Image "$size"
# Ramdisk: an xnu payload (tools/mkpayload.py) if given as $1, else an empty
# newc cpio (ABL dislikes a zero-size ramdisk on some builds) -> diagnostics.
if [ -n "${1:-}" ]; then
	cp "$1" out/ramdisk.bin
else
	(cd out && rm -rf rd && mkdir rd && cd rd && find . | cpio -o -H newc --quiet | gzip -9 > ../ramdisk.bin)
fi
if [ "$BOARD" = beryllium ]; then
	# Same layout as the ROM's boot.img: header v1, Image.gz with the DTB
	# appended (ABL gunzips the kernel and finds the DTB behind the stream).
	gzip -9 -n -c out/Image | cat - "$DTB" > out/Image.gz-dtb
	mkbootimg --header_version 1 --kernel out/Image.gz-dtb --ramdisk out/ramdisk.bin \
		--base 0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000 \
		--tags_offset 0x100 --pagesize 4096 --os_version 16.0.0 --os_patch_level 2025-06 \
		--cmdline "console=null" -o out/shim-boot.img
else
	mkbootimg --header_version 2 --kernel out/Image --ramdisk out/ramdisk.bin \
		--dtb "$DTB" --base 0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000 \
		--tags_offset 0x100 --dtb_offset 0x1f00000 --pagesize 4096 \
		--os_version 17.0.0 --os_patch_level 2035-06 \
		--cmdline "console=null" -o out/shim-boot.img
fi
# Host render of the console layout and the boot screen (out/host.ppm, out/preview/*.ppm).
mkdir -p out/preview
cc -O1 -Wall $([ "$BOARD" = beryllium ] && echo -DBOARD_BERYLLIUM) $([ "${BOOTLOG:-0}" = 0 ] || echo -DBOOTUI_LOG=1) -o out/host_test console.c bootui.c host_test.c && ./out/host_test
ls -l out/Image out/shim-boot.img
