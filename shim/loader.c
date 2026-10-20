/*
 * Milestone 4: act as iBoot for xnu.
 *
 * mkpayload.py already resolved the kernel's chained fixups and built the
 * ADT, so this only has to: find the payload in the ABL ramdisk, copy the
 * segments to phys_base + (vmaddr - virt_base), place the ADT and
 * boot_args behind the kernel, and jump to the entry point with the MMU
 * and caches off, x0 = boot_args (physical).
 *
 * The copy/inflate runs with the MMU and D-cache on (payload, kernel
 * destination and our image write-back, everything else Device as before):
 * the bit-at-a-time inflater was ~10 MiB/min on uncached Device memory.
 * mmu_off_jump cleans it all to memory before xnu starts.
 */
#include <stdint.h>
#include "console.h"
#include "fdt.h"
#include "inflate.h"
#include "loader.h"
#include "mmu.h"

#define BOOT_LINE_LENGTH	608
#define PAGE_16K		0x4000UL

/*
 * version 1: 4 u64 per segment. version 2 (mkpayload.py --compress): a fifth u64, raw_size; when it is not 0 the
 * segment is raw DEFLATE data of file_size bytes that inflates to raw_size bytes (docs/IOS18_PORT.md section 11:
 * ABL places the boot.img ramdisk just below 0x85600000, so the payload must stay small).
 */
struct payload_seg {
	uint64_t vmaddr, vmsize, file_off, file_size;
	uint64_t raw_size;	/* version 2 only */
};

struct payload {
	char magic[8];
	uint32_t version, nsegs;
	uint64_t virt_base, entry_va, adt_off, adt_size, kernel_end;
	uint64_t phys_base, mem_size;
	char cmdline[BOOT_LINE_LENGTH];
	uint8_t segs[];		/* nsegs x (32 bytes v1, 40 bytes v2) */
};

/* pexpert/pexpert/arm64/boot.h, Revision/Version 2 */
struct boot_video {
	uint64_t v_baseAddr, v_display, v_rowBytes, v_width, v_height, v_depth;
};

struct boot_args {
	uint16_t Revision, Version;
	uint64_t virtBase, physBase, memSize, topOfKernelData;
	struct boot_video Video;
	uint32_t machineType;
	uint64_t deviceTreeP;
	uint32_t deviceTreeLength;
	char CommandLine[BOOT_LINE_LENGTH];
	uint64_t bootFlags, memSizeActual;
};

_Static_assert(__builtin_offsetof(struct payload, segs) == 0x2a8, "payload header layout");
_Static_assert(sizeof(struct payload_seg) == 40, "payload segment layout");
_Static_assert(__builtin_offsetof(struct boot_args, Video) == 40, "boot_args layout");
_Static_assert(__builtin_offsetof(struct boot_args, CommandLine) == 108, "boot_args layout");
_Static_assert(sizeof(struct boot_args) == 736, "boot_args layout");

/* MMU off: everything is Device memory, so copy in aligned 8-byte words. */
static void copy64(uintptr_t dst, uintptr_t src, uint64_t n)
{
	volatile uint64_t *d = (volatile uint64_t *)dst;
	volatile const uint64_t *s = (volatile const uint64_t *)src;
	for (uint64_t i = 0; i < (n + 7) / 8; i++)
		d[i] = s[i];
}

static void zero64(uintptr_t dst, uint64_t n)
{
	volatile uint64_t *d = (volatile uint64_t *)dst;
	for (uint64_t i = 0; i < n / 8; i++)
		d[i] = 0;
}

static int magic_ok(const char *m)
{
	static const char want[] = "SWEETXNU";
	for (int i = 0; i < 8; i++)
		if (m[i] != want[i])
			return 0;
	return 1;
}

static void inflate_progress(uint64_t done)
{
	static unsigned calls;
	if (++calls % 4 == 0)
		con_hex2("INFLATE", "MiB=", (uint32_t)(done >> 20), 0, 0);
}

