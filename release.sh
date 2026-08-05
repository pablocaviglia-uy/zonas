#!/usr/bin/env bash
#
# release.sh — turns the working tree into the one file a stranger can download
# and use: a universal, hardened, notarized and stapled .dmg.
#
#   ./release.sh 0.1.0             build, notarize, staple, verify
#   ./release.sh 0.1.0 --resume    pick up a run whose upload was left in flight
#
# One-time setup, on the owner's machine and nowhere else:
#
#   xcrun notarytool store-credentials zonas --team-id YY7SF272MV
#
# It asks for an Apple ID and an app-specific password and puts them in the
# keychain. NO credential is ever written into this file or read from the
# environment: everything goes through --keychain-profile. If you ever find
# yourself adding --apple-id or --password here, stop.
#
# What this script does NOT do: touch /Applications (it only reads the installed
# copy's signature, to compare), and publish anything. The last thing it prints
# is the git and gh commands to run by hand, because deciding that a build is
# THE release is not a script's call.
#
# ---------------------------------------------------------------------------
# Why a .dmg, when Rectangle, AeroSpace, Loop and Ice all publish a .zip
#
# Because those projects are installed by Homebrew or updated by Sparkle, and
# their .zip is almost never touched by a human. Zonas has neither yet, so the
# archive gets opened by a person, in ~/Downloads, with a double click — and
# that path runs the app under App Translocation. Measured on this machine, on
# macOS 26.6: the process ends up executing from a read-only random directory
# under /private/var/folders/.../AppTranslocation/. For this app in particular
# that is not cosmetic:
#
#   - LaunchAtLogin.isInstalledCopy tests for a /Applications/ prefix, so
#     "Launch at Login" would be greyed out forever with no explanation.
#   - the translocated path changes on every launch, so the Accessibility list
#     in System Settings fills up with entries pointing at paths that no longer
#     exist, and the permission has to be granted over and over.
#
# Dragging the bundle in the Finder is what cancels translocation. The .dmg,
# with its alias to /Applications sitting next to the app, is what makes that
# the obvious gesture. It costs 70 KB more than the .zip.
# ---------------------------------------------------------------------------
set -euo pipefail

BUNDLE_ID="uy.com.fcstudio.zonas"
PERFIL="zonas"

# Written out, not searched for. build.sh finds its identity with
# `security find-identity | grep -m1 -E '(Zonas Dev|Apple Development|Developer
# ID Application)'`, and -m1 takes the first line that MATCHES IN THE INPUT, not
# the first alternative of the pattern: the order of preference the regex seems
# to promise is fiction, the keychain's listing order decides. That is harmless
# for a development build and fatal here — the day an "Apple Development"
# certificate shows up (opening Xcode is enough), a release could be signed with
# it and the notary would answer "The binary is not signed with a valid
# Developer ID certificate" after the upload.
ID="Developer ID Application: Pablo Caviglia (YY7SF272MV)"
TEAM_ID="YY7SF272MV"

# The notary usually answers in one to five minutes; Apple's stated expectation
# is under fifteen. The timeout is not a deadline for Apple —when it expires the
# service keeps working— it is a deadline for this script's patience, and
# --resume is how the answer gets collected afterwards.
TIMEOUT="30m"

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$RAIZ"

DIST="$RAIZ/dist"
APP="$DIST/Zonas.app"

say()  { printf '\n==> %s\n' "$*"; }
paso() { printf '\n\033[1m--- %s\033[0m\n' "$*"; }

# Everything that goes wrong here goes wrong loudly, and says where to look.
# A release that half-happened is worse than one that did not: an unnotarized
# .dmg on a Releases page is a bug report from every single person who downloads
# it.
die() {
    printf '\n\033[1mFAILED\033[0m: %s\n' "$1" >&2
    shift
    # Piped through sed rather than printed straight: half of these arguments are
    # command output several lines long, and only indenting the first line of
    # each makes the reason and the evidence impossible to tell apart.
    for linea in "$@"; do printf '%s\n' "$linea" | sed 's/^/  /' >&2; done
    printf '\n' >&2
    exit 1
}

