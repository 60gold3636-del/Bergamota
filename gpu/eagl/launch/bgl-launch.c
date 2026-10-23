/*
 * SPDX-License-Identifier: MIT
 * bgl-launch: the launchd job of backboardd points here (Renegade root tweak "bglrender"); it execs the REAL backboardd,
 * with the Bergamota GL shim injected only when the kernel boot-args ask for it. Minimal and fail-safe: on ANY doubt it
 * execs plain /usr/libexec/backboardd, exactly as without this wrapper.
 *
 *   boot-arg bglrender=1     inject the shim; GPU (freedreno) if the kernel offers it, else softpipe
 *   boot-arg bglrender=soft  inject the shim, force softpipe (SWEET_GPU=0)
 *   boot-arg bgldebug=1      additionally EAGL_SHIM_DEBUG=1 (shim logging to the log file below)
 *   (anything else / no boot-arg)  plain backboardd
 *
 * Second switch for live use without a reboot (the wrapper is then installed AS /usr/libexec/backboardd, the original moved to
 * backboardd.real, build with -DBGL_REAL_PATH='"/usr/libexec/backboardd.real"'): the marker file /private/var/run/bglrender containing
 * "soft|1 BOOT-SESSION-UUID [debug]", honoured only when the uuid is this boot's kern.bootsessionuuid (so a marker can never act on a
 * later boot; `bgl-launch --bgl-print-boot-uuid` prints it). The boot-arg wins when both are present.
 *
 * Checks before injecting: all payload files readable; crash-loop guard: state in /private/var/tmp/bgl-render.state
 * (boot time, last start, strikes): a start less than 120 s after the previous one in the same boot is a strike; at 3 strikes this
 * boot runs plain. The state is per boot (the boot time is compared), so nothing carries over a reboot. The wrapper's stderr
 * (and with it backboardd's) goes to /private/var/tmp/bgl-backboardd.log (truncated above 1 MiB) while injecting.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#ifndef BGL_REAL_PATH
#define BGL_REAL_PATH "/usr/libexec/backboardd"
#endif
#ifdef BGL_TEST                     /* test build: paths and boot-args overridable from the environment */
#define MARKER      (getenv("BGL_MARKER") ? getenv("BGL_MARKER") : "/private/var/run/bglrender")
#define REAL_PATH   (getenv("BGL_REAL") ? getenv("BGL_REAL") : BGL_REAL_PATH)
#define LIBDIR      (getenv("BGL_LIBDIR") ? getenv("BGL_LIBDIR") : "/usr/local/lib/bergamota-gl")
#define STATE_PATH  (getenv("BGL_STATE") ? getenv("BGL_STATE") : "/private/var/tmp/bgl-render.state")
#define LOG_PATH    (getenv("BGL_LOG") ? getenv("BGL_LOG") : "/private/var/tmp/bgl-backboardd.log")
#else
#define MARKER      "/private/var/run/bglrender"
#define REAL_PATH   BGL_REAL_PATH
#define LIBDIR      "/usr/local/lib/bergamota-gl"
#define STATE_PATH  "/private/var/tmp/bgl-render.state"
#define LOG_PATH    "/private/var/tmp/bgl-backboardd.log"
#endif

static int has_arg(const char *args, const char *key, char *val, size_t vlen)
{
	size_t kl = strlen(key);
	for (const char *p = args; *p; ) {
		while (*p == ' ') p++;
		const char *e = p;
		while (*e && *e != ' ') e++;
		if ((size_t)(e - p) > kl && !strncmp(p, key, kl) && p[kl] == '=') {
			size_t n = (size_t)(e - p) - kl - 1;
			if (n >= vlen) n = vlen - 1;
			memcpy(val, p + kl + 1, n);
			val[n] = 0;
			return 1;
		}
		p = e;
	}
	return 0;
}

static int boot_uuid(char *out, size_t n)
{
#ifdef BGL_TEST
	if (getenv("BGL_UUID")) { snprintf(out, n, "%s", getenv("BGL_UUID")); return 0; }
#endif
	size_t len = n;
	return sysctlbyname("kern.bootsessionuuid", out, &len, NULL, 0);
}

/* The volatile marker holds "MODE UUID [debug]" (MODE soft|1) and is honoured only when UUID is the boot session UUID of THIS boot
 * (kern.bootsessionuuid): a marker left over from an earlier boot can never act, whatever the clock says (the first live test showed that
 * kern.boottime and file times are unreliable early in boot: the RTC is set only later). Returns 1 and the mode in val. */
static int g_marker_debug, g_marker_nohook, g_marker_frames, g_marker_dirty, g_marker_syncall;
static int marker_mode(char *val, size_t vlen)
{
	char line[256], uuid[64] = "", cur[64] = "";
	char *mode, *u, *dbg, *save = NULL;
	g_marker_nohook = 0;
	FILE *f;

	if (boot_uuid(cur, sizeof cur) != 0 || !cur[0])
		return 0;
	f = fopen(MARKER, "r");
	if (!f)
		return 0;
	if (!fgets(line, sizeof line, f)) { fclose(f); return 0; }
	fclose(f);
	mode = strtok_r(line, " \r\n", &save);
	u = strtok_r(NULL, " \r\n", &save);
	dbg = strtok_r(NULL, " \r\n", &save);
	if (!mode || !u)
		return 0;
	/* words after the uuid, any order: debug, frames (debug + per-frame luminance/thumbnails), nohook, dirty (accepted, now the default; sync-all disables it) */
	{
		char *w = dbg;
		int debug = 0;
		while (w) {
			if (!strcmp(w, "nohook")) g_marker_nohook = 1;
			else if (!strcmp(w, "debug")) debug = 1;
			else if (!strcmp(w, "frames")) { debug = 1; g_marker_frames = 1; }
			else if (!strcmp(w, "dirty")) g_marker_dirty = 1;
			else if (!strcmp(w, "syncall")) g_marker_syncall = 1;
			w = strtok_r(NULL, " \r\n", &save);
		}
		dbg = debug ? "debug" : NULL;
	}
	snprintf(uuid, sizeof uuid, "%s", u);
	if (strcmp(uuid, cur) != 0) {   /* a marker of another boot grants nothing */
		g_marker_nohook = g_marker_frames = g_marker_dirty = g_marker_syncall = 0;
		return 0;
	}
	g_marker_debug = dbg && !strcmp(dbg, "debug");
	snprintf(val, vlen, "%s", mode);
	return 1;
}

