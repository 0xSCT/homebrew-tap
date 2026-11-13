# SCT Homebrew Tap Design

## Intent

Maintain `0xSCT/homebrew-tap` as a conventional Homebrew tap for missing packages and development variants that official packages do not supply. Support the user's ARM Macs running macOS 27 and newer and Intel Macs running macOS 26 and newer. Provide static graphics libraries for native application development.

## Agreed requirements

- Keep formulae in `Formula/` and casks in `Casks/`.
- Check official availability before duplicating a package.
- Keep existing ImGui SDL2/OpenGL3 backend modules and improve both supplied formulae.
- Provide native arm64 and x86_64 builds, not Rosetta builds.
- Run builds automatically after changes are pushed. Publish bottles only after review.
- Preserve the user's pyenv default Python `3.14.3` and existing pyenv configuration.
- Package Aseprite as a cask for an application built on the user's host. Do not publish Aseprite binaries.
- Build tap LLVM/LLDB bottles only for Intel in GitHub Actions; ARM users use the official Homebrew packages. Do not add Aseprite-specific build, download or installation jobs.
- Use Homebrew Ruby conventions, upstream versions, SHA-256 hashes and meaningful installation tests.
- Do not delete files or folders outside the workspace. Do not alter unrelated host installations during verification.
- Leave every repository change uncommitted; the user performs all commits and pushes. Do not execute publication workflows in this session.

## Official availability checked

The official API and current formula sources were checked on 2026-11-13.

| Requested package | Official status | Reason for tap entry |
| --- | --- | --- |
| Chromium | Cask exists; disabled for `fails_gatekeeper_check` | Maintain pinned native snapshot downloads, with the security limitation explicit |
| imgui | Missing | Install static core and existing SDL2/OpenGL3 backend archives |
| sdl2 | Alias for `sdl2-compat` | Provide actual upstream SDL2 as a static library |
| sdl3 | Available; default upstream build selects shared only | Provide a static-only variant |
| raygui | Missing; upstream is single-header | Provide header plus a precompiled static implementation |
| raylib | Available; contains static archive, JPEG loading disabled | Provide static-only build with JPEG decoding enabled |
| lldb | Available; current macOS bottles are ARM only | Use official LLDB on ARM; bottle the tap copy for Intel only |
| llvm | Available; current macOS bottles are ARM only | Use official LLVM on ARM; bottle the tap copy for Intel only |
| gstreamer-development | Cask exists; disabled for `fails_gatekeeper_check` | Maintain upstream universal development installer |
| gstreamer-runtime | Cask exists; disabled for `fails_gatekeeper_check` | Maintain matching universal runtime installer |
| aseprite | Missing | Install the user's own locally built application |

Homebrew treats all Intel macOS systems as Tier 3 and plans to remove Intel execution support in or after September 2027. This tap cannot override that upstream lifecycle.

## Selected approach

Use normal formula definitions and supported Homebrew install/test/bottle commands for native CI. Retain `test-bot` for syntax and eligible affected-dependent tests, and `pr-pull`/`pr-upload` for reviewed GitHub Releases publication. Do not add a package framework or an independent bottle uploader.

Alternatives considered:

- Official packages alone: insufficient for missing libraries, JPEG decoding, original static SDL2 and current Intel bottles.
- Automatically publishing every main-branch push: requires extra publication and stale-commit handling; the user chose reviewed publication instead.
- Aseprite source formula: conventional for compilation, but the user specifically chose a cask and host-side compilation.

## Package definitions

### Static graphics libraries

