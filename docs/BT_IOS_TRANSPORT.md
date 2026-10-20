# How iOS 16.7.16 (iPhone X, iPhone10,3 / D22AP) userland talks to its Bluetooth controller, and what our kernel must provide

Goal: expose the Qualcomm WCN3990 (already driven by our kernel over QUP SE6 UART with raw HCI, `sweetwlan=2`)
to the stock `bluetoothd`. Read-only research; nothing was run on the phone.

Tags: **[V]** = verified by me in the artifacts below; **[U]** = unverified (inference, or needs a phone experiment).

Artifacts used (all from the 20H392 IPSW in `research/ipsw-x`, no download): `usr/sbin/bluetoothd`, `usr/sbin/BlueTool`
and `System/Library/LaunchDaemons/*.plist` from rootfs dmg 087-86698-044 (mounted read-only, then detached); the
kernelcache `kernelcache.release.iphone10b` (decompressed, `__PRELINK_INFO` personalities parsed, kext code
disassembled with `ipsw macho disass`); the stock D22AP ADT `research/ipsw-x/d22ap.adt`; IDA (idalib) on both daemons.
Public web search found nothing usable on this topic (only 2010-era Apple TV remarks that BlueTool talks to a
Broadcom chip) so everything below comes from the binaries. Scratch copies live in the session scratchpad, not in the repo.

## 0. One-paragraph answer

On A11 the Bluetooth controller is a **plain UART HCI device (H4 framing)**, not PCIe and not an IOKit user client.
bluetoothd and BlueTool reach it through a **kernel control socket** (`socket(PF_SYSTEM, SOCK_STREAM, SYSPROTO_CONTROL)`,
`CTLIOCGINFO` on the name `com.apple.uart.sk.bluetooth` for bluetoothd or `com.apple.uart.bluetooth` for BlueTool,
`connect`, termios via get/setsockopt). The kernel side is Apple's closed `AppleSamsungSerial` + `AppleOnboardSerial`
kexts; our source-built XNU has neither, so **we must supply the control socket ourselves** (plus an ADT node named
`bluetooth`). IOKit matching matters only for reading ADT properties (`local-mac-address`, `transport-encoding`,
`transport-speed`) from a registry entry named `bluetooth`. The chip boot sequence (power pulse, patchram) lives in
**BlueTool's built-in Broadcom scripts**, run on bluetoothd's request over XPC; they will fail on a Qualcomm chip, and
the supported override mechanism (`/etc/bluetool/<hash>.boot.script`) is gated on `ReleaseType` being Internal/Vendor, so
the robust plan is to do power/firmware in the kernel (as we already do) and make BlueTool a no-op stub.

## 1. The transport on A11

### 1.1 Stock device tree (D22AP ADT) [V]

```
/arm-io/uart1    compatible "uart-1,samsung", dma-channels, dma-types, function-rts/-tx, uart-version 1
/arm-io/uart1/bluetooth
    compatible        "bluetooth,n88"
    device_type       "bluetooth"
    transport-encoding 03 00 00 00      (u32 LE = 3)
    transport-speed    c0 c6 2d 00      (u32 LE = 3,000,000 baud)
    vendor-id 0x05ac, product-id 0x12a0, supported-profiles 0x2ffb, coex 2, voice-record
    local-mac-address  template string "macaddr/btaddr,syscfg/BMac/6,zeroes/6" (iBoot replaces it with 6 bytes)
    function-bt_wake   (GPIO),  function-power_enable (PMU)      <-- there is NO function-bt_reset on this board
    bluetooth-tx-calibration / -rx-calibration / -taurus-calibration = syscfg paths
/arm-io/uart4/wlan   compatible "wlan-pcie-uart,bcm4357 ..."   (Wi-Fi is PCIe; the uart4 parent is only a carrier)
```

So BT lives on its own UART (uart1, with DMA and RTS/CTS), as a child node called exactly `bluetooth`.
Our synthetic beryllium ADT (`tools/mkadt.py`) has **no** `bluetooth` node and no uart nodes: arm-io has only
gic/wdt/disp0 [V, parsed `shim/out/beryllium-hi-2x.adt`]; only `/chosen mac-address-bluetooth0` exists, and bluetoothd
does not read that (see 2.1).

### 1.2 Which transport bluetoothd selects [V]

bluetoothd (`sub_100156160`) picks the HCI transport this way:

1. env `BT_HCI_TRANSPORT` = `TRANSPORT[:DRIVER[:DEVICE]]` if set (table of 9 transports, 6 drivers; driver name seen: `POSIX`; transport name seen: `H4BC`).
2. else the u32 `transport-encoding` read from the ADT (`IOServiceNameMatching("marconi-bt")`, falling back to `"bluetooth"`,
   `IORegistryEntrySearchCFProperty(.., "IODeviceTree", "transport-encoding", recursive)`):
   `0` USB, `1` H4, `2` H4DS, `3` **H4BC**, `4` H5, `5` BCSP (unsupported, falls to USB), `6` APPLEBT (IOKit user clients
   `AppleBTHci`/`AppleBTMgmt`), `7` PCIe (Skywalk or not, via `AppleConvergedTransport.dylib`), anything else USB.
   Log lines: "HCI Transport is set to H4BC", "DeviceTree transport = 0x%08x".

The iPhone X ADT says `3`, so stock iPhone X uses **H4BC over UART**. Transports 6 and 7 (the `AppleBluetoothModule` /
`AppleConvergedIPCOLYBTControl` path our earlier plan assumed) are used by later devices, not A11:
neither of those two names is a kext in the iPhone10,3 kernelcache (they appear only as strings inside the
AppleBluetoothDebug kext), and the ADT value is 3 [V]. **Correction for `docs/WIFI_BT_PLAN.md` section 4.4.**

### 1.3 How the UART is opened [V]

