# Implementation status vs. design v1.1

Source spec: `docs/design-v1.1-redline.md` (parsed from
`local-transcription-design-v1.1-redline.docx`, 18 Aug 2026). All §-references
below point into that document. Redline conventions: this implementation
follows the **v1.1 inserted text**, not the struck v1.0 text.

## What is left (22 Aug 2026)

Grouped by what actually blocks each item, because "deferred" has been covering
three different situations.

**Waiting on one recording, not on code.** Both harnesses exist, both run, and
both currently answer "not enough data". One take with the same two people,
speaker names confirmed and a few turns corrected, settles both at once.

- §6.1, Turbo vs non-distilled large-v3 on Hebrew. `$D accuracy <dir> --by
  model` compares them over the corrections. Needs one recording transcribed by
  both variants with some turns corrected.
- §18.2, speaker-matcher calibration. `$D accuracy <dir> --calibration` reports
  NOT CALIBRATED today: every labelled voice comes from the single recording, so
  there is no same-voice-across-takes pair, which is exactly what the score
  floor rests on.

**Blocked on something this project cannot produce.**

- DER / cpWER / WDER (§18.1). These need ground truth about *who was speaking*,
  and the overlay does not carry it: a reassignment records which cluster a turn
  was moved to, not whose voice it was. The word-error half is done; this half
  needs annotation that does not exist as a by-product of using the app.
- The `[VERIFY]` items at the end of this document. They need Apple, or a
  decision, not an implementation.
- `tools/hda2mp3.sh`, referenced by §5.5 as the porting source, is not in this
  repo and never was.

**Deliberately gated, working as intended.**

- Stereo diarizer bypass (§5.3): the gate asks for measurements first, and
  `metadata.json` has been collecting them since import was written.
- TitaNet / sherpa-onnx (§9.1): centroid matching has not proved insufficient.

**Genuinely still to do.**

- Phase 0 benchmark and the CI offline assertion (§18.1).

## Layout

- **`LonghandKit/`**: local Swift package holding the deterministic core:
  pure-Foundation, platform-independent, tested with `swift test` on macOS
  (200 tests). This is the §16 module structure minus OS-coupled layers.
- **`LonghandEngines/Tests/`**: pipeline tests that need no audio and no
  models: seeding `10_asr.json` + `20_diarization.json` makes `run()` skip to
  merge → identify → export, and stub engines fail the test if inference is
  reached. This is the guard on the re-merge path.
- **`LonghandEngines/`**: local Swift package, the OS-coupled but
  cross-platform middle layer (engines, normalizer, adapters, import,
  pipeline, stores). Compiles for iOS and macOS; shared by the iOS, watch,
  and macOS shells.
- **`Longhand/`**: iOS app target (SwiftUI, AVAudioSession recording,
  BGTask background execution, location, watch receiver). Files added here
  join the target automatically (filesystem-synchronized group).
- **`LonghandWatch/`**: watchOS capture app (see the watch row below).
- **`LonghandMac/`**: native macOS app target (SwiftUI, sandboxed,
  hardened runtime). Same pipeline and on-disk job layout as iOS, in its own
  container: sidebar library grouped by day, drag-and-drop and Open-panel
  import, in-app recording via `AVAudioRecorder` (macOS has no audio
  session), transcript with karaoke highlight, speaker rename + voice
  enrollment + auto-match confirmation (§9.2, §9.3, §13.1), exports through
  `fileExporter` behind the §14.1 confirmation, and a Settings scene with
  transcription defaults, location toggle, enrolled-voice management (§14.1
  deletion), and acknowledgments.
  No phone↔Mac sync in v1; the two libraries are independent.

## Implemented

