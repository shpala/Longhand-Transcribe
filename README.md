# Longhand

[![CI](https://github.com/shpala/Longhand-Transcribe/actions/workflows/ci.yml/badge.svg)](https://github.com/shpala/Longhand-Transcribe/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

Transcripts that never leave your device.

Longhand records or imports a conversation and turns it into a transcript,
with each person's words attributed to them. Speech recognition and speaker
detection run on the iPhone, iPad, Apple Watch or Mac itself. There is no
server, no account, no analytics, and nothing is uploaded.

- **App Store:** [Longhand Transcribe](https://apps.apple.com/app/id6805631549) for iPhone and iPad.
  The Mac app is in App Review; until it appears, build it from this repository.
- **Website:** [shpala.github.io/Longhand-Transcribe](https://shpala.github.io/Longhand-Transcribe/)
  (privacy policy and support).

## What it does

- **Speaker-attributed transcripts.** Every passage carries the name of
  whoever said it. Rename a speaker everywhere, move one passage to someone
  else, split a passage, or select several and reassign them at once.
- **Voices it can learn.** Turn on "Remember this voice" when naming a
  speaker and later recordings propose that name. Voice profiles stay on the
  device, are never exported, are excluded from backups and can be deleted
  at any time.
- **Many languages, including Hebrew and Russian**, and recordings that
  switch between languages mid-way. Languages Apple's on-device recognizer
  covers use it; the rest use a Whisper model that is downloaded once, with
  your consent, and then works offline.
- **Record anywhere.** Phone, iPad, Mac or Apple Watch, with the watch
  handing its takes to the phone. A take in progress is a Live Activity on
  the Lock Screen and in the Dynamic Island, with Pause, Mark and Stop. Siri,
  the Shortcuts app, the Action Button and Control Center can start and stop
  a recording.
- **Import from other apps.** Share audio or video from Voice Memos, Files,
  Mail and others, or drag files onto the Mac window.
- **Corrections you can revert.** Edit text, place and label markers, type
  notes while recording. Corrections are stored apart from the machine
  output, so re-running speaker matching never loses them and any edit can
  be undone.
- **Summaries** from Apple's on-device model where Apple Intelligence is
  available, marked stale when the transcript changes.
- **Exports** to Markdown, plain text and JSON, each behind a confirmation.
  The JSON keeps the timing and speaker of every passage, and never the
  voice profiles or location.
- **Found from outside the app.** Recordings and their words are in Spotlight,
  a Home Screen widget lists the latest takes, and an iPad can open each
  transcript in its own window.

## Privacy

Longhand collects no data. The only network traffic the app itself makes is
the one-time download of a speech model from the publisher's Hugging Face
repository, after you agree to it. Recordings, transcripts, notes, voice
profiles and location tags (off by default) live in the app's container on
your device. The full policy is at
[site/privacy](site/privacy/index.html); it makes factual claims about the
code, so a change in behaviour has to keep it true.

## How it works

```
record or import
  -> format adapters (container, MPEG elementary stream, raw PCM)
  -> normalize to 16 kHz mono WAV
  -> speech recognition (Apple Speech per language, or WhisperKit with
     per-chunk language detection), hallucination filter on the Whisper path
  -> speaker diarization (SpeakerKit, pyannote community-1 models bundled)
  -> word-to-speaker merge, turn building
  -> speaker identification against enrolled voices (optional)
  -> transcript.json plus Markdown and text exports
```

Every stage writes an atomic checkpoint under the recording's folder, so a
kill at any point resumes rather than restarts. The transcript and every
export are derived from the merged words, the identification result and a
separate overlay holding everything the user wrote. That separation is what
lets the merge stage rebuild turns on every run without erasing a correction.

Speech recognition and diarization come from
[argmax-oss-swift](https://github.com/argmaxinc/argmax-oss-swift) (WhisperKit
and SpeakerKit). The Whisper weights are fetched on first use; the diarization
models ship inside the app.

## Repository layout

| Directory | What it holds |
|---|---|
| `LonghandKit/` | The deterministic core: data models, the merge engine, turn builder, hallucination filter, exporters, job state machine, overlay, search. Pure Foundation, so it tests on macOS in seconds. Also the offline `longhand-accuracy` tool. |
| `LonghandEngines/` | Everything OS-coupled but shared by every shell: the speech and diarization engines, audio normalization, import, pipeline orchestration, stores, Spotlight indexing, and the screen models both UIs render. |
| `Longhand/` | The iPhone and iPad app. |
| `LonghandMac/` | The Mac app. Same pipeline and on-disk layout, its own library. |
| `LonghandWatch/`, `LonghandComplication/` | The Apple Watch capture app and its complication. |
| `LonghandLiveActivity/` | Lock Screen and Dynamic Island card, the record control, and the Home Screen widget. |
| `LonghandUITests/` | XCUITest suites that drive the app end to end. |
| `docs/` | The design specification and the implementation map (see below). |
| `site/` | The privacy policy and support pages, deployed by GitHub Pages. |
| `.claude/skills/run-longhand/` | The build, test, device and simulator driver used in development. |

## Building from source

Requirements: macOS 26 and Xcode 26 (iOS 26 SDK). The Swift packages resolve on
first build; nothing else to install.

Open `Longhand.xcodeproj`, pick the `Longhand` or `LonghandMac` scheme and a
simulator, and run. No signing identity is needed for a simulator. To run on a
device or to distribute, put your team ID in a gitignored file:

```
# Config/Local.xcconfig
LONGHAND_TEAM_ID = ABCDE12345
```

The three shells compile in Swift 6 language mode with main-actor isolation by
default; the packages are nonisolated by default, as usual.

### Tests

```bash
swift test --package-path LonghandKit        # deterministic core, fast
swift test --package-path LonghandEngines    # pipeline tests: no audio, no models
```

The pipeline tests seed the recognition and diarization checkpoints, so a run
exercises merge, identification and export without loading a model. CI runs
both on every push and additionally compiles every shell, unsigned, on pull
requests.

The UI suites in `LonghandUITests/` are the interaction harness. The driver
script wraps the build, launch, seed, screenshot and pull commands they need:

```bash
D=.claude/skills/run-longhand/driver.sh
$D build sim
$D seed-sim                                         # install a committed, completed job
$D uitest LonghandUITests/TranscriptUISmokeTests sim
$D pull sim build/recs                              # job folders are the ground truth
```

The skill's `SKILL.md` documents which suites need a seeded library, what the
simulator cannot do (no Apple speech, no diarization) and the device and watch
gotchas. Read it before debugging the app.

## Documentation

- `docs/design-v1.1-redline.md` is the specification. It is a redline: the
  inserted v1.1 text is what the code follows.
- `docs/IMPLEMENTATION.md` maps each section of the specification to the
  code, and records what is deliberately deferred and why.
- `CLAUDE.md` lists the invariants that are easy to break (derived exports,
  checkpoint reconciliation, serialized pipeline runs, backup exclusions,
  background audio) and is worth reading before changing the pipeline.

## Licence

Longhand is released under the Apache License 2.0; see `LICENSE`. The
bundled and downloaded third-party work and the attribution it requires are
listed in `NOTICE` and shown in the app under Acknowledgments.

## Issues

Bug reports and questions go to the
[issue tracker](https://github.com/shpala/Longhand-Transcribe/issues).
Please do not attach recordings or transcripts; none are needed to describe a
problem.
