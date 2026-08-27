# LOCAL ON-DEVICE CALL TRANSCRIPTION for iPhone 16 Pro Max
## Implementation Design Document, Version 1.1 (draft), redlined against v1.0
[TABLE]
|  |  |
| Target device | iPhone 16 Pro Max (A18 Pro) |
| Target OS | iOS 26 |
| Primary ASR | {-WhisperKit / Whisper large-v3 Turbo compressed-} {+Pluggable. Default selected by the Phase 0 benchmark (§4.2): Apple +}{+SpeechTranscriber+}{+ where the language is supported, WhisperKit large-v3 Turbo compressed otherwise and for Hebrew.+} |
| Diarization | SpeakerKit / Pyannote Community-1 {+(licensing unresolved, see §4.3)+} |
| Speaker identity | Optional TitaNet via sherpa-onnx ONNX |
| Version | {-1.0 • 18 August 2026-} {+1.1 draft • 18 August 2026+} |
[/TABLE]

### Redline conventions
- {-Struck text-} is proposed for deletion. 
- {+Underlined/inserted text+} is proposed for addition. 
- Sections marked [NEW] did not exist in v1.0. 
- Blockquoted ⟨R-n⟩ notes are reviewer rationale, not part of the final document; delete them on acceptance. 
- Items marked [VERIFY] are factual claims this revision could not confirm and that must be checked against primary sources before the document is treated as settled. 
### Change summary
[TABLE]
| # | Severity | Section | Change |
| R-1 | High | §4.2 [NEW], §6.1 | Apple SpeechAnalyzer/SpeechTranscriber was never evaluated. Added an explicit engine comparison and a Phase 0 gate; ASR engine is now a benchmarked choice, not an assumption. |
| R-2 | High | §13.3 [NEW], §14.2 | No model-delivery design existed. Added asset delivery, integrity, disk preconditions, and resolution of the "strict-local app that downloads 700 MB" contradiction. |
| R-3 | High | §12.1, §18.2 | No speaker-attribution metric. Added cpWER/WDER as a release gate alongside WER and DER. |
| R-4 | High | §8 | Merge treated ASR and diarization timings as exact. Added boundary tolerance, segment-first attribution with word-level refinement. |
| R-5 | High | §8.2 [NEW] | Overlapped speech was in the test corpus but absent from the design. Added an explicit, bounded policy. |
| R-6 | High | §5.1, §5.5 [NEW] | .hda (headerless MPEG elementary stream), the actual source format, was unsupported and AVFoundation cannot decode it. Added an ingest adapter requirement. |
| R-7 | High | §5.3 | Stereo bypass under-specified; hid a 2× ASR cost and ignored channel crosstalk. Rewritten and deferred behind a gate. |
| R-8 | Medium | §12 | End-to-end targets carried no per-stage budget and were therefore untestable until integration. Added a stage budget table. |
| R-9 | Medium | §4.3 [NEW] | Load-bearing third-party dependencies had no licensing or commercial-terms analysis. |
| R-10 | Medium | §6.4 [NEW] | Whisper hallucination on silence/non-speech had no mitigation despite a long-silence corpus. |
| R-11 | Medium | §6.1 | large-v3 turbo is a speed distillation; presenting it as settled conflicts with the Hebrew requirement. Made it revisable by benchmark. |
| R-12 | Medium | §15.4 [NEW], §16 | Hebrew in the corpus but no RTL/bidi handling in UI or exporters. |
| R-13 | Medium | §13.4 [NEW] | No retention policy; every job retained originals plus ~115 MB/hr of normalized PCM indefinitely. |
| R-14 | Minor | §10 | EXPORTED is not a job state; no re-entry edge existed for the promised no-inference relabeling. |
| R-15 | Minor | §6.3 | Per-word confidence implied calibrated probability. Renamed and qualified. |
| R-16 | Minor | §15.2 | Playback-synced 1-hour transcript needs a virtualization plan. |
| R-17 | Minor | §18.2 | Offline assertion made structural/CI-enforced rather than a manual observation. |
| R-18 | Minor | §2.2, §5.2 | iOS 26 system call recording noted as an ingestion source. |
| R-19 | Minor | §17 | Failure table missing asset, disk, and format-rejection rows. |
| R-20 | Medium | §19 | Roadmap assumed the engine decision. Added Phase 0. |
[/TABLE]