- `Formula/sdl2-static.rb`: upstream SDL2 `2.32.10`; `SDL_SHARED=OFF`, `SDL_STATIC=ON`; disable upstream test programs, not rendering, Metal, controllers, sensors or other normal library capabilities. Keg-only to avoid shadowing SDL2 compatibility packages. Use Homebrew's compiler and SDK defaults.
- `Formula/imgui.rb`: upstream `1.93.0`; retain `libimgui.a`, `libimgui_impl_sdl2.a`, `libimgui_impl_opengl3.a` and all three existing pkg-config module names. Declare `pkgconf` and the actual dependency `0xsct/tap/sdl2-static`. Use checked command output, archive indexing and usable static link ordering. Preserve existing headers and backend headers.
- `Formula/sdl3-static.rb`: upstream SDL3 `3.4.20`; `SDL_SHARED=OFF`, `SDL_STATIC=ON`; retain normal native capabilities. Keg-only. Install upstream CMake and pkg-config metadata.
- `Formula/raylib-static.rb`: upstream raylib `6.2`; static-only library; enable JPEG decoding using supported upstream configuration; retain normal native features. Disable examples/games and universal-library building, because each bottle is native. Keg-only to coexist with official raylib.
- `Formula/raygui.rb`: upstream raygui `5.0`; install `raygui.h`, compile exactly one `RAYGUI_IMPLEMENTATION` translation unit into `libraygui.a`, and provide pkg-config metadata using `0xsct/tap/raylib-static`.

Library tests must compile, link and run consumers against explicit installed `.a` archives. `pkg-config --static` supplies private dependencies but does not itself force archive selection. Tests must not accidentally link neighboring dylibs. Raylib's test must decode a real JPEG without opening a window. ImGui's test must exercise its core and resolve both backend archives. SDL tests use headless-compatible initialization and check retained API functionality.

Static here means static third-party graphics archives. macOS system frameworks and system runtime libraries remain dynamic. No fully static macOS executable is promised.

### LLVM and LLDB

Create `Formula/llvm-sct.rb` and `Formula/lldb-sct.rb` from the current official upstream recipes, preserving their compiler, runtime, debugger, Python and SDK behavior. Rename their formula classes and adapt formula-name-derived references without renaming upstream installed tools or directories. Remove foreign bottle metadata. Include any referenced upstream patch under `Patches/llvm/`; never leave an unresolved patch reference.

Use the distinct package names `llvm-sct` and `lldb-sct` and keep both keg-only, so they can coexist with official packages instead of sharing the same Cellar racks. Qualify LLDB's LLVM dependency and CMake lookup as `0xsct/tap/llvm-sct`, so it cannot silently build against official LLVM instead. Retain LLVM's installed static component archives. These entries provide development tools; LLDB's upstream public shared library is not represented as a static SDK.

Do not reduce upstream targets or supported tool components to fit CI without approval. Cap build parallelism to available memory. LLVM may exceed standard hosted-runner storage or memory; actual build output, not configuration alone, determines viability.

The current official recipes declare Homebrew `python@3.15`. Retaining that dependency does not change pyenv's default. LLDB's embedded interpreter and Python bindings use its declared Homebrew Python, not pyenv `3.14.3`. Document this explicitly; do not instruct the user to import a Python 3.15 extension into Python 3.14.

CI builds `llvm-sct` and `lldb-sct` only on Intel. ARM installation instructions use official `llvm` and `lldb`, which already supply ARM bottles and LLVM development archives. The tap recipes may retain source-build support on ARM, but no ARM compiler bottles are required or built.

### Upstream binary casks

Use distinct cask tokens to avoid globally colliding with existing official casks:

- `Casks/sct-chromium.rb`: pinned native ARM and Intel snapshot URLs and separate SHA-256 hashes. Track the application version plus architecture-specific snapshot positions. Chromium snapshots are best-effort development snapshots, not stable Chrome releases, and do not auto-update.
- `Casks/sct-gstreamer-runtime.rb`: upstream universal runtime installer, currently `1.28.8`.
- `Casks/sct-gstreamer-development.rb`: matching universal development installer, currently `1.28.8`; depends on the matching runtime cask.

Recheck upstream versions during implementation. Download and verify actual hashes rather than inventing checksums. Use normal `app`/`pkg` artifacts, versioning and livecheck stanzas. Keep runtime/development versions synchronized. Use exact package receipt IDs for installer uninstall metadata; do not add a zap that removes the entire shared GStreamer framework or user browser data.

Shared SDK protection includes runtime roots and protected-path ancestors. Directory cleanup may remove only genuinely empty unprotected development directories; it must never remove directory metadata or dangling runtime symlinks. The permanent ownership regression exercises the actual cleanup boundary under isolated fixtures.

