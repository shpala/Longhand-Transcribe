# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Longhand is an open-source (Apache-2.0) iOS app (iOS 26, Swift 6, SwiftUI) that
records or imports audio and produces speaker-attributed transcripts entirely
on-device. The normative spec is `docs/design-v1.1-redline.md`, a redline
document: implement the *inserted v1.1* text, never the struck v1.0 text;
⟨R-n⟩ notes are reviewer rationale, `[VERIFY]` items are unconfirmed claims.
`docs/IMPLEMENTATION.md` maps every §-reference to code and records what is
deliberately deferred and why. When a change touches pipeline behavior, keep
both documents current.

SpeakerKit and WhisperKit are vendored through the `argmax-oss-swift` SwiftPM
package. The §4.3 licensing question that gated that is settled and written up
in `docs/IMPLEMENTATION.md`: the Argmax SDK is MIT, the Whisper weights are
MIT, and the pyannote components are MIT and CC BY 4.0. The pyannote models are
bundled rather than downloaded, so CC BY 4.0's attribution and statement of
changes apply to redistribution; both are in
`LonghandEngines/.../Resources/Licenses/` and are shown in the app under
Acknowledgments.

## Commands

```bash
# Deterministic-core unit tests (fast, pure macOS; run these constantly)
swift test --package-path LonghandKit
swift test --package-path LonghandKit --filter MergeEngineTests   # one suite

# Pipeline tests: no audio, no models. Checkpoints are seeded so run()
# exercises merge → identify → export, the path every overlay feature rides
swift test --package-path LonghandEngines

# CI (.github/workflows/ci.yml) runs both of the above on every push to main,
# and adds unsigned iOS and Mac app builds on pull requests and manual runs.
# site/ is the App Store privacy policy and support pages; pages.yml deploys
# it to https://shpala.github.io/Longhand-Transcribe/ when it changes. The
# privacy policy makes factual claims about the app: keep it true when
# behaviour changes (network use, what is stored, what is backed up).

# Everything else goes through the run skill's driver:
D=.claude/skills/run-longhand/driver.sh
$D build sim                    # simulator build (resolves valid destination)
$D uitest LonghandUITests/RecordingFlowUITests sim   # UI suites = the app driver
$D device-install               # build + install on the owner's iPhone
$D pull sim build/recs          # job folders (checkpoints/transcripts) = ground truth
```

The `/run-longhand` skill (`.claude/skills/run-longhand/SKILL.md`) is the
authoritative how-to-run/test/debug reference, including hard-won gotchas
(simulator capability gaps, XCUITest quiescence, model-download budgets,
device flakiness signatures). Read it before running or debugging the app.

Xcode's SourceKit diagnostics are chronically stale for this project
("No such module 'LonghandKit'", cross-file type resolution): `swift test`
and `xcodebuild` are the arbiters, not editor diagnostics.

## Architecture

Three layers with hard boundaries:

- **`LonghandKit/`**: local Swift package; the deterministic core. Pure
  Foundation only (no AVFoundation/Speech/UIKit), so it tests on macOS in
  milliseconds. Contains: canonical Codable models (ASR contract §6.3,
  transcript JSON §13.1), engine protocols (§16.1), the word-to-speaker
  merge (τ tolerance, segment-first, hysteresis; §8), turn builder,
  hallucination filter (§6.4), `.hda`/MPEG format probe (§5.5), bidi export
  helpers + all exporters (§15.4), job state machine (§10), atomic
  checkpoint I/O, speaker profile matcher (§9.3), quiet-take gain policy,
  `UserOverlay` (user-authored content) + `TextFold`/`StableHash`,
  `TranscriptSearch`, `TranscriptIndex`. New deterministic logic belongs
  here, with tests.
