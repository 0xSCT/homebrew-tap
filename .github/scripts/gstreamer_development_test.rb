# frozen_string_literal: true

# Run with: brew ruby .github/scripts/gstreamer_development_test.rb
# Exercises the actual script and directory helper only against guarded workspace fixtures.
require "cask/cask_loader"
require "cask/pkg"
require "tmpdir"
command_result = Struct.new(:stdout, :plist, keyword_init: true)

cask = Cask::CaskLoader.load("0xsct/tap/sct-gstreamer-development")
script = cask.artifacts.find { |artifact| artifact.is_a?(Cask::Artifact::Uninstall) }.directives.fetch(:script)
code = script.fetch(:args).last

Dir.mktmpdir("task-4-receipts", __dir__) do |directory|
  root = Pathname.new(directory)
  (root/"bin").mkpath
  (root/"lib").mkpath
  # Shared paths come from the actual upstream 1.28.8 BOM intake.
  shared = %w[bin/gio-querymodules lib/libMoltenVK.dylib lib/liba52.dylib]
  shared.each { |path| (root/path).write("runtime") }
  (root/"lib/libgstreamer-1.0.0.dylib").write("runtime")
  File.symlink("libgstreamer-1.0.0.dylib", root/"lib/libgstreamer-1.0.dylib")
  (root/"lib/libgstreamer-1.0.a").write("development")
  (root/".DS_Store").write("runtime sentinel")
  File.symlink("missing-runtime-target", root/"runtime-dangling")
  (root/"devel-only/empty").mkpath
  (root/"devel-only/keep").mkpath
  (root/"devel-only/keep/.DS_Store").write("untracked sentinel")
  uninstall_source = root/"uninstall.rb"
  uninstall_source.write(code)
  prefix = "org.freedesktop.gstreamer.darwin."
  receipts = {
    "#{prefix}base-system-1.0"          => ["bin/gio-querymodules"],
    "#{prefix}gstreamer-1.0-system"     => ["lib/libMoltenVK.dylib"],
    "#{prefix}gstreamer-1.0-codecs-gpl" => ["lib/liba52.dylib"],
    "#{prefix}gstreamer-1.0-core"       => [
      "lib/libgstreamer-1.0.dylib",
      "lib/libgstreamer-1.0.0.dylib",
      ".DS_Store",
      "runtime-dangling",
    ],
    # Deliberately put shared files in a different development receipt.
    "#{prefix}gstreamer-1.0-core-devel" => shared + [
      "lib/libgstreamer-1.0.dylib",
      "lib/libgstreamer-1.0.a",
      "devel-only",
      "devel-only/empty",
      "devel-only/keep",
    ],
    "#{prefix}unrelated-devel"          => ["lib/do-not-remove.a"],
  }
  (root/"lib/do-not-remove.a").write("unrelated")
  forgotten = []
  original_run = SystemCommand.method(:run!)
  SystemCommand.define_singleton_method(:run!) do |executable, **options|
    args = options.fetch(:args)
    case [executable, args.first]
    when ["/usr/sbin/pkgutil", "--pkgs"]
      command_result.new(stdout: receipts.keys.join("\n"))
    when ["/usr/sbin/pkgutil", "--files"]
      command_result.new(stdout: receipts.fetch(args.last).join("\n"))
    when ["/usr/sbin/pkgutil", "--pkg-info-plist"]
      command_result.new(plist: { "volume" => "/", "install-location" => root.to_s })
    when ["/usr/sbin/pkgutil", "--forget"]
      forgotten << args.last
      command_result.new(stdout: "")
    when ["/usr/bin/xargs", "-0"]
      if args == ["-0", "--", "/bin/rm", "--"]
        options.fetch(:input).split("\0").each do |path|
          raise "Deletion escaped fixture" unless path.start_with?("#{root}/")

          File.unlink(path)
        end
      elsif args == ["-0", "--", (HOMEBREW_LIBRARY_PATH/"cask/utils/rmdir.sh").to_s]
        paths = options.fetch(:input).split("\0")
        paths.each do |path|
          if path != root.to_s && !path.start_with?("#{root}/")
            raise "Directory deletion escaped fixture"
          end
          raise "Directory cleanup follows symlink" if File.symlink?(path)

          real_path = File.realpath(path)
          if real_path != root.to_s && !real_path.start_with?("#{root}/")
            raise "Directory cleanup escaped real fixture"
          end
        end
        # Exercise the real helper: it removes .DS_Store and dangling links before checking emptiness.
        original_run.call("/bin/bash", args: [args.last, *paths])
      else
        raise "Unexpected command: #{args.inspect}"
      end
      command_result.new(stdout: "")
    when ["/bin/rmdir", "--"]
      path = args.fetch(1).to_s
      raise "Empty-directory deletion escaped fixture" unless path.start_with?("#{root}/")
      raise "Empty-directory deletion follows symlink" if File.symlink?(path)
      raise "Empty-directory deletion escaped real fixture" unless File.realpath(path).start_with?("#{root}/")

      original_run.call(executable, args: ["--", path])
    else
      raise "Unexpected command: #{executable} #{args.inspect}"
    end
  end
  begin
    load uninstall_source.to_s
    raise "Shared runtime file removed" unless shared.all? { |path| (root/path).file? }
    raise "Shared runtime symlink removed" unless (root/"lib/libgstreamer-1.0.dylib").symlink?
    raise "Runtime-owned root dangling symlink removed" unless (root/"runtime-dangling").symlink?
    if !(root/".DS_Store").file? || (root/".DS_Store").read != "runtime sentinel"
      raise "Runtime-owned .DS_Store removed"
    end
    raise "Development archive retained" if (root/"lib/libgstreamer-1.0.a").exist?
    raise "Unrelated receipt file removed" unless (root/"lib/do-not-remove.a").file?
    raise "Empty development directory retained" if (root/"devel-only/empty").exist?
    raise "Untracked directory contents removed" unless (root/"devel-only/keep/.DS_Store").file?
    raise "Wrong receipts forgotten: #{forgotten.inspect}" if forgotten != ["#{prefix}gstreamer-1.0-core-devel"]
  ensure
    SystemCommand.define_singleton_method(:run!, original_run)
  end
end
puts "Task 4 receipt ownership regression passed"
