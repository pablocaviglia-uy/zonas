# Zonas

**Your window layout is a file.** Not a preference pane, not a database in
`~/Library` — a file you write, with comments in it, that goes in your dotfiles
repo and gets symlinked wherever you want it.

Hold **⇧ Shift** while dragging a window, the zones light up, drop it and the
window fills the one under the cursor. Edit the file, save, and the zones change
underneath you. (*zonas* is Spanish for *zones*.)

```js
// ~/.config/zonas/zonas.json5
//
//        x: 0                                   x: 1
//   y: 0 ┌───────────┬───────────────────────────┐
//        │           │   the wide one for what   │
//        │   docs    │   you are working on      │
//   y: 1 └───────────┴───────────────────────────┘

{
  name: "Three Columns",
  zones: [
    { name: "Left",   x: 0,    y: 0, width: 0.25, height: 1 },
    { name: "Center", x: 0.25, y: 0, width: 0.5,  height: 1 },
    { name: "Right",  x: 0.75, y: 0, width: 0.25, height: 1 },
  ],
}
```

Ratios work too — `"1/3"` rather than `0.3333`, because three columns written as
`0.3333` leave a sliver on the right edge that is invisible in the file and
maddening on screen. If the file does not parse, the app says which line, keeps
the zones it was already using, and does not touch a byte of what you wrote.

