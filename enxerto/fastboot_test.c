/*
 * Host test of the fastboot protocol state machine (fastboot.c) with a fake
 * transport: cc -O1 -Wall -o out/fastboot_test fastboot.c fastboot_test.c && out/fastboot_test
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "fastboot.h"

static int failures, checks;
#define CHECK(c) do { checks++; if (!(c)) { failures++; printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

enum { S_CMD, S_DATA, S_LINK, S_DATA_ERR };
struct step {
	int kind;
	const char *cmd;
	const uint8_t *data;
	uint64_t len;
	uint64_t off;	/* progress inside a DATA step */
};

static struct step script[32];
static int n_steps, cur;
static char resp[64][80];
static int n_resp;
static unsigned data_chunk = 1000;	/* bytes per fake bulk transfer */

static void reset_fake(void)
{
	memset(script, 0, sizeof script);
	n_steps = cur = n_resp = 0;
	data_chunk = 1000;
}

static void cmd(const char *c) { script[n_steps++] = (struct step){ S_CMD, c, 0, 0, 0 }; }
static void data(const void *d, uint64_t n) { script[n_steps++] = (struct step){ S_DATA, 0, d, n, 0 }; }
static void link_lost(void) { script[n_steps++] = (struct step){ S_LINK, 0, 0, 0, 0 }; }
static void data_err(void) { script[n_steps++] = (struct step){ S_DATA_ERR, 0, 0, 0, 0 }; }

static int t_recv_cmd(void *ctx, char *buf, unsigned max)
{
	(void)ctx;
	if (cur >= n_steps)
		return FB_EOF;
	struct step *s = &script[cur];
	if (s->kind == S_LINK) {
		cur++;
		return FB_LINK_LOST;
	}
	if (s->kind != S_CMD) {
		printf("FAIL protocol: recv_cmd while a data step is next\n");
		failures++;
		return FB_EOF;
	}
	cur++;
	unsigned n = (unsigned)strlen(s->cmd);
	if (n > max)
		n = max;
	memcpy(buf, s->cmd, n);
	return (int)n;
}

static int t_send(void *ctx, const char *buf, unsigned len)
{
	(void)ctx;
	CHECK(len <= 64);
	if (n_resp < 64) {
		memcpy(resp[n_resp], buf, len);
		resp[n_resp][len] = 0;
		n_resp++;
	}
	return 0;
}

static int t_recv_data(void *ctx, uint8_t *dst, uint64_t len)
{
	(void)ctx;
	if (cur >= n_steps)
		return FB_EOF;
	struct step *s = &script[cur];
	if (s->kind == S_LINK) {
		cur++;
		return FB_LINK_LOST;
	}
	if (s->kind == S_DATA_ERR) {
		cur++;
		return -7;
	}
	if (s->kind != S_DATA) {
		printf("FAIL protocol: recv_data while a command is next\n");
		failures++;
		return FB_EOF;
	}
	uint64_t n = s->len - s->off;
	if (n > len)
		n = len;
	if (n > data_chunk)
		n = data_chunk;
	memcpy(dst, s->data + s->off, n);
	s->off += n;
	if (s->off == s->len)
		cur++;
	return (int)n;
}

/* platform fakes */
static uint8_t dlbuf[0x100000];
static int boot_calls, reboot_calls, last_reboot_mode, idle_calls;
static uint64_t boot_len;
static int boot_content_ok;
static const uint8_t *boot_expect;

static void p_idle(void *ctx, struct fb *fb) { (void)ctx; (void)fb; idle_calls++; }

static const char *p_check_boot(void *ctx, const uint8_t *img, uint64_t len)
{
	(void)ctx;
	uint64_t off, size;
	const char *why = "";
	return fb_find_payload(img, len, &off, &size, &why) ? 0 : why;
}

static void p_boot(void *ctx, const uint8_t *img, uint64_t len)
{
	(void)ctx;
	boot_calls++;
	boot_len = len;
	boot_content_ok = boot_expect && !memcmp(img, boot_expect, len);
}

static void p_reboot(void *ctx, int mode)
{
	(void)ctx;
	reboot_calls++;
	last_reboot_mode = mode;
}

