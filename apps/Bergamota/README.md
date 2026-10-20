# Bergamota

A native macOS (14+) SwiftUI control panel for the iOS-on-Poco-F1 project: phone status, live kernel log, CI runs, and a boot queue that schedules `fastboot boot`.
No third-party packages. The app is **not sandboxed** (it runs `fastboot`, `adb`, `ssh`, `gh` and `python3`) and is ad-hoc signed ("Sign to Run Locally").

## Build

```sh
open apps/Bergamota/Bergamota.xcodeproj          # then Run in Xcode
# or
cd apps/Bergamota && xcodebuild -scheme Bergamota -configuration Debug build
```

The project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen && xcodegen generate`); both `project.yml` and the generated `Bergamota.xcodeproj` are committed. The app icon is produced by `swift scripts/make-icon.swift`.

## Usage

Sidebar sections:

- **Dashboard**: polls every 2 s and shows one of fastboot (`fastboot devices`), OrangeFox/recovery (`adb devices`), iOS (USB Ethernet MAC `02:00:5e:77:ee:01` up in `ifconfig -a`, ping of the phone IP, TCP 22 open), Android (adb `device`), or offline. When iOS is up it SSHes as `root@192.168.7.2` (`BatchMode=yes`, `ConnectTimeout=3`, your normal `known_hosts`) every ~10 s for `uname -a`, `kern.boottime` and `/usr/local/bin/sweetps` (battery %, charging, power source). It also shows the Mac's `net.inet.ip.forwarding` (read only; enable NAT with `tools/sweet-mac-nat.sh`).
- **Live Log**: listens on UDP 5140 for the phone's kernel console (same stream as `tools/sweet-usbnet.sh`; quit that script first, only one listener can bind). Ring buffer of 300k lines, UI updates batched every 100 ms, search box, filter chips (SWEET USB / GPU / WLAN / FB / CRASH), follow/pause, copy. "Record to logs/" appends every incoming line to `logs/usb-<timestamp>.txt` in the repo; "Save buffer" dumps the whole buffer there.
- **CI**: `gh run list` for `xnu.yml` on `main`, `ios18`, `ci-cache` (status, branch, sha, age, duration). "Download kernel" runs `gh run download <id> -n xnu-kernel -D xnu/out-<branch>-<id>` in the repo (needs `gh auth login`).
- **Boot Queue**
  - *Build*: pick a kernel (`xnu/out-*/kernel.development.sweet`), an ADT (`shim/out/*.adt`, default `beryllium-hi-3x.adt`), a cmdline (presets in `~/Library/Application Support/Bergamota/presets.json`, seeded with "default @3x", "bluetooth test", "ios18 poc") and an image name. It runs `tools/mkpayload.py`, then `BOARD=beryllium ./build.sh` in `shim/`, then copies `shim/out/shim-boot.img` to `shim/out/shim-boot-<name>.img`, streaming the output.
  - *Images*: lists `shim/out/*.img`; add any to the queue.
  - *Queue*: press **Start** to arm. When the phone is in fastboot (seen on two consecutive polls) the app sends exactly **one** `fastboot boot <img>`, records the result and time, and will not send again until the phone has left fastboot (a failed send leaves ABL hung; re-enter fastboot yourself, there is never an automatic retry). Optional toggle (off by default): when the phone is in OrangeFox, run `adb reboot bootloader` once first. The queue disarms itself when it is empty. Optional notifications when a boot is sent and when iOS comes up.
- **Settings** (also Cmd+,): repo path (default `/Users/zesmoi/git/iAndroid/ios-beryllium`), phone IP, GitHub repo, and tool paths (`fastboot`, `adb`, `gh`, `python3`, `ssh`; empty means resolve via `PATH` plus `/opt/homebrew/bin` and `/usr/local/bin`).

## Remote control (file-based API, no network)

Bergamota watches `~/Library/Application Support/Bergamota/inbox/` for `*.json` requests (polled every second), processes them and moves each to `inbox/done/` (with a `result` field) or `inbox/failed/` (with an `error` field). Kinds:

```json
{"kind":"enqueue","image":"shim/out/x.img","label":"...","arm":true}
{"kind":"build","name":"N","kernel":"xnu/out-.../kernel.development.sweet","adt":"shim/out/beryllium-hi-3x.adt","preset":"default @3x","enqueue":true,"arm":true}
{"kind":"build","name":"N","kernel":"...","adt":"...","cmdline":"debug=0xc ..."}
{"kind":"orangefox_reboot","enabled":true}
{"kind":"stop"}
```

Paths are absolute or repo-relative; images and ADTs must live under `shim/out/` (`.img` / `.adt`), kernels under `xnu/`. `"arm": true` only arms the queue when Settings > "Allow remote requests to start the queue" is on (default on; the Boot Queue header shows a "remote control on" badge). Otherwise items are added and you press Start. The one-`fastboot boot`-per-fastboot-appearance rule applies unchanged.

`status.json` (same folder) is rewritten atomically on every state change and at least every 5 s: `phone` (state, `ios` battery/charging/kernel/uptime when known), `queue` (armed, items with `state` pending|waiting|sent|failed, `sentAt`, `result`), `liveLog` (listening, `savingTo`), `build`.

CLI (`scripts/bergamota`, bash + python3):

```sh
scripts/bergamota enqueue shim/out/shim-boot-0130.img [--label L] [--no-arm] [--wait]
scripts/bergamota build --name N --kernel K --adt A (--preset P | --cmdline C) [--no-enqueue] [--no-arm] [--wait]
scripts/bergamota orangefox on|off
scripts/bergamota stop
scripts/bergamota status
```

## Notes

- **Local Network permission.** Without it macOS hides every MAC address from the app (`ifconfig` shows `02:00:00:00:00:00`) and blocks connections to the phone ("No route to host"). Bergamota declares `NSLocalNetworkUsageDescription` so macOS asks on first run; allow it under System Settings > Privacy & Security > Local Network. Until then the USB Ethernet interface is found by subnet (the Mac side `192.168.7.1`) and the Dashboard shows a warning. A debug trace of each detection change is written to `~/Library/Logs/Bergamota.log`.
- The live log is saved automatically to `logs/usb-<timestamp>.txt` (Settings > Live log; turning Record off in the Live Log pauses it until the next launch).
- The phone has no `sysctl`, so uptime is shown only if `ps -o etime= -p 1` is sane; the Dashboard also shows when Bergamota first saw iOS up.

The app only ever runs `fastboot devices` and `fastboot boot`, plus `adb devices` and (opt-in) `adb reboot bootloader`. It never flashes, erases or sends `oem` commands.
