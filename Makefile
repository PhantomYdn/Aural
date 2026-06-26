# Hark build helpers.
#
# Workaround: on machines with Command Line Tools only (no full Xcode),
# Testing.framework and lib_TestingInterop.dylib are not on the default
# search paths, so `swift test` fails with "no such module 'Testing'".
# The flags below point the compiler/linker at the CLT copies; they are
# harmless on machines where full Xcode is installed.
CLT := /Library/Developer/CommandLineTools
TESTING_FLAGS := \
	-Xswiftc -F$(CLT)/Library/Developer/Frameworks \
	-Xlinker -F$(CLT)/Library/Developer/Frameworks \
	-Xlinker -rpath -Xlinker $(CLT)/Library/Developer/Frameworks \
	-Xlinker -rpath -Xlinker $(CLT)/Library/Developer/usr/lib

.PHONY: build test release clean demo

build:
	swift build

test:
	swift test $(TESTING_FLAGS)

release:
	swift build -c release

clean:
	swift package clean

# Render the README demo GIF (assets/demo.gif) from demo/hark.tape.
# Requires VHS + ffmpeg:  brew install vhs ffmpeg
# Builds a release binary and puts it first on PATH so the tape's `hark`
# resolves to this checkout.
demo: release
	@command -v vhs >/dev/null || { echo "vhs not found — run: brew install vhs ffmpeg"; exit 1; }
	PATH="$(PWD)/.build/release:$$PATH" vhs demo/hark.tape
	@echo "wrote assets/demo.gif"
