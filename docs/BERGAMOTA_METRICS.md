# Bergamota live device metrics (`sweetmetrics`)

`/usr/local/bin/sweetmetrics` prints **one JSON object** with the phone's live metrics. Bergamota (apps/Bergamota) runs it over SSH about every 2 s while iOS is up, shows it (Dashboard "Performance" card, Control Plane strip, 2-minute sparklines) and republishes it in `status.json` as `phone.metrics`; `scripts/bergamota metrics [--json]` prints it.

Source: `tools/sweetnet/sweetmetrics.c` (plain C, arm64e, `tools/sweetnet/build.sh` -> `research/sweetnet/ios18/sweetmetrics`, then `tools/renegade/renegade strip --sign`). Installed by Renegade (`tools/renegade/root_tweaks18.py`, `sweetmetrics()`); on a running phone: `scp` it to `/usr/local/bin/sweetmetrics` and verify the sha256.
It is read-only and takes about 0.3 s (the CPU load window). Flags: `--gpu-info` (also open a SweetAdreno630 user client and read INFO, see GPU), `--no-load`, `--interval MS` (load window, default 250), and the host-test hooks `--parse-cpufreq STR` / `--parse-gpu STR`.

## Contract (schema 1)

Rules: every member except `schema` may be **missing or null**; null means "not reported by this kernel", never 0. Readers must ignore unknown members and unknown `mode`/`state` strings. A new incompatible layout bumps `schema`. `errors` lists the sources that were unavailable (human text).

```json
{
  "schema": 1,
  "t": 1792781636.697,                      // phone clock, unix seconds
  "cpu": {
    "source": "sysctl kern.sweet_cpufreq",  // or "none"
    "freqKnown": true,                      // false: no frequency source at all (fixed by the bootloader)
    "loadPct": [31,22,18,40,3,0,1,0],       // per CPU, host_processor_info deltas over the window
    "clusters": [
      { "id": 0, "name": "A55", "cpus": [0,1,2,3],
        "curKhz": 1209600, "minKhz": null, "maxKhz": null,
        "mode": "static",                   // unknown | off | pending | skipped | static | governor
        "governor": null,                   // name when mode = governor
        "capPercent": 40,                   // static cap of kern.sweet_cpufreq (patch 0190)
        "perfState": 3, "perfStates": 12,   // LUT index / entries (patch 0190)
        "loadPct": 28 },                    // mean of the cluster's CPUs
      { "id": 1, "name": "A75", "cpus": [4,5,6,7], "...": "..." }
    ]
  },
  "gpu": {
    "present": true,                        // the SweetAdreno630 IOService exists
    "source": "sysctl kern.sweet_gpu",      // | "SweetAdreno630 INFO" | "none"
    "state": "on",                          // on | slumber | off | lost | unknown | absent
    "level": 3, "levels": 8, "mhz": 427, "minMhz": 257, "maxMhz": 710, "busyPct": 41,
    "clients": 1                            // open SweetAdrenoUserClient instances
  },
  "renderer": {
    "mode": "fd630",                        // cpu | softpipe | fd630  (the truth, see below)
    "label": "FD630 (GPU)",                 // "CPU (CoreAnimation software)" | "softpipe" | "FD630 (GPU)"
    "requested": "1",                       // off | soft | 1   (boot-arg bglrender, else the marker)
    "requestedBy": "bootarg",               // bootarg | marker | none
    "backboarddPid": 87, "injected": true,  // injected: DYLD_INSERT_LIBRARIES with bergamota-gl in backboardd's environment
    "gpuClientOpen": true,                  // backboardd holds a SweetAdrenoUserClient
    "gpuClients": [ { "pid": 87, "name": "backboardd.real" } ],
    "registryRead": true,                   // false: no SweetAdreno630 service, so no client can exist
    "logLast": null                         // last line of /private/var/tmp/bgl-backboardd.log
  },
  "battery": {
    "present": true, "percent": 87, "charging": true, "external": true, "full": false,
    "source": "AC Power",                   // IOPS "Power Source State"
    "currentMa": 1020,                      // positive = charging, negative = discharging (kernel SweetBattery)
    "voltageMv": 4120
  },
  "thermal": { "batteryC": 31.5 },          // ONLY when measured; absent today (see below)
  "errors": ["kern.sweet_gpu: absent (GPU DCVS interface not in this kernel)"]
}
```

## How each field is derived

