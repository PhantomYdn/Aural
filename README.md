# aural

Capture audio and produce transcripts on macOS, from a single native Swift
binary. `aural` is the verb — "listen and transcribe": it takes one input
(your microphone by default, or system/per-app audio, or an existing file) and
writes the outputs you name (an audio file, a transcript, or a stream on
stdout). It is built for Unix-style pipelines and unattended use.

> Status: pre-1.0 beta. Core capture, transcoding, and transcription work;
> packaging (signing, Homebrew) is in progress. See [PLAN.md](PLAN.md).

## Features

- **Capture** the microphone, **all system audio** (`--system`), **specific
  apps** (`--app`), or **everything except** some apps (`--exclude-app`) via
  Core Audio process taps — and optionally **mix in the mic** (`--mix`).
- **Transcribe** with a selectable engine: `whisper` (local whisper.cpp,
  multilingual + translate) or `apple` (native on-device Speech.framework, no
  dependencies). Near-runtime live transcription segments the stream and emits
  text as you speak.
- **Formats**: write `.wav`, `.m4a`, `.flac` audio and `.txt`, `.srt`, `.json`
  transcripts; **transcode** between formats (`aural -i in -a out`); **split**
  into chunks by duration or silence.
- **Streaming**: `-a -` writes a WAV (or raw PCM) stream to stdout; transcripts
  go to stdout by default — both compose with `ffmpeg`, `sox`, and friends.
- **Config & environment**: persistent defaults in `~/.aural/config.json` plus
  `$AURAL_*` overrides.

## Requirements

- macOS 14.4 or later (Core Audio process-tap API). Apple Silicon and Intel.
- For the `whisper` engine: a whisper.cpp binary on `PATH`
  (`brew install whisper-cpp`) and a ggml model.
- For the `apple` engine: the Speech Recognition permission (granted on first
  use). No model download.

## Install

Build from source with the Swift toolchain (Swift 6 / Xcode 16):

```sh
git clone <this-repo> aural && cd aural
make build                      # or: swift build -c release
cp .build/release/aural /usr/local/bin/aural
```

