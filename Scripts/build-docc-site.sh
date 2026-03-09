#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="$ROOT_DIR/DerivedData"
ARCHIVE_PATH="$DERIVED_DATA_PATH/Build/Products/Debug/Loom.doccarchive"
OUTPUT_PATH="$ROOT_DIR/docs"
HOSTING_BASE_PATH="${DOCC_HOSTING_BASE_PATH:-/Loom}"

rm -rf "$DERIVED_DATA_PATH" "$OUTPUT_PATH"

xcodebuild docbuild \
  -scheme Loom \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO

if [[ ! -d "$ARCHIVE_PATH" ]]; then
  echo "Expected DocC archive at '$ARCHIVE_PATH' but it was not produced." >&2
  exit 1
fi

xcrun docc process-archive transform-for-static-hosting \
  "$ARCHIVE_PATH" \
  --output-path "$OUTPUT_PATH" \
  --hosting-base-path "$HOSTING_BASE_PATH"

touch "$OUTPUT_PATH/.nojekyll"
