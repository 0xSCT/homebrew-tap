# SCT Homebrew Tap

Personal Homebrew packages for native macOS development.

- ARM: macOS 27 and newer.
- Intel: macOS 26 and newer.
- Graphics libraries contain static `.a` archives.
- LLVM and LLDB bottles build only for Intel. Use official Homebrew packages on ARM.
- Aseprite uses your own local build. GitHub does not build or publish it.

## What belongs in this tap

A **formula** builds software from source. A **bottle** is a prebuilt formula.
A **cask** installs a finished app or installer. A **tap** is the Git repository containing these definitions.

Official availability was checked before adding these packages:

| Package here | Version | Why this tap needs it |
| --- | --- | --- |
| `imgui` | 1.93.0 | Missing from core; includes static SDL2 and OpenGL3 backends |
| `sdl2-static` | 2.32.10 | Official `sdl2` now points to the SDL3-backed compatibility library |
| `sdl3-static` | 3.4.20 | Static-only variant of official SDL3 |
| `raygui` | 5.0 | Missing from core; installs a header and static implementation |
| `raylib-static` | 6.2 | Official raylib has a static archive but disables JPEG decoding |
| `llvm-sct` | 23.1.5, revision 1 | Current official macOS bottles do not cover Intel |
| `lldb-sct` | 23.1.5, revision 1 | Current official macOS bottles do not cover Intel |
| `sct-chromium` | 160.0.8159.0 | Official cask is disabled; this tap pins native snapshot downloads |
| `sct-gstreamer-runtime` | 1.28.8 | Official SDK cask is disabled; installs the universal runtime |
| `sct-gstreamer-development` | 1.28.8 | Installs the matching universal SDK, including static archives |
| `sct-aseprite` | 1.3.18.6 | Installs your host-built app, without distributing binaries |

