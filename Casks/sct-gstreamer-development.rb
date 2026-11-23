cask "sct-gstreamer-development" do
  version "1.28.8"
  sha256 "e6d380bc17be7eccf13e0154567d4718fc9321da822408c7ca0cd808b3d4a3f7"

  on_arm do
    depends_on macos: :golden_gate
  end
  on_intel do
    depends_on macos: :tahoe
  end

  url "https://gstreamer.freedesktop.org/data/pkg/osx/#{version}/gstreamer-1.0-devel-#{version}-universal.pkg"
  name "GStreamer development package"
  desc "Universal GStreamer headers, pkg-config metadata and static archives"
  homepage "https://gstreamer.freedesktop.org/"

  livecheck do
    url "https://gstreamer.freedesktop.org/download/"
    regex(/gstreamer[._-]1\.0[._-]devel[._-]v?(\d+(?:\.\d+)+)[._-]universal\.pkg/i)
  end

  depends_on cask: "0xsct/tap/sct-gstreamer-runtime"

  pkg "gstreamer-1.0-devel-#{version}-universal.pkg"

  uninstall script: {
    executable:   "#{HOMEBREW_PREFIX}/bin/brew",
    args:         ["ruby", "-e", <<~'RUBY'],
      # frozen_string_literal: true

      require "cask/pkg"
      require "set"

      prefix = "org.freedesktop.gstreamer.darwin."
      components = %w[
        base-crypto
        base-system-1.0
        gstreamer-1.0-analytics
        gstreamer-1.0-capture
        gstreamer-1.0-codecs
        gstreamer-1.0-codecs-gpl
        gstreamer-1.0-codecs-gpl-restricted
        gstreamer-1.0-codecs-restricted
        gstreamer-1.0-core
        gstreamer-1.0-devtools
        gstreamer-1.0-dvd-gpl
        gstreamer-1.0-editing
        gstreamer-1.0-effects
        gstreamer-1.0-encoding
        gstreamer-1.0-gtk
        gstreamer-1.0-libav
        gstreamer-1.0-net
        gstreamer-1.0-net-restricted
        gstreamer-1.0-playback
        gstreamer-1.0-python
        gstreamer-1.0-system
        gstreamer-1.0-visualizers
      ]
      installed = SystemCommand.run!("/usr/sbin/pkgutil", args: ["--pkgs"]).stdout.lines.map(&:chomp)
      runtime_ids = (components + ["GStreamer"]).map { |component| "#{prefix}#{component}" } & installed
      runtime_packages = runtime_ids.map { |id| Cask::Pkg.new(id) }
      protected_paths = runtime_packages.flat_map { |package| package.pkgutil_bom_all + [package.root] }.to_set
      protected_directories = protected_paths.flat_map { |path| path.ascend.to_a }.to_set

      components.each do |component|
        id = "#{prefix}#{component}-devel"
        next unless installed.include?(id)

        package = Cask::Pkg.new(id)
        # Both upstream installers own some dylibs, links and tools; keep runtime-owned paths.
        package.pkgutil_bom_all.reject! { |path| protected_paths.include?(path) }
        # Homebrew's default rmdir helper deletes directory contents even at shared roots.
        package.define_singleton_method(:rmdir) do |paths|
          Array(paths).each do |path|
            next if protected_directories.include?(path)
            next unless path.lstat.directory?
            next unless path.children.empty?

            SystemCommand.run!("/bin/rmdir", args: ["--", path], sudo: true, sudo_as_root: true)
          end
        end
        package.singleton_class.send(:private, :rmdir)
        package.uninstall
      end
    RUBY
    must_succeed: true,
    sudo:         false,
  }

  caveats <<~EOS
    This upstream installer adds headers and static archives to
    /Library/Frameworks/GStreamer.framework alongside the matching runtime.
    Use a clean host; installing over an existing SDK can replace its files.
    Uninstall removes development receipts while preserving runtime-owned paths.
    This cask does not bypass macOS installer trust or Gatekeeper checks.
  EOS
end
