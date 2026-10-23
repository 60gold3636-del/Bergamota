/*
 * Off-mode charging screen, see charge.h. Palette/logo/text helpers are the Bergamota fastboot
 * screen's (fbui.c); everything below the 128 px notch area of the 1080-wide a8r8g8b8 FB.
 */
#include "bootui.h"
#include "charge.h"
#include "console.h"
#include "fbart.h"
#include "fbui.h"

#define LOGO_Y		144
#define TITLE_SCALE	4
#define TITLE_Y		(LOGO_Y + FBART_LOGO_H + 20)
#define SUB_Y		(TITLE_Y + 16 * TITLE_SCALE + 14)

/* battery icon: nub on top of a rounded body, fill grows from the bottom */
#define BODY_W		360
#define BODY_H		600
#define BODY_X		((FB_W - BODY_W) / 2)
#define NUB_W		120
#define NUB_H		32
#define NUB_Y		(SUB_Y + 32 + 56)
#define BODY_Y		(NUB_Y + NUB_H)
#define BORDER		16
#define RADIUS		40
#define IN_X		(BODY_X + BORDER)
#define IN_Y		(BODY_Y + BORDER)
#define IN_W		(BODY_W - 2 * BORDER)
#define IN_H		(BODY_H - 2 * BORDER)

#define PCT_SCALE	12
#define PCT_H		(16 * PCT_SCALE)
#define PCT_Y		(BODY_Y + BODY_H + 48)
#define STATUS_SCALE	3
#define STATUS_H	(16 * STATUS_SCALE)
#define STATUS_Y	(PCT_Y + PCT_H + 36)
#define BAR_Y		(STATUS_Y + STATUS_H + 44)
#define BAR_W		640
#define BAR_H		16
#define BAR_X		((FB_W - BAR_W) / 2)
#define NOTICE_Y	(BAR_Y + BAR_H + 56)
#define DIAG_Y		(FB_H - 136)
#define HINT_Y		(FB_H - 76)

#define BAR_TRACK	0xff0f3d22U
#define MUTED		0xff74a283U
#define AMBER		0xffffc04dU

#define STR_MAX		96

static int cur_valid;			/* icon/percent/status/bar cache valid */
static unsigned cur_soc;
static enum charge_state cur_state;
static int cur_charging, cur_avail;
static char cur_pct[8], cur_status[STR_MAX], cur_notice[STR_MAX], cur_diag[2][STR_MAX];
static uint32_t cur_notice_fg;
static int bar_px = -1;

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

/* Parts separated by a small square dot (the 8x16 font has no middle dot). */
static void parts_line(int y, int scale, uint32_t fg, const char *const *p, int n)
{
	int dot = scale * 2, gap = scale * 6, w = 0;

	for (int i = 0; i < n; i++)
		w += con_text_w(p[i], scale, 0) + (i ? 2 * gap + dot : 0);
	int x = (FB_W - w) / 2;
	for (int i = 0; i < n; i++) {
		if (i) {
			x += gap;
			con_rect(x, y + 8 * scale - dot / 2, dot, dot, fg);
			x += dot + gap;
		}
		con_text(x, y, scale, 0, fg, p[i]);
		x += con_text_w(p[i], scale, 0);
	}
}

/* ---- tiny string builder ---- */

struct sb {
	char *d;
	unsigned n, max;
};

static void sb_str(struct sb *b, const char *s)
{
	while (*s && b->n + 1 < b->max)
		b->d[b->n++] = *s++;
	b->d[b->n] = 0;
}

static void sb_u(struct sb *b, unsigned v)
{
	char t[12];
	int n = 0;
	do
		t[n++] = '0' + v % 10;
	while ((v /= 10) && n < 12);
	while (n && b->n + 1 < b->max)
		b->d[b->n++] = t[--n];
	b->d[b->n] = 0;
}

/* ---- battery icon ---- */

static void body_corners(int x, int y, int w, int h, int r, uint32_t bg)
{
	for (int i = 0; i < r; i++) {
		int dy = r - i, cut = 0;
		while ((r - cut) * (r - cut) + dy * dy > r * r)
			cut++;
		if (!cut)
			continue;
		con_rect(x, y + i, cut, 1, bg);
		con_rect(x + w - cut, y + i, cut, 1, bg);
		con_rect(x, y + h - 1 - i, cut, 1, bg);
		con_rect(x + w - cut, y + h - 1 - i, cut, 1, bg);
	}
}