- **`LonghandEngines/`**: local Swift package; OS-coupled but
  cross-platform (iOS + macOS). Engines (`AppleSpeechEngine`,
  `WhisperKitEngine` + `WhisperModelVariant`, `SpeakerKitDiarizer`,
  adapter class `CommunityOneDiarizer`), AVFoundation audio normalization
  (incl. QuietBoost application) + format adapter chain, `ImportService`,
  pipeline orchestration (`JobPipeline`), `JobStore`,
  `SpeakerProfileStore`, `LocationCapture`, the bundled licence texts +
  `Acknowledgments` catalog, and the shared UI-facing types both shells use:
  `JobLibraryModel` (one library model, platform bits injected),
  `TranscriptPlayer`, `LibrarySearch`, `WordTapText` (per-word hit testing),
  `TranscriptScreenModel` (the transcript screen's data, marker placement and
  every correction; the views keep only the player, presentation and error
  reporting), `TurnBodyText`/`MarkerRow`/`PlaybackTurnTracker`,
  `ProcessingTimings`/`NoSpeechDiagnostics` (transcript-screen diagnostics both
  shells render identically).
  Builds standalone for macOS
  (`swift build --package-path LonghandEngines`), and that build succeeding
  is what keeps the Mac app cheap.
- **`Longhand/` (+ `LonghandWatch/`, `LonghandMac/`)**: platform shells;
  everything platform-specific. iOS: `AVAudioSession` recording, location
  capture, background execution (`Jobs/BackgroundExecution`), watch receiver
  (`WatchLink`), SwiftUI. One binary serves iPhone and iPad
  (`TARGETED_DEVICE_FAMILY = "1,2"`): `LibraryView` branches on
  `UIDevice.current.userInterfaceIdiom` into a `NavigationSplitView` for iPad
  or the `NavigationStack` for iPhone, and `AppCommands.swift` adds the
  hardware-keyboard verbs an attached iPad keyboard expects.
  Other apps share audio and video into it through `CFBundleDocumentTypes`
  (Alternate rank, not opened in place): iOS copies the file into
  `Documents/Inbox`, `LibraryView.receiveShared` imports it with the saved
  defaults and deletes that copy.
  A take in progress is also a Live Activity (`LonghandLiveActivity/`, an
  iOS WidgetKit extension embedded in the app): Lock Screen card and Dynamic
  Island with Pause/Resume, Mark and Stop. `RecordingActivity.swift` there is
  compiled into both targets (a synchronized-group membership exception on
  the app), because ActivityKit matches by type and the buttons name the
  intents; the intents only run in the app, through the handler `RecordSheet`
  installs. One parameterless intent per button: an `AppEnum` parameter set in
  the widget arrived in the app as nil.
  Siri, Shortcuts and the Action Button: `Longhand/Intents/` (compiled into
  the Mac target as well, through a membership exception; Stop Recording,
  Transcribe Audio File, Get Transcript, Open Recording, a `RecordingEntity`
  searched like the library, and the App Shortcuts phrases). Start Recording
  sits in the shared `LonghandLiveActivity/RecordingIntents.swift` because the
  "Record with Longhand" Control (Control Center, Lock Screen, Action Button)
  names it. Intents never touch a view: they leave a request in `AppRequests`,
  which `LibraryView` observes with `initial: true`, since a cold launch runs
  the intent before any view exists. Get Transcript asks before handing text
  to a shortcut (§14.1). The Mac gets the same intents and phrases (no
  Action Button or Control there); `MacLibraryView` observes `AppRequests`
  and `MacRecordSheet` installs the `LiveRecordingControls` handler, so the
  shared `RecordingIntents.swift` must never import an iOS-only framework.
  Playback outside the app goes through `NowPlaying` (in `LonghandEngines`,
  so the Mac gets Now Playing and the media keys from the same code):
  `TranscriptPlayer` claims the system controls on its first `play()`, never
  on load, and only its own `stop()` releases them. The `.playback` category
  is set before the `AVAudioPlayer` is built, or its queue is never eligible
  for the Lock Screen.
  Watch: capture UI + `WCSession` hand-off, plus
  `LonghandComplication/`, a WidgetKit extension embedded in the watch app
  whose tap opens `longhand://record` to start a take. Mac:
  `NavigationSplitView` library, drag-and-drop import, `AVAudioRecorder`
  capture without an audio session, `fileExporter` exports, Settings scene
  (transcription defaults, location, enrolled voices, acknowledgments). Its
  own library, no sync with the phone in v1. The project uses
  filesystem-synchronized groups: files dropped under `Longhand/` /
  `LonghandWatch/` / `LonghandMac/` join their targets automatically. All
  three shells build in **Swift 6 language mode** and default to MainActor
  isolation: mark services `nonisolated`; the packages are
  nonisolated-by-default as usual. A system callback documented to arrive on
  the main queue (`NotificationCenter … queue: .main`) reaches main-actor
  state through `MainActor.assumeIsolated`, not an async hop; hopping would
  let a `stop()` interleave.

