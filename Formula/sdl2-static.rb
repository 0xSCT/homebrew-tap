class Sdl2Static < Formula
  desc "SDL2 built with static libraries only (SCT static-link builds)"
  homepage "https://libsdl.org"
  url "https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz"
  sha256 "5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165"
  license "Zlib"

  livecheck do
    url :stable
    regex(/^release-(2\.\d+\.\d+)$/i)
    strategy :github_releases
  end

  # Static-only native build; Homebrew core only ships sdl2-compat (SDL3 shim,
  # shared-only), which is useless for a fully static SDL2 link.
  keg_only "static-only build that would shadow sdl2/sdl2-compat"

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
      -DCMAKE_BUILD_TYPE=Release
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5
      -DSDL_SHARED=OFF
      -DSDL_STATIC=ON
      -DSDL_TEST=OFF
    ]
    system "cmake", "-S", ".", "-B", "build", *args, *std_cmake_args
    system "cmake", "--build", "build"
    system "cmake", "--install", "build"
  end

  test do
    (testpath/"test.c").write <<~C
      #include <SDL.h>
      #include <assert.h>
      #include <string.h>

      int main(void) {
        assert(SDL_Init(SDL_INIT_EVENTS) == 0);
        SDL_Surface *surface = SDL_CreateRGBSurfaceWithFormat(0, 8, 8, 32, SDL_PIXELFORMAT_RGBA32);
        assert(surface != NULL);
        SDL_Renderer *renderer = SDL_CreateSoftwareRenderer(surface);
        assert(renderer != NULL);
        assert(SDL_SetRenderDrawColor(renderer, 255, 0, 0, 255) == 0);
        assert(SDL_RenderClear(renderer) == 0);
        SDL_RenderPresent(renderer);
        Uint32 pixel;
        memcpy(&pixel, surface->pixels, sizeof(pixel));
        Uint8 r, g, b, a;
        SDL_GetRGBA(pixel, surface->format, &r, &g, &b, &a);
        assert(r == 255 && g == 0 && b == 0 && a == 255);
        assert(SDL_GameControllerGetButtonFromString("a") == SDL_CONTROLLER_BUTTON_A);
        assert(strcmp(SDL_GameControllerGetStringForButton(SDL_CONTROLLER_BUTTON_A), "a") == 0);
        SDL_DestroyRenderer(renderer);
        SDL_FreeSurface(surface);
        SDL_Quit();
        return 0;
      }
    C
    ENV.prepend_path "PKG_CONFIG_PATH", lib/"pkgconfig"
    flags = shell_output("#{formula_opt_bin("pkgconf")}/pkgconf --cflags --libs --static sdl2").shellsplit
    flags.map! { |flag| (flag == "-lSDL2") ? (lib/"libSDL2.a").to_s : flag }
    system ENV.cc, "test.c", "-o", "test", *flags
    system "./test"
    assert_empty lib.glob("*.dylib")
  end
end
