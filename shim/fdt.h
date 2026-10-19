#pragma once
#include <stdint.h>

/* Read a u32/u64 (cell-size agnostic) property of /chosen. Returns 0 if absent. */
int fdt_chosen_u64(uintptr_t fdt, const char *prop, uint64_t *out);
/*
 * Board bring-up screen: the live FDT's /memory ranges, /reserved-memory
 * children, model and the panel ABL picked (dsi_display0 in bootargs).
 */
void fdt_board_info(uintptr_t fdt);
