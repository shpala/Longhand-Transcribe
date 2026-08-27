---
name: run-longhand
description: Build, run, test, screenshot, and drive the Longhand iOS transcription app, on the iOS simulator or the owner's iPhone. Use for "run the app", "run the tests", "screenshot", "install on the phone", "seed a job", "pull transcripts off the device".
---

# Run Longhand

Longhand is a local, on-device call-transcription iOS app (SwiftUI + a local
Swift package `LonghandKit`). There is no way to "click" an iOS app from the
shell. The drivers are (a) `driver.sh`, which wraps every verified
build/launch/screenshot/pull command, and (b) the XCUITest suites in
`LonghandUITests/`, which are the programmatic hands: they record audio, tap
through flows, and attach screenshots. App-side test hooks (`--uitest-reset`,
`--uitest-synth-import`) make runs deterministic.

All paths are relative to the repo root. Requires macOS with Xcode 26+
(iOS 26 SDK); nothing else to install; SwiftPM pulls `argmax-oss-swift`
on first build.

## Run (agent path)

The driver: `.claude/skills/run-longhand/driver.sh <command>`

```bash
D=.claude/skills/run-longhand/driver.sh
$D kit-test                 # 122 unit tests for the deterministic core (fast, macOS)
swift test --package-path LonghandEngines   # 10 pipeline tests: no audio, no models,
                                            # checkpoints are seeded so run() exercises
                                            # merge → identify → export
$D build sim                # build for simulator (resolves a valid destination itself)
$D sim-launch --reset --synth he   # boot+install+launch; wipes state, imports
                                   # synthesized Hebrew speech and processes it
$D sim-screenshot build/shot.png   # look at what the app shows; actually look at it
$D pull sim build/recs      # copy all job folders (checkpoints, transcript.json) out
$D seed-sim                 # install a committed COMPLETE job w/ real diarization
$D share-sim note.m4a       # what Share > Longhand does: Inbox copy + open URL
$D uitest LonghandUITests/TranscriptUISmokeTests sim   # drive the transcript UI
$D attachments build/results/<bundle>.xcresult build/shots   # export test screenshots
```

Synth-import languages: `he`, `ru`, or `auto` (renders Hebrew + silence +
Russian in one file to exercise mixed-language detection). This is the
deterministic way to create content; never assert on mic-recorded audio
(see Gotchas).

The UI-test suites are the interaction harness; run them with `$D uitest`:

