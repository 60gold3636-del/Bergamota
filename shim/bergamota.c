/*
 * Bergamota fastboot glue: wires the protocol core (fastboot.c) to the polled
 * DWC3 driver (usb_dwc3.c), the text console, the loader and the reset
 * machinery. MMU stays off for the whole fastboot phase (all memory is Device,
 * DMA needs no cache maintenance); the cached MMU only comes up inside
 * loader_boot_payload, after usb_dwc3_stop().
 *
 * No static tables of pointers anywhere in this file (build.sh rejects ABS64
 * relocations): the transport/platform structs are filled in at run time.
 */
#include <stdint.h>
#include "board.h"
#include "bergamota.h"
#include "bootui.h"
#include "console.h"
#include "fastboot.h"
#include "fdt.h"
#include "loader.h"
#include "usb_dwc3.h"

/*
 * Download window. Derived from the live DT (dtb/beryllium/live.dts) and tools/mkadt.py:
 * every fixed carve-out ends below 0xb0400000 and the ADT's own pools are validated inside
 * 0x9f800000..0xfd000000 (mkadt.py LOWPOOL_MIN/MAX); the kernel payloads put phys_base at
 * 0x100000000 with mem_size 0xfcc00000 (whole upper DDR bank), so the buffer must live in the
 * low bank. 0xb8000000 + 1 GiB = 0xf8000000 keeps clear of ramoops/ramdump (<= 0xb0400000) and
 * of the ABL scratch area near the top of 4 GiB (its USB event buffer was at 0xfdfc8000).
 * It overlaps xnu's default zero-copy low pool (0xb0400000 + 252 MiB), which xnu only touches
 * after the buffer is dead (the loader has copied everything out by then).
 */
#define DL_BASE		0xb8000000UL
#define DL_SIZE		0x40000000UL	/* 1 GiB */
#define DL_MIN		0x04000000UL	/* refuse to run with less than 64 MiB */

#define RESTART_BOOTLOADER	0x77665500U
#define RESTART_REBOOT		0x77665501U
#define PSCI_SYSTEM_RESET	0x84000009UL

_Static_assert(USB_LINK_LOST == FB_LINK_LOST, "transport codes");

#define rsr(r) ({ uint64_t _v; __asm__ volatile("mrs %0, " r : "=r"(_v)); _v; })

extern char _head[], _end[];

static uint64_t ms_now(void)
{
	uint64_t t, f;
	__asm__ volatile("isb; mrs %0, cntpct_el0" : "=r"(t) : : "memory");
	f = rsr("cntfrq_el0");
	return t / (f / 1000);
}

static void delay_ms(unsigned ms)
{
	uint64_t end = ms_now() + ms;
	while (ms_now() < end)
		;
}

static uint32_t be32(uintptr_t a)
{
	return __builtin_bswap32(*(volatile uint32_t *)a);
}

/* ---- boot.img cmdline options ---- */

static int starts(const char *s, const char *p)
{
	while (*p && *s == *p)
		s++, p++;
	return !*p;
}

/* Value of "key=" as a whole word of /chosen bootargs, or 0. */
static const char *cmdline_opt(uintptr_t dtb, const char *key)
{
	uint32_t len = 0;
	const char *a = (const char *)fdt_chosen_prop(dtb, "bootargs", &len);

	if (!a)
		return 0;
	for (uint32_t i = 0; i < len && a[i]; i++)
		if ((i == 0 || a[i - 1] == ' ') && starts(a + i, key)) {
			const char *v = a + i;
			while (*key++)
				v++;
			return v;
		}
	return 0;
}

int bergamota_wanted(uintptr_t dtb)
{
	const char *v = cmdline_opt(dtb, "bergamota.fastboot=");

	if (v)
		return *v == '1';
	return !loader_has_payload(dtb);
}

/* ---- reset ---- */

static uint64_t smc(uint64_t fn)
{
	register uint64_t x0 __asm__("x0") = fn;
	register uint64_t x1 __asm__("x1") = 0;
	register uint64_t x2 __asm__("x2") = 0;
	register uint64_t x3 __asm__("x3") = 0;
	__asm__ volatile("smc #0" : "+r"(x0), "+r"(x1), "+r"(x2), "+r"(x3) : : "x4", "x5", "x6", "x7", "x8",
			 "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17", "memory");
	return x0;
}