- bluetoothd, `POSIX` driver open (`sub_100066BDC`, called with mode 0 for H4BC): `socket(32 /*PF_SYSTEM*/, 1 /*SOCK_STREAM*/, 2 /*SYSPROTO_CONTROL*/)`,
  `ioctl(CTLIOCGINFO = 0xC0644E03)` with `ctl_name = "com.apple.uart.sk.bluetooth"` (the default when no device string is given),
  `connect` with `sockaddr_ctl{sc_len 0x20, AF_SYSTEM, ss_sysaddr 2, sc_id, sc_unit 0}`. For the `.sk.` name it then does the
  **Skywalk channel** dance: `setsockopt(level 2, IOAOSSKYSETCHANNELSPEC)`, `getsockopt(.. IOAOSSKYGETCHANNELUUID)` ->
  `os_channel_create`, two kqueues on the channel fd (entitlement `com.apple.private.skywalk.register-user-pipe` is in bluetoothd).
  For any other ctl name it skips the channel and reads/writes the socket as a plain byte stream.
  If the device string is `NAME,SPEED`, NAME is the ctl name and SPEED the baud; speed otherwise comes from env `BT_BAUDRATE`,
  then ADT `transport-speed`, else 2,400,000.
- termios is passed via `getsockopt/setsockopt(sock, SYSPROTO_CONTROL, 0x40487413 /*TIOCGETA*/ / 0x80487414 /*TIOCSETA*/, struct termios 72 B)`:
  `cfmakeraw`, `cfsetspeed(speed)`, mode 0 sets `c_iflag |= 4`, `c_cflag = 0x38B00` (8 data bits, CREAD, CCTS_OFLOW|CRTS_IFLOW =
  hardware flow control); modes 1/2 set other flags.
- BlueTool `device -D` (`sub_10001CA84`/`sub_10001DA38`): same socket sequence but with name `$BT_UART` or default
  **`com.apple.uart.bluetooth`** (non-Skywalk), same termios ioctls, speed 115200 unless `-s`/`-S` (ADT speed, default 2.4 Mbaud).
  BlueTool's transport is chosen the same way from `transport-encoding` (`6` AppleBT, `7` PCIe, everything else = this UART path).
  BlueTool's H4 reader parses only HCI events (and data headers), "ACL/SCO DATA?!?!? What do you think I am?".
- The device-node check in bluetoothd's `main` [V, disasm of `start`]: it first finds the local address
  (env `BT_DEVICE_ADDRESS`, else `local-mac-address` of the registry entry `marconi-bt` or `bluetooth`, else
  `kern.bootargs` `wlan.debug.generate-mac` / `wlan.factory&4` random). Then, if the address is non-zero, it requires **one of**
  `access("/dev/cu.bluetooth")`, `access("/dev/uart.bluetooth")` or an IORegistry service named `marconi-bt`/`bluetooth`;
  otherwise it prints "No serial port found" / "No bluetooth on this device." and `errx(0, ...)`.
  **Exit status 0 plus `KeepAlive.SuccessfulExit=false` in com.apple.bluetoothd.plist means launchd does not restart it.**
  This is almost certainly what happens on our boots today (the NOTES line "bluetoothd runs" is from process listings;
  [U] confirm from the unified log).
- H4BC also opens `/dev/btwake` (`sub_100066B24`); failure only logs "Unable to turn on BT)_WAKE signal" and continues [V].

### 1.4 What stock XNU/kexts publish for this (iPhone10,3 kernelcache) [V strings/personalities, disasm for gating]

| Piece | What it does |
|---|---|
| `AppleSamsungSerial` (`IONameMatch uart-1,samsung`, provider AppleARMIODevice) | the A11 UART driver; publishes the `AppleOnboardSerialSync` provider the BSD client attaches to |
| `AppleOnboardSerial` -> `AppleOnboardSerialBSDClient` (provider class `AppleOnboardSerialSync`, `IOResourceMatch IOBSD`) | makes the devfs node `uart.<IOTTYBaseName><IOTTYSuffix>` (so `/dev/uart.bluetooth`), the kernel control `com.apple.uart.<name>` and, unless disabled, `com.apple.uart.sk.<name>` (Skywalk). The names come from the `IOTTYBaseName` / `IOTTYSuffix` properties of the bus-interface nub made for the **first child ADT node** of the uart ("more than one subnode in device tree! Ignoring all but the first"). Properties/boot-args consulted: ADT `no-control-socket`, boot-arg `uart.skywalk`, ADT `boot-console`, `uart.panic_on_delay`. [U: exact gating between the plain and the `.sk.` socket; I read the two creation paths but could not settle which one is the default without the full function]. |
| `AppleBluetooth` kext, class **`BTReset`**, `IONameMatch bluetooth`, provider `IOService` | reads ADT `function-bt_reset`, `function-bt_wake`, `function-power_enable`, `function-bootstrap_lock`, `bootstrap-delay`; **each is optional** (null-checked); creates char devices `/dev/btreset`, `/dev/btwake`, `/dev/btpoweroff` only for the functions present. Semantics from log strings: open `btreset` = assert RESET, close = deassert; open `btwake` = assert WAKE, close = deassert; open `btpoweroff` = **deassert REG_ON (chip off)**, close = assert REG_ON (chip on). boot-arg `btreset-verbose`. |
| `AppleBluetoothDebug` (`BTDebug`, `IONameMatch bluetooth`, user client `BTDebugUserClient`) | logging/capture helper; no evidence bluetoothd needs it to power the stack [U] |
| `AppleBluetoothModule`, `AppleConvergedIPCOLYBTControl` | **not present as kexts on A11** (see 1.2) |

## 2. What the kernel must provide

### 2.1 Mandatory for bluetoothd to get as far as opening the transport [V unless noted]