| Design section | Where | Notes |
|---|---|---|
| §6.3 ASR output contract | `LonghandKit/Sources/LonghandKit/Models/ASRModels.swift` | `avgLogprob`, never `confidence`; `engine` required; optional-score tolerated |
| §7.2 diarization output, overlap regions | `Models/DiarizationModels.swift` | includes `forcedSpeakerCount` for the §17 row |
| §13.1 canonical transcript JSON | `Models/Transcript.swift` | `matchScore`+`confirmedByUser`, `mergeParams`, `overlapped`, engine-qualified `models.asr`; turns carry `cluster` so renames are deterministic |
| §16.1 protocols | `Protocols.swift` | `SpeechTranscribing` (renamed per v1.1 amendment), capability declaration, `AudioSourceAdapter` |
| §10 state machine | `Jobs/JobState.swift` | EXPORTED removed; re-entry edges `COMPLETE→MERGED`, `COMPLETE→IDENTIFIED`, `COMPLETE` self-edge; `TRANSCRIBED→MERGED` degrade edge |
| §10.1 per-job files, atomic checkpoints | `Jobs/JobFiles.swift` | temp-write + rename; truncated checkpoint reads throw `checkpointCorrupt` and are never trusted |
| §8 merge (τ, segment-first, hysteresis) | `Merge/MergeEngine.swift` | word attribution always retained for τ re-merge without inference |
| §8.1 turn construction + island smoothing | `Merge/TurnBuilder.swift` | raw word attribution preserved through smoothing |
| §8.2 overlapped speech policy | merge + turn builder + exporters | flag detected, propagated, surfaced, never dropped |
| §6.4 hallucination mitigations | `ASR/HallucinationFilter.swift` | logprob **and** silence required jointly; repeated tail trimmed not whole segment; suppressions recorded with reasons |
| §5.5 format probe (.hda) | `Ingest/FormatProbe.swift` | container-first ordering, positive frame-sync (6 consecutive consistent frames), plausible-duration check |
| §15.4 bidi | `Export/BidiText.swift` | first-strong detection; directional isolates in exports; per-turn direction in UI |
| §2.1 exporters | `Export/Exporters.swift` | JSON canonical + MD/TXT (SRT and WebVTT removed by owner decision, see below); `writeAll` applies `overlay.json` so no export path can bypass user edits, and returns which edits went stale |
| User-authored content (addition) | `LonghandKit/Sources/LonghandKit/Edits/UserOverlay.swift`, `overlay.json`, `JobPipeline.rerender`/`updateOverlay` | speaker names, text edits, per-turn reassignment, markers. Text edits anchor on start time + cluster + folded-text hash (never the positional `Turn.id`, never `end`, since joins and splits preserve `start`); a stale edit is kept and reported, never dropped. Reassignment is a midpoint-matched time range writing `assignedCluster`, so the diarizer's own claim stays readable for centroids and enrollment. Rebuilding from checkpoints is what makes un-editing possible |
| Search (addition, §15.4) | `LonghandKit/Sources/LonghandKit/Text/TextFold.swift`, `Search/TranscriptSearch.swift`, `LonghandEngines/Sources/LonghandEngines/LibrarySearch.swift` | nikkud-insensitive Hebrew matching, final-form folding, geresh dropped, bidi controls stripped (exports inject them); ranges point into the original text for highlighting. Hebrew clitic prefixes (ו/ב/כ/ל/מ/ש/ה) are stripped off the *query* as a fallback, so `לרופא` finds `הרופא`; the substring scan already covered the other direction. Fallback only, and the stemmed hit must start a word modulo clitics, so `שלום` cannot match `חלום`. No persisted index; a per-job scan with an mtime cache keeps §14.1 complete deletion free |
| Pause / resume (addition) | `JobRecord.pausedByUser`, `JobLibraryModel.pause`, `BackgroundExecution` cancellation handler | `Task.checkCancellation()` at each stage boundary **and inside the three loops that run for minutes**: `AudioNormalizer`'s two chunk loops, `SpeakerKitDiarizer.loadSamples`, and WhisperKit's decode (via its per-token `callback` returning false, which runs on a detached task, so a `CancellationFlag` set from `withTaskCancellationHandler` is the only way it can see the cancel; early stopping yields partial results, so the engine re-throws rather than checkpointing a truncated transcript). The diarization stage rethrows `CancellationError` instead of degrading, because a pause is not the diarizer failing (§17). The handle is registered inside `run` so imports are stoppable too; the row says "Stopping…" until the pipeline reaches a checkpoint, and `resumeInterrupted` leaves user-paused jobs alone |
| Copy paths (addition) | per-turn context menus, "Copy Transcript" | the clipboard goes through the §14.1 confirmation like any other export |
| Empty-transcript state (§17 addition) | `JobPipeline.run`, both transcript views | a job with no turns records a degradation and distinguishes silence from speech the §6.4 filter removed; the screen shows the evidence (including quiet-take gain) instead of a blank page under a green Complete |
| Filtered speech is reported (§6.4 / §17) | `JobPipeline.run`, `SuppressedSpans` in `TranscriptDiagnostics.swift`, both transcript views | the degradation fires whenever `suppressedSpans` is non-empty, not only when the filter emptied the transcript. It previously fired only on an empty transcript, so the common case (a transcript with words in it, minus a passage) was reported nowhere: the span was written to `10_asr.json` and nothing read it back, which does not satisfy §6.4's "never silently discard". The note says how many; a collapsed `SuppressedSpans` group beside `ProcessingTimings` says which, with the text and a plain-language reason, because the filter is usually right and a reader who can see the words can tell. Verified against the owner's own library, where job `BE5716F9` carried a `verbatimRepeat` of "איפה נד?" at 12.88 s and an empty `degradations` array |
| Model assets (§13.3 addition) | `WhisperKitEngine.prefetch` / `isDownloaded` / `downloadedBytes`, `ModelSettingsSection` (iOS), `MacModelRow` | per-variant state, size and a Download button so the first recording is not where the 626 MB fetch is discovered; presence now requires compiled `.mlmodelc` bundles, since a half-finished download leaves a non-empty folder |
| Honest progress (§17 addition) | `PipelineProgress.isDeterminate/processedSeconds/totalSeconds/overallFraction` | transcription reports "12:30 of 48:00"; second-long stages show motion, not an invented percentage; WhisperKit's out-of-order VAD reports are latched monotonic; the background pill uses the whole-job fraction through a ratchet, instead of the per-stage one that reset it each stage |
| Mac keyboard + documents (addition) | `LonghandCommands`, `LonghandMac/Info.plist`, `LonghandAppDelegate` | File/Edit/Playback menus with ⌘R/⌘O/⌘⌫/space/⌘←→; `CFBundleDocumentTypes` + an imported `.hda`/`.hta` type so dock drops and Open With work |
| Watch take correlation (addition) | `WatchTransfer` take id → `ImportMetadata.sourceTakeID` → `WatchLink.push` | the wrist can tell its own take's progress from another job's status, and shows the transfer queue depth |
| Watch upload progress (addition) | `WatchTransfer.sendProgress` from `WCSessionFileTransfer.progress`, polled 400 ms | the upload had no indicator, only the text "Sending to iPhone…", because the transfer handle returned by `transferFile` was discarded. Polled rather than KVO-observed, following `AppleSpeechEngine`'s precedent, and the handle (not `Sendable`) rides in an `UncheckedBox` so only the `Double` crosses to the main actor. Kept visually separate from `phoneProgress`: leaving the watch and being transcribed on the phone are different waits and used to look identical |
| Watch → phone Handoff (addition) | `.userActivity(WatchTransfer.handoffActivityType,…)` on the watch, `.onContinueUserActivity` on the phone | **No API lets watchOS foreground an app on the iPhone**, verified against current docs, and watchOS 26 Controls explicitly exclude actions that would do it. Handoff is therefore the whole mechanism: the watch advertises, the user completes it from the *bottom* of the iPhone's App Switcher. The affordance was a `Label`, which looks and behaves tappable while doing nothing; it is a `Button` that explains where to go. `hasDeliveredTake` is cleared when a new send starts; it never was, so one delivery left the activity advertised for the rest of the session. Note the watch's own `NSUserActivityTypes` entry is inert (watchOS can send activities, not receive them); only the phone's declaration matters |
| Transcript editing (addition) | `JobPipeline.editTurnText`/`clearTurnEdit`, editor sheets on both shells | whole-turn text; edited turns are marked and fall back to a turn-level highlight since word timings no longer describe them; revert restores the derived text |
| Per-turn speaker reassignment (addition) | `JobPipeline.assignTurn`, `Turn.assignedCluster`, speaker chip menu in both shells | one passage moves without touching the diarizer's claim, so §9.2 enrollment eligibility and centroid lookup are unaffected. The chip is a scope chooser: "this passage is someone else" versus "rename, N passages", the count naming a reach the chip cannot otherwise show |
| User-defined speakers (addition) | `UserOverlay.mintSpeakerCluster()` / `isUserDefined`, `USER_<hex>` keys | the diarizer folding a third person into someone else's cluster leaves nothing to reassign *to*; "Someone else…" mints a cluster the overlay seeds into the speakers table. No centroid exists for it, so `canEnroll` refuses enrollment without a special case: an invented speaker is a label, never a voiceprint. Undoing the last passage prunes the orphaned name |
| Markers (addition) | flag button on all three record surfaces → `ImportService(markers:)` → overlay → transcript + Markdown | `AVAudioRecorder.currentTime` excludes paused time, so marker times share the transcript's clock |
| Per-word tap-to-seek (addition) | `LonghandEngines/Sources/LonghandEngines/WordTapText.swift` (`WordFrameRenderer`, `WordFrames`) | words stay in one `Text` so SwiftUI keeps bidi reordering intact; the renderer reports each word's frame and also draws the active word's wash |
| Playback (addition) | `LonghandEngines/Sources/LonghandEngines/TranscriptPlayer.swift` | one player for both shells: speed 0.75×-2× (remembered), ±15 s skip, clock ticking only while playing |
| §15.2 ⟨R-16⟩ rendering at scale | `LonghandKit/Sources/LonghandKit/Transcript/TranscriptIndex.swift` + per-row observation | binary-search time→turn with a forward cursor, word slices precomputed at load (also fixes a word being claimed by two abutting turns); the 10 Hz repaint is confined to the active row instead of the whole list |
| §5.1-5.3 import, channel stats | `LonghandEngines/Sources/LonghandEngines/ImportService.swift`, `Audio/AudioNormalizer.swift` | stereo stats recorded, **not** branched on (bypass deferred per §5.3) |
| Apple Watch capture (addition) | `LonghandWatch/` target, `Longhand/WatchLink.swift` | the watch is a third ingest source: on-watch AAC recording (brand-matched record surface, waveform meter), WCSession `transferFile` to the phone, phone-side receiver feeds the normal import pipeline and reports the latest job's state back to the wrist. `--uitest-autotake` launch hook for watch-sim determinism. Sim gotcha: transferFile never delivers between paired simulators (watch reports success; phone wcd sees nothing), so hardware-only verification for the transport hop |
| Capture location (addition) | `LonghandKit` `CapturedLocation` (+ISO 6709 parser, tested), `LonghandEngines` `LocationCapture` (shared by the iOS and Mac shells) | one-shot when-in-use fix at record start (Settings toggle on iOS and macOS, **default off**; the watch has no settings screen and follows the phone's answer, pushed in the status context); imported files use their embedded ISO 6709 metadata; stored in `metadata.json` ONLY, never in transcript.json or any export (same rule as §14.1 embeddings); shown as raw coordinates (reverse geocoding would send them to a network service), tap/click opens Maps; on macOS the fix comes from Wi-Fi positioning and needs the `personal-information.location` sandbox entitlement |
| Quiet-take gain recovery (§5.4 addition) | `LonghandKit/Sources/LonghandKit/Ingest/QuietBoost.swift` (policy+tests), `Audio/AudioNormalizer.swift` | whole-take peak < −12 dBFS → clip-safe boost to −3 dBFS (cap +30 dB, silence floor −60 dB) applied to the transient PCM only; surfaced as a degradation note and recorded in `metadata.appliedGainDb` (§17). Gotcha: AVAudioFile finalizes the WAV header only on dealloc, so writers must be scoped out before any re-read, or readers see zero frames |
| §5.5 adapter chain + MPEG ES decode | `LonghandEngines/Sources/LonghandEngines/FormatAdapters.swift` | AudioToolbox with per-layer file-type hints; raw PCM only behind explicit user confirmation |
| §4.2 engine routing | `LonghandEngines/Sources/LonghandEngines/JobPipeline.swift` | per-language selection; substitutions recorded as visible degradations |
| Apple engine | `LonghandEngines/Sources/LonghandEngines/AppleSpeechEngine.swift` | iOS 26 `SpeechAnalyzer`/`SpeechTranscriber`, word timings via `audioTimeRange` |
| §13.3 disk preconditions | `ImportService.checkDiskPreconditions` | checked before the copy and before jobs start |
| §13.4 retention | `JobPipeline` + `JobFiles.deleteTransientArtifacts` | normalized PCM deleted at COMPLETE |
| §15.1-15.3 UI | `Longhand/UI/*` | library grouped by day ("Today"…), lazy transcript view, rename-without-inference, assign-to-enrolled-person in the rename sheet, degradation banners, raw-PCM confirm dialog, delete confirmation, import-failure alerts, auto-resume of INTERRUPTED jobs, Settings screen (transcription defaults, Enrolled Voices, §13.4 disk usage), `reidentify` wired to UI (per-job context menu, transcript actions menu, all-jobs from Enrolled Voices) |
| §14.3 logging | (by construction) | nothing logs transcript text or filenames; no logging framework wired yet |
| In-app mic recording (addition, not in the doc) | `Longhand/Audio/RecorderService.swift`, `UI/RecordSheet.swift` | records meetings/notes via AVAudioRecorder (AAC m4a) and feeds the normal import pipeline; §2.2's *call*-recording non-goal is untouched. Temp takes are deleted on cancel and after the protected copy is made. Live level meter (Canvas, because subview churn starves UI-test quiescence). Stop & Save starts processing immediately with persisted defaults; long-press offers the §7.1 options sheet. Permission-denied state links to Settings |
| §15.2 playback | `Longhand/UI/TranscriptView.swift` (`PlaybackTurnTracker`, `PlaybackBar`), `LonghandEngines/Sources/LonghandEngines/TranscriptPlayer.swift` | AVAudioPlayer on the retained original; tap a turn to seek+play; the playhead is published only while audio moves, and only the playing row reads it, so a tick repaints one row rather than the list |
| Speaker chips + one-tap confirm | `UI/TranscriptView.swift` | speaker names are tappable chips; "auto" chips offer one-tap confirm (flips `confirmedByUser`, §13.1) or rename |
| §13.2 explicit re-run | `JobPipeline.retranscribe`, `RetranscribeMenu` | COMPLETE→PREPARED re-entry edge; deletes ASR+downstream checkpoints, keeps original+metadata; offered on rows and in the transcript menu. Validates the state transition **before** rewriting metadata or deleting anything, and `JobLibraryModel.retranscribe` refuses while the job is running; otherwise a rejected call still changed the language and destroyed a live job's checkpoints |
| §14.2 honesty in UI | `JobStage.downloadingModel` | model downloads surface as "Downloading speech model (one-time)…" instead of masquerading as transcription |
| Export chooser | transcript toolbar export menu | all five formats plus original audio, each behind a §14.1 confirmation dialog, then the system share sheet; re-transcribe and re-identify live in a separate actions menu |
| Brand palette | `Assets.xcassets` (AccentColor, LonghandIndigo/Cream/Background/Highlight), `UI/BrandMark.swift` | the icon's indigo/cream identity inside the app: indigo accent (light+dark variants), indigo-tinted dark background, brand mark on empty states and launch screen; record sheet is the signature surface (indigo field, cream timer, waveform-stroke level meter); transcript body sets in serif |

Tests (`LonghandKit/Tests`): merge determinism and ±300 ms jitter stability
(§18.2), hysteresis, UNKNOWN fallbacks, overlap flagging and propagation,
hallucination rules incl. the long-silence corpus miniature, probe order and
garbage rejection, bidi golden samples per export format, state-machine edges,
truncated-checkpoint rejection.

## §4.3 licensing gate, audited for App Store distribution (19 Aug 2026)

Originally waived (18 Aug 2026) as a personal, unpublished build. Re-audited
when the owner considered publishing; findings, verified against the SwiftPM
checkout and the Hugging Face repos the app downloads from:

- **Code**: `argmax-oss-swift` is MIT (LICENSE in checkout); its vendored
  swift-transformers portions are Apache 2.0 (NOTICES). swift-argument-parser
  is only linked into Argmax's CLI executable, not the app products, so no
  attribution needed. → All permissive; texts bundled under
  `LonghandEngines/Sources/LonghandEngines/Resources/Licenses/` (bundled with
  the layer whose dependencies they cover, so every shell ships the same set)
  and listed by `Acknowledgments`, at Settings → Acknowledgments on both iOS and
  macOS.
- **Whisper weights**: upstream OpenAI weights are MIT. Clear.
- **Pyannote Community-1**: CC BY 4.0: commercial use allowed WITH
  attribution (bundled in the acknowledgments screen). pyannoteAI states the
  model "will always remain freely accessible".
- **Open item**: Argmax's Core ML conversion repos (`argmaxinc/
  whisperkit-coreml`, `argmaxinc/speakerkit-coreml`) declare NO explicit
  license on their model cards (checked via HF API + raw README, 19 Aug
  2026). Ungated and served by default from Argmax's MIT SDK, so intent is
  clear, but confirm with info@argmaxinc.com before submission.
- **App Store scaffolding shipped**: `PrivacyInfo.xcprivacy` on all three
  shells (no tracking, no collected data; required-reason: UserDefaults
  CA92.1, DiskSpace E174.1, FileTimestamp **3B52.1** (container files, the
  search cache keys on `transcript.json`'s mtime; the earlier C617.1
  "display to the person" was never what the code does),
  `ITSAppUsesNonExemptEncryption=NO` on iOS and macOS, Acknowledgments
  screen, `LSApplicationCategoryType` + copyright on macOS, the full 16→1024
  macOS icon ladder (it previously declared a lone 1024@2x, so Finder and the
  Dock had no small representations), `NSSpeechRecognitionUsageDescription`
  on iOS and macOS, **not** the watch, which links no engines, and the SDK
  pinned to `exactVersion 1.1.0` so the shipped revision is provably the
  audited one. `--uitest-` scaffolding is `#if DEBUG` apart from
  `isUITestRun`, which shipping views read for animation cadence.
  `xcodebuild archive` succeeds clean and the keys are verified in the
  archived bundle. Still needed to submit: privacy policy URL, support URL,
  Developer Program membership, name check, screenshots, and StoreKit if the
  app ships paid.
- **§4.2.3(ii) model-download consent**: both fetches (WhisperKit's 626/947 MB
  weights and SpeakerKit's ~33 MB Community-1 bundle, the latter unconditional
  on first use) now stop and name their size before downloading. Engines
  declare `pendingDownloadBytes`; `JobPipeline` throws
  `LonghandError.modelDownloadRequired(asset:bytes:)`; `JobLibraryModel`
  surfaces `pendingModelDownload` and both shells present a sheet, on the
  `pendingRawPCMJob` precedent. The diarization stage rethrows it rather than
  degrading, because a consent prompt is not the diarizer failing.

## Review pass (20 Aug 2026)

An eight-dimension review with adversarial verification of every finding: 83
raised, 9 refuted, 66 confirmed and fixed, 8 unverified (their verifiers hit a
session limit, recorded here as unexamined, not as absent). The load-bearing
ones, all now covered by tests:

- Mac exports wrote nothing: the sandbox was `user-selected.read-only`, and
  AppKit refuses to show a save panel at all in that state.
- Editing a turn twice destroyed both corrections: the anchor hash was taken
  from post-overlay text. Anchors are carried forward when replacing an edit.
- A job killed at IDENTIFIED could never finish (illegal self-transition), and
  more broadly the record could lag its checkpoints; see the reconciliation
  invariant in CLAUDE.md.
- Deleting a running job resurrected its folder, because an atomic write
  recreates missing directories.
- `drainIncoming` was re-entrant, importing a watch take up to four times.
- The diarization degradation named the loss but discarded the error, so a
  failed model fetch, an unreadable file and an unsupported device all read
  identically; the note now carries the reason (§17).
- `CommunityOneDiarizer.modelsPresent()` probed Application Support. Argmax
  caches under `Documents/huggingface/...`, the same root
  `WhisperKitEngine.modelFolder(for:)` uses, so the probe reported every
  install as empty, which under the §4.2.3(ii) consent gate means asking for a
  download already on disk before every job. Its declared size was estimated
  at 33 MB; a real download measures 11 MB.
- A half-downloaded Community-1 cache was permanent: the phone's
  `PldaProjector.mlmodelc` arrived incomplete, Core ML answered "Unable to load
  model … Compile the model with Xcode", and every later recording lost its
  speaker labels the same way, because the next download saw files and skipped.
  Presence now means each component holds a `.mlmodelc` carrying both
  `coremldata.bin` and `model.mil` (found at whatever depth the release nests
  them), and a *load* failure (never a download failure, which would delete a
  cache that cannot be replaced offline) purges the tree and refetches once.
- Per-stage wall-clock timings (`JobRecord.stageSeconds`, `JobPipeline.StageClock`)
  measured off the progress sink, so the engines' own download and load are
  covered without instrumenting them separately; monotonic `ContinuousClock`,
  accumulated across a resume, shown collapsed on the transcript. `loadingModel`
  is its own `JobStage` because staging a 626 MB model onto the ANE can outlast
  the decoding it enables on a short take, and folding it into "Transcribing"
  hid that.
- `WhisperModelVariant` gained `base` (146.5 MB), `small` (484.5 MB) and
  `turboSpeedBuild` (638 MB, `large-v3-v20240930_turbo_632MB`). Sizes are summed
  from the vendor's repository, not estimated; the two original variants carry
  their size in the model name, these do not. Each variant states its decoder
  layer count, because "smaller download" does not mean "faster": `turbo` is a
  4-layer distillation and `small` has 12.
- The iPhone offers both selectable builds again. It had been narrowed to
  `turbo` alone, with Settings force-resetting the stored choice on appear, on
  the reasoning that a Mac has thermal headroom a phone does not. The reasoning
  was sound and the remedy was not: it removed the speed/accuracy trade on the
  device that records most of the audio, and it left the §6.1 gate unreachable
  there, since comparing Turbo against non-distilled large-v3 needs one
  recording transcribed by both. `ModelSettingsSection` now mirrors the Mac (a
  picker over `WhisperModelVariant.selectable` plus a download row each) and
  states the cost, per variant via `speedNote`, which until now was defined and
  never rendered. `LanguageHeaderTests.bothBuildsStayOfferable` makes a future
  narrowing a deliberate act rather than a quiet edit.
- Restoring that exposed a §4.2.3(ii) defect the Mac already had:
  `TranscriptionLanguages.modelHeader`/`modelSizeDescription` hardcoded
  `.turbo.approximateBytes`, so with Maximum accuracy selected the language
  picker disclosed a 626 MB download and the pipeline then fetched 947 MB. Both
  now read `WhisperModelVariant.current`.
- Every model download rendered as an indeterminate spinner despite carrying a
  real fraction: the row reads `isDeterminate` off the *latest* `PipelineProgress`,
  and only WhisperKit's first call set it; the per-chunk updates dropped it, as
  did Apple Speech's and the diarizer's entirely. All four sites now set it.
- The speaker models had no download control anywhere: no Settings row (unlike
  the Whisper variants) and no action beside the §17 note that said "download it
  to continue". `CommunityOneDiarizer.prefetch/isDownloaded/downloadedBytes`
  now mirror `WhisperKitEngine`'s, both shells' Settings gained a row, and the
  transcript offers the download inline, then a one-tap re-transcribe, since a
  COMPLETE job's normalized audio is gone (§13.4) and a re-merge cannot redo
  diarization. The offer is gated on the *note*, never on the models being
  missing: gating on the latter made the whole row vanish at the moment the
  download succeeded, which is precisely when the re-transcribe it unlocks
  becomes possible. `prefetch` purges an unloadable tree first, so a repair is a real
  fetch rather than a skipped one.
- A model-download prompt failed the job it was asking about: the generic
  catch in `JobPipeline.run` marked it FAILED and wrote the consent sentence in
  as `errorDescription`, so a phone read "Couldn't transcribe. Speaker
  identification needs a one-time 11 MB download". `LonghandError.isAwaitingAnswer`
  now separates questions (model download, raw-PCM §5.5) from failures; a
  question leaves the job INTERRUPTED with no error text, which is what it is:
  stopped, checkpointed, resumable.
- A job stopped on a question sat in INTERRUPTED with `pausedByUser` unset, so
  the row promised "Interrupted, will resume" and `resumeUnfinished` obliged on
  the next library appearance, hit the same gate and asked again. Raising a
  question now parks the job; answering it un-parks. Caught by
  `RecordingFlowUITests` waiting 928 s for a terminal state that was never
  coming, introduced by the fix immediately below, which is why the two are
  recorded together.
- Tapping Download did nothing: `confirmModelDownload()` read `pendingModelDownload`
  back, and the confirmation dialog's own `isPresented` setter clears it on
  dismissal, which can land first. Both shells now pass the value into
  `confirmModelDownload(_:)` / `cancelModelDownload(_:)`, so either ordering
  works; "Not now" parks the job (`pausedByUser`) rather than leaving it to be
  picked up and re-asked on every library appearance.
- "Re-identify Speakers" was a silent no-op on a job with no diarization
  checkpoint: `JobLibraryModel.reidentify` returns false and both shells
  ignored it, so the menu item did nothing and explained nothing, indistinguishable
  from having run and matched nobody. It now says what is missing and names
  re-transcribe as the thing that fixes it.
- `RecorderService` did every blocking CoreAudio call on the main actor (the
  app target defaults to `MainActor`), so `setCategory`/`setActive` (XPC to
  mediaserverd), `AVAudioRecorder.init`, `record()`, and on the way out `stop()`
  (which flushes and closes the AAC file) all blocked the UI. Milliseconds when
  the system is idle; seconds right after a transcription, which is when the
  owner reported a hang. `start()`/`stop()` are async now, with the blocking
  half on one **serial** queue: off-main alone would have let a discard's
  `setActive(false)` land after the next take's `setActive(true)`, i.e. a live
  recorder on a dead session. A start token disowns an open that a stop or
  discard superseded. NOT a confirmed fix for the reported hang, since the simulator
  has never reproduced it, but the main-thread block was real.
- The record sheet drew an empty control row for both `.idle` and `.finished`,
  and `RecorderService.start()` returned silently when the state was neither,
  so any failed start looked exactly like the app doing nothing, with no button
  to press and nothing to read. A start that has not succeeded is now either
  still going (spinner) or over (named reason + Try Again), never blank, and
  `reset()` gives a finished sheet a way back to `.idle` without discarding the
  take. `--uitest-fail-record` is the seam, since the real cause is device-only.
- The speaker chip acted on `cluster` rather than `effectiveCluster`, so a
  reassigned turn renamed, and could enrol the voice of, the wrong person.
- Per-turn reassignment existed but only behind a long-press, while the chip,
  the control that looks like the speaker control, always renamed the whole
  cluster; and the choice list was built from clusters the diarizer had already
  found, so the commonest misclassification (a third person folded into one
  cluster) had no fix at all, and iOS hid the action entirely in a
  single-speaker transcript.
- Unbounded concurrent pipeline runs; interruptions that left the recorder
  silently dead while the UI said "Recording"; `TranscriptSearch.Hit.id`
  trapping on a mid-turn match; multi-line corrections breaking SRT/VTT cue
  structure; `retranscribe` destroying the previous transcript before producing
  a replacement; the location setting not reaching the watch; `Documents/Incoming`
  outside every deletion path and storage figure.

## Additions beyond the spec

- **Watch-face complication (21 Aug 2026).** `LonghandComplication/`, a WidgetKit
  extension embedded in the watch app (`com.shpala.Longhand.watchkitapp.recordwidget`;
  the obvious `.complication` was refused by Apple as an App ID already taken),
  in the circular, corner and rectangular accessory families. It carries the app
  mark as a *template* image: `BrandGlyph` is the cream script lifted off the
  indigo tile of `BrandMark.png`, because accessory families render inside the
  face's own tint and a full-colour tile flattens to a grey square. Tapping it
  opens `longhand://record`, which `WatchRecordView.onOpenURL` turns into a
  running take via the same `beginRecording()` the Record button calls, so the
  complication is one tap from recording rather than one tap from a button.
  The timeline is static: live recording state would need a shared app-group
  container plus `WidgetCenter.reloadTimelines` pushed from the recorder, and a
  complication that misreports whether you are recording is worse than one that
  never claims to. Inline is unsupported on purpose, since it renders only text
  and SF Symbols and the mark could not appear there.

- **Diarization models ship with the app (21 Aug 2026).** The Community-1
  Core ML set is 11.24 MB (`speaker_segmenter` and `speaker_embedder` at
  pyannote-v3/W8A16, `speaker_clusterer` at pyannote-v4/W32A32, the exact
  variants SpeakerKit fetches), vendored under
  `LonghandEngines/Resources/SpeakerModels` and copied into the cache
  SpeakerKit already reads on first use. The bundle is read-only and the
  library wants a writable model root, so seeding beats loading in place and
  leaves the presence check, load and purge-and-refetch paths unchanged; the
  download remains as a fallback if seeding ever fails. §13.3's delivery
  question is therefore answered "bundled" for diarization and "first-run
  download" for Whisper. Diarization was never really optional (without it
  there are no speakers at all, only timestamps, §17), so shipping it removes
  a network request standing in front of a core feature. The models are now
  redistributed rather than fetched, which the CC BY 4.0 notice states.

