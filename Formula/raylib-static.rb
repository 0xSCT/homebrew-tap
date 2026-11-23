class RaylibStatic < Formula
  desc "Raylib built as a static library with JPEG support"
  homepage "https://www.raylib.com/"
  url "https://github.com/raysan5/raylib/archive/refs/tags/6.2.tar.gz"
  sha256 "df7a13129b1bec9e73a6962efff170beba310ee6eab8f94cd000b7316b4db5ee"
  license "Zlib"

  bottle do
    root_url "https://github.com/0xsct/homebrew-tap/releases/download/raylib-static-6.2"
    sha256 cellar: :any_skip_relocation, arm64_golden_gate: "9dca5549b71a0be123cdb0a83ed9e3686312cdf550bf03257a744b48b941d5fa"
    sha256 cellar: :any_skip_relocation, tahoe:             "22070170f517940562089a1b4e0a8fe0785855fd8edc028b3a9e5ea7bb88404d"
  end

  keg_only "static-only build that would shadow raylib"

  depends_on "cmake" => :build
  depends_on "pkgconf" => :test
  depends_on :macos

  on_arm do
    depends_on macos: :golden_gate
  end

  on_intel do
    depends_on macos: :tahoe
  end

  def install
    # Upstream uses an out-of-scope GLFW variable and omits OpenGL from raylib.pc.
    inreplace "cmake/InstallConfigurations.cmake",
              "set(PKG_CONFIG_LIBS_PRIVATE ${GLFW_PKG_LIBS})", <<~CMAKE.strip
                library_path_to_linker_flags(PKG_CONFIG_LIBS_PRIVATE "${raylib_install_private_libs}")
                string(APPEND PKG_CONFIG_LIBS_PRIVATE " ${GLFW_PKG_CONFIG_LIBS_PRIVATE}")
              CMAKE

    system "cmake", "-S", ".", "-B", "build", *std_cmake_args,
           "-DBUILD_SHARED_LIBS=OFF",
           "-DBUILD_EXAMPLES=OFF",
           "-DPLATFORM=Desktop",
           "-DUSE_EXTERNAL_GLFW=OFF",
           "-DCUSTOMIZE_BUILD=ON",
           "-DSUPPORT_FILEFORMAT_JPG=ON"
    system "cmake", "--build", "build"
    system "cmake", "--install", "build"
  end

  test do
    (testpath/"test.c").write <<~C
      #include <stddef.h>
      #include <assert.h>
      #include <raylib.h>

      int main(int argc, char **argv) {
        assert(argc == 2);
        Image image = LoadImage(argv[1]);
        assert(image.data != NULL);
        assert(image.width > 0 && image.height > 0);
        UnloadImage(image);
        return 0;
      }
    C
    ENV.prepend_path "PKG_CONFIG_PATH", lib/"pkgconfig"
    flags = shell_output("#{formula_opt_bin("pkgconf")}/pkgconf --cflags --libs --static raylib").shellsplit
    flags.delete("-lraylib")
    system ENV.cc, "test.c", lib/"libraylib.a", "-o", "test", *flags
    system "./test", test_fixtures("test.jpg")
    assert_empty lib.glob("*.dylib")
  end
end
