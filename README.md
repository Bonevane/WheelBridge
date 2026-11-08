# WheelBridge

Force feedback and full wheel support for Windows racing games running through
Wine on macOS: CrossOver, Whisky, Sikarugir, Kegworks, Wineskin, Heroic, Game
Porting Toolkit or plain Wine. It supports Logitech's classic force feedback wheels.

**Status:** tested on a real G29 in F1 2021 under CrossOver. Other wheels and
launchers follow published protocol notes and pass the tests below, but haven't
been tried on hardware. See [docs/SUPPORT.md](docs/SUPPORT.md) for games, wheels
and launchers.

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
| `windows/probe` | Stand-in games for testing under Wine: a basic one, and ones that copy Kunos, BeamNG and SDL games |

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
the wheel, play a force and stall. Three more copy the DirectInput calls of
Assetto Corsa, ACC and AC EVO, of BeamNG.drive, and of SDL games, and each must
move the motor. The script prints the exact reports the motor would receive. It
never touches your own bottles.

To look at the screens with sample data, without the helper or any bottle:

```sh
open -n build/WheelBridge.app --args --preview good
open -n build/WheelBridge.app --args --preview failure --screen Health
```

## Not yet tested on hardware

- Any wheel but the G29, and the switches out of compatibility mode.
- Games other than F1 2021, and launchers other than CrossOver.

## Licence

[Apache 2.0](LICENSE), the same as Bridge.
