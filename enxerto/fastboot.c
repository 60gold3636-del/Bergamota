/*
 * Bergamota fastboot protocol core: see fastboot.h. No libc, no hardware, no
 * absolute pointers in data (the shim image runs wherever ABL put it); the
 * host test (fastboot_test.c) compiles this file unchanged.
 */
#include "fastboot.h"

#ifndef FB_PRODUCT
#define FB_PRODUCT	"beryllium"
#endif
#define FB_VERSION_BL	"bergamota-1"
#define FB_SERIAL	"bergamota0001"
#define FB_PKT		64	/* fastboot packet limit: 4 byte status + 60 */

static int fb_starts(const char *s, const char *p)
{
	while (*p && *s == *p)
		s++, p++;
	return !*p;
}

static int fb_eq(const char *a, const char *b)
{
	while (*a && *a == *b)
		a++, b++;
	return *a == *b;
}

static void fb_copy(char *d, const char *s, int max)
{
	int i = 0;
	while (i < max - 1 && s[i])
		d[i] = s[i], i++;
	d[i] = 0;
}

static int fb_hex(char *out, uint64_t v, int min_digits)
{
	static const char hex[] = "0123456789abcdef";
	char tmp[16];
	int n = 0, o = 0;
	do {
		tmp[n++] = hex[v & 0xf];
		v >>= 4;
	} while (v);
	while (n < min_digits)
		tmp[n++] = '0';
	while (n)
		out[o++] = tmp[--n];
	out[o] = 0;
	return o;
}

void fb_init(struct fb *fb, const struct fb_transport *t, const struct fb_platform *p)
{
	fb->t = t;
	fb->p = p;
	fb->dl_len = fb->dl_want = fb->dl_got = 0;
	fb->last_cmd[0] = fb->last_resp[0] = 0;
	fb->n_cmds = fb->n_links = 0;
}

/* "OKAY" / "FAIL" / "INFO" / "DATA" + text, at most 64 bytes. */
static int fb_resp(struct fb *fb, const char *kind, const char *text)
{
	char buf[FB_PKT + 1];
	int n = 0;

	for (; n < 4; n++)
		buf[n] = kind[n];
	for (int i = 0; text[i] && n < FB_PKT; i++)
		buf[n++] = text[i];
	buf[n] = 0;
	if (kind[0] != 'I' && kind[0] != 'D')	/* the screen shows the final answer, not INFO/DATA */
		fb_copy(fb->last_resp, buf, sizeof fb->last_resp);
	return fb->t->send(fb->t->ctx, buf, n);
}

static void fb_drop_session(struct fb *fb)
{
	fb->dl_len = fb->dl_want = fb->dl_got = 0;
	fb->n_links++;
}

/*
 * Variable table as code: a static array of string pointers would need absolute
 * relocations, and the shim image runs wherever ABL put it (build.sh rejects ABS64).
 */
#define FB_NVARS 9

static const char *fb_var(struct fb *fb, unsigned i, const char **name, char *buf)
{
	switch (i) {
	case 0: *name = "version"; return "0.4";
	case 1: *name = "version-bootloader"; return FB_VERSION_BL;
	case 2: *name = "product"; return FB_PRODUCT;
	case 3: *name = "serialno"; return FB_SERIAL;
	case 4: *name = "secure"; return "no";
	case 5: *name = "unlocked"; return "yes";
	case 6:
		*name = "max-download-size";
		buf[0] = '0';
		buf[1] = 'x';
		fb_hex(buf + 2, fb->p->dl_max, 1);
		return buf;
	case 7: *name = "is-userspace"; return "no";
	case 8: *name = "bergamota"; return "1";
	}
	return 0;
}