const char *loader_boot(uintptr_t dtb)
{
	uint64_t rd_start, rd_end;

	if (!fdt_chosen_u64(dtb, "linux,initrd-start", &rd_start) ||
	    !fdt_chosen_u64(dtb, "linux,initrd-end", &rd_end))
		return "no initrd in /chosen";
	con_hex2("INITRD", "lo=", rd_start, "hi=", rd_end);

	const struct payload *p = (const struct payload *)rd_start;
	if (!magic_ok(p->magic))
		return "no SWEETXNU payload";
	if ((p->version != 1 && p->version != 2) || (p->adt_off & 7) || (rd_start & 7))
		return "bad payload header";
	const unsigned stride = p->version == 2 ? 40 : 32;

	uint64_t pa_of_va_base = p->phys_base - p->virt_base;	/* pa = va + this */
	con_hex2("PHYS", "base=", p->phys_base, "size=", p->mem_size);
	con_hex("VIRT", p->virt_base);
	con_hex("ENTRY", p->entry_va);

	/* The payload must not overlap where the kernel goes. */
	if (rd_end > p->phys_base && rd_start < p->phys_base + p->mem_size)
		return "ramdisk overlaps kernel memory";

	/* Kernel destination through boot_args (see below), and the payload: cacheable while we work. */
	uint64_t kend_pa = p->kernel_end + pa_of_va_base;
	uint64_t top_pa = ((kend_pa + p->adt_size + PAGE_16K - 1) & ~(PAGE_16K - 1)) + PAGE_16K;
	struct mmu_range wb[3] = {
		{ p->phys_base, top_pa },
		{ rd_start, rd_end },
		{ 0, 0 },	/* the image: filled in from mmu_info */
	};
	struct mmu_info mi;
	int mmu_rc = mmu_enable_ranges(&mi, wb, 2);
	con_hex2("MMU", "rc=", (uint32_t)mmu_rc, "l3=", (uint32_t)mi.n_l3);
	wb[2] = (struct mmu_range){ mi.img_lo, mi.img_hi };

	for (uint32_t i = 0; i < p->nsegs; i++) {
		const struct payload_seg *s = (const struct payload_seg *)(p->segs + (uint64_t)i * stride);
		uintptr_t dst = s->vmaddr + pa_of_va_base;
		uint64_t raw = s->file_size;
		if (p->version == 2 && s->raw_size) {
			uint64_t cap = s->vmsize;
			con_hex2("INFLATE", "in=", (uint32_t)s->file_size, "out=", (uint32_t)s->raw_size);
			int rc = inflate_raw((const uint8_t *)(rd_start + s->file_off), s->file_size,
					     (volatile uint8_t *)dst, &cap, inflate_progress);
			if (rc || cap != s->raw_size) {
				con_hex2("INFLATE", "rc=", (uint32_t)rc, "got=", (uint32_t)cap);
				return "inflate failed";
			}
			raw = cap;
		} else {
			copy64(dst, rd_start + s->file_off, s->file_size);
		}
		if (s->vmsize > raw)
			zero64(dst + ((raw + 7) & ~7UL), s->vmsize - ((raw + 7) & ~7UL));
	}
	con_hex2("SEGS", "n=", p->nsegs, "end=", p->kernel_end + pa_of_va_base);

	/* ADT, then boot_args, behind the kernel; everything below topOfKernelData is ours. */
	uintptr_t adt_pa = p->kernel_end + pa_of_va_base;
	copy64(adt_pa, rd_start + p->adt_off, p->adt_size);
	uintptr_t ba_pa = (adt_pa + p->adt_size + PAGE_16K - 1) & ~(PAGE_16K - 1);
	uintptr_t top = ba_pa + PAGE_16K;
	if (top != top_pa)
		return "boot_args placement mismatch";

	zero64(ba_pa, PAGE_16K);
	volatile struct boot_args *ba = (volatile struct boot_args *)ba_pa;
	ba->Revision = 2;
	ba->Version = 2;
	ba->virtBase = p->virt_base;
	ba->physBase = p->phys_base;
	ba->memSize = p->mem_size;
	ba->topOfKernelData = top;
	ba->Video.v_baseAddr = FB_BASE;
	ba->Video.v_display = 1;
	ba->Video.v_rowBytes = FB_STRIDE;
	ba->Video.v_width = FB_W;
	ba->Video.v_height = FB_H;
	ba->Video.v_depth = 32;
	ba->deviceTreeP = adt_pa - pa_of_va_base;	/* xnu reads it with the MMU on: a VA */
	ba->deviceTreeLength = (uint32_t)p->adt_size;
	for (int i = 0; i < BOOT_LINE_LENGTH; i++)
		ba->CommandLine[i] = p->cmdline[i];
	ba->memSizeActual = p->mem_size;
	con_hex2("BOOTARG", "pa=", ba_pa, "top=", top);

	uintptr_t entry_pa = p->entry_va + pa_of_va_base;
	con_hex("JUMP", entry_pa);
	con_str("XNU", "jumping (fbcon clears screen)");

	/* Clean to memory, MMU and caches off, invalidate, jump (also right when mmu_rc failed). */
	mmu_off_jump(entry_pa, ba_pa, wb);
}
