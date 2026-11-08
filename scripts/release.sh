#!/bin/zsh
# Builds a release: build/release/WheelBridge-<version>.dmg and SHA256SUMS.
#
#   VERSION=0.2.0 scripts/release.sh             build and check, publish nothing
#   VERSION=0.2.0 PUBLISH=1 scripts/release.sh   also create the GitHub release
#
# Signing, best first:
#   - A "Developer ID Application" certificate in the keychain. With
#     NOTARY_PROFILE set too, the app and DMG are notarized and stapled, so
#     they open with no Gatekeeper warning. Make the profile once with
#     xcrun notarytool store-credentials <name> --apple-id <id> --team-id <team>
#   - A self-signed "WheelBridge Dev" certificate. Updates keep Input
#     Monitoring, but the first launch needs Open Anyway in Privacy & Security.
#   - Ad hoc. Every update asks for Input Monitoring again. For testing only.
# SIGN_IDENTITY overrides the choice.
#
# The release notes come from release-notes/v<version>.md, which must exist.
set -euo pipefail
cd "${0:A:h:h}"

: ${VERSION:?Set VERSION, for example VERSION=0.2.0}
BUILD=${BUILD:-$(git rev-list --count HEAD)}
notes=release-notes/v$VERSION.md
[[ -f $notes ]] || { print -u2 "Write $notes first."; exit 1; }
[[ -n ${ALLOW_DIRTY:-} || -z $(git status --porcelain) ]] || { print -u2 "Commit or stash your changes first, so the release matches a commit."; exit 1; }

if [[ -z ${SIGN_IDENTITY:-} ]]; then
    identities=$(security find-identity -p codesigning 2>/dev/null)
    if developer=$(print -r -- $identities | grep -o '"Developer ID Application: [^"]*"' | head -1) && [[ -n $developer ]]; then
        SIGN_IDENTITY=${developer//\"/}
    elif print -r -- $identities | grep -q '"WheelBridge Dev"'; then
        SIGN_IDENTITY="WheelBridge Dev"
    else
        print -u2 "warning: no certificate found, signing ad hoc. Updates will ask for Input Monitoring again."
        SIGN_IDENTITY=-
    fi
fi
notarize=0
[[ $SIGN_IDENTITY == "Developer ID Application:"* && -n ${NOTARY_PROFILE:-} ]] && notarize=1
print "Version $VERSION ($BUILD), signed with: $SIGN_IDENTITY, notarized: $([[ $notarize == 1 ]] && print yes || print no)"

export VERSION BUILD SIGN_IDENTITY
scripts/build-app.sh
app=build/WheelBridge.app
codesign --verify --deep --strict $app

out=build/release
dmg=$out/WheelBridge-$VERSION.dmg
rm -rf $out && mkdir -p $out

if [[ $notarize == 1 ]]; then
    ditto -c -k --keepParent $app $out/notarize.zip
    xcrun notarytool submit $out/notarize.zip --keychain-profile $NOTARY_PROFILE --wait
    xcrun stapler staple $app
    rm $out/notarize.zip
fi

stage=$out/dmg
mkdir -p $stage
cp -R $app $stage/
ln -s /Applications $stage/Applications
if [[ $notarize == 0 ]]; then
    cat > "$stage/First launch - read me.txt" <<'TXT'
Drag WheelBridge onto Applications.

This copy isn't notarized by Apple, so the first time you open it macOS refuses.
Click Done, then open System Settings › Privacy & Security, scroll down and
click Open Anyway next to WheelBridge. After that it opens normally.
TXT
fi
hdiutil create -volname "WheelBridge $VERSION" -srcfolder $stage -ov -format UDZO -quiet $dmg
rm -rf $stage
[[ $SIGN_IDENTITY != - ]] && codesign --force --timestamp --sign "$SIGN_IDENTITY" $dmg
if [[ $notarize == 1 ]]; then
    xcrun notarytool submit $dmg --keychain-profile $NOTARY_PROFILE --wait
    xcrun stapler staple $dmg
fi

(cd $out && shasum -a 256 WheelBridge-$VERSION.dmg > SHA256SUMS)
print "Built $dmg"
cat $out/SHA256SUMS

if [[ ${PUBLISH:-0} == 1 ]]; then
    gh release create v$VERSION $dmg $out/SHA256SUMS \
        --title "WheelBridge $VERSION" --notes-file $notes --target $(git rev-parse HEAD)
else
    print "Not published. Run again with PUBLISH=1 to create the GitHub release v$VERSION."
fi
