#!/bin/bash
# Compile focused playback input checks without the full app dependency build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/khua-playback-gestures.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT

xcrun swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Apps/Mac/UI/PlaybackScrollGesture.swift" \
  "$ROOT/Scripts/tests/playback_scroll_gesture.swift" \
  -o "$CHECK_DIR/playback-scroll-gesture-checks"
"$CHECK_DIR/playback-scroll-gesture-checks"

xcrun swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Apps/Mac/UI/PlaybackScrollGesture.swift" \
  "$ROOT/Apps/Mac/UI/PlaybackPinchGesture.swift" \
  "$ROOT/Scripts/tests/playback_pinch_gesture.swift" \
  -o "$CHECK_DIR/playback-pinch-gesture-checks"
"$CHECK_DIR/playback-pinch-gesture-checks"

xcrun swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Apps/Mac/UI/PlaybackGestureSeek.swift" \
  "$ROOT/Scripts/tests/playback_gesture_seek.swift" \
  -o "$CHECK_DIR/playback-gesture-seek-checks"
"$CHECK_DIR/playback-gesture-seek-checks"