/* Lightning bolt, polygon in a 20 x 32 grid scaled by BOLT_S, scan-converted with integers. */
#define BOLT_S		11
#define BOLT_N		7
static const int8_t bolt_x[BOLT_N] = { 11, 2, 9, 6, 18, 10, 14 };
static const int8_t bolt_y[BOLT_N] = { 0, 18, 18, 32, 11, 11, 0 };

static void bolt_row(int py, int x0, int y0, int fill_top, uint32_t over_fill, uint32_t over_empty)
{
	int xs[BOLT_N], n = 0;

	for (int i = 0; i < BOLT_N; i++) {
		int j = (i + 1) % BOLT_N;
		int xa = bolt_x[i] * BOLT_S, ya = bolt_y[i] * BOLT_S, xb = bolt_x[j] * BOLT_S, yb = bolt_y[j] * BOLT_S;
		if (ya == yb)
			continue;
		if (ya > yb) {
			int t = xa; xa = xb; xb = t;
			t = ya; ya = yb; yb = t;
		}
		if (2 * ya <= 2 * py + 1 && 2 * py + 1 < 2 * yb)
			xs[n++] = xa + (xb - xa) * (2 * py + 1 - 2 * ya) / (2 * (yb - ya));
	}
	for (int i = 1; i < n; i++)
		for (int j = i; j > 0 && xs[j - 1] > xs[j]; j--) {
			int t = xs[j]; xs[j] = xs[j - 1]; xs[j - 1] = t;
		}
	int ay = y0 + py;
	for (int i = 0; i + 1 < n; i += 2)
		con_rect(x0 + xs[i], ay, xs[i + 1] - xs[i], 1, ay >= fill_top ? over_fill : over_empty);
}

static void draw_icon(int avail, unsigned soc, int charging)
{
	uint32_t fill = LABEL;

	if (soc <= 15)
		fill = charging ? AMBER : FBUI_ERR_COLOR;
	con_rect(IN_X, IN_Y, IN_W, IN_H, BG_BOOT);
	int fh = 0;
	if (avail) {
		fh = IN_H * (int)soc / 100;
		if (soc && fh < 6)
			fh = 6;
		con_rect(IN_X, IN_Y + IN_H - fh, IN_W, fh, fill);
	}
	if (!avail) {
		const char *q = "?";
		con_text((FB_W - 8 * 24) / 2, IN_Y + (IN_H - 16 * 24) / 2, 24, 0, MUTED, q);
	} else if (charging) {
		int bw = 20 * BOLT_S, bh = 32 * BOLT_S;
		int bx = IN_X + (IN_W - bw) / 2, by = IN_Y + (IN_H - bh) / 2;
		for (int py = 0; py < bh; py++)
			bolt_row(py, bx, by, IN_Y + IN_H - fh, BG_BOOT, TEXT);
	}
}

static void draw_icon_frame(void)
{
	con_rect(BODY_X + (BODY_W - NUB_W) / 2, NUB_Y, NUB_W, NUB_H, LABEL);
	con_rect(BODY_X, BODY_Y, BODY_W, BODY_H, LABEL);
	body_corners(BODY_X, BODY_Y, BODY_W, BODY_H, RADIUS, BG_BOOT);
	con_rect(IN_X, IN_Y, IN_W, IN_H, BG_BOOT);
}

/* ---- bar ---- */

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

/* ---- public ---- */

void charge_ui_init(void)
{
	const char *foot[2];	/* filled at run time: a static pointer table would need ABS64 relocations */

	foot[0] = "Vol - fastboot";
	foot[1] = "Power hold: start iOS";
	con_clear(BG_BOOT);
	bootui_draw_rle(fbart_logo_pal, fbart_logo_rle, FBART_LOGO_W, FBART_LOGO_H, (FB_W - FBART_LOGO_W) / 2, LOGO_Y);
	centered(TITLE_Y, TITLE_SCALE, 10, TEXT, "BERGAMOTA");
	centered(SUB_Y, 2, 14, LABEL, "CHARGING");
	draw_icon_frame();
	parts_line(HINT_Y, 2, MUTED, foot, 2);
	cur_valid = 0;
	cur_pct[0] = cur_status[0] = cur_notice[0] = 0;
	cur_diag[0][0] = cur_diag[1][0] = 0;
	bar_px = -1;
	con_set_scale(2);
	con_window(0, -1);	/* con_* log lines are recorded, not drawn */
}