Pipeline flow (all stages checkpointed, §10):

```
import/record → adapter chain (§5.5: container → MPEG-ES → confirmed raw PCM)
  → normalize to 16 kHz mono WAV (§5.4, transient, deleted at COMPLETE §13.4)
  → engine routing (§4.2: per-language; "auto" sentinel = WhisperKit with
     per-chunk language detection) → hallucination filter (Whisper path only)
  → SpeakerKit diarization (degrades per §17 if unavailable)
  → merge (MergeEngine, params recorded for re-merge reproducibility)
  → centroid speaker identification (§9.3, optional)
  → transcript.json (canonical) + MD/TXT exports
```

Per-job state lives in `Documents/Recordings/<UUID>/` as numbered checkpoint
files (`10_asr.json`, `20_diarization.json`, …) plus `job.json`. When
debugging, pull and read these instead of guessing from the UI.

## Invariants that are easy to break

- **`transcript.json` and every export are derived** from
  `(30_merged_words.json, 40_identity.json, overlay.json)`. User intent
  (speaker names, text edits, per-turn reassignments, markers) lives only in
  `overlay.json`, never in the derived transcript; that is what lets the merge
  stage rebuild turns on every run without erasing anything. Mutations go
  through `JobPipeline.updateOverlay` (change the overlay, then `rerender`),
  and `TranscriptExporter.writeAll` applies the overlay so no export path can
  bypass it. Anchors use start time + cluster + a folded-text hash; never
  `Turn.id`, which is positional.
- **The record is reconciled against the checkpoints** at the start of every
  `JobPipeline.run`: a kill between writing a stage file and writing `job.json`
  leaves the state behind the disk, and gating stages on a stale state either
  skips work or trips an illegal transition. Stage bookkeeping uses `advance`,
  which no-ops rather than failing a job whose work succeeded.
- **Pipeline runs are serialized** through `JobLibraryModel.pipelineGate`: each
  one loads a 626 MB (or 947 MB) model, so N concurrent jobs is a jetsam.
- **User-owned `JobRecord` fields** (`title`, `pausedByUser`) are merged from
  disk by `JobPipeline.persist`: a run holds its record in memory for minutes
  and would otherwise clobber a rename or a pause made while it worked.

- **State transitions only via `JobRecord.transition(to:)`**. The machine
  has deliberate re-entry edges (COMPLETE→MERGED re-merge, COMPLETE→PREPARED
  explicit re-run §13.2) and deliberate absences. Never assign `state`
  directly.
- **Checkpoints are atomic** (temp + rename) and truncated checkpoints must
  read as absent-with-error, never trusted. Exports are projections;
  `transcript.json` is the source of truth.
- **Honesty rules from the design doc**: `avgLogprob` is never presented as
  a confidence/percentage (§6.3); degradations are surfaced in
  `JobRecord.degradations`, never silent (§17); model downloads report as a
  distinct stage, not as transcription (§14.2); `matchScore` vs
  `confirmedByUser`: a user statement always beats a model match (§13.1).
- **Speaker embeddings are biometric-like** (§14.1): local only, never in
  any export, complete deletion supported. `speaker-profiles.json` is
  excluded from iCloud/Time Machine backup, so deletion leaves no copy behind.
- **Models are excluded from backup** through the flag on
  `Documents/huggingface` (`ModelStaging.excludeFromBackup`). Keep them under
  that folder; Caches would let the system purge a 626 MB download.
- **`UIBackgroundModes: audio` is what keeps a take recording** with the
  screen locked (`BackgroundRecordingUITests`, which only catches its removal
  on a device). Removing it looks harmless and truncates every locked-screen
  recording.
- **Turns carry a stable `cluster` key** alongside the display name; renames
  and re-identification rewrite display names via the `speakers` table only.
- **WhisperKit with `language: nil` requires `detectLanguage: true`**,
  otherwise it silently decodes as English.
- **`Longhand/Info.plist` is a partial plist** (BGTask identifiers) merged
  into the generated one; the pbxproj has a synchronized-group exception
  excluding it from resources. Don't "simplify" either side.
- UI-test determinism comes from app-side launch hooks (`--uitest-reset`,
  `--uitest-synth-import he|ru|auto` in `UITestSupport.swift`). Extend
  those rather than asserting on mic-captured audio, which is unassertable.