| Suite | Drives |
|---|---|
| `LonghandUITests/RecordingFlowUITests` | record → stop → pipeline → terminal state |
| `LonghandUITests/SpeakerRecognitionUITests` | enroll a voice → second take auto-matches |
| `LonghandUITests/MultilingualUITests` | Hebrew/Russian/mixed via synth-import |
| `LonghandUITests/TranscriptUISmokeTests` | chips, playback bar, rename (needs `seed-sim` first on sim) |
| `LonghandUITests/NowPlayingUITests` | Lock Screen / Notification Center media controls appear and their Pause pauses the app (device only: the simulator never shows them; plays the newest recording muted) |
| `LonghandUITests/SiriShortcutsUITests` | Siri phrases start and stop a take (skips while the simulator's Siri data is still downloading); a launch-time record request opens the recorder |
| `LonghandUITests/LiveActivityUITests` | Mark, Pause and Stop pressed on the Live Activity (Notification Center) reach the recorder |
| `LonghandUITests/BackgroundRecordingUITests` | a take keeps recording through 10 s in the background (meaningful on device only; the simulator never suspends the recorder) |
| `LonghandUITests/BackgroundExecutionUITests` | job completes while backgrounded (device-only; skips on sim) |
| `LonghandUITests/UXImprovementsUITests` | Settings, delete confirmation, record-with-options |
| `LonghandUITests/TitleAndPauseUITests` | rename a recording; pause a job and confirm it stays paused |
| `LonghandUITests/SearchUITests` | library search + in-transcript find (needs `seed-sim`) |
| `LonghandUITests/TranscriptEditingUITests` | edit a turn, revert it (needs `seed-sim`) |
| `LonghandUITests/WordSeekUITests` | tap a word → playhead jumps to it (needs `seed-sim`) |
| `LonghandUITests/AppStoreScreenshotTests` | the App Store screenshot set (needs `seed-store-demo`) |

**Ordering matters when you batch them.** The four "needs `seed-sim`" suites
read a fixture out of the app container; every suite that launches with
`--uitest-reset` (Multilingual, SpeakerRecognition, UXImprovements,
TitleAndPause, RecordingFlow) wipes that container. Seeding once and then
looping over a list that mixes the two kinds fails the fixture suites with
whatever assertion happens to come first ("speaker chip should exist"), which
reads exactly like a regression and is not one. Either re-run `$D seed-sim`
immediately before the fixture suites, or keep them in their own batch.

## Mac (screenshot-driven; there is no XCUITest target for it)

The Mac and watch shells have no automated UI tests, so Mac verification is
manual driving through the driver:

```bash
$D mac-run --fresh                  # build + relaunch (--fresh wipes its library)
$D mac-shot build/mac.png           # screenshot the display, then LOOK at it
$D mac-click 740 298                # click in screen POINTS (Retina pixels ÷ 2)
$D mac-menu                         # dump File/Edit/Playback menu items
```

`mac-click` exists because **SwiftUI ignores AppleScript's `click at`**,
`System Events` reports success and nothing happens. The driver compiles a tiny
`CGEvent` poster instead. Selecting a sidebar row *can* be done through
accessibility, which is more robust than clicking:

```bash
osascript -e 'tell application "System Events" to tell process "Longhand" \
  to set selected of row 2 of outline 1 of scroll area 1 of group 1 \
  of splitter group 1 of group 1 of window 1 to true'
```

`mac-menu` is worth knowing: it works with the display asleep, whereas
`mac-shot` returns an all-black image and tells you nothing.

**App Intents on the Mac need one copy of the app.** Every Debug build,
DerivedData product and archive registers `com.shpala.Longhand` with Launch
Services, and the system indexes one of them, not necessarily the newest. With
several around, Spotlight and Shortcuts show no Longhand actions at all. List
them with `mdfind 'kMDItemCFBundleIdentifier == "com.shpala.Longhand"'`,
unregister each with `lsregister -u <path>` (in
`/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/`),
copy one build to `/Applications`, `lsregister -f` it and launch it once.
Spotlight then offers "Start Recording" for "Start recording with Longhand".

## Device (owner's iPhone)

`driver.sh` reads the phone's UDID from `LONGHAND_DEVICE_ID` and the watch's
from `LONGHAND_WATCH_ID`, either exported or set in `devices.local.sh` beside
the script, which is gitignored because a UDID identifies one person's
hardware. Without one, every device command stops with a message saying so
rather than handing xcodebuild an empty destination. The phone must be
connected or paired and unlocked; check `xcrun devicectl list devices` for
`connected`/`available` state first, which is also where the UDIDs come from.

```bash
$D device-install                    # build + install the app
$D uitest LonghandUITests/RecordingFlowUITests device
$D pull device build/phone-recs      # pull job folders off the phone
```

**Device UI tests never reset.** Suites that pass `--uitest-reset` skip it on
a device (`#if targetEnvironment(simulator)`), because it deletes the library
and every enrolled voice, and the phone holds the real corpus. Check any new
suite for the same guard before running it with `device`.

**Signing without an Apple ID in Xcode.** A new target's bundle ID, or a stale
test-runner profile ("doesn't include signing certificate"), stops at
`No Accounts`. The App Store Connect API key can register and refresh instead;
add these to the `xcodebuild` call (the key file stays outside the repo):

```bash
-allowProvisioningUpdates -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8 \
  -authenticationKeyID <KEYID> -authenticationKeyIssuerID <ISSUER>
```

Speaker profiles live outside job folders; pull them with:
`xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer --domain-identifier com.shpala.Longhand --source "Library/Application Support/speaker-profiles.json" --destination <dest>`

## Accuracy

```bash
$D pull device build/recs      # the corpus lives on the device (§14.1)
$D accuracy build/recs         # what the corrections say
$D accuracy build/recs --calibration   # §18.2 speaker-matcher calibration
$D accuracy build/recs --pairs # every machine/human pair, worst first
$D accuracy build/recs --by language
```

§18.1's harness was deferred for want of an annotated corpus. One has been
accumulating all along: every `UserOverlay.TurnEdit` holds `baseTextHash`, the
machine's own words, beside `newText`, what a person changed them to. The
machine text is rebuilt from `30_merged_words.json` the way `rerender` does, and
the stored hash confirms the pair is genuine rather than a coincidence of
timing. `transcript.json` is **not** the source: it has the overlay applied, so
pairing against it would measure nothing.

**Read the numbers for what they are.** Only corrected turns contribute errors,
so this is biased towards hard passages and is not a WER for a recording. The
*floor* is sound, since a word a person changed was wrong, and comparisons
between rows are the point. The tool prints that caveat under every run rather
than leaving it in a doc.

Edits it cannot use are counted, never dropped: `machineTextChanged` (a
re-transcription moved the words under the anchor), `noMatchingTurn`, and
`noMeasurableDifference` (a punctuation-only correction, which is a real edit
and not a transcription error).

### Calibration (§18.2)

`--calibration` reads the clusters whose names you **confirmed**: a confirmed
name is ground truth, and a name the matcher proposed is the claim being
calibrated, so it cannot stand in for one. Two takes naming the same person give
the same-speaker pair the score floor rests on; two names give a
different-speaker pair.

Enrollment copies the cluster centroid, so a person compared against their own
take scores exactly 1.0000. That is self-similarity, not evidence, and the
report segregates it.

The pulled folder holds embeddings, which are §14.1 biometric-like data. Delete
it when you are done rather than leaving it on the Mac.

## Logs

```bash
$D logs sim 30        # filters the unified log; catches an app already running
$D logs device 60     # attaches to a fresh launch
```

`log collect --device-name` is the obvious tool for a phone and **requires
root**, so it is not available here. `devicectl device process launch --console`
streams the app's own stdout/stderr instead and needs no privileges, at two
costs worth knowing before you reach for it: it can only attach **at launch**,
so the app is relaunched, and it forwards signals, so closing the capture
window **terminates the app** ("App terminated due to signal 15").

The device stream carries only what the app itself writes. A quiet app produces
a near-empty capture, which is not a failure. The simulator stream is the real
unified log filtered to the process, so it is far richer (~1500 lines a minute
at launch) and is the better place to look for Core ML and WhisperKit
complaints.

## Apple Watch

The watch is never cabled. It is reached over the network through the paired
iPhone, and it needs three things before it will take a build:

1. **Developer Mode on the watch** (Settings → Privacy & Security).
2. **"Connect via network"** ticked for the iPhone in Xcode → Window → Devices
   and Simulators. The watch is discovered *through* the phone.
3. **Registered in the provisioning profile.** A watch that is paired but
   unregistered fails at install with
   `0xe8008012, This provisioning profile cannot be installed on this device`.
   Registering it needs an Apple ID `xcodebuild` can see; without one it stops
   at `No Account for Team "…"` and cannot add the device. Fix by building the
   watch scheme against the watch once:

   ```bash
   xcodebuild -project Longhand.xcodeproj -scheme LonghandWatch -configuration Release \
     -destination "platform=watchOS,id=$LONGHAND_WATCH_ID" \
     -derivedDataPath build/driver-dd-ios-release -allowProvisioningUpdates build
   ```

   Confirm it worked by counting devices in the embedded profile rather than
   trusting the build to say so:

   ```bash
   security cms -D -i .../Release-watchos/Longhand.app/embedded.mobileprovision \
     | plutil -extract ProvisionedDevices json -o -
   ```

Then `$D watch-install` puts the app straight on the wrist. Waiting for the
phone to forward its embedded copy also works but is slow and silent when it
fails.

**A tunnel timeout is not a signing failure**, and the two are easy to
confuse because both stop the install dead:

```
ERROR: A connection to this device could not be established. (…error 4000)
       Timed out while attempting to establish tunnel using negotiated
       network parameters. (com.apple.dt.RemotePairingError error 1001)
```

This says the watch is unreachable, not unauthorised, and retrying does not help
while it persists, and it happens even when `devicectl list devices` reports
the watch `available (paired)`, because that listing is cached. Before
concluding anything about signing, check the two facts that actually settle
it: the watch binary's mtime (`Release-watchos/Longhand.app/Longhand`; note
that `embedded.mobileprovision` inside the bundle keeps its *old* date on an
incremental build and reads like a stale product when it is not), and the
device list in the embedded profile:

