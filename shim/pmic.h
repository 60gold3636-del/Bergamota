#pragma once
#include <stdint.h>

/*
 * Minimal polled SPMI access for the off-mode charging screen (docs/BERGAMOTA_CHARGE.md).
 * Port of the read paths of xnu/patches 0062/0092/0095/0126/0137 (bsd/dev/sweet_spmi.c):
 * PMIC arbiter v5, apps EE observer reads, MMU-off safe, aligned 32-bit MMIO, no interrupts.
 *
 * Everything is READ ONLY (battery fuel gauge + SCHG status on PMI8998 = SID 2, PM8998 PON =
 * SID 0) except the PMI8998 WLED backlight brightness (SID 3, peripheral 0xd9), which
 * pmic_wled_set() writes through the arbiter's write channel. No other write is reachable:
 * the write whitelist is the same five registers the kernel's backlight fade may touch.
 */

/* Charger state, from BATTERY_CHARGER_STATUS_1 + USBIN plug-in. */
enum pmic_chg {
	PMIC_CHG_NONE,		/* USB not present, or charging inhibited/paused/disabled */
	PMIC_CHG_CHARGING,	/* trickle / pre / fast / taper */
	PMIC_CHG_FULL,		/* terminate */
};

struct pmic_batt {
	int valid;		/* fuel gauge SOC + voltage read and sane */
	unsigned soc;		/* percent 0..100 (FG monotonic SOC, rescaled as the kernel does) */
	unsigned mv;		/* battery voltage */
	int ma;			/* >0 charging, <0 discharging; meaningful when ma_valid */
	int ma_valid;
	int usb_present;	/* USBIN_PLUGIN_RT_STS */
	enum pmic_chg chg;
	unsigned chg_state;	/* raw BATTERY_CHARGER_STATUS_1 [2:0] */
	unsigned apsd;		/* raw USBIN APSD_RESULT_STATUS (charger type bits), 0 unknown */
	uint8_t msoc_raw;
};

/* Look at the arbiter. 0 = ready, <0 = unsupported/unmapped (everything else then fails). */
int pmic_init(void);
/* Poll the battery/charger. valid=0 when the FG could not be read; usb_present may still be set. */
void pmic_read_batt(struct pmic_batt *b);

#define PMIC_KEY_POWER	1u	/* PM8998 PON KPDPWR_N RT status */
#define PMIC_KEY_VOLDN	2u	/* PM8998 PON RESIN_N RT status (Volume Down on beryllium) */
#define PMIC_KEY_ERR	0x80u	/* read failed: no key state */
unsigned pmic_keys(void);
/* PON_REASON1 (bit 4 = USB_CHG, bit 7 = KPDPWR), -1 when unreadable. Informational only. */
int pmic_pon_reason(void);

/* WLED backlight: raw 12-bit brightness of both strings. */
int pmic_wled_get(uint16_t v[2]);
int pmic_wled_set(const uint16_t v[2]);	/* 0 = written, latched and read back, -1 = not (originals restored) */
int pmic_wled_enabled(void);		/* MOD_EN bit 7 */
