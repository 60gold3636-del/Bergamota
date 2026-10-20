/*
 * Render the console and the branded boot screen on the host:
 *   ./out/host_test   ->  out/host.ppm (text console), out/preview/ (boot screen stages)
 */
#include <stdio.h>
#include "bootui.h"
#include "console.h"

static uint32_t host_fb[FB_H * FB_STRIDE / 4];

static void dump(const char *path)
{
	FILE *f = fopen(path, "wb");
	if (!f)
		return;
	fprintf(f, "P6 %d %d 255\n", FB_W, FB_H);
	for (int i = 0; i < FB_W * FB_H; i++) {
		unsigned char px[3] = { host_fb[i] >> 16, host_fb[i] >> 8, host_fb[i] };
		fwrite(px, 1, 3, f);
	}
	fclose(f);
}

int main(void)
{
	con_fb = host_fb;
	con_clear(BG_BOOT);
	con_str("SHIM", "sweet milestone 2");
	con_hex("MMFR0", 0x0000000000101122ULL);
	con_hex2("PSCI", "ver=", 0x10001, "smccc=", 0x10002);
	con_hex2("CPU7", "ret=", 0, "mpidr=", 0x81000700);
	dump("out/host.ppm");

	/* Boot screen as loader.c drives it (same strings, stages and log lines). */
	bootui_init();
	bootui_progress(40, "INITRD FOUND");
	con_hex2("INITRD", "lo=", 0x85400000, "hi=", 0x86100000);
	dump("out/preview/boot-0-initrd.ppm");
	con_hex2("PHYS", "base=", 0x80000000, "size=", 0x80000000);
	con_hex("VIRT", 0xfffffff007004000ULL);
	con_hex("ENTRY", 0xfffffff007b14c28ULL);
	bootui_progress(70, "PAYLOAD OK");
	con_hex2("MMU", "rc=", 0, "l3=", 3);
	bootui_progress(100, "MMU ON");
	con_hex2("INFLATE", "in=", 0x2400000, "out=", 0x5a00000);
	bootui_mib("INFLATE", 0, 311, 100, 900);
	bootui_mib("INFLATE", 140, 311, 100, 900);
	dump("out/preview/boot-1-inflate-45pct.ppm");
	bootui_mib("INFLATE", 311, 311, 100, 900);
	bootui_progress(920, "SEGMENTS READY");
	con_hex2("SEGS", "n=", 4, "end=", 0x8a000000);
	bootui_progress(960, "BOOT ARGS");
	con_hex2("BOOTARG", "pa=", 0x8a400000, "top=", 0x8a404000);
	bootui_progress(1000, "STARTING IOS");
	con_hex("JUMP", 0x80f14c28ULL);
	con_str("XNU", "jumping (fbcon clears screen)");
	dump("out/preview/boot-2-jump.ppm");

	/* Failure on the boot screen, then the text fallback / panic screens. */
	bootui_init();
	bootui_progress(100, "MMU ON");
	con_hex2("INFLATE", "rc=", (uint32_t)-3, "got=", 0x1234);
	bootui_fail("inflate failed");
	dump("out/preview/boot-3-fail.ppm");

	con_clear(BG_PANIC);
	con_str("PANIC", "sync exception");
	con_hex("ESR", 0x96000010);
	dump("out/preview/panic.ppm");
	return 0;
}
