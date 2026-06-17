# Product Requirements Document (PRD)

## Product: Aural
**Version:** 1.0 (MVP)
**Date:** 2026-06-12
**Author:** TBD

---

## 1. Overview

Aural is a native macOS command-line utility, shipped as a single Swift binary, that captures audio from physical input sources (microphones) and from the system itself — all system audio or the output of specific applications — using Core Audio process taps (macOS 14.4+) or ScreenCaptureKit (macOS 15+), selectable per the environment. No third-party virtual audio driver (e.g., BlackHole) is required. Recordings are saved locally and serve as the foundation for downstream audio processing workflows, most notably automatic speech-to-text transcription.

The tool strictly follows Unix/Linux design patterns, treating audio as a stream that can be manipulated, piped, and extended by other command-line programs. The primary goal is to provide a simple, scriptable, and composable replacement for GUI-based audio recording, enabling users to automate meeting recordings, create transcription pipelines, or build custom audio-processing chains without leaving the terminal.

---

## 2. Objectives & Success Criteria

| Objective | Success Criteria |
|-----------|------------------|
| Enable reliable capture of both microphone and system/app audio (e.g., Zoom, Teams) on macOS without third-party drivers | Users can record their voice and the counterparty's audio simultaneously with < 200 ms latency drift, measured as offset between mic and system tracks over a 60-minute dual-source recording |
| Provide a Unix-compatible interface that integrates with standard pipes, redirections, and signal handling | All audio data can be streamed via stdout; the CLI responds to SIGINT/SIGTERM by gracefully closing the output file |
| Simplify the transcription pipeline | Output files (WAV, M4A, FLAC, MP3, Opus) can be directly fed to `whisper.cpp`, Fabric AI, or cloud-based transcription services without extra conversion |
| Minimise dependencies and footprint | The tool is shipped as a single Swift binary requiring only macOS baseline frameworks (CoreAudio, AudioToolbox, AVFoundation); no third-party audio driver installation |
| Follow the "do one thing well" philosophy | The root verb captures/transcribes/transcodes via composable flags; small utility subcommands inspect the environment (list devices, list apps, file info); complex workflows are built by chaining invocations through stdin/stdout |

---

## 3. Target Audience

- **Software developers** who want to automate meeting recordings or build audio-enabled scripts.
- **Data scientists / ML engineers** who need a reliable way to collect audio corpora and pipe them into transcription models.
- **Power users & system administrators** comfortable with the terminal who require a lightweight, scriptable recording tool.
- **Open-source contributors** who can extend the tool by adding new output formats or post-processing hooks.

---

## 4. Features

### 4.1 MVP Features (v1.0)

| # | Feature | Priority | Description |
|---|---------|----------|-------------|
| 1 | Device & application enumeration | P0 | List all input/output audio devices (UID, name, channels, sample rates) and running applications capturable via process taps (name, bundle ID, PID). JSON output for scripting. |
| 2 | Audio capture from any single source | P0 | Record from a specified input device (built-in microphone, USB headset). Configurable sample rate, bit-depth, and channel count. Falls back to default input device. |
| 3 | System & per-app audio capture | P0 | Capture all system audio (`--system`), specific application(s) (`--app`, repeatable), or everything except listed apps (`--exclude-app`). Mixed mic + system capture via `--mix`. Two interchangeable backends — ScreenCaptureKit (macOS 15+, GUI session) and Core Audio process taps (macOS 14.4+, headless-capable) — selected with `--capture-backend` (default auto); see §6.2. |
| 4 | File output — native formats | P0 | Save to WAV (PCM), M4A/AAC, or FLAC using native CoreAudio encoders. |
| 5 | Stream-mode operation | P0 | Stream a WAV container to stdout with `-a -` (e.g., `aural -a - \| ffmpeg ...`), or headerless PCM with `--raw`; accept audio from stdin (`-i -`) for transcoding/transcription. |
| 6 | Signal handling & graceful shutdown | P0 | On SIGINT (Ctrl+C) or SIGTERM, finalise the output file header so it remains playable. |
| 7 | File output — additional formats | P1 | MP3 (vendored libmp3lame) and Ogg/Opus (native CoreAudio encoder + hand-written Ogg muxer, zero deps). All output formats verified compatible with major transcription tools (whisper.cpp, Fabric AI, cloud APIs). |
| 8 | Time-based chunking | P1 | Split recordings into sequential files by duration (`--split duration=SEC`). |
| 9 | Transcription integration | P1 | Transcription is built into the root verb: any input (live capture or `-i` file/stream) can be transcribed by a local engine (e.g., `whisper.cpp`) via `-t/--transcript`. Audio and transcript can be produced in the same run (`-a rec.m4a -t notes.srt`); naming no output transcribes to stdout. |
| 12 | Live transcription | P1 | During live capture, emit the transcript incrementally — as close to runtime as possible — by segmenting the stream on natural pauses and transcribing each segment as it completes (true streaming is post-MVP). |
| 13 | Multi-language & translation | P1 | Transcribe ~99 languages with a multilingual model via `--language CODE` or auto-detect (`--language auto`, default); `--translate` emits English from any spoken language (engines that support it). `aural models list/download` manages local models. |
| 14 | Pluggable transcription engines | P2 | Select the engine with `--engine`: `whisper` (whisper.cpp, default), `apple` (native Speech.framework, no extra deps), `whisperkit` (CoreML, on-device, multilingual + translate). Capabilities (auto-detect, translate, model semantics) vary and are validated. |
| 10 | Silence-based splitting | P2 | Split on continuous silence exceeding a configurable threshold (`--split silence=SEC`). |
| 11 | Basic metadata embedding | P2 | Store recording start time, source name, and sample rate in WAV INFO, MP4, or ID3 tags. |
| 15 | Speaker attribution by source (You vs Others) | P1 | When two sources are captured (`--mix`, or `--system`/`--app` + mic), keep the microphone and system audio as separate **internal** tracks and tag each transcript segment with its source ("You" = mic, "Others" = system). Deterministic and exact — no ML, no model download. This replaces the unreliable single-mixed-stream heuristic. |
| 16 | Acoustic speaker diarization | P1 | Separate anonymous speakers ("Speaker 1/2…") within a single stream using FluidAudio CoreML models (on-device, Apple Neural Engine). Offline mode (batch `-i`, most accurate) and streaming mode (live capture). |
| 17 | VAD-based live segmentation | P1 | Replace amplitude/silence-threshold segment cutting with Silero VAD (FluidAudio) for stable speech/pause boundaries at runtime; graceful fallback to the existing amplitude method when VAD models are unavailable. Feeds both transcription and the speaker pipeline. |
| 18 | Combined source-split + per-source diarization | P2 | Label You (mic) plus each distinct remote participant (diarize the system track) so multi-party calls resolve both sides at once. |
| 19 | Named speaker identification (enrolled voiceprints) | Post-MVP | Match voices to named people via stored speaker embeddings; enrollment + a local voiceprint store (FluidAudio embedding extraction). |