static void fb_getvar(struct fb *fb, const char *want)
{
	char vbuf[24], line[FB_PKT];
	const char *name;

	if (fb_eq(want, "all")) {
		for (unsigned i = 0; i < FB_NVARS; i++) {
			int n = 0;
			const char *v = fb_var(fb, i, &name, vbuf);
			for (const char *s = name; *s && n < 40; s++)
				line[n++] = *s;
			line[n++] = ':';
			line[n++] = ' ';
			for (; *v && n < FB_PKT - 5; v++)
				line[n++] = *v;
			line[n] = 0;
			fb_resp(fb, "INFO", line);
		}
		fb_resp(fb, "OKAY", "");
		return;
	}
	for (unsigned i = 0; i < FB_NVARS; i++) {
		const char *v = fb_var(fb, i, &name, vbuf);
		if (fb_eq(want, name)) {
			fb_resp(fb, "OKAY", v);
			return;
		}
	}
	fb_resp(fb, "FAIL", "unknown variable");
}

static int fb_parse_hex(const char *s, uint64_t *out)
{
	uint64_t v = 0;
	int n = 0;

	for (; *s; s++, n++) {
		char c = *s;
		int d;
		if (c >= '0' && c <= '9')
			d = c - '0';
		else if (c >= 'a' && c <= 'f')
			d = c - 'a' + 10;
		else if (c >= 'A' && c <= 'F')
			d = c - 'A' + 10;
		else
			return 0;
		if (n >= 8)
			return 0;
		v = v << 4 | (uint64_t)d;
	}
	*out = v;
	return n > 0;
}

/* Returns 0 = answered, FB_LINK_LOST / FB_EOF to bubble up. */
static int fb_download(struct fb *fb, const char *arg)
{
	uint64_t n;
	char buf[12];

	fb->dl_len = 0;
	if (!fb_parse_hex(arg, &n)) {
		fb_resp(fb, "FAIL", "bad download size");
		return 0;
	}
	if (n == 0) {
		fb_resp(fb, "FAIL", "empty download");
		return 0;
	}
	if (n > fb->p->dl_max) {
		fb_resp(fb, "FAIL", "data too large");
		return 0;
	}
	fb_hex(buf, n, 8);
	if (fb_resp(fb, "DATA", buf) < 0)
		return FB_LINK_LOST;
	fb->dl_want = n;
	fb->dl_got = 0;
	int empty = 0;
	while (fb->dl_got < n) {
		int r = fb->t->recv_data(fb->t->ctx, fb->p->dl_buf + fb->dl_got, n - fb->dl_got);
		if (r == 0) {
			if (++empty > 64) {
				fb->dl_want = fb->dl_got = 0;
				fb_resp(fb, "FAIL", "download stalled");
				return 0;
			}
			continue;
		}
		if (r < 0 || (uint64_t)r > n - fb->dl_got) {
			fb->dl_want = fb->dl_got = 0;
			if (r == FB_LINK_LOST || r == FB_EOF)
				return r;
			fb_resp(fb, "FAIL", "data transfer error");
			return 0;
		}
		empty = 0;
		fb->dl_got += (uint64_t)r;
		if (fb->p->idle)
			fb->p->idle(fb->p->ctx, fb);
	}
	fb->dl_len = n;
	fb->dl_want = fb->dl_got = 0;
	fb_resp(fb, "OKAY", "");
	return 0;
}

enum fb_result fb_run(struct fb *fb)
{
	char cmd[FB_PKT + 1];

