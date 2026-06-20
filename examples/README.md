# Aural recipes

Small, copy-and-adapt `zsh` scripts that wrap the `aural` binary for common
workflows. They are **examples, not an installed part of Aural** — read one,
tweak it to taste, and drop it somewhere on your `PATH`.

| Script | What it does |
| --- | --- |
| [`aural-meeting`](aural-meeting) | Record a meeting (system + mic) interactively, then summarize the transcript with fabric-ai. |
| [`aural-note`](aural-note) | Quick spoken voice memo → timestamped audio + transcript. |
| [`aural-dictate`](aural-dictate) | Speak for a few seconds → text on your clipboard. |

## Install

```sh
# Make them executable and put them on your PATH (adjust the target dir):
chmod +x examples/aural-*
mkdir -p ~/.local/bin
cp examples/aural-meeting examples/aural-note examples/aural-dictate ~/.local/bin/
# ensure ~/.local/bin is on PATH (e.g. in ~/.zshrc):
#   export PATH="$HOME/.local/bin:$PATH"
```

Then:

```sh
aural-meeting "Team Sync"
aural-note "idea about the parser"
aural-dictate 15
```

## Prerequisites

- **`aural`** — built from this repo (`make build`) or installed on your `PATH`.
- **A transcription model** — the default `whisper` engine needs a local
  whisper.cpp model (`aural models download base.en`). Override per the usual
  `--engine`/`$AURAL_ENGINE` / `aural config`.
- **`fabric-ai`** — only for `aural-meeting`'s summary step
  (<https://github.com/danielmiessler/fabric>), with a configured model.
- **macOS permissions** — microphone for all of them; the **System Audio
  Recording** permission for `aural-meeting` (it uses `--system`). See
  [`docs/permissions.md`](../docs/permissions.md).
- Acoustic speaker diarization (the `Speaker N` labels in `aural-meeting`) needs
  Apple Silicon; on Intel it falls back to deterministic You/Others attribution.

## Customizing

Each script reads a few environment variables (documented in its header
comment) — output directory, fabric pattern/model, capture length. For example:

```sh
AURAL_MEETINGS_DIR=~/Meetings FABRIC_PATTERN=extract_recommendations \
  aural-meeting "1:1 with Sam"
```

Because `aural` itself honors `$AURAL_*` and `aural config`, you can set the
engine, model, language, and more globally without touching the scripts.