### 4.2 Post-MVP Features (Future)

- **Daemon/agent mode**: launchd-managed background service for scheduled and unattended recording, with IPC for client commands.
- **Silence-based voice activity detection** for trimming.
- **Real-time streaming** to a network socket or HTTP endpoint.
- **Multi-channel mapping** (e.g., separate tracks for mic and system audio).
- **Plugin system** to inject custom DSP filters (EQ, noise suppression) as middleware.
- **Configuration profiles** to store default sources, formats, and transcription settings.
- **Additional engines**: NVIDIA Parakeet (via FluidAudio CoreML); cloud backends (Deepgram, Google) selectable via `--engine`.
- **Named speaker identification**: voiceprint enrollment and a local speaker store, so diarized speakers resolve to named people across recordings (FluidAudio speaker embeddings).
- **Overlapping-speech handling**: per-word speaker assignment and crosstalk resolution when two speakers talk simultaneously.

---

## 5. User Stories

### US01 — Quick voice notes
As a **developer**, I want to quickly capture my microphone input for five minutes and save it to a file, so that I can review my spoken notes later without opening Audacity.
- Acceptance Criteria:
  - [ ] `aural -a notes.m4a --duration 300` records from the default input device without specifying a device UID (and writes no transcript, since only `-a` is named)
  - [ ] Recording stops automatically after 300 seconds with exit code 0
  - [ ] Resulting file plays correctly in QuickTime/`afplay` and duration is 300 s ± 1 s

### US02 — Record a meeting without echo
As a **developer**, I want to record the audio from an ongoing Zoom call without echoing my own voice, so that I can later transcribe the meeting and extract action items.
- Acceptance Criteria:
  - [ ] `aural apps` lists the running Zoom process with its bundle ID
  - [ ] `aural --app us.zoom.xos -a call.m4a` captures only Zoom's output audio
  - [ ] The user's own microphone is not captured unless `--mix` is explicitly given
  - [ ] First-run macOS "System Audio Recording" permission prompt and approval flow is documented

### US03 — Zero-touch transcription pipeline
As a **data engineer**, I want to capture audio and get a transcript with zero manual steps, so that I can build a fully automated transcription pipeline.
- Acceptance Criteria:
  - [ ] `aural --duration 60 -t -` captures from the default mic and produces transcript text on stdout in one step
  - [ ] The equivalent pipeline `aural -a - --duration 60 | aural -i -` produces the same transcript text on stdout
  - [ ] A failure in the transcription engine propagates a non-zero exit code through the pipeline

### US04 — Manageable chunks
As a **power user**, I want to split a long recording into chunks based on silence, so that I can easily manage large audio files and focus on important segments.
- Acceptance Criteria:
  - [ ] `aural --split silence=1.5 -a name.wav` produces sequentially numbered files (`name_001.wav`, `name_002.wav`, …)
  - [ ] Each chunk is independently playable with a valid, finalised header
  - [ ] The silence detection threshold (dBFS) is configurable

