# macOS Permissions (TCC)

Aural needs two privacy permissions, both granted per-application by macOS
TCC. **For command-line tools, macOS attributes permissions to the terminal
application that launched them** (Terminal, iTerm2, kitty, an IDE, …), not
to `aural` itself — even though `aural` embeds its own usage descriptions.

## Microphone (live capture, `--mix`)

Service: `kTCCServiceMicrophone`.

The first microphone capture triggers the standard prompt, attributed to
your terminal. If it was denied, re-enable it under:

> System Settings → Privacy & Security → Microphone → *your terminal* → on

## System / app audio capture (`--system`, `--app`, `--exclude-app`)

System/app capture uses one of two backends (`--capture-backend`, default
`auto`), each with its own permission. `auto` prefers ScreenCaptureKit when it
is available (macOS 15+, a GUI session, and Screen Recording granted) and
otherwise falls back to the Core Audio tap, printing a notice.

### Core Audio tap — "System Audio Recording" (headless-capable)

Service: `kTCCServiceAudioCapture` ("System Audio Recording Only"). The narrower
permission; works headless (cron/launchd/SSH) and on macOS 14.4+.

**macOS does not show a prompt for terminal-attributed CLIs** — and a missing
permission does not produce an error: the process tap silently delivers
all-zero samples. Aural detects an entirely-silent system capture and warns:

1. Open **System Settings → Privacy & Security → Screen & System Audio
   Recording**
2. Find the **System Audio Recording Only** section
3. Click **+**, add your terminal application
4. **Restart the terminal** and retry

To verify the grant took effect:

```bash
sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
  "SELECT client, auth_value FROM access WHERE service='kTCCServiceAudioCapture';"
# auth_value 2 = allowed
```

### ScreenCaptureKit — "Screen Recording" (macOS 15+, GUI session only)

Service: `kTCCServiceScreenCapture`. The broader Screen Recording permission;
ScreenCaptureKit needs it for any capture, including audio-only, and only works
inside a graphical login session (not headless/SSH/LaunchDaemon).

> System Settings → Privacy & Security → Screen & System Audio Recording →
> *your terminal* → on, then restart the terminal.

Force the headless-capable Core Audio backend (skipping Screen Recording) with
`--capture-backend coreaudio` or `AURAL_CAPTURE=coreaudio`.

## Speech Recognition (`--engine apple`)

Service: `kTCCServiceSpeechRecognition`.

The `apple` engine uses macOS on-device speech recognition, which needs the
Speech Recognition permission — attributed to your terminal, like the mic:

> System Settings → Privacy & Security → Speech Recognition → *your terminal* → on

The first use triggers the prompt; on-device locale assets may download on
first use of a language. The `whisper` and `whisperkit` engines don't need
this permission.

## Multiplexers (tmux, screen)

Permission attribution resolves through tmux/screen to the terminal that
hosts them. Granting the permission to the terminal app is sufficient;
restarting the terminal does not kill detached tmux sessions, so you can
reattach after the restart.

## Notes for packaging (Phase 5)

- `aural` embeds an `Info.plist` (`__TEXT,__info_plist`) with
  `NSMicrophoneUsageDescription`, `NSAudioCaptureUsageDescription`, and
  `NSSpeechRecognitionUsageDescription` plus a bundle identifier, which is
  required for any future direct attribution.
- A signed and notarized release binary is planned in Phase 5; that work
  should re-test whether direct attribution (prompting for `aural` itself)
  becomes available.
