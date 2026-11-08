#!/bin/zsh
# Builds build/WheelBridge.app with the helper and both proxies inside.
# Signed ad hoc here. Set SIGN_IDENTITY to a Developer ID to sign for release.
set -euo pipefail
cd "${0:A:h:h}"

./scripts/build-proxy.sh >/dev/null
(cd mac && swift build -c release --product WheelBridge && swift build -c release --product wheelbridged)

app=build/WheelBridge.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/proxy/x86_64" "$app/Contents/Resources/proxy/i686"
cp mac/.build/release/WheelBridge mac/.build/release/wheelbridged "$app/Contents/MacOS/"
cp build/windows/x86_64/dinput8.dll "$app/Contents/Resources/proxy/x86_64/"
cp build/windows/i686/dinput8.dll "$app/Contents/Resources/proxy/i686/"

cat >"$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>WheelBridge</string>
    <key>CFBundleIdentifier</key><string>com.bonevane.wheelbridge</string>
    <key>CFBundleName</key><string>WheelBridge</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

identity=${SIGN_IDENTITY:--}
codesign --force --options runtime --sign "$identity" "$app/Contents/MacOS/wheelbridged"
codesign --force --options runtime --sign "$identity" "$app"
print "Built $app"