A signed, notarized release and a Homebrew formula are planned (see PLAN.md
Phase 5). Until then the binary is unsigned, so macOS attributes its
microphone / system-audio / speech permissions to the **terminal** that runs
it — see [Permissions](#permissions).

Install a transcription engine and model:

```sh
brew install whisper-cpp                 # the default 'whisper' engine
aural models download base.en --default  # fetch a model and make it the default
```

## Quick start

```sh
aural                                  # live mic -> transcript on stdout (Ctrl+C to stop)
aural -i recording.m4a                 # transcribe a file -> stdout
aural -a rec.m4a                       # record only (no transcript)
aural -a rec.m4a -t notes.txt          # record + transcribe to files
aural --system --mix -a mtg.m4a -t mtg.srt   # capture a meeting, keep audio + subtitles
aural -i in.wav -a out.flac            # transcode between formats
aural --engine apple                   # transcribe live with on-device Apple speech
```

## Usage

`aural` takes **one input** and writes the **outputs you name**; naming no
output transcribes to stdout.

**Input — pick one** (default: system default microphone):

| Flag | Source |
|------|--------|
| *(none)* | live capture from the default input device |
| `-d, --device UID` | live capture from a specific input device (`aural devices`) |
| `--system` | all system audio via a process tap |
| `--app ID` | a specific app (bundle ID or PID; repeatable) |
| `--exclude-app ID` | all system audio except the listed app(s) (repeatable) |
| `--mix` | additionally mix the microphone into a system/app capture |
| `-i, --input PATH\|-` | read an existing file, or `-` for stdin (no live capture) |

**Output — name what to keep; `-` means stdout** (at most one output may be `-`):

| Flag | Output |
|------|--------|
| `-a, --audio PATH\|-` | audio file (`.wav`/`.m4a`/`.flac`), or `-` for a WAV stream |
| `-t, --transcript PATH\|-` | transcript (`.txt`/`.srt`/`.json`), or `-` for text |
| *(none)* | transcribe to stdout (the default verb) |
| `--raw` | with `-a -`, stream headerless PCM instead of WAV |

**Capture / timing**: `-r/--rate`, `-b/--bits` (16/24/32), `-c/--channels`
(1/2), `--duration SEC`, `--split duration=SEC` / `--split silence=SEC`
(with `--silence-threshold dBFS`).

**Transcription**: `-e/--engine`, `--model`, `--language` (`auto` to detect),
`--translate` / `--no-translate`, `--transcript-format txt|srt|json`.

Run `aural --help` for the full list, and `aural help <subcommand>` for a
subcommand's options.

### Subcommands

```sh
aural devices [--list-inputs|--list-outputs] [--json]   # enumerate audio devices
aural apps [--json]                                     # list capturable applications
aural info <file> [--json]                              # duration/format/metadata
aural models list [--available] [--json]                # local or downloadable models
aural models download <name> [--default] [--force]      # fetch a ggml model
aural config show|set <key> <value>|unset <key>|path    # persisted defaults
```

## Transcription engines

Select with `-e/--engine` (default `whisper`). All engines accept any readable
input; it is normalized to 16 kHz mono internally.

| Engine | Runtime | Languages | Auto-detect | Translate→EN | Notes |
|--------|---------|-----------|-------------|--------------|-------|
| `whisper` (default) | whisper.cpp binary (`whisper-cli`/`whisper-server`) | ~99 | yes (`--language auto`) | yes | needs a non-`.en` model for non-English |
| `apple` | native `Speech.framework` (no deps) | ~50 locales | no (uses the locale) | no | on-device; plain-text only in batch |
| `whisperkit` | WhisperKit CoreML | ~99 | yes | yes | Apple-Silicon-first; models auto-download |
| `parakeet` | FluidAudio CoreML | 25 European (v3) / English (v2) | yes | no | Apple-Silicon-first; `--model v2`/`v3` |
| `cloud` | post-MVP | — | — | — | — |

- `whisper` is found on `PATH` (`whisper-cli`/`whisper-cpp`, and
  `whisper-server` for resident live transcription) or via `$AURAL_WHISPER_BIN`
  / `$AURAL_WHISPER_SERVER_BIN`. Disable the server with `$AURAL_WHISPER_SERVER=0`.
- `apple` needs the Speech Recognition permission and runs entirely on-device
  (no network). Batch transcription writes plain text; for `.srt`/`.json` from a
  file, use another engine. Live `.srt`/`.json` works with any engine.
- `whisperkit` and `parakeet` are CoreML engines (Apple Silicon only). They
  download their models from Hugging Face on first use, then run fully
  on-device. `parakeet` auto-detects its language (`--language` is ignored) and
  cannot translate.

## Models

Whisper ggml models live in `~/.aural/models` as `ggml-<name>.bin`.

```sh
aural models list --available        # catalog you can download
aural models download large-v3-turbo # fetch one (the only command that hits the network)
aural models list                    # what's installed; the active default is marked *
```

The first model you download becomes the default; set it explicitly with
`--default` or `aural config set model <name>`.

## Configuration & environment

Most defaults resolve **flag › environment (`$AURAL_*`) › config
(`~/.aural/config.json`) › built-in**:

| Setting | Flag | Env var | Config key | Default |
|---------|------|---------|------------|---------|
| model | `--model` | `$AURAL_WHISPER_MODEL` | `model` | (required for whisper) |
| engine | `-e/--engine` | `$AURAL_ENGINE` | `engine` | `whisper` |
| language | `--language` | `$AURAL_LANGUAGE` | `language` | `auto` |
| translate | `--translate`/`--no-translate` | `$AURAL_TRANSLATE` | `translate` | `false` |
| silence threshold | `--silence-threshold` | `$AURAL_SILENCE_THRESHOLD` | `silence-threshold` | `-50` |
| input device | `-d/--device` | `$AURAL_DEVICE` | `device` | system default |

```sh
aural config set engine apple
aural config set silence-threshold -40   # values starting with '-' are taken verbatim
aural config show
```

The config file is plain JSON and hand-editable; `aural config path` prints its
location.

## Permissions

macOS gates microphone, system-audio, and speech recognition behind TCC. For an
unsigned build these prompts are attributed to the **terminal** that launches
`aural`. See [docs/permissions.md](docs/permissions.md) for the exact
System Settings paths, the system-audio "+" flow, and notes for tmux/screen.

## Pipelines

```sh
# Stream live WAV into ffmpeg
aural -a - --duration 10 | ffmpeg -i - out.mp3

# Record on one machine, transcribe on another
aural -a - | aural -i -

# Follow a live transcript as it is written
aural -t notes.txt --system & tail -f notes.txt
```

`aural` follows POSIX conventions: audio/transcripts on stdout, diagnostics on
stderr (`-v` for detail), and a non-zero engine exit code propagates through the
pipeline. SIGINT/SIGTERM finalize the current file so it stays playable.

## Exit codes

Following BSD `sysexits(3)` where applicable:

| Code | Meaning |
|------|---------|
| 0 | success |
| 1 | generic failure |
| 64 | usage / invalid arguments |
| 66 | input file or device not found |
| 69 | feature/engine unavailable or not implemented |
| 70 | internal error |
| 74 | I/O error |
| 77 | permission denied (microphone / system audio / speech) |

## Development

```sh
make build      # swift build
make test       # swift test (with a CLT Testing.framework path workaround)
make release    # swift build -c release
```

Modular SwiftPM targets: `DeviceManager`, `TapEngine`, `Encoders`, `CLI`. Many
integration tests are gated on optional tools (whisper.cpp, a model, `say`,
Speech authorization) and skip cleanly when absent.

## Project documents

- [PRD.md](PRD.md) — product requirements
- [PLAN.md](PLAN.md) — phased implementation plan and status
- [docs/permissions.md](docs/permissions.md) — TCC permission setup
