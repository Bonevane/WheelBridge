# Research: racing wheels and force feedback in CrossOver on macOS

Researched 2026-11-08 on macOS 26.6.2 (Apple Silicon) with CrossOver 26.3.

**How to read the evidence labels**

| Label | Meaning |
|---|---|
| **Verified here** | Checked on this Mac, or read directly in the project's source |
| **Reported** | Stated by another project's docs. Not reproduced here |
| **Claimed** | Vendor marketing. Closed source, cannot be checked |
| **Unknown** | Needs a real wheel. No hardware was attached during this research |

No force feedback has been tested on hardware for this project yet.

## The short version

1. macOS cannot be given a force feedback device without Apple-restricted
   entitlements, so the wheel has to be faked **inside the bottle** instead.
2. Every working tool has the same shape: a proxy `dinput8.dll` in Wine, talking
   to a macOS process that writes HID reports to the wheel. This needs no kext,
   no root and no SIP change.
3. The existing tools differ in where the proxy goes, whether they rely on Wine
   to deliver input, and how much of DirectInput they cover. No single tool has
   the best answer to all three.
4. The G29 has no TrueForce. TrueForce is a G923 and newer feature, and in
   CrossOver it can only be *simulated* from game telemetry.

## Why wheels are broken in CrossOver

| Link in the chain | What happens | Evidence |
|---|---|---|
| DirectInput in Wine | Only reports force feedback if the HID descriptor has a PID collection. Logitech wheels have none | Reported, `crossover-wheel` B4, citing `dlls/dinput/joystick_hid.c` |
| Wine's IOHID bus | Raw pass-through. Implements output reports but no force feedback | Verified here, read `bus_iohid.c` |
| Wine's SDL bus | Can synthesise PID, but only for devices SDL calls haptic. On macOS that needs `ForceFeedback.framework` | Reported, `crossover-wheel` B9 |
| `ForceFeedback.framework` | Only reaches devices whose *driver* published a plug-in | Reported, D1 |
| Virtual HID device | `IOHIDUserDeviceCreate` needs a restricted entitlement | Reported, D2. Akellacom's T300RS driver disables SIP and AMFI to get around it |
| DriverKit | Entitlement granted case by case | Reported |

Two more failures people hit:

- **macOS 27 removed the wheel from CrossOver entirely.** CrossFFB's 1.2.0
  release notes say so for the G29, and `crossover-wheel` E9 reports the same
  for the T150, with a suspected cause in SDL's GameController path.
