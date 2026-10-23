#!/bin/sh
# Host test of sweetmetrics' text parsers (no device): kern.sweet_cpufreq / kern.sweet_gpu strings -> JSON.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
bin=${TMPDIR:-/tmp}/sweetmetrics-host
clang -O2 -Wall -framework CoreFoundation -framework IOKit "$here/sweetmetrics.c" -o "$bin"
python3 - "$bin" <<'PY'
import json, subprocess, sys
b = sys.argv[1]
def run(*a): return json.loads(subprocess.check_output([b, *a]))
bad = 0
def ck(c, w):
    global bad
    print(("ok   " if c else "FAIL ") + w); bad += (not c)
cf = "domain0 A55 applied: state 3/12 1209600 kHz (requested 3, 40%); domain1 A75 applied: state 11/12 2803200 kHz (requested 11, 100%)"
c = run("--parse-cpufreq", cf)["cpu"]["clusters"]
ck([x["curKhz"] for x in c] == [1209600, 2803200] and c[0]["capPercent"] == 40 and c[0]["mode"] == "static", "patch 0190 string")
c = run("--parse-cpufreq", "domain0 A55 off; domain1 A75 pending")["cpu"]["clusters"]
ck(c[0]["mode"] == "off" and c[1]["mode"] == "pending" and c[0]["curKhz"] is None, "off / pending")
c = run("--parse-cpufreq", "domain0 A55 skipped; domain1 A75 applied: state 2/12 825600 kHz")["cpu"]["clusters"]
ck(c[0]["mode"] == "skipped" and c[1]["curKhz"] == 825600, "skipped + no cap")
c = run("--parse-cpufreq", "cluster0 A55 applied: 1100000 kHz min 300 max 1785600 governor schedutil; cluster1 A75 applied: 2000000 kHz gov=perf")["cpu"]["clusters"]
ck(c[0]["governor"] == "schedutil" and c[0]["minKhz"] == 300000 and c[0]["maxKhz"] == 1785600 and c[0]["mode"] == "governor" and c[1]["governor"] == "perf", "governor build (min/max MHz or kHz)")
ck(run("--parse-cpufreq", "garbage")["cpu"]["clusters"][0]["curKhz"] is None, "garbage gives unknown clusters")
g = run("--parse-gpu", "state slumber level 2/8 freq 342 MHz busy 12% min 257 max 710")["gpu"]
ck((g["state"], g["level"], g["levels"], g["mhz"], g["busyPct"], g["maxMhz"]) == ("slumber", 2, 8, 342, 12, 710), "gpu string")
g = run("--parse-gpu", "state=active level=7 clock=710000000 load=99")["gpu"]
ck((g["state"], g["level"], g["mhz"], g["busyPct"]) == ("on", 7, 710, 99), "gpu alt keys (active, Hz)")
g = run("--parse-gpu", "state lost")["gpu"]
ck(g["state"] == "lost" and g["mhz"] is None, "gpu lost, rest null")
sys.exit(1 if bad else 0)
PY