# --------------------------------------------------------------------- arguments
VERSION=""; RESUME=""
for arg in "$@"; do
    case "$arg" in
        --resume) RESUME="1" ;;
        -*) die "unknown option: $arg" "usage: ./release.sh <version> [--resume]" ;;
        *)  VERSION="$arg" ;;
    esac
done
[[ -n "$VERSION" ]] || die "no version given" \
    "usage: ./release.sh <version> [--resume]" \
    "example: ./release.sh 0.1.0"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version '$VERSION' is not X.Y.Z" \
    "The Homebrew livecheck strategy derives the cask version from the git tag" \
    "with /\\D*(.+)/, so 'v$VERSION' has to reduce to exactly this string."

DMG="$DIST/Zonas-$VERSION.dmg"

# ======================================================================== 1
paso "1/7  preflight"
#
# Every check here is cheap and every one of them fails a release that would
# otherwise die later, after a build and an upload. They are in order of how
# early they can be known, not of importance.

[[ "$(uname -s)" == "Darwin" ]] || die "this only runs on macOS"

security find-identity -v -p codesigning 2>/dev/null | grep -qF "$ID" \
    || die "the signing identity is not in the keychain: $ID" \
           "security find-identity -v -p codesigning   # to see what IS there" \
           "Without a Developer ID certificate there is nothing to notarize:" \
           "an ad-hoc or self-signed build is rejected by the notary service."

# The version lives in Info.plist, under git, and this script only confirms it.
# The alternative —passing the version in and having the script stamp it— makes
# the tag, the plist and the .dmg name three independent truths that drift.
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$RAIZ/Resources/Info.plist" 2>/dev/null || echo "")"
[[ "$PLIST_VERSION" == "$VERSION" ]] || die \
    "Resources/Info.plist says $PLIST_VERSION, you asked for $VERSION" \
    "The plist is the source of truth and it is under git. Edit the one line" \
    "BY HAND and commit it:" \
    "" \
    "  <key>CFBundleShortVersionString</key>" \
    "  <string>$VERSION</string>" \
    "" \
    "Do NOT use \`PlistBuddy -c Set\`, which this message used to recommend." \
    "It rewrites the whole file: it alphabetises every key and it DELETES the" \
    "XML comments, which for this plist means losing the note explaining why" \
    "LSUIElement is there. Measured, on the 0.1.0 -> 0.2.0 bump: one intended" \
    "line changed and fifteen unintended ones came with it. A project whose" \
    "thesis is that a writer must not eat your comments should not ship a" \
    "release step that does."

# A release built from uncommitted changes cannot be rebuilt from the tag, and
# the tag is the only thing anyone else can look at.
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    if [[ -z "${ZONAS_ALLOW_DIRTY:-}" ]]; then
        die "the working tree is dirty" \
            "$(git status --short | head -10)" \
            "" \
            "Commit first: the tag has to point at the code that was signed." \
            "To build a test .dmg anyway: ZONAS_ALLOW_DIRTY=1 ./release.sh $VERSION"
    fi
    say "WARNING: building from a dirty tree because ZONAS_ALLOW_DIRTY is set."
    say "         Do not publish this .dmg."
fi

# Deliberately a live call and not a keychain lookup: it proves the profile
# exists AND that the credentials in it still authenticate. An expired
# app-specific password fails exactly here, ten seconds in, instead of after the
# build and the upload.
say "checking the notarization credentials (this talks to Apple)…"
xcrun notarytool history --keychain-profile "$PERFIL" >/dev/null 2>&1 \
    || die "the '$PERFIL' keychain profile does not work" \
           "Create it once, answering with an app-specific password from" \
           "appleid.apple.com (NOT the Apple ID password):" \
           "" \
           "  xcrun notarytool store-credentials $PERFIL --team-id $TEAM_ID" \
           "" \
           "If it already exists, this is either an expired app-specific" \
           "password or no network. To see the real error:" \
           "  xcrun notarytool history --keychain-profile $PERFIL"

