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
#   ./build.sh release -u universal (arm64 + x86_64) — what release.sh ships
#
set -euo pipefail

BUNDLE_ID="uy.com.fcstudio.zonas"

# The parser is NOT positional. When it was, `./build.sh -r` —the most obvious
# way to ask for "install it for me"— died with `Missing value for '-c
# <configuration>'`, because `-r` landed in the configuration variable.
CONFIG=""; RUN=""; UNIVERSAL=""
for arg in "$@"; do
    case "$arg" in
        -r|--run)        RUN="-r" ;;
        -u|--universal)  UNIVERSAL="-u" ;;
        debug|release)   CONFIG="$arg" ;;
        *) echo "usage: ./build.sh [debug|release] [-r] [-u]" >&2; exit 2 ;;
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

# Every `swift build` goes through here so that release.sh can send its build to
# a scratch directory of its own (ZONAS_SCRATCH). That is not tidiness: a
# cross-compiled x86_64 build and the everyday native build share one llbuild
# database, and mixing them poisons it. Measured on Swift 6.3.3: right after the
# first `--arch x86_64` build, three consecutive plain `swift build -c release`
# died with `command .../x86_64-apple-macosx/release/swift-version-<hash>.txt
# not registered` before the tree healed by itself. A separate scratch path
# means the universal build for a release can never do that to the tree you
# develop in.
#
# A function and not an array because /bin/bash here is 3.2.57, where expanding
# an empty array under `set -u` is a fatal error.
compilar() {
    if [[ -n "${ZONAS_SCRATCH:-}" ]]; then
        swift build -c "$CONFIG" --scratch-path "$ZONAS_SCRATCH" "$@"
    else
        swift build -c "$CONFIG" "$@"
    fi
}

compilar
BIN="$(compilar --show-bin-path)"
APP="$BIN/Zonas.app"
EXEC="$APP/Contents/MacOS/Zonas"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# ---------------------------------------------------------------- architecture
#
# Day to day this builds for this machine only: waiting on an x86_64 slice that
# nobody here will ever execute is time thrown away. What gets published is the
# opposite case — an arm64-only bundle does not launch at all on an Intel Mac,
# because Rosetta translates Intel→ARM and never the other way round, so for
# those machines the app simply does not exist.
#
# Two builds plus lipo, and NOT `--arch arm64 --arch x86_64`. The multi-arch
# form works and even runs lipo for you, but passing two --arch silently
# switches SwiftPM to the Swift Build backend and starts a fresh .build/apple/
# tree that shares nothing with anything else: ~168 MB of objects for a 4 second
# saving.
if [[ -n "$UNIVERSAL" ]]; then
    compilar --arch x86_64
    BIN_X86="$(compilar --arch x86_64 --show-bin-path)"
    # lipo BEFORE codesign, never after: the signature is stored per slice, and
    # gluing signed slices together afterwards yields a bundle that fails to
    # verify.
    lipo -create -output "$EXEC" "$BIN/Zonas" "$BIN_X86/Zonas"
else
    cp "$BIN/Zonas" "$EXEC"
fi
echo "archs: $(lipo -archs "$EXEC")"

cp Resources/Info.plist "$APP/Contents/Info.plist"

# The icon goes in BEFORE signing: `codesign` seals the contents of Resources/,
# and putting it in afterwards would invalidate the signature.
[[ -f Resources/Zonas.icns ]] && cp Resources/Zonas.icns "$APP/Contents/Resources/"

# CFBundleVersion from git. Pinned at 1, LaunchServices caches the old icon and
# there is no way to tell which build is installed. The `|| echo 0` is not
# paranoia: in a repo without a single commit, `git rev-list` fails with exit 128.
BUILD_N="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_N" "$APP/Contents/Info.plist" >/dev/null