1. An IORegistry entry named **`bluetooth`** (IOService name; `IOServiceNameMatching("bluetooth")`) that is also in the
   IODeviceTree plane, carrying:
   - `local-mac-address` (6 raw bytes, not all zero). This is what bluetoothd (`FindLocalMacAddress`) and BlueTool read; the
     `/chosen mac-address-bluetooth0` we already set is **not** consulted by them (it feeds MobileGestalt). Alternative without
     ADT: env `BT_DEVICE_ADDRESS=aa:bb:cc:dd:ee:ff` in bluetoothd's launchd job.
   - `transport-encoding` (u32). Not strictly required for bluetoothd if `BT_HCI_TRANSPORT` is set, but without it the default is
     transport 8 -> "unknown - setting to USB", which will wait for a USB controller. Use 3 (H4BC) or 1 (H4).
   - `transport-speed` (u32 baud), optional (default 2.4 Mbaud, env `BT_BAUDRATE` overrides).
   - nice to have: `device_type = bluetooth`, `compatible`, `vendor-id`/`product-id` (sent in Device ID records; bluetoothd logs
     "Sending Device ID with vendor/product/chip"), `supported-profiles`, `coex`.
   Because `SweetPlatformExpert::createNubs` only publishes `gic` under `arm-io` today, either add `('bluetooth')` to its exclusive
   list (and add the node to the ADT under `arm-io`) or create the nub from our BT driver. The stock position is
   `/arm-io/uart1/bluetooth`; the parent is irrelevant for userland because the lookups are by name and the properties sit on the node itself.
2. **A kernel control** named `com.apple.uart.bluetooth` registered with `CTL_FLAG_REG_SOCK_STREAM`, **not** `CTL_FLAG_PRIVILEGED`
   (bluetoothd runs as user `mobile`; BlueTool too: `UserName mobile` in both plists), dynamic unit (`sc_unit 0`).
   It must support `ctl_getopt/ctl_setopt` for `0x40487413`/`0x80487414` (termios, 72 bytes: map `c_ospeed`/`c_ispeed` and `CRTSCTS`
   to the UART), `ctl_send` (userland writes -> UART TX) and `ctl_enqueuedata` (UART RX -> socket), with H4 packet boundaries
   not required (it is a SOCK_STREAM byte pipe; both userland readers resynchronise on the H4 type byte).
3. A path-existence hit for one of `/dev/uart.bluetooth` or `/dev/cu.bluetooth` is **not required** if the ADT node `bluetooth`
   exists (the third alternative in 1.3 satisfies `main`), but creating a tty-like `cu.bluetooth`/`uart.bluetooth` char device costs little
   and makes the intent explicit. Userland never opened them in the code I read (only `access()`); [U] `ioreg`/other tools might.
4. `/dev/btwake` (any char device whose `open` is a no-op or toggles a GPIO). bluetoothd tolerates absence.
5. Skywalk path (stock default): **not needed** if bluetoothd is forced onto the plain control socket with
   `BT_HCI_TRANSPORT=H4BC:POSIX:com.apple.uart.bluetooth,3000000` (format: transport:driver:device-string; the device string is the
   ctl name, optionally `,baud`). [U] This exact string syntax: I verified the tokenisation (`strtok(":")` twice, 3rd token stored
   as the driver argument, then `strtok(",")` inside the open function), and the transport/driver names `H4BC` and `POSIX`, not a live run.
   Implementing `com.apple.uart.sk.bluetooth` instead would mean a Skywalk nexus provider with `IOAOSSKYSETCHANNELSPEC` /
   `IOAOSSKYGETCHANNELUUID` socket options and `os_channel` rings: avoid.

### 2.2 What does NOT need to exist on A11

- No IOKit user client, no `AppleBTHci`/`AppleBTMgmt`/`AppleBluetoothModuleUserClient`/`AppleConvergedIPC*` (transport 6/7 only) [V].
- No `AppleSerialShim`: it matches only `uart0..8` with `boot-console` (the debug console) and `dockchannel-uart` [V].
- `/dev/btreset`, `/dev/btpoweroff`: optional. If `/dev/btpoweroff` does not exist, BlueTool's `power on|off` and `reset` commands
  **silently succeed without doing anything** on the UART path (`access("/dev/btpoweroff")` guard) [V]. That is what we want
  because the kernel owns power.

### 2.3 Broadcom-specific work and how to bypass it

bluetoothd does not itself patch the chip. On start it asks BlueTool over XPC [V]:

- Mach service `com.apple.BlueTool` (launchd job `com.apple.BlueTool`: `/usr/sbin/BlueTool -R`, user `mobile`, on demand, `EnablePressuredExit`).
- Messages: dictionary `kMsgId` in {`RunBuiltinScript`, `RunExternalScript`, `RunCommand`}, `kMsgArgs` {`script`: `boot` | `init` | `deepsleep`, `btaddress`},
  reply keys `result` (int, 0 = ok), `firmware`, `output`, `manufacturer`, `btaddress`.
  bluetoothd logs "Booting chipset" (`boot`), "Powering on chipset" (`init`), and "BlueTool failed to run %s script with result %ld".
- BlueTool computes `platform` = hex SHA-1 `ProductHash` (MobileGestalt; overridable by boot-args `wifibt-external=0x4425/4433/4434 14e4`),
  `chip` from the Wi-Fi bus driver's `HWIdentifiers` (`AppleBCMWLANBusInterfacePCIe`, "No AppleBCMWLANBusInterface service. Retrying..."),
  `vendor` from MG `WifiVendor`, and looks up a firmware table (BCM4350C5, BCM43452A2/BCM4357B1 `.hcd` under `/usr/share/firmware/bluetooth/`,
  `aci_*.hcd`, BCM4378 PCIe `.bin`). No match: it retries about 9 times at 0.5 s ("No WiFi - Iteration %d") then
  returns **13** (or 10) = "Error - no firmware for this platform".
- The built-in BCM scripts [V strings]: `wake on; msleep 100; hci reset; bcm -B; msleep 200; bcm -W` (patchram `.hcd`), `device -s 115200`,
  `bcm -A/-N/-Q` (BD address from device tree, name, MSF/calibration from ADT `syscfg`), `device -D -S` (reopen at ADT speed),
  `wake off`, `bcm -b 1500000`, `bcm -x`, ... These use Broadcom vendor commands (0xFC18 Write RAM etc., 0xFC45 baud, 0xFC01 BDADDR);
  a WCN3990 returns Unknown Command or hangs the script. Expect result codes 5/10/13/15.
