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
 * Checks before injecting: all payload files readable; crash-loop guard: state in /private/var/tmp/bgl-render.state
 * (boot time, last start, strikes): a start less than 60 s after the previous one in the same boot is a strike; at 3 strikes this
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

#ifdef BGL_TEST                     /* test build: paths and boot-args overridable from the environment */
#define REAL_PATH   (getenv("BGL_REAL") ? getenv("BGL_REAL") : "/usr/libexec/backboardd")
#define LIBDIR      (getenv("BGL_LIBDIR") ? getenv("BGL_LIBDIR") : "/usr/local/lib/bergamota-gl")
#define STATE_PATH  (getenv("BGL_STATE") ? getenv("BGL_STATE") : "/private/var/tmp/bgl-render.state")
#define LOG_PATH    (getenv("BGL_LOG") ? getenv("BGL_LOG") : "/private/var/tmp/bgl-backboardd.log")
#else
#define REAL_PATH   "/usr/libexec/backboardd"
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

static int readable(const char *dir, const char *rel)
{
	char path[512];
	struct stat st;
	snprintf(path, sizeof path, "%s/%s", dir, rel);
	return access(path, R_OK) == 0 && stat(path, &st) == 0 && S_ISREG(st.st_mode) && st.st_size > 0;
}

/* 1 = go on with injection; updates the state file. */
static int guard(void)
{
	struct timeval bt;
	size_t len = sizeof bt;
	long boot = 0, last = 0, strikes = 0, b2 = 0, l2 = 0, s2 = 0;
	time_t now = time(NULL);
	FILE *f;

	int mib[2] = { CTL_KERN, KERN_BOOTTIME };
	if (sysctl(mib, 2, &bt, &len, NULL, 0) != 0)
		return 0;
	boot = (long)bt.tv_sec;
	f = fopen(STATE_PATH, "r");
	if (f) {
		if (fscanf(f, "%ld %ld %ld", &b2, &l2, &s2) == 3 && b2 / 4 == boot / 4) {   /* same boot (tolerate a few seconds of boot-time skew) */
			last = l2; strikes = s2;
			if (now - last < 60)
				strikes++;
			else
				strikes = 0;
		}
		fclose(f);
	}
	if (strikes >= 3)
		return 0;
	f = fopen(STATE_PATH, "w");
	if (!f)
		return 0;                       /* cannot record: no guard, no injection */
	fprintf(f, "%ld %ld %ld\n", boot, (long)now, strikes);
	fclose(f);
	return 1;
}

int main(int argc, char **argv)
{
	char args[1024] = "", mode[16] = "", dbg[16] = "";
	size_t n = sizeof args;
	(void)argc;

#ifdef BGL_TEST
	if (getenv("BGL_BOOTARGS"))
		snprintf(args, sizeof args, "%s", getenv("BGL_BOOTARGS"));
	else
#endif
	if (sysctlbyname("kern.bootargs", args, &n, NULL, 0) != 0)
		args[0] = 0;
	args[sizeof args - 1] = 0;

	if (has_arg(args, "bglrender", mode, sizeof mode) &&
	    (!strcmp(mode, "1") || !strcmp(mode, "soft")) &&
	    readable(LIBDIR, "OpenGLES.framework/OpenGLES") && readable(LIBDIR, "libOSMesa.8.dylib") &&
	    readable(LIBDIR, "libdrm.2.dylib") && guard()) {
		char lib[600];
		struct stat st;
		snprintf(lib, sizeof lib, "%s/OpenGLES.framework/OpenGLES", LIBDIR);
		setenv("DYLD_INSERT_LIBRARIES", lib, 1);
		if (!strcmp(mode, "soft"))
			setenv("SWEET_GPU", "0", 1);
		if (has_arg(args, "bgldebug", dbg, sizeof dbg) && !strcmp(dbg, "1")) {
			setenv("EAGL_SHIM_DEBUG", "1", 1);
			setenv("SWEET_GPU_DEBUG", "1", 1);
		}
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
