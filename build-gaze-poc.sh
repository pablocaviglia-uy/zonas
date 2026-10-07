#!/usr/bin/env bash
# Isolated signed bundle; the installed stable app and its login item survive.
set -euo pipefail
POC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$POC_ROOT"
if [[ "${1:-}" != "" && "${1:-}" != "-r" && "${1:-}" != "-i" ]]; then
    echo "usage: ./build-gaze-poc.sh [-i|-r]" >&2; exit 2
fi
POC_SIGN_ID="${ZONAS_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/^.*"\(.*\)"$/\1/p' | grep -m1 -E '^(Zonas Dev|Apple Development|Developer ID Application)')}"
[[ -n "$POC_SIGN_ID" ]] || { echo "A real signing identity is required." >&2; exit 1; }
ZONAS_SIGN_ID="$POC_SIGN_ID" ./build.sh release
POC_BIN="$(swift build -c release --show-bin-path)"
POC_APP="$POC_BIN/Zonas Gaze POC.app"
rm -rf "$POC_APP"
ditto "$POC_BIN/Zonas.app" "$POC_APP"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier uy.com.fcstudio.zonas.gaze-poc' "$POC_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Zonas Gaze POC' "$POC_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Zonas Gaze POC' "$POC_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :ZonasGazePOC bool true' "$POC_APP/Contents/Info.plist"
codesign --force --options runtime --timestamp --entitlements Resources/Zonas.entitlements --sign "$POC_SIGN_ID" "$POC_APP"
codesign --verify --strict "$POC_APP"
echo "ready: $POC_APP"
if [[ "${1:-}" == "-r" || "${1:-}" == "-i" ]]; then
    # Both variants use the same hotkeys, so only one may run at a time.
    # Keep /Applications/Zonas.app untouched for a one-click return to stable.
    pkill -x Zonas 2>/dev/null || true
    for _ in $(seq 1 20); do pgrep -x Zonas >/dev/null || break; sleep 0.1; done
    rm -rf '/Applications/Zonas Gaze POC.app'
    ditto "$POC_APP" '/Applications/Zonas Gaze POC.app'
    if [[ "${1:-}" == "-r" ]]; then open '/Applications/Zonas Gaze POC.app'; fi
    echo "POC installed; stable /Applications/Zonas.app preserved"
fi