GStreamer installs under `/Library/Frameworks/GStreamer.framework/Versions/1.0`, regardless of Homebrew prefix. Its universal SDK includes static archives and plugin metadata, but some plugin dependencies remain shared. Linking `-framework GStreamer` is dynamic. Document static plugin registration and warn against mixing SDK libraries with the official Homebrew GStreamer formula.

Do not strip quarantine, disable Gatekeeper, suppress checksum failures or automatically approve unsigned software. SHA-256 pins bytes; it does not provide Apple notarization. A custom tap does not repair upstream signing. Report actual security-assessment failures honestly and do not claim that a cask launches normally without observing it.

### Locally built Aseprite cask

Create `Casks/sct-aseprite.rb`, currently tracking upstream version `1.3.18.6`. The user builds the complete upstream source on the host with its matching Skia SDK. The cask does not compile and has no public binary download.

Proposed local artifact contract:

- The user creates `~/Downloads/Aseprite-<version>-<arch>.zip` with an `Aseprite.app` at the archive root.
- `<arch>` is `arm64` or `x86_64`, matching the host.
- The cask uses a local `file://` URL and the normal `app "Aseprite.app"` stanza.
- Because each host build produces different bytes, this local-artifact-only cask uses `sha256 :no_check`, with the reason documented. Remote casks always use literal checksums.
- No binary artifact, app bundle, bottle or local archive enters Git or CI artifact upload.
- Livecheck is skipped for the local artifact; the user updates the cask version together with the local build.

Document version-specific host build prerequisites and how to create the archive with `ditto`. The uploaded complete-source release ZIP is required; generic GitHub source ZIPs omit required submodules. Preserve pyenv while following upstream's build instructions. Host builds use pinned Aseprite/Skia inputs; do not substitute an incompatible Skia release.

Do not add Aseprite-specific build, download or installation jobs to GitHub Actions. Generic tap Ruby syntax checks may parse the definition. Actual installation depends on the user's host-built archive, not on a fake CI app.

## GitHub automation

Use `.github/workflows/tests.yml` and `.github/workflows/publish.yml` based on current Homebrew templates. Pin action versions by commit SHA, with version comments. Use Homebrew's recommended RuboCop configuration and a small Dependabot configuration for action updates.

Native runner matrix:

- ARM: `xcode-27`, currently macOS 27; verify runner architecture and OS before building.
- Intel: `macos-26-intel`, macOS 26; verify runner architecture and OS before building.

Trigger tests on pull requests and pushes to main. Pull request updates are the recommended maintenance path. Build changed graphics formulae on both native runners, and `llvm-sct`/`lldb-sct` only on Intel. Preserve eligible affected-dependent testing within that platform scope. Use the entire pushed commit range, not only the last commit. A first push with an all-zero previous SHA selects all platform-eligible current formulae. Deleted-only and cask-only changes must not invent formula builds or empty bottle publication.

Schedule selected tap formulae dependency-first using canonical full identities from Homebrew's native Formula/dependency API, but keep short archive and TestBot names. Do not use TestBot's Tier-1 selected-formula gate on Intel: its unbottled-dependency tracking can skip a formula before producing its bottle. Its full-name dependency matching and short-name bottle glob also prevent fixing both contracts by blindly qualifying its input.

Use `brew install --only-dependencies --include-test --build-from-source <qualified-selected-formula>` without `--build-bottle` to install the actual missing build/test closure. Homebrew's nested dependency installers can source-build unbottled core dependencies in dependency order and prune fulfilled macOS system dependencies. Then run `brew install --build-bottle --include-test <qualified-selected-formula>`, `brew test`, and `brew bottle --json --root-url=<reviewed-release-root>`. `--build-bottle` already forces source for the selected formula; it conflicts with a simultaneous `--build-from-source`. Do not use unsupported `reinstall --build-bottle`.

The clean-root builder must require `GITHUB_ACTIONS=true`, case-insensitive exact repository identity and matching native architecture before any uninstall or build. Remove a preinstalled selected tap root only in the ephemeral GitHub native job and before dependency bootstrap, preventing installed-root build-dependency pruning or reuse of a non-bottle receipt. Do not expose this as a local host maintenance path. Keep real eligible dependent tests in a separate `test-bot --only-formulae-dependents` phase with short testing/tested names. Remove inappropriate Tier-1 native setup/cleanup gates rather than suppressing failures.