if [[ -n "$RESUME" ]]; then
    [[ -d "$APP" ]] || die "--resume with nothing to resume: $APP does not exist" \
        "Run it without --resume."
    say "resuming: keeping dist/ exactly as it is, nothing gets rebuilt"
else
    rm -rf "$DIST"
fi
mkdir -p "$DIST"

# ======================================================================== 2
paso "2/7  build and sign"
#
# The bundle is assembled by build.sh and not here, on purpose: there is one
# place that knows what a Zonas.app is made of —the Info.plist, the icon, the
# CFBundleVersion from git, the rpath the linker leaves behind, the signing
# flags— and a second copy of that knowledge in this file would drift the first
# time one of them changes.
#
# ZONAS_SCRATCH keeps this build out of .build/. That is not tidiness: the
# x86_64 slice and the everyday native build share one llbuild database, and
# right after the first cross build the next plain `swift build` can die with
# `swift-version-<hash>.txt not registered`. Releasing must not break the tree
# you develop in.
if [[ -n "$RESUME" ]]; then
    say "skipped (--resume)"
else
    ZONAS_SIGN_ID="$ID" ZONAS_SCRATCH="$RAIZ/.build-release" \
        "$RAIZ/build.sh" release -u

    BIN="$(swift build -c release --scratch-path "$RAIZ/.build-release" --show-bin-path)"
    [[ -d "$BIN/Zonas.app" ]] || die "build.sh did not leave a bundle in $BIN"
    # ditto and not cp -R: it is the copy that preserves the metadata a
    # signature seals over.
    ditto "$BIN/Zonas.app" "$APP"
fi

# ======================================================================== 3
paso "3/7  check the signature before spending an upload on it"
#
# Each of these is a notarization rejection that can be seen locally in a
# millisecond instead of remotely in five minutes.

ARCHS="$(lipo -archs "$APP/Contents/MacOS/Zonas")"
say "archs: $ARCHS"
[[ "$ARCHS" == *"arm64"* && "$ARCHS" == *"x86_64"* ]] \
    || die "the binary is not universal: $ARCHS" \
           "An arm64-only bundle does not launch on an Intel Mac at all —" \
           "Rosetta translates Intel→ARM, never the other way round."

codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /' \
    || die "the signature does not verify" \
           "Almost always something touching the bundle AFTER codesign ran." \
           "Everything that writes into Contents/ has to happen before signing."

FIRMA="$(codesign -d --verbose=2 "$APP" 2>&1)"
printf '%s\n' "$FIRMA" | grep -E '^(Format=|Timestamp=|Authority=Developer ID)' | sed 's/^/    /'

printf '%s\n' "$FIRMA" | grep -q '^Authority=Developer ID Application' \
    || die "this is not signed with a Developer ID Application certificate" \
           "An 'Apple Development' certificate signs perfectly well and is" \
           "rejected by the notary with 'The binary is not signed with a valid" \
           "Developer ID certificate.'"

printf '%s\n' "$FIRMA" | grep -q 'flags=0x10000(runtime)' \
    || die "the hardened runtime is not on" \
           "The notary rejects it with 'The executable does not have the" \
           "hardened runtime enabled.' — build.sh should be passing" \
           "--options runtime to codesign."

printf '%s\n' "$FIRMA" | grep -q "^TeamIdentifier=$TEAM_ID" \
    || die "wrong Team ID in the signature" \
           "It must match the --team-id of the notarization credentials."

printf '%s\n' "$FIRMA" | grep -q '^Timestamp=' \
    || die "the signature has no secure timestamp" \
           "The notary rejects it with 'The signature does not include a secure" \
           "timestamp.' — this is the ad-hoc branch of build.sh having run," \
           "which signs with --timestamp=none."

