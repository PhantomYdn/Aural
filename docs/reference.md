# Reference

The complete flag, environment, and configuration reference. For the guided
tour, start with the [README](../README.md); this page is the exhaustive
lookup. Run `hark --help` for the canonical list and `hark help <subcommand>`
for a subcommand's options.

## The model

`hark` takes **one input** and writes the **outputs you name**. Naming no
output transcribes to stdout (the default verb).

## Input — pick one

Default: the system default microphone.

| Flag | Source |
|------|--------|
| *(none)* | live capture from the default input device |
| `-d, --device UID` | live capture from a specific input device (`hark devices`) |
| `--system` | all system audio via a process tap |
| `--app ID` | a specific app (bundle ID or PID; repeatable) |
| `--exclude-app ID` | all system audio except the listed app(s) (repeatable) |
| `--mix` | additionally mix the microphone into a system/app capture |
| `--capture-backend auto\|sckit\|coreaudio` | system/app capture backend (default `auto`; or `$HARK_CAPTURE`) |
| `-i, --input PATH\|-` | read an existing file, or `-` for stdin (no live capture) |

## Output — name what to keep

`-` means stdout; at most one output may be `-`.

| Flag | Output |
|------|--------|
| `-a, --audio PATH\|-` | audio file (`.wav`/`.m4a`/`.flac`/`.mp3`/`.opus`), or `-` for a WAV stream |
| `-t, --transcript PATH\|-` | transcript (`.txt`/`.srt`/`.json`), or `-` for text |
| *(none)* | transcribe to stdout (the default verb) |
| `--raw` | with `-a -`, stream headerless PCM instead of WAV |

## Capture / timing

`-r/--rate`, `-b/--bits` (16/24/32), `-c/--channels` (1/2), `--duration SEC`,
`--split duration=SEC` / `--split silence=SEC` (with `--silence-threshold dBFS`),
`--keep-awake` to stop the system sleeping mid-recording (also the display in
`--interactive`; off by default, or `$HARK_KEEP_AWAKE` / config `keep-awake`).

## Interruptions

Capture auto-recovers from a screen lock, display/system sleep, or device
change — the stream is restarted and recording resumes (tunable via
`$HARK_STALL_SECONDS`, `$HARK_RECOVER_TIMEOUT`; disable with `$HARK_NO_RECOVER`).
Pair with `--keep-awake` to avoid idle sleep entirely.

## Working directory

`-C, --directory PATH` resolves **relative** artifact paths (`-i`, `-a`, `-t`,
and `--split` outputs) against `PATH` (absolute paths and `-` are unaffected).
Defaults to the current directory; also `$HARK_DIRECTORY` or config `directory`.
The directory must already exist.

## Transcription

`-e/--engine`, `--model` (engine-specific — see
[Models](../README.md#models)), `--language` (`auto`, or a code; support varies
by engine), `--translate` / `--no-translate`,
`--transcript-format txt|srt|json`.

### Quiet captures

Live transcription covers the whole timeline — an on-device VAD (Apple Silicon)
only picks clean cut points, and speech the VAD doesn't flag (quiet or
overlapping, e.g. remote participants over a room mic) is still transcribed
rather than dropped; only true silence is skipped. `--vad-threshold` (0–1,
default `0.5`) tunes where turns are cut. Segments are also peak-normalized
before the engine to improve recognition of low-level audio (the recording is
unaffected; disable with `HARK_GAIN=off`).

## Speaker labels

| Flag | Meaning |
|------|---------|
| `--speakers`, `--diarize` | enable speaker labels (off by default) |
| `--speaker-mode auto\|source\|acoustic` | `auto` (default): source + diarization; `source`: You/Others only; `acoustic`: diarize one stream |
| `--diarize-engine auto\|streaming\|offline` | `auto` (default): streaming live / offline batch; `streaming`: real-time; `offline`: accurate, diarized at end of capture |
| `--max-speakers N` | cap the number of distinct speakers |
| `--speaker-threshold 0..1` | clustering sensitivity (default ~0.7; lower splits more, higher merges) |
| `--speaker-labels "You,Others"` | rename the source labels |

## Configuration & environment

Most defaults resolve **flag › environment (`$HARK_*`) › config
(`~/.hark/config.json`) › built-in**.

Every setting has a flag, a `$HARK_*` env var, and a config key. The env var is
`HARK_<KEY>` (uppercased, `-`→`_`) except `model` (`$HARK_WHISPER_MODEL`) and
`capture-backend` (`$HARK_CAPTURE`).

| Config key | Flag | Default |
|------------|------|---------|
| `engine` | `-e/--engine` | `whisper` |
| `model` | `--model` | (required for whisper) |
| `language` | `--language` | `auto` |
| `translate` | `--translate`/`--no-translate` | `false` |
| `device` | `-d/--device` | system default |
| `directory` | `-C/--directory` | current directory |
| `capture-backend` | `--capture-backend` | `auto` |
| `rate` / `bits` / `channels` | `-r` / `-b` / `-c` | live `44100`/`16`; convert = source |
| `keep-awake` | `--keep-awake`/`--no-keep-awake` | `false` |
| `silence-threshold` | `--silence-threshold` | `-50` |
| `vad` | `--vad`/`--no-vad` | `true` |
| `vad-threshold` | `--vad-threshold` | `0.5` |
| `gain` | `--gain`/`--no-gain` | `true` |
| `speakers` | `--speakers`/`--no-speakers` | `false` |
| `speaker-mode` | `--speaker-mode` | `auto` |
| `speaker-labels` | `--speaker-labels` | `You,Others` |
| `diarize-engine` | `--diarize-engine` | `auto` |
| `max-speakers` | `--max-speakers` | (unset) |
| `speaker-threshold` | `--speaker-threshold` | (engine default) |

```sh
hark config set engine apple
hark config set silence-threshold -40   # values starting with '-' are taken verbatim
hark config set speaker-mode source
hark config show                        # every setting, its value, and its SOURCE
```

`hark config show` lists **all** settings with their effective value and a
`SOURCE` column — `default` (built-in), `config` (set in the file), or `env`
(an `$HARK_*` override, which outranks config). `--json` emits
`{ "<key>": { "value": …, "source": … } }`.

The config file is plain JSON and hand-editable; `hark config path` prints its
location.

## Subcommands

```sh
hark devices [--list-inputs|--list-outputs] [--json]   # enumerate audio devices
hark apps [--json]                                     # list capturable applications
hark info <file> [--json]                              # duration/format/metadata
hark models list [--available] [--json]                # local or downloadable models
hark models download <name> [--default] [--force]      # fetch a ggml model
hark config show|set <key> <value>|unset <key>|path    # persisted defaults
```

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
