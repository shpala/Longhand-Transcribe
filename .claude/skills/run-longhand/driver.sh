#!/bin/bash
# Driver for building, running, and driving Longhand (iOS on-device
# transcription app). Every subcommand wraps a command line that was run and
# verified on this machine. Run from anywhere; it cd's to the repo root.
set -euo pipefail
cd "$(dirname "$0")/../../.."

SCHEME=Longhand
BUNDLE_ID=com.shpala.Longhand

# A UDID identifies one physical device and belongs to whoever owns it, so
# none are in the repo. Put yours in devices.local.sh next to this script,
# which is gitignored:
#
#     LONGHAND_DEVICE_ID=00008140-...   # the iPhone
#     LONGHAND_WATCH_ID=00006001-...    # the paired Apple Watch
#
# or export them yourself. `xcrun devicectl list devices` prints both.
LOCAL_DEVICES="$(dirname "$0")/devices.local.sh"
# shellcheck source=/dev/null
[ -f "$LOCAL_DEVICES" ] && . "$LOCAL_DEVICES"
DEVICE_ID="${LONGHAND_DEVICE_ID:-}"
WATCH_ID="${LONGHAND_WATCH_ID:-}"

# Called before anything that talks to hardware. Without this, an unset UDID
# reaches xcodebuild as an empty destination id and comes back as a
# destination-not-found error, which reads like the phone is unplugged.
require_device() {
    [ -n "$DEVICE_ID" ] || {
        echo "no iPhone UDID. Set LONGHAND_DEVICE_ID or write $LOCAL_DEVICES" >&2
        exit 2
    }
}
require_watch() {
    [ -n "$WATCH_ID" ] || {
        echo "no watch UDID. Set LONGHAND_WATCH_ID or write $LOCAL_DEVICES" >&2
        exit 2
    }
}
DD=build/driver-dd
RESULTS=build/results

# Not every simulator simctl lists is a destination xcodebuild accepts (there
# are duplicate iPhone 17 Pro Max devices; one is rejected). Resolve through
# xcodebuild itself.
resolve_sim() {
    if [ -n "${LONGHAND_SIM_ID:-}" ]; then echo "$LONGHAND_SIM_ID"; return; fi
    xcodebuild -project Longhand.xcodeproj -scheme "$SCHEME" -showdestinations 2>/dev/null \
        | grep 'platform:iOS Simulator' | grep 'iPhone 17 Pro Max' | head -1 \
        | sed -E 's/.*id:([A-F0-9-]+).*/\1/'
}

usage() {
    cat <<'EOF'
usage: driver.sh <command> [args]

  kit-test                      Run the 60 LonghandKit unit tests (macOS, fast)
  build sim|device              Build the app for simulator / owner's iPhone
  sim-launch [--reset] [--synth he,ru,auto]
                                Boot sim, install, launch with UI-test hooks:
                                --reset wipes library+voice profiles,
                                --synth renders speech and imports it (see SKILL)
  share-sim <audio-file>        Hand a file to the running sim app the way the
                                share sheet does (copied into Documents/Inbox)
  sim-screenshot <out.png>      Screenshot whatever the simulator shows
  uitest <spec> sim|device      Run a UI test suite, e.g.
                                  LonghandUITests/RecordingFlowUITests
                                Result bundle lands in build/results/
  attachments <bundle.xcresult> <outdir>
                                Export screenshots a test attached
  seed-sim                      Install a committed COMPLETE job (with real
                                diarization) into the simulator container;
                                required before TranscriptUISmokeTests on sim
  seed-store-demo [udid]        Install the four invented recordings the App
                                Store screenshots are taken against, plus two
                                voice profiles, into a simulator container
  pull sim|device <dest-dir>    Copy Documents/Recordings (job folders,
                                checkpoints, transcripts) off the target
  accuracy <recordings-dir>     What the corrections in a pulled library say
                                about transcription quality. Pass --pairs to
                                see every machine/human pair.
  logs sim|device [seconds]     Stream the app's log for N seconds (default 60)
                                into build/. sim filters the unified log and
                                catches an app already running. device attaches
                                devicectl to a fresh launch, so it RESTARTS the
                                app and TERMINATES it when the window closes.
                                Needs no root, unlike `log collect --device-*`.
  device-install                Build for and install on the owner's iPhone
  device-install-release        Same, optimized (Release, dev-signed)
  watch-install                 Install the watch app straight onto the watch
                                (bypasses waiting for the phone to forward it)

  mac-build                     Build the macOS app
  mac-run [--fresh]             Build, (re)launch it; --fresh wipes its library
  mac-shot <out.png>            Screenshot the whole display (needs Screen
                                Recording permission for the terminal)
  mac-click <x> <y>             Synthetic click in screen POINTS; SwiftUI
                                ignores AppleScript's "click at"
  mac-menu                      Dump the running app's menu bar (works with the
                                display asleep, unlike a screenshot)