void charge_ui_update(const struct charge_view *v)
{
	char pct[8], status[STR_MAX], volt[12], amp[12];
	struct sb bp = { pct, 0, sizeof pct }, bs = { status, 0, sizeof status };
	struct sb bv = { volt, 0, sizeof volt }, ba = { amp, 0, sizeof amp };
	const char *parts[3];
	int np = 0, avail = v->state != CHARGE_UNAVAILABLE;
	unsigned soc = v->soc > 100 ? 100 : v->soc;
	int charging = v->state == CHARGE_CHARGING;
	uint32_t pcol = TEXT;

	pct[0] = status[0] = volt[0] = amp[0] = 0;
	if (avail) {
		sb_u(&bp, soc);
		sb_str(&bp, "%");
		sb_u(&bv, v->mv / 1000);
		sb_str(&bv, ".");
		sb_u(&bv, (v->mv % 1000) / 100);
		sb_u(&bv, (v->mv % 1000) / 10 % 10);
		sb_str(&bv, " V");
		unsigned ma = (unsigned)(v->ma < 0 ? -v->ma : v->ma);
		unsigned dec = (ma + 50) / 100;
		sb_u(&ba, dec / 10);
		sb_str(&ba, ".");
		sb_u(&ba, dec % 10);
		sb_str(&ba, " A");
		parts[np++] = v->state == CHARGE_CHARGING ? "Charging" : v->state == CHARGE_FULL ? "Charged" : "Not charging";
		if (v->mv)
			parts[np++] = volt;
		if (v->ma_valid && charging)
			parts[np++] = amp;
		if (soc <= 15 && !charging)
			pcol = FBUI_ERR_COLOR;
	} else {
		sb_str(&bp, "--%");
		parts[np++] = "Battery info unavailable";
		pcol = MUTED;
	}
	for (int i = 0; i < np; i++) {
		if (i)
			sb_str(&bs, "|");
		sb_str(&bs, parts[i]);
	}

	if (!cur_valid || soc != cur_soc || charging != cur_charging || avail != cur_avail)
		draw_icon(avail, soc, charging);
	if (!cur_valid || !same(pct, cur_pct) || v->state != cur_state) {
		con_rect(0, PCT_Y, FB_W, PCT_H, BG_BOOT);
		centered(PCT_Y, PCT_SCALE, 0, pcol, pct);
		copy(cur_pct, pct);
	}
	if (!cur_valid || !same(status, cur_status)) {
		con_rect(0, STATUS_Y, FB_W, STATUS_H, BG_BOOT);
		parts_line(STATUS_Y, STATUS_SCALE, LABEL, parts, np);
		copy(cur_status, status);
	}
	draw_bar(avail ? (int)soc * 10 : FBUI_NOBAR);
	cur_soc = soc;
	cur_state = v->state;
	cur_charging = charging;
	cur_avail = avail;
	cur_valid = 1;
}

void charge_ui_notice(const char *s, uint32_t fg)
{
	if (!s)
		s = "";
	if (same(cur_notice, s) && fg == cur_notice_fg)
		return;
	cur_notice_fg = fg;
	con_rect(0, NOTICE_Y, FB_W, 32, BG_BOOT);
	if (*s)
		centered(NOTICE_Y, 2, 0, fg, s);
	copy(cur_notice, s);
}

void charge_ui_diag(const char *l0, const char *l1)
{
	const char *l[2] = { l0, l1 };

	for (int i = 0; i < 2; i++) {
		const char *s = l[i] ? l[i] : "";
		if (same(cur_diag[i], s))
			continue;
		con_rect(0, DIAG_Y + i * 16, FB_W, 16, BG_BOOT);
		centered(DIAG_Y + i * 16, 1, 0, MUTED, s);
		copy(cur_diag[i], s);
	}
}

void charge_view_from(struct charge_view *v, const struct pmic_batt *b)
{
	v->soc = b->soc;
	v->mv = b->mv;
	v->ma = b->ma;
	v->ma_valid = b->ma_valid;
	if (!b->valid)
		v->state = CHARGE_UNAVAILABLE;
	else if (b->chg == PMIC_CHG_CHARGING)
		v->state = CHARGE_CHARGING;
	else if (b->chg == PMIC_CHG_FULL || (b->usb_present && b->soc >= 100))
		v->state = CHARGE_FULL;
	else
		v->state = CHARGE_NOT_CHARGING;
}
