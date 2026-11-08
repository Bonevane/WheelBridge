#!/bin/zsh
# Draws the app icon and writes build/AppIcon.icns.
set -euo pipefail
cd "${0:A:h:h}"

mkdir -p build/icon
swiftc -O -o build/icon/make-icon mac/Sources/WheelBridge/Glyph.swift scripts/icon/main.swift
rm -rf build/icon/AppIcon.iconset
build/icon/make-icon build/icon/AppIcon.iconset
iconutil -c icns -o build/AppIcon.icns build/icon/AppIcon.iconset
print "Built build/AppIcon.icns"
