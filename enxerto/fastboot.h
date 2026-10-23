#pragma once
/*
 * Bergamota fastboot: the Android fastboot protocol subset (getvar, download,
 * boot, reboot, reboot-bootloader, continue) as a transport-independent
 * state machine, so shim/fastboot_test.c can drive it with a fake transport.
 * There is deliberately no flash / erase / format / set_active.
 * Hardware glue (USB, screen, boot, reset): bergamota.c.
 */
#include <stdint.h>

/* Transport return codes (anything else < 0 is a failure of that call). */
#define FB_LINK_LOST	(-1)	/* host reset / unplugged: drop the session, keep serving */
#define FB_EOF		(-2)	/* fake transport only: script over, fb_run returns */

struct fb_transport {
	void *ctx;
	/* One command packet (no terminator): >0 length, 0 = nothing yet, <0 = FB_LINK_LOST / FB_EOF. */
	int (*recv_cmd)(void *ctx, char *buf, unsigned max);
	/* 0 or <0 */
	int (*send)(void *ctx, const char *buf, unsigned len);
	/* One bulk transfer of up to len bytes into dst: >0 bytes, 0 = empty packet (retried), <0 = FB_LINK_LOST / error. */
	int (*recv_data)(void *ctx, uint8_t *dst, uint64_t len);
};

struct fb;

struct fb_platform {
	void *ctx;
	uint8_t *dl_buf;	/* download buffer */
	uint64_t dl_max;	/* its size = max-download-size */
	/* Called while nothing is happening (UI refresh); may be NULL. */
	void (*idle)(void *ctx, struct fb *fb);
	/* 'boot' pre-check on the downloaded image: NULL = acceptable, else a short reason (sent as FAIL). */
	const char *(*check_boot)(void *ctx, const uint8_t *img, uint64_t len);
	/* After OKAY was sent: boot it (does not return on success). */
	void (*boot)(void *ctx, const uint8_t *img, uint64_t len);
	/* After OKAY was sent: mode 0 = normal reboot, 1 = bootloader (does not return on hardware). */
	void (*reboot)(void *ctx, int mode);
};

enum fb_result {
	FB_R_BOOT,		/* 'boot' accepted; platform boot returned (= failed) */
	FB_R_REBOOT,
	FB_R_REBOOT_BL,
	FB_R_CONTINUE,
	FB_R_EOF,		/* transport script ended (tests) */
};

struct fb {
	const struct fb_transport *t;
	const struct fb_platform *p;
	uint64_t dl_len;	/* bytes in the buffer from the last complete download */
	uint64_t dl_want, dl_got; /* download in progress */
	char last_cmd[64];	/* NUL terminated, for the screen */
	char last_resp[64];
	unsigned n_cmds, n_links;
};

void fb_init(struct fb *fb, const struct fb_transport *t, const struct fb_platform *p);
/* Serve until a terminal command ran (platform callback returned) or the transport ended. */
enum fb_result fb_run(struct fb *fb);

/* ---- image helpers (pure; also used by the boot pre-check) ---- */
#define FB_IMG_SWEETXNU	1	/* raw SWEETXNU payload */
#define FB_IMG_BOOTIMG	2	/* Android boot.img with a SWEETXNU ramdisk */
/*
 * Locate the SWEETXNU payload: (*off, *size) = its place inside img. Returns the
 * kind (FB_IMG_*), or 0 with a short reason in *why.
 */
int fb_find_payload(const uint8_t *img, uint64_t len, uint64_t *off, uint64_t *size, const char **why);