## 1. Executive Summary
Purpose. Design a completely local iPhone application that imports a recorded call or meeting and produces a timestamped, speaker-attributed transcript without sending the recording, transcript, or voice embeddings to a cloud service during inference.
{-Recommended production stack:-}{- WhisperKit for ASR and word timestamps; SpeakerKit for Community-1 diarization; optional TitaNet ONNX for known-speaker identification; AVFoundation for media handling; SwiftUI for the UI; BackgroundTasks for resumable long-running processing.-}
{+Recommended production stack.+}{+ A pluggable ASR layer (§16.1) with two conforming engines, Apple's on-device +}{+SpeechTranscriber+}{+ and WhisperKit, whose default is decided per language by the Phase 0 benchmark (§4.2); SpeakerKit for Community-1 diarization; optional TitaNet ONNX for known-speaker identification; AVFoundation plus a format-adapter layer for media handling (§5.5); SwiftUI for the UI; BackgroundTasks for resumable long-running processing.+}
⟨R-1⟩ v1.0 named WhisperKit as the stack before comparing it to the transcriber the target OS ships for free. The likely outcome is still WhisperKit, because of Hebrew, but that must be a finding, not a premise.
The design is optimized specifically for the iPhone 16 Pro Max. Apple specifies an A18 Pro SoC with a 6-core CPU, 6-core GPU, and 16-core Neural Engine. The phone is sold with 256 GB, 512 GB, or 1 TB of storage. The architecture therefore prioritizes Core ML/Apple-silicon execution, bounded-memory audio loading, model lifecycle control, and checkpointing rather than a desktop-style Python runtime.
The expected user workflow is intentionally simple:
HiDock / Files / Share Sheet
        ↓
  Import recording
        ↓
 On-device processing
        ↓
Speaker-labelled transcript
        ↓
Review / rename speakers / export

## 2. Goals and Non-Goals
### 2.1 Functional goals
- Import recordings from Files, a Share Sheet, a document picker, or another app without requiring a recorder-specific protocol{+, including source formats AVFoundation cannot decode directly (§5.5)+}. 
- Transcribe multilingual audio locally and retain word- or segment-level timing. 
- Detect speaker turns using Community-1 on-device diarization. 
- Optionally map diarization clusters to enrolled people using local speaker embeddings. 
- Preserve the original file and all intermediate artifacts for deterministic reprocessing. 
- Remain usable if the app is backgrounded or interrupted by checkpointing every expensive stage. 
- Provide JSON as the canonical transcript representation plus Markdown, TXT, SRT, and WebVTT exports. 
- Allow the user to correct speaker identities without rerunning ASR or diarization. 
- {+Render and export bidirectional text (Hebrew/English) correctly (§15.4).+} 
### 2.2 Non-goals for v1
- Directly recording ordinary cellular/VoIP calls inside the app; the initial product ingests an existing recording. {+Note that iOS 26's system call-recording feature produces recordings the user can share into this app, so the non-goal costs less coverage than it appears to. +}{+[VERIFY]+}{+ feature availability by region and the exported file's format/metadata.+} 
- Cloud transcription, cloud summarization, or cloud speaker recognition. 
- Real-time meeting-bot behavior. 
- Automatic contact/calendar identity claims without user confirmation. 
- A local LLM summary stage; this is intentionally downstream of the canonical transcript and can be added later. 
- {+Speaker-attributed output for heavily overlapped speech beyond the bounded policy in §8.2.+} 

## 3. Target Platform and Constraints
[TABLE]
| Item | Design choice |
| Device | iPhone 16 Pro Max |
| SoC | Apple A18 Pro |
| CPU | 6-core: 2 performance + 4 efficiency cores |
| GPU | 6-core Apple GPU |
| Neural Engine | 16-core Neural Engine |
| Storage | 256 GB / 512 GB / 1 TB |
| OS target | iOS 26 |
| App language | Swift 6 + SwiftUI |
| Primary compute | Core ML / Apple silicon; ONNX Runtime only where needed |
| {+Free disk precondition+} | {+Model assets + 2× source duration of working audio; enforced before a job starts (§13.3, §13.4)+} |
[/TABLE]
Important memory rule. Do not hard-code assumptions about available RAM. The app should react to memory pressure, use incremental audio loading, avoid holding ASR and diarization models concurrently until benchmarks prove it is safe, and be able to unload/reload model components between stages.

## 4. System Architecture
The pipeline deliberately separates transcription, diarization, identity recognition, and presentation. This keeps every stage replaceable and allows a completed job to be re-merged or re-labelled without rerunning neural inference.
Figure 1. Preferred iPhone 16 Pro Max processing architecture.
### 4.1 Preferred component choices
[TABLE]
| Layer | Technology | Reason |
| Media import / decode | AVFoundation + Uniform Type Identifiers {++ format adapters (§5.5)+} | Native file handling; channel inspection; decode to float PCM. {+Adapters cover headerless/raw sources AVFoundation rejects.+} |
| ASR | {-WhisperKit-} {+SpeechTranscribing+}{+ protocol with two engines: Apple +}{+SpeechTranscriber+}{+ and WhisperKit (§4.2)+} | {-Swift-native on-device Whisper; Core ML; word timestamps; VAD; incremental loading.-} {+Language coverage and cost differ sharply between the two; the protocol lets the default be chosen per language by measurement rather than assumption.+} |
| Diarization | SpeakerKit | Core ML implementation of Pyannote Community-1 on Apple silicon. {+Subject to §4.3.+} |
| Known-speaker ID | TitaNet through sherpa-onnx | Optional; local ONNX speaker embeddings and similarity matching. |
| Persistence | FileManager + SQLite/GRDB or SwiftData | Job state, speaker enrollment metadata, transcript indexes. |
| Background work | BGContinuedProcessingTask | Continue user-initiated long work after backgrounding on iOS 26. |
| UI | SwiftUI | Import, progress, transcript review, speaker correction, export. |
[/TABLE]
### 4.2 ASR engine evaluation [NEW]
⟨R-1⟩ This section is the substantive addition of v1.1. Everything downstream of it (app size, thermal budget, §13.3, and the roadmap) depends on its outcome.
Two on-device engines are candidates. They are not interchangeable, and the difference is not primarily accuracy:
[TABLE]
| Dimension | Apple SpeechTranscriber (iOS 26) | WhisperKit large-v3 Turbo compressed |
| App size cost | None; assets are OS-managed | ~626 MB package to deliver and store (§13.3) |
| Language coverage | Limited to Apple's supported set. [VERIFY] whether Hebrew is included; the working assumption is no | Broad multilingual, including Hebrew |
| Code-switching | Unknown; likely weak across a language boundary. [VERIFY] | Native to the model, though quality varies |
| Word timings | Provided [VERIFY] granularity and stability | Provided; DTW-derived, see §8 |
| Thermal / power | Lower; OS-tuned and hardware-scheduled | Higher; the dominant contributor to §11.2 risk |
| Version control | Follows the OS; not pinnable by the app | Pinnable, which §13.2 requires for reproducibility |
| Offline posture | Assets may require a one-time OS-managed download | One-time app-controlled download or bundle |
[/TABLE]
Decision rule. The engine is selected per recording by detected/declared language:
- If the language is in Apple's supported set and the recording is not flagged as code-switching, use SpeechTranscriber. 
- Otherwise use WhisperKit. 
- The user may override per job; the chosen engine and version are recorded in models.asr (§13.1). 
Gate. Phase 0 (§19) must produce, on a physical iPhone 16 Pro Max: WER per engine on the English and Hebrew reference recordings, wall clock, peak memory, and thermal transitions. If Apple's engine covers a language at comparable WER, it is the default for that language, since the size and thermal savings are decisive. If WhisperKit must ship anyway for Hebrew, evaluate whether shipping both is worth the complexity, or whether one engine for all languages is simpler at acceptable cost. Either outcome is acceptable; shipping without having measured is not.
### 4.3 Dependency licensing and commercial terms [NEW]
⟨R-9⟩ v1.0 selected a stack without recording whether it may be shipped. This blocks Phase 2, not Phase 7.
Before SpeakerKit work begins, resolve and record in this document:
- SpeakerKit: open-source SDK terms vs. any commercial/Pro tier, and whether App Store distribution of a shipping product is covered. [VERIFY] 
- Pyannote Community-1 weights: model license, attribution obligations, and any gating on model distribution. [VERIFY] 
- WhisperKit / Whisper weights: model and code licenses (expected permissive; confirm the specific compressed variant's redistribution terms). [VERIFY] 
- sherpa-onnx and the NeMo TitaNet export: runtime license and model license, which differ. [VERIFY] 
For each: license, whether redistribution inside an app bundle is permitted, attribution text required in the app's acknowledgements screen, and any commercial threshold. A dependency that cannot be resolved is a design change, not a legal footnote; §16.1's protocol boundaries exist partly so one can be swapped.

## 5. Recording Ingestion and Audio Preparation
### 5.1 Supported inputs
- M4A / AAC 
- WAV 
- MP3 
- FLAC 
- MOV / MP4 when audio is embedded 
- {+HiDock +}{+.hda+}{+ / +}{+.hta+}{+: headerless MPEG audio elementary stream (Layer 1/2, mono, 16 kHz, ~64 kb/s), with per-model variants that are instead plain RIFF/WAV or raw PCM. AVFoundation cannot decode the headerless case; see §5.5.+} 
- Other formats that AVFoundation can decode reliably 
The importer copies the original file into the app container before processing. Processing never mutates the original.
### 5.2 Import paths
- UIDocumentPicker / Files app. 
- Share extension: "Share → Local Transcript". {+This is also the path for recordings produced by the iOS 26 system call recorder (§2.2).+} 
- Open-in-place when a provider supports it, followed by a protected local copy for deterministic processing. 
- {-Future recorder-specific import adapters can write into the same ingestion boundary.-} {+Recorder-specific format adapters (§5.5) sit behind the same ingestion boundary and run before validation.+} 
### 5.3 Channel preservation {-and diarizer bypass-} {+(deferred)+}
⟨R-7⟩ v1.0 proposed bypassing the diarizer for dual-channel sources. That is correct in principle and wrong to schedule into v1: the detection is fragile and the bypass silently doubles the most expensive stage.
{-Do not immediately downmix stereo. If a recorder stores the local microphone and remote participant in separate channels, speaker attribution is deterministic and the diarizer should be bypassed. The app first inspects channel count and channel energy/correlation before creating the mono working stream.-}
{+v1 behavior.+}{+ Record channel count, per-channel energy, and inter-channel correlation into +}{+metadata.json+}{+ at import, then downmix to the mono working stream and diarize normally. Do not branch on the measurement yet.+}
{+Why the bypass is deferred.+}{+ Two problems v1.0 did not state:+}
{+1. +}{+Detection is not reliable.+}{+ Real recorders bleed the far-end signal into the near-end channel. A correlation threshold that works on a clean synthetic case misfires on acoustic echo, shared AGC, or a recorder that duplicates one mic across both channels. A false positive produces a confidently wrong transcript, which is worse than a diarization error the user can see and correct.+} {+2. +}{+The bypass doubles ASR cost.+}{+ Per-channel attribution requires transcribing each channel separately. That is 2× the dominant stage, against §12 budgets computed for one pass; the bypass trades a cheap diarization pass for an expensive second ASR pass and may be a net loss.+}
{+Gate to enable.+}{+ Ship the bypass only once (a) the collected +}{+metadata.json+}{+ measurements from real recordings show a separable decision boundary, and (b) a dual-ASR run measures faster than mono ASR + diarization on the same file. Note that the primary source for this product (HiDock) records mono, so this path may not earn its complexity at all.+}
### 5.4 Canonical audio representation
Internally, the pipeline should expose 16 kHz mono float PCM to speech models while preserving the original media file. One hour of 16 kHz mono 16-bit PCM is about 115 MB, so storing a temporary normalized copy is practical, but the implementation should prefer streaming/incremental decoding to reduce memory pressure. {+The normalized copy is a working artifact, not a checkpoint, and is deleted per §13.4.+}
### 5.5 Format adapters for non-AVFoundation sources [NEW]
⟨R-6⟩ The product's actual source device writes a format the framework rejects. v1.0 filed this under "future adapters"; for this product it is Phase 1.
Some recorders, HiDock among them, write a headerless MPEG audio elementary stream with no container and no parseable header. AVAsset fails to open these. The adapter layer runs at the ingestion boundary and applies, in order:
- Probe as-is. If AVFoundation recognizes a stream, use it. This covers .hda files that are actually RIFF/WAV or a containerized variant. 
- Forced MPEG elementary-stream decode. Layer 1/2/3 frames at 16 kHz mono. Because permissive MPEG parsers will "open" arbitrary bytes, require a positive frame-sync and plausible duration before accepting the result. 
- Raw PCM, 16 kHz mono 16-bit. Last resort, accepted only on an explicit user confirmation of the format. 
- Reject with a specific error before any neural inference (§17). 
The probe/fallback logic already exists in this workspace as tools/hda2mp3.sh and should be ported to Swift rather than reinvented; the shell script is the reference implementation and its ordering rationale carries over directly. Adapters normalize into the same 16 kHz mono float PCM contract as §5.4, so nothing downstream knows the source was unusual.

## 6. ASR Design
⟨R-1⟩ Retitled from "ASR Design: WhisperKit"; this section now describes the WhisperKit engine specifically, and applies to it whenever it is the selected engine per §4.2.
{-Use WhisperKit as the primary ASR engine.-} {+Where §4.2 selects WhisperKit, the following applies.+} Argmax documents on-device transcription, word timestamps, VAD, and incremental loading for long recordings. For iOS, its current recommendation for maximum multilingual accuracy is the compressed large-v3 Turbo variant large-v3-v20240930_626MB.
### 6.1 Default model profiles
[TABLE]
| Profile | Model | Use |
| Fast | small or base | Debugging, archive indexing, battery-sensitive use. |
| Balanced (default) | large-v3 Turbo compressed (~626 MB package) {+(+}{+provisional, see gate below+}{+)+} | Best default for iPhone 16 Pro Max. |
| Maximum accuracy | Same compressed Turbo initially; evaluate alternate large variants only after device benchmark | Avoid choosing a larger model merely because it exists; thermal and memory stability matter more. |
[/TABLE]
{+Turbo caveat and gate.+}{+ +}{+large-v3 turbo+}{+ is a +}{+speed distillation+}{+ of +}{+large-v3+}{+, and its quality regression is not uniform across languages. This document requires Hebrew and English/Hebrew code-switching support (§18.1), which is exactly where a distilled model is most likely to give ground. Treat "Balanced = Turbo" as provisional: if Phase 0 measures a material Hebrew WER gap against non-distilled +}{+large-v3+}{+, the default model changes, and the size and thermal consequences of that change flow into §13.3 and §12.+}
⟨R-11⟩ v1.0 correctly warned against picking a bigger model for its own sake, but then picked the smaller/faster one for its own sake. The gate makes both directions evidence-driven.
### 6.2 Long-file loading
let options = AudioInputOptions(audioLoadingMode: .incremental)
let results = try await whisper.transcribe(
    audioPath: recordingURL.path,
    audioInputOptions: options
)
Incremental loading should be mandatory for recordings above a configurable threshold (for example 10 minutes). WhisperKit splits long audio at silence/VAD boundaries while keeping peak memory bounded.
### 6.3 ASR output contract
{
  "language": "en",
  "engine": "whisperkit",
  "segments": [...],
  "words": [
    {"text":"We",   "start":13.42, "end":13.61, "avgLogprob":-0.21},
    {"text":"need", "start":13.62, "end":13.94, "avgLogprob":-0.34}
  ]
}
{+The per-word score is a token +}{+log-probability+}{+, not a calibrated confidence. It is usable for ranking and thresholding (§6.4) and must not be presented to the user as a percentage or treated by downstream logic as +}{+P(correct)+}{+. The field is named +}{+avgLogprob+}{+ rather than +}{+confidence+}{+ to prevent exactly that. Engines that cannot supply it omit the field; consumers must tolerate its absence.+}
⟨R-15⟩ v1.0's "confidence":0.94 invites a UI that shows "94% sure", which the underlying number does not support.
{+The +}{+engine+}{+ field is required so a transcript can be reproduced with the engine that produced it (§4.2, §13.1).+}
### 6.4 Hallucination and non-speech handling [NEW]
⟨R-10⟩ §18.1 tested a long-silence recording; nothing in v1.0 said what should happen. This is Whisper's most common production failure.
Whisper-family models emit fluent text for non-speech input and can enter repetition loops. Required mitigations when WhisperKit is the engine:
- VAD gating. Do not submit regions the VAD marks as non-speech. This is the primary defense; the remaining rules are backstops. 
- Repetition detection. Flag a segment whose n-gram repetition rate exceeds a threshold, or which repeats the previous segment's text verbatim. Drop the repeated tail rather than the whole segment. 
- Logprob suppression. Drop segments whose mean avgLogprob falls below a calibrated floor and which sit inside a VAD-silent region. Both conditions are required, since low logprob alone also occurs on genuinely difficult speech, and silently dropping hard audio is worse than the hallucination. 
- Boilerplate list. Maintain a small list of known hallucination artifacts (subtitle-credit phrases and similar) suppressed only in non-speech regions. 
- Never silently discard. Suppressed spans are recorded in 10_asr.json with the reason so the behavior is auditable and the thresholds are tunable against the §18.1 corpus. 
Thresholds are calibrated on the long-silence recording and validated against the noisy 60-minute call to confirm real speech is not being suppressed.

## 7. Diarization Design: SpeakerKit / Community-1
Use SpeakerKit for speaker diarization{+, subject to §4.3+}. The current Argmax open-source SDK runs Pyannote v4 / Community-1 on Apple silicon using Core ML, supports iOS 16+, and can accept an explicit speaker count. This removes the need to port the Python Community-1 pipeline to iOS.
### 7.1 Call-mode optimization
if metadata.expectedSpeakerCount == 2 {
    diarization.numSpeakers = 2
}
For ordinary phone calls, a trustworthy known count of two should be supplied. For meetings, allow the diarizer to infer the count or constrain a range when the framework exposes that option. {+"Trustworthy" means user-declared or structurally implied, never inferred from the filename. An incorrect forced count is unrecoverable without rerunning the stage.+}
### 7.2 Diarization output
[
  {"speaker":"SPEAKER_00", "start":0.42, "end":4.83},
  {"speaker":"SPEAKER_01", "start":5.10, "end":9.21},
  {"speaker":"SPEAKER_00", "start":9.47, "end":13.18}
]
### 7.3 Execution order on iPhone
Although ASR and diarization are logically independent, v1 should run them sequentially on iPhone. This reduces simultaneous Core ML memory pressure and makes thermal behavior predictable. Parallel execution can be enabled only after profiling on the actual iPhone 16 Pro Max.
{+The cost of this choice is that wall clock is the +}{+sum+}{+ of both stages, which §12 now budgets explicitly rather than leaving implied.+}
ASR + timestamps
      ↓ unload ASR model if necessary
Community-1 diarization
      ↓
    merge

## 8. Word-to-Speaker Merge
The merge layer assigns each timestamped ASR word to a diarization cluster. This is deterministic application logic and should be heavily unit-tested.
{+Precondition: both inputs are approximate.+}{+ Whisper word timestamps are derived from cross-attention alignment and typically drift on the order of 100–300 ms; diarization boundaries are similarly soft, and both are least reliable +}{+at turn boundaries+}{+, precisely where an attribution error is most visible to the user. v1.0's overlap arithmetic treated both as exact. The revised algorithm therefore prefers the more stable unit (the segment) and admits a tolerance.+}
⟨R-4⟩ Argmax-overlap on jittery intervals flips attribution on short boundary words. The failure is not rare and it reads as a broken product.
{+Revised algorithm.+}
- {+Attribute at the segment level first.+}{+ For each ASR segment, choose the speaker with the largest total temporal overlap across the whole segment. Segment-level voting averages out per-word jitter.+} 
- {+Refine within a segment only on evidence.+}{+ Split a segment across speakers only where a diarization boundary falls inside it with a margin greater than the tolerance +}{+τ+}{+ (initially 250 ms, configurable) on both sides. Otherwise the whole segment takes the segment-level speaker.+} 
- {+Apply hysteresis at boundaries.+}{+ A word whose interval lies within +}{+τ+}{+ of a speaker change inherits the speaker of the run it is contiguous with in the ASR segment, not the raw overlap winner.+} 
- {-Find all speaker intervals overlapping the word interval.-} {-Choose the speaker with the largest temporal overlap.-} {+For words not resolved by the above, choose the speaker with the largest temporal overlap.+} 
- If no meaningful overlap exists, use the speaker active at the word midpoint. 
- If still unresolved, choose the closest speaker interval only within a conservative gap threshold. 
- Otherwise mark the word as UNKNOWN rather than guessing. 
{+Word-level attribution is always retained in +}{+30_merged_words.json+}{+ even when the decision was made at segment level, so the merge can be re-run with different +}{+τ+}{+ without re-running inference.+}
### 8.1 Turn construction
After word attribution, adjacent words are merged into conversational turns when the speaker is unchanged and the inter-word gap is below a configurable threshold (initially 1.0 second). Tiny one-word islands may be smoothed conservatively, but the raw word-level attribution is always preserved.
### 8.2 Overlapped speech [NEW]
⟨R-5⟩ §18.1 requires an overlapped-speech recording. v1.0's data model cannot represent one: every word gets exactly one speaker.
The merge assigns each word a single speaker and therefore cannot represent simultaneous speech. v1 accepts this, with a bounded and visible policy rather than a silent failure:
- Detect. Where diarization reports overlapping intervals for a word's span, mark the resulting turn overlapped: true in the canonical JSON. 
- Attribute to the dominant speaker by overlap duration, as elsewhere. 
- Surface it. The transcript view marks overlapped turns; exports may include a marker in formats that support it and must not silently drop the flag. 
- Do not enroll from overlapped regions. Speaker-ID (§9) skips any segment flagged overlapped, since its embedding is contaminated. This is a hard rule, not a heuristic. 
- Measure it. The overlapped-speech recording is scored separately in §12.1; degradation there is expected and bounded, not a regression. 
Multi-speaker regions in the data model are deferred past v1 and are listed as a non-goal (§2.2).

## 9. Known-Speaker Identification with TitaNet
Diarization answers "which cluster spoke?"; identity recognition answers "is that cluster a person I already know?". Keep these responsibilities separate. TitaNet should be optional and should never be required to produce a usable Speaker 1 / Speaker 2 transcript.
### 9.1 Runtime choice
Use sherpa-onnx as the iOS-compatible runtime for a NeMo TitaNet ONNX speaker embedding model. sherpa-onnx supports iOS, speaker identification, and exported NeMo TitaNet speaker models. {+Note this introduces a second inference runtime alongside Core ML, with its own binary size and memory profile; account for it in §13.3 and treat it as a reason to keep the stage optional.+}
### 9.2 Enrollment
- Enroll multiple clean samples per person rather than a single clip. 
- Prefer samples from different acoustic conditions: handset, headset, room microphone. 
- {+Never enroll from a region flagged +}{+overlapped+}{+ (§8.2).+} 
- Store embeddings locally with model-version metadata. 
- Never auto-enroll a speaker solely from an AI prediction; require explicit user confirmation. 
### 9.3 Safer "known-self" mode
Recommended default for two-person calls: Enroll only the phone owner. After diarization, compare both clusters against the owner embedding. The matching cluster becomes "Me"; the other remains "Other participant" until the user names it. This avoids false claims about remote identities.
{+Require a +}{+margin+}{+, not just a winner: if both clusters score within a small delta of each other, or the best score is below an absolute floor, assign neither and leave both labels generic. A confidently wrong "Me" is the worst output this stage can produce.+}

## 10. Job State Machine and Checkpointing
⟨R-14⟩ v1.0's machine was strictly linear and included an action as a state, which contradicts §15.3's promise of relabeling without inference.
IMPORTED
   ↓
PREPARED
   ↓
TRANSCRIBED
   ↓
DIARIZED
   ↓
MERGED ←──────────┐
   ↓              │ re-merge (τ change, no inference)
IDENTIFIED ←──┐   │
   ↓          │   │
COMPLETE ─────┴───┘
   │  relabel / re-identify / re-export
   │  (repeatable; does not leave COMPLETE)
   ↓
~~EXPORTED~~
   ↓
~~COMPLETE~~

Any active state ─► INTERRUPTED / FAILED
{+EXPORTED+}{+ is removed: export is a repeatable action on a +}{+COMPLETE+}{+ job, not a state a job passes through once. Re-entry edges into +}{+MERGED+}{+ and +}{+IDENTIFIED+}{+ make §15.3's "no ASR rerun required" a property of the state machine rather than an aspiration. A job may be re-merged after a +}{+τ+}{+ change or re-identified after new enrollment without re-entering +}{+TRANSCRIBED+}{+.+}
Every expensive stage writes a durable checkpoint before advancing the state machine. If iOS suspends or terminates the app, the next launch resumes from the last valid checkpoint instead of repeating the entire recording.
### 10.1 Per-job files
Recordings/<UUID>/
  original.m4a
  metadata.json
  10_asr.json
  20_diarization.json
  30_merged_words.json
  40_identity.json
  transcript.json
  transcript.md
  transcript.srt
{+Working files not listed here (normalized 16 kHz PCM, temporary enrollment clips) are transient and are removed per §13.4. Checkpoint writes are atomic (write to a temp path and rename) so a termination mid-write cannot leave a truncated checkpoint that resume logic would trust.+}

## 11. Background Execution, Thermal Management, and Power
On iOS 26, BGContinuedProcessingTask is designed for user-started work that begins in the foreground and may continue after the app is backgrounded. Apple also exposes an entitlement for GPU access with continued-processing background tasks. The app should still treat background execution as interruptible and checkpoint aggressively.
### 11.1 Foreground-first policy
- Start the job in the foreground and immediately create a BGContinuedProcessingTask. 
- Expose visible progress as completed audio duration / total duration. 
- Persist progress after each ASR chunk and after every stage boundary. 
- If continued processing is unavailable, keep the job resumable and explain that foreground execution is required. 
- Do not rely on one uninterruptible 60-minute inference call. 
- {+[VERIFY]+}{+ the GPU-access entitlement's approval process and whether it is required for the selected engines; an entitlement that must be requested from Apple is a schedule dependency, not a build setting.+} 
### 11.2 Thermal policy
[TABLE]
| Thermal state | Policy |
| Nominal / fair | Normal profile. |
| Serious | Reduce concurrent work; do not launch speaker-ID work until diarization finishes; optionally lower ASR profile for newly queued jobs. {+Do not change the ASR profile mid-job: a transcript produced by two models is not reproducible from its +}{+models+}{+ block.+} |
| Critical | Checkpoint and suspend inference as soon as practical; resume when the device returns to a safer thermal state. |
[/TABLE]
{+Thermal headroom is one of the strongest arguments for Apple's engine where it covers the language (§4.2); the measurements in Phase 0 should include thermal transitions, not just wall clock.+}

## 12. Performance and Benchmark Plan
Do not treat desktop or Mac benchmarks as proof of iPhone performance. Establish device-specific gates on an actual iPhone 16 Pro Max. The following are design targets rather than guaranteed measured numbers.
[TABLE]
| Corpus | Profile | Acceptance target |
| 10-minute clean 2-person call | Balanced | ≤ 2 minutes end-to-end |
| 60-minute clean 2-person call | Balanced | ≤ 10 minutes end-to-end |
| 60-minute noisy call | Balanced | ≤ 15 minutes end-to-end |
| 60-minute call | Maximum quality | ≤ 20 minutes end-to-end |
| All tests | Any | No crash / jetsam; resume correctly after interruption |
[/TABLE]
### {+12.1 Per-stage budget +}{+[NEW]+}
⟨R-8⟩ An end-to-end number cannot be tested until everything is integrated, and gives no signal about which stage blew the budget. Because §7.3 makes the stages sequential, the budget is a sum and should be written as one.
{+Reference decomposition of the 10-minute target for a 60-minute clean call, to be replaced by measurements after Phase 0:+}
[TABLE]
| {+Stage+} | {+Budget+} | {+Notes+} |
| {+Import + decode + normalize+} | {+≤ +}{+0:30+} | {+I/O bound; includes format adapter (§5.5)+} |
| {+ASR+} | {+≤ +}{+7:00+} | {+Dominant stage; the RTF that matters+} |
| {+Diarization+} | {+≤ +}{+2:00+} | {+Not free; v1.0 left it implicit+} |
| {+Merge + turn construction+} | {+≤ +}{+0:10+} | {+Pure CPU; if it exceeds this, it is a bug+} |
| {+Speaker ID (optional)+} | {+≤ +}{+0:20+} | {+Only on clean, non-overlapped segments+} |
| {+Total+} | {+≤ +}{+10:00+} |  |
[/TABLE]
{+If Phase 0 shows the sum cannot be met, the correct response is to change the target or the engine, not to enable parallel execution against §7.3's reasoning without profiling.+}
### {-12.1-} {+12.2+} Metrics to record
- Wall-clock time by stage 
- Real-time factor 
- Peak resident memory when measurable 
- Thermal state transitions 
- Battery percentage delta 
- ASR word error rate on annotated samples 
- Diarization error rate on annotated samples 
- {+Speaker-attributed WER (cpWER) and word diarization error rate (WDER)+}{+: release gates, not diagnostics.+} 
- Speaker-ID false accept / false reject rate 
⟨R-3⟩ WER and DER can both pass while the product fails. Attribution error is the product of two noisy stages plus §8's merge, and it is what the user actually reads. Without cpWER/WDER, §8 is the only major component with no acceptance metric, and it is the one most likely to be quietly wrong.
{+Report metrics separately for: clean 2-person, noisy, 4-person meeting, and overlapped-speech recordings. Overlapped-speech cpWER is expected to be worse and is bounded rather than gated (§8.2).+}

## 13. Storage and Data Model
### 13.1 Canonical transcript JSON
{
  "recordingID": "...",
  "sourceHash": "...",
  "duration": 3604.32,
  "language": "en",
  "pipelineVersion": "1.1.0",
  "models": {
    "asr": "whisperkit/large-v3-v20240930_626MB",
    "diarization": "speakerkit/community-1",
    "speakerID": "titanet-large"
  },
  "mergeParams": { "boundaryToleranceMs": 250, "turnGapSeconds": 1.0 },
  "speakers": {
    "SPEAKER_00": {"displayName":"Me", "matchScore":0.93, "confirmedByUser":true},
    "SPEAKER_01": {"displayName":"Speaker 2"}
  },
  "turns": [
    {"speaker":"Me", "start":12.41, "end":17.52, "overlapped": false,
     "text":"We need to get this done before Wednesday."}
  ]
}
{+Changes from v1.0: +}{+models.asr+}{+ is engine-qualified (§4.2); +}{+mergeParams+}{+ records the tolerance so a re-merge is reproducible (§8); +}{+overlapped+}{+ per turn (§8.2); +}{+confidence+}{+ on a speaker is renamed +}{+matchScore+}{+ and paired with +}{+confirmedByUser+}{+, so the UI can distinguish "the model thinks" from "the user said" (§9.3).+}
### 13.2 Persistence strategy
- Use files for large immutable artifacts (audio and JSON checkpoints). 
- Use SQLite/GRDB or SwiftData for job metadata, transcript indexing, speaker profiles, and settings. 
- Store a SHA-256 of the original recording for duplicate detection. 
- Version the pipeline and every model revision used for a transcript. 
- Allow re-export and speaker renaming without re-running inference. 
### 13.3 Model asset delivery, integrity, and versioning [NEW]
⟨R-2⟩ The single largest gap in v1.0. ~626 MB of ASR weights plus SpeakerKit models plus an optional ONNX runtime and TitaNet have to physically arrive on the device, and v1.0 addressed this only as a compliance aside in §14.2.
Inventory. Every shipped asset with its size, source, license (§4.3), and pinned revision:
[TABLE]
| Asset | Approx. size | Required for |
| WhisperKit large-v3 Turbo compressed | ~626 MB | ASR (non-Apple-engine languages) |
| SpeakerKit / Community-1 Core ML models | TBD [VERIFY] | Diarization, required for the core product |
| sherpa-onnx runtime + TitaNet embeddings | TBD [VERIFY] | Optional speaker ID |
| Apple SpeechTranscriber assets | OS-managed | ASR (supported languages) |
[/TABLE]
Delivery strategy, decided in Phase 0 and recorded here:
- Bundled in the app. Simplest and fully offline from first launch, but pushes the download past App Store cellular thresholds and forces a full app update for a model revision. [VERIFY] current App Store size limits before assuming this is viable at ~700 MB. 
- On-Demand Resources. App Store-hosted, no separate server, evictable by the OS, which means the app must handle an asset disappearing between jobs. 
- First-run download from a controlled host. Most flexible and the worst first-run experience; requires hosting, versioning, and a resumable transfer. 
Requirements regardless of strategy:
- Integrity. Every asset is hash-pinned; verify before first use and refuse to run on mismatch. A corrupt model must fail loudly at load, not produce degraded transcripts. 
- Preconditions. Check free disk before download and before each job (§3). Never begin a 60-minute job that will fail at the last checkpoint write. 
- Resumability. Downloads resume; a partial asset is never treated as present. 
- Pinning. The asset revision is recorded per transcript (§13.1). Upgrading a model does not retroactively change existing transcripts, and re-running a job with a new model is an explicit user action. 
- Removability. The user can delete optional assets (speaker ID) to reclaim storage; the app degrades per §17. 
- Honesty. Whichever strategy is chosen, the first-run experience is stated in §14.2 rather than described as "no cloud". 
### 13.4 Retention and cleanup [NEW]
⟨R-13⟩ v1.0 retained the original, a ~115 MB/hr normalized copy, and six JSON artifacts per job, indefinitely, on a phone that may have 256 GB.
- Delete the normalized 16 kHz PCM working file when the job reaches COMPLETE. It is fully reproducible from the original and is the largest transient artifact. 
- Delete temporary enrollment clips immediately after embedding generation (already required by §14.1). 
- Retain the original recording, metadata.json, and stage checkpoints: these are what make reprocessing deterministic and are the point of §10. 
- Offer per-job "delete original, keep transcript" and a storage screen showing per-job usage, with jobs sorted by size. 
- Warn when free space falls below the working-set requirement for a queued job, before it starts. 

## 14. Privacy, Security, and Compliance Controls
Security property: The inference path is local. No recording, transcript, diarization output, or speaker embedding needs to leave the phone once the required models are present.
### 14.1 Data protection
- Store recordings and transcript databases with iOS Data Protection enabled. 
- Keep files inside the application sandbox unless the user explicitly exports them. 
- Exclude temporary working files from broad sharing mechanisms. 
- Delete temporary speaker clips immediately after embeddings are generated. 
- Treat speaker embeddings as sensitive biometric-like data and support complete deletion. 
- {+Treat +}{+export+}{+ as the privacy boundary: the share sheet leaves the sandbox. Confirm destination-agnostic exports of transcripts the same way any data egress would be confirmed, and do not include speaker embeddings in any export.+} 
### 14.2 Strict-local build
For the strongest compliance posture, provide a build/configuration that has no cloud transcription or analytics dependency at all. {-Models can be bundled, installed during a controlled setup step, or downloaded once and then used from local storage.-} {+Model acquisition is designed in §13.3, and the honest framing is: +}{+the inference path is local; the asset-acquisition path may not be.+}{+ An app that downloads ~700 MB of weights on first launch is not "never touches the network"; it is "never sends your audio anywhere". Say the second thing, in the UI as well as here.+}
⟨R-2⟩ v1.0's strongest privacy claim sat one paragraph away from an unresolved 700 MB download. The claim survives precisely stated; it does not survive being overstated.
{+For the strict-local configuration specifically, prefer bundled or ODR-delivered assets so that a device can complete a job having never made an app-initiated network request after installation, and make that testable per §18.2.+}
If an organization requires technical prevention of outbound traffic rather than application-level assurances, enforce that with its device-management/network-control stack; ordinary iOS app sandboxing does not itself mean "no Internet".
### 14.3 Logging
- Never write transcript text to diagnostic logs by default. 
- Log job ID, stage, duration, model version, and error codes only. 
- Provide an explicit redacted diagnostic export for support. 
- Do not emit speaker embeddings or voice samples to logs/crash reports. 
- {+Do not log source filenames; a filename is often the most identifying string in the pipeline.+} 

## 15. User Experience
### 15.1 Library screen
┌──────────────────────────────────┐
│ Local Transcript                 │
│                                  │
│ + Import Recording               │
│                                  │
│ Today                            │
│ Work call              01:02:13  │
│ ✓ Complete                       │
│                                  │
│ Design review          00:47:22  │
│ Transcribing… 68%                │
└──────────────────────────────────┘
### 15.2 Transcript screen
┌──────────────────────────────────┐
│ Work call                        │
│                                  │
│ Me                      00:04    │
│ I looked at the issue yesterday. │
│                                  │
│ Speaker 2               00:11    │
│ Did you find the cause?          │
│                                  │
│ Me                      00:15    │
│ Yes, it looks like...            │
│                                  │
│ ▶ ───────────── 13:42 / 1:02:13  │
└──────────────────────────────────┘
{+Rendering at scale.+}{+ A 60-minute transcript is on the order of 10,000 words and several hundred turns, with playback-synced highlighting updating continuously. Naïve SwiftUI rendering of that is a known performance trap. Requirements: a lazy/virtualized list keyed by stable turn IDs; highlight state driven by a throttled time observer rather than per-frame view invalidation; scroll anchoring that survives a speaker rename; and a scroll-performance test on the 60-minute corpus (§18.2).+}
⟨R-16⟩ The pipeline can be perfect and the product still feel broken if the transcript view stutters while scrubbing an hour-long call.
### 15.3 Speaker correction
- Tap a speaker label → Rename. 
- Optionally choose an existing enrolled identity. 
- Optionally "Use clean segments from this call to improve this speaker" after explicit confirmation. {+Overlapped segments are excluded from this offer (§8.2).+} 
- Re-render the transcript immediately; no ASR rerun required. {+This is the +}{+COMPLETE+}{+ self-edge in §10.+} 
### 15.4 Bidirectional text and localization [NEW]
⟨R-12⟩ §18.1 requires Hebrew and English/Hebrew code-switching recordings. v1.0's UI and exporter sections never mention direction.
Hebrew is a first-class requirement, so RTL is a design requirement and not a localization afterthought:
- Transcript view. Per-turn text direction derived from content, not from the app locale: a Hebrew turn and an English turn in the same call must each render correctly. Speaker label, timestamp, and text must not swap into an illegible arrangement when direction flips. 
- Code-switched turns. Mixed-direction runs within a single turn need correct bidi handling, including punctuation at run boundaries, which is where naïve rendering fails visibly. 
- App UI. Full RTL layout support when the device locale is Hebrew, independent of transcript content. 
- Exporters. SRT and WebVTT are the hard cases: mixed-direction subtitle text needs explicit directional marks to render predictably in third-party players. Markdown and TXT need the same consideration. Golden-file tests (§18.2) must include a code-switched sample per format. 
- Search. Normalization and matching behave correctly for Hebrew, including nikkud-insensitive matching if search is added. 

## 16. Swift Module Boundaries
App/
  UI/
  Import/
  Audio/
  ASR/              // engine adapters: WhisperKit, Apple SpeechTranscriber
  Diarization/      // SpeakerKit adapter
  SpeakerID/        // TitaNet / sherpa-onnx adapter
  Merge/
  Jobs/
  Storage/
  Assets/           // NEW: model asset delivery, integrity, lifecycle (§13.3)
  Export/
  Localization/     // NEW: bidi/RTL helpers shared by UI and Export (§15.4)
  Security/
  Diagnostics/
### 16.1 Core protocols
protocol SpeechTranscriber {
    func transcribe(_ input: AudioAsset, progress: ProgressSink) async throws -> ASRResult
}

protocol SpeakerDiarizer {
    func diarize(_ input: AudioAsset, expectedSpeakers: Int?) async throws -> DiarizationResult
}

protocol SpeakerIdentifier {
    func identify(cluster: SpeakerCluster, in audio: AudioAsset) async throws -> IdentityMatch?
}
{+Two amendments:+}
{+1. +}{+Rename the ASR protocol.+}{+ +}{+SpeechTranscriber+}{+ now collides with Apple's own type name (§4.2). Use +}{+SpeechTranscribing+}{+ for the protocol.+} {+2. +}{+Add capability declaration+}{+, so §4.2's per-language routing is data-driven rather than a hard-coded switch:+}
protocol SpeechTranscribing {
    static var engineID: String { get }
    func supports(language: Locale.Language) -> Bool
    func transcribe(_ input: AudioAsset, progress: ProgressSink) async throws -> ASRResult
}
{+An +}{+AudioSourceAdapter+}{+ protocol covers §5.5, so new recorder formats are additive.+}
Protocol boundaries make it possible to benchmark {-Apple SpeechTranscriber-} {+either ASR engine+}, a future SpeakerKit release, or a different speaker embedding model without rewriting ingestion or storage. {+They are also the mitigation if §4.3 resolves badly for any dependency.+}

## 17. Failure Handling and Graceful Degradation
[TABLE]
| Failure | Required behavior |
| ASR fails | Job fails at TRANSCRIBING; keep original and error metadata; retry allowed. |
| Diarization fails | Still export timestamped transcript without speaker labels. |
| Speaker identification fails | Keep Speaker 1 / Speaker 2 labels. |
| Background task expires / app terminated | Resume from latest durable checkpoint. |
| Memory pressure | Unload nonessential models; reduce chunk size; continue sequentially. |
| Thermal critical | Checkpoint and pause; do not corrupt the job. |
| Unsupported media | Fail validation before any neural inference. {+Name the format in the error and, for a headerless source, offer the explicit raw-PCM confirmation path (§5.5) rather than a generic rejection.+} |
| {+Model asset missing or hash mismatch+} | {+Fail before inference with a specific, actionable error; offer re-download; never fall back to an unverified asset.+} |
| {+Optional asset removed by user or evicted by OS+} | {+Degrade to the stage below (no speaker ID; or no diarization) and say so in the UI; do not silently produce a lesser transcript.+} |
| {+Insufficient disk at job start or mid-job+} | {+Refuse to start with a required-vs-available figure; mid-job, checkpoint and pause rather than failing the write.+} |
| {+Selected ASR engine unavailable for the detected language+} | {+Fall back to the other engine per §4.2 and record the substitution in +}{+models.asr+}{+.+} |
| {+Forced speaker count contradicted by audio+} | {+Complete the job; surface that the count was forced so the user can re-run without it.+} |
[/TABLE]

## 18. Validation and Test Plan
### 18.1 Reference corpus
- 2-person clean phone call, 10 minutes. 
- 2-person clean phone call, 60 minutes. 
- 2-person noisy call, 60 minutes. 
- 4-person meeting, 30–60 minutes. 
- English recording. 
- Hebrew recording. 
- English/Hebrew code-switching recording. 
- Stereo recording with local/remote channels separated. 
- Recording with overlapping speech. 
- Recording with long silence. 
- {+HiDock +}{+.hda+}{+ source, headerless variant+}{+: the actual production ingest path (§5.5).+} 
- {+HiDock +}{+.hda+}{+ source, RIFF/WAV variant+}{+: confirms the probe order does not misclassify.+} 
- {+Truncated / corrupt file+}{+: confirms rejection happens before inference.+} 
{+Each recording needs a reference transcript with speaker attribution, not just text, or §12.2's cpWER/WDER cannot be computed. Producing these annotations is a Phase 0 deliverable and is the schedule risk in this plan that is easiest to underestimate.+}
### 18.2 Required tests
- Unit tests for timestamp overlap and word-to-speaker assignment. {+Including boundary jitter: perturb ASR word timings by ±300 ms and assert attribution is stable (§8).+} 
- Unit tests for turn smoothing and UNKNOWN handling. 
- {+Unit tests for overlapped-region flagging and speaker-ID exclusion (§8.2).+} 
- Golden-file tests for JSON and subtitle exporters. {+Including a code-switched RTL/LTR sample per format (§15.4).+} 
- Interruption test: background/terminate during ASR and resume. {+Also terminate mid-checkpoint-write and assert no truncated checkpoint is trusted on resume (§10.1).+} 
- Memory-pressure test on the full 60-minute corpus. 
- Thermal soak test while unplugged and while charging. 
- Speaker-identification calibration with positive and negative speaker pairs. 
- {+Accuracy harness+}{+ computing WER, DER, cpWER, and WDER against the annotated corpus, run per engine and per model revision, with results checked in so regressions are visible in review (§12.2).+} 
- {+Hallucination test+}{+ on the long-silence recording: assert zero emitted words in VAD-silent regions, and assert the noisy call loses no real speech to the same thresholds (§6.4).+} 
- {+Transcript scroll/playback performance test+}{+ on the 60-minute corpus (§15.2).+} 
- {+Asset integrity test+}{+: corrupt a model file and assert a loud failure, not a degraded run (§13.3).+} 
- {-Privacy test verifying no network requests occur during a complete offline job.-} {+Structural offline assertion+}{+, not a manual observation: a build-time check that the strict-local target links no networking symbol path the app itself calls, plus a runtime test that asserts zero app-initiated requests across a complete job with assets already present. Both run in CI so the property cannot silently regress; this is the app's strongest privacy claim and the only one a user cannot verify themselves.+} 
⟨R-17⟩ A privacy property observed once by hand is a property that regresses on a Tuesday.

## 19. Implementation Roadmap
[TABLE]
| Phase | Deliverable |
| {+Phase 0, engine and asset spike+}{+ +}{+[NEW]+} | {+On a physical iPhone 16 Pro Max: Apple +}{+SpeechTranscriber+}{+ vs. WhisperKit turbo on the English and Hebrew recordings: WER, wall clock, peak memory, thermal. Confirm/deny Hebrew coverage. Annotate the reference corpus for attribution. Resolve §4.3 licensing and choose the §13.3 delivery strategy. +}{+Exit criterion:+}{+ §4.1, §6.1, and §13.3 are settled by measurement.+} |
| Phase 1, import + ASR | Document picker/share sheet; {+.hda+}{+ format adapter (§5.5);+} copy source; {-WhisperKit-} {+selected-engine+} incremental transcription; JSON + TXT output. {+Hallucination mitigations (§6.4).+} |
| Phase 2, Community-1 | Add SpeakerKit; known 2-speaker mode; speaker-labelled turns. {+Merge with tolerance and overlap flagging (§8, §8.2); cpWER/WDER harness online (§12.2).+} |
| Phase 3, persistence | Durable job state machine; checkpoints; resume after termination. {+Retention policy (§13.4).+} |
| Phase 4, TitaNet identity | Enroll "Me"; known-self matching {+with a score margin+}; conservative UNKNOWN behavior. |
| Phase 5, background execution | BGContinuedProcessingTask; progress reporting; interruption tests. |
| Phase 6, review UX | Audio playback synced to transcript {+(virtualized, §15.2)+}; rename speaker; export Markdown/SRT/VTT {+with bidi handling (§15.4)+}. |
| Phase 7, hardening | Thermal/memory tuning; model version pinning; strict-local build; privacy audit {+enforced in CI (§18.2)+}. |
[/TABLE]
⟨R-20⟩ Phase 0 is days of work against a seven-phase plan, and it decides the three most expensive commitments in the document. Every phase after it is cheaper for having run it.

## 20. Final Recommendation
{-Build v1 around WhisperKit + SpeakerKit, not a port of the desktop Python stack. On the iPhone 16 Pro Max, use the compressed large-v3 Turbo WhisperKit model with incremental loading, run Community-1 through SpeakerKit after ASR, then merge word timestamps with speaker intervals.-}
{+Build v1 around a Swift-native, Core ML pipeline, not a port of the desktop Python stack. That part of v1.0 is right and unchanged.+}
{+Choose the ASR engine by measurement, not by default. Apple's on-device +}{+SpeechTranscriber+}{+ costs nothing in app size and little in thermal budget; WhisperKit large-v3 Turbo covers Hebrew, which this product requires. The most likely shipping answer is both, routed per language behind +}{+SpeechTranscribing+}{+, but Phase 0 decides that, and it also decides the ~700 MB delivery problem that v1.0 never designed (§13.3).+}
{+Run Community-1 through SpeakerKit after ASR, sequentially, and merge with an explicit boundary tolerance rather than exact-interval arithmetic: both inputs to the merge are approximate, and the merge is the component the user actually reads. Gate it on cpWER/WDER, not on WER and DER alone.+}
Add TitaNet only as an optional, conservative identity layer. Run stages sequentially until profiling proves parallel Core ML execution is safe. Treat background execution as interruptible and persist every expensive result.
Best first milestone: Import a 60-minute two-person recording {+from the actual HiDock +}{+.hda+}{+ source+}, process it entirely on the iPhone, obtain "Me / Speaker 2" transcript turns, survive an app interruption, and export transcript.json + transcript.md without any cloud request.

## References
- Apple, iPhone 16 Pro Max Technical Specifications: https://support.apple.com/en-us/121032 (A18 Pro CPU/GPU/Neural Engine and storage capacities. 
- Apple Developer, BGContinuedProcessingTask: https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask (iOS 26 continued user-initiated processing). 
- Apple Developer, performing long-running tasks on iOS and iPadOS: https://developer.apple.com/documentation/BackgroundTasks/performing-long-running-tasks-on-ios-and-ipados (background processing guidance). 
- Apple Developer, Background GPU Access entitlement: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.background-tasks.continued-processing.gpu (GPU access for continued-processing tasks where supported). 
- Argmax OSS Swift, WhisperKit and SpeakerKit: https://github.com/argmaxinc/argmax-oss-swift (WhisperKit ASR; incremental audio loading; recommended iOS model; SpeakerKit Community-1 Core ML diarization. 
- sherpa-onnx, iOS / speaker identification / NeMo models: https://k2-fsa.github.io/sherpa/onnx/ (iOS support, speaker identification, and TitaNet ONNX model support). 
- {+Apple Developer, +}{+SpeechAnalyzer+}{+ / +}{+SpeechTranscriber+}{+ (iOS 26): Speech framework documentation: on-device transcription, supported locales, asset lifecycle. +}{+Required reading before Phase 0 (§4.2).+} 
- {+Apple Developer, On-Demand Resources and app size limits: inputs to the §13.3 delivery decision.+} 
- {+License sources for each dependency in §4.3, to be filled in with specific URLs and license identifiers once verified.+} 
- {+tools/hda2mp3.sh+}{+ in this workspace: reference implementation of the +}{+.hda+}{+ probe/fallback ordering ported in §5.5.+} 

Design note. Performance figures in Section 12 are engineering acceptance targets, not published benchmarks. They must be validated on the target iPhone 16 Pro Max build and model revisions.
{+Revision note (v1.1).+}{+ This revision changes no core architectural decision from v1.0: staged pipeline, sequential execution, checkpoint-per-stage, diarization separated from identity, and protocol boundaries all stand. It closes omissions: an unevaluated alternative engine, an undesigned 700 MB delivery path, an unmeasured merge stage, an unsupported source format, and an unhandled overlapped-speech case that the test plan already required. Items marked +}{+[VERIFY]+}{+ are unresolved and must not be treated as settled facts.+}