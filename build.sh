#!/usr/bin/env bash
#
# Builds and assembles the .app.
#
# SwiftPM produces a loose executable, but macOS will not grant Accessibility
# permission to a bare binary: it needs a bundle with an Info.plist and a
# signature. This is what builds that wrapper.
#
#   ./build.sh            builds in debug and leaves the .app
#   ./build.sh release    same but optimized
#   ./build.sh -r         builds release, installs in /Applications and opens it
#   ./build.sh debug -r   forces debug and installs it all the same
#
set -euo pipefail

BUNDLE_ID="uy.com.fcstudio.zonas"

# The parser is NOT positional. When it was, `./build.sh -r` —the most obvious
# way to ask for "install it for me"— died with `Missing value for '-c
# <configuration>'`, because `-r` landed in the configuration variable.
CONFIG=""; RUN=""
for arg in "$@"; do
    case "$arg" in
        -r|--run)       RUN="-r" ;;
        debug|release)  CONFIG="$arg" ;;
        *) echo "usage: ./build.sh [debug|release] [-r]" >&2; exit 2 ;;
    esac
done

# The default is split in two on purpose: what gets built just to look at can be
# debug and it makes no difference, but what gets copied to /Applications and is
# going to spend all day hanging off the mouse goes optimized, unless explicitly
# asked otherwise.
if [[ -z "$CONFIG" ]]; then
    if [[ -n "$RUN" ]]; then CONFIG="release"; else CONFIG="debug"; fi
fi

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$RAIZ"
echo "config: $CONFIG"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
APP="$BIN/Zonas.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Zonas" "$APP/Contents/MacOS/Zonas"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# The icon goes in BEFORE signing: `codesign` seals the contents of Resources/,
# and putting it in afterwards would invalidate the signature.
[[ -f Resources/Zonas.icns ]] && cp Resources/Zonas.icns "$APP/Contents/Resources/"

# CFBundleVersion from git. Pinned at 1, LaunchServices caches the old icon and
# there is no way to tell which build is installed. The `|| echo 0` is not
# paranoia: in a repo without a single commit, `git rev-list` fails with exit 128.
BUILD_N="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_N" "$APP/Contents/Info.plist" >/dev/null

# ----------------------------------------------------------------- signature
#
# Accessibility permission is not granted to "the app": it is granted to a
# SIGNATURE. Next to the toggle, TCC stores the code requirement that the app
# satisfied at the moment permission was granted, and it checks that same
# requirement again every time the app asks. With an ad-hoc signature that
# requirement is `cdhash H"..."` —the hash of the binary itself— and
# `swift build` produces a different binary on every run, even when compiling
# the same source from the same path.
#
# Hence the most bewildering symptom in this project: the toggle is still on in
# Settings, but AXIsProcessTrusted() returns false forever, because the code
# doing the asking is no longer the code that was said yes to.
#
# With a certificate of our own the requirement names the CERTIFICATE, which
# does not change between builds. How to create one: README, section
# "Development signing".
# To force a specific identity:  ZONAS_SIGN_ID="My Cert" ./build.sh
identidad_de_firma() {
    if [[ -n "${ZONAS_SIGN_ID:-}" ]]; then printf '%s' "$ZONAS_SIGN_ID"; return 0; fi
    security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/^.*"\(.*\)"$/\1/p' \
        | grep -m1 -E '^(Zonas Dev|Apple Development|Developer ID Application)'
}

ID="$(identidad_de_firma || true)"

if [[ -n "$ID" ]]; then
    # `--timestamp` (with a secure timestamp), NOT `--timestamp=none`. Without
    # the timestamp, the day the certificate expires the signature stops
    # validating and Accessibility permission breaks again, with no apparent
    # cause. With it, the signature still holds after expiry because there is
    # proof that it was signed while the certificate was still valid.
    codesign --force --timestamp --sign "$ID" "$APP"
    echo "signature: $ID"
else
    # No stable identity: sign ad-hoc but pin the designated requirement by
    # hand, because otherwise it would be the cdhash and we would be back to
    # the same problem.
    #
    # It is a development patch and nothing more: the requirement is weak —any
    # app declaring this bundle id satisfies it— and Apple makes no promise that
    # TCC will honor it instead of falling back to the cdhash. Never to ship.
    codesign --force --timestamp=none --sign - \
        --identifier "$BUNDLE_ID" \
        -r="designated => identifier \"$BUNDLE_ID\"" \
        "$APP"
    echo "signature: ad-hoc (no stable identity in the keychain)"
    echo "WARNING: Accessibility permission may be asked for again on every build."
fi

# The one thing to look at when the permission "gets lost": if this line changes
# from one build to the next, TCC will reject the app even if the toggle is on.
echo "requirement: $(codesign -d -r- "$APP" 2>/dev/null | sed -n 's/^#\{0,1\} *designated => //p')"

echo "done: $APP"

if [[ "$RUN" == "-r" ]]; then
    # pkill signals and returns without waiting. Without this wait there are two
    # live instances for an instant, both writing to the same log.
    pkill -x Zonas 2>/dev/null || true
    for _ in $(seq 1 20); do pgrep -x Zonas >/dev/null || break; sleep 0.1; done

    rm -rf /Applications/Zonas.app
    ditto "$APP" /Applications/Zonas.app     # preserves metadata better than cp -R
    open /Applications/Zonas.app
    echo "installed in /Applications and opened"
fi
