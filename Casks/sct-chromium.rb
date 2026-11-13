cask "sct-chromium" do
  arch arm: "Mac_Arm", intel: "Mac"

  on_arm do
    version "160.0.8159.0,1743866"
    sha256 "53a7981e0353e4518d21ffc51bfcfe4faa95fc61dacb9f33553bd8550fe590a4"

    depends_on macos: :golden_gate
  end
  on_intel do
    version "160.0.8159.0,1743864"
    sha256 "12cb5adbbb7ab1d00718add20944d96a0a4f2bc507a0ee53d02bf7eb85aac28c"

    depends_on macos: :tahoe
  end

  url "https://storage.googleapis.com/chromium-browser-snapshots/#{arch}/#{version.csv.second}/chrome-mac.zip"
  name "Chromium"
  desc "Native Chromium browser snapshot"
  homepage "https://www.chromium.org/"

  livecheck do
    url "https://storage.googleapis.com/chromium-browser-snapshots/#{arch}/LAST_CHANGE"
    regex(/\A\s*(\d+)\s*\z/)
    strategy :page_match do |page, regex|
      match = page.match(regex)
      next if match.blank?

      # Snapshot updates require reviewing chrome/VERSION at the new REVISIONS commit.
      "#{version.csv.first},#{match[1]}"
    end
  end

  app "chrome-mac/Chromium.app"

  caveats <<~EOS
    This is a pinned upstream snapshot, not a stable Chromium release.
    Chromium snapshots may fail macOS signing or Gatekeeper checks.
    This cask does not bypass macOS security protections.
  EOS
end
