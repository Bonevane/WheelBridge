# What WheelBridge supports

"Tested" means tried on real hardware or a real game. "Expected" means it follows
published protocol notes and passes `wheelcore-check` and `scripts/test-in-wine.sh`,
but nobody has tried it for real yet. Reports either way are welcome.

## Launchers

The proxy is an ordinary Windows `dinput8.dll`, so it works in any Wine 6 or newer.
What differs between launchers is where they keep prefixes and their Wine, because
the proxy forwards to a copy of that Wine's own `dinput8.dll`.

| Launcher | Found automatically | Wine used | Status |
|---|---|---|---|
| CrossOver | `~/Library/Application Support/CrossOver/Bottles` | The CrossOver chosen in Bottles | Tested |
| Whisky | Its container, and any extra bottle paths in `BottleVM.plist` | Whisky's own Wine in Application Support | Expected |
| Sikarugir, Kegworks, Wineskin | Wrapper apps in `~/Applications/<name>` or `/Applications/<name>` | The wrapper's own engine | Expected |
| Heroic | Prefixes named in `GamesConfig/*.json`, and `~/Games/Heroic/Prefixes/default` | The Wine each game is set to use | Expected |
| Plain Wine, Game Porting Toolkit | `~/.wine` | Wine Stable, Staging or Devel apps, Homebrew, or the toolkit | Expected |
| Anything else | Add Wine Prefix… in Bottles | Found in the usual places, or chosen | Expected |

Heroic games that run in a CrossOver bottle show up under CrossOver.

When you update CrossOver or a wrapper's engine, or switch to another CrossOver,
the bottle shows "Made for a different CrossOver version". Repair fixes it in one
click. Until then the proxy forwards to the old Wine's `dinput8`, which may not load.

Wine older than 6 keeps its libraries in a different layout and isn't supported.

## Games

Everything goes through DirectInput 8, which nearly every PC sim uses for force
feedback. The test script copies the calls each family below is known to make.

| Game | How it does force feedback | Status |
|---|---|---|
| F1 2021 | DirectInput | Tested on a G29 |
| Assetto Corsa | DirectInput. Content Manager works the same way | Expected |
| Assetto Corsa Competizione | DirectInput | Expected |
| Assetto Corsa EVO | DirectInput | Expected |
| BeamNG.drive | DirectInput | Expected |
| rFactor 2, Le Mans Ultimate, iRacing, RaceRoom, Automobilista 2, DiRT Rally 2.0, EA WRC | DirectInput | Expected |
| Forza Motorsport, Forza Horizon | Windows.Gaming.Input, and anti-cheat that blocks Wine | Not expected to work |

Notes for these games:

- **Kunos games (AC, ACC, EVO)** also load Logitech's steering wheel SDK for rev
  lights, the rotation range and TrueForce. That SDK talks to G HUB, which doesn't
  exist under Wine. So it reports no wheel, and the games carry on with DirectInput.
  Set the steering lock in the game to match the range in WheelBridge.
- **ACC's "Dynamic damping"** uses a damper effect. WheelBridge runs it in its effect
  engine, like every condition effect.
- **TrueForce**, the high-frequency haptics on the G923, isn't supported. It needs
  Logitech's SDK and G HUB.
- **Games that read the wheel another way**, through Raw Input, the old `winmm`
  joystick calls, or `dinput.dll` (DirectInput 7), see Wine's own copy of the
  wheel, which has no force feedback. None of the games above do this.

## Wheels

All of these use Logitech's classic protocol: seven-byte reports, a constant force
in slot 1, and the range set by the wheel itself. The byte layouts come from Linux's
`hid-lg4ff` and the out-of-tree `new-lg4ff`.

| Wheel | USB id | Range | Status |
|---|---|---|---|
| G29 | `046d:c24f` | 40–900° | Tested |
| G923 for PlayStation and PC | `046d:c266` | 40–900° | Expected |
| G27 | `046d:c29b` | 40–900° | Expected |
| G25 | `046d:c299` | 40–900° | Expected |
| Driving Force GT | `046d:c29a` | 40–900° | Expected |
| Driving Force Pro | `046d:c298` | 40–900°, with its own range command | Expected |
| Driving Force, Driving Force EX | `046d:c294` | Fixed at 270° | Expected |
| MOMO Force, MOMO Racing | `046d:c295`, `046d:ca03` | Fixed at 270° | Expected |

Most multimode wheels start in a compatibility mode that shows up as `c294`, and the
G923 shows up as `c267` in its PlayStation mode. WheelBridge reads the firmware version
to tell which wheel it really is, sends the matching mode switch, and picks the wheel
up again when it comes back with its own id.

### Recognised, not supported yet

The app names these wheels and explains why they aren't driven. Games still see
them through Wine, without force feedback.

| Wheel | Why |
|---|---|
| G920, G923 for Xbox and PC | They use Logitech's HID++ force feedback, a different protocol. The G920 also starts in an Xbox mode that isn't a HID device on macOS. |
| PRO Racing Wheel, RS50 | Direct drive, with Logitech's newer protocol. |

### Other brands

- **Direct drive wheels that follow the USB PID standard** (most Moza, Simagic,
  Simucube, Cammus and OpenFFBoard bases) could share one generic driver, because
  the standard describes every report. It needs one of these wheels to test with.
- **Thrustmaster and Fanatec** use their own protocols. Linux has community drivers
  (`hid-tmff2`, `hid-fanatecff`) to follow, but each needs hardware to test with.

Adding a family means adding one `WheelDriver` in `mac/Sources/WheelCore/WheelDriver.swift`.
Everything above it works in plain torque and degrees.