### US05 — Unattended compliance recording
As a **sysadmin**, I want to install the tool via Homebrew and have it run in a crontab, so that I can automatically record every team stand-up for compliance.
- Acceptance Criteria:
  - [ ] `brew install aural` installs a working, signed binary
  - [ ] Once the TCC permission is granted, recording runs unattended from cron/launchd without GUI interaction
  - [ ] Exit codes and stderr logging are suitable for cron-based monitoring and alerting

### US06 — Script-parseable enumeration
As an **ML researcher**, I want to list all available audio devices and capturable applications in a script-parseable format, so that I can write robust automation that adapts to different machine setups.
- Acceptance Criteria:
  - [ ] `aural devices --json` outputs valid JSON with UID, name, channel count, and sample rates
  - [ ] `aural apps --json` outputs valid JSON with name, bundle ID, and PID
  - [ ] Commands exit 0 with an empty array when nothing is found

### US07 — Focused app capture
As a **developer**, I want to capture audio from one specific app while excluding others, so that my recording contains no notification sounds or unrelated audio.
- Acceptance Criteria:
  - [ ] `--app` is repeatable to include multiple applications in one capture
  - [ ] `--exclude-app` captures all system audio except the listed applications
  - [ ] Notification sounds from excluded apps are absent from the resulting recording

### US08 — Know who said what
As a **developer**, I want my meeting transcript to label who said each line — me versus the call, and distinct remote speakers — so that I can produce accurate minutes and attribute action items.
- Acceptance Criteria:
  - [ ] `aural --system --mix --speakers -t mtg.srt` tags each cue with a speaker label (e.g. `You`, `Speaker 1`)
  - [ ] Lines spoken into my microphone are labeled distinctly from the call audio (deterministic source attribution, not a guess)
  - [ ] `aural --system --mix --speakers -t mtg.json` includes a `speaker` field on every segment
  - [ ] Diarization runs fully on-device; the first run may download CoreML models, after which it is offline
  - [ ] During live capture, speaker labels appear close to runtime (streaming), not only after the call ends

---

## 6. Functional Requirements

### 6.1 CLI Commands & Flags

`aural` itself is the verb — "listen and transcribe." It takes one input (live capture by default, or an existing file/stream via `-i`) and writes the outputs you name. Utility subcommands cover inspection and setup.

```
aural [INPUT] [OUTPUTS] [OPTIONS]        # capture / transcribe / convert
aural devices | apps | info              # inspection utilities
aural models | config                    # model + default management
```

**Input — pick one (default: system default microphone):**
- *(no flag)* : live capture from the default input device.
- `-d, --device UID` : live capture from a specific input device.
- `--system` : live capture of all system audio (via the selected capture backend, see §6.2).
- `--app ID` : live capture of a specific application (bundle ID or PID; repeatable).
- `--exclude-app ID` : live capture of all system audio except the listed application(s) (repeatable).
- `--mix` : additionally mix the microphone (default or `-d` device) into a system/app capture.
- `-i, --input PATH|"-"` : read an existing audio file, or `-` for stdin, instead of live capture. Mutually exclusive with the live flags above.

**Outputs — name what you want to keep; `-` means stdout:**
- `-a, --audio PATH|"-"` : write audio. The file extension picks the format (`.wav`, `.m4a`, `.flac`, `.mp3`, `.opus`); `-` streams a WAV container to stdout.
- `-t, --transcript PATH|"-"` : write a transcript. The file extension picks the format (`.txt`, `.srt`, `.json`); `-` writes text to stdout.
- *(no output flag)* : transcribe to stdout (the default verb).
- At most one output may be `-` — stdout carries a single stream.

**Capture format & timing (live capture):**
- `-r, --rate Hz` : sample rate (live default 44100; file convert defaults to the source rate).
- `-b, --bits 16|24|32` : bit depth (live default 16; convert defaults to the source depth).
- `-c, --channels 1|2` : channel count (default based on the source, capped at 2).
- `--duration SEC` : stop live capture after SEC seconds (otherwise Ctrl+C).
- `--split duration=SEC` / `--split silence=SEC` : split the audio file into sequentially numbered chunks (requires `-a FILE`; silence threshold via `--silence-threshold` dBFS).
- `--capture-backend auto|sckit|coreaudio` : system/app capture backend (default `auto`, or `$AURAL_CAPTURE`); see §6.2.

**Format overrides & transcription:**
- `--format wav|m4a|flac|mp3|opus` : force the audio format, overriding the extension.
- `--transcript-format txt|srt|json` : force the transcript format, overriding the extension.
- `-e, --engine whisper|apple|whisperkit` : recognition engine (default `whisper`; `cloud` is post-MVP). Capabilities vary — see §6.6.
- `--model NAME|PATH` : engine-specific model selector. `whisper`: ggml path or short name (`large-v3-turbo`); `whisperkit`: a WhisperKit model name (`large-v3-v20240930_626MB`); `apple`: ignored (OS assets). whisper precedence: `--model` › `$AURAL_WHISPER_MODEL` › config `model` (`aural config` / `~/.aural/config.json`).
- `--language CODE` : spoken language (e.g. `de`); `auto` (default) detects it where the engine supports detection.
- `--translate` : output English regardless of the spoken language (whisper/whisperkit only).
- `--raw` : with `-a -`, stream headerless raw PCM to stdout instead of a WAV container.

