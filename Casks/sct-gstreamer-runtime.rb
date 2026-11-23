cask "sct-gstreamer-runtime" do
  version "1.28.8"
  sha256 "d371ab04a7632713626836c2fc234e863cc98484c74c473eba99b0fbd9b3a3fe"

  on_arm do
    depends_on macos: :golden_gate
  end
  on_intel do
    depends_on macos: :tahoe
  end

  url "https://gstreamer.freedesktop.org/data/pkg/osx/#{version}/gstreamer-1.0-#{version}-universal.pkg"
  name "GStreamer runtime package"
  desc "Universal GStreamer multimedia framework runtime"
  homepage "https://gstreamer.freedesktop.org/"

  livecheck do
    url "https://gstreamer.freedesktop.org/download/"
    regex(/gstreamer[._-]1\.0[._-]v?(\d+(?:\.\d+)+)[._-]universal\.pkg/i)
  end

  pkg "gstreamer-1.0-#{version}-universal.pkg"

  uninstall pkgutil: [
    "^org\\.freedesktop\\.gstreamer\\.darwin\\.base-crypto$",
    "^org\\.freedesktop\\.gstreamer\\.darwin\\.base-system-1\\.0$",
    "^org\\.freedesktop\\.gstreamer\\.darwin\\.GStreamer$",
    "^org\\.freedesktop\\.gstreamer\\.darwin\\.gstreamer-1\\.0-analytics$",
    "^org\\.freedesktop\\.gstreamer\\.darwin\\.gstreamer-1\\.0-capture$",
    "^org\\.freedesktop\\.gstreamer\\.darwin\\.gstreamer-1\\.0-codecs$",
    "^org\\.freedesktop\\.gstreamer\\.darwin\\.gstreamer-1\\.0-codecs-gpl$",
    "^org\\.freedesktop\\.gstreamer\\.darwin\\.gstreamer-1\\.0-codecs-gpl-restricted$",
    "^org\\.freedesktop\\.gstreamer\\.darwin\\.gstreamer-1\\.0-codecs-restricted$",
    "^org\\.freedesktop\\.gstreamer\\.darwin\\.gstreamer-1\\.0-core$",
    "^org\\.freedesktop\\.gstreamer\\.darwin\\.gstreamer-1\\.0-devtools$",
    "^org\\.freedesktop\\.gstreamer\\.darwin\\.gstreamer-1\\.0-dvd-gpl$",
    "^org\\.freedesktop\\.gstreamer\\.darwin\\.gstreamer-1\\.0-editing$",
    "^org\\.freedesktop\\.gstreamer\\.darwin\\.gstreamer-1\\.0-effects$",
    "^org\\.freedesktop\\.gstreamer\\.darwin\\.gstreamer-1\\.0-encoding$",
    "^org\\.freedesktop\\.gstreamer\\.darwin\\.gstreamer-1\\.0-gtk$",
    "^org\\.freedesktop\\.gstreamer\\.darwin\\.gstreamer-1\\.0-libav$",
    "^org\\.freedesktop\\.gstreamer\\.darwin\\.gstreamer-1\\.0-net$",
    "^org\\.freedesktop\\.gstreamer\\.darwin\\.gstreamer-1\\.0-net-restricted$",
    "^org\\.freedesktop\\.gstreamer\\.darwin\\.gstreamer-1\\.0-playback$",
    "^org\\.freedesktop\\.gstreamer\\.darwin\\.gstreamer-1\\.0-python$",
    "^org\\.freedesktop\\.gstreamer\\.darwin\\.gstreamer-1\\.0-system$",
    "^org\\.freedesktop\\.gstreamer\\.darwin\\.gstreamer-1\\.0-visualizers$",
  ]

  caveats <<~EOS
    This upstream installer writes to /Library/Frameworks/GStreamer.framework.
    Use a clean host; installing over an existing SDK can replace its files.
    For matching development headers and static archives, install:
      brew install --cask 0xsct/tap/sct-gstreamer-development
    This cask does not bypass macOS installer trust or Gatekeeper checks.
  EOS
end