Keep PR jobs read-only, including fork PRs. Never execute unreviewed PR Ruby with a write token or through `pull_request_target`. Artifact names include architecture, workflow run ID and run attempt: `bottles_arm64_<run-id>_<attempt>` and `bottles_x86_64_<run-id>_<attempt>`. Verify both native builds and their tests before allowing publication.

Publication uses manual `workflow_dispatch` with a PR number and required reviewed head SHA. Select the same newest `tests.yml` check suite that Homebrew selects, then require that exact run and attempt and both native jobs to be successful. Pass its run/attempt-specific artifact pattern to `brew pr-pull --no-upload --retain-bottle-dir --head-sha`. If a different newer run is selected during download, publication must fail rather than consume different artifacts. Recheck the selected run attempt and reviewed head after download, validate the actual bottle payloads, then run `brew pr-upload` once on those retained files. No second artifact selection occurs during upload. Serialize publication and never force-push.

Derive expected bottles from the reviewed commit's existing added/modified formulae and Homebrew package versions, including revisions. Graphics formulae require `arm64_golden_gate` and `tahoe` tarball/JSON pairs; `llvm-sct` and `lldb-sct` require only `tahoe`. Require every selected formula's native pair before native job success and artifact upload, not merely any archive/JSON in that architecture's output. Preserve Homebrew's canonical full-name JSON keys, short basenames and versioned release root URLs. Validate identity, version, allowed platform, filename and archive SHA-256 in every pair. Upload only reviewed selected tap pairs: dependency bootstrap never creates or publishes core bottles, and affected dependents that were only tested do not need bottles. Cask-only/deleted-only changes have an empty expected set. Compiler-only changes do not require an ARM artifact. Skip upload and archive attestation when no bottles are expected.

The no-extra-credentials default requires an unprotected `main` that permits the publisher's normal direct push. Before any upload, read the branch policy and reject protected branches, unavailable policy information or insufficient repository write permission. Do not change protections or configure a bypass. If the user requires enforced branch protection, that needs a separately approved publisher identity/policy rather than silently weakening protection. Repository policy could not be established without authenticated access during research.

Both `GITHUB_REPOSITORY` and the PR base repository's complete `full_name` must equal `0xSCT/homebrew-tap` case-insensitively. Reject different owners/repositories, malformed values, suffixes and whitespace; this is exact identity matching, not prefix or substring matching.

Do not add automatic upstream autobumping initially. `livecheck` plus explicit `brew bump-formula-pr`/cask updates keeps updates reviewed and synchronized without extra credentials or bots.

## Documentation and verification

Expand `README.md` with the package list, fully qualified installation commands, keg-only static linking examples, architecture/OS minimums, Python compatibility, local Aseprite build/install instructions, cask security limits and the PR/build/publish sequence. The repository MIT license covers tap definitions, not upstream software.

Verify reachable changes with Homebrew syntax/style/audit checks, source download hashes and actual native ARM consumer tests. Run native Intel and large compiler builds in CI, and report them as unverified until an actual run is observed. Test GitHub workflow structure and change-selection edge cases without downloading fake applications or uploading artifacts. Remove only throwaway files created inside this workspace.

## Evidence

- https://docs.brew.sh/Taps
- https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap
- https://docs.brew.sh/Formula-Cookbook
- https://docs.brew.sh/Cask-Cookbook
- https://docs.brew.sh/Support-Tiers
- https://formulae.brew.sh/api/formula.json
- https://github.com/Homebrew/brew/tree/main/.github/workflows
- https://docs.github.com/en/actions/reference/runners/github-hosted-runners
- https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md
- https://github.com/raysan5/raylib/blob/6.2/src/config.h
- https://gstreamer.freedesktop.org/download/#macos
- https://github.com/GStreamer/cerbero/tree/1.28.8
- https://www.chromium.org/getting-involved/download-chromium/
- https://github.com/aseprite/aseprite/blob/v1.3.18.6/INSTALL.md
- https://www.aseprite.org/faq/#can-i-redistribute-aseprite
