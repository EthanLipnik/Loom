#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="${TMPDIR:-/tmp}"
TMP_DIR="$(mktemp -d "$TMP_ROOT/loom-docc.XXXXXX")"
SYMBOLGRAPH_FILTER_DIR="$TMP_DIR/symbolgraph"
DUMP_STDOUT="$TMP_DIR/dump-symbol-graph.stdout"
DUMP_STDERR="$TMP_DIR/dump-symbol-graph.stderr"
OUTPUT_PATH="$ROOT_DIR/docs"
HOSTING_BASE_PATH="${DOCC_HOSTING_BASE_PATH:-Loom}"
HOSTING_BASE_PATH="${HOSTING_BASE_PATH#/}"

trap 'rm -rf "$TMP_DIR"' EXIT

rm -rf "$OUTPUT_PATH"
mkdir -p "$SYMBOLGRAPH_FILTER_DIR"

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

cp "$LOOM_SYMBOLGRAPH" "$SYMBOLGRAPH_FILTER_DIR/"
if [[ -f "$LOOM_CLOUDKIT_SYMBOLGRAPH" ]]; then
  cp "$LOOM_CLOUDKIT_SYMBOLGRAPH" "$SYMBOLGRAPH_FILTER_DIR/"
fi
if [[ -f "$LOOM_SHELL_SYMBOLGRAPH" ]]; then
  cp "$LOOM_SHELL_SYMBOLGRAPH" "$SYMBOLGRAPH_FILTER_DIR/"
else
  cat "$DUMP_STDOUT"
  cat "$DUMP_STDERR" >&2
  echo "Expected public LoomShell symbol graph at '$LOOM_SHELL_SYMBOLGRAPH' but it was not produced." >&2
  exit 1
fi

convert_catalog() {
  local catalog_path="$1"
  local display_name="$2"
  local bundle_identifier="$3"

  xcrun docc convert \
    "$catalog_path" \
    --additional-symbol-graph-dir "$SYMBOLGRAPH_FILTER_DIR" \
    --output-dir "$OUTPUT_PATH" \
    --transform-for-static-hosting \
    --hosting-base-path "$HOSTING_BASE_PATH" \
    --fallback-display-name "$display_name" \
    --fallback-bundle-identifier "$bundle_identifier"
}

convert_catalog "$ROOT_DIR/Sources/Loom/Loom.docc" Loom loom.Loom
convert_catalog "$ROOT_DIR/Sources/LoomShell/LoomShell.docc" LoomShell loom.LoomShell

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