static const struct fb_transport transport = { 0, t_recv_cmd, t_send, t_recv_data };
static const struct fb_platform platform = {
	0, dlbuf, sizeof dlbuf, p_idle, p_check_boot, p_boot, p_reboot,
};

static struct fb run_session(enum fb_result *out)
{
	struct fb fb;
	boot_calls = reboot_calls = idle_calls = 0;
	boot_content_ok = 0;
	fb_init(&fb, &transport, &platform);
	*out = fb_run(&fb);
	return fb;
}

static int resp_is(int i, const char *s) { return i < n_resp && !strcmp(resp[i], s); }
static int resp_starts(int i, const char *s) { return i < n_resp && !strncmp(resp[i], s, strlen(s)); }

/* ---- image builders ---- */
static uint8_t *make_sweet(uint64_t size)
{
	uint8_t *p = calloc(1, size);
	memcpy(p, "SWEETXNU", 8);
	for (uint64_t i = 8; i < size; i++)
		p[i] = (uint8_t)(i * 31 + (i >> 8));
	return p;
}

static void put32(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }

/* boot.img v0..v2 (hv < 3) or v3/v4 */
static uint8_t *make_bootimg(int hv, uint32_t page, uint32_t ksz, const uint8_t *rd, uint32_t rdsz, uint64_t *total)
{
	uint32_t kpad = (ksz + page - 1) / page * page, rpad = (rdsz + page - 1) / page * page;
	uint64_t n = (uint64_t)page + kpad + rpad;
	uint8_t *p = calloc(1, n);
	memcpy(p, "ANDROID!", 8);
	put32(p + 8, ksz);
	if (hv >= 3) {
		put32(p + 12, rdsz);
		put32(p + 40, hv);
		page = 4096;	/* v3 pages are fixed; callers pass 4096 */
	} else {
		put32(p + 16, rdsz);
		put32(p + 36, page);
		put32(p + 40, hv);
	}
	memset(p + page, 0xaa, ksz);
	memcpy(p + page + kpad, rd, rdsz);
	*total = n;
	return p;
}