- **Override scripts**: BlueTool will read `/etc/bluetool/<MG "/YYygAofPDbhrwToVsXdeA" model>.<boot|init|deepsleep>.script` and
  `/etc/bluetool/<ProductHash>.<boot|init|deepsleep>.script` (one BlueTool command per line) and skip the built-ins, **but only if
  MobileGestalt `ReleaseType` equals `Vendor` or `Internal`** (`runCommandForCurrentConfig`, `sub_100015FA4`). On a normal image the check fails and
  the override is ignored. [U] what our image reports for `ReleaseType`; BlueTool logs `_isVendorInstall = %d and _isInternalInstall = %d`
  every run, so the first BlueTool run answers it.
- The `HWRepair`/`BlueToolBTResult` preference (`sub_100272034`): only makes bluetoothd **replace a non-zero BlueTool result** with a
  configured value ("Using override value (%d) for runBlueTool BTResult"); it cannot turn a failure into success, so it is not a bypass [V].
  Failure handling: repeated failures (11 inside 5 s windows) set a "give up" flag; a single failure is surfaced as "Power on failed" [V/U].
- A defaults/plist route to disable BlueTool does **not** exist in what I read. The workable bypasses, in order of preference:
  1. **Stub `/usr/sbin/BlueTool`** (we control the root image, `tools/sweet-retweak-image.sh`; unsigned/ad-hoc binaries already run: dropbear,
     dash, toybox): a tiny C program that registers the Mach service `com.apple.BlueTool` and answers `RunBuiltinScript`/`RunExternalScript`/`RunCommand`
     with `result = 0`. It also keeps the stock binary usable for manual experiments if we install it under another path (`BlueTool.real`).
  2. A `ProductHash.*.script` override (needs `ReleaseType` Internal/Vendor, risky side effects elsewhere; only if the log shows it is already Internal).
  3. Fake `AppleBCMWLANBusInterface` + `HWIdentifiers` so a built-in row matches, then provide `.hcd` files that are really no-op: not recommended.

### 2.4 What bluetoothd's own stack may still ask the controller [U, needs the phone]

After the transport is up bluetoothd runs its Apple stack: `HCI_Reset`, read local version/features, event masks, LE setup, the
Device ID record (vendor/product/chip), and many Apple "ACI"/Olympic vendor commands (`aci_vsc.c`: LE meta, zone, IRK, scan filter ...).
On a Qualcomm chip those VSCs get "Unknown HCI Command"; whether bluetoothd treats that as fatal for each one is not decidable
statically. The kernel can make this robust by answering unknown OGF 0x3F commands itself (see 3.3).

## 3. Recommended design

### 3.1 Decision: kernel control socket + BSD shims, not an IOKit transport stand-in

On A11 nothing in userland uses IOKit for the data path, so an IOKit HCI user client would be dead code. The cheapest faithful
interface is exactly what Apple's UART path presents to userland: a **kernel control socket**. Keep everything chip-specific in the kernel
(power, rampatch/NVM download from `crbtfw21.tlv`/`crnv21.bin`, baud change, in-band-sleep, BD address) and expose a **clean H4 byte stream**.

### 3.2 Exact names and properties to publish

Device tree (extend `tools/mkadt.py`, board `beryllium`; keep it out of the sweet ADT):

```
/device-tree/arm-io/bluetooth          (or /arm-io/uart-bt/bluetooth)
    name                "bluetooth"
    device_type         "bluetooth"
    compatible          "bluetooth,wcn3990"          (any; ours)
    local-mac-address   02 00 5e 77 b0 01            (6 bytes; same synthetic value as chosen mac-address-bluetooth0)
    transport-encoding  03 00 00 00                  (H4BC, as stock; use 01 for plain H4 if H4BC misbehaves)
    transport-speed     c0 c6 2d 00                  (3,000,000; must equal the baud the kernel left the chip at)
    vendor-id           ac 05 00 00                  (0x05ac, optional)
    product-id          a0 12 00 00                  (optional)
    AAPL,phandle        (unique)
    (no function-* properties: no kernel BTReset personality exists to consume them)
```

Kernel (new file next to `bsd/dev/beryllium_wlan.c`, registered from the BT stage once the chip is up):

| What | Name / value |
|---|---|
| kernel control | `ctl_register("com.apple.uart.bluetooth", flags = CTL_FLAG_REG_SOCK_STREAM, no PRIVILEGED, sendsize/recvsize ~ 64 KiB)` |
| socket options on that control | `0x40487413` get termios, `0x80487414` set termios (apply `c_ospeed` and `CRTSCTS` to SE6) |
| devfs nodes | `/dev/uart.bluetooth`, `/dev/cu.bluetooth` (tty-like char devices; may share one cdevsw whose open returns EBUSY while the ctl is connected), `/dev/btwake` (no-op open/close) |
| optional | `/dev/btpoweroff`, `/dev/btreset` (leave out: BlueTool treats absence as "kernel manages it") |
| IOKit | registry entry named `bluetooth` with the ADT properties above, published by `SweetPlatformExpert` (add `bluetooth` to the arm-io `createNubs` list) |
| launchd (bluetoothd job only) | `EnvironmentVariables`: `BT_HCI_TRANSPORT=H4BC:POSIX:com.apple.uart.bluetooth,3000000`, optionally `BT_DEVICE_ADDRESS`, `BT_BAUDRATE=3000000` |
| BlueTool | stub (2.3, option 1) |

Edit `com.apple.bluetoothd.plist` with the existing `tools/patch-launchd-plist.py` mechanism (the launchd cache is the thing that is actually read; NOTES
use `launchd_unsecure_cache=1`).

### 3.3 Behaviour of the kernel UART layer (what keeps stock bluetoothd alive)

- One consumer at a time: both bluetoothd (stack) and BlueTool (scripts) connect to the same control; with the stub BlueTool only bluetoothd does.
- RX path: UART -> HCI framing parser in the kernel (type byte 0x02/0x04/0x05 + lengths) -> `ctl_enqueuedata`. Drop/handle QCA in-band-sleep bytes
  (`0xFD` sleep ind, `0xFC` wake ind, `0xFE` wake ack, Linux `hci_qca.c` IBS) **in the kernel**; stray bytes would trigger bluetoothd's
  "unknown packet type received" / "garbage received when searching for new packet identifier" resync paths. Simplest: keep IBS disabled
  in the NVM/boot sequence (`sweetbt` boot-args from patch 0124) and keep the line awake.
