class Raygui < Formula
  desc "Immediate-mode GUI library for raylib, built as a static archive"
  homepage "https://github.com/raysan5/raygui"
  url "https://github.com/raysan5/raygui/archive/refs/tags/5.0.tar.gz"
  sha256 "0f194c4a5e837c0930aca0b6315db45d00f76fa0052d841eea94598d390c39d6"
  license "Zlib"

  depends_on "pkgconf" => :test
  depends_on "0xsct/tap/raylib-static"
  depends_on :macos

  on_arm do
    depends_on macos: :golden_gate
  end

  on_intel do
    depends_on macos: :tahoe
  end

  def install
    raylib = Formula["0xsct/tap/raylib-static"]
    (buildpath/"raygui.c").write <<~C
      #define RAYGUI_IMPLEMENTATION
      #include "raygui.h"
    C
    system ENV.cc, "-std=c99", "-O2", "-Isrc", "-I#{raylib.opt_include}",
           "-c", "raygui.c", "-o", "raygui.o"
    system "xcrun", "ar", "rcs", "libraygui.a", "raygui.o"
    lib.install "libraygui.a"
    include.install "src/raygui.h"

    (lib/"pkgconfig/raygui.pc").write <<~EOS
      prefix=#{prefix}
      libdir=${prefix}/lib
      includedir=${prefix}/include

      Name: raygui
      Description: Immediate-mode GUI library for raylib
      Version: #{version}
      Requires.private: raylib >= 6.2.0
      Libs: -L${libdir} -lraygui
      Cflags: -I${includedir}
    EOS
  end

  test do
    (testpath/"test.c").write <<~C
      #include <assert.h>
      #include <raygui.h>

      int main(void) {
        GuiSetState(STATE_NORMAL);
        GuiDisable();
        assert(GuiGetState() == STATE_DISABLED);
        GuiEnable();
        assert(GuiGetState() == STATE_NORMAL);
        GuiLock();
        assert(GuiIsLocked());
        GuiUnlock();
        assert(!GuiIsLocked());
        GuiSetStyle(DEFAULT, BORDER_WIDTH, 3);
        assert(GuiGetStyle(BUTTON, BORDER_WIDTH) == 3);
        GuiSetStyle(BUTTON, BORDER_WIDTH, 5);
        assert(GuiGetStyle(BUTTON, BORDER_WIDTH) == 5);
        assert(GuiGetStyle(DEFAULT, BORDER_WIDTH) == 3);
        return 0;
      }
    C
    raylib = Formula["0xsct/tap/raylib-static"]
    ENV.prepend_path "PKG_CONFIG_PATH", lib/"pkgconfig"
    ENV.append_path "PKG_CONFIG_PATH", raylib.opt_lib/"pkgconfig"
    flags = shell_output("#{formula_opt_bin("pkgconf")}/pkgconf --cflags --libs --static raygui").shellsplit
    flags.delete("-lraygui")
    flags.delete("-lraylib")
    system ENV.cc, "test.c", lib/"libraygui.a", raylib.opt_lib/"libraylib.a", "-o", "test", *flags
    system "./test"
    assert_empty lib.glob("*.dylib")
  end
end
