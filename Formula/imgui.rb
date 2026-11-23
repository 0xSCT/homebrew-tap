class Imgui < Formula
  desc "Dear ImGui 1.93.0 core + SDL2/OpenGL3 backends (static libs + pkg-config)"
  homepage "https://github.com/ocornut/imgui"
  url "https://github.com/ocornut/imgui/archive/refs/tags/v1.93.0.tar.gz"
  sha256 "f7bf6bc76e5d79d40d751096663e6c5d18daf08129dd52e7f7b09e4251c8eeee"
  license "MIT"

  # Upstream ships no build system for the installed-library layout used by the
  # SCT builds (pkg-config modules imgui / imgui_impl_sdl2 / imgui_impl_opengl3,
  # same as the Linux cross toolchains). This formula compiles the core and the
  # two backends and installs that layout.
  depends_on "pkgconf" => [:build, :test]
  depends_on "0xsct/tap/sdl2-static"

  on_arm do
    depends_on macos: :golden_gate
  end
  on_intel do
    depends_on macos: :tahoe
  end

  def install
    sdl2 = Formula["0xsct/tap/sdl2-static"]
    ENV.prepend_path "PKG_CONFIG_PATH", (sdl2.opt_lib/"pkgconfig").to_s
    sdl_cflags = Utils.safe_popen_read(formula_opt_bin("pkgconf")/"pkgconf", "--cflags", "sdl2").shellsplit
    cxxflags = ENV.cxxflags.to_s.shellsplit

    inc = include/"imgui"
    (inc/"backends").mkpath
    %w[imgui.h imgui_internal.h imconfig.h imstb_rectpack.h imstb_textedit.h
       imstb_truetype.h].each { |h| cp h, inc }
    %w[imgui_impl_sdl2.h imgui_impl_opengl3.h imgui_impl_opengl3_loader.h]
      .each { |h| cp "backends/#{h}", inc/"backends" }

    core = %w[imgui imgui_demo imgui_draw imgui_tables imgui_widgets]
    core.each do |n|
      system ENV.cxx, *cxxflags, "-std=c++17",
             "-c", "#{n}.cpp", "-o", "#{n}.o", "-I."
    end
    # Apple's archiver preserves Mach-O member alignment even when GNU ar is on PATH.
    system "xcrun", "ar", "rcs", "libimgui.a", *core.map { |n| "#{n}.o" }

    system ENV.cxx, *cxxflags, "-std=c++17", "-c",
           "backends/imgui_impl_sdl2.cpp", "-o", "imgui_impl_sdl2.o",
           "-I.", *sdl_cflags
    system ENV.cxx, *cxxflags, "-std=c++17", "-c",
           "backends/imgui_impl_opengl3.cpp", "-o", "imgui_impl_opengl3.o",
           "-I."
    system "xcrun", "ar", "rcs", "libimgui_impl_sdl2.a", "imgui_impl_sdl2.o"
    system "xcrun", "ar", "rcs", "libimgui_impl_opengl3.a", "imgui_impl_opengl3.o"

    lib.install "libimgui.a", "libimgui_impl_sdl2.a", "libimgui_impl_opengl3.a"

    pc = lib/"pkgconfig"
    pc.mkpath
    (pc/"imgui.pc").write <<~EOS
      prefix=#{prefix}
      Name: imgui
      Description: Dear ImGui immediate-mode GUI
      Version: #{version}
      Cflags: -I${prefix}/include/imgui
      Libs: -L${prefix}/lib -limgui
    EOS
    (pc/"imgui_impl_sdl2.pc").write <<~EOS
      prefix=#{prefix}
      Name: imgui_impl_sdl2
      Description: Dear ImGui SDL2 platform backend
      Version: #{version}
      Requires: imgui sdl2
      Libs: -L${prefix}/lib -limgui_impl_sdl2
    EOS
    (pc/"imgui_impl_opengl3.pc").write <<~EOS
      prefix=#{prefix}
      Name: imgui_impl_opengl3
      Description: Dear ImGui OpenGL3 renderer backend
      Version: #{version}
      Requires: imgui
      Libs: -L${prefix}/lib -limgui_impl_opengl3
    EOS
  end

  test do
    (testpath/"test.cpp").write <<~CPP
      #include <imgui.h>
      #include <backends/imgui_impl_sdl2.h>
      #include <backends/imgui_impl_opengl3.h>
      #include <cassert>

      int main() {
        IMGUI_CHECKVERSION();
        ImGuiContext *context = ImGui::CreateContext();
        assert(context != nullptr && ImGui::GetCurrentContext() == context);
        auto *volatile sdl_backend = &ImGui_ImplSDL2_InitForOpenGL;
        auto *volatile gl_backend = &ImGui_ImplOpenGL3_Init;
        assert(sdl_backend != nullptr && gl_backend != nullptr);
        ImGui::DestroyContext(context);
        assert(ImGui::GetCurrentContext() == nullptr);
        return 0;
      }
    CPP
    ENV.prepend_path "PKG_CONFIG_PATH", lib/"pkgconfig"
    ENV.prepend_path "PKG_CONFIG_PATH", formula_opt_lib("0xsct/tap/sdl2-static")/"pkgconfig"
    flags = shell_output("#{formula_opt_bin("pkgconf")}/pkgconf --cflags --libs --static " \
                         "imgui_impl_sdl2 imgui_impl_opengl3").shellsplit
    flags.map! do |flag|
      case flag
      when "-limgui", "-limgui_impl_sdl2", "-limgui_impl_opengl3"
        (lib/"lib#{flag.delete_prefix("-l")}.a").to_s
      when "-lSDL2"
        (formula_opt_lib("0xsct/tap/sdl2-static")/"libSDL2.a").to_s
      else
        flag
      end
    end
    system ENV.cxx, "-std=c++17", "test.cpp", "-o", "test", *flags
    system "./test"
    assert_empty lib.glob("*.dylib")
  end
end
