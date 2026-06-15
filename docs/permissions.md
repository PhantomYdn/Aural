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

## System Audio Recording (`--system`, `--app`, `--exclude-app`)

Service: `kTCCServiceAudioCapture` ("System Audio Recording Only").

**macOS does not show a prompt for terminal-attributed CLIs** — and worse,
a missing permission does not produce an error: the process tap silently
delivers all-zero samples. Aural detects an entirely-silent system capture
and prints a warning with these instructions:

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
