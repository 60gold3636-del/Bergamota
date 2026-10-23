#pragma once
#include <stdint.h>

#include "board.h"

/* Bergamota palette (apps/Bergamota icon): bergamot leaf, rind, pulp. */
#define BG_BOOT	0xff1a5933U	/* dark bergamot green: normal boot screens */
#define BG_PANIC 0xff7a1414U	/* deep red: shim exceptions */
#define LABEL	0xffccec59U	/* lime rind */
#define TEXT	0xfffff78cU	/* pale bergamot yellow */
#define WHITE	0xffffffffU
#define GREEN	0xff00ff00U

/* First text row: rows 0-1 sit under the notch/status area. */
#define TOP_ROWS 2

extern volatile uint32_t *con_fb;

void con_clear(uint32_t bg);
void con_skip(void);
/* Re-print the recorded console lines (kept even while the boot-screen log is muted). */
void con_replay(void);
/* Like con_replay, but only the last n lines. */
void con_replay_tail(unsigned n);
void con_rect(int x, int y, int w, int h, uint32_t c);	/* clipped solid fill, 32-bit stores */
/* Text at pixel position, transparent background; spacing = extra px between glyphs. */
void con_text(int x, int y, int scale, int spacing, uint32_t fg, const char *s);
int con_text_w(const char *s, int scale, int spacing);
/* Route con_str/con_hex* into a window of `rows` lines (current scale) at y_px that wraps; rows < 0 mutes them. */
void con_window(int y_px, int rows);
void con_set_scale(int s);	/* 2 or 3; applies to the following rows */
void con_str(const char *label, const char *s);
void con_hex(const char *label, uint64_t v);
/* label, then "a=xxxxxxxx b=xxxxxxxx" style pairs of 32-bit values */
void con_hex2(const char *label, const char *a, uint32_t va, const char *b, uint32_t vb);
