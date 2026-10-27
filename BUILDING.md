# Building Madeira

Madeira is intended to be buildable from a clean clone with one command.

## Prerequisites

- macOS with a current Xcode installation and the iOS SDK
- Xcode command-line tools selected with `xcode-select`
- Homebrew
- Git
- Rust installed with [rustup](https://rustup.rs/)

The build script installs the remaining Homebrew packages, initializes all
submodules (including DXMT's nested header submodules), downloads the pinned compiler toolchains, builds the native iOS
libraries, downloads the official Microsoft Visual C++ x64 Redistributable,
extracts the required runtime DLLs locally, builds the Xcode project, and
packages the result. Microsoft runtime DLLs are never added to Git.
The pairing-library build installs the Rust iOS target and generates its crate notices.

Expect the first run to take several hours on a typical Mac: LLVM 15 is
compiled twice (macOS host tools, then the iOS target libraries), and FEX is
a large C++ codebase. Later runs reuse cached outputs and finish in minutes.

## Build an IPA

```sh
git clone --recurse-submodules https://github.com/willfaust/Madeira.git
cd Madeira
./tools/build-ipa.sh
```

The output is:

```text
dist/Madeira.ipa
```

The IPA is ad-hoc signed with Madeira's requested entitlements so that a
sideloading tool such as SideStore can re-sign it with the contributor's own
development identity.

The current native DXMT build targets iOS 18.0, so the packaged application
also uses iOS 18.0 as its effective deployment target.

## Re-running the build

Toolchains and expensive native build outputs are cached under their existing
ignored build directories. Re-running `./tools/build-ipa.sh` reconfigures the source builds and uses their incremental compile rules.
An existing archive alone does not skip these local source builds.

GitHub Actions runs once for each PR update, on pushes to main, and on manual
requests. Changes limited to docs/, README.md or BUILDING.md do not start an
automatic build. A newer run cancels an older run for the same PR or branch.

CI can reuse a completed IPA when the checked-out Git tree, runner platform,
Xcode/SDK/compiler identity, runner image and build flags match. The Git tree
includes component pins and build scripts. A reused IPA must pass the ZIP and
bundle-layout checks before upload. GitHub's branch and PR cache access rules
still apply; an unrelated branch's cache is not a shared artifact store.

On an IPA cache miss, the workflow builds the native stages in parallel. Their
cache keys include the relevant source pins, recipes and build environment.
Unrelated workflow edits do not invalidate LLVM or FEX. CI accepts a complete
restored FEX/DXMT output set; LLVM also checks its archive checksum list and
required headers. Its source-header cache does not need an LLVM Git checkout.
Local source builds keep their normal incremental path.

You can override parallelism with, for example:

```sh
JOBS=4 ./tools/build-ipa.sh
```

If you already have an official `vc_redist.x64.exe`, avoid the download with:

```sh
VC_REDIST_X64="$HOME/Downloads/vc_redist.x64.exe" ./tools/build-ipa.sh
```
