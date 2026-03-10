#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="${TMPDIR:-/tmp}"
TMP_DIR="$(mktemp -d "$TMP_ROOT/loom-docc.XXXXXX")"
LOOM_SYMBOLGRAPH_DIR="$TMP_DIR/loom-symbolgraph"
LOOM_KIT_SYMBOLGRAPH_DIR="$TMP_DIR/loomkit-symbolgraph"
LOOM_SHELL_SYMBOLGRAPH_DIR="$TMP_DIR/loomshell-symbolgraph"
LOOM_ARCHIVE="$TMP_DIR/Loom.doccarchive"
LOOM_KIT_ARCHIVE="$TMP_DIR/LoomKit.doccarchive"
LOOM_SHELL_ARCHIVE="$TMP_DIR/LoomShell.doccarchive"
LOOM_STATIC_DIR="$TMP_DIR/loom-static"
LOOM_KIT_STATIC_DIR="$TMP_DIR/loomkit-static"
LOOM_SHELL_STATIC_DIR="$TMP_DIR/loomshell-static"
DUMP_STDOUT="$TMP_DIR/dump-symbol-graph.stdout"
DUMP_STDERR="$TMP_DIR/dump-symbol-graph.stderr"
OUTPUT_PATH="$ROOT_DIR/docs"
HOSTING_BASE_PATH="${DOCC_HOSTING_BASE_PATH:-Loom}"
HOSTING_BASE_PATH="${HOSTING_BASE_PATH#/}"

trap 'rm -rf "$TMP_DIR"' EXIT

rm -rf "$OUTPUT_PATH"
mkdir -p "$LOOM_SYMBOLGRAPH_DIR" "$LOOM_KIT_SYMBOLGRAPH_DIR" "$LOOM_SHELL_SYMBOLGRAPH_DIR"

dump_exit=0
if ! swift package dump-symbol-graph --minimum-access-level public >"$DUMP_STDOUT" 2>"$DUMP_STDERR"; then
  dump_exit=$?
fi

SYMBOLGRAPH_DIR="$(sed -n 's/^Files written to //p' "$DUMP_STDOUT" | tail -n 1)"
if [[ -z "$SYMBOLGRAPH_DIR" ]]; then
  SYMBOLGRAPH_DIR="$(find "$ROOT_DIR/.build" -type d -name symbolgraph -print | head -n 1)"
fi
LOOM_SYMBOLGRAPH="$SYMBOLGRAPH_DIR/Loom.symbols.json"
LOOM_CLOUDKIT_SYMBOLGRAPH="$SYMBOLGRAPH_DIR/LoomCloudKit.symbols.json"
LOOM_KIT_SYMBOLGRAPH="$SYMBOLGRAPH_DIR/LoomKit.symbols.json"
LOOM_SHELL_SYMBOLGRAPH="$SYMBOLGRAPH_DIR/LoomShell.symbols.json"

if [[ ! -f "$LOOM_SYMBOLGRAPH" ]]; then
  cat "$DUMP_STDOUT"
  cat "$DUMP_STDERR" >&2
  echo "Expected public Loom symbol graph at '$LOOM_SYMBOLGRAPH' but it was not produced." >&2
  if (( dump_exit != 0 )); then
    exit "$dump_exit"
  fi
  exit 1
fi

if (( dump_exit != 0 )); then
  if grep -Eq "Failed to emit symbol graph for '.*Tests'" "$DUMP_STDERR"; then
    echo "Ignoring SwiftPM test-target symbol graph failure because the Loom public symbol graph was emitted." >&2
  else
    cat "$DUMP_STDOUT"
    cat "$DUMP_STDERR" >&2
    exit "$dump_exit"
  fi
fi

cp "$LOOM_SYMBOLGRAPH" "$LOOM_SYMBOLGRAPH_DIR/"
if [[ -f "$LOOM_CLOUDKIT_SYMBOLGRAPH" ]]; then
  cp "$LOOM_CLOUDKIT_SYMBOLGRAPH" "$LOOM_SYMBOLGRAPH_DIR/"
fi
if [[ -f "$LOOM_KIT_SYMBOLGRAPH" ]]; then
  cp "$LOOM_KIT_SYMBOLGRAPH" "$LOOM_KIT_SYMBOLGRAPH_DIR/"
else
  cat "$DUMP_STDOUT"
  cat "$DUMP_STDERR" >&2
  echo "Expected public LoomKit symbol graph at '$LOOM_KIT_SYMBOLGRAPH' but it was not produced." >&2
  exit 1
fi
if [[ -f "$LOOM_SHELL_SYMBOLGRAPH" ]]; then
  cp "$LOOM_SHELL_SYMBOLGRAPH" "$LOOM_SHELL_SYMBOLGRAPH_DIR/"
else
  cat "$DUMP_STDOUT"
  cat "$DUMP_STDERR" >&2
  echo "Expected public LoomShell symbol graph at '$LOOM_SHELL_SYMBOLGRAPH' but it was not produced." >&2
  exit 1
