#!/usr/bin/env bash
set -euo pipefail

# Run the plugin tests with a disposable Godot project and a known Web preset.
# No editor configuration or export presets in the checkout are changed.
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NODE_BIN="${NODE_BIN:-node}"
GODOT_BIN="${GODOT_BIN:-godot}"
if ! command -v "$NODE_BIN" >/dev/null 2>&1; then
    echo "Node.js 22+ is required. Set NODE_BIN to its executable path." >&2
    exit 1
fi
if ! command -v "$GODOT_BIN" >/dev/null 2>&1; then
    if [ "$GODOT_BIN" = godot ] && [ -x /Applications/Godot.app/Contents/MacOS/Godot ]; then
        GODOT_BIN=/Applications/Godot.app/Contents/MacOS/Godot
    else
        echo "Godot matching support-matrix.json is required. Set GODOT_BIN to its executable path." >&2
        exit 1
    fi
fi
NODE_BIN="$(command -v "$NODE_BIN")"
GODOT_BIN="$(command -v "$GODOT_BIN")"
# GDScript contract tests also invoke Node directly.
export PATH="$(dirname "$NODE_BIN"):$PATH"

cd "$PROJECT_DIR"
"$NODE_BIN" --test test/*.test.mjs

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/godot-minigame-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/project" "$TEST_DIR/logs"
for source in addons assets scenes scripts test project.godot icon.svg support-matrix.json; do
    cp -R "$PROJECT_DIR/$source" "$TEST_DIR/project/"
done
cp "$PROJECT_DIR/test/fixtures/web_export_presets.cfg" "$TEST_DIR/project/export_presets.cfg"

run_godot() {
    local name="$1"
    shift
    if ! "$GODOT_BIN" --headless --log-file "$TEST_DIR/logs/$name.engine.log" \
        --path "$TEST_DIR/project" "$@" > "$TEST_DIR/logs/$name.log" 2>&1; then
        cat "$TEST_DIR/logs/$name.log" >&2
        return 1
    fi
    if grep -q '^SCRIPT ERROR:' "$TEST_DIR/logs/$name.log"; then
        cat "$TEST_DIR/logs/$name.log" >&2
        return 1
    fi
    echo "PASS $name"
}

run_godot import --import --quit
for test_file in "$TEST_DIR"/project/test/*_test.gd; do
    run_godot "$(basename "$test_file")" --script "res://test/$(basename "$test_file")"
done
