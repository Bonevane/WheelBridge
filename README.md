# WheelBridge

Force feedback and full wheel support for Windows racing games running through
CrossOver on macOS, starting with the Logitech G29.

**Status:** research and design. There is no working code yet.

## Plan

A `dinput8.dll` proxy, installed once per bottle, presents a virtual wheel to the
game. A small macOS helper computes force feedback and drives the real wheel over
HID. It needs no kext, no root and no SIP change.

Read [docs/RESEARCH.md](docs/RESEARCH.md) for the findings, the comparison with
existing tools, and the reasoning behind this design.

## Licence

[Apache 2.0](LICENSE), the same as Bridge.