**Speaker recognition (diarization) — see §6.7:**
- `--speakers[=auto|source|acoustic]` (alias `--diarize`) : label transcript segments by speaker. `auto` (the value when the flag is given bare) attributes the microphone side by source ("You") and diarizes the system/single stream acoustically ("Speaker 1/2…"); `source` labels by capture source only (needs two sources); `acoustic` runs acoustic diarization only. Off by default.
- `--max-speakers N` : cap/hint for acoustic diarization (bounded by the diarizer model's capacity; see §6.7).
- `--speaker-threshold 0..1` : acoustic clustering sensitivity (default ~0.7; lower splits speakers more readily, higher merges them).
- `--diarize-engine auto|streaming|offline` : pick the diarizer (default `auto` → streaming for live capture, offline for `-i` files).
- `--speaker-labels "You,Others"` : rename the source-attribution labels (default `You,Others`).

**Examples:**
```
aural                                       # live mic, transcript -> stdout
aural -i recording.m4a                       # transcribe a file -> stdout
aural -a rec.m4a                             # record only (no transcription)
aural -a rec.m4a -t notes.txt                # record + transcribe to files
aural --system --mix -a mtg.m4a -t mtg.srt   # capture a meeting, keep both
aural -i in.wav -a out.m4a                   # convert between formats
aural -a - | ffmpeg -i - ...                 # stream WAV into a pipe
aural -i talk.mp3 --language auto -t talk.srt        # detect language -> subtitles
aural --system --engine whisperkit --translate -t -  # any language -> English, live
aural --system --mix --speakers -t mtg.srt           # meeting w/ speaker labels (You / Speaker N)
aural -i mtg.wav --speakers=acoustic -t mtg.json     # diarize a recording -> labeled JSON
```

**`aural devices`**
- `--list-inputs` / `--list-outputs`
- `--json` : output in JSON for scripting.

**`aural apps`**
- List running applications whose audio can be captured via process taps.
- Output: application name, bundle ID, PID.
- `--json` : output in JSON for scripting.

**`aural info <file>`**
- Print duration, sample rate, channels, and metadata of an audio file.
- `--json` : output in JSON for scripting.

**`aural models`**
- `list` : show installed models across engines (name, engine, size) and the active default (`*`).
- `list --available` : show the downloadable catalog across engines with an `ENGINE` column, language coverage, and installed/current status.
- `download <name>` : fetch a model. Names are engine-tagged: a bare ggml short name is a whisper model (`base.en`); CoreML engines use a prefix (`whisperkit:tiny`, `parakeet:v3`). whisper models land in `~/.aural/models`; whisperkit/parakeet delegate to their SDK caches. `--force` re-downloads. `--default` makes it the default: for whisper the first download is auto-adopted; for whisperkit/parakeet `--default` also sets `config.engine`.
- Applies to file-based engines (`whisper`, `whisperkit`, `parakeet`); `apple` uses OS-managed assets.
- `--json` on `list` for scripting.

**`aural config`** — persisted defaults in `~/.aural/config.json` (JSON; user-editable, kebab-case keys).
- `show` (default; `--json`) / `set <key> <value>` / `unset <key>` / `path`.
- Keys: `model`, `engine`, `language`, `translate`, `silence-threshold`, `device`. Values are type-checked (`translate` boolean; `silence-threshold` negative number; `engine` a known engine); unknown keys are rejected. Values beginning with `-` are taken verbatim (e.g. `aural config set silence-threshold -40`).

**Defaults precedence (environment & configuration).** Each setting resolves in the order **flag › environment (`$AURAL_*`) › config (`aural config`) › built-in default**:

| Setting | Flag | Env var | Config key | Default |
|---------|------|---------|------------|---------|
| model | `--model` | `$AURAL_WHISPER_MODEL` | `model` | (required) |
| engine | `-e/--engine` | `$AURAL_ENGINE` | `engine` | `whisper` |
| language | `--language` | `$AURAL_LANGUAGE` | `language` | `auto` |
| translate | `--translate`/`--no-translate` | `$AURAL_TRANSLATE` | `translate` | `false` |
| silence threshold | `--silence-threshold` | `$AURAL_SILENCE_THRESHOLD` | `silence-threshold` | `-50` |
| input device | `-d/--device` | `$AURAL_DEVICE` | `device` | system default input |

Model values (flag/env/config) may each be a ggml path or a short name resolved under `~/.aural/models`. Malformed env values (non-boolean `$AURAL_TRANSLATE`, non-negative/non-numeric `$AURAL_SILENCE_THRESHOLD`) are reported as usage errors.

All invocations accept `-h, --help` and `-v, --verbose`.

> **Note on the root verb.** `aural` with no arguments starts live microphone capture and prints a transcript to stdout; full usage is available via `aural --help`. Naming no output transcribes to stdout, so the default behaviour matches the product's one-line description. Transcoding (`aural -i in -a out`) replaces the former `convert` subcommand, which has been removed.

### 6.2 Source Handling

- Use CoreAudio APIs to enumerate AudioDeviceIDs; automatically exclude inactive devices.
- **System/app capture uses one of two interchangeable backends** (both deliver the same packed-PCM stream); `--capture-backend auto|sckit|coreaudio` (default `auto`, or `$AURAL_CAPTURE`) selects:
  - **`sckit` — ScreenCaptureKit** (`SCStream`, macOS 15+): captures system/app audio and, for `--mix`, the microphone in the same synchronized stream. Audio is delivered continuously (silence when idle), so `--mix` keeps recording the microphone even when no system audio is playing. Requires the **Screen Recording** TCC permission and a graphical login session (it cannot run headless / over SSH / as a LaunchDaemon).
  - **`coreaudio` — Core Audio process taps** (`CATapDescription` / `AudioHardwareCreateProcessTap`, macOS 14.4+): no virtual audio driver. Uses a private aggregate device; for `--mix` the **microphone is the aggregate's clock master** so capture runs continuously regardless of system-audio activity. Requires the narrower **System Audio Recording** permission and **works headless** (cron/launchd/SSH).
  - **`auto`** prefers `sckit` when available (macOS 15+, a GUI session is present, and Screen Recording is granted) and otherwise falls back to `coreaudio`, printing a one-line notice on stderr. Headless and macOS 14.x always use `coreaudio`.
- Tap/stream lifecycle: created at capture start and torn down on stop; if a tapped application quits mid-capture, the capture finalises cleanly and reports it on stderr.
- Fallback to the default input device when no source flag is given.

### 6.3 Streaming & Pipes

- `-a -` streams a self-describing WAV container to stdout (unknown-length header); `--raw` switches it to headerless 16-bit PCM. The stream must play nicely with `ffmpeg`, `sox`, and other tools.
- `-i -` reads audio from stdin (a WAV stream is auto-detected; raw PCM is interpreted with `--input-rate/-bits/-channels`) for transcoding and/or transcription.
- Exactly one output may target stdout; the tool refuses combinations that would interleave two streams on stdout.
- Exit code 0 on success, non-zero on failure (explicit error codes documented).

### 6.4 Format Support

- Read: WAV, AIFF, CAF, M4A, FLAC.
- Write (P0): WAV (PCM), M4A/AAC, FLAC — native CoreAudio encoders.
- Write (P1): MP3 (vendored libmp3lame, encode-only — Sources/CLame, LGPL), Ogg/Opus (native `kAudioFormatOpus` encoder + hand-written Ogg muxer, zero external deps).
- All write formats must be accepted as-is by major transcription tools: `whisper.cpp`, Fabric AI, OpenAI/cloud transcription APIs.
- Metadata: WAV INFO chunk, MP4 metadata atoms for M4A, ID3v2 for MP3.

### 6.5 Chunking & Splitting

- Time-based: `--split duration=300` creates `meeting_001.wav`, `meeting_002.wav`, …
- Silence-based: `--split silence=1.5` triggers a new file after 1.5 seconds of continuous silence (configurable threshold).
- Both modes must flush the file header correctly and continue recording.

### 6.6 Transcription Integration

- Transcription is requested with `-t/--transcript` (or implied when no output flag is given). It applies uniformly to file input (`-i`), stdin (`-i -`), and live capture.
- Input is normalised internally to 16 kHz mono 16-bit WAV (the whisper.cpp requirement) before the engine runs; any readable input format is therefore accepted without prior conversion.
- For live capture, transcription should run as close to runtime as possible: the stream is segmented on natural pauses (with a maximum-window cap) and each segment is transcribed as it completes, appending to the destination. True streaming transcription is post-MVP; batch (transcribe-at-end) is the minimum acceptable behaviour for v1. **Segment boundaries are determined by voice-activity detection (VAD) when available** (Silero via FluidAudio — far more stable than a raw amplitude threshold), falling back to the `--silence-threshold` amplitude heuristic when VAD models are absent; see §6.7. When `--speakers` is active, the same segmentation feeds the speaker pipeline so each emitted segment carries a speaker label.
- When both `-a` and `-t` are given, audio and transcript are produced in the same capture pass.
- If `--engine whisper`, call a system-installed whisper.cpp binary (`whisper-cli`/`whisper-cpp` on `PATH`, or `$AURAL_WHISPER_BIN`); if not found, provide a clear error with installation instructions (e.g., `brew install whisper-cpp`). The model comes from `--model` or `$AURAL_WHISPER_MODEL`.
- Live transcription prefers a model-resident backend when `whisper-server` is available (`$AURAL_WHISPER_SERVER_BIN` to override the path): the server is launched once on loopback (127.0.0.1) so the model loads a single time, and each segment is transcribed via a local HTTP request to its `/inference` endpoint. This is local IPC with Aural's own child process — not an external network call. It is disabled with `AURAL_WHISPER_SERVER=0`, and Aural falls back to spawning `whisper-cli` per segment whenever the server is absent or fails to start, so transcription is never blocked by the optimization.
- STDERR from the transcription engine is passed through for debugging (suppressed for the high-volume per-segment live calls unless `-v`); a non-zero engine exit code propagates through the pipeline.
- Recognition uses a selectable engine (`--engine`, default `whisper`). All engines share one internal primitive — "transcribe a 16 kHz mono WAV (optionally translating) → text (+ optional timestamps)" — used by both batch and live paths.

| Engine | Runtime / deps | Languages | Auto-detect | Translate→EN | Model selection |
|--------|----------------|-----------|-------------|--------------|-----------------|
| `whisper` (default) | whisper.cpp CLI/server (external binary) | ~99 (multilingual model) | yes (`auto`) | yes | ggml path/short name; needs a non-`.en` model |
| `apple` | native `Speech.framework` (no deps) | ~50 locales | no (chosen/current locale) | no | OS-managed on-device assets |
| `whisperkit` | WhisperKit CoreML (SwiftPM dep) | ~99 | yes | yes | WhisperKit model name; auto-downloaded |
| `parakeet` | FluidAudio CoreML (SwiftPM dep) | 25 European (v3) / English (v2) | yes (auto) | no | `--model v2`/`v3`; auto-downloaded |

- An `.en` whisper model ignores `--language`; Aural warns when a non-English language is requested with such a model.
- `--translate` is rejected with a clear error on engines that don't support it (`apple`, `parakeet`).
- `apple` requires the macOS Speech Recognition TCC permission (docs/permissions.md) and on-device locale assets; it runs fully on-device (`requiresOnDeviceRecognition`, no network) and recognizes in one locale (`--language CODE` → locale, e.g. `de`→`de-DE`; `auto` uses the current locale). It produces plain text: batch (`-i`) rejects `--transcript-format srt|json` with a clear hint, while live `-t out.srt`/`.json` still works (timestamps come from Aural's segmenter).
- `whisperkit` and `parakeet` are Apple-Silicon-first (clear error on Intel) and load their CoreML model once, reused across live segments (model-resident, like the whisper-server backend). Both build `srt`/`json` from engine timings (whisperkit segments, parakeet token timings).
- `parakeet` auto-detects within its language set; a specific `--language` emits a notice and is ignored. `whisperkit` caches models under `~/.aural/models/whisperkit`; `parakeet` uses FluidAudio's managed cache (`~/Library/Application Support/FluidAudio/Models`). `aural models list` shows both.

### 6.7 Speaker Recognition & Diarization

Speaker labeling answers "who said what." It is **opt-in** via `--speakers`/`--diarize` (§6.1); without it, transcript output is unchanged. Two complementary mechanisms combine, because each is strong where the other is weak:

**a) Source attribution (deterministic, no ML).** When Aural already captures two distinct sources — `--mix`, or `--system`/`--app` with the microphone — the microphone (you) and the system audio (everyone on the call) are *inherently separate signals*. Today they are summed into one stream before transcription (`StreamMixer`/`StreamMixing`), which discards that separation and forces any "who spoke" decision onto an unreliable single-stream heuristic. Under `--speakers`, Aural **keeps the mic and system as separate internal tracks**, transcribes/segments each independently, and tags segments by origin: the mic side is labeled `You`, the system side `Others` (relabel with `--speaker-labels "You,Others"`). This is exact, cheap, headless-safe, and needs no model download. **The packaged audio output (`-a`) remains the mixed stream** by default; separate-track *audio* output is out of scope here (see §4.2 / Open Questions).

**b) Acoustic diarization (FluidAudio CoreML, on-device/ANE).** To resolve multiple distinct speakers *within* one stream — several remote participants on the system side, or a single-source/in-room recording — Aural uses FluidAudio's diarization models, reusing the dependency already linked for the `parakeet` engine (no new heavy dependency). Anonymous speakers are labeled `Speaker 1`, `Speaker 2`, …
  - **Offline mode** (default for `-i` file input, and for live capture with `--diarize-engine offline`): the most accurate pipeline (Pyannote Community-1 — segmentation + speaker embeddings + clustering). Runs over the whole recording; for live capture it records the stream(s) and diarizes at stop (transcript at end).
  - **Streaming mode** (default for live capture): real-time per-segment **speaker-embedding clustering** — each VAD segment is embedded (`extractSpeakerEmbedding`) and assigned to an existing or new cluster (`SpeakerManager`) → `Speaker N`. Reuses the live VAD segmentation; low-latency, incremental.
  - `--diarize-engine auto|streaming|offline` overrides the mode; `--max-speakers N` caps the count; `--speaker-threshold` tunes clustering sensitivity.