EOF
    exit 1
}

cmd="${1:-}"; shift || usage

case "$cmd" in
kit-test)
    swift test --package-path LonghandKit
    ;;

build)
    case "${1:-sim}" in
    sim)
        SIM=$(resolve_sim)
        xcodebuild -project Longhand.xcodeproj -scheme "$SCHEME" \
            -destination "platform=iOS Simulator,id=$SIM" \
            -derivedDataPath "$DD-sim" build
        ;;
    device)
        require_device
        xcodebuild -project Longhand.xcodeproj -scheme "$SCHEME" \
            -destination "platform=iOS,id=$DEVICE_ID" \
            -derivedDataPath "$DD-ios" -allowProvisioningUpdates build
        ;;
    device-release)
        # Same development signing, optimized build. Separate derived data so
        # a Release build never gets confused with the Debug one when
        # installing: they produce identically named products.
        require_device
        xcodebuild -project Longhand.xcodeproj -scheme "$SCHEME" \
            -configuration Release \
            -destination "platform=iOS,id=$DEVICE_ID" \
            -derivedDataPath "$DD-ios-release" -allowProvisioningUpdates build
        ;;
    *) usage ;;
    esac
    ;;

sim-launch)
    SIM=$(resolve_sim)
    ARGS=()
    while [ $# -gt 0 ]; do
        case "$1" in
        --reset) ARGS+=("--uitest-reset") ;;
        --synth) shift; ARGS+=("--uitest-synth-import" "$1") ;;
        *) usage ;;
        esac
        shift
    done
    xcrun simctl boot "$SIM" 2>/dev/null || true
    xcrun simctl bootstatus "$SIM" -b >/dev/null
    xcrun simctl privacy "$SIM" grant microphone "$BUNDLE_ID" 2>/dev/null || true
    APP="$DD-sim/Build/Products/Debug-iphonesimulator/$SCHEME.app"
    [ -d "$APP" ] || { echo "no sim build. Run: driver.sh build sim" >&2; exit 1; }
    xcrun simctl install "$SIM" "$APP"
    xcrun simctl launch --terminate-running-process "$SIM" "$BUNDLE_ID" "${ARGS[@]:-}" >/dev/null
    echo "launched $BUNDLE_ID on $SIM ${ARGS[*]:-}"
    ;;

sim-screenshot)
    SIM=$(resolve_sim)
    xcrun simctl io "$SIM" screenshot "${1:?output path}"
    echo "wrote $1"
    ;;

uitest)
    SPEC="${1:?test spec, e.g. LonghandUITests/RecordingFlowUITests}"
    TARGET="${2:-sim}"
    mkdir -p "$RESULTS"
    BUNDLE="$RESULTS/$(echo "$SPEC" | tr '/' '-')-$TARGET.xcresult"
    rm -rf "$BUNDLE"
    case "$TARGET" in
    sim)
        SIM=$(resolve_sim)
        # -parallel-testing-enabled NO: otherwise tests run on a throwaway
        # simulator clone and the app container vanishes with it.
        xcodebuild test -project Longhand.xcodeproj -scheme "$SCHEME" \
            -destination "platform=iOS Simulator,id=$SIM" \
            -only-testing:"$SPEC" -parallel-testing-enabled NO \
            -resultBundlePath "$BUNDLE"
        ;;
    device)
        require_device
        xcodebuild test -project Longhand.xcodeproj -scheme "$SCHEME" \
            -destination "platform=iOS,id=$DEVICE_ID" \
            -only-testing:"$SPEC" -allowProvisioningUpdates \
            -resultBundlePath "$BUNDLE"
        ;;
    *) usage ;;
    esac
    echo "result bundle: $BUNDLE"
    ;;

attachments)
    BUNDLE="${1:?xcresult path}"; OUT="${2:?output dir}"
    rm -rf "$OUT"; mkdir -p "$OUT"
    xcrun xcresulttool export attachments --path "$BUNDLE" --output-path "$OUT"
    echo "manifest: $OUT/manifest.json (suggestedHumanReadableName -> exportedFileName)"
    ;;