# `codesign -d --entitlements` prints the Executable= line on stderr and the
# entitlements, if any, on stdout — so an empty stdout is the assertion.
ENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
[[ -z "$ENTS" ]] || die "the signature carries entitlements, and it must not" \
    "$ENTS" \
    "" \
    "If this is get-task-allow, ZONAS_DEBUG_ENTITLEMENTS was left set in the" \
    "environment. The notary rejects that build by name."

RPATHS="$(otool -l "$APP/Contents/MacOS/Zonas" \
    | awk '/^ *cmd LC_RPATH$/{f=1;next} f&&/^ *path /{print $2;f=0}' \
    | sort -u | grep -v -E '^(@|/usr/|/System/)' || true)"
[[ -z "$RPATHS" ]] || die "the binary carries an rpath outside the system" \
    "$RPATHS" \
    "" \
    "That is the toolchain path the linker left behind, and it would ship" \
    "inside a public binary. build.sh strips it before signing."

# --------------------------------------------------------- the requirement
#
# The most important line in this script, for this project. TCC does not record
# "the user allowed Zonas": it records the code requirement the app satisfied at
# the moment the Accessibility toggle was flipped, and it re-checks it on every
# launch. If a release changes that requirement, everyone who updates loses the
# permission silently — the switch still on, the app still dead.
REQ="$(codesign -d -r- "$APP" 2>/dev/null | sed -n 's/^designated => //p')"
say "designated requirement:"
printf '    %s\n' "$REQ"

[[ "$REQ" == *"identifier \"$BUNDLE_ID\""* && "$REQ" == *"leaf[subject.OU] = $TEAM_ID"* ]] \
    || die "the designated requirement does not name this app and this team" \
           "Anyone who already granted the Accessibility permission would lose it."

# Read-only comparison against the copy that already has the permission granted
# on this machine. A warning and not an error: on a machine with nothing
# installed there is simply nothing to compare against.
if [[ -d /Applications/Zonas.app ]]; then
    REQ_VIEJO="$(codesign -d -r- /Applications/Zonas.app 2>/dev/null | sed -n 's/^designated => //p')"
    if [[ -n "$REQ_VIEJO" && "$REQ_VIEJO" != "$REQ" ]]; then
        say "WARNING: this differs from the requirement of the installed copy."
        printf '    installed: %s\n' "$REQ_VIEJO"
        printf '    new:       %s\n' "$REQ"
        say "         Everyone updating will have to grant Accessibility again."
    else
        say "matches the installed copy: the granted permission survives the update"
    fi
fi

# ======================================================================== 4
paso "4/7  notarize the .app"

