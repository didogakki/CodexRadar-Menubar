#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-"$ROOT_DIR/build/preview-renders"}"
BINARY_PATH="$ROOT_DIR/build/render-preview-states"
HOST_ARCH="$(uname -m)"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"

mkdir -p "$OUTPUT_DIR" "$ROOT_DIR/build"

swiftc -DDEBUG -parse-as-library \
  -sdk "$SDKROOT" \
  -target "$HOST_ARCH-apple-macos13.0" \
  "$ROOT_DIR"/Sources/Model/*.swift \
  "$ROOT_DIR"/Sources/Service/*.swift \
  "$ROOT_DIR"/Sources/ViewModel/*.swift \
  "$ROOT_DIR"/Sources/Support/*.swift \
  "$ROOT_DIR"/Sources/Views/*.swift \
  "$ROOT_DIR"/Tools/RenderPreviewStates.swift \
  -o "$BINARY_PATH"

"$BINARY_PATH" "$OUTPUT_DIR"

if command -v magick >/dev/null 2>&1; then
  magick -size 1098x965 xc:'#1F1F20' \
    "$OUTPUT_DIR/success.png" -geometry +18+18 -composite \
    "$OUTPUT_DIR/loading-initial.png" -geometry +384+18 -composite \
    "$OUTPUT_DIR/loading-refresh.png" -geometry +750+18 -composite \
    "$OUTPUT_DIR/error-initial.png" -geometry +18+518 -composite \
    "$OUTPUT_DIR/error-cached.png" -geometry +384+518 -composite \
    "$OUTPUT_DIR/comparison.png"
  echo "$OUTPUT_DIR/comparison.png"
else
  echo "ImageMagick not found; skipped comparison.png"
fi
