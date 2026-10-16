#!/usr/bin/env bash
# Store builds (docs/DARB-RELEASE.md): obfuscated Dart, symbols kept in build/symbols/ for Sentry (never shipped, never
# in git). Android needs android/key.properties (the upload key, on your machine only); iOS needs the ASC signing setup.
# Usage: ./build-release.sh android|ios   (iOS: on macOS with Xcode 26)
set -euo pipefail
cd "$(dirname "$0")"
FLAGS=(--release --obfuscate --split-debug-info=build/symbols)
case "${1:-}" in
  android)
    [ -f android/key.properties ] || { echo "android/key.properties is missing: refusing to build an upload with the debug key" >&2; exit 1; }
    flutter build appbundle "${FLAGS[@]}"
    echo "upload: build/app/outputs/bundle/release/app-release.aab" ;;
  ios)
    flutter build ipa "${FLAGS[@]}"
    echo "upload: build/ios/ipa/*.ipa (xcrun altool or Transporter)" ;;
  *) echo "usage: $0 android|ios" >&2; exit 2 ;;
esac