```bash
security cms -D -i .../Release-watchos/Longhand.app/embedded.mobileprovision > /tmp/wp.plist
plutil -extract ProvisionedDevices json -o - /tmp/wp.plist   # watch UDID starts 00006001-
```

If both are good, it is the network. The phone install already carries the
watch app embedded, so leaving it to iOS to forward is the fallback.

**The watch app is named by PRODUCT_NAME, not just the display name.**
`CFBundleName` is generated from the product name and has no `INFOPLIST_KEY_*`
equivalent, and setting one is silently ignored, so the target name leaks onto
the wrist unless the product itself is renamed. Note also that an incremental
build does not clean `Longhand.app/Watch/`, so a stale embedded copy can
survive a rename; delete `Products/Debug-watchos` and the app's `Watch/`
directory when a change refuses to appear.

## App Store screenshots

The listing's pictures come out of a UI test, not out of a screenshot session
someone did by hand, so they can be regenerated after any redesign:

```bash
D=.claude/skills/run-longhand/driver.sh
$D build sim
$D seed-store-demo                       # iPhone, or pass an iPad UDID
$D uitest LonghandUITests/AppStoreScreenshotTests sim
$D attachments build/results/LonghandUITests-AppStoreScreenshotTests-sim.xcresult build/shots
```