/* Like shim.c reset(): IMEM restart reason, PSCI SYSTEM_RESET, PS_HOLD as the fallback. */
static void __attribute__((noreturn)) hw_reset(uint32_t reason)
{
	usb_dwc3_stop();
	*(volatile uint32_t *)IMEM_RESTART_REASON = reason;
	__asm__ volatile("dsb sy" ::: "memory");
	smc(PSCI_SYSTEM_RESET);
	*(volatile uint32_t *)PSHOLD = 0;
	for (;;)
		__asm__ volatile("wfe");
}

/* ---- screen ---- */

static struct fb *g_fb;
static uint64_t ui_last_ms, ui_sig;
static unsigned ui_draws;

/* no lookup table of string pointers (ABS64 relocations): keep this a real switch */
__attribute__((optimize("no-tree-switch-conversion")))
static const char *usb_state_str(enum usb_state s)
{
	switch (s) {
	case USB_ST_DOWN: return "down";
	case USB_ST_RUNNING: return "up, no host yet (plug in the Mac)";
	case USB_ST_RESET: return "bus reset, enumerating";
	case USB_ST_ADDRESSED: return "addressed";
	case USB_ST_CONFIGURED: return "CONFIGURED: fastboot ready";
	}
	return "?";
}

static uint32_t le32p(const uint8_t *p)
{
	return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static uint64_t buf_base, buf_size;

static void ui_draw(void)
{
	struct usb_dwc3_info *u = &usb_info;
	struct fb *fb = g_fb;

	con_clear(BG_BOOT);
	con_set_scale(2);
	con_str("SHIM", "Bergamota fastboot " BOARD_NAME);
	con_skip();
	con_str("USB", usb_state_str(usb_dwc3_state()));
	con_hex2("BUFFER", "base=", (uint32_t)buf_base, "MiB=", (uint32_t)(buf_size >> 20));
	if (fb) {
		con_skip();
		con_str("CMD", fb->last_cmd);
		con_str("REPLY", fb->last_resp);
		if (fb->dl_want)
			con_hex2("DOWNLOAD", "MiB=", (uint32_t)(fb->dl_got >> 20), "of=", (uint32_t)(fb->dl_want >> 20));
		else
			con_hex2("IMAGE", "bytes=", (uint32_t)fb->dl_len, "cmds=", fb->n_cmds);
	}
	con_skip();
	con_hex2("EVENTS", "n=", u->events, "resets=", u->resets);
	con_hex2("SETUP", "n=", u->setups, "last=", le32p(u->last_setup));
	con_hex2("DWC3", "id=", u->gsnpsid, "dsts=", u->dsts);
	con_hex2("GCTL", "abl=", u->gctl_abl, "now=", u->gctl_now);
	con_hex2("QUSB2", "pwr=", u->qusb_pwr_before << 8 | u->qusb_pwr_after, "pll=", u->qusb_pll_after);
	con_hex2("SMMU", "rc=", (uint32_t)u->smmu_rc, "smr=", u->smmu_info);
	con_skip();
	con_str("HOLD", "Power+VolDown = back to ABL fastboot");
	ui_draws++;
}

/* Cheap enough to call from every wait loop: redraws at most every 500 ms and only after a change. */
static void ui_tick(void)
{
	uint64_t t = ms_now();
	if (t - ui_last_ms < 500)
		return;
	struct fb *fb = g_fb;
	uint64_t sig = usb_info.change * 0x9e3779b1u + (fb ? fb->n_cmds * 131u + (fb->dl_got >> 20) + fb->n_links * 7u : 0);
	ui_last_ms = t;
	if (sig == ui_sig && ui_draws)
		return;
	ui_sig = sig;
	ui_draw();
}

/* ---- transport + platform callbacks ---- */

static int t_recv_cmd(void *ctx, char *buf, unsigned max)
{
	(void)ctx;
	return usb_dwc3_cmd_poll(buf, max);
}

static int t_send(void *ctx, const char *buf, unsigned len)
{
	(void)ctx;
	return usb_dwc3_bulk_in(buf, len);
}

static void usb_idle(void)
{
	ui_tick();
}

static int t_recv_data(void *ctx, uint8_t *dst, uint64_t len)
{
	(void)ctx;
	return usb_dwc3_bulk_out(dst, len, usb_idle);
}

static void p_idle(void *ctx, struct fb *fb)
{
	(void)ctx;
	(void)fb;
	ui_tick();
}

/* [off, off + size) of the SWEETXNU payload inside the download, or a reason. */
static const char *payload_range(const uint8_t *img, uint64_t len, uintptr_t *lo, uintptr_t *hi)
{
	uint64_t off = 0, size = 0;
	const char *why = "bad image";

	if (!fb_find_payload(img, len, &off, &size, &why))
		return why;
	*lo = (uintptr_t)img + off;
	*hi = *lo + size;
	return 0;
}

static const char *p_check_boot(void *ctx, const uint8_t *img, uint64_t len)
{
	uintptr_t lo = 0, hi = 0;
	const char *why = payload_range(img, len, &lo, &hi);

	(void)ctx;
	if (why)
		return why;
	return loader_check(lo, hi);
}

static void __attribute__((noreturn)) boot_failed(const char *why)
{
	if (bootui_active()) {
		bootui_fail(why);
		delay_ms(8000);
	}
	con_clear(BG_PANIC);
	con_set_scale(2);
	con_str("BOOT", "failed after OKAY");
	con_str("WHY", why);
	if (bootui_active())
		con_replay();
	con_skip();
	con_str("RESET", "back to ABL fastboot in 20 s");
	delay_ms(20000);
	hw_reset(RESTART_BOOTLOADER);
}

static void p_boot(void *ctx, const uint8_t *img, uint64_t len)
{
	uintptr_t lo = 0, hi = 0;
	const char *why = payload_range(img, len, &lo, &hi);

	(void)ctx;
	if (why)
		boot_failed(why);
	con_clear(BG_BOOT);
	con_set_scale(2);
	con_str("BOOT", "downloaded image, stopping USB");
	usb_dwc3_stop();
	why = loader_boot_payload(lo, hi, 1);
	boot_failed(why);
}

static void p_reboot(void *ctx, int mode)
{
	(void)ctx;
	con_clear(BG_BOOT);
	con_set_scale(2);
	con_str("RESET", mode ? "reboot-bootloader" : "reboot");
	delay_ms(300);		/* the OKAY has completed on the wire; give the host a moment */
	hw_reset(mode ? RESTART_BOOTLOADER : RESTART_REBOOT);
}

/* ---- download window ---- */

static void carve(uint64_t *base, uint64_t *end, uint64_t lo, uint64_t hi)
{
	if (hi <= *base || lo >= *end)
		return;
	if (lo > *base && lo - *base >= *end - hi)
		*end = lo;
	else
		*base = (hi + 0x1fffffUL) & ~0x1fffffUL;
}

static const char *pick_buffer(uintptr_t dtb)
{
	uint64_t base = DL_BASE, end = DL_BASE + DL_SIZE, a, b;

	carve(&base, &end, (uintptr_t)_head, (uintptr_t)_end);
	if (dtb && be32(dtb) == 0xd00dfeed)
		carve(&base, &end, dtb, dtb + be32(dtb + 4));
	if (fdt_chosen_u64(dtb, "linux,initrd-start", &a) && fdt_chosen_u64(dtb, "linux,initrd-end", &b))
		carve(&base, &end, a, b);
	if (end <= base || end - base < DL_MIN)
		return "no free download buffer";
	buf_base = base;
	buf_size = (end - base) & ~0xfffffUL;	/* whole MiB */
	return 0;
}

const char *bergamota_fastboot(uintptr_t dtb)
{
	static struct fb fb;
	static struct fb_transport tr;
	static struct fb_platform pl;
	con_clear(BG_BOOT);
	con_set_scale(2);
	con_str("SHIM", "Bergamota fastboot " BOARD_NAME);
	con_skip();
	const char *why = pick_buffer(dtb);

	if (why)
		return why;
	const char *smmu_opt = cmdline_opt(dtb, "bergamota.smmu=");
	int use_smmu = !(smmu_opt && *smmu_opt == '0');

	con_str("USB", "starting controller...");
	int rc = usb_dwc3_init(use_smmu);
	if (rc) {
		ui_draw();
		usb_dwc3_stop();
		return usb_dwc3_errstr(rc);
	}

	tr.ctx = 0;
	tr.recv_cmd = t_recv_cmd;
	tr.send = t_send;
	tr.recv_data = t_recv_data;
	pl.ctx = 0;
	pl.dl_buf = (uint8_t *)buf_base;
	pl.dl_max = buf_size;
	pl.idle = p_idle;
	pl.check_boot = p_check_boot;
	pl.boot = p_boot;
	pl.reboot = p_reboot;
	fb_init(&fb, &tr, &pl);
	g_fb = &fb;
	ui_draw();
	ui_last_ms = ms_now();
	fb_run(&fb);
	usb_dwc3_stop();
	return "fastboot ended";
}