- TX path: `ctl_send` -> UART with RTS/CTS honoured (`CRTSCTS` set by bluetoothd).
- Vendor-command shim [U, only if the phone shows a fatal VSC]: parse HCI commands from userland and answer selected OGF 0x3F opcodes locally with a
  Command Complete (status 0x00 or 0x01) instead of forwarding. Make it a small table so it is data, not code.
- Connect/disconnect: on `connect` do nothing destructive (the chip is already booted by the kernel); on the last `disconnect` do **not** power the chip off.
  `HCI_Reset` from bluetoothd must be forwarded to the controller as is.
- Kernel brings the chip up **before** userland runs (boot stage) and leaves rails on (patch 0117); the first userland `HCI_Reset` at the
  post-firmware baud is the integration test.

### 3.4 Alternatives considered

| Option | Verdict |
|---|---|
| IOKit `AppleBTHci`-style user client (transport 6) | Needs the exact method selectors of `AppleBTHciUC`/`AppleBTMgmtUC` (not in our kernelcache: no kext). Large unknown surface, no benefit: reject. |
| PCIe/Skywalk stand-in (transport 7) | Requires Skywalk nexus + `AppleConvergedTransport.dylib` protocol: reject. |
| Plain devfs tty only (no ctl) | bluetoothd and BlueTool never open `/dev/*.bluetooth`; they require the control socket: insufficient. |
| `com.apple.uart.sk.bluetooth` with Skywalk channel | Stock default, but needs IOAOSSKY* socket options and nexus rings: avoid; use the plain name via `BT_HCI_TRANSPORT`. |
| Userland relay daemon + `DYLD_INSERT_LIBRARIES` interposer on `connect/ioctl` | bluetoothd is a platform binary (hardened); fragile; only a fallback if the kernel ctl approach is blocked by sandbox/AMFI. |

## 4. Risks

1. **`BT_HCI_TRANSPORT` syntax is verified only by reading code** [U]; the failure mode is "Searching for transport ... could not be matched" in the log: one boot per attempt.
2. **Stack assumptions about Broadcom/Apple chips**: ACI vendor commands, Device ID `chip`, Apple-specific LE features. Possible hard failures: bluetoothd asserts or loops "Power on failed" until the "give up" flag latches. Mitigation: VSC shim (3.3) and `bluetoothd` crash logs.
3. **BlueTool stub fidelity**: unknown extra reply keys bluetoothd may require (`firmware`, `btaddress`, `manufacturer` appear as keys in BlueTool); if a missing key is fatal, add them. The stock binary is kept for comparison.
4. **Sandbox/AMFI**: bluetoothd seatbelt profile `BTServer` and BlueTool profile `BlueTool` are applied by the real Sandbox kext; our stand-in (op 5 earlier) may deny `system-socket`/`network-outbound (control)` for the uart ctl. First failure would be `connect(...) failed (error = Operation not permitted)`.
5. **Control not non-privileged** or `SOCK_STREAM` flag missing -> `socket`/`connect` errors EPROTONOSUPPORT/EPERM.
6. **RX ordering/loss at 3 Mbaud**: current polled UART in `beryllium_wlan.c` is boot-stage code with a 512-byte `rxq`; a ctl backend needs an interrupt- or thread-driven RX with a ring (>= 2 KiB) or bluetoothd will lose events and wedge on "timed out waiting for reset response".
7. **Both firmware download and userland share the UART**: the kernel must stop its own polling before enabling the ctl, and must not re-run `HCI_Reset`/power-pulse later.
8. **ReleaseType unknown** (override script route): do not rely on it.
9. **Wake/coex GPIOs** (`function-bt_wake`, `coex`): not wired on our board; harmless to skip, but Wi-Fi coexistence (later) may want them.
10. `KeepAlive.SuccessfulExit=false` plus "No bluetooth on this device" exit(0) means a missing prerequisite looks like a clean exit: always check the log, not just `launchctl list`.
11. Any change to `com.apple.bluetoothd.plist` is a root-image change (needs retweak/reflash, or the launchd cache patch used for other jobs). Prefer experiments that do not need it first (E3 below runs BlueTool by hand).

## 5. Order of experiments (SSH root, dash/toybox, can push files and set defaults via cfprefsd)

Each step is read-only or reversible; stop at the first surprise.

- **E0 (no change): baseline.** Pull the bluetoothd/BlueTool log (`tools/sweet-ios-pull.sh`, subsystem `com.apple.bluetooth`, process bluetoothd) and look for
  "No bluetooth on this device", "No valid serial port found", "Unable to match bluetooth service in device tree". Also `ps`/`launchctl list | grep -i bluetooth`.
  Expected [U]: bluetoothd already exited with status 0.
- **E1 (kernel/ADT only, no root change): publish `bluetooth` + ctl.** Add the ADT node and the control socket (3.2) to a kernel that still runs the `sweetwlan=2` stage. On the phone, write a 40-line C
  (or reuse `tools/sweetnet`-style toolchain) test client that does exactly the BlueTool sequence: `socket(32,1,2)`, `CTLIOCGINFO "com.apple.uart.bluetooth"`, `connect`, TIOCSETA 3 Mbaud, write `01 03 0c 00`, read `04 0e 04 01 03 0c 00`. This validates the ctl, flow control, speed and RX with no Apple code in the loop.
- **E2: stock BlueTool by hand as the second client.** `BT_UART=com.apple.uart.bluetooth BT_BAUDRATE=3000000 /usr/sbin/BlueTool -c 'device -D; hci reset; hci info'`
  (`device -D` opens the control, `hci info` prints manufacturer/LMP version; prerequisites: ADT `bluetooth` node as above). Expect "Radio Manufacturer" = Qualcomm (we already saw 0x001d). If this works, the whole kernel interface is proven against Apple's own H4 reader.
  Also run `BlueTool -c 'power on'` once and confirm it prints nothing harmful and that `/dev/btpoweroff` is absent (no-op path).
