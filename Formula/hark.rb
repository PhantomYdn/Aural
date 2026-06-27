class Hark < Formula
  desc "Capture and transcribe microphone and system audio on macOS"
  homepage "https://github.com/PhantomYdn/hark"
  url "https://github.com/PhantomYdn/hark/releases/download/v0.3.0/hark-0.3.0-macos-arm64.tar.gz"
  version "0.3.0"
  sha256 "c397601f3137bdfd35400bdefc00831b1470205a693785cab6873bce2a0c964c"
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
