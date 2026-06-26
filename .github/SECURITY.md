# Security Policy

## Supported versions

hark is pre-1.0; security fixes land on the latest release and `main`. Please
make sure you can reproduce an issue on the most recent
[release](https://github.com/PhantomYdn/hark/releases) before reporting.

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Report privately via GitHub's
[private vulnerability reporting](https://github.com/PhantomYdn/hark/security/advisories/new)
(Security → Report a vulnerability). Include:

- affected version (`hark --version`) and macOS version,
- a description of the issue and its impact,
- reproduction steps or a proof of concept if you have one.

You can expect an initial acknowledgement within a few days. Once a fix is
available, we'll coordinate disclosure and credit you if you'd like.

## Scope & design notes

hark is built to minimize attack surface:

- **On-device by default.** Capture and transcription run locally; there are no
  telemetry or network calls unless you explicitly download a model.
- **Remote control is opt-in and loopback-only by default.**
  `hark --remote-control` binds to `127.0.0.1`; any non-loopback bind *requires*
  `$HARK_REMOTE_TOKEN`. The API is control + status only — recording artifacts
  are written to local files and never returned over HTTP.
- **macOS TCC** gates microphone, system-audio, and speech-recognition access;
  hark cannot capture without a user-granted permission.

Reports about these boundaries (e.g. a way to capture without the expected
permission, or to reach the remote-control API unauthenticated) are especially
welcome.