# Submits, waits, staples, and leaves behind everything needed to pick up where
# it left off. Two things this must never do: treat a non-zero exit from
# notarytool as the whole story (a rejection has a status and a log, and the log
# is the only place that says why), and re-upload something already submitted —
# every codesign produces a new cdhash and tickets are issued per cdhash, so a
# rebuilt artifact is a different artifact and the old ticket is orphaned.
#
# Upload and staple are two different paths on purpose: the notary only accepts
# archives, but a ticket has to be stapled to the thing that gets opened.
#   notarizar <slug> <what gets uploaded> <what gets stapled>
notarizar() {
    local slug="$1" envio="$2" artefacto="$3"
    local idfile="$DIST/$slug.submission-id"
    local estado_json="$DIST/$slug.status.json"
    local log_json="$DIST/$slug.notary-log.json"
    local id estado

    # Already stapled from an earlier run: nothing to do. This is what makes the
    # script safe to run twice.
    if xcrun stapler validate "$artefacto" >/dev/null 2>&1; then
        say "$slug: already has a stapled ticket, skipping the notary service"
        return 0
    fi

    if [[ -f "$idfile" ]]; then
        id="$(cat "$idfile")"
        say "$slug: an earlier run already uploaded this — asking about $id"
        xcrun notarytool info "$id" --keychain-profile "$PERFIL" \
            --output-format json > "$estado_json" 2>"$DIST/$slug.stderr" \
            || die "notarytool info failed for submission $id" \
                   "$(cat "$DIST/$slug.stderr")"
    else
        say "$slug: uploading $(basename "$envio") ($(du -h "$envio" | cut -f1))…"
        # The exit status is not a verdict: --wait returns non-zero on timeout
        # too, and a timeout is not a rejection. The JSON is what decides.
        set +e
        xcrun notarytool submit "$envio" \
            --keychain-profile "$PERFIL" \
            --wait --timeout "$TIMEOUT" \
            --output-format json > "$estado_json" 2>"$DIST/$slug.stderr"
        set -e
        id="$(plutil -extract id raw -o - "$estado_json" 2>/dev/null || true)"
        [[ -n "$id" ]] || die "the notary service did not even return a submission id" \
            "$(cat "$estado_json" 2>/dev/null)" \
            "$(cat "$DIST/$slug.stderr" 2>/dev/null)" \
            "" \
            "Usually the credentials or the network. Try:" \
            "  xcrun notarytool history --keychain-profile $PERFIL"
        printf '%s\n' "$id" > "$idfile"
    fi

    estado="$(plutil -extract status raw -o - "$estado_json" 2>/dev/null || echo "?")"
    say "$slug: submission $id — status: $estado"

    # Pulled even when accepted: an Accepted submission can still carry warnings,
    # and they are worth reading before they become the next release's error.
    xcrun notarytool log "$id" --keychain-profile "$PERFIL" "$log_json" >/dev/null 2>&1 || true

    case "$estado" in
        Accepted)
            if [[ -f "$log_json" ]] && grep -q '"severity": *"warning"' "$log_json"; then
                say "$slug: accepted WITH warnings — $log_json"
                grep -B2 -A2 '"severity": *"warning"' "$log_json" | sed 's/^/    /'
            fi
            ;;
        "In Progress")
            die "$slug: Apple is still processing it after $TIMEOUT" \
                "Nothing is lost and nothing needs re-uploading. Check with:" \
                "  xcrun notarytool info $id --keychain-profile $PERFIL" \
                "and when it says Accepted, carry on from where this stopped:" \
                "  ./release.sh $VERSION --resume"
            ;;
        Invalid|Rejected)
            printf '\n' >&2
            if [[ -f "$log_json" ]]; then
                say "the notary log is the only place that says why:"
                cat "$log_json" >&2
            fi
            die "$slug: the notary service said $estado" \
                "Full log: $log_json" \
                "The 'issues' array is what matters — each entry has severity," \
                "path, message and architecture."
            ;;
        *)
            die "$slug: unexpected status '$estado'" \
                "$(cat "$estado_json")"
            ;;
    esac

    # The ticket goes INSIDE the bundle, in Contents/CodeResources — a separate
    # file from Contents/_CodeSignature/CodeResources, written after signing and
    # deliberately outside the seal, so stapling does not break the signature.
    #
    # Without stapling the app still passes Gatekeeper... but only with a working
    # network connection, because macOS then has to go and fetch the ticket from
    # Apple. Offline it fails, and it fails with the "cannot be verified" panel.
    # Stapling costs one command.
    say "$slug: stapling the ticket"
    xcrun stapler staple "$artefacto" || die "$slug: stapling failed" \
        "The submission was accepted, so this is local. Try again:" \
        "  xcrun stapler staple $artefacto"
}

# notarytool does not accept a loose .app — its help is explicit: `<file-path>
# Path to the archive`, and the archive has to be a .zip, a .dmg or a .pkg. So
# the bundle travels inside a zip that is nothing but an envelope: the ticket
# comes back for the app, gets stapled to the app, and the zip is thrown away.
#
# `ditto` and not `zip` or the Finder's Compress: those drop symlinks, xattrs
# and resource forks, and the signature arrives broken. `--keepParent` is not
# optional — without it the bundle's contents land at the root of the archive
# and the notary finds no bundle to look at. `--sequesterRsrc` pushes the
# AppleDouble files into __MACOSX/ instead of leaving `._Zonas` files inside the
# bundle, where a third-party unarchiver could break the seal.
ZIP="$DIST/Zonas-envelope.zip"
[[ -f "$ZIP" ]] || ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