static int readable(const char *dir, const char *rel)
{
	char path[512];
	struct stat st;
	snprintf(path, sizeof path, "%s/%s", dir, rel);
	return access(path, R_OK) == 0 && stat(path, &st) == 0 && S_ISREG(st.st_mode) && st.st_size > 0;
}

/* 1 = go on with injection; updates the state file (boot session uuid, last start, strikes). */
static int guard(void)
{
	char cur[64] = "", u2[64] = "";
	long last = 0, strikes = 0, l2 = 0, s2 = 0;
	time_t now = time(NULL);
	FILE *f;

	if (boot_uuid(cur, sizeof cur) != 0 || !cur[0])
		return 0;
	f = fopen(STATE_PATH, "r");
	if (f) {
		int n = fscanf(f, "%63s %ld %ld", u2, &l2, &s2);
		if (n == 3 && !strcmp(u2, cur)) {
			last = l2; strikes = s2;
			if (now - last < 120)
				strikes++;
			else
				strikes = 0;
		} else if (n != 3) {
			fclose(f);
			return 0;                   /* a state file that exists but cannot be read back (filesystem errors seen on this root): do not inject */
		}
		fclose(f);
	}
	if (strikes >= 2)                   /* the third start within two minutes of the previous one runs plain; this applies to boot-arg and marker alike */
		return 0;
	f = fopen(STATE_PATH, "w");
	if (!f)
		return 0;                       /* cannot record: no guard, no injection */
	fprintf(f, "%s %ld %ld\n", cur, (long)now, strikes);
	fclose(f);
	return 1;
}

int main(int argc, char **argv)
{
	char args[1024] = "", mode[16] = "", dbg[16] = "";
	size_t n = sizeof args;
	if (argc == 2 && !strcmp(argv[1], "--bgl-print-boot-uuid")) {      /* helper for bgl-live.sh */
		char u[64] = "";
		if (boot_uuid(u, sizeof u) == 0) { puts(u); return 0; }
		return 1;
	}

#ifdef BGL_TEST
	if (getenv("BGL_BOOTARGS"))
		snprintf(args, sizeof args, "%s", getenv("BGL_BOOTARGS"));
	else
#endif
	if (sysctlbyname("kern.bootargs", args, &n, NULL, 0) != 0)
		args[0] = 0;
	args[sizeof args - 1] = 0;

	{ char mm[16] = ""; int have_marker = marker_mode(mm, sizeof mm); if (!has_arg(args, "bglrender", mode, sizeof mode) && have_marker) snprintf(mode, sizeof mode, "%s", mm); }   /* boot-arg wins for the mode; the marker may still add debug/nohook */
	if (mode[0] &&
	    (!strcmp(mode, "1") || !strcmp(mode, "soft")) &&
	    readable(LIBDIR, "OpenGLES.framework/OpenGLES") && readable(LIBDIR, "libOSMesa.8.dylib") &&
	    readable(LIBDIR, "libdrm.2.dylib") && guard()) {
		char lib[600];
		struct stat st;
		snprintf(lib, sizeof lib, "%s/OpenGLES.framework/OpenGLES", LIBDIR);
		setenv("DYLD_INSERT_LIBRARIES", lib, 1);
		if (!strcmp(mode, "soft"))
			setenv("SWEET_GPU", "0", 1);
		{   /* the render-server hook of the shim (ca_server_hook.m): on unless bglhook=0 (boot-arg) or "nohook" in the marker */
			char hv[16] = "";
			if (!g_marker_nohook && !(has_arg(args, "bglhook", hv, sizeof hv) && !strcmp(hv, "0")))
				setenv("BGL_CA_HOOK", "1", 1);
		}
		if ((has_arg(args, "bgldebug", dbg, sizeof dbg) && !strcmp(dbg, "1")) || g_marker_debug) {
			setenv("EAGL_SHIM_DEBUG", g_marker_frames ? "2" : "1", 1);
			setenv("SWEET_GPU_DEBUG", "1", 1);
			setenv("MESA_DEBUG", "1", 1);   /* GL errors and shader compile/link failures on stderr */
		}
		if (g_marker_syncall) setenv("BGL_SYNC_ALL", "1", 1);
		if (stat(LOG_PATH, &st) == 0 && st.st_size > (1 << 20))
			unlink(LOG_PATH);
		int fd = open(LOG_PATH, O_WRONLY | O_CREAT | O_APPEND, 0644);
		if (fd >= 0) {
			dup2(fd, 2);
			close(fd);
			fprintf(stderr, "bgl-launch: injecting %s (bglrender=%s)\n", lib, mode);
		}
	}
	argv[0] = (char *)REAL_PATH;
	execv(REAL_PATH, argv);
	_exit(127);
}
