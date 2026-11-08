#!/bin/zsh
# Builds the 32-bit and 64-bit dinput8.dll proxies and the test probe.
# Needs: brew install mingw-w64
set -euo pipefail
cd "${0:A:h:h}"

build=build/windows
sources=(windows/proxy/bridge.c windows/proxy/proxy.c windows/proxy/device.c windows/proxy/effect.c)
flags=(-std=c11 -O2 -Wall -Wextra -Werror -Wno-cast-function-type -Wno-unused-parameter -Wno-format-truncation
       -Imac/Sources/CWheelBridge/include -D_WIN32_WINNT=0x0601)

for arch in x86_64 i686; do
    out=$build/$arch
    mkdir -p "$out"
    "$arch-w64-mingw32-gcc" "${flags[@]}" -shared -static-libgcc -Wl,--kill-at,--enable-stdcall-fixup \
        -o "$out/dinput8.dll" "${sources[@]}" windows/proxy/dinput8.def -ldxguid -luuid
    "$arch-w64-mingw32-gcc" -std=c11 -O2 -Wall -Wextra -Wno-missing-field-initializers -static-libgcc \
        -o "$out/wbprobe.exe" windows/probe/wbprobe.c -ldinput8 -ldxguid -luuid
    "$arch-w64-mingw32-strip" "$out/dinput8.dll"
done
ls -la "$build"/*/dinput8.dll