notarizar "app" "$ZIP" "$APP"

# It has served its only purpose. Leaving it in dist/ next to the .dmg is an
# invitation to publish the wrong file — and this one has no ticket in it.
rm -f "$ZIP"

# ======================================================================== 5
paso "5/7  build the .dmg"
#
# Built AFTER the app is stapled, so the copy the user drags into /Applications
# already carries its ticket and validates with the Wi-Fi off.
if [[ -f "$DMG" ]]; then
    say "$(basename "$DMG") already exists, reusing it"
    say "(rebuilding it would change its cdhash and orphan its notarization ticket)"
else
    ROOT="$DIST/dmgroot"
    rm -rf "$ROOT"; mkdir -p "$ROOT"
    ditto "$APP" "$ROOT/Zonas.app"
    # The alias is the whole point of shipping a .dmg: dragging the bundle in the
    # Finder is what cancels App Translocation.
    ln -s /Applications "$ROOT/Applications"

    # HFS+ on purpose: an APFS image buys nothing here and is readable by fewer
    # systems. UDZO with zlib-level=9 because the payload is 500 KB and the
    # compression time is not measurable.
    hdiutil create -volname "Zonas $VERSION" -srcfolder "$ROOT" -ov \
        -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG"
    rm -rf "$ROOT"

    # --identifier because otherwise codesign derives it from the file name and
    # the disk image ends up identified as "Zonas-0" — different on every
    # release, for no reason. No --options runtime here: a disk image is not
    # executable code and the hardened runtime does not apply to it.
    codesign --force --timestamp --identifier "$BUNDLE_ID.dmg" --sign "$ID" "$DMG"
fi
codesign --verify --strict --verbose=2 "$DMG" 2>&1 | sed 's/^/    /' \
    || die "the disk image's own signature does not verify"

# ======================================================================== 6
paso "6/7  notarize the .dmg"
#
# A second submission, and it is not redundant: the ticket stapled to the .app
# lives inside the .app, and the .dmg is a separate file that Gatekeeper checks
# on its own when the user double-clicks it. Without its own stapled ticket the
# image needs the network to open.
notarizar "dmg" "$DMG" "$DMG"

# ======================================================================== 7
paso "7/7  verify what the downloader's Mac will say"

# stapler is the only one of the three that actually proves the ticket is
# attached. spctl cannot tell "stapled" from "notarized, with a network
# connection": it accepts as soon as a ticket exists anywhere, even if it had to
# go to Apple to find it.
xcrun stapler validate "$DMG" \
    || die "the .dmg has no stapled ticket" "Run: xcrun stapler staple $DMG"
xcrun stapler validate "$APP" \
    || die "the .app has no stapled ticket" "Run: xcrun stapler staple $APP"

# Apple's modern check, and the one that gives a diagnosis in one line.
# Its sibling `syspolicy_check notary-submission` is NOT usable as a gate: on a
# correctly signed but not-yet-notarized app it returns a Fatal "Gatekeeper
# rejected this file", which is a false positive by construction.
say "syspolicy_check distribution:"
/usr/bin/syspolicy_check distribution "$APP" 2>&1 | sed 's/^/    /' \
    || die "the app failed Apple's pre-distribution check (see above)"

say "spctl, the verdict Gatekeeper gives:"
SPCTL="$(spctl -a -vvv -t exec "$APP" 2>&1 || true)"
printf '%s\n' "$SPCTL" | sed 's/^/    /'
printf '%s\n' "$SPCTL" | grep -q 'source=Notarized Developer ID' \
    || die "Gatekeeper does not see this as notarized" \
           "Expected 'source=Notarized Developer ID'. 'Unnotarized Developer ID'" \
           "means the ticket did not make it."

