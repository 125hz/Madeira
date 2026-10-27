#!/usr/bin/env bash
set -euo pipefail
xcode=$(xcodebuild -version)
sdk=$(xcrun --sdk iphoneos --show-sdk-version)
compiler=$(xcrun clang --version)
key=$( { printf '%s\n' "$xcode" "$sdk" "$compiler"; uname -sm; env | LC_ALL=C sort | awk -F= '$1 ~ /^(CFLAGS|CXXFLAGS|LDFLAGS|CONFIGURATION|MADEIRA_MOLTENVK|ImageOS|ImageVersion)$/'; } | shasum -a 256 | cut -c1-20)
if [[ -n "${MADEIRA_PLANNED_SDK:-}" && "$key" != "$MADEIRA_PLANNED_SDK" ]]; then
  echo "ERROR: this runner's build inputs differ from the planned IPA key" >&2
  exit 1
fi
echo "key=$key" >> "$GITHUB_OUTPUT"
