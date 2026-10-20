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
void con_set_scale(int s);	/* 2 or 3; applies to the following rows */
void con_str(const char *label, const char *s);
void con_hex(const char *label, uint64_t v);
/* label, then "a=xxxxxxxx b=xxxxxxxx" style pairs of 32-bit values */
void con_hex2(const char *label, const char *a, uint32_t va, const char *b, uint32_t vb);