- **Language picker grouped by engine (22 Aug 2026).**
  `LonghandEngines/Sources/LonghandEngines/TranscriptionLanguages.swift` + `LanguagePicker.swift`, used
  by both shells and by the §13.2 re-transcribe menus. Apple's
  `SpeechTranscriber` covers ten languages on device (measured: de, en, es, fr,
  it, ja, ko, pt, yue, zh; not Hebrew or Russian), so the picker shows two groups
  headed by *engine*, "Apple speech recognition" and "Whisper speech model",
  which is what makes §4.2's routing visible before a recording instead of at
  the §4.2.3(ii) gate mid-job. The headers deliberately do not mention where
  the work happens: an earlier wording, "Transcribed on this device", implied
  the other group was not, which contradicts §14.2's central claim. A caption
  under the picker says both run entirely on this device. The Whisper header
  carries "· 626 MB download" only while the model is absent, since a size is
  a gate rather than a property and naming it to someone who already
  downloaded it describes a cost they have paid. The on-device list comes from
  `supportedLocales`, with a static fallback because that returns empty on
  simulators and on a device whose speech assets are not installed; losing the
  group entirely there would be worse than the hardcoded three it replaced.
  "Automatic" names what it resolved to, since undeclared Hebrew on an
  English-locale device routes to Apple's engine and is transcribed as English
  with no §17 degradation, the router having seen nothing fail. "Mixed" is
  relabelled "detected every 30 seconds" and moved into the model group: Whisper
  decodes one language per window, which helps block-structured multilingual
  audio and hurts sentence-level code-switching, where pinning the dominant
  language is better.
  The model group is all 90 languages `Constants.languages` declares that Apple
  does not cover, derived rather than typed; the engine adapter always accepted
  them and only the picker's hardcoded pair stood between someone and an Arabic
  transcript. Quality across those 90 is not uniform, so the list states what
  the model claims rather than promising each works well. Only the recent few
  are inline, with `LanguageListView` (searchable, a sheet on both platforms
  since the Mac's Settings form has no navigation stack) behind "More
  languages…"; recency is seeded with he/ru and reordered by use, rather than a
  "popular languages" list chosen on the owner's behalf.

- **Markers drawn among the words (22 Aug 2026).**
  `LonghandKit/Sources/LonghandKit/Transcript/MarkerPlacement.swift` (pure, tested) plus
  `LonghandEngines/Sources/LonghandEngines/MarkerViews.swift` (`MarkedTurnText`, `MarkerTrack`), used by
  both shells. A marker is a moment, and rendering it as a row between turns
  moved a flag pressed mid-sentence to the nearest turn boundary, sometimes
  several sentences from what it was reacting to. Placement is *between* words,
  not on one: the flag means "here", not "this word matters". Built from the
  merged words rather than by string-matching `turn.text`, so bidi runs keep
  their shape, and the flag carries U+2068/U+2069 isolates, without which it
  reorders in Hebrew. §15.2 ⟨R-16⟩ rations per-word rendering to the playing
  row; this stays affordable because it also applies only to turns carrying a
  marker. Edited turns and jobs with no word timings fall back to the row form,
  which now quotes the words around the moment instead of only a timestamp.
  Markers also appear as ticks on both playback scrubbers, which is where
  "how many and where" belongs and the only way to reach the next flag without
  scrolling for it.

- **Platform parity pass (22 Aug 2026).** An audit of the three shells against
  each other found eleven divergences that were accidents rather than decisions,
  all now closed.

  The one that lost work: the Mac's record sheet had no `interactiveDismissDisabled`
  and no discard confirmation, so Escape mid-take dismissed it, tore the view
  down, and ran neither `discard()` nor `onCancel()`. Capture stopped and the
  file was orphaned in the container's temp directory, unreachable from the app.
  Verified before and after by watching the temp file grow: it stopped growing
  at Escape, and now keeps growing. Cancel also confirms first, as iOS does.

  Also on the Mac: "Stop & Save with Options…" (§7.1 options for a take, not
  just for an import), a Try Again after a failed start, Mark enabled while
  paused, a confirmation before deleting a single enrolled voice (§14.1 data,
  and Delete All already asked), Resume rather than Retry for a paused job on
  the transcript screen, the first-launch welcome, and the elapsed timer moved
  off `TimelineView(.periodic(from: .now …))`, the re-anchoring pattern already
  fixed on the watch (`75a8fc2`) and the phone (`fad6c8b`).

  On iOS: the file picker takes multiple files, and audio can be dropped onto
  the library, both of which the Mac already did.

  Two transcript surfaces that existed only on iOS moved into `LonghandEngines`
  rather than being copied: `ProcessingTimings` (the §-stage breakdown behind
  "Processed in …") and `NoSpeechDiagnostics` with `ImportDiagnostics` (applied
  gain and input level in dBFS from the §5.4 stats). The Mac, the machine most
  likely to be handed a two-hour recording, was the shell that could not say
  where two hours went or whether the microphone had heard anything.

- **iPad gets its own layout (22 Aug 2026).** There is no separate iPadOS
  target: `TARGETED_DEVICE_FAMILY = "1,2"` is one binary, and it had no
  size-class or idiom handling anywhere, so an iPad ran an iPhone layout at
  iPad size. `LibraryView` now branches on `UIDevice.current.userInterfaceIdiom`
  into a `NavigationSplitView` (sidebar library, transcript in the detail
  column) or the existing `NavigationStack`. The idiom is read rather than the
  size class deliberately: it cannot change while the process runs, whereas
  branching on `horizontalSizeClass` would swap the navigation container when a
  Stage Manager window is resized and tear down whatever is on screen, a
  running record sheet included. The iPhone path is unchanged.

  Row taps still drive it through `open(_:)` rather than a selection-driven
  `List`, which would take the whole cell back and break the Retry/Resume
  button the explicit `path` was introduced to fix. The detail column carries
  `.id(selection)`, without which SwiftUI reuses the view across a selection
  change and `onAppear`, which is what calls `load()`, does not fire again.
  Search is pinned with `.navigationBarDrawer(displayMode: .always)` in the
  sidebar, where the automatic placement collapsed it out of sight entirely.

  `LonghandCommands` adds hardware-keyboard verbs (⌘R record, ⌘O import,
  ⌘F find, ⌘P play/pause, ⌘← / ⌘→ skip) through an `AppCommandTargets`
  object the owning views publish into, the same shape as the Mac's
  `MacCommandTargets`. It is a deliberate subset: Rename and Delete are
  bare-Return and ⌘⌫ on the Mac because a focused sidebar row is an
  unambiguous target, and iPadOS has no equivalent here. Transcript text is
  capped at a 760pt reading measure, which the phone never reaches and a
  13-inch iPad in landscape would otherwise blow past by a factor of two.

## Deviations from the spec (owner decisions)

- **§2.1/§15.4 subtitle exports removed (21 Aug 2026).** The design asks for
  Markdown, TXT, SRT and WebVTT alongside the canonical JSON. SRT and WebVTT
  were dropped at the owner's request: this is a transcription app, not a
  subtitling one, and neither format was ever used. Gone from the export menus
  in both shells, from `TranscriptExporter` (`srt`, `webVTT`, `singleLine`,
  `vttEscaped`, `srtTime`, `vttTime`), from `writeAll`, and from `JobFiles`,
  so no job folder holds a `transcript.srt` or `transcript.vtt` any more. The
  export set is now: copy transcript, Markdown, Text, JSON, original audio.
  The §15.4 bidi guarantee it used to be tested through moved onto the text
  and Markdown exporters, which keep the directional-isolate coverage.

## Tried and removed: on-device summarization (26 Aug 2026)

Built end to end, measured on the owner's iPhone 16 Pro Max, and removed
because the summaries were not good enough to be worth what they cost. The
code is recoverable from the reverted commits (`1d77e33`, `f022a27`,
`a52fcb9`, `039ee1b`); the numbers are here so nobody has to spend the
afternoon again.

- **Feasibility was never the problem.** MLX Swift builds into the iOS app and
  runs (`MLX arithmetic on GPU: ok`). Qwen3-4B-Instruct-2507 at 4-bit is
  2277 MB of weights; loading costs ~110 MB above that, and generating over a
  3000-token chunk adds ~975 MB more. Peak process footprint **3378 MB against
  a 3536 MB jetsam ceiling**, so it fits with ~160 MB to spare and needs no
  `increased-memory-limit` entitlement. `MLX.GPU.clearCache()` returns ~950 MB
  immediately afterwards.
- **Speed was never the problem either**: 18 tok/s output and 3043 tok/s
  prefill on device, which puts an hour of audio at roughly three minutes.
- **Halving the chunk window is not the memory lever it looks like.** 1500
  tokens moved the peak only 3378 → 3183 MB and cost 32% throughput, because
  MLX `active` is 2265 MB either way: the weights dominate and the KV cache
  never was the bulk.
- **Foreground only.** The app was SIGKILLed at 1561 MB the moment it was not
  frontmost, while `os_proc_available_memory` still reported ~2 GB free, since
  that figure answers for the foreground limit. Any future attempt has to hold
  a background assertion or refuse to start.
- **Qwen3-1.7B is disqualified on quality**, not memory (it peaks at 1917 MB,
  less than 4B's weights alone): it echoed its input verbatim and collapsed a
  Hebrew transcript into French and German mid-sentence.
- **Cost of even trying it**: linking the package makes Xcode's Metal toolchain
  component a hard requirement for building Longhand at all, and `swift build`
  cannot produce a working MLX binary on the command line at all.

## Deliberately deferred (with the design's own gates)

- **WhisperKit: IMPLEMENTED** (`LonghandEngines/Sources/LonghandEngines/WhisperKitEngine.swift`).
  Model is user-selectable in Settings (`WhisperModelVariant`): the default
  `openai_whisper-large-v3-v20240930_626MB` (the §6.1 compressed Turbo,
  still provisional per its gate) or `openai_whisper-large-v3_947MB`
  ("Maximum accuracy", the non-distilled large-v3). Either downloads once
  from Argmax hosting on first use (§13.3 "first-run download" strategy,
  de facto); the transcript's `models.asr` records which one produced it,
  and a Settings change rebuilds the engine set on the next run.
  Word timestamps on; `avgLogprob` from word probability; incremental
  loading above 10 min (§6.2); special tokens stripped. §4.2 routing sends
  any language Apple's engine lacks, with Hebrew and Russian verified end to end
  on device via the deterministic synth-import test (`MultilingualUITests`,
  app-side `--uitest-synth-import` scaffolding in `UITestSupport.swift`).
  Hebrew SRT export carries RLI/PDI isolates; Russian correctly does not.
  Real human Hebrew incl. English code-switching also observed transcribing
  correctly. The §6.1 Hebrew-WER gate (Turbo vs non-distilled large-v3) is
  **unmeasured but no longer unmeasurable**: `$D accuracy <dir> --by model`
  compares them over the corrections in the library. It needs a recording
  transcribed by both variants and some turns corrected; today the library
  holds neither.
- **Speaker recognition: IMPLEMENTED (Phase 4, without TitaNet).** §9.3
  known-self mode generalized to any enrolled person, built on Community-1's
  per-cluster centroid embeddings instead of a second inference runtime
  (which §9.1 itself flagged as a reason to keep TitaNet optional). Pieces:
  `LonghandKit/Sources/LonghandKit/SpeakerID/` (profiles, cosine matcher with
  score-floor + two-sided margin rule, `40_identity.json` checkpoint),
  `LonghandEngines/Sources/LonghandEngines/SpeakerProfileStore.swift`
  (local-only, complete deletion per §14.1), pipeline identify stage + `reidentify` re-entry edge,
  enrollment via "Remember this voice" in the rename sheet (explicit
  confirmation per §9.2; §8.2 overlap exclusion enforced), "auto" badge on
  model-matched labels, Enrolled Voices management screen. Verified E2E on
  device: enroll from take 1 → take 2 auto-labeled (score 0.60, margin 0.16).
  Thresholds (floor 0.55, margin 0.05) are roughly calibrated from on-device
  measurements recorded in `SpeakerMatcher.Config`. §18.2's calibration has
  been **built and run** (`$D accuracy <dir> --calibration`) and reports NOT
  CALIBRATED: the library holds one recording, so there is no same-voice pair
  across takes, which is the evidence the score floor rests on. The one real
  datapoint it produced, two different speakers at 0.1125, says the floor is
  safe in that direction and sits outside the 0.38-0.53 band the config
  records. One pair is not grounds to move a threshold. TitaNet/sherpa-onnx
  stays unimplemented; revisit only if centroid matching proves insufficient.
- ~~BGContinuedProcessingTask~~: **IMPLEMENTED (Phase 5)**:
  `Longhand/Jobs/BackgroundExecution.swift`. Jobs claim a continued-processing
  task at start (§11.1 foreground-first); system progress pill driven by the
  pipeline's ProgressSink; expiration cancels into INTERRUPTED via checkpoints.
  Wildcard identifier `com.shpala.Longhand.processing.*` in a partial
  `Longhand/Info.plist` (merged; sync-group membership exception excludes it
  from resources). Fallback is registration-gated; submitting without a
  successful registration is an uncatchable ObjC assertion, not a thrown
  error. GPU [VERIFY] resolved: the `continued-processing.gpu` entitlement
  needs Apple approval, so the app requests default resources (CPU+ANE) only.
  Device-verified: job completed during 75 s backgrounded
  (`BackgroundExecutionUITests`); simulators lack BGTaskScheduler and use the
  inline fallback.
- **Stereo diarizer bypass**: deferred behind the §5.3 gate; measurements
  are being collected into `metadata.json` as the gate requires.
- **Playback-synced highlighting: IMPLEMENTED** (§15.2 ⟨R-16⟩). Turn and word
  highlighting in both shells, off a throttled observer scoped to the playing
  row (`PlaybackTurnTracker`), with `TranscriptIndex` doing the time lookups.
- **Scroll/playback performance test: IMPLEMENTED** (§15.2 ⟨R-16⟩). See
  "Rendering at scale, measured" below.
- **Phase 0 benchmark, CI offline assertion**: still open (§18.1).
- **DER/cpWER/WDER**: blocked on speaker-labelled ground truth the overlay does
  not carry. A reassignment records which cluster a turn was moved *to*, not
  whose voice it was, so unlike the word-error half this one does not fall out
  of ordinary use. See "What is left" at the top.
- **Word error (§18.1, §6.1)**: no longer deferred. See "Accuracy from the
  corrections" below.
- `tools/hda2mp3.sh` referenced by §5.5 as the porting source **does not
  exist in this repo**; the probe ordering was implemented directly from the
  spec text instead.

## Model presence and repair (22 Aug 2026)

A Hebrew take on the owner's phone failed with "Required model asset is not
installed" after sitting in **Loading speech model… for 179 seconds**
(`stageSeconds.loadingModel: 179.474` in the job record, state `PREPARED`,
original audio intact). The container showed the cause: a stale
`weight.bin.<sha>.incomplete` of zero bytes in
`Documents/huggingface/.cache/huggingface/download/`, and every small file in
the model tree rewritten at the moment the job ran. Those three minutes were
network work reported as a load.

Three defects in `WhisperKitEngine`, all pre-dating the change:

- The already-downloaded branch passed **`download: true`**, so WhisperKit was
  free to consult the hub and re-fetch from inside a stage that says "Loading
  speech model…". §14.2 requires a download to report as a download, with a
  number. Now `download: false`: the load either succeeds locally or fails at
  once.
- `isDownloaded` checked only that **two directory names** existed
  (`AudioEncoder.mlmodelc`, `TextDecoder.mlmodelc`), never opening them, and
  omitted `MelSpectrogram.mlmodelc`, which inference also loads. It now applies
  the same rule `CommunityOneDiarizer.isLoadable` has applied to the speaker
  models since the equivalent failure there: `coremldata.bin` and `model.mil`
  present and non-empty, and a `weights` directory, if present, holding at
  least one non-empty file.
- There was **no repair path**, where the diarizer has purge-and-refetch. A
  tree that will not load is now purged, and `modelDownloadRequired` is thrown
  so the §4.2.3(ii) gate asks before spending 626 MB again. The purge is what
  makes that terminate: the presence check answers "absent" on the next run, so
  consent is asked once and the refetch is real rather than a no-op over the
  same broken tree.

Note the honest limit: the stricter presence check would **not** have caught
this particular tree, whose weights were full-size. `download: false` plus the
repair path are what fix the failure that was observed; the stricter check
fixes the other shape of partial download, the one the speaker models hit for
real. `ModelPresenceTests` covers both; six of its seven cases fail against the
old name-only check.

## Stage budgets (22 Aug 2026)

`stageSeconds.loadingModel: 179.474` was the whole diagnosis of the model
failure above, and the app had recorded it, stored it and rendered it in
`ProcessingTimings` without anyone noticing. §17 says a degradation is never
silent; a stage doing something other than what it claims was.

`StageBudget` (LonghandKit) gives each stage a loose plausibility bound: cheap
fixed-cost stages (`merging`, `identifying`, `exporting`) get an absolute limit,
stages that read the whole recording (`preparing`, `transcribing`, `diarizing`)
get a multiple of its duration with a floor, and `downloadingModel` gets none,
because a download takes as long as the network takes.

`loadingModel` also gets none, which is the opposite of how this started.
It was the obvious candidate, being the stage that misbehaved. Measurement on
the owner's iPhone 16 Pro Max says there is no threshold to draw: the run that
failed spent 179.5 s there, and the run that succeeded after the `download:
false` fix spent 146.4 s. Thirty seconds apart is noise, not a signal, and any
bound between them would call a healthy first load a fault. Core ML compiles
for the device on first load, so minutes are normal.

What survives is the half that never needed a threshold. A failure says where
this run's time went when one stage dominates it:

    Transcription failed: Required model asset is not installed: …
    Most of that time (2:59) went on loading model.

That is a fact about the run, with no judgement attached, and it is the sentence
that would have made the original failure diagnosable from the row instead of
from `devicectl`. It reads `thisRun` from the stage clock rather than
`record.stageSeconds`, which accumulates across runs by design: after two runs
the phone's record read 325.919 s of `loadingModel`, a total no single sitting
ever spent.

`ProcessingTimings` still tints a row that overran one of the remaining budgets
and says the transcript is unaffected, because it is: this is a measurement, not
a degradation, and putting it in `degradations` would conflate "slower than it
should be" with "a lesser result was produced".

The bounds are deliberately loose and the tests pin the quiet direction as hard
as the loud one: an ordinary run, a short take whose fixed overheads dwarf its
own length, an hour-long download, and both of the real model loads above must
all produce nothing. A budget that cries wolf trains the reader to ignore the
one report that mattered, which is the failure being fixed here.

Verified on screen in the Mac shell (22 Aug 2026) against a doctored record:
collapsed header, single tinted row, note beneath the breakdown. The fixture was
removed from the library afterwards.

## Typed degradations (22 Aug 2026)

§17 degradations were `[String]`, and one of those strings was load-bearing.
The transcript screen decided whether to offer the speaker models by testing
`hasPrefix("Diarization unavailable")` against a sentence composed in
`JobPipeline`, with four test sites matching the same prose. Rewording a
user-facing line would have removed a button, and only a test failure three
modules away would have said so.

`Degradation` is now `{ kind, message }`. Behaviour switches on `kind`; the
message is for reading. `Kind` carries an `unspecified` case so a note written
by a later version keeps its text instead of failing the record it lives in.

The migration is the part that mattered. Every `job.json` on the device was
written with bare strings, so `init(from:)` accepts a single string and infers
the kind from its prefix. That inference is the only place a degradation is
identified by its prose, it runs once per legacy record rather than on every
render, and `DegradationTests` pins all seven messages the pipeline has ever
written. A record that will not decode is a recording the library cannot show,
which is worse than the coupling this removes.

Not addressed here: the Mac still renders degradation notes as plain text with
no affordance, where iOS offers the speaker models next to a diarization note.
That gap is now a few lines (`note.kind == .diarizationUnavailable`) rather than
a second copy of a prefix match.

## One model-asset rule (22 Aug 2026)

Both vendored engines shipped the same bug. SpeakerKit called a tree present
while `weight.bin` was missing; WhisperKit called one present on two directory
names it never opened, with the third component absent from the list. Each was
fixed separately, the second fix largely a copy of the first.

`ModelAsset` holds the rule once: a component resolves to at least one compiled
bundle (itself when the component is already a `.mlmodelc`, as WhisperKit lays
them out, or nested at whatever depth the vendor uses, as SpeakerKit does), and
every such bundle carries a non-empty `coremldata.bin` and `model.mil` plus, if
a `weights` directory exists at all, a non-empty file inside it. Both engines
now declare themselves through it, and both inherit the stricter size checks
that only the later of the two fixes had: SpeakerKit's own rule asked whether
files existed, so a resumed fetch that left a zero-length `coremldata.bin`
behind read as healthy.

Also closed here: the Mac transcript screen rendered §17 degradation notes as
plain text, where iOS put the repair beside them. It now offers "Re-transcribe
to add speaker labels" against a `.diarizationUnavailable` note, which is the
whole repair on that platform: the speaker models ship in the app and are seeded
into the cache on first use, so there is no download row to mirror.

Verified on screen with a job seeded carrying the *legacy* bare-string
degradation, which exercised the `job.json` migration end to end in a running
app: the string decoded, `inferKind` resolved it to `.diarizationUnavailable`,
and that is what made the button appear.

## The first model load is one-time, and now says so (22 Aug 2026)

Measured on the owner's iPhone 16 Pro Max: 146 s to load the 626 MB turbo
weights the first time, against seconds for every load after. Core ML compiles
a model for the device on first load and caches the result. The row said
"Loading speech model…" for two and a half minutes, which is indistinguishable
from a hang, and is the same complaint §14.2 makes about a download that does
not report itself.

`PipelineProgress.isFirstModelLoad` rides on the report the engine already
sends. `WhisperKitEngine` records a per-variant flag in `UserDefaults` after a
successful load, per variant because each set of weights is compiled
separately: having loaded turbo says nothing about how long large will take.

All three surfaces say it: the iOS row, the Mac row, and the background task's
own pill. A cleared cache makes the flag optimistic, which is the harmless
direction, since the label then understates a wait rather than promising a
one-time cost that recurs.

## Staged downloads are counted and swept (22 Aug 2026)

HuggingFace stages a fetch in `.cache/huggingface/download/` beside the models
it writes, and leaves `weight.bin.<sha>.incomplete` behind when one is
abandoned. Nothing counted that directory: `totalDiskUsage` walks job folders
and `downloadedBytes` walks a variant's own folder. Nothing swept it either, so
an interrupted 626 MB download could sit there permanently and invisibly. The
owner's phone was carrying one, at zero bytes, from 21 Aug.

`ModelStaging` counts and sweeps it. Only `.incomplete` files: the `.metadata`
files beside them are the vendor's etag bookkeeping, and deleting those invites
exactly the re-fetch this project has already been bitten by once. The sweep
runs after a successful model load, which is the one moment it is safe, since
the weights demonstrably loaded and anything left staged is abandoned rather
than in flight.

Both Settings screens show an "Interrupted downloads" figure with a Clean Up
button, and only when it is non-zero: a healthy install stages nothing, and a
permanent row reading "Zero KB" would be noise standing in for the fact worth
surfacing.

`vendorRoots` spells the two paths out rather than reading them off the engines,
which live inside `#if canImport` guards and vanish in a build without the
packages. A test pins the spelling against `WhisperKitEngine.modelFolder(for:)`
and `CommunityOneDiarizer.modelFolder()` so they cannot drift.

## Device logs (22 Aug 2026)

`$D logs sim|device [seconds]`. Diagnosing the model failure meant inferring
from file modification times, because the driver could pull containers but not
logs.

`log collect --device-name` is the obvious tool for a phone and requires root,
so it is not usable here. `devicectl device process launch --console` streams
the app's own stdout/stderr and needs no privileges, at two costs: it can only
attach at launch, so the app is relaunched, and it forwards signals, so closing
the capture window terminates the app. The simulator path filters the real
unified log instead, catches an app already running, and is far richer.

## Accuracy from the corrections (22 Aug 2026)

§18.1's accuracy harness was deferred for want of an annotated corpus. One had
been accumulating the whole time. Every `UserOverlay.TurnEdit` holds
`baseTextHash`, the machine's own words, beside `newText`, what a person changed
them to; the machine text is recoverable by rebuilding turns from
`30_merged_words.json` exactly as `rerender` does, and the stored hash confirms
the pair is genuine rather than a coincidence of timing. `transcript.json` is
deliberately not the source: it has the overlay applied, so its turns are
already the corrected text.

`WordAlignment` is word-level Levenshtein with the three operations counted
apart, because they mean different things: a deletion is speech the model
missed, an insertion is speech it invented, and §6.4 exists because the second
happens. Tokens are folded through `TextFold.fold`, the matching form, so a
correction that only restores nikkud or a final letter form is not counted as an
error, and punctuation is stripped for the same reason.

`AccuracyCorpus` pairs and aggregates. `longhand-accuracy` is an executable
target in LonghandKit (it needs nothing but the deterministic core) and reaches
the corpus through `$D pull device`, since §14.1 keeps it on the device until
someone takes it off deliberately.

**What it may be trusted to say.** Only corrected turns contribute errors, so
the figures are biased towards hard passages and are not a WER for a recording.
Two things they support: comparison between models, languages or periods over
the same corrections, and a floor under the error rate, since a word a person
changed was definitely wrong. The tool prints that caveat under every run.

Edits it cannot use are counted rather than dropped, because a harness that
silently discards its inputs is measuring an unknown subset:
`machineTextChanged`, `noMatchingTurn`, and `noMeasurableDifference` for a
punctuation-only correction.

Exercised against the owner's own library, which currently holds one recording
with no corrections and therefore reports nothing to measure, and against that
same Hebrew transcript with corrections applied to a scratch copy: two genuine
one-word fixes measured as substitutions, the punctuation-only edit correctly
excluded, an error floor of 3.2% over 62 machine words. The scratch copy was
deleted afterwards, since it carried a copy of the recording.

## Per-run stage timings (22 Aug 2026)

`stageSeconds` totals across sittings, and is right to: a job that stopped and
continued really did load the model twice. It is the wrong number to compare
with, because it belongs to no single run. The phone's own record read 5:26 of
model load after a failed run and a successful one, when the load that produced
the transcript took 2:26, and the stage budget above was reading exactly that
total.

`lastRunStageSeconds` and `processingRuns` sit beside it, written by
`JobPipeline.persist` from the same drain that feeds the totals. The run counter
increments on the first stage that costs anything rather than on entry, so a run
that finds every checkpoint present and only re-exports is not counted as a
sitting. `comparableStageSeconds` prefers the per-run figures and falls back to
the totals for a record written before the distinction existed.

Consumers split accordingly. `StageBudget` judges one run, so an interrupted job
is not called slow for having been interrupted. `ProcessingTimings` keeps
showing the totals, which are the honest answer to what the job cost, and now
says "across 2 runs" with a line explaining that a repeated stage is counted
each time. Unlabelled, that total reads as one run's cost, which is the actual
defect: the number was true and the framing was not.

## The speaker models are not a download (22 Aug 2026)

The transcript screen offered "Download Speaker Identification (11 MB)" beside a
`.diarizationUnavailable` note, with `ModelDownloadState.downloadSpeakerModels`
and `CommunityOneDiarizer.prefetch` behind it. The models have shipped inside
the app since they were bundled, and are seeded into the cache on first use, so
the button offered a download that could not happen. It is gone, and the note
now carries the same single affordance the Mac was given: re-transcribe.

Behind it was the worse half. `pendingDownloadBytes` asked `modelsPresent`,
which does not seed, and nothing seeds at launch, so on a fresh install the
§4.2.3(ii) consent gate stood in front of the *first* diarization asking
permission to download 11 MB the app was already carrying. It asks
`isDownloaded` now, which seeds first, and that is the earliest honest answer
because it is also the first call that needs the models.

`approximateBytes` stays. If seeding ever fails the gate still has to name a
real size, and that is the case the constant now exists for.

## Speaker-matcher calibration, run (22 Aug 2026)

§18.2's calibration has the same shape as the accuracy harness: the labels are
already in the library. A cluster whose name the user **confirmed** is a
labelled voice, and its centroid is the embedding the matcher compares. A name
the matcher proposed is the claim being calibrated and is excluded, or the
matcher would be marking its own work (§13.1).

`SpeakerCalibration` builds the pairs; `$D accuracy <dir> --calibration` reports
them. Run against the owner's library:

    Labelled voices  2 across 1 recording: Emilia, Pavel

      same person, different takes      none
      different people                  1 pair   0.1125
      same person, one take             none

    NOT CALIBRATED.

**The verdict is that it cannot be run yet, and that is the finding.** The score
floor exists to hold when a voice is recorded again in another take, and there
is no such pair: both voices were enrolled from the one recording. Enrollment
copies the cluster centroid, so a person against their own take scores exactly
1.0000, which is self-similarity and measures nothing. The report segregates
that row so it cannot be mistaken for evidence.

One real datapoint did come out. Two different speakers in the same recording
score **0.1125**, far below the floor of 0.55, so the floor is safe in that
direction. It also sits well outside the "different voices ≈0.38-0.53" band
recorded in `SpeakerMatcher.Config`, which was calibrated from a handful of
samples; one pair is not enough to revise it, and it is noted here rather than
quietly acted on.

What would settle it: record the same people again, confirm the names in that
take, re-run. The embeddings pulled to produce this were deleted from the Mac
afterwards.

## Rendering at scale, measured (23 Aug 2026)

§15.2 ⟨R-16⟩ asked for a scroll/playback performance test on the 60-minute
corpus. It exists now, in two halves, because the two things worth asserting
are not assertable in the same place.

The corpus is `LonghandKit/Sources/LonghandKit/Transcript/TranscriptFixture.swift`:
an hour of ~10,000 words in ~500 turns, alternating speakers, with a pause
every eighth turn. It generates words only and lets `TurnBuilder` make the
turns, so its word-to-turn join is the pipeline's rather than a second opinion
about it. Shipped rather than test-local because the UI-test seeder needs the
same corpus; two generators would measure two things.

**The cost, in `LonghandKit/Tests/LonghandKitTests/TranscriptScrollPerformanceTests.swift`.**
The trap ⟨R-16⟩ names is not slow code, it is code whose cost grows with the
transcript while someone scrubs an hour-long call. So each test compares a
15-minute corpus against a 60-minute one and asserts the *per-operation* cost
is flat, instead of asserting a millisecond figure that would describe the
machine more than the code. A length-dependent implementation shows up as a
factor of four; the threshold is 2.5. Measurements are interleaved and the
fastest of seven is taken, so a burst of load lands on both sides of the ratio.

Covered: finding the current turn on a playback tick, finding the current word,
seeking (which bypasses the cursor and hits the search), the rename chip's
passage count, and the index build. Two more that a ratio cannot reach: the
cursor form must agree with the search form at all 36,000 ticks of an hour and
across backwards scrubbing, and the cursor must actually beat a fresh search
(measured at ~1.9x, asserted above 1.4) since both are logarithmic and no size
ratio would notice the cursor being deleted.

Each was checked against a sabotaged `TranscriptIndex`: replacing the binary
search with a scan, dropping the cursor, counting passages with a `filter`, and
scanning every word for the active one. Each sabotage failed exactly the test
meant for it, at ratios of 3.9 to 4.0.

**The structure, in `LonghandUITests/TranscriptScrollUITests.swift`.**
Virtualization is only observable from outside as the absence of rows nobody is
looking at, so each turn's timestamp carries a `turn-<id>` identifier and the
suite counts them. It asserts that an hour opens with a fraction of its 500
rows built, that twenty swipes leave the opening turns behind without the built
count climbing (rows released, not accumulated), and that renaming a speaker
leaves the reader on the row they were on, which is §15.2's scroll-anchoring
requirement. `--uitest-synth-transcript <minutes>` seeds the corpus as a
COMPLETE job straight to disk, with no audio and no pipeline run.

Nothing in the UI half asserts a frame rate. A simulator's is not the phone's,
and a flaky performance gate is worse than none; the numbers live in the half
where a number means something.

## Deleting a downloaded model (27 Aug 2026)

Settings now offers a Delete on each downloaded Whisper build, on iOS and
macOS. `WhisperKitEngine.delete(_:)` is the one entry point and it removes
three things, not one:

- the model tree (626 MB turbo, 947 MB Maximum accuracy),
- the vendor's staging area beside it, which can hold a partial payload from an
  interrupted fetch. `ModelStaging` already counted those bytes and swept them
  from a separate Settings row; a delete that skipped them would report freeing
  space it had left on disk,
- the `whisperModelLoaded.<model>` flag. That flag is what lets the download
  sheet call the first Core ML compile one-time. A re-downloaded model is new
  files and compiles again, so a stale `true` would understate the wait on the
  exact run where it is longest.

`reclaimableBytes(for:)` exists so the confirmation names a real figure rather
than asking anyone to trust one.

**Gating.** A pipeline run holds its weights open and re-reads them per chunk,
so deleting underneath one fails the job. The engine cannot see jobs, so the
guard is in the shells: both Delete buttons are disabled while
`runningJobs` is non-empty. Deleting the *selected* variant is allowed and is
called out in the confirmation, because the next recording that needs it simply
re-enters the existing §4.2.3(ii) download-consent path.

Not offered for the speaker models. `CommunityOneDiarizer` seeds its folder
from the app bundle rather than the network (see "The speaker models are not a
download"), so deleting them would reclaim ~33 MB that the next run copies
straight back out of the binary. A button that undoes itself is worse than no
button.

`ModelDeletionTests` (5, serialized) cover it. Serialized because every case
stages the same folder under one vendor root and touches one defaults key;
run in parallel they delete each other's fixtures and fail in ways that read as
bugs in the code under test. Each case also refuses to run against a genuinely
downloaded model, so the suite cannot destroy a real 626 MB on a working
machine, which it caught itself doing on the first run.

## Enrolling a voice from a recorded sample (27 Aug 2026)

§9.3's known-self mode needs the owner enrolled *before* a recording exists.
Until now the only enrollment path was renaming a speaker in a finished
transcript, so the first call could never label "Me" however obvious it was.
`VoiceEnrollment.embed(clipURL:diarizer:)` closes that cold start, and nothing
else about identification changes: `SpeakerMatcher` already generalises over
however many people are enrolled, so an owner profile named "Me" is just
another profile.

The embedding comes from the same diarizer the pipeline uses, over audio put
through `AudioNormalizer` exactly as §5.4 does. That is not incidental. An
embedding produced by any other route would not be comparable with the
centroids it is later matched against, and the whole value of the sample is
that comparison.

**What it refuses, and why refusing is the point.** This one sample decides
whether the first call says "Me" or says it about the wrong person, so the
rules matter more than the happy path:

- fewer than 6 seconds of *speech* (not of clip): a centroid over two seconds
  is noise wearing a voice's clothes,
- a second cluster with more than a fifth of the main speaker's airtime: the
  clip is not one person alone, and enrolling the dominant cluster anyway would
  bake a stranger into the profile. The bar is a fifth rather than zero because
  diarizers emit brief spurious clusters on breaths and room noise, and
  refusing those would reject honest clips,
- no centroid at all from the backend.

**§14.1.** The clip is a means to an embedding and never a recording. It is
written to the temporary directory, and both it and the normalised copy are
deleted before the sheet closes, including on every refusal path. Two tests
cover the leak directly, one on success and one on refusal, because a `defer`
that only fires on the happy path is the easy mistake here.

`EnrollVoiceSheet` and `VoiceSampleRecorder` live in `LonghandEngines` so both
shells present the same screen rather than growing two implementations. The
recorder is deliberately not `RecorderService`: that one owns takes, writes
into the library and hands off to the pipeline, none of which should happen to
audio that is about to be deleted. `AVAudioSession` is `#if os(iOS)`; the Mac
records without one by design.

Reached from Settings → Enrolled Voices on iOS and the Voices tab on macOS,
from both the empty state and the populated list, since §9.2 prefers several
samples per person across different acoustic conditions over a single clip.

`VoiceEnrollmentTests` (7) cover it with a scripted diarizer, so the rules are
testable without Core ML or a real voice.

## Recording in the background, and what a backup holds (2 Oct 2026)

**A take stopped when the screen locked.** The iOS app declared no
`UIBackgroundModes`, so iOS suspended `AVAudioRecorder` with the app the moment
it left the foreground: a meeting recorded with the phone locked came back as
the few seconds before the lock. `BGContinuedProcessingTask` (§11.1) covers
transcription only, never capture. `audio` is now declared in the partial
`Longhand/Info.plist`, and `BackgroundRecordingUITests` presses Home for ten
seconds mid-take and requires the clock to have kept running. That test only
proves anything on a phone: the simulator does not suspend the recorder, and
the test passed there with the key removed. On the owner's iPhone it passes
with the key, and with the key removed it fails the way the bug did: ten
seconds in the background recorded three. It also means
playback continues with the screen locked, which it did not before.

**The models were in every iCloud backup.** Argmax's hub client writes to
`Documents/huggingface`, so 626 MB (or 947 MB, plus 11 MB of speaker models)
of re-downloadable weights went into each backup. The folder is now flagged
`isExcludedFromBackup`, created first if needed so a download in progress is
covered from its first byte. The flag is set on every model load and every
speaker-model seed, which is how an existing install picks it up: on its next
job, not at launch. Moving the models to Caches was rejected: the system
purges Caches under storage pressure, which would make a 626 MB download recur
without warning.

**Enrolled voices were too (§14.1).** `speaker-profiles.json` is flagged the
same way after every write and on every read (the second covers a file written
before the flag existed). A backup is a copy `deleteAll` cannot reach, so
complete deletion was untrue while one survived. The cost is that voices must
be enrolled again after a restore onto a new device.

Data protection stays at the system default (until first unlock), deliberately.
The identify stage reads the profiles from a background job that often runs
locked, and `load` reads an unreadable file as no profiles: under `.complete` a
locked run would silently match nobody, and an enrollment made then would save
over every voice but the new one.

Job folders still back up, centroids in `20_diarization.json` included. They
sit beside the original audio, which is more identifying than any embedding
derived from it, and excluding the checkpoint alone would leave a restored job
unable to re-merge or re-identify.

## One transcript screen model, CI, and a queue that lets go (2 Oct 2026)

**The two transcript screens shared a model in name only.** `TranscriptView`
(iOS) and `MacTranscriptView` each carried their own copy of the loading,
marker placement, every correction, the turn-text rendering and the playhead
tracker, and the copies had drifted:

- On the Mac every correction called the full `load()`, which reloads the
  player, so renaming a speaker or fixing a word stopped playback and rewound
  to 0:00. iOS had `keepingPlayback` for exactly this.
- The Mac had no row for markers flagged after the last turn began, so a flag
  pressed near the end of a recording vanished.
- The Mac printed clock times past an hour as 65:00 where iOS printed 1:05:00.
- Both computed every turn's marker placements for every row, quadratic in the
  number of turns on a marked transcript.
- Both carried a `karaokeText` nothing called.

`TranscriptScreenModel` in `LonghandEngines` now owns the data, the marker
rules (placements worked out once per load) and the corrections, which reload
data only. `TurnBodyText`, `MarkerRow`, `PlaybackTurnTracker` and
`TranscriptClock` are the shared view pieces. The shells keep what is really
theirs: the player, presentation, the iOS share sheet against the Mac save
panel, haptics, and a single-OK alert against a retryable one.
`TranscriptScreenModelTests` covers the marker rules, the edit-moves-marker
fallback and the corrections against a seeded job.

**CI.** `.github/workflows/ci.yml` runs both package test suites on every push
to `main`, on a macOS 26 runner because `LonghandEngines` targets macOS 26. Unsigned
builds of the iOS (with the watch) and Mac apps run on pull requests and on
demand only, since macOS minutes are billed at ten times the Linux rate on a
private repository. It is not yet §18.1's offline assertion: that needs the
tests run with the network denied, which a hosted runner does not offer.

**A paused job left the queue only when its turn came.** `PipelineGate` waited
on a continuation nothing could cancel, so pausing a job queued behind a long
one left the row saying "Stopping…" until the first finished. Resume did
nothing in that window either, because `start` refuses a job still counted as
running. Waiting is now cancellable (`PipelineGateTests`).

## Sharing into Longhand from other apps (2 Oct 2026)

Until now a recording made elsewhere reached Longhand only through the file
picker. The iOS app now declares `public.audio` and `public.movie` in
`CFBundleDocumentTypes`, which puts it in other apps' share sheets and Open In
menus: Voice Memos, Files, Mail attachments, messaging apps.

- **Alternate rank**, so Longhand never becomes the default app for playing
  audio; it is offered, not chosen.
- **Not opened in place** (`LSSupportsOpeningDocumentsInPlace` false). iOS
  copies the file into `Documents/Inbox` and opens that copy, so the source
  app's file is never touched and the copy is ours to delete once the job has
  its own (§14.1, nothing left lying about). The URL can arrive with a
  security scope even inside our own Inbox, so the location decides the
  deletion, never the scope: a file anywhere else is left where it is.
- **Saved defaults, no options sheet**, the same decision a drop makes. A
  shared file can arrive while the recorder, Settings or an edit sheet is up,
  and a second sheet would fail to appear and leave the file stranded.

Verified on the simulator with `$D share-sim`, which does what the share sheet
does: a spoken clip arrived, the Inbox copy was deleted, and the transcript
read back the sentence. A file opened from outside the Inbox imported and was
left in place. Not covered: a share extension (an App Group and a second
target, for apps that share only data rather than a file), and the Mac, which
already takes drag-and-drop.

## A take in progress as a Live Activity (2 Oct 2026)

With recording now carrying on behind the Lock Screen, the only sign of a
running microphone was the system's orange dot, and stopping meant unlocking
and finding the sheet. A take in progress is now a Live Activity: a card on
the Lock Screen and in Notification Center, and the Dynamic Island, with the
clock and the sheet's own Pause/Resume, Mark and Stop.

- **`LonghandLiveActivity/`** is a new iOS WidgetKit extension embedded in the
  app. Its `RecordingActivity.swift` (the `ActivityAttributes` and the
  intents) is compiled into the app as well, through a synchronized-group
  membership exception, because ActivityKit pairs an activity with its views
  by type and the buttons name the intents. The intents run only in the app:
  `RecordSheet` installs a handler while a take is open, and the extension
  never sets one.
- **One parameterless intent per button.** The first version had one intent
  with an `AppEnum` command parameter. The log showed the widget preparing it
  as `LiveRecordingCommand(nil)`; the app then tried to ask which command was
  meant, from a card that cannot ask anything, and nothing happened. Four
  intents with nothing to encode fixed it.
- **No per-second updates.** The clock is the system's own timer text counting
  from `elapsed` before `asOf`, so the app sends an update only when the phase
  or the marker count changes. A paused take shows the time it stopped at.
- **Ended, not left behind.** The activity ends the moment a take is saved or
  discarded, and any left by a crash are ended at the next launch: their
  buttons would answer to nothing.
- iOS asks once whether to allow Live Activities from Longhand, the first time
  a card is interactive. Turning them off in Settings is respected
  (`areActivitiesEnabled`).

`LiveActivityUITests` starts a take, goes Home, pulls down Notification Center,
presses Mark and Pause on the card, and checks the sheet reads "Paused · 1
marked"; then Stop from the card, and checks the take is in the library and
the card gone. Passes on the simulator and on the owner's iPhone 16 Pro Max,
where the Dynamic Island showed the clock and the Lock Screen card took the
presses. On a phone the test skips the library reset and discards the take
rather than pressing Stop, so a real library is never wiped or added to.

## Siri, Shortcuts and the Action Button (2 Oct 2026)

- **Start Recording** opens Longhand into a take. Foreground only: the record
  sheet owns the microphone. It lives in the shared
  `LonghandLiveActivity/RecordingIntents.swift` because the "Record with
  Longhand" Control names it, and a control is how the Action Button,
  Control Center and the Lock Screen reach an app in one tap.
- **Stop Recording** saves the take in progress, in the background, through
  the same handler the Live Activity's Stop uses.
- **Transcribe Audio File** takes an audio or video file and imports it with
  the saved defaults, as a shared file is.
- **Recordings are an `AppEntity`**, searched by title and transcript text with
  `LibrarySearch`, so Shortcuts can pick one. **Open Recording** navigates to
  it; **Get Transcript** returns its plain-text transcript, and asks first,
  every time: handing text to whatever a shortcut does next is an export
  (§14.1). The entity itself carries only title and date.
- **App Shortcuts phrases**: "Start recording with Longhand", "Record with
  Longhand", "Stop recording with Longhand", and one each for opening a
  recording and getting a transcript.

Intents never reach into a view. They leave a request in `AppRequests`, and
`LibraryView` acts on it with `onChange(initial: true)`, because a cold launch
from Siri runs the intent before any view exists. A sheet that would block the
record sheet (Settings, voices, rename, the file picker) is closed first; an
import waiting on its options sheet is left alone rather than imported or
discarded on someone else's behalf.

Verified: the app's half, by `SiriShortcutsUITests`'s launch-time request,
which opens the recorder already recording. Not yet verified: the spoken
round trip. The simulator answered "Siri Not Available: Data for using Siri is
downloading", Spotlight's App Shortcuts are not reachable from XCUITest, and
the phone dropped off the network before the test could run on it. The Siri
test skips with that reason rather than failing.

**The Mac has the same intents.** `Longhand/Intents/LonghandIntents.swift` and
the shared `RecordingIntents.swift` are compiled into the Mac target through
synchronized-group membership exceptions rather than copied; the only fork is
which library model the intents import into (`IntentHost`). The record
controls (`LiveRecordingCommand`, `LiveRecordingControls`) moved out of the
ActivityKit file into `RecordingIntents.swift` so the Mac can compile them.
`MacRecordSheet` answers Stop, Pause, Resume and Mark through the same handler,
and `MacLibraryView` acts on start and open requests. Verified on the Mac:
Spotlight offered Longhand's "Start Recording" for "Start recording with
Longhand", which opened the app already recording, and "Stop Recording" saved
the take, which then transcribed. That needed one installed copy: with eight
copies of the app under one bundle ID (Debug builds, DerivedData, archives),
the system indexed an old one without intents and Spotlight showed nothing.

## Playback on the Lock Screen and the Mac's media keys (2 Oct 2026)

`NowPlaying` (`LonghandEngines`) publishes the playing recording to
`MPNowPlayingInfoCenter`, with its title, the Longhand mark as artwork,
duration, position and speed, and answers `MPRemoteCommandCenter`: play,
pause, toggle, skip 15 s either way, scrubbing and speed. On iOS that is the
Lock Screen, Control Center and headphone controls; on the Mac, the same code
is Now Playing and the media keys.

- **Claimed on play, not on load.** Opening a transcript must not take the
  controls from whatever else is playing. Several transcript screens can hold
  players on iOS; the one that played last owns the controls, and only its own
  `stop()` releases them.
- **Published on change, never per tick.** The system extrapolates position
  from the rate it was given, so a paused recording must publish a rate of
  zero. A unit test caught it publishing the `Int` 0, which the system does
  not read as a rate: each branch of `isPlaying ? rate : 0` became `Any` on
  its own. It is `0.0` now, with a comment saying why.
- **The category before the player.** The system made Longhand the now-playing
  app but logged its audio queue as "NOT Now Playing eligible", having built
  it when the transcript opened under the default category. `.playback` is
  now set (not activated) before the `AVAudioPlayer` is created.

Verified on the owner's iPhone: the controls showed the title, the mark, the
scrubber and ±15 s, and their Pause paused the app (`NowPlayingUITests`, which
plays the newest finished recording muted through a debug-only
`--uitest-mute-playback`). The simulator never shows the controls for any
build tried, and the test skips there. On the Mac, Control Center's Now
Playing showed the recording with the mark and transport controls, and the
keyboard's play/pause key paused it.

## Open [VERIFY] items carried from the doc

Hebrew coverage of Apple's engine, SpeechTranscriber timing granularity,
App Store size limits for a bundled model, SpeakerKit/Pyannote/WhisperKit/
sherpa-onnx license terms, iOS 26 call-recording export format, GPU
entitlement process. None are assumed resolved anywhere in the code.
