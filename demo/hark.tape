# hark demo — render with:  make demo   (needs: brew install vhs ffmpeg)
#
# Drives only deterministic, no-permission commands so the GIF is
# reproducible: version, device list, file transcription, transcode,
# and the resolved config. No microphone/system-audio TCC prompts.
#
# The `make demo` target builds a release binary and puts it on PATH,
# so `hark` below resolves to this checkout.

Output assets/demo.gif

Require hark

Set Shell        "zsh"
Set FontSize     18
Set Width        1240
Set Height       680
Set Padding      24
Set Margin       16
Set BorderRadius 12
Set WindowBar    Colorful
Set Theme        "Catppuccin Mocha"
Set TypingSpeed  55ms
Set PlaybackSpeed 1.0

# Setup (not recorded): enable `#` comments and a clean prompt.
Hide
Type "setopt interactive_comments" Enter
Type "export PROMPT='%F{45}❯%f '" Enter
Type "clear" Enter
Show
Sleep 600ms

Type "hark --version"
Sleep 400ms
Enter
Sleep 1500ms

Type "hark devices"
Sleep 400ms
Enter
Sleep 3s

Type "# transcribe a file to stdout"
Enter
Type "hark -i demo/sample.mp3 -t -"
Sleep 400ms
Enter
Sleep 3s

Type "# transcode between formats - no model needed"
Enter
Type "hark -i demo/sample.mp3 -a out.flac && hark info out.flac"
Sleep 400ms
Enter
Sleep 3s

Type "# every default, and where it came from"
Enter
Type "hark config show"
Sleep 400ms
Enter
Sleep 4s

# tidy up the scratch file so the demo leaves nothing behind
Hide
Type "rm -f out.flac" Enter
Show
Sleep 1.5s