It is for people who liked
[FancyZones](https://learn.microsoft.com/en-us/windows/powertoys/fancyzones)
from PowerToys on Windows, and for people who would rather write their window
layout once and take it to every machine they own.

<!--
  DEMO GIF GOES HERE.
  Two halves, and the second one is the pitch: a window being dragged with
  Shift held — zones appearing, the one under the cursor highlighting, the
  window snapping on release — and then the file being edited in vim,
  saved, and the zones changing without touching the app.
  Then replace this comment with:
  ![Zonas snapping a window into a zone](docs/demo.gif)
-->

**There is no visual editor, and that is on purpose for now.** Everything you
can express you express in the file, which means every layout you build is
something you can read, diff, comment, and carry to another machine. An editor
will come to widen the audience, not to make this usable: AeroSpace has 22,000
stars and no configuration GUI at all.

**Status: early.** The snapping works end to end and the file is the real
source of truth — comments, ratios, live reload, errors that name the line. What
is not there yet is multiple layouts, per-monitor rules, and the visual editor.
See [Not there yet](#not-there-yet).

## Install

If you only want to use it, there is nothing to compile. Download
**`Zonas-x.y.z.dmg`** from the
[Releases page](https://github.com/pablocaviglia-uy/zonas/releases). It is
signed with a Developer ID and notarized by Apple, and it runs on Apple Silicon
and Intel Macs alike, on macOS 14 (Sonoma) or later.

Open the disk image and **drag Zonas onto the Applications folder** next to it.

That drag matters more than it looks. An app launched from where the browser
left it — the disk image, or `~/Downloads` — runs under *App Translocation*:
macOS executes it from a read-only copy in a temporary directory whose path
changes on every single launch. For this app that is not cosmetic. "Launch at
Login" would stay greyed out forever, and the Accessibility permission would
have to be granted again and again, each time to a path that no longer exists.
Dragging it in the Finder is what cancels translocation.

### The first launch

Open Zonas from Applications. macOS asks once whether you are sure, because it
was downloaded from the internet, and tells you Apple checked it and found no
malicious software. Click **Open**.

**And then nothing happens.** That is the app working. It is also the most
confusing minute of using it: Zonas has no window and no icon in the Dock, on
purpose. The only trace of it is a new menu bar icon — a small rectangle split
into three, dimmed — at the top right of the screen. On a MacBook with a notch
and a busy menu bar it can end up *underneath* the notch, where it is simply
invisible; if you cannot find it, quit something else that lives up there.

The icon is dimmed because Zonas cannot do anything yet. Moving another
application's window requires the **Accessibility** permission, and only you can
grant it:

1. Click the menu bar icon → **Accessibility Permissions…**
2. Two things happen at once, which is deliberate: a system dialog asks whether
   to let Zonas control your computer, and System Settings opens straight to
   Privacy & Security → Accessibility.
3. Find **Zonas** in that list and switch it on. Confirm with Touch ID or your
   password.

Within a second and a half the menu bar icon stops looking dimmed, on its own.
That is the only confirmation there is, and it is the one to wait for.

Now hold **⇧ Shift** and drag any window. Three zones light up — a quarter, a
half, a quarter — and dropping the window fills whichever one is under the
cursor. Those three are just the layout it starts with; they live in a file you
can edit, see [The zones](#the-zones).

There is no automatic update yet. New versions are announced on the Releases
page, and installing one is the same drag over the old copy — the Accessibility
permission survives it, because it is tied to the signing certificate and not
to the particular build.

## Requirements

To run it:

- macOS 14 (Sonoma) or later, Apple Silicon or Intel.
- The **Accessibility** permission. It is not optional: without it the app
  cannot move other applications' windows and fails silently.

To build it:

- Xcode 16 or the matching Command Line Tools — the package declares
  `swift-tools-version: 6.0` and builds in Swift 5 language mode.
- Recommended before your first build: a self-signed code signing certificate.
  See [Development signing](#development-signing) — skipping it is the single
  most common way to lose an afternoon on this project.

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

## Using it

Hold **⇧ Shift** while dragging a window. The zones appear; drop the window on
the one you want.

Shift was chosen because Option is already taken by the native macOS tiling,
and stepping on it would make the two features fight each other.

The menu bar item — a `rectangle.split.3x1` glyph, dimmed while the permission
is missing — has:

| Item | |
|---|---|
| `Hold ⇧ while dragging a window` | Reminder, not a button |
| `Edit Zones…` | Opens `zonas.json5` in your default editor |
| `Reload Zones` (⌘R) | Re-reads the file after you edit it |
| `Open Log…` | Opens `~/Library/Logs/Zonas.log` |
| `Launch at Login` | Only available from `/Applications` |
| `Accessibility Permissions…` | Prompts and opens the Settings pane |
| `Quit Zonas` (⌘Q) | |

There is no permission prompt at launch, on purpose: when the app starts by
itself at login, a modal system dialog either steals focus or ends up buried
behind the Desktop. Asking is what the `Accessibility Permissions…` item is
for — the moment the user actually asked.

When something looks wrong, the log is the place to look:

```bash
tail -f ~/Library/Logs/Zonas.log
```

It records **state transitions**, not every event — a `mouseDragged` arrives
dozens of times per second and would bury the file in noise.

## The zones

Zones live in **`~/.config/zonas/zonas.json5`** — or under `$XDG_CONFIG_HOME`
if you set it — stored as
fractions from 0 to 1 of the screen's usable area — the part left over after
the menu bar, the Dock and, on the machines that have one, the notch. Keeping
them relative instead of in pixels is what makes the same layout work on the
laptop screen and on an external monitor without redrawing it.

The file the first launch writes is JSON5, so it can be written the way you
would write it by hand — with comments, without quoting every key, and with a
comma after the last item:

```js
{
  name: "Three Columns",

  // Editor in the middle, docs on the left, chat on the right.
  zones: [
    { name: "Left",   x: 0,    y: 0, width: 0.25, height: 1 },
    { name: "Center", x: 0.25, y: 0, width: 0.5,  height: 1 },
    { name: "Right",  x: 0.75, y: 0, width: 0.25, height: 1 },
  ],
}
```

Edit the file and pick **Reload Zones** from the menu bar. Notes:

- The file is written once, on first launch, and **never overwritten** after
  that. Your zones, your comments and your ordering are yours.
- Plain JSON is valid JSON5, so quoting the keys is fine too.
- Windows land with a few points of air between them. The zone you see
  highlighted during the drag is exactly the rectangle the window gets.
- If the file does not parse, the app says so in the log and leaves your file
  exactly as it is. It keeps the zones it was already using — a typo does not
  take your layout with it — and only falls back to the built-in three columns
  when there was nothing working to keep, which means at startup.
- When zones overlap, **the smallest one containing the cursor wins**. That is
  what makes a layout with one big background zone and smaller ones on top of
  it usable.

## From the command line

The app and the command line are the same binary. With arguments it answers and
exits without ever starting the menu bar app:

```bash
/Applications/Zonas.app/Contents/MacOS/Zonas check
```

| Command | What it does |
|---|---|
| `check [file]` | Reads the layout and says what is wrong with it, with the line number. Exit 1 on an error, 0 on a warning. |
| `fmt [file]` | Rewrites the file in canonical form — aligned columns, comments kept. |
| `fmt [file] --check` | Says whether it would rewrite it, and changes nothing. Exit 1 if it would. |
| `monitors` | Name, size and display ID of every screen you have plugged in. |
| `version`, `help` | |

Give `check` and `fmt` a path to work on a file other than the installed one —
which is what you want in the CI of a dotfiles repo, where nothing is installed:

```bash
Zonas check ~/dotfiles/config/zonas/zonas.json5
```

`fmt` runs Zonas' own comment-conservation check before it writes, and refuses
to write at all if reformatting would lose a single comment you typed.

**`$XDG_CONFIG_HOME` is deliberately not honoured.** A GUI app on macOS is
launched by Finder or launchd and never sees your shell's exports, so the app
would read `~/.config` while `zonas check` in a terminal read somewhere else —
silently, with only one of the two files existing. Symlink the file instead:
that is resolved by the filesystem, so the app and the command line agree, and
Zonas writes through symlinks without replacing them.

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

## How it is put together

| File | What it solves |
|---|---|
| `DragMonitor.swift` | Detects the drag with a listen-only event tap. The awkward part: macOS has no API that tells you a window is being moved. |
| `AXWindow.swift` | Reads and moves other apps' windows through the Accessibility API. |
| `Coords.swift` | Converts between the two macOS coordinate systems — Cocoa's bottom-left origin and CoreGraphics' top-left one. The number one source of multi-monitor bugs. |
| `OverlayController.swift` | The click-through translucent layer that draws the zones. |
| `Zone.swift` | The model: zones, layouts, and which zone is under the cursor. |
| `LayoutFile.swift` | Where the layout file is, reading and writing it, and the text of the one the first launch creates. |
| `ZoneStore.swift` | The layout in memory. |
| `AppDelegate.swift` | Menu bar, permission watchdog, wiring. |
| `LaunchAtLogin.swift` | The login item, via `SMAppService`. |
| `Log.swift` | Append-only file logging. |
| `build.sh` | Wraps the executable in a real `.app` and signs it. |
| `release.sh` | Universal, notarized, stapled `.dmg` for the Releases page. |

## Not there yet

Roughly in the order they are being built. The reasoning behind the order — and
behind most of the decisions in here — is written down in
[`docs/PLAN.md`](docs/PLAN.md).

- [ ] **Multiple layouts, and per-monitor rules.** Which layout goes on which
      screen, described by name, by glob, by minimum width — including monitors
      you do not have plugged in right now. A GUI can only offer a dropdown of
      what is attached today; a file can describe the office dock, the home
      dock, and the laptop on its own.
- [ ] Respecting the minimum window size each app enforces. Right now Zonas asks
      for the zone, the app quietly gives back something else, and the log says
      so.
- [ ] Electron, Java and other apps that do not cooperate with the
      Accessibility API
- [ ] `gap`, `margin` and the modifier key, set from the file
- [ ] A visual editor — one that writes *this* file, comments and all
- [ ] A Homebrew cask, so `brew install --cask zonas` works
- [ ] Automatic updates. Today a new version means downloading the `.dmg` again

## License

MIT. See [LICENSE](LICENSE).