share-sim)
    # What "Share > Longhand" does: iOS copies the file into the app's
    # Documents/Inbox and opens it there. The app imports it with the saved
    # defaults and deletes the Inbox copy.
    [ -f "${1:-}" ] || usage
    SIM=$(resolve_sim)
    C=$(xcrun simctl get_app_container "$SIM" "$BUNDLE_ID" data)
    mkdir -p "$C/Documents/Inbox"
    cp "$1" "$C/Documents/Inbox/"
    xcrun simctl openurl "$SIM" "file://$C/Documents/Inbox/$(basename "$1")"
    echo "shared $(basename "$1") with $BUNDLE_ID on $SIM"
    ;;

seed-sim)
    SIM=$(resolve_sim)
    xcrun simctl boot "$SIM" 2>/dev/null || true
    xcrun simctl bootstatus "$SIM" -b >/dev/null
    APP="$DD-sim/Build/Products/Debug-iphonesimulator/$SCHEME.app"
    [ -d "$APP" ] || { echo "no sim build. Run: driver.sh build sim" >&2; exit 1; }
    xcrun simctl install "$SIM" "$APP"
    CONTAINER=$(xcrun simctl get_app_container "$SIM" "$BUNDLE_ID" data)
    rm -rf "$CONTAINER/Documents/Recordings"
    mkdir -p "$CONTAINER/Documents/Recordings"
    # UUID directory name must match the job record's id; regenerate copy under
    # the fixture's recorded id.
    JOB_ID=$(python3 -c "import json; print(json.load(open('.claude/skills/run-longhand/fixture/seed-job/job.json'))['id'])")
    cp -R .claude/skills/run-longhand/fixture/seed-job "$CONTAINER/Documents/Recordings/$JOB_ID"
    echo "seeded job $JOB_ID into simulator container"
    ;;