See the [official package index](https://formulae.brew.sh/) for current core availability.
Chromium and the official GStreamer casks were disabled for failing Gatekeeper checks.
This tap does not fix upstream signing or remove macOS security protections.

## Repository layout

```text
Formula/              Source builds and library tests
Casks/                Upstream installers and the local Aseprite app
Patches/llvm/         Required patch from the maintained LLVM recipe
LICENSES/             Notices for imported Homebrew code
.github/workflows/    Native builds and reviewed publication
.github/scripts/      Change selection, publication checks and regressions
docs/                 Approved design and implementation plan
```

`0xSCT/homebrew-tap` maps to the tap name `0xsct/tap`.
Formula and cask filenames match their package names. Custom variants have distinct names to avoid replacing official packages.

## Install

Commit and push the tap definitions before installing them from GitHub.
The commands below select this tap explicitly. Homebrew can then add the tap and trust the selected item.

```sh
brew install 0xsct/tap/imgui
brew install 0xsct/tap/sdl2-static 0xsct/tap/sdl3-static
brew install 0xsct/tap/raylib-static 0xsct/tap/raygui
```

On ARM, use the existing official compiler packages:

```sh
brew install llvm lldb
```

On Intel, use these maintained variants:

```sh
brew install 0xsct/tap/llvm-sct 0xsct/tap/lldb-sct
```

Install the upstream binary packages separately:

```sh
brew install --cask 0xsct/tap/sct-chromium
brew install --cask 0xsct/tap/sct-gstreamer-development
```

The development cask installs its matching GStreamer runtime dependency.
Use a clean host for the SDK. Its installer writes to `/Library/Frameworks/GStreamer.framework`, not a Homebrew Cellar.
Installing another SDK release can replace files there.

Before bottles are published, formula installation builds from source.
After publication, Homebrew selects the matching bottle when one is available.
Intel dependencies may still need source builds because official Intel bottles are no longer maintained.

## Use the static libraries

`sdl2-static`, `sdl3-static`, `raylib-static`, `llvm-sct` and `lldb-sct` are **keg-only**.
This means Homebrew does not place their files in the shared prefix. Find their paths with `brew --prefix`.

```sh
brew --prefix 0xsct/tap/sdl2-static
brew --prefix 0xsct/tap/sdl3-static
brew --prefix 0xsct/tap/raylib-static
```

Use headers from `include/`, archives from `lib/`, and metadata from `lib/pkgconfig/` or `lib/cmake/`.
SDL2 and SDL3 provide upstream static CMake targets. Raylib's installed CMake target is static in this variant.

For ImGui, the preserved pkg-config modules are:

- `imgui`
- `imgui_impl_sdl2`
- `imgui_impl_opengl3`

The following headless example uses ImGui's core and resolves both backend archives.
Run it in **Bash** after installing `0xsct/tap/imgui` and `pkgconf`:

```bash
set -euo pipefail
imgui_prefix=$(brew --prefix 0xsct/tap/imgui)
sdl2_prefix=$(brew --prefix 0xsct/tap/sdl2-static)
export PKG_CONFIG_PATH="$imgui_prefix/lib/pkgconfig:$sdl2_prefix/lib/pkgconfig"

cat > imgui-consumer.cpp <<'CPP'
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

pkg_flags=$(pkgconf --cflags --libs --static imgui_impl_sdl2 imgui_impl_opengl3)
# Decode pkgconf's shell quoting into a Bash array without executing its output.
flags=()
while IFS= read -r -d '' flag; do
  flags+=("$flag")
done < <(brew ruby -e 'require "shellwords"; STDIN.read.shellsplit.each { |flag| print flag, "\0" }' <<< "$pkg_flags")
for i in "${!flags[@]}"; do
  case "${flags[$i]}" in
    -limgui|-limgui_impl_sdl2|-limgui_impl_opengl3)
      flags[$i]="$imgui_prefix/lib/lib${flags[$i]#-l}.a" ;;
    -lSDL2)
      flags[$i]="$sdl2_prefix/lib/libSDL2.a" ;;
  esac
done
xcrun clang++ -std=c++17 -arch "$(uname -m)" -isysroot "$(xcrun --show-sdk-path)" \
  imgui-consumer.cpp -o imgui-consumer "${flags[@]}"
./imgui-consumer
```

`--static` adds private dependencies. It does not force archive selection by itself.
The array replaces graphics `-l` flags in place with explicit `.a` paths, preserving pkgconf's dependency and framework order.
Do not define `RAYGUI_IMPLEMENTATION` in your application when linking the installed `libraygui.a`.

macOS system frameworks and system runtime libraries remain dynamic. This tap does not promise a fully static macOS executable.
Raylib enables JPEG decoding while keeping its normal graphics, audio, image and model features.
SDL2 retains rendering, Metal, controllers and other normal native capabilities.

### GStreamer SDK

The universal SDK includes ARM and Intel slices in its static archives.
Its headers and link metadata are under:

```text
/Library/Frameworks/GStreamer.framework/Versions/1.0/include/
/Library/Frameworks/GStreamer.framework/Versions/1.0/lib/
/Library/Frameworks/GStreamer.framework/Versions/1.0/lib/pkgconfig/
/Library/Frameworks/GStreamer.framework/Versions/1.0/lib/gstreamer-1.0/
```

Linking `-framework GStreamer` uses the shared framework.
Static plugins need their archives and registration through `GST_PLUGIN_STATIC_DECLARE` and `GST_PLUGIN_STATIC_REGISTER`.
Some plugins depend on libraries that are only shared. Review the dependencies of the plugins your application uses.
Do not mix libraries from this SDK with the official Homebrew GStreamer formula in one application.
Static LGPL/GPL linkage also carries upstream licensing and relinking obligations.

Development uninstall preserves runtime-owned files, links, roots and protected ancestors.
It removes only genuinely empty unprotected directories, not directory contents or metadata. The regression checks this without uninstalling a host SDK.

## Aseprite: build on your host

The cask installs a finished app. It does not compile Aseprite.

For version 1.3.18.6:

1. Use the [complete-source release ZIP](https://github.com/aseprite/aseprite/releases/tag/v1.3.18.6), not GitHub's generic source ZIP.
2. Use its matching [Skia SDK tag `m124-08a5439a6b`](https://github.com/aseprite/skia/releases/tag/m124-08a5439a6b).
   Keep the full SDK, including headers, auxiliary archives and ICU data.
3. Install CMake and Ninja, and use Xcode's native macOS SDK.
4. Follow that release's [build instructions](https://github.com/aseprite/aseprite/blob/v1.3.18.6/INSTALL.md), or run its interactive `build.sh`.
5. Build `arm64` on the ARM Mac and `x86_64` on the Intel Mac.

The normal manual build places the app at `build/bin/Aseprite.app` inside the source tree.
From that source tree, create the local archive:

```sh
version=1.3.18.6
arch=$(uname -m)
ditto -c -k --sequesterRsrc --keepParent build/bin/Aseprite.app \
  "$HOME/Downloads/Aseprite-$version-$arch.zip"
brew install --cask 0xsct/tap/sct-aseprite
```

If your upstream build uses another output directory, package its actual `Aseprite.app` instead.
The ZIP must have `Aseprite.app` at its root. Each Mac supplies its own native build.
Local builds have different bytes, so this one local-only cask uses `sha256 :no_check`.
All remote casks use literal SHA-256 checksums.

Build the next local version before updating this cask or running its upgrade.
No Aseprite binary, ZIP or app is uploaded to GitHub. Generic Ruby syntax checks may read the cask, but no Aseprite build, fetch or installation job runs.

## Your Python

Nothing changes pyenv or your default Python 3.14.3.
The current LLVM/LLDB recipes separately declare Homebrew `python@3.15`.
LLDB's embedded Python and compiled Python bindings use that interpreter.
Do not import its Python 3.15 extension into pyenv Python 3.14.
Using LLDB's command-line tool does not require changing your pyenv default.

## GitHub builds and publication

A local commit alone does not start GitHub Actions. Pushing changes does.

```mermaid
flowchart LR
    Push[Your commit and push] --> PR[Open or update pull request]
    PR --> Tests[Syntax, downloads and native builds]
    Tests --> Review[Review passing checks]
    Review --> Publish[Run publish with PR number and reviewed SHA]
    Publish --> Releases[GitHub Releases bottles and bottle metadata]
```

- `tests.yml` runs on pull requests and pushes to `main`.
- Graphics formulae build on native ARM macOS 27 and Intel macOS 26 runners.
- `llvm-sct` and `lldb-sct` build only on Intel.
- Casks use existing upstream binaries; they do not have bottle builds.
- Remote cask downloads are checksum-checked. Local Aseprite archives are not fetched in CI.
- Tests cover complete multi-commit pushes, initial pushes, deleted packages, platform selection, bottle contents and shared SDK ownership.

The native builder uses canonical dependency identities to build selected tap libraries before their dependents.
It first installs each selected formula's build/test dependency closure outside bottle mode, allowing missing Intel core dependencies to build from source.
It then source-builds that tap formula with `--build-bottle`, runs `brew test`, and creates its standard `brew bottle --json` payload.
Every selected native archive/JSON pair must pass identity, version, filename and hash checks before the job succeeds.
Only reviewed tap bottles are uploaded; core dependencies are installed but never bottled or published here.
Homebrew's separate eligible affected-dependent tests still run.
The clean-root builder requires GitHub Actions, this complete repository identity and matching native architecture.
It removes a preinstalled selected tap root only in that ephemeral CI job, never as a local maintenance command.

After review, open **Actions → brew pr-pull → Run workflow**. Supply the PR number and the exact reviewed head SHA.
The publisher checks the selected run and attempt, successful native jobs, package versions, expected architectures and actual archive hashes before upload.
It rejects stale heads, failed reruns and incomplete bottle sets.

The standard publisher needs permission to push generated bottle metadata to `main`.
This implementation refuses protected or unreadable branch policy before upload. It never changes branch protection or bypasses it.
The manually triggered workflow creates Homebrew's bottle metadata commit. The assistant does not run publication, commit or push your code.
Source review and normal user commits remain yours.

LLVM retains the complete upstream build, including PGO and all standard components.
It may need more RAM or disk than a standard hosted Intel runner provides. No components are removed to hide a build failure.
GitHub publication and pushing metadata are not one atomic operation; a late push failure can leave published assets without an updated formula.

## Maintenance

- Update the upstream URL/version and exact downloaded SHA-256 together.
- Use `revision` when a same-version change requires rebuilding an installed package.
- Rebuild static dependents when their dependency change requires it.
- Keep both GStreamer SDK casks on the same release.
- Review Chromium's application version at the source commit for each new snapshot position.
- Keep SDL2 and SDL3 livecheck filters within their own major release families.
- Keep LLVM/LLDB adaptations synchronized with their recorded official core source, including required patches and tests.
- `brew livecheck` reports upstream versions. This tap does not silently auto-bump packages.
- Dependabot checks GitHub Action pins weekly. Package updates stay reviewed.

Local check commands use Homebrew's Ruby, not macOS's older system Ruby:

```sh
brew style Formula/*.rb Casks/*.rb .github/scripts/*.rb
brew readall --aliases --os=all --arch=all 0xsct/tap
brew ruby .github/scripts/gstreamer_development_test.rb
```

The workflow installs its pinned Minitest dependency in runner-local storage for helper tests.
No Python environment change is needed.

## Limits and sources

Homebrew no longer maintains new Intel macOS bottles and plans to remove Intel support in or after September 2027.
This tap does not extend Homebrew's own support window.
Chromium snapshots are development snapshots, not stable Chrome releases, and do not auto-update.
Upstream signing/Gatekeeper failures are not repaired by putting a cask in another tap.

- [Homebrew taps](https://docs.brew.sh/Taps)
- [Create and maintain a tap](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap)
- [Formula cookbook](https://docs.brew.sh/Formula-Cookbook)
- [Cask cookbook](https://docs.brew.sh/Cask-Cookbook)
- [Homebrew support tiers](https://docs.brew.sh/Support-Tiers)
- [GitHub hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [GStreamer SDK downloads](https://gstreamer.freedesktop.org/download/#macos)

The repository's MIT license covers original tap code. Imported Homebrew material retains its BSD-2-Clause notice under `LICENSES/`.
Each installed package keeps its own upstream software license.