SPCTL_DMG="$(spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1 || true)"
printf '%s\n' "$SPCTL_DMG" | sed 's/^/    /'
printf '%s\n' "$SPCTL_DMG" | grep -q 'accepted' \
    || die "Gatekeeper rejects the .dmg itself"

# ------------------------------------------------------- the download rehearsal
#
# Building and running locally NEVER exercises what a downloader goes through:
# the Gatekeeper panel only appears on items carrying the com.apple.quarantine
# xattr, and a file that came out of your own build never has one. This fakes
# the browser's part.
#
# A fresh temporary directory and a fresh UUID every time: syspolicyd keeps a
# record of past evaluations per app, and a previous approval would flatter the
# next run into passing for the wrong reason.
ENSAYO="$(mktemp -d)"
NOMBRE="$(basename "$DMG")"
cp "$DMG" "$ENSAYO/"
xattr -w com.apple.quarantine \
    "0083;$(printf %x "$(date +%s)");Safari;$(uuidgen)" "$ENSAYO/$NOMBRE"
xattr -p com.apple.quarantine "$ENSAYO/$NOMBRE" >/dev/null 2>&1 \
    || die "the quarantine xattr did not stick, so this rehearsal proves nothing"
say "the same verdict, on a copy that carries the browser's quarantine flag:"
SPCTL_Q="$(spctl -a -vvv -t open --context context:primary-signature "$ENSAYO/$NOMBRE" 2>&1 || true)"
printf '%s\n' "$SPCTL_Q" | sed 's/^/    /'
printf '%s\n' "$SPCTL_Q" | grep -q 'accepted' \
    || die "Gatekeeper rejects the quarantined copy" \
           "This is the one that matters: it is what the downloader gets."

# Relative to dist/, so that `shasum -c Zonas-x.y.z.dmg.sha256` works next to the
# file instead of pointing at a path that only exists on this machine.
( cd "$DIST" && shasum -a 256 "$NOMBRE" | tee "$NOMBRE.sha256" )

# ---------------------------------------------------------------------- done
cat <<FIN

$(printf '\033[1m')ready$(printf '\033[0m'): $DMG

The checksum sits next to it, in $NOMBRE.sha256.
It is not a security measure —it travels over the same channel as the file, so
it defends against nothing that controls that channel; the stapled notarization
ticket is the real integrity guarantee— but it costs one line and the day
somebody writes a Homebrew cask, that is the number it asks for.

Test it like a stranger would, because no command replaces this. The rehearsal
copy below carries the quarantine flag, exactly as a browser leaves it:

  open $ENSAYO

Double-click the .dmg, drag the app onto Applications, open it from there. Then
do it once more with the Wi-Fi OFF — that, and only that, proves the stapling
works. Best of all in a freshly created user account, where there is no
Accessibility grant and no Gatekeeper history to flatter the result.

Then publish, by hand. Write the notes first — with no website and no cask, the
release notes ARE the installation page: what it does in two lines, macOS 14+ on
Intel and Apple Silicon, drag it to Applications and do not open it from
Downloads, grant Accessibility from the menu bar item, hold Shift and drag.
Above all, warn that on first launch nothing visible happens except a small grey
icon appearing in the menu bar.

  \$EDITOR dist/notes.md
  git tag -a v$VERSION -m "Zonas $VERSION"
  git push origin v$VERSION
  gh release create v$VERSION "$DMG" --draft --verify-tag \\
      --title "Zonas $VERSION" --notes-file dist/notes.md
  # download the asset from the draft, check it opens, and only then:
  gh release edit v$VERSION --draft=false --latest

--draft first is not ceremony: with immutable releases turned on, a published
asset can no longer be replaced or deleted. The draft is the last chance to
rebuild the .dmg. And do not tick "pre-release": Homebrew's cask audit rejects
a version that comes from a pre-release tag.
FIN
