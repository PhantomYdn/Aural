class Hark < Formula
  desc "Capture and transcribe microphone and system audio on macOS"
  homepage "https://github.com/PhantomYdn/hark"
  url "https://github.com/PhantomYdn/hark/releases/download/v0.2.1/hark-0.2.1-macos-arm64.tar.gz"
  version "0.2.1"
  sha256 "608a243558905fa109d45375e0bb28b7fe10c15ba29cfe7730972c781add6b40"
  license "MIT"

  # Prebuilt Apple Silicon binary; Intel users build from source (see README).
  depends_on arch: :arm64
  depends_on macos: :sonoma

  # The default `whisper` engine shells out to whisper.cpp at runtime.
  depends_on "whisper-cpp"

  def install
    bin.install "hark"
    man1.install "hark.1"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/hark --version")
  end
end
