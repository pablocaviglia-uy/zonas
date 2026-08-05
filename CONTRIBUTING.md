# Contributing to Zonas

Everything about building, signing and releasing. What Zonas *is* and how to use
it is in the [README](README.md); **why it is built the way it is** — with the
measurements behind the decisions — is in [docs/PLAN.md](docs/PLAN.md), and that
is the document to read before changing anything structural. Its §10 is a short
list of rules that must not be broken.

Code, comments, documentation and commit messages are in English. Commit
messages are narrative and explain the *why*: read `git log` for the register.

## What you need

- Xcode 16 or the matching Command Line Tools — the package declares
  `swift-tools-version: 6.0` and builds in Swift 5 language mode.
- **A code signing certificate, before your first build.** Skipping this is the
  single most common way to lose an afternoon on this project. See
  [Development signing](#development-signing).

```bash
swift build          # compile
swift test           # the test suite; CI runs it on every push
```

## Build

```bash
git clone https://github.com/pablocaviglia-uy/zonas.git
cd zonas
./build.sh -r
```

`build.sh` compiles with SwiftPM and wraps the result in a real `.app` bundle,
because macOS will not grant the Accessibility permission to a bare executable:
it needs an `Info.plist` and a signature.

| Command | What it does |
|---|---|
| `./build.sh` | Debug build, leaves `Zonas.app` under `.build/` |
| `./build.sh release` | Same, optimized |
| `./build.sh -r` | Release build, installs into `/Applications` and opens it |
| `./build.sh debug -r` | Forces a debug build and installs it anyway |
| `./build.sh release -u` | Universal (arm64 + x86_64). What `release.sh` ships |

`-u` is off by default because waiting on an x86_64 slice that this machine will
never execute is time thrown away — it roughly doubles the build. It exists for
[Releasing](#releasing), where leaving it out would publish a bundle that does
not launch at all on an Intel Mac: Rosetta translates Intel→ARM and never the
other way round.

The split default is deliberate: what you build to look at can be debug, but
what gets copied into `/Applications` and then hangs off your mouse all day
long is built optimized unless you ask otherwise.

Two things only work from the installed copy: **Launch at Login** (greyed out
in the `.build/` copy on purpose) and a stable Accessibility grant.

## How it is put together

| File | What it solves |
|---|---|
| `DragMonitor.swift` | Detects the drag with a listen-only event tap. The awkward part: macOS has no API that tells you a window is being moved. |
| `AXWindow.swift` | Reads and moves other apps' windows through the Accessibility API. |
| `Coords.swift` | Converts between the two macOS coordinate systems — Cocoa's bottom-left origin and CoreGraphics' top-left one. The number one source of multi-monitor bugs. |
| `OverlayController.swift` | The click-through translucent layer that draws the zones. |
| `Zone.swift` | The model: zones, layouts, and which zone is under the cursor. |
| `LayoutFile.swift` | Where the layout file is, reading and writing it, and the text of the one the first launch creates. |
| `LayoutStore.swift` | The layout in memory. |
| `Welcome.swift` | What the first-launch window decides: when to open, which of the three permission states the app is in, and whether macOS is drawing the menu bar icon at all. |
| `WelcomeController.swift` | That window, and its two code-drawn diagrams. |
| `AppDelegate.swift` | Menu bar, permission watchdog, wiring. |
| `LaunchAtLogin.swift` | The login item, via `SMAppService`. |
| `Log.swift` | Append-only file logging. |
| `build.sh` | Wraps the executable in a real `.app` and signs it. |
| `release.sh` | Universal, notarized, stapled `.dmg` for the Releases page. |

## Development signing

**Do this before your first build.** Without your own certificate, the
Accessibility permission breaks on *every* recompile, and the symptom is one of
those that costs you an afternoon: the switch stays on in System Settings and
the app still behaves as if it had been denied.

### Why it breaks

The permission is not granted to "the app". It is granted to a **signature**.

Next to the on/off switch, TCC — the subsystem behind Privacy & Security —
stores the *code requirement* that the app satisfied at the moment you granted
it. From then on, every time the app asks `AXIsProcessTrusted()`, the system
does not check "is this app in the list?" but "does the code asking still
satisfy the requirement I recorded?".

With an ad-hoc signature there is no certificate to name, so the designated
requirement macOS derives is `cdhash H"..."` — the hash of the binary's code
directory. And `swift build` produces a different binary on every run, even
from identical sources at the same path. So the recorded requirement pins the
one exact build that was running when you clicked the switch, and the next
build can never satisfy it again.

The result is the most disorienting failure mode in this project: the switch is
still on in Settings, but `AXIsProcessTrusted()` returns `false` forever,
because whoever is asking is no longer the code that was said yes to. In the
system log it shows up as:

```
tccd: Failed to match existing code requirement
```

With your own certificate, the designated requirement names the
**certificate** instead of the binary's hash — and the certificate does not
change between builds. Any build you sign with it satisfies a grant made to any
earlier build.

### Creating the certificate

1. **Keychain Access** → menu *Certificate Assistant* → *Create a Certificate…*
   - Name: `Zonas Dev`
   - Identity Type: **Self Signed Root**
   - Certificate Type: **Code Signing**
   - Tick *Let me override defaults* and set the validity to **3650 days** —
     the 365-day default breaks the permission once a year, and by then nobody
     remembers why.
   - Keychain: **login**
2. Double-click the certificate → expand **Trust** → *Code Signing* → **Always
   Trust**. Authenticate when asked.
   **This step is not optional:** without it `codesign` answers
   `no identity found` and you are back to ad-hoc.
3. Check that it shows up:
   ```bash
   security find-identity -v -p codesigning
   ```
4. Export a `.p12` backup **outside the repository**. Losing the certificate
   breaks the permission exactly the same way as never having had one.
5. Build. `build.sh` finds the identity on its own: it takes the first of
   `Zonas Dev`, `Apple Development` or `Developer ID Application` that shows up
   in the keychain listing — the keychain's order decides, not the order in that
   list. Any of the three gives a stable requirement, so for development it does
   not matter which; `release.sh` writes its identity out in full rather than
   searching, because there it does. To force a specific one:
   ```bash
   ZONAS_SIGN_ID="My Certificate" ./build.sh
   ```
   After the first signed build you have to re-grant the permission **once**
   (see below), because the grant you already had pointed at the old cdhash.

Two details `build.sh` takes care of, both of which exist to keep the
permission from breaking again later:

- It signs with `--timestamp`, a secure timestamp, not `--timestamp=none`.
  Without it, the day the certificate expires the signature stops validating
  and the permission breaks again for no visible reason. With it, the signature
  keeps validating past expiry, because there is proof it was made while the
  certificate was still valid.
- After every build it prints the resulting designated requirement, on a line
  starting with `requirement:` — the same thing you would get from
  `codesign -d -r- /Applications/Zonas.app`. That single line is the thing to
  watch. Signed with a certificate it names the certificate and stays identical
  build after build; if it ever changes, TCC will reject the app no matter what
  the switch says.
- It signs with `--options runtime`, the hardened runtime, the same as a release
  build. Notarization requires it, and building development and release copies
  the same way is the point: whatever breaks under it should break here and not
  two minutes into an upload. It needs no entitlements — the event tap and the
  Accessibility API are governed by TCC at runtime, not by entitlements — and it
  does not change the designated requirement, so turning it on does not cost
  anyone a permission they had already granted.

  The one thing it takes away is attaching a debugger. `lldb` cannot attach to a
  hardened process without `com.apple.security.get-task-allow`, an entitlement
  the notary rejects by name. So it lives in its own file, opt-in, one build at
  a time:

  ```bash
  ZONAS_DEBUG_ENTITLEMENTS=1 ./build.sh -r
  ```

  `release.sh` refuses to publish anything whose signature carries entitlements,
  so leaving that variable set fails locally instead of remotely.

Zonas also writes its own signature fingerprint — the live process's cdhash and
designated requirement — into the log at startup, which closes the diagnosis at
a glance: if today's cdhash is not the one from the previous run, the permission
is already broken and there is nothing else to investigate.

### Without a certificate

If no stable identity is found, `build.sh` still signs ad-hoc, but pins the
designated requirement by hand:

```bash
codesign --force --timestamp=none --sign - \
  --identifier "uy.com.fcstudio.zonas" \
  -r="designated => identifier \"uy.com.fcstudio.zonas\"" \
  Zonas.app
```

This works most of the time, but it is a patch and nothing more. The
requirement it leaves behind is weak — any app declaring the same bundle
identifier satisfies it — and Apple makes no promise that TCC will honor it
instead of falling back to the cdhash. Fine for a development machine. Never
for anything you hand to someone else.

### When the permission "gets lost"

Toggling the switch off and back on **does not work**. It rewrites the boolean
and keeps the old, stale code requirement. The entry has to be deleted and
created again:

1. Quit Zonas.
2. In System Settings → Privacy & Security → Accessibility, select Zonas and
   remove it with the **−** button.
3. Add it back with **+**, picking `/Applications/Zonas.app`, and leave it
   switched on.

To confirm the diagnosis before touching anything (`log` is a zsh builtin, so
the absolute path is required):

```bash
/usr/bin/log show --last 30m --predicate 'subsystem == "com.apple.TCC"' --info --debug \
  | grep -i zonas | grep -E "Failed to match|cdhash H|TCCDEvent"
```

## Releasing

`release.sh` builds the file that ends up on the Releases page: a single `.dmg`,
universal, signed with a Developer ID, hardened, notarized by Apple and with the
ticket stapled into it so that it opens on a Mac with no network.

```bash
./release.sh 0.1.0
```

Once per machine, and never in the repository, the notarization credentials have
to go into the keychain:

```bash
xcrun notarytool store-credentials zonas --team-id YY7SF272MV
```

It asks for an Apple ID and an **app-specific password** — one generated at
[appleid.apple.com](https://appleid.apple.com), not the Apple ID password
itself. Every command in `release.sh` then goes through
`--keychain-profile zonas`; no credential is ever written to a file.

A few decisions worth knowing about:

- **The version is read, not written.** It comes from
  `Resources/Info.plist`, and the argument only has to agree with it. That way
  the git tag, the plist and the file name cannot drift apart. Building from a
  dirty working tree is refused, because a release nobody can rebuild from the
  tag is not a release.
- **Everything Apple would reject is checked locally first**, before uploading
  anything: hardened runtime missing, no secure timestamp, entitlements present,
  a binary that is not universal, a certificate that is not a Developer ID, an
  rpath left pointing at the local Xcode toolchain.
- **It prints the designated requirement and compares it with the copy already
  installed in `/Applications`.** If those two ever differ, every person who
  updates loses their Accessibility permission — see above for why. It is the
  one line in the output worth reading every time.
- **A `.dmg` and not a `.zip`**, which is what most similar projects publish,
  for the App Translocation reason explained in [Install](#install): the `.zip`
  invites the double click in `~/Downloads`, and the disk image with its
  `/Applications` alias invites the drag.
- **If Apple takes longer than the timeout, nothing is lost.** The submission
  keeps processing on their side, and `./release.sh 0.1.0 --resume` collects the
  answer without rebuilding or re-uploading. Re-uploading would be worse than
  useless: every `codesign` produces a new cdhash, and tickets are issued per
  cdhash, so a rebuilt artifact is a different artifact.
- **It publishes nothing and never touches `/Applications`.** The last thing it
  prints is the `git tag` and `gh release` commands to run by hand, plus the
  path to a quarantined copy of the `.dmg` for rehearsing the download.

Notarizing belongs to tags, not to commits: refusing to sign twice is not
laziness, it is that every signature invalidates the previous ticket.
