/*
 * Bergamota fastboot screen, see fbui.h. Style follows bootui.c (same palette, logo helper).
 * Layout for a 1080-wide a8r8g8b8 framebuffer, everything below the 128 px notch area.
 */
#include "bootui.h"
#include "console.h"
#include "fbart.h"
#include "fbui.h"

#define LOGO_Y		144
#define TITLE_Y		(LOGO_Y + FBART_LOGO_H + 20)
#define TITLE_SCALE	4
#define SUB_Y		(TITLE_Y + 16 * TITLE_SCALE + 14)
#define TAG_Y		(SUB_Y + 32 + 12)
#define SCENE_Y		(TAG_Y + 32 + 12)
#define STATUS_Y	(SCENE_Y + FBART_SCENE_H + 36)
#define BAR_Y		(STATUS_Y + 64 + 28)
#define BAR_W		640
#define BAR_H		16
#define BAR_X		((FB_W - BAR_W) / 2)
#define DETAIL_Y	(BAR_Y + BAR_H + 20)
#define LOG_Y		(DETAIL_Y + 60)
#define LOG_ROWS	15
#define DIAG_Y		(FB_H - 136)
#define HINT_Y		(FB_H - 76)
#define CHG_Y		(DIAG_Y - 40)
#define ENTRY_Y		(FB_H - 36)

#define BAR_TRACK	0xff0f3d22U
#define MUTED		0xff74a283U

#define STR_MAX		96

static char cur_text[STR_MAX], cur_detail[STR_MAX], cur_diag[3][STR_MAX], cur_chg[STR_MAX];
static int cur_color_set;
static uint32_t cur_fg;
static int bar_px = -1;	/* -1: hidden */
static char entry_txt[48];

static void copy(char *d, const char *s)
{
	int i = 0;
	while (s && s[i] && i < STR_MAX - 1) {
		d[i] = s[i];
		i++;
	}
	d[i] = 0;
}

static int same(const char *a, const char *b)
{
	while (*a && *a == *b)
		a++, b++;
	return *a == *b;
}

static void centered(int y, int scale, int spacing, uint32_t fg, const char *s)
{
	con_text((FB_W - con_text_w(s, scale, spacing)) / 2, y, scale, spacing, fg, s);
}

static void draw_bar(int permille)
{
	if (permille < 0) {
		if (bar_px >= 0)
			con_rect(BAR_X, BAR_Y, BAR_W, BAR_H, BG_BOOT);
		bar_px = -1;
		return;
	}
	if (permille > 1000)
		permille = 1000;
	int px = BAR_W * permille / 1000;
	if (bar_px < 0) {
		con_rect(BAR_X, BAR_Y, BAR_W, BAR_H, BAR_TRACK);
		bar_px = 0;
	}
	if (px > bar_px)
		con_rect(BAR_X + bar_px, BAR_Y, px - bar_px, BAR_H, LABEL);
	else if (px < bar_px)
		con_rect(BAR_X + px, BAR_Y, bar_px - px, BAR_H, BAR_TRACK);
	bar_px = px;
}

void fbui_init(const char *entry)
{
	con_clear(BG_BOOT);
	bootui_draw_rle(fbart_logo_pal, fbart_logo_rle, FBART_LOGO_W, FBART_LOGO_H, (FB_W - FBART_LOGO_W) / 2, LOGO_Y);
	centered(TITLE_Y, TITLE_SCALE, 10, TEXT, "BERGAMOTA");
	centered(SUB_Y, 2, 14, LABEL, "FASTBOOT");
	centered(TAG_Y, 2, 0, MUTED, "boot from your Mac");
	bootui_draw_rle(fbart_scene_pal, fbart_scene_rle, FBART_SCENE_W, FBART_SCENE_H, (FB_W - FBART_SCENE_W) / 2, SCENE_Y);
	centered(HINT_Y, 2, 0, MUTED, "Hold Power + Volume Down for the bootloader");
	entry_txt[0] = 0;
	if (entry) {
		int i = 0;
		for (const char *p = "entered via: "; *p; p++)
			entry_txt[i++] = *p;
		for (; *entry && i < (int)sizeof(entry_txt) - 1; entry++)
			entry_txt[i++] = *entry;
		entry_txt[i] = 0;
		centered(ENTRY_Y, 1, 0, MUTED, entry_txt);
	}
	cur_text[0] = cur_detail[0] = 0;
	cur_diag[0][0] = cur_diag[1][0] = cur_diag[2][0] = cur_chg[0] = 0;
	cur_color_set = 0;
	bar_px = -1;
	con_set_scale(2);
	con_window(0, -1);	/* log lines are recorded, not drawn */
}

void fbui_status(const char *text, const char *detail, int permille, uint32_t fg)
{
	if (!cur_color_set || fg != cur_fg || !same(cur_text, text)) {
		int scale = TITLE_SCALE;
		while (scale > 2 && con_text_w(text, scale, 0) > FB_W - 48)
			scale--;
		con_rect(0, STATUS_Y, FB_W, 64, BG_BOOT);
		centered(STATUS_Y + (64 - 16 * scale) / 2, scale, 0, fg, text);
		copy(cur_text, text);
		cur_fg = fg;
		cur_color_set = 1;
	}
	if (!detail)
		detail = "";
	if (!same(cur_detail, detail)) {
		con_rect(0, DETAIL_Y, FB_W, 32, BG_BOOT);
		centered(DETAIL_Y, 2, 0, LABEL, detail);
		copy(cur_detail, detail);
	}
	draw_bar(permille);
}

void fbui_charge(const char *s)
{
	if (!s)
		s = "";
	if (same(cur_chg, s))
		return;
	con_rect(0, CHG_Y, FB_W, 32, BG_BOOT);
	if (*s)
		centered(CHG_Y, 2, 0, MUTED, s);
	copy(cur_chg, s);
}

void fbui_diag(const char *l0, const char *l1, const char *l2)
{
	const char *l[3] = { l0, l1, l2 };
	for (int i = 0; i < 3; i++) {
		const char *s = l[i] ? l[i] : "";
		if (same(cur_diag[i], s))
			continue;
		con_rect(0, DIAG_Y + i * 16, FB_W, 16, BG_BOOT);
		centered(DIAG_Y + i * 16, 1, 0, MUTED, s);
		copy(cur_diag[i], s);
	}
}

void fbui_error(const char *why, const char *detail)
{
	char buf[STR_MAX];
	int i = 0;
	for (const char *p = "BOOT FAILED: "; *p; p++)
		buf[i++] = *p;
	for (; *why && i < STR_MAX - 1; why++)
		buf[i++] = *why;
	buf[i] = 0;
	fbui_status(buf, detail, FBUI_NOBAR, FBUI_ERR_COLOR);
	con_set_scale(2);
	con_window(LOG_Y, LOG_ROWS);
	con_replay_tail(LOG_ROWS - 1);
	con_window(0, -1);
}
