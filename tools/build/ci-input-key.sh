#!/usr/bin/env bash
set -euo pipefail
xcode=$(xcodebuild -version)
sdk=$(xcrun --sdk iphoneos --show-sdk-version)
compiler=$(xcrun clang --version)
repo_root=$(git rev-parse --show-toplevel)
rustc=$(cd "$repo_root/build/rppairing-ios" && rustc -vV)
fingerprint() { shasum -a 256 | cut -c1-20; }
flags() { env | LC_ALL=C sort | awk -F= -v pattern="$1" '$1 ~ pattern'; }
key=$( { printf '%s\n' "$xcode" "$sdk" "$compiler"; uname -sm; flags '^(CC|CXX|AR|RANLIB|CFLAGS|CXXFLAGS|CPPFLAGS|LDFLAGS|SDKROOT|MACOSX_DEPLOYMENT_TARGET|IPHONEOS_DEPLOYMENT_TARGET|ImageOS|ImageVersion)$'; } | fingerprint)
rust=$( { printf '%s\n' "$key" "$rustc"; flags '^(RUSTFLAGS|CARGO_ENCODED_RUSTFLAGS|RUSTUP_TOOLCHAIN)$'; } | fingerprint)
graphics=$( { printf '%s\n' "$key"; flags '^(DXMT_METAL_STD|MADEIRA_ONLY|MADEIRA_MSC_ROOT)$'; } | fingerprint)
ipa=$( { printf '%s\n' "$key" "$rust" "$graphics"; flags '^(CONFIGURATION|MADEIRA_MOLTENVK)$'; } | fingerprint)
if [[ -n "${MADEIRA_PLANNED_SDK:-}" && "$key" != "$MADEIRA_PLANNED_SDK" ]]; then
  echo "ERROR: this runner's build inputs differ from the planned IPA key" >&2
  exit 1
fi
if [[ -n "${MADEIRA_PLANNED_IPA:-}" && "$ipa" != "$MADEIRA_PLANNED_IPA" ]]; then
  echo "ERROR: this runner's app build inputs differ from the planned IPA key" >&2
  exit 1
fi
printf 'key=%s\nrust=%s\ngraphics=%s\nipa=%s\n' "$key" "$rust" "$graphics" "$ipa" >> "$GITHUB_OUTPUT"
