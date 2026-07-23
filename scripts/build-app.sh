#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_APP="${1:-$ROOT_DIR/dist/Dictor.app}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

say() {
    printf 'Dictor: %s\n' "$*"
}

fail() {
    printf 'Dictor: %s\n' "$*" >&2
    exit 1
}

validate_output_app_path() {
    local output="$1"
    local parent base

    [[ -n "$output" ]] || fail "Output app path is empty."
    [[ "$output" == *.app ]] || fail "Output app path must end with .app."

    parent="$(dirname "$output")"
    base="$(basename "$output")"

    [[ "$base" != "." && "$base" != ".." ]] || fail "Output app path is not specific enough."
    [[ "$output" != "/" && "$parent" != "/" ]] || fail "Refusing to write directly under /."
    [[ "$output" != "$HOME" && "$parent" != "$HOME" ]] || fail "Refusing to replace the home directory."
    [[ "$output" != "/Applications" && "$parent" != "/Applications" ]] || fail "Refusing to write directly under /Applications."
    [[ "$output" != "$ROOT_DIR" && "$parent" != "$ROOT_DIR" ]] || fail "Refusing to replace the repository root."
}

running_under_rosetta() {
    [[ "$(/usr/bin/uname -m)" == "x86_64" ]] || return 1
    [[ "$(/usr/sbin/sysctl -in sysctl.proc_translated 2>/dev/null || true)" == "1" ]]
}

[[ "$(/usr/bin/uname -s)" == "Darwin" ]] || fail "macOS is required."
if running_under_rosetta; then
    say "Restarting the build natively for Apple Silicon..."
    exec /usr/bin/arch -arm64 /bin/bash "$0" "$@"
fi
[[ "$(/usr/bin/uname -m)" == "arm64" ]] || fail "An Apple Silicon Mac (M1 or newer) is required."
validate_output_app_path "$OUTPUT_APP"
command -v swift >/dev/null 2>&1 || fail "Swift is missing. Run: xcode-select --install"
command -v codesign >/dev/null 2>&1 || fail "codesign is missing. Run: xcode-select --install"

say "Building the release app..."
swift build -c release --package-path "$ROOT_DIR/swift"
BIN_DIR="$(swift build -c release --package-path "$ROOT_DIR/swift" --show-bin-path)"
BIN="$BIN_DIR/Dictor"
[[ -x "$BIN" ]] || fail "The Swift build did not produce $BIN"

STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dictor-build.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT
STAGE_APP="$STAGE_DIR/Dictor.app"

mkdir -p "$STAGE_APP/Contents/MacOS" "$STAGE_APP/Contents/Resources"
cp "$BIN" "$STAGE_APP/Contents/MacOS/Dictor"
cp "$ROOT_DIR/swift/Info.plist" "$STAGE_APP/Contents/Info.plist"
cp "$ROOT_DIR/swift/Resources/dictor-menubar.png" "$STAGE_APP/Contents/Resources/"
cp "$ROOT_DIR/swift/Resources/dictor-menubar@2x.png" "$STAGE_APP/Contents/Resources/"
cp "$ROOT_DIR/icon/Dictor.icns" "$STAGE_APP/Contents/Resources/Dictor.icns"
chmod 755 "$STAGE_APP/Contents/MacOS/Dictor"

SIGN_ARGS=(--force --deep --sign "$SIGN_IDENTITY" --options runtime
           --entitlements "$ROOT_DIR/entitlements.plist")
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    SIGN_ARGS+=(--timestamp=none)
else
    SIGN_ARGS+=(--timestamp)
fi

say "Signing the app..."
codesign "${SIGN_ARGS[@]}" "$STAGE_APP"
codesign --verify --deep --strict "$STAGE_APP"

mkdir -p "$(dirname "$OUTPUT_APP")"
rm -rf "$OUTPUT_APP"
mv "$STAGE_APP" "$OUTPUT_APP"
trap - EXIT
rm -rf "$STAGE_DIR"

say "Built $OUTPUT_APP"