| Field | Source | Notes |
|---|---|---|
| CPU cur kHz, mode, cap | sysctl `kern.sweet_cpufreq`, a string: `domain0 A55 applied: state 3/12 1209600 kHz (requested 3, 40%); domain1 A75 ...` (xnu patch 0190, branch cpufreq); `domainN NAME off\|pending\|skipped` while not applied | Absent sysctl = `freqKnown:false`, `mode:"unknown"` ("fixed by bootloader"). Parser is tolerant: segments split at `;`/newline, prefix `domain\|cluster\|policy N`, first `<n> kHz` = current, `min`/`max` (kHz, or MHz below 10000), `gov`/`governor` word -> `mode:"governor"` |
| CPU load | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`, two samples 250 ms apart | cluster 0 = CPU 0-3 (A55), cluster 1 = CPU 4-7 (A75) |
| GPU | sysctl `kern.sweet_gpu` text (tolerant `key value`: `state on\|slumber\|off\|lost`, `level N/M`, `freq\|mhz\|clock N`, `busy\|load\|util N`, `min`/`max`), and with `--gpu-info` the INFO selector `0x70` of `SweetAdreno630` (`xnu/gpu-abi/sweet_adreno_abi.h`, flags bit0 ready, bit1 lost) | INFO only knows ready/lost, so it can give `on`/`off`/`lost` but not level, MHz, busy or slumber. `--gpu-info` opens (and closes) a user client every call, so Bergamota only passes it when Settings > Phone > "Read the GPU INFO selector" is on (default off) |
| Renderer | boot-arg `bglrender=` (`kern.bootargs`), else marker `/private/var/run/bglrender` (`MODE UUID [debug]`, honoured only when UUID = `kern.bootsessionuuid`, same rule as `bgl-launch`); backboardd pid from `KERN_PROC_ALL` (`backboardd` / `backboardd.real`); `injected` from its `KERN_PROCARGS2` environment; clients = children of the `SweetAdreno630` registry entry (service plane) with `IOUserClientCreator = "pid N, name"` | **Mode is the truth, not the request**: `fd630` only when backboardd itself holds a SweetAdrenoUserClient; `softpipe` only when the shim is injected into backboardd and `bgl-backboardd.log` shows softpipe; otherwise `cpu`. (Today the render server never creates an EAGLContext, so even `requested:"1", injected:true` reads `cpu`.) Reading the registry does not open a client |
| Battery | `IOPSCopyPowerSourcesInfo` (as `sweetps`: Current Capacity, Is Charging, Power Source State) plus the `IOPMPowerSource` registry entry (`InstantAmperage`/`Amperage`, `Voltage`, `ExternalConnected`, `FullyCharged`) | mA outside +-20000 is dropped (null) |
| Thermal | none | The SoC temperature is not exposed by the kernel. The battery `Temperature` property is a placeholder (2500, `SweetBatteryTemperatureEstimated`), so `thermal` is omitted unless that flag is gone |

## Bergamota

- Polling: `PhoneMonitor.refreshMetrics()` on its own 2 s loop (not the detection loop, never on the main thread), `ssh root@phone /usr/local/bin/sweetmetrics`, 6 s timeout. A missing tool (exit 127) is retried every 15 s with a message; samples are cleared when iOS goes away.
- UI: Dashboard "Performance" card (cluster bars with load and mode, GPU bar/state, renderer badge, battery draw, sparklines of CPU kHz per cluster, GPU MHz and battery mA over the last 2 minutes, a list of what is still waiting on the kernel); Control Plane strip below the PHONE/BATTERY/LAST BOOT tiles (shown while iOS is up).
- `status.json` `phone.metrics` = the object above plus `fetched` (ISO time at the Mac); `phone.metricsError` when the last poll failed. CLI: `scripts/bergamota metrics [--json]`.
- Tests: `apps/Bergamota/Tests/run-metrics-tests.sh` (Swift parser on recorded samples in `Tests/metrics-samples/`), `tools/sweetnet/test-sweetmetrics.sh` (C text parsers).

## Waiting on the kernel

- **cpufreq**: `kern.sweet_cpufreq` of patch 0190 gives the current state and the static cap only. Still missing: min/max kHz and a governor name (the card says "capped at 40%"/"unknown"); the parser already accepts `min`/`max`/`governor` words, so a governor build needs no tool change if it prints them in the same string. If it moves to another format, only `parse_cpufreq()` changes.
- **GPU DCVS**: the gpu-kernel ABI (`sweet_adreno_abi.h`, v1) has no level, MHz, busy or slumber (`SWEET_MSM_PARAM_MAX_FREQ` is the 710 MHz limit only). Until `kern.sweet_gpu` (or an agreed property) exists the GPU row shows the state at most and "waiting on the GPU DCVS interface".
- **SoC temperature**: nothing exposed.
- **Renderer**: needs nothing from the kernel; it becomes `fd630` the moment backboardd opens the GPU client, and `softpipe` once the render server uses the shim.