**c) Combined.** With `--speakers` (auto/acoustic) and two sources, Aural attributes the mic side as `You` (deterministic) and diarizes the system side, yielding `You` plus `Speaker 1/2…` for the remote participants in one transcript — live (streaming) or as an accurate offline pass at stop. `You` is a live-only label (a single mixed `-i` file can't separate your voice — everyone is `Speaker N`).

**Runtime segmentation (the "delay in a sound" fix).** Live segmentation no longer relies solely on an amplitude/silence threshold. On Apple Silicon, **FluidAudio VAD (Silero) drives the speech/pause boundaries by default** (a full streaming state machine with hysteresis and speech padding; and, in streaming diarization, speaker-change turns also cut segments). The Silero CoreML model is fetched on the first live run (then fully local) — the one network-using exception on the default live path, opt out with `AURAL_VAD=0`. The existing `--silence-threshold` amplitude method remains the graceful fallback on Intel or whenever the VAD model can't be loaded, so transcription is never blocked. This stabilizes both transcription boundaries and speaker turns at runtime.

**Output.** Speaker labels are carried in every transcript format:
  - `txt` : each line is prefixed `Speaker 1: …` / `You: …`.
  - `srt` : the speaker is prefixed in the cue text (`[Speaker 1] text`), keeping the file valid SRT.
  - `json` : every segment object gains a `"speaker"` field alongside `start`/`end`/`text`.

**Models & platform.**
  - Diarization/VAD CoreML models are managed through `aural models` (engine-tagged, e.g. `fluidaudio:diarizer`, `fluidaudio:vad`) and FluidAudio's own cache (`~/Library/Application Support/FluidAudio/Models`); `aural models list` shows them. They download from Hugging Face on first use (opt-in network, then fully local) — consistent with the `whisperkit`/`parakeet` engines and §7 Security & Privacy.
  - Acoustic diarization and VAD are **Apple-Silicon-first** (runtime-gated with a clear error on Intel, like `whisperkit`/`parakeet`). **Source attribution (a) has no such requirement** — it is pure stream routing and works everywhere `--mix` works, including headless. No new TCC permission is required (same captured audio).

---

## 7. Non-Functional Requirements

| Category | Requirement |
|----------|-------------|
| **Performance** | Recording must use < 3% CPU on an Apple Silicon Mac (16 kHz mono); buffering delays < 100 ms. Live diarization (streaming) must keep up with real time (RTF < 1) on Apple Silicon and emit speaker labels close to runtime — a tentative label within ~1 s and a finalized one within ~2 s of a turn. Offline (`-i`) diarization is bounded by file length, not interactive. Source attribution (§6.7a) adds negligible overhead. |
| **Reliability** | 24-hour continuous recording must produce a valid, non-corrupted file when terminated via SIGINT/SIGTERM. Resilience to hard kills (SIGKILL, power loss) is parked — see Open Questions. |
| **Usability** | CLI help and error messages are clear, include examples, and follow POSIX utility conventions. |
| **Compatibility** | macOS 14.4 (Sonoma) and later — required by the Core Audio process-tap API; both Intel and Apple Silicon. The ScreenCaptureKit capture backend additionally needs macOS 15+ and a graphical login session; on macOS 14.x or headless it falls back to the Core Audio tap (see §6.2). The `whisperkit` and `parakeet` engines, and **acoustic diarization / VAD (§6.7b)**, are Apple-Silicon-first (runtime-gated with a clear error on Intel); `whisper` and `apple` cover Intel. **Source attribution (§6.7a) is platform-agnostic** (pure stream routing) and works wherever `--mix` works, including headless. |
| **Security & Privacy** | No external network calls by default; cloud transcription backends are opt-in and use HTTPS with user-provided API keys. (Live transcription may run a local `whisper-server` bound to loopback 127.0.0.1 for performance — IPC with Aural's own child process, never an external connection; disable with `AURAL_WHISPER_SERVER=0`.) System/app audio capture requires a TCC permission that depends on the backend (§6.2): the Core Audio tap uses the narrower "System Audio Recording" permission (and works headless); the ScreenCaptureKit backend requires the broader "Screen Recording" permission and a GUI session. Both are terminal-attributed for unbundled CLIs and their approval flows are documented. The `apple` engine uses the Speech Recognition TCC permission; `whisperkit` and `parakeet` download CoreML models from Hugging Face on first use (model fetch only, then fully local). Speaker diarization/VAD (§6.7) likewise fetch FluidAudio CoreML models from Hugging Face on first use, then run fully on-device, and require **no additional TCC permission** (they operate on already-captured audio). Note: live VAD segmentation is on by default on Apple Silicon, so its Silero model is fetched on the first live run — a deliberate, documented exception to "no network by default", opt out with `AURAL_VAD=0`. |
| **Maintainability** | Single Swift binary built with SwiftPM; modular targets: `DeviceManager`, `TapEngine`, `Encoders`, `CLI`. Well-documented code. The CoreML engines add the `argmaxinc/argmax-oss-swift` (whisperkit) and `FluidInference/FluidAudio` (parakeet) SwiftPM dependencies, currently always linked (a lean/trait-gated build is a future option — they increase binary size). Speaker diarization and VAD (§6.7) reuse the already-linked `FluidInference/FluidAudio` dependency, so they add no new SwiftPM dependency (only additional model assets). |
| **Installability** | Distributed via Homebrew (`brew install aural`) and direct download from GitHub Releases; binary is signed and notarized so TCC permission flows work cleanly. |
| **Auditability** | All recorded file paths and durations are logged to STDERR when `-v` is enabled. |

---

## 8. Success Metrics (KPIs)

- **Adoption:** 1000 Homebrew installs within 3 months of public release.
- **Pipeline integration:** At least two open-source transcription projects (e.g., `whisper.cpp`, `faster-whisper`) officially list Aural as a recommended capture tool.
- **Reliability:** Crash-free session rate > 99.5%, measured via strictly opt-in telemetry (consistent with the "no network calls by default" security requirement; mechanism TBD — see Open Questions).
- **Community engagement:** Minimum 10 pull requests contributed from external developers within 6 months (discouraging feature bloat, but demonstrating extendability).
- **Source attribution accuracy:** ~100% — in a two-source capture, every segment is attributed to its true origin (mic vs system) because the routing is deterministic, not inferred.
- **Diarization quality:** Diarization Error Rate (DER) on a reference set (e.g. AMI-style meeting audio) within a documented target band for the chosen FluidAudio model; tracked offline so regressions are visible.
- **Runtime labeling latency:** ≥ 90% of live speaker labels finalized within ~2 s of the corresponding turn (per §7 Performance).
- **Segmentation stability:** VAD-based live segmentation produces measurably fewer spurious cuts than the amplitude-threshold method on a fixed test clip (the "delay in a sound" instability this feature targets).

---

## 9. Timeline & Milestones

| Milestone | Deliverables | Target | Dependencies |
|-----------|--------------|--------|--------------|
| **M1 – Core Capture** | Swift/SwiftPM project skeleton, device & app enumeration (`devices`, `apps`), mic recording to WAV, signal handling, stdout streaming | Week 1–2 | — |
| **M2 – System Audio** | Core Audio process taps: `--system`, `--app`, `--exclude-app`, `--mix`; TCC permission flow & docs | Week 3–4 | M1 |
| **M3 – Formats & Chunking** | M4A/FLAC output, MP3/Opus (static libs), time-based splitting, transcoding via `-i in -a out` | Week 5–6 | M1 |
| **M4 – Transcription MVP** | Root-verb transcription with local Whisper support; stdin/file/live input; combined `-a`+`-t` | Week 7 | M3 |
| **M5 – Polish & Release** | Code signing & notarization, Homebrew formula, man page, example scripts, CI/CD, public beta | Week 8–9 | M2, M3, M4 |
| **M6 – Engines & Languages** | Engine abstraction; multilingual + `--translate` + `--language auto` on whisper; `aural models`; `apple` (Speech.framework) and `whisperkit` (CoreML) engines | Post-M5 | M4 |
| **M7 – Speaker Recognition & Runtime Segmentation** | Source attribution (You/Others) via internal multi-track capture; acoustic diarization (FluidAudio, offline + streaming); VAD-based live segmentation; `--speakers`/`--diarize` flags; speaker labels in txt/srt/json; diarization/VAD models in `aural models` | Post-M6 | M4, M6 |
| **Post-MVP** | Daemon mode (launchd scheduled recording), streaming transcription, cloud backends, configuration profiles, named speaker identification (voiceprints), overlapping-speech handling | Ongoing | M5 |

---

## 10. Open Questions & Assumptions

1. **Crash resilience (parked):** How should recordings survive hard kills (SIGKILL, power loss)? Candidates: periodic header flush every N seconds, or a `aural repair` subcommand for truncated files. Decision deferred.
2. **Whisper bundling:** Will the tool bundle a transcription engine or expect the user to install it separately? (Assumption: no bundling to keep the binary small; document external dependencies.)
3. **Telemetry mechanism:** What opt-in mechanism (if any) will measure the crash-free-rate KPI without violating the no-network-by-default principle?
4. **TCC for unbundled CLI:** Confirm the exact permission-attribution behaviour for a signed standalone binary vs. terminal-attributed permission, and document the recommended setup.
5. **Named speaker identification (deferred):** How should enrolled voiceprints be stored and matched (local embedding store, privacy, cross-recording identity), and what CLI surface (`aural speakers enroll`?) does it need? Deferred to Post-MVP.
6. **Overlapping speech:** How are simultaneous speakers handled — drop to a single label, mark overlap, or attempt per-word assignment? Depends on the chosen FluidAudio diarizer's capabilities; deferred.
7. ~~**Diarization streaming model choice:** LS-EEND vs Sortformer~~ → **Resolved:** live streaming uses per-segment **speaker-embedding clustering** (FluidAudio `extractSpeakerEmbedding` + `SpeakerManager`), reusing the VAD segmentation rather than an end-to-end frame model — simpler and lower-risk. Tunable via `--speaker-threshold`/`--max-speakers`. (FluidAudio model-download footprint of always-linking the diarization assets is still open.)
8. **Separate-track audio output:** Whether to expose the internal mic/system separation as user-facing audio output (e.g. dual files or L/R channels), beyond its use for transcript attribution. Currently scoped out (see §4.2).

### Resolved (2026-06-12)
- ~~Language/stack~~ → **Swift**, single binary, SwiftPM modular targets.
- ~~System audio without a virtual device~~ → **Core Audio process taps** (macOS 14.4+); BlackHole no longer required.
- ~~Product/binary naming~~ → **aural**.

---

**Document Status:** Draft for review
**Next Steps:** Fill in Author field; review drafted acceptance criteria (US01–US07); decide crash-resilience strategy (Open Question 1).