`seed-store-demo` installs `fixture/store-demo`: four invented recordings (an
English design review with three speakers, a Hebrew team meeting, a client
call, a memo) and two voice profiles. All of it is written by hand. None of it
is a real recording, and `20_diarization.json` has no `centroids` key at all
rather than plausible-looking numbers, because a 256-dim vector in a fixture
would be indistinguishable from the biometric-like data 14.1 says never leaves
the device. It also pins the status bar to 9:41 on a full battery and forces
dark mode, so two runs a month apart produce the same picture.

Sizes come out right on their own: an iPhone 17 Pro Max simulator screenshots
at 1320x2868, which is what Apple wants for 6.9", and an iPad Pro 13-inch at
2064x2752. Pick the iPadOS 26.5 simulator, not the 26.0 one; the app's
deployment target rejects the older runtime at install time with "Requires a
Newer Version of iPadOS", which reads like a signing problem and is not one.

Watch screenshots need no test: install the watch build, launch it, and take
`xcrun simctl io <watch-udid> screenshot`. A Series 11 46mm shoots 416x496,
which is Apple's Series 10 slot. `--uitest-autotake <seconds>` gets the
recording screen without a tap, since watch simulators accept no synthetic
taps.

The Mac needs two tricks. `screencapture -o -l <windowid>` grabs the window
without the desktop showing through its rounded corners, but it cannot see an
open menu, because a menu is a window of its own; for a menu shot, capture the
region and clip it back to a rounded rectangle over white. Size the window to
1440x900 points first and a Retina capture lands on 2880x1800 exactly. The Mac
app follows the system appearance and nothing short of changing it makes the
app dark, so those four are light while the phone's are dark.

## Distribution (App Store / TestFlight)

Signing for distribution is a different path from `device-install`, and none of
it goes through Xcode's UI. There is no Apple ID signed in to Xcode on this
machine (`DVTDeveloperAccountManagerAppleIDLists` is empty); the development
profiles are cached ones minted long ago, which is why device installs keep
working while anything that needs a *new* profile fails with `No Accounts`.
Authenticate with the App Store Connect API key instead:

```bash
# Key lives outside the repo. Key ID is the .p8 filename; the issuer ID is the
# UUID at App Store Connect → Users and Access → Integrations.
KEY=~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8
AUTH="-authenticationKeyPath $KEY -authenticationKeyID <KEYID> -authenticationKeyIssuerID <ISSUER>"

xcodebuild -project Longhand.xcodeproj -scheme Longhand -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath build/appstore/Longhand.xcarchive archive

PATH=/usr/bin:/bin:/usr/sbin:/sbin xcodebuild -exportArchive \
  -archivePath build/appstore/Longhand.xcarchive \
  -exportOptionsPlist build/appstore/ExportOptions.plist \
  -exportPath build/appstore/export \
  -allowProvisioningUpdates $AUTH
```