seed-store-demo)
    SIM="${1:-$(resolve_sim)}"
    xcrun simctl boot "$SIM" 2>/dev/null || true
    xcrun simctl bootstatus "$SIM" -b >/dev/null
    APP="$DD-sim/Build/Products/Debug-iphonesimulator/$SCHEME.app"
    [ -d "$APP" ] || { echo "no sim build. Run: driver.sh build sim" >&2; exit 1; }
    xcrun simctl install "$SIM" "$APP"
    CONTAINER=$(xcrun simctl get_app_container "$SIM" "$BUNDLE_ID" data)
    FIXTURE=.claude/skills/run-longhand/fixture/store-demo
    rm -rf "$CONTAINER/Documents/Recordings"
    mkdir -p "$CONTAINER/Documents/Recordings" "$CONTAINER/Library/Application Support"
    for JOB in "$FIXTURE"/*/; do
        cp -R "$JOB" "$CONTAINER/Documents/Recordings/$(basename "$JOB")"
    done
    cp "$FIXTURE/speaker-profiles.json" "$CONTAINER/Library/Application Support/"
    xcrun simctl privacy "$SIM" grant microphone "$BUNDLE_ID" 2>/dev/null || true
    # 9:41 and a full battery, so a screenshot does not date itself to the
    # afternoon it was taken.
    xcrun simctl ui "$SIM" appearance dark
    xcrun simctl status_bar "$SIM" override --time "9:41" --batteryState charged \
        --batteryLevel 100 --wifiMode active --wifiBars 3 \
        --cellularMode active --cellularBars 4 --operatorName "" 2>/dev/null || true
    echo "seeded the store demo library into $SIM"
    ;;

pull)
    TARGET="${1:?sim|device}"; DEST="${2:?destination dir}"
    rm -rf "$DEST"
    case "$TARGET" in
    sim)
        SIM=$(resolve_sim)
        CONTAINER=$(xcrun simctl get_app_container "$SIM" "$BUNDLE_ID" data)
        cp -R "$CONTAINER/Documents/Recordings" "$DEST"
        ;;
    device)
        require_device
        xcrun devicectl device copy from --device "$DEVICE_ID" \
            --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
            --source Documents/Recordings --destination "$DEST"
        ;;
    *) usage ;;
    esac
    echo "pulled Recordings to $DEST"
    ;;

accuracy)
    DIR="${1:?recordings dir, e.g. build/recs from `pull device`}"; shift || true
    # Absolute, because `swift run --package-path` resolves relative paths
    # against the package rather than the caller's directory.
    swift run --package-path LonghandKit longhand-accuracy \
        "$(cd "$(dirname "$DIR")" && pwd)/$(basename "$DIR")" "$@"
    ;;

logs)
    TARGET="${1:?sim|device}"; WATCH_SECONDS="${2:-60}"
    mkdir -p build
    case "$TARGET" in
    device)
        OUT="build/device-console.log"
        # `log collect --device-name` is the obvious tool and needs root, which
        # an agent has no business asking for. devicectl's --console streams the
        # app's own stdout/stderr instead, at the cost of having to relaunch:
        # it can only attach at launch, so anything already running is replaced.
        echo "streaming $BUNDLE_ID for ${WATCH_SECONDS}s -> $OUT" >&2
        require_device
        xcrun devicectl device process launch --device "$DEVICE_ID" \
            --console --terminate-existing "$BUNDLE_ID" >"$OUT" 2>&1 &
        STREAM_PID=$!
        ;;
    sim)
        SIM=$(resolve_sim)
        OUT="build/sim-console.log"
        # The simulator has a real unified log, so this one filters rather than
        # relaunching, and catches an app that is already running.
        echo "streaming $BUNDLE_ID for ${WATCH_SECONDS}s -> $OUT" >&2
        xcrun simctl spawn "$SIM" log stream --level debug --style compact \
            --predicate "process == \"$SCHEME\" OR senderImagePath CONTAINS \"$SCHEME\"" \
            >"$OUT" 2>&1 &
        STREAM_PID=$!
        ;;
    *) usage ;;
    esac
    sleep "$WATCH_SECONDS"
    kill "$STREAM_PID" 2>/dev/null || true
    wait "$STREAM_PID" 2>/dev/null || true
    echo "captured $(wc -l < "$OUT" | tr -d ' ') lines in $OUT" >&2
    ;;

device-install)
    "$0" build device
    require_device
    xcrun devicectl device install app --device "$DEVICE_ID" \
        "$DD-ios/Build/Products/Debug-iphoneos/$SCHEME.app"
    ;;

watch-install)
    # Direct install, rather than building the phone app and hoping iOS pushes
    # the embedded copy across. Requires the watch to be registered in the
    # provisioning profile; if it is not, the device says so plainly:
    # "This provisioning profile cannot be installed on this device" (0xe8008012).
    "$0" build device-release
    require_watch
    xcrun devicectl device install app --device "$WATCH_ID" \
        "$DD-ios-release/Build/Products/Release-watchos/Longhand.app"
    ;;

device-install-release)
    "$0" build device-release
    APP="$DD-ios-release/Build/Products/Release-iphoneos/$SCHEME.app"
    # The watch app rides inside the phone app; renaming its product means the
    # embedded bundle is Watch/Longhand.app, and an incremental build does not
    # clean that directory, so check it before shipping.
    ls "$APP/Watch"
    require_device
    xcrun devicectl device install app --device "$DEVICE_ID" "$APP"
    ;;

mac-build)
    xcodebuild -project Longhand.xcodeproj -scheme LonghandMac \
        -destination 'platform=macOS' -derivedDataPath "$DD-mac" build
    ;;

mac-run)
    "$0" mac-build >/dev/null
    APP="$DD-mac/Build/Products/Debug/Longhand.app"
    osascript -e 'tell application "Longhand" to quit' 2>/dev/null || true
    sleep 1
    if [ "${1:-}" = "--fresh" ]; then
        # The Mac app is sandboxed, so its library lives in its container.
        rm -rf "$HOME/Library/Containers/$BUNDLE_ID/Data/Documents/Recordings"
    fi
    open "$PWD/$APP"
    sleep 3
    echo "launched $APP"
    ;;

mac-shot)
    OUT="${1:?output png path}"
    mkdir -p "$(dirname "$OUT")"
    # -o omits the window shadow; a black image means the display is asleep,
    # and "could not create image from display" means the terminal lacks
    # Screen Recording permission (System Settings → Privacy & Security).
    screencapture -x -o "$OUT"
    echo "wrote $OUT"
    ;;

mac-click)
    X="${1:?x in screen points}"; Y="${2:?y in screen points}"
    CLICK="$DD-mac/mac-click"
    mkdir -p "$(dirname "$CLICK")"
    SRC=".claude/skills/run-longhand/mac-click.swift"
    if [ ! -x "$CLICK" ] || [ "$SRC" -nt "$CLICK" ]; then
        swiftc -O -o "$CLICK" "$SRC"
    fi
    "$CLICK" "$X" "$Y"
    ;;

mac-menu)
    osascript <<'AS'
tell application "System Events" to tell process "Longhand"
  set out to {}
  repeat with menuName in {"File", "Edit", "Playback"}
    set end of out to "--- " & menuName
    try
      repeat with i in menu items of menu 1 of menu bar item menuName of menu bar 1
        set end of out to (name of i as text)
      end repeat
    end try
  end repeat
  return out
end tell
AS
    ;;

*) usage ;;
esac