- **E3: bluetoothd by hand with the env vars, no plist edit.** `launchctl unload` is not needed if bluetoothd is already dead: as root
  `BT_HCI_TRANSPORT=H4BC:POSIX:com.apple.uart.bluetooth,3000000 BT_DEVICE_ADDRESS=02:00:5e:77:b0:01 /usr/sbin/bluetoothd` (as user mobile via `su`/`sudo -u` if available;
  otherwise root first) and watch the log for "HCI Transport is set to ...", "Booting chipset", the BlueTool result, then the first HCI traffic. Without the stub BlueTool the expected failure is result 13/10 ("no firmware for this platform").
- **E4: BlueTool stub.** Push the stub as `/usr/sbin/BlueTool` (keep the original as `BlueTool.real`), re-run E3. Success looks like "BlueTool finished running boot script" then `HCI_Reset`, `Read_Local_Version`, `Read_BD_ADDR` visible from the kernel's UART trace.
- **E5: make it persistent.** Add the `EnvironmentVariables` to `com.apple.bluetoothd.plist` via the image retweak flow, reboot, confirm `bluetoothd` stays up; then check the user-visible result: Settings -> Bluetooth toggle responds (`defaults`: set `com.apple.MobileBluetooth.debug` is not needed; use `sweetprefs` only if a pref is found to gate power, [U]).
- **E6: iterate on VSC failures** with the shim table (3.3), watching bluetoothd crash reports and the unified log; then scan/advertise from the UI.
- **E7 (later): in-band sleep / low power, `function-bt_wake`, coexistence with Wi-Fi.**

## 6. Corrections to earlier notes

- `docs/WIFI_BT_PLAN.md` section 4.4 (and section 1 "iOS side"): the A11 BT path is **UART + kernel control socket**, not `AppleBluetoothModule`/`AppleConvergedIPCOLYBTControl`. Those names exist only as strings inside `AppleBluetoothDebug`; they belong to PCIe-BT devices (transport 7).
- The synthetic `/chosen mac-address-bluetooth0` is not read by bluetoothd/BlueTool; they need `local-mac-address` on a registry entry named `bluetooth` (or env `BT_DEVICE_ADDRESS`).
- Stock `/dev/btreset|btwake|btpoweroff` come from the `AppleBluetooth` kext (`BTReset`), not from the UART driver.

## 7. Evidence index (addresses are file VAs in the IPSW binaries)

- bluetoothd `usr/sbin/bluetoothd`: transport selection `0x100156160`, driver table `0x1007fd430`, transport table `0x1007fd3e0`, ADT read `0x1000e7684`, POSIX UART open `0x100066bdc`, `/dev/btwake` `0x100066b24`, `main` serial/MAC check `0x100026af4`..`0x100027510`, BlueTool XPC `0x100272034`, callers `0x100272ce4` (boot), `0x100272d5c` (init).
- BlueTool `usr/sbin/BlueTool`: UART open `0x10001da38` (`com.apple.uart.bluetooth`), `device` command `0x10001ca84`, transport id `0x10003e188`/`0x10003e2f8`, `transport-speed` `0x10003e030`, `local-mac-address` `0x10003e33c`, power/reset/wake `0x10003eccc`/`0x10003f15c`/`0x10003f580`, script lookup `0x100015fa4`, platform hash `0x10004075c`.
- kernelcache (`kernelcache.release.iphone10b`, vm base `0xfffffff004dc8000` prelink text): `AppleOnboardSerialBSDClient` sk/plain control creation `0xfffffff00581ba78` / `0xfffffff00581cb44`, devfs `uart.%s%s` `0xfffffff00581c9d4`, `BTReset::start` `0xfffffff006270370`.
- ADT: `research/ipsw-x/d22ap.adt` (`/arm-io/uart1/bluetooth`), `shim/out/beryllium-hi-2x.adt` (no uart/bluetooth nodes).

## 8. Implemented: patch 0136 (xnu/patches/0136-beryllium-bt-hci-kctl.patch) and the userland pieces

> **Do not set `BT_DEVICE_ADDRESS` (boot 0137, 2026-10-20).** bluetoothd 16.7 `sscanf()`s it into its
> address global and then unconditionally zeroes it (`main` 0x1000268f4/8), so it logs "Not a valid MAC
> address (all 00s)" and exits with "No bluetooth on this device" (launchd restarts it forever). Without
> the variable it reads `local-mac-address` from the ADT `/arm-io/bluetooth` node (verified:
> "bluetooth: Got local-mac-address: 02:00:5e:77:b0:01"). Older mentions of the variable below are wrong.

Base `research/bt133/xnu` (0001-0133); `git apply --check` clean on a fresh copy, `xnu-cc.py` clean (objects built; the
new undefined symbols `ctl_register`, `ctl_enqueuedata`, `mbuf_data/len/next/freem`, `SecureDTLookupEntry/GetProperty`,
`lck_mtx_*` are all defined in the tree and kern_control.c / kpi_mbuf.c are built by the sweet config). **Nothing here
has run on the phone.** The patch is named 0136 for the ios18 branch's collision; renumber on merge.

### 8.1 Kernel

Files: `bsd/dev/beryllium_bt_hci.c` (new: kctl, RX ring, TX framer, termios), `bsd/dev/beryllium_wlan.c` (UART/IBS side),
`bsd/conf/files`. Gate: boot-arg **`sweetbt=1`** together with `sweetwlan=2` (default off; without `sweetwlan=2` it is
ignored with a log line). Other boot-args: `sweetbtsk=1` also registers `com.apple.uart.sk.bluetooth` (same stream; bluetoothd
would still need the IOAOSSKY* socket options, so it only serves plain-socket clients), `sweetbtlog=N` HCI packet trace lines
(default 64, 0 = none), `sweetbtaddr=0` skips programming the BD_ADDR. All log lines start `SWEET BT:`.

