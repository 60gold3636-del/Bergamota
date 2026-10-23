/*
 * Branded boot screen, see bootui.h. Layout for a 1080-wide a8r8g8b8 framebuffer; all
 * positions derive from FB_W/FB_H so sweet (2400) and beryllium (2246) both work. The block
 * (logo, title, bar, status) is centred between the notch area and the log window.
 */
#include "bootui.h"
#include "console.h"
#include "bootlogo.h"
/* Apple logo for the hand-off screen: generated from the iOS root by tools/mkapplelogo.py (git-ignored). */
#if defined(__has_include)
#if __has_include("applelogo.h")
#include "applelogo.h"
#define HAVE_APPLELOGO 1
#endif
#endif

#ifndef BOOTUI_LOG
#define BOOTUI_LOG	0	/* logo only; the log is recorded and shown if the boot fails */
#endif

#define NOTCH_PX	128			/* status bar / notch area, nothing is drawn above */
#define LOG_SCALE	2
#define LOG_ROWS	24
#define LOG_Y		(FB_H - 24 - LOG_ROWS * 16 * LOG_SCALE)

#define TITLE_SCALE	5
#define TITLE_SPACE	10
#define SUB_SCALE	2
#define SUB_SPACE	14
#define BAR_W		640
#define BAR_H		16
#define STATUS_SCALE	2

#define GAP_LOGO	56
#define GAP_SUB		16
#define GAP_BAR		96
#define GAP_STATUS	28

#define BLOCK_H		(BOOTLOGO_H + GAP_LOGO + 16 * TITLE_SCALE + GAP_SUB + 16 * SUB_SCALE + GAP_BAR + \
			 BAR_H + GAP_STATUS + 16 * STATUS_SCALE)
#define BLOCK_TOP	(((NOTCH_PX + (BOOTUI_LOG ? LOG_Y : FB_H - 24)) - BLOCK_H) / 2)
#define LOGO_Y		BLOCK_TOP
#define TITLE_Y		(LOGO_Y + BOOTLOGO_H + GAP_LOGO)
#define SUB_Y		(TITLE_Y + 16 * TITLE_SCALE + GAP_SUB)
#define BAR_Y		(SUB_Y + 16 * SUB_SCALE + GAP_BAR)
#define BAR_X		((FB_W - BAR_W) / 2)
#define STATUS_Y	(BAR_Y + BAR_H + GAP_STATUS)

#define BAR_TRACK	0xff0f3d22U	/* darker green */
#define FAIL		0xffff8a6aU

static int active;
static unsigned bar_px;		/* filled width so far */

/* Row-wise RLE (tools/mkbootlogo.py) straight into the framebuffer; also used by fbui.c. */
void bootui_draw_rle(const unsigned int *pal, const unsigned char *p, int w, int h, int x0, int y0)
{
	for (int y = 0; y < h; y++) {
		volatile uint32_t *line = con_fb + (y0 + y) * (FB_STRIDE / 4) + x0;
		int x = 0;
		while (x < w) {
			unsigned c = *p++;
			if (c & 0x80) {
				for (unsigned n = (c & 0x7f) + 1; n; n--)
					line[x++] = pal[*p++];
			} else {
				uint32_t col = pal[*p++];
				for (unsigned n = c + 1; n; n--)
					line[x++] = col;
			}
		}
	}
}

static void draw_logo(int x0, int y0)
{
	bootui_draw_rle(bootlogo_pal, bootlogo_rle, BOOTLOGO_W, BOOTLOGO_H, x0, y0);
}

static void centered(int y, int scale, int spacing, uint32_t fg, const char *s)
{
	con_text((FB_W - con_text_w(s, scale, spacing)) / 2, y, scale, spacing, fg, s);
}

static void status(uint32_t fg, const char *s)
{
	con_rect(0, STATUS_Y, FB_W, 16 * STATUS_SCALE, BG_BOOT);
	centered(STATUS_Y, STATUS_SCALE, 0, fg, s);
}

void bootui_init(void)
{
	con_clear(BG_BOOT);
	draw_logo((FB_W - BOOTLOGO_W) / 2, LOGO_Y);
	centered(TITLE_Y, TITLE_SCALE, TITLE_SPACE, TEXT, "BERGAMOTA");
	centered(SUB_Y, SUB_SCALE, SUB_SPACE, LABEL, "PROJECT");
	con_rect(BAR_X, BAR_Y, BAR_W, BAR_H, BAR_TRACK);
	bar_px = 0;
	status(LABEL, "STARTING");
	con_set_scale(LOG_SCALE);
	con_window(BOOTUI_LOG ? LOG_Y : 0, BOOTUI_LOG ? LOG_ROWS : -1);
	if (BOOTUI_LOG)
		con_replay();	/* lines printed before the boot screen existed (e.g. usb_power_up) */
	active = 1;
}

void bootui_handoff(void)
{
#ifdef HAVE_APPLELOGO
	/* iBoot-style: black, Apple logo centred, nothing else. Stays on the panel (xnu keeps the boot
	 * framebuffer untouched in graphics mode) until backboardd presents its own identical logo. */
	if (!active)
		return;
	con_clear(0xff000000U);
	bootui_draw_rle(applelogo_pal, applelogo_rle, APPLELOGO_W, APPLELOGO_H,
			(FB_W - APPLELOGO_W) / 2, (FB_H - APPLELOGO_H) / 2);
#endif
}

static void bar_to(unsigned permille)
{
	if (permille > 1000)
		permille = 1000;
	unsigned px = (unsigned)((uint64_t)BAR_W * permille / 1000);
	if (px > bar_px) {
		con_rect(BAR_X + bar_px, BAR_Y, px - bar_px, BAR_H, LABEL);
		bar_px = px;
	}
}

void bootui_progress(unsigned permille, const char *s)
{
	bar_to(permille);
	status(TEXT, s);
}

static char *put_u(char *d, uint64_t v)
{
	char t[20];
	int n = 0;
	do
		t[n++] = '0' + v % 10;
	while ((v /= 10) && n < 20);
	while (n)
		*d++ = t[--n];
	return d;
}

void bootui_mib(const char *label, uint64_t done, uint64_t total, unsigned from, unsigned to)
{
	char buf[64], *d = buf;
	while (*label && d < buf + 24)
		*d++ = *label++;
	*d++ = ' ';
	d = put_u(d, done);
	*d++ = ' '; *d++ = '/'; *d++ = ' ';
	d = put_u(d, total);
	const char *u = " MiB";
	while (*u)
		*d++ = *u++;
	*d = 0;
	bar_to(total ? from + (unsigned)((uint64_t)(to - from) * (done > total ? total : done) / total) : from);
	status(TEXT, buf);
}

void bootui_fail(const char *msg)
{
	status(FAIL, msg);
}

int bootui_active(void)
{
	return active;
}