- **`LogiWheelForceFeedback.kext`** from an old G HUB install claims the wheel and
  causes USB stalls (CrossWheel's troubleshooting page). We should detect this.

## The projects

| | CrossWheel | CrossFFB | crossover-ffb | crossover-wheel | g29fbb |
|---|---|---|---|---|---|
| Source | Closed, paid €19.99 | MIT | MIT | BSD-style | No licence |
| Wheels | G29, G923, G27, DFGT, G25. Thrustmaster beta (claimed) | G29 | G923 tested, G29 untested | T150 only | G29 |
| Proxy location | **Bottle** `system32` + `syswow64` | Game folder | Game folder | Bottle | Game folder |
| 32-bit games | **Yes** (ships `dinput8_32.dll`) | No | No | No | Unclear |
| Input path | Unknown | Wine, virtual fallback on macOS 27 | **Virtual device** | Wine | Wine |
| Transport | Unknown | TCP loopback | **Shared memory** | TCP loopback | UDP |
| Effects | 500 Hz mixer, ramps, envelopes (claimed) | Constant, spring, damper, friction, inertia | **Full set, ~500 Hz** | Full surface, per its docs | Constant only |
| TrueForce | No | No | **Simulated, G923** | No | No |
| Rev LEDs | ETS2/ATS plugin | No | AC, ACC, EVO | No | No |
| Signed | **No.** Ad-hoc, Gatekeeper rejects it (verified here) | **Developer ID + notarized** | No | No | Source only |
| Tests | Unknown | None | 8 files | 21 files | None |
| Maturity | v83 | 37 commits, 1.1.0 | 3 commits, 0.2.1 | 50+ commits, 0.3.12 | Experimental |

Related projects:

- `producedbytmsh/ets2-g29-macos` sets range and centring only. No game-driven FFB.
- `eddieavd/fffb` and `AndreyZarembo/ets2-g29-ffb-macos` serve native macOS SCS
  games, not CrossOver.
- `Mhytee/Trueforce-For-All` is the Windows SimHub plugin that proved TrueForce
  simulation on the G923.
- `mescon/logitech-trueforce-linux-driver` is the reference for the TrueForce
  protocol (GPL-2.0).
- `berarma/new-lg4ff` is the reference for the classic Logitech protocol
  (GPL-2.0).

### What was verified on this Mac

`/Applications/CrossWheel.app` (build 83) is installed, and the `Games` bottle
contains its proxy:

- `system32/dinput8.dll` matches the bundled `dinput8_64.dll` by SHA-256.
- `syswow64/dinput8.dll` matches the bundled `dinput8_32.dll` by SHA-256.
- `system32/dinput8_real.dll` is byte-identical to CrossOver's own builtin, so the
  original was saved under a new name and the proxy forwards to it.
- The bundle holds a single executable. Whether it runs a separate helper some
  other way, and what a crash does to a held force, is untested.
- The bottle has `DisableHidraw=1` and `SDL_JOYSTICK_MFI=0`. Which tool set these
  is not known.
- `dosdevices/z:` points to `/`, which the shared memory design depends on.
- There is a per-app `dinput8` override for `F1_2021_dx12.exe`, and F1 2020 is
  installed.

### Where each one falls short

- **CrossWheel:** closed, paid and unsigned. It has the widest wheel and game
  list on paper, and it is the one that has worked for the project owner.
- **CrossFFB:** the best release engineering, but G29 only, 64-bit only, one
  folder per game, and a manual Wine override. Open issues report that Assetto
  Corsa and Project CARS fail.
- **crossover-ffb:** the strongest architecture, but very young, with most games
  marked "should work". It presents every wheel as a G923, and is unsigned, so
  Input Monitoring has to be granted by hand.
- **crossover-wheel:** T150 only, but `docs/RESEARCH.md` there is the most
  valuable document in this space. Read section D before trying anything clever.

Why any one of these fails for a given person is not established here. The
symptoms reported to me are worth reproducing once a wheel is attached.

## Recommended architecture

Take the best proven decision from each project.

```
 Game (Wine)
   | DirectInput 8
   v
 dinput8.dll proxy         in system32 + syswow64, covers the whole bottle
   | presents a virtual wheel with the real wheel's name and IDs
   | shared memory, seqlock, never blocks the game
   v
 Wheel helper (launchd agent, no UI)
   | effect engine at 500 Hz or better, watchdog, safety limits
   | IOHIDDeviceSetReport, never seizing the device
   v
 Wheel driver: Logitech classic / HID++ / TrueForce / Thrustmaster

 Menu bar app + window: settings and diagnostics only.
 It can crash or quit without touching the motor.
```

| Decision | Choice | Taken from | Why |
|---|---|---|---|
| Proxy location | Bottle, both architectures, per-game as fallback | CrossWheel | One install per bottle, and 32-bit games work |
| Input | Virtual device fed by the helper | crossover-ffb | Survives CrossOver, SDL and macOS changes, which is exactly what broke on macOS 27 |
| Transport | Shared memory with seqlocks | crossover-ffb | A stalled helper can never freeze a game's frame |
| Effects | Computed on the Mac, sent as torque | CrossWheel, crossover-ffb | One engine for all wheels, drivers stay small |
| Wheel layer | Driver protocol per family | New | The main reason others are stuck on one wheel |
| Process split | Separate helper | New | Motor safety must not depend on the UI |
| Distribution | Developer ID + notarized | CrossFFB | Stable Input Monitoring, no Gatekeeper workaround |
| Diagnostics | Show every link in the chain | New | The most common complaint is "it doesn't work" with no reason |

### Rules that come from others' mistakes

- Never seize the device. It takes input from everything else (B6).
- Never block the game thread. Bound every call.
- Zero the motor on stall, pause, quit and unplug. crossover-ffb notes a
  force-killed app can leave a force held until the wheel is unplugged.
- Do not copy the `system32/dinput8.dll` placeholder as the "real" DLL. Find the
  true builtin by its `Wine builtin DLL` signature at byte 64 (E8).
- Back up what you replace and make uninstall exact.
- Expect CrossOver updates to undo the install. Detect it and offer a repair.
- On the G923, classic constant force is ignored while TrueForce streams, so FFB
  must ride in the stream's torque field (reported by crossover-ffb).

### Wheel support plan

| Wheels | Protocol | Plan |
|---|---|---|
| G29, G923 PS, G27, G25, DFGT | Logitech classic | First target |
| G923 Xbox, G920 | HID++ | Second |
| G923, G PRO, RS50 | TrueForce stream, interface 2 | Simulated TrueForce after FFB is stable |
| T300RS family, T150 | Thrustmaster | Later. T150 has working open prior art |
| Direct-drive PID wheels | Native PID | May work through Wine's hidraw with no bridge. Unknown |

### What this will not do

- Games that skip DirectInput 8 (XInput-only, raw HID) need a different route.
- Game-authored TrueForce needs G HUB, which does not run under Wine, so TrueForce
  stays simulated from telemetry.
- macOS-native games are out of scope for the first version.

## Licensing

- MIT and BSD-style code (CrossFFB, crossover-ffb, crossover-wheel) can be reused
  with attribution.
- `new-lg4ff` and the TrueForce driver are GPL-2.0. Protocol facts are fine, but
  copying code would make this project GPL.
- `g29fbb` and the T300RS driver have no licence, so their code cannot be reused.
- Logitech's SDK DLLs must not be redistributed.

## Naming

Checked on 2026-11-08 against GitHub, the Mac App Store, web search and DNS.
This is not a trademark search, and "no nameservers" does not prove a domain is
for sale.

| Name | Meaning | Conflicts found | Domains |
|---|---|---|---|
| **Countersteer** (recommended) | Steering into a slide. Also a nod to Oversteer, the Linux wheel tool | No app of that name found | `.app` taken, `.dev` shows no nameservers |
| Slipangle | The tyre physics behind what you feel through the wheel | None found | `.app` taken, `.dev` shows no nameservers |
| Rumblestrip | Playful, and suits haptics | None found | `.app` taken, `.dev` shows no nameservers |

Rejected:

- **CrossWheel** is the existing paid product, so this project must not ship
  under that name, even though the folder currently uses it.
- **Anything starting with Cross** gets confused with CrossWheel, CrossFFB and
  CodeWeavers' CrossOver trademark.
- **Chicane** is an existing iPhone motorsport telemetry app.
- **Oversteer** is the existing Linux tool.
- **Kingpin, Scrub, Caster, Pinion, Tarmac, Camber** are crowded or taken.

## Before building

- Install full Xcode (only Command Line Tools are present) and `llvm`/`lld` or
  `mingw-w64` for the Windows DLLs.
- A paid Apple Developer account is needed for notarization.
- Reading the wheel needs Input Monitoring, and `IOHIDDeviceSetReport` needs the
  console user, so macOS CI cannot test the write path.
- Hardware testing needs a real wheel. None was attached during this research.

## Sources

- https://crosswheel.seastian.com/ (also `/changelog/`, `/troubleshooting/`)
- https://github.com/teosemi/CrossFFB
- https://github.com/0xbiel/crossover-ffb
- https://github.com/renaudallard/crossover-wheel (`docs/RESEARCH.md`, `docs/ARCHITECTURE.md`)
- https://github.com/cslaviero/g29fbb-mac-crossover
- https://github.com/producedbytmsh/ets2-g29-macos
- https://github.com/eddieavd/fffb
- https://github.com/AndreyZarembo/ets2-g29-ffb-macos
- https://github.com/Akellacom/thrustmaster_t300rs_gt_macos_driver
- https://github.com/mescon/logitech-trueforce-linux-driver
- https://github.com/berarma/new-lg4ff
- https://github.com/Mhytee/Trueforce-For-All
- https://github.com/wine-mirror/wine/blob/master/dlls/winebus.sys/bus_iohid.c
