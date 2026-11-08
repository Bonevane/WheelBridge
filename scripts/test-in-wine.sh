#!/bin/zsh
# End-to-end test with no wheel: real CrossOver, real installer, real proxies, and
# a helper with a simulated wheel. It runs in a throwaway bottle, away from your
# own bottles, and prints the exact reports the motor would have received.
#
# Usage: scripts/test-in-wine.sh WORK_FOLDER
set -uo pipefail
cd "${0:A:h:h}"

work=${1:?usage: test-in-wine.sh WORK_FOLDER}
crossover=${CROSSOVER:-$HOME/Applications/CrossOver.app}
[[ -d $crossover ]] || crossover=/Applications/CrossOver.app
wine=$crossover/Contents/SharedSupport/CrossOver/bin
export CX_BOTTLE_PATH=$work/bottles
bottle=$CX_BOTTLE_PATH/wbtest
bridge=$work/bridge.bin
helper=mac/.build/debug/wheelbridged

mkdir -p "$CX_BOTTLE_PATH"
if [[ ! -d $bottle ]]; then
    print "creating a throwaway bottle"
    "$wine/cxbottle" --bottle wbtest --create --template win10_64 >"$work/create.log" 2>&1 || {
        print "could not create the bottle"; tail -5 "$work/create.log"; exit 1
    }
fi

"$wine/wine" --bottle wbtest --ux-app wineserver -k 2>/dev/null
"$helper" --install "$bottle" --proxies build/windows --bridge "$bridge" || exit 1

"$helper" --simulate --bridge "$bridge" >>"$work/motor.log" 2>&1 &
helper_pid=$!
trap 'kill -TERM $helper_pid 2>/dev/null' EXIT
sleep 1

result=0
for arch in x86_64 i686; do
    print "=== $arch game"
    cp "build/windows/$arch/wbprobe.exe" "$bottle/drive_c/wbprobe-$arch.exe"
    : >"$work/motor.log"
    "$wine/wine" --bottle wbtest --cx-app "C:\\wbprobe-$arch.exe" 2 2>"$work/wine-$arch.log" | tr -d '\r' | tee "$work/probe-$arch.log"
    [[ $(tail -1 "$work/probe-$arch.log") == done ]] || result=1
    print -- "--- reports the motor received"
    cat "$work/motor.log"
done

cp build/windows/x86_64/wbgames.exe "$bottle/drive_c/wbgames.exe"
for profile in kunos beamng sdl; do
    print "=== $profile-style game"
    : >"$work/motor.log"
    "$wine/wine" --bottle wbtest --cx-app 'C:\wbgames.exe' $profile 2 2>"$work/wine-$profile.log" | tr -d '\r' | tee "$work/games-$profile.log"
    [[ $(tail -1 "$work/games-$profile.log") == done ]] || result=1
    forces=$(grep -c '^report 11 00' "$work/motor.log")
    distinct=$(grep '^report 11 00' "$work/motor.log" | sort -u | wc -l | tr -d ' ')
    print -- "--- $forces force reports, $distinct distinct levels"
    (( distinct > 2 )) || { print "FAIL the motor never moved"; result=1; }
done

kill -TERM $helper_pid
wait $helper_pid
print -- "--- after the helper was told to quit"
tail -1 "$work/motor.log"

print "=== no helper: the proxy must step aside, not fail"
"$wine/wine" --bottle wbtest --cx-app 'C:\\wbprobe-x86_64.exe' 1 2>/dev/null | tr -d '\r' | grep -E 'ok create |wheels' | tee "$work/no-helper.log"
grep -q 'wheels 0' "$work/no-helper.log" || result=1

"$wine/wine" --bottle wbtest --ux-app wineserver -k 2>/dev/null
sleep 1
"$helper" --uninstall "$bottle" --proxies build/windows --bridge "$bridge"
exit $result
