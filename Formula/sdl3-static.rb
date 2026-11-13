class Sdl3Static < Formula
  desc "SDL3 built with static libraries only (SCT static-link builds)"
  homepage "https://libsdl.org"
  url "https://github.com/libsdl-org/SDL/releases/download/release-3.4.20/SDL3-3.4.20.tar.gz"
  sha256 "f3bb06f55bed9557227a700af2ea62e49497ebdf58037732a731a5fb3ef8581f"
  license "Zlib"

  livecheck do
    url :stable
    regex(/^release-(3\.\d+\.\d+)$/i)
    strategy :github_releases
  end

  keg_only "static-only build that would shadow sdl3"

  depends_on "cmake" => :build
  depends_on "pkgconf" => [:build, :test]

  on_arm do
    depends_on macos: :golden_gate
  end
  on_intel do
    depends_on macos: :tahoe
  end

  def install
    args = %w[
      -DSDL_SHARED=OFF
      -DSDL_STATIC=ON
      -DSDL_TEST_LIBRARY=OFF
      -DSDL_TESTS=OFF
    ]
    system "cmake", "-S", ".", "-B", "build", *args, *std_cmake_args
    system "cmake", "--build", "build"
    system "cmake", "--install", "build"
  end

  test do
    (testpath/"test.c").write <<~C
      #include <SDL3/SDL.h>
      #include <assert.h>
      #include <string.h>

      int main(void) {
        assert(SDL_Init(SDL_INIT_EVENTS));
        SDL_Surface *surface = SDL_CreateSurface(8, 8, SDL_PIXELFORMAT_RGBA32);
        assert(surface != NULL);
        SDL_Renderer *renderer = SDL_CreateSoftwareRenderer(surface);
        assert(renderer != NULL);
        assert(SDL_SetRenderDrawColor(renderer, 255, 0, 0, 255));
        assert(SDL_RenderClear(renderer));
        assert(SDL_RenderPresent(renderer));
        Uint32 pixel;
        memcpy(&pixel, surface->pixels, sizeof(pixel));
        Uint8 r, g, b, a;
        SDL_GetRGBA(pixel, SDL_GetPixelFormatDetails(surface->format), NULL, &r, &g, &b, &a);
        assert(r == 255 && g == 0 && b == 0 && a == 255);
        const char *button = SDL_GetGamepadStringForButton(SDL_GAMEPAD_BUTTON_SOUTH);
        assert(button != NULL);
        assert(SDL_GetGamepadButtonFromString(button) == SDL_GAMEPAD_BUTTON_SOUTH);
        SDL_DestroyRenderer(renderer);
        SDL_DestroySurface(surface);
        SDL_Quit();
        return 0;
      }
    C
    ENV.prepend_path "PKG_CONFIG_PATH", lib/"pkgconfig"
    flags = shell_output("#{formula_opt_bin("pkgconf")}/pkgconf --cflags --libs --static sdl3").shellsplit
    flags.map! { |flag| (flag == "-lSDL3") ? (lib/"libSDL3.a").to_s : flag }
    system ENV.cc, "test.c", "-o", "test", *flags
    system "./test"
    assert_empty lib.glob("*.dylib")
  end
end