After the BT stage's firmware step succeeds (`sweetbtfast=1 sweetbtibs=1` as in the NOTES entry) the stage no longer
restores clocks/RCG/pins: the stage thread itself becomes the RX loop and never returns. The order is: read ADT
`/arm-io/bluetooth local-mac-address` (fallback 02:00:5e:77:b0:01), **set the controller's BD_ADDR** (btqca.c `qca_set_bdaddr`:
vendor `0xFC14`, address least-significant byte first; the stage reads Read_BD_ADDR first, skips the command when it
already matches, re-reads afterwards, tries one HCI Reset if the new address is not visible yet and logs `MISMATCH` if it
still is not: [U] whether the WCN3990 applies it immediately), switch the framer on, force hardware flow control on,
register the controls.

* **RX path.** Polled kernel thread, no GENI IRQ plumbing exists in this tree (an IRQ would be SPI 607 [U, from the
  mainline dtsi]). The loop reads the FIFO under the UART lock (`wl_hw_lock`), feeds each byte to an H4 framer
  (`wl_xport_feed`), and every complete packet goes to a **64 KiB ring** (whole packets only: when the ring is full the packet is
  dropped, framing survives) from which `bt_hci_rx_service()` enqueues up to 4 KiB at a time with `ctl_enqueuedata`
  (socket receive buffer 128 KiB; `ENOBUFS` = flow control: the bytes stay in the ring and the next round retries).
  Justification of the timing: the RX FIFO has `rx_depth` words (logged: `RX FIFO N words`) and RFR deasserts at
  `rx_depth - 2` words, so after a poll the controller may send about `(rx_depth-2)*4` bytes before it is held off by RTS;
  at 3 Mbaud (10 bits per byte) that is ~190 us for a 16-word FIFO. While traffic flows the loop polls every ~30 us; after 200
  empty polls it sleeps 300 us per round (2 ms with no client), and the first bytes of a burst are simply held by RFR. A
  transmitter that wants the UART makes the RX loop step aside for 50 us so the mutex is not starved. The ring is only for a slow
  userland: 64 KiB is 218 ms of a saturated 3 Mbaud line, plus the 128 KiB socket buffer. **Measured, not assumed:** every
  10 s of activity the kernel prints `SWEET BT: UART RX <bytes> B in <polls> polls, max burst B / FIFO words (depth N), FIFO
  errors E ...` and `SWEET BT: HCI: rx ... (ring peak P of 65536 B, dropped ..., socket full ...)`. `max FIFO words` close to
  `depth` or `FIFO errors > 0` means the margin was exceeded and the loop needs an interrupt.
* **IBS, transparent.** Between packets, `0xFC` WAKE_ACK, `0xFD` WAKE_IND and `0xFE` SLEEP_IND are consumed in the kernel (state
  `ibs_asleep`, WAKE_IND is acknowledged with 0xFC by the RX loop, never inside a TX packet); userland never sees them. Before
  every packet from userland the existing `wl_ibs_wake` runs (0xFD, wait for 0xFC or the controller's own 0xFD, 100 ms x 3,
  then "sending anyway"). The host never sends SLEEP_IND itself. The first 24 handshakes are logged, then only the counters
  (`IBS: sleeps N wakes N (failed N)`). The H4 framer drops a byte that is not a packet type (logged, 8 times) and resyncs.