int main(void)
{
	enum fb_result r;
	struct fb fb;

	/* getvar */
	reset_fake();
	cmd("getvar:version"); cmd("getvar:product"); cmd("getvar:max-download-size");
	cmd("getvar:is-userspace"); cmd("getvar:bergamota"); cmd("getvar:nonsense"); cmd("getvar:version-bootloader");
	fb = run_session(&r);
	CHECK(r == FB_R_EOF);
	CHECK(resp_is(0, "OKAY0.4"));
	CHECK(resp_is(1, "OKAYberyllium"));
	CHECK(resp_is(2, "OKAY0x100000"));
	CHECK(resp_is(3, "OKAYno"));
	CHECK(resp_is(4, "OKAY1"));
	CHECK(resp_starts(5, "FAIL"));
	CHECK(resp_is(6, "OKAYbergamota-1"));
	CHECK(fb.n_cmds == 7);
	CHECK(idle_calls >= 7);

	/* getvar all: INFO lines then OKAY */
	reset_fake();
	cmd("getvar:all");
	fb = run_session(&r);
	CHECK(n_resp >= 10 && resp_is(n_resp - 1, "OKAY"));
	CHECK(resp_starts(0, "INFOversion: 0.4"));
	int saw_prod = 0, saw_max = 0, saw_user = 0, saw_berg = 0;
	for (int i = 0; i < n_resp; i++) {
		saw_prod |= !strcmp(resp[i], "INFOproduct: beryllium");
		saw_max |= !strcmp(resp[i], "INFOmax-download-size: 0x100000");
		saw_user |= !strcmp(resp[i], "INFOis-userspace: no");
		saw_berg |= !strcmp(resp[i], "INFObergamota: 1");
	}
	CHECK(saw_prod && saw_max && saw_user && saw_berg);

	/* download of 5000 bytes in 1000 byte bulk transfers, then boot a raw payload */
	uint8_t *raw = make_sweet(5000);
	reset_fake();
	boot_expect = raw;
	cmd("download:00001388"); data(raw, 5000); cmd("boot");
	fb = run_session(&r);
	CHECK(r == FB_R_BOOT);
	CHECK(resp_is(0, "DATA00001388"));
	CHECK(resp_is(1, "OKAY"));
	CHECK(resp_is(2, "OKAY"));
	CHECK(boot_calls == 1 && boot_len == 5000 && boot_content_ok);
	CHECK(!memcmp(dlbuf, raw, 5000));

	/* boot.img v0, v2 and v3 wrappers with a SWEETXNU ramdisk */
	{
		uint8_t *rd = make_sweet(3000);
		static const struct { int hv; uint32_t page; } cfgs[] = { { 0, 2048 }, { 1, 4096 }, { 2, 4096 }, { 3, 4096 }, { 4, 4096 } };
		for (unsigned i = 0; i < sizeof cfgs / sizeof cfgs[0]; i++) {
			uint64_t total, off = 0, size = 0;
			const char *why = "";
			uint8_t *bi = make_bootimg(cfgs[i].hv, cfgs[i].page, 12345, rd, 3000, &total);
			CHECK(fb_find_payload(bi, total, &off, &size, &why) == FB_IMG_BOOTIMG);
			CHECK(size == 3000 && !memcmp(bi + off, rd, 3000) && (off & 7) == 0);
			free(bi);
		}
		/* ramdisk that is not a payload, truncated image, empty ramdisk, junk */
		uint64_t total, off, size;
		const char *why = "";
		uint8_t bad[3000];
		memset(bad, 7, sizeof bad);
		uint8_t *bi = make_bootimg(2, 4096, 100, bad, 3000, &total);
		CHECK(fb_find_payload(bi, total, &off, &size, &why) == 0 && strstr(why, "not SWEETXNU"));
		free(bi);
		bi = make_bootimg(2, 4096, 100, rd, 3000, &total);
		CHECK(fb_find_payload(bi, total - 8192 + 10, &off, &size, &why) == 0 && strstr(why, "truncated"));
		put32(bi + 16, 0);
		CHECK(fb_find_payload(bi, total, &off, &size, &why) == 0 && strstr(why, "no ramdisk"));
		put32(bi + 16, 3000);
		put32(bi + 36, 1000);	/* page size not a power of two */
		CHECK(fb_find_payload(bi, total, &off, &size, &why) == 0 && strstr(why, "page"));
		put32(bi + 36, 4096);
		put32(bi + 8, 0xffffffffu);	/* kernel size far beyond the file */
		CHECK(fb_find_payload(bi, total, &off, &size, &why) == 0);
		free(bi);
		uint8_t junk[64] = { 1, 2, 3 };
		CHECK(fb_find_payload(junk, sizeof junk, &off, &size, &why) == 0 && strstr(why, "not a boot.img"));
		CHECK(fb_find_payload(junk, 3, &off, &size, &why) == 0);

		/* end to end: download a boot.img, boot it */
		uint8_t *img = make_bootimg(2, 4096, 20000, rd, 3000, &total);
		reset_fake();
		boot_expect = img;
		char c[32];
		snprintf(c, sizeof c, "download:%08x", (unsigned)total);
		cmd(c); data(img, total); cmd("boot");
		fb = run_session(&r);
		CHECK(r == FB_R_BOOT && boot_calls == 1 && boot_len == total && boot_content_ok);
		free(img);
		free(rd);
	}

	/* boot without a download, boot of junk */
	reset_fake();
	cmd("boot");
	fb = run_session(&r);
	CHECK(r == FB_R_EOF && boot_calls == 0 && resp_starts(0, "FAIL"));
	{
		static const uint8_t junk[100] = { 'h', 'e', 'l', 'l', 'o' };
		reset_fake();
		cmd("download:00000064"); data(junk, 100); cmd("boot");
		fb = run_session(&r);
		CHECK(r == FB_R_EOF && boot_calls == 0 && resp_is(1, "OKAY") && resp_starts(2, "FAILnot a boot.img"));
	}

	/* download errors */
	reset_fake();
	cmd("download:00200000");	/* > dl_max */
	cmd("download:0"); cmd("download:zz"); cmd("download:123456789"); cmd("download:");
	fb = run_session(&r);
	CHECK(resp_is(0, "FAILdata too large"));
	CHECK(resp_starts(1, "FAIL") && resp_starts(2, "FAIL") && resp_starts(3, "FAIL") && resp_starts(4, "FAIL"));
	CHECK(fb.dl_len == 0);

	/* the maximum size is accepted and filled exactly */
	{
		uint8_t *big = make_sweet(sizeof dlbuf);
		reset_fake();
		data_chunk = 0x30000;
		cmd("download:00100000"); data(big, sizeof dlbuf);
		fb = run_session(&r);
		CHECK(resp_is(0, "DATA00100000") && resp_is(1, "OKAY") && fb.dl_len == sizeof dlbuf);
		CHECK(!memcmp(dlbuf, big, sizeof dlbuf));
		free(big);
	}

	/* link lost in the middle of a download drops it; a later boot must fail */
	{
		reset_fake();
		cmd("download:00001000"); data(raw, 1000); link_lost(); cmd("boot");
		fb = run_session(&r);
		CHECK(resp_is(0, "DATA00001000"));
		CHECK(fb.dl_len == 0 && fb.n_links >= 1);
		CHECK(boot_calls == 0 && resp_starts(1, "FAILno image"));
	}
	/* link lost between commands also forgets a finished download */
	reset_fake();
	cmd("download:00001388"); data(raw, 5000); link_lost(); cmd("boot");
	fb = run_session(&r);
	CHECK(boot_calls == 0 && resp_starts(2, "FAILno image"));

	/* transport error in the data phase answers FAIL */
	reset_fake();
	cmd("download:00000010"); data_err(); cmd("getvar:version");
	fb = run_session(&r);
	CHECK(resp_is(0, "DATA00000010") && resp_starts(1, "FAILdata transfer") && resp_is(2, "OKAY0.4") && fb.dl_len == 0);

	/* a second download replaces the first */
	reset_fake();
	cmd("download:00000008"); data("SWEETXNU", 8); cmd("download:00000009"); data("SWEETXNUX", 9);
	fb = run_session(&r);
	CHECK(fb.dl_len == 9);

	/* reboot family */
	reset_fake();
	cmd("reboot");
	fb = run_session(&r);
	CHECK(r == FB_R_REBOOT && reboot_calls == 1 && last_reboot_mode == 0 && resp_is(0, "OKAY"));
	reset_fake();
	cmd("reboot-bootloader");
	fb = run_session(&r);
	CHECK(r == FB_R_REBOOT_BL && reboot_calls == 1 && last_reboot_mode == 1 && resp_is(0, "OKAY"));
	reset_fake();
	cmd("continue");
	fb = run_session(&r);
	CHECK(r == FB_R_CONTINUE && reboot_calls == 1 && last_reboot_mode == 0);

	/* nothing that writes storage is accepted, and nothing after a refused command breaks */
	{
		static const char *const bad[] = { "flash:boot", "erase:userdata", "format:ext4:userdata", "set_active:a",
			"oem unlock", "flashing unlock", "create-logical-partition:x:1", "snapshot-update:cancel", "frobnicate", "" };
		reset_fake();
		for (unsigned i = 0; i < sizeof bad / sizeof bad[0] - 1; i++)
			cmd(bad[i]);
		cmd("getvar:version");
		fb = run_session(&r);
		int all_fail = 1;
		for (unsigned i = 0; i < sizeof bad / sizeof bad[0] - 1; i++)
			all_fail &= resp_starts((int)i, "FAIL");
		CHECK(all_fail);
		CHECK(resp_is(9, "OKAY0.4"));
		CHECK(boot_calls == 0 && reboot_calls == 0);
	}

	/* response packets never exceed 64 bytes: a very long variable name is just refused */
	reset_fake();
	cmd("getvar:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
	fb = run_session(&r);
	CHECK(resp_starts(0, "FAIL"));

	free(raw);
	printf("fastboot_test: %d checks, %d failures\n", checks, failures);
	return failures ? 1 : 0;
}
