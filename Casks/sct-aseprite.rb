cask "sct-aseprite" do
  arch arm: "arm64", intel: "x86_64"

  version "1.3.18.6"
  # User-built local archives differ with each native build.
  sha256 :no_check

  on_arm do
    depends_on macos: :golden_gate
  end
  on_intel do
    depends_on macos: :tahoe
  end

  url "file://#{Dir.home}/Downloads/Aseprite-#{version}-#{arch}.zip"
  name "Aseprite"
  desc "Animated sprite editor and pixel art tool"
  homepage "https://www.aseprite.org/"

  livecheck do
    skip "User-built local artifact"
  end

  app "Aseprite.app"
end