	for (;;) {
		int n = fb->t->recv_cmd(fb->t->ctx, cmd, FB_PKT);
		if (n == FB_EOF)
			return FB_R_EOF;
		if (n == FB_LINK_LOST) {
			fb_drop_session(fb);
			if (fb->p->idle)
				fb->p->idle(fb->p->ctx, fb);
			continue;
		}
		if (n <= 0) {
			if (fb->p->idle)
				fb->p->idle(fb->p->ctx, fb);
			continue;
		}
		cmd[n] = 0;
		fb_copy(fb->last_cmd, cmd, sizeof fb->last_cmd);
		fb->last_resp[0] = 0;
		fb->n_cmds++;

		int rc = 0;
		if (fb_starts(cmd, "getvar:")) {
			fb_getvar(fb, cmd + 7);
		} else if (fb_starts(cmd, "download:")) {
			rc = fb_download(fb, cmd + 9);
		} else if (fb_eq(cmd, "boot")) {
			const char *why = 0;
			if (!fb->dl_len)
				why = "no image downloaded";
			else if (fb->p->check_boot)
				why = fb->p->check_boot(fb->p->ctx, fb->p->dl_buf, fb->dl_len);
			if (why) {
				fb_resp(fb, "FAIL", why);
			} else {
				fb_resp(fb, "OKAY", "");
				if (fb->p->boot)
					fb->p->boot(fb->p->ctx, fb->p->dl_buf, fb->dl_len);
				fb_copy(fb->last_resp, "boot failed", sizeof fb->last_resp);
				return FB_R_BOOT;
			}
		} else if (fb_eq(cmd, "reboot") || fb_eq(cmd, "continue")) {
			int cont = fb_eq(cmd, "continue");
			fb_resp(fb, "OKAY", "");
			if (fb->p->reboot)
				fb->p->reboot(fb->p->ctx, 0);
			return cont ? FB_R_CONTINUE : FB_R_REBOOT;
		} else if (fb_eq(cmd, "reboot-bootloader")) {
			fb_resp(fb, "OKAY", "");
			if (fb->p->reboot)
				fb->p->reboot(fb->p->ctx, 1);
			return FB_R_REBOOT_BL;
		} else if (fb_starts(cmd, "flash:") || fb_starts(cmd, "erase:") || fb_starts(cmd, "format") ||
			   fb_starts(cmd, "set_active") || fb_starts(cmd, "oem") || fb_starts(cmd, "flashing") ||
			   fb_starts(cmd, "create-logical") || fb_starts(cmd, "delete-logical") ||
			   fb_starts(cmd, "resize-logical") || fb_starts(cmd, "update-super") ||
			   fb_starts(cmd, "snapshot-update")) {
			fb_resp(fb, "FAIL", "not supported: bergamota never writes storage");
		} else {
			fb_resp(fb, "FAIL", "unknown command");
		}
		if (rc == FB_EOF)
			return FB_R_EOF;
		if (rc == FB_LINK_LOST)
			fb_drop_session(fb);
		if (fb->p->idle)
			fb->p->idle(fb->p->ctx, fb);
	}
}

/* ---- images ---- */

static uint32_t le32(const uint8_t *p)
{
	return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static int magic8(const uint8_t *p, const char *m)
{
	for (int i = 0; i < 8; i++)
		if (p[i] != (uint8_t)m[i])
			return 0;
	return 1;
}

int fb_find_payload(const uint8_t *img, uint64_t len, uint64_t *off, uint64_t *size, const char **why)
{
	if (len >= 8 && magic8(img, "SWEETXNU")) {
		*off = 0;
		*size = len;
		return FB_IMG_SWEETXNU;
	}
	if (len < 8 || !magic8(img, "ANDROID!")) {
		*why = "not a boot.img or SWEETXNU payload";
		return 0;
	}
	if (len < 48) {
		*why = "boot.img header truncated";
		return 0;
	}
	uint32_t hv = le32(img + 40), ksz = le32(img + 8), rsz, page;
	if (hv >= 3) {			/* v3/v4: fixed 4096-byte pages */
		rsz = le32(img + 12);
		page = 4096;
	} else {			/* v0..v2 */
		rsz = le32(img + 16);
		page = le32(img + 36);
	}
	if (page < 2048 || page > 65536 || (page & (page - 1))) {
		*why = "boot.img bad page size";
		return 0;
	}
	if (!rsz) {
		*why = "boot.img has no ramdisk";
		return 0;
	}
	uint64_t rd_off = (uint64_t)page + (((uint64_t)ksz + page - 1) / page) * page;
	if (rd_off + rsz > len || rd_off + rsz < rd_off) {
		*why = "boot.img truncated";
		return 0;
	}
	if (rsz < 8 || !magic8(img + rd_off, "SWEETXNU")) {
		*why = "boot.img ramdisk is not SWEETXNU";
		return 0;
	}
	*off = rd_off;
	*size = rsz;
	return FB_IMG_BOOTIMG;
}