Swap the scheme to `LonghandMac` and the destination to
`generic/platform=macOS` for the Mac, which exports a `.pkg` rather than an
`.ipa`.

`build/` is gitignored, so write `ExportOptions.plist` fresh each time rather
than expecting to find one. Four keys, the same for both platforms, with the
team ID coming from `Config/Local.xcconfig` rather than from here:

```xml
<key>method</key><string>app-store-connect</string>
<key>teamID</key><string>$LONGHAND_TEAM_ID</string>
<key>signingStyle</key><string>automatic</string>
<key>destination</key><string>export</string>
```

The export is what creates the store provisioning profiles, so the first run
against a fresh account does real work on the portal. Four exist as of
26 Aug 2026 (`com.shpala.Longhand`, `.watchkitapp`, `.watchkitapp.recordwidget`,
plus the Mac one), all expiring 26 Aug 2027.

**Verify the product, never the exit code.** Unzip the `.ipa` and check every
nested bundle, since the watch app and the complication are signed separately
and a wrong profile on either is only visible here:

```bash
unzip -q export/Longhand.ipa -d /tmp/ipacheck
A=/tmp/ipacheck/Payload/Longhand.app
codesign -dvvv "$A" 2>&1 | grep Authority          # Apple Distribution, not Development
codesign -d --entitlements - --xml "$A" | plutil -p -   # get-task-allow false, beta-reports-active true
for b in "$A" "$A/Watch/Longhand.app" "$A/Watch/Longhand.app/PlugIns/LonghandComplication.appex"; do
  security cms -D -i "$b/embedded.mobileprovision" | plutil -extract Name raw -o -
done
```

Uploading needs an App Store Connect app record to exist first; the same
`$AUTH` triple drives that leg too.

## Run (human path)

Open `Longhand.xcodeproj` in Xcode, pick a simulator or the phone, ⌘R.
Useless for agents; nothing to observe programmatically.

## Gotchas (all hit for real)

- **`screencapture` needs Screen Recording permission** for the terminal app,
  or it fails with "could not create image from display". An all-black PNG is a
  different problem: the display is asleep.
- **The Mac app is sandboxed**, so its library is at
  `~/Library/Containers/com.shpala.Longhand/Data/Documents/Recordings`, not in
  `~/Documents`. Its voice profiles are under that container's
  `Library/Application Support/speaker-profiles.json`.
- **A location fix requested while the authorization prompt is still up comes
  back nil**; `LocationCapture`'s 15 s watchdog fires first. Only bites on the
  first recording after granting; re-record to test the happy path.

- **Ground truth is the container, not the UI.** `job.json` (state, error,
  degradations), `10_asr.json`, `20_diarization.json`, `transcript.json` tell
  you exactly what happened. `$D pull sim|device` first, guess never.
- **Mic-loop audio is unassertable.** Playing synthesized speech through a
  speaker into the mic yields ~-36 dBFS mush; WhisperKit returns ZERO segments
  (immediate endoftext) on degraded audio rather than erroring. Use
  `--uitest-synth-import` for any test that asserts transcript content.
- **Simulators have no Apple speech and no diarization.**
  `SpeechTranscriber.supportedLocales` is empty, so ASR routes to WhisperKit
  (626 MB download into the sim container on first use, ~2 min). SpeakerKit
  diarization degrades on sim → jobs get "Unknown speaker", no chips. For
  speaker-UI tests, `$D seed-sim` installs a committed device-produced job.
- **A dead simulator pasteboard hangs every text field.** Symptom: any test
  that focuses a field (library search, Find, the turn editor, the language
  search) stops with "process main thread busy for 30.0s" or "Timed out while
  evaluating UI query", right after the field appears, on old code as well as
  new. `becomeFirstResponder` asks the pasteboard whether image paste is
  supported, synchronously, and a dead `pasted` never answers. Confirm with
  `xcrun simctl spawn <udid> launchctl list | grep pasted` (a status of `-9`
  is the dead one) and fix with `xcrun simctl shutdown <udid>` then boot it
  again. Found 2 Oct 2026 by sampling the hung app (`sample <pid> 4`): the
  main thread sat in `PBServerConnection` for the whole sample.