* **TX path.** `ctl_send` copies the mbuf chain through a small H4 framer (userland's SOCK_STREAM writes may split packets) and
  transmits each complete packet through `wl_xport_tx` (UART lock, IBS wake, FIFO-sized chunks).
* **Kernel control.** `ctl_register("com.apple.uart.bluetooth", CTL_FLAG_REG_SOCK_STREAM)`, **not privileged** (bluetoothd and
  BlueTool run as `mobile`), dynamic unit, one client at a time (a second `connect` gets `EBUSY`), registered only once the
  controller is up (before that `CTLIOCGINFO` fails with ENOENT). A disconnect leaves the controller powered and untouched.
* **termios "ioctls": no gap.** They are `getsockopt/setsockopt(sock, SYSPROTO_CONTROL, 0x40487413/0x80487414, struct termios)`,
  which `kern_control.c` hands to `ctl_getopt/ctl_setopt` with the option name as `opt`; handled there (0x80487415/6 =
  TIOCSETAW/F are accepted too). Get returns the stored termios with the speed in effect and CRTSCTS set; set accepts anything and
  **answers as already-at-3M**: the controller's speed was fixed by the 0xFC48 step and a host-only switch would break the link,
  so a different requested speed, or a request to turn hardware flow control off, is logged and ignored. Broadcom baud
  vendor commands that H4BC might send after that go to the controller as they are and come back as Unknown Command [U].
* **Not implemented.** No devfs nodes (`/dev/uart.bluetooth`, `/dev/cu.bluetooth`, `/dev/btwake`): the ADT node satisfies
  bluetoothd's device check (see 1.3), `/dev/btwake` is optional. No vendor-command shim (3.3): add it only if the phone shows a
  fatal VSC.

### 8.2 ADT (tools/mkadt.py, board beryllium only; the sweet ADT is byte-identical apart from `random-seed`)

`/arm-io/bluetooth`: `device_type bluetooth`, `compatible bluetooth,wcn3990`, `local-mac-address 02:00:5e:77:b0:01` (same value as
`/chosen mac-address-bluetooth0`, `BT_MAC` in the script; the kernel programs it into the controller), `transport-encoding 3`,
`transport-speed 3000000`, `vendor-id 0x05ac`, `product-id 0x12a0`. No new kernel code publishes it: `SweetPlatformExpert` already
makes a nub for every `/arm-io` child except `gic`, and the nub's registry name is `bluetooth` (what
`IOServiceNameMatching("bluetooth")` finds; [U] until `ioreg` confirms).
**transport-encoding 3 (H4BC), not 1:** the stock iPhone X value, the path I verified in bluetoothd (H4BC = POSIX driver, mode 0,
`/dev/btwake` tolerated) and the same one `BT_HCI_TRANSPORT=H4BC:...` forces, so the ADT and the env agree and BlueTool/bluetoothd
never see a mixed configuration. Our socket carries plain H4 and the Broadcom-specific parts of H4BC (baud, wake) are not driven over
it by anything we know [U]; if bluetoothd misbehaves with H4BC, set the env to `H4:POSIX:com.apple.uart.bluetooth,3000000` and/or
`transport-encoding` 1. **No `function-*` properties** (the doc's 3.2 table and 1.4: they are only read by the AppleBluetooth `BTReset` kext, which this kernel does not
have; `function-bt_wake` / `function-power_enable` without a consumer would be dead data, and without `function-power_enable` no
`/dev/btpoweroff` exists, which makes BlueTool's power/reset commands no-ops, as wanted). Rebuild the ADT with
`tools/mkadt.py OUT --board beryllium ...` (or `shim/build.sh`) to get the node.

### 8.3 Root image / live phone

* `tools/sweetnet/bluetool-stub.c` (built by `tools/sweetnet/build.sh`, ad-hoc signed with `bluetool.entitlements`: platform-application,
  no-container, no-sandbox, skip-library-validation): listens on the Mach service `com.apple.BlueTool` (launchd job `BlueTool -R`, user
  mobile) and answers **every** dictionary with `result` = int64 0, `firmware`, `output`, `manufacturer` strings and `btaddress`
  echoed back when the request carried one. It does not depend on the (unverified) message shape and writes each request and reply
  description to `/private/var/tmp/bluetool-stub.log`, so the first boot shows the real shape. `xpc_connection_create_mach_service` is
  marked unavailable in the iOS SDK, so it is resolved with `dlsym`. Started with other arguments it just exits 0.
* `tools/sweet-root-tweaks.py` (new `bluetooth` step, also `--bt-plist IN OUT`): `EnvironmentVariables` of the `com.apple.bluetoothd`
  job in the cached `launchd.plist` get `BT_HCI_TRANSPORT=H4BC:POSIX:com.apple.uart.bluetooth,3000000` and
  `BT_DEVICE_ADDRESS=02:00:5e:77:b0:01`; the stub replaces `/usr/sbin/BlueTool`, the original is kept as `BlueTool.orig`.
* `tools/sweet-bt-install.sh [-n|-u]`: the same on the live phone over SSH: pulls `/System/Library/xpc/launchd.plist`, edits it with
  plistlib on the Mac (copy kept in `research/bt-install/`), backs the phone's file up once as `launchd.plist.pre-bt`, writes it back
  in place, installs the stub (`BlueTool.orig` once) and `hcitest` to `/usr/local/bin`. `-n` shows the diff only, `-u` restores.
  launchd reads the cache at boot, so reboot afterwards. Build first: `TOOLS="hcitest bluetool-stub" tools/sweetnet/build.sh`.
* `tools/sweetnet/hcitest.c` (`hcitest [-n ctl] [-b baud] [-l secs]`): opens the control exactly like BlueTool (`socket(32,1,2)`,
  `CTLIOCGINFO`, `connect`, TIOCGETA/TIOCSETA 3 Mbaud with the termios bluetoothd builds), sends HCI Reset, Read Local Version, Read
  BD_ADDR and prints the raw events decoded; exit 0 only when all three complete with status 0.

### 8.4 Phone test order (each step stops at the first surprise)

1. **Kernel + ADT only.** Boot the patched kernel with the beryllium ADT rebuilt from this mkadt.py and
   `sweetwlan=2 sweetbt=1 sweetbtfast=1 sweetbtibs=1` (default `sweetwlandelay=90`, i.e. the stage starts ~90 s after boot; lower it
   only if you accept a risky MMIO access earlier). Wait for `SWEET BT: transport up:` in the kernel log; before it, the
   `SWEET WLAN:` firmware lines of the NOTES entry must be unchanged and `SWEET BT: controller BD_ADDR ... BD_ADDR now ...` shows
   the 0xFC14 result. Without the log line nothing below can work.
2. **hcitest, bluetoothd not involved.** If `bluetoothd` already runs it holds the (single) connection: `launchctl bootout
   system/com.apple.bluetoothd` (it exits 0 anyway on a stock image without the ADT node). Install the tools without touching
   launchd yet: `scp -O research/sweetnet/hcitest root@192.168.7.2:/usr/local/bin/` (or run `tools/sweet-bt-install.sh`, step 3), then
   `ssh root@192.168.7.2 hcitest -l 5`. Expect `connected`, TIOCGETA/TIOCSETA, `Command Complete for 0x0c03, status 0`,
   `HCI version 9 ... manufacturer 0x001d`, `BD_ADDR 02:00:5e:77:b0:01` and kernel lines `client connected`, `TX cmd`, `RX evt`.
   Check the `UART RX` / `HCI:` statistics lines (FIFO words vs depth, ring peak). Failure triage: ENOENT on CTLIOCGINFO = control not
   registered (step 1), EBUSY = other client, no reply = look at `BT IBS` lines and the TX line.
3. **Userland install.** `tools/sweet-bt-install.sh -n`, then without `-n`; reboot with the same boot-args.
4. **BlueTool stub.** After boot `cat /private/var/tmp/bluetool-stub.log` (the file exists once bluetoothd contacted the service) shows the
   real request/reply shape; if bluetoothd logs "BlueTool failed to run boot script", fix the reply keys there.
5. **bluetoothd.** The control only exists ~100-120 s after boot (stage delay + firmware download), later than bluetoothd's first
   start, which then fails to connect: after `SWEET BT: transport up` run `launchctl kickstart -k system/com.apple.bluetoothd`. Unified log (`tools/sweet-ios-pull.sh`, process bluetoothd): "HCI Transport is set to H4BC", the POSIX open of
   `com.apple.uart.bluetooth`, "Booting chipset" / "Powering on chipset", then HCI traffic in the kernel `SWEET BT: TX/RX` trace (raise
   `sweetbtlog=` to see more) and vendor commands that return Unknown Command (VSC shim candidates, 3.3). If it fails earlier:
   `ReleaseType`/sandbox (risk 4), `connect ... Operation not permitted`.
6. **Settings -> Bluetooth** toggle, scan; watch the `UART RX` statistics for FIFO errors under load.