fi

copy_if_exists() {
  local source_path="$1"
  local destination_path="$2"

  if [[ -e "$source_path" ]]; then
    mkdir -p "$destination_path"
    rsync -a "$source_path" "$destination_path/"
  fi
}

xcrun docc convert \
  "$ROOT_DIR/Sources/Loom/Loom.docc" \
  --additional-symbol-graph-dir "$LOOM_SYMBOLGRAPH_DIR" \
  --output-dir "$LOOM_ARCHIVE" \
  --fallback-display-name Loom \
  --fallback-bundle-identifier loom.Loom \
  --enable-experimental-external-link-support

xcrun docc convert \
  "$ROOT_DIR/Sources/LoomKit/LoomKit.docc" \
  --additional-symbol-graph-dir "$LOOM_KIT_SYMBOLGRAPH_DIR" \
  --dependency "$LOOM_ARCHIVE" \
  --output-dir "$LOOM_KIT_ARCHIVE" \
  --fallback-display-name LoomKit \
  --fallback-bundle-identifier loom.LoomKit \
  --enable-experimental-external-link-support

# Build LoomShell against Loom as a DocC dependency so its imported Loom symbols
# resolve externally instead of overwriting Loom's authored landing pages.
xcrun docc convert \
  "$ROOT_DIR/Sources/LoomShell/LoomShell.docc" \
  --additional-symbol-graph-dir "$LOOM_SHELL_SYMBOLGRAPH_DIR" \
  --dependency "$LOOM_ARCHIVE" \
  --output-dir "$LOOM_SHELL_ARCHIVE" \
  --fallback-display-name LoomShell \
  --fallback-bundle-identifier loom.LoomShell \
  --enable-experimental-external-link-support

xcrun docc process-archive transform-for-static-hosting \
  "$LOOM_ARCHIVE" \
  --output-path "$LOOM_STATIC_DIR" \
  --hosting-base-path "$HOSTING_BASE_PATH"

xcrun docc process-archive transform-for-static-hosting \
  "$LOOM_KIT_ARCHIVE" \
  --output-path "$LOOM_KIT_STATIC_DIR" \
  --hosting-base-path "$HOSTING_BASE_PATH"

xcrun docc process-archive transform-for-static-hosting \
  "$LOOM_SHELL_ARCHIVE" \
  --output-path "$LOOM_SHELL_STATIC_DIR" \
  --hosting-base-path "$HOSTING_BASE_PATH"

rsync -a "$LOOM_STATIC_DIR/" "$OUTPUT_PATH/"
mkdir -p "$OUTPUT_PATH/data/documentation" "$OUTPUT_PATH/documentation"
rsync -a "$LOOM_KIT_STATIC_DIR/data/documentation/loomkit" "$OUTPUT_PATH/data/documentation/"
rsync -a "$LOOM_KIT_STATIC_DIR/data/documentation/loomkit.json" "$OUTPUT_PATH/data/documentation/"
rsync -a "$LOOM_KIT_STATIC_DIR/documentation/loomkit" "$OUTPUT_PATH/documentation/"
copy_if_exists "$LOOM_KIT_STATIC_DIR/downloads/loom.LoomKit" "$OUTPUT_PATH/downloads"
copy_if_exists "$LOOM_KIT_STATIC_DIR/images/loom.LoomKit" "$OUTPUT_PATH/images"
copy_if_exists "$LOOM_KIT_STATIC_DIR/videos/loom.LoomKit" "$OUTPUT_PATH/videos"
rsync -a "$LOOM_SHELL_STATIC_DIR/data/documentation/loomshell" "$OUTPUT_PATH/data/documentation/"
rsync -a "$LOOM_SHELL_STATIC_DIR/data/documentation/loomshell.json" "$OUTPUT_PATH/data/documentation/"
rsync -a "$LOOM_SHELL_STATIC_DIR/documentation/loomshell" "$OUTPUT_PATH/documentation/"
copy_if_exists "$LOOM_SHELL_STATIC_DIR/downloads/loom.LoomShell" "$OUTPUT_PATH/downloads"
copy_if_exists "$LOOM_SHELL_STATIC_DIR/images/loom.LoomShell" "$OUTPUT_PATH/images"
copy_if_exists "$LOOM_SHELL_STATIC_DIR/videos/loom.LoomShell" "$OUTPUT_PATH/videos"

mkdir -p "$OUTPUT_PATH/documentation/loomshell/build-a-shell-app-on-loom"
cat >"$OUTPUT_PATH/documentation/loomshell/build-a-shell-app-on-loom/index.html" <<'EOF'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta http-equiv="refresh" content="0; url=../buildashellapponloom/">
    <link rel="canonical" href="../buildashellapponloom/">
    <title>Redirecting…</title>
  </head>
  <body>
    <p><a href="../buildashellapponloom/">Redirecting to Build A Shell App On Loom…</a></p>
  </body>
</html>
EOF

touch "$OUTPUT_PATH/.nojekyll"