- **Continuous animation starves XCUITest.** Any view redrawing subviews on a
  timer (the record-sheet level meter originally) blocks accessibility
  snapshots → "Failed to get matching snapshots: Timed out". Draw with a
  single `Canvas`; keep TimelineView ticks ≥ 0.25 s *under UI tests*, since the
  level meter runs ~12 Hz for humans and drops to 0.25 s automatically when
  any `--uitest-` launch arg is present (`UITestSupport.isUITestRun`).
- **Count cells, not identifiers.** One row exposes its accessibility
  identifier on several nested elements,
  `app.cells.containing(.any, identifier: "status-COMPLETE").count`, never
  `descendants(matching:).count`.
- **`-parallel-testing-enabled NO` on simulator tests**, or else tests run
  on a throwaway simulator clone and the app container (your ground truth)
  is destroyed with it.
- **Not every listed simulator is a valid destination.** `simctl list` shows
  two iPhone 17 Pro Max devices; xcodebuild rejects one. The driver resolves
  through `xcodebuild -showdestinations`.
- **First runs download models.** WhisperKit ~626 MB, SpeakerKit Community-1,
  Apple locale assets (device only). Budget 10-15 min deadlines the first
  time; cached afterwards.
- **Device flakiness reads as infra errors** ("runner exited with code 74",
  "continuity display" timeouts): the phone dropped to Wi-Fi debugging, is
  locked, or is in use. Check `devicectl list devices`, retry once, else use
  the simulator.
- **BGTaskScheduler:** submitting without a successful registration is an
  uncatchable ObjC assertion crash, and registration legitimately fails on
  simulators; the app gates on `register()`'s Bool. Don't "fix" that.
- **Watch simulators accept no synthetic taps** (no XCUITest target, no
  simctl tap). The watch app has `--uitest-autotake <seconds>` (records N s,
  stops, transfers); extend that hook, don't fight the simulator. Create/
  pair a watch sim with `simctl create` + `simctl pair <watch> <phone>`;
  install `Debug-watchsimulator/LonghandWatch.app`; pre-grant mic with
  `simctl privacy`.
- **Homebrew's rsync breaks `xcodebuild -exportArchive`.** It fails with a
  bare `error: exportArchive Copy failed`, which says nothing and looks like a
  signing problem. It is not. `/usr/bin/rsync` is Apple's openrsync, and it
  spawns its server side by looking `rsync` up on `PATH`; `/opt/homebrew/bin`
  comes first and rsync 3.4.2 rejects the `--extended-attributes` that
  openrsync sends for `-E`. The real error is buried in the distribution log
  (`IDEDistributionPipeline.log` in the `.xcdistributionlogs` bundle the run
  prints a path to), not in xcodebuild's output. Prefix the command with
  `PATH=/usr/bin:/bin:/usr/sbin:/sbin`. Hit 26 Aug 2026.
- **WCSession `transferFile` does NOT deliver between paired simulators**:
  the watch side even reports "Delivered" (didFinish, no error) while the
  phone's wcd never sees the file. Verified empirically 19 Aug 2026. The
  watch→phone hand-off can only be tested on real hardware; everything up
  to the transport (recording, queueing, phone-side import) verifies in sim.

## Troubleshooting

- `Multiple commands produce .../Info.plist`: the synchronized group tried to
  copy `Longhand/Info.plist` as a resource; the pbxproj has a
  `PBXFileSystemSynchronizedBuildFileExceptionSet` excluding it. Keep it.
- `ambiguous use of 'downloadModels(progressCallback:)'`: SpeakerKit subclass
  re-declares the base overload; call through `(diarizer as ModelManager)`.
- App crash `CheckedContinuation.resume` in UITestSupport: the
  `AVSpeechSynthesizer.write` callback delivers its zero-length terminator
  more than once; the per-utterance completion guard must stay.
- Test screenshots: export with `$D attachments`, then map names via
  `manifest.json` (`suggestedHumanReadableName` → `exportedFileName`).