# ------------------------------------------------------------------- rpath
#
# The linker leaves behind an rpath pointing at the toolchain that did the
# compiling — on this machine
# `/Applications/Xcode-26.6.0.app/.../XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx`.
# Nothing needs it: `otool -L` resolves every single dylib by absolute path to
# /usr/lib or /System/Library. What it does do is travel inside the binary of a
# public release, leaking the developer's local paths, and sit there as a
# landmine for the day SwiftPM decides to resolve something through @rpath.
#
# It has to be deleted BEFORE signing — install_name_tool says as much, warning
# on stderr that the change invalidates the signature. That warning is expected
# here (the signature it invalidates is the linker's ad-hoc one, and the real
# one is applied below), which is why stderr is dropped; a genuine failure still
# stops the script through `set -e`.
RPATHS_AJENOS="$(otool -l "$EXEC" \
    | awk '/^ *cmd LC_RPATH$/{f=1;next} f&&/^ *path /{print $2;f=0}' \
    | sort -u | grep -v -E '^(@|/usr/|/System/)' || true)"
if [[ -n "$RPATHS_AJENOS" ]]; then
    while IFS= read -r rpath; do
        install_name_tool -delete_rpath "$rpath" "$EXEC" 2>/dev/null
        echo "rpath stripped: $rpath"
    done <<< "$RPATHS_AJENOS"
fi

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

# `--options runtime` turns on the hardened runtime, and it is here rather than
# only in release.sh so that what gets debugged is what gets shipped. It is a
# hard requirement for notarization —the notary rejects anything without it—
# and it costs this app nothing: what it forbids is JIT, writable-executable
# memory, DYLD_* injection and loading code signed by another team, none of
# which happens here (`otool -L` lists nothing but Apple's own dylibs).
#
# It needs NO entitlement. The event tap and the Accessibility API are governed
# by TCC at runtime, not by entitlements; there has never been an accessibility
# entitlement for third-party apps, and `NSAccessibilityUsageDescription` is not
# a real key either — grep tccd and neither string is in it. Verified on this
# machine: with the flag on, AXIsProcessTrusted() still returns YES and the tap
# still comes up, and the designated requirement printed below is byte for byte
# the one produced without it. That last part is what matters: turning the
# hardened runtime on does not break a permission already granted.
OPCIONES_FIRMA="runtime"

# The one thing the hardened runtime takes away is attaching lldb, which needs
# `com.apple.security.get-task-allow`. That entitlement can never ship: the
# notary rejects any build carrying it, by name. Hence a separate file and an
# explicit opt-in, never a default:
#   ZONAS_DEBUG_ENTITLEMENTS=1 ./build.sh -r
ENTITLEMENTS=""
if [[ -n "${ZONAS_DEBUG_ENTITLEMENTS:-}" ]]; then
    ENTITLEMENTS="$RAIZ/Resources/Zonas-debug.entitlements"
    echo "WARNING: signing with get-task-allow. This build can NOT be notarized."
fi

firmar() {  # $@ = the arguments that differ between the two branches
    if [[ -n "$ENTITLEMENTS" ]]; then
        codesign --options "$OPCIONES_FIRMA" --entitlements "$ENTITLEMENTS" "$@" "$APP"
    else
        codesign --options "$OPCIONES_FIRMA" "$@" "$APP"
    fi
}

if [[ -n "$ID" ]]; then
    # `--timestamp` (with a secure timestamp), NOT `--timestamp=none`. Without
    # the timestamp, the day the certificate expires the signature stops
    # validating and Accessibility permission breaks again, with no apparent
    # cause. With it, the signature still holds after expiry because there is
    # proof that it was signed while the certificate was still valid.
    firmar --force --timestamp --sign "$ID"
    echo "signature: $ID"
else
    # No stable identity: sign ad-hoc but pin the designated requirement by
    # hand, because otherwise it would be the cdhash and we would be back to
    # the same problem.
    #
    # It is a development patch and nothing more: the requirement is weak —any
    # app declaring this bundle id satisfies it— and Apple makes no promise that
    # TCC will honor it instead of falling back to the cdhash. Never to ship.
    firmar --force --timestamp=none --sign - \
        --identifier "$BUNDLE_ID" \
        -r="designated => identifier \"$BUNDLE_ID\""
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
