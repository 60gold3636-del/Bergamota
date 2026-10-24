#pragma once
#include <stdint.h>

/*
 * Bergamota fastboot screen (the "connect to a computer" picture): logo, title, laptop + USB
 * cable illustration (fbart.h, tools/mkfbart.py), a big status line with progress bar, a footer
 * hint, and optional muted diagnostics. Only the status strip / bar / diagnostics are redrawn
 * after fbui_init; all stores are aligned 32-bit (MMU off safe). con_* log lines are muted
 * (but recorded) while it is up and shown small under the status on fbui_error.
 */
#define FBUI_NOBAR	(-1)

#define FBUI_OK_COLOR	0xffccec59U	/* lime */
#define FBUI_ERR_COLOR	0xffff6a5aU	/* red */

/* Full redraw. `entry` = why fastboot was entered (shown small in the footer), may be 0. */
void fbui_init(const char *entry);
/* Big status line (colour fg), small detail line, bar at permille (0..1000) or FBUI_NOBAR. Redraws only changes. */
void fbui_status(const char *text, const char *detail, int permille, uint32_t fg);
/* One muted line above the footer (the charger state); "" or 0 hides it. Redraws only changes. */
void fbui_charge(const char *s);
/* Muted diagnostic lines at the very bottom; all 0 hides them. */
void fbui_diag(const char *l0, const char *l1, const char *l2);
/* Error: red status, bar hidden, the recorded console log replayed small underneath. */
void fbui_error(const char *why, const char *detail);
