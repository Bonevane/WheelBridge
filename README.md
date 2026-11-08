# WheelBridge

Force feedback and full wheel support for Windows racing games running through
CrossOver on macOS, starting with the Logitech G29.

**Status:** working end to end in CrossOver with a simulated wheel. Not yet tested
with a real wheel.

## How it works

```
 Game (Wine)
   | DirectInput 8
   v
 dinput8.dll proxy        one install per bottle, 32-bit and 64-bit
   | a virtual G29, fed by the helper
   | shared memory, never blocks the game
   v
 wheelbridged             the helper: effect engine at 500 Hz and the motor safety rules
   | IOHIDDeviceSetReport, never seizing the device
   v
 the wheel

 WheelBridge.app          settings and diagnostics. It cannot touch the motor.
```

It needs no kext, no root and no SIP change. Read
[docs/RESEARCH.md](docs/RESEARCH.md) for the reasoning.

## Layout

| Path | What it is |
|---|---|
| `mac/Sources/CWheelBridge/include/wheelbridge_bridge.h` | The shared memory contract. Both the proxy and the helper compile this one file |
| `mac/Sources/WheelCore` | Effect engine, motor rules, wheel protocol, bottle installer |
| `mac/Sources/wheelbridged` | The helper |
| `mac/Sources/WheelBridge` | The app |
| `mac/Sources/wheelcore-check` | Logic checks |
| `windows/proxy` | The `dinput8.dll` proxy |
| `windows/probe` | A stand-in game for testing under Wine |

## Building

You need Xcode's Command Line Tools and `brew install mingw-w64`.

```sh
scripts/build-app.sh
```

This builds `build/WheelBridge.app`, signed ad hoc. Set `SIGN_IDENTITY` to a
Developer ID to sign for release.

## Testing

```sh
cd mac && swift run wheelcore-check
```

This checks the protocol bytes, every effect type, the motor safety rules, the
shared memory, registry edits, and that uninstall restores a bottle byte for byte.

```sh
scripts/test-in-wine.sh /some/scratch/folder
```

This runs a real CrossOver throwaway bottle with the real installer and proxies,
plus a helper with a simulated wheel. A 64-bit and a 32-bit test game each find
the wheel, play a force and stall, and the script prints the exact reports the
motor would receive. It never touches your own bottles.

To look at the screens with sample data, without the helper or any bottle:

```sh
open -n build/WheelBridge.app --args --preview good
open -n build/WheelBridge.app --args --preview failure --screen Health
```

## Not yet tested on hardware

- Whether the G29 turns the expected way for a given force. Reverse force
  direction exists in case it doesn't.
- The compatibility-mode switch from `c294` to `c24f`.
- Real games, beyond the test probe.
- Starting the helper with launchd, and Input Monitoring prompts.

## Licence

[Apache 2.0](LICENSE), the same as Bridge.
