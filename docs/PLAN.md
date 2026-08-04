# Zonas — working plan

Written 2026-08-03, at the end of the session that built the prototype. In
English because the code, the comments and the README are, and because whoever
picks this up next will be reading `file.swift:line` references against English
source.

This is a handoff document. It carries the decisions **and the reasons for
them**, because most of the reasons cost hours to find and none of them are
obvious from the code. Where a decision was made against the obvious
alternative, the alternative and why it lost are written down too — that is the
part that stops the next person from cheerfully undoing it.

---

## 1. Where things stand

**Repository:** https://github.com/pablocaviglia-uy/zonas — public, MIT.

> **Updated 2026-08-04.** Everything in §3 has landed, one commit per fix, in
> the order they are written there. Two things in this section were out of date
> and are corrected below: `release.sh` has been run end to end, and the
> uncommitted tree is committed. §3 itself now carries a status note, including
> the two places where what landed is not literally what it asked for.

**What works, end to end:** hold ⇧ while dragging a window, the zones light up,
drop it and the window fills the one under the cursor. Zones are stored as
fractions of the screen's usable area, so the same layout works on a 5120×1440
ultrawide and on the laptop screen with no changes. Verified on both.

**How it is built and signed:** `build.sh` compiles with SwiftPM, wraps the
binary in a real `.app`, and signs it with a Developer ID certificate
(`Developer ID Application: Pablo Caviglia (YY7SF272MV)`, expires
**2027-02-01**) with hardened runtime and a secure timestamp. It can produce a
universal binary with `-u`.

**Source layout:**

| File | What it owns |
|---|---|
| `DragMonitor.swift` | The `CGEventTap` that detects the drag. macOS has no API that says "a window is being moved", so this is the awkward part. |
| `AXWindow.swift` | Reading and moving other apps' windows through the Accessibility API. |
| `Coords.swift` | Converting between macOS's two screen coordinate systems. The number one source of bugs in this kind of app. Also `NSScreen.displayID`. |
| `OverlayController.swift` | The translucent layer that draws the zones. |
| `Zone.swift` | The model: `Zone`, `Layout`, hit-testing, and the two view-space conversions the overlay and the editor share. |
| `LayoutFile.swift` | Where the file is, reading it, writing it, and the text of the one the first launch creates. |
| `LayoutStore.swift` | The layout in memory, and which file it came from. |
| `LayoutSyntax.swift` | JSON5 in, tree out, text back, comments intact. `LayoutParser`, `LayoutSchema` and `LayoutMigration` sit beside it. |
| `LayoutWriter.swift` | An edited document back into the file it came from. The one place Rule 2 has an exception, and it is computed. |
| `EditorController.swift` | The editor: windows, gestures, drawing, and when it must not write. |
| `EditorDocument.swift` | What the editor edits — `rid` identity, split, move, delete, undo. Nothing about screens. |
| `Fraction.swift` | The denominators the file can write, which are the ones the editor snaps to. |
| `LaunchAtLogin.swift` | `SMAppService` registration. |
| `Signature.swift` | Logs the live process's cdhash and designated requirement. |
| `Log.swift` | File log at `~/Library/Logs/Zonas.log`. |
| `AppDelegate.swift` | Menu bar, permissions, wiring. |
| `Tests/ZonasTests/` | 198 tests. `swift test`, and CI runs it on every push. |

### The release pipeline, corrected

**Published 2026-08-04: [v0.1.0](https://github.com/pablocaviglia-uy/zonas/releases/tag/v0.1.0).**
Universal, signed, notarized, stapled. Verified the way it has to be verified —
downloaded from GitHub, quarantine attribute set as a browser would set it,
`spctl` answering `accepted / source=Notarized Developer ID`, and then installed
and opened with the network off, which is the only thing that actually proves
the stapling.

Note for the next release: the `.dmg` that was sitting in `dist/` was **21
commits stale** (build 2 against a HEAD of 24). `release.sh` rebuilds from the
working tree, so run it *at the tag* and check `CFBundleVersion` against
`git rev-list --count HEAD` before publishing anything.

Still open in Stage 2, and it is the one that matters: **the first-launch
window**. The release notes warn in bold that nothing visible happens on first
launch except a small grey icon, but a release note is not a window.

Everything that was listed here as uncommitted is committed (`40c3e11`).

### The one human step, already taken

The notarization credentials are stored — this is kept because it is what a
fresh machine, or an expired app-specific password, will need again:

```bash
xcrun notarytool store-credentials zonas --team-id YY7SF272MV
```

It needs an app-specific password generated at appleid.apple.com → Sign-In and
Security → App-Specific Passwords. Apple shows it once. It goes into the
keychain under the profile name `zonas`, and every script refers to it as
`--keychain-profile zonas` — the password itself never appears in the repo, in a
script, or in shell history.

Verify with a command that does not touch the credential:

```bash
xcrun notarytool history --keychain-profile zonas
```

An empty list means success. An error means the profile is not there.

### Two things a fresh session should know

**A test copy may be running.** During the release research, agents launched
copies of Zonas from `dist/` and from scratch directories. Check with
`pgrep -x Zonas` and confirm the path — only the copy in `/Applications` should
be running day to day, because `LaunchAtLogin` deliberately refuses to talk to
Background Task Management from anywhere else. (Checked on 2026-08-04: one
process, `/Applications/Zonas.app`. Worth re-checking, not worth assuming.)

**Two user-facing warnings were seen during testing, and both are real.**
macOS 26 showed *"Support Ending for Intel-based Apps"* while universal binaries
were being launched, and the Gatekeeper *"Apple could not verify Zonas is free
of malware"* dialog appeared for a quarantined unnotarized copy. The second is
exactly what every downloader would see today; eliminating it is the whole point
of the notarization work. The first is unresolved and is noted in §7.

---

## 2. The one thing that costs an afternoon if you do not know it

Accessibility permission is not granted to "the app". It is granted to a
**signature**.

Next to the toggle in System Settings, TCC stores the *code requirement* the app
satisfied when permission was granted, and re-checks it every time the app calls
`AXIsProcessTrusted()`. With an ad-hoc signature that requirement is
`cdhash H"..."` — the hash of the binary — and `swift build` produces a
different binary on every run, even from identical sources at the same path.

So the toggle stays on in Settings while `AXIsProcessTrusted()` returns `false`
forever, because the code asking is no longer the code that was said yes to. In
the system log:

```
tccd: Failed to match existing code requirement
```

Two consequences that are not guessable:

**Turning the toggle off and on does not fix it.** That rewrites the boolean and
keeps the old requirement. Measured against tccd's log during this session: two
off/on cycles, both denied; then removing the entry with **−** and re-adding it
with **+**, granted. Only a delete-and-re-add rewrites the requirement.

**With a real certificate the problem disappears entirely.** The requirement
becomes the certificate and the Team ID, neither of which changes between
builds. Proven: two builds with different cdhashes, permission held across both
with no user action.

When permission "gets lost", this is the first and usually only thing to check:

```bash
codesign -d -r- /Applications/Zonas.app
/usr/bin/log show --last 30m --predicate 'subsystem == "com.apple.TCC"' --info --debug \
  | grep -i zonas | grep -E "Failed to match|authValue"
```

(`log` is a zsh builtin — the absolute path is required.)

The app logs its own fingerprint at startup precisely so this is a one-line
diagnosis rather than an investigation. If the cdhash changed since the previous
run *and* the requirement still mentions `cdhash`, the permission is already
broken and there is nothing to debug.

---

## 3. Fixes to land before building anything new

Eight items, ordered by what they cost to fix later rather than by size. All
verified against the current code and against the file the app actually wrote on
this machine.

> **Done, 2026-08-04.** All of it, one commit per item, in this order, from
> `1c18c77` to `dd6d701`. The commit messages carry the reasoning; this section
> is left as written so the two can be read against each other. Three things are
> worth knowing before reading on:
>
> **(e) landed as two functions, not one.** Applying the inset inside
> `rect(in:)` as written below would have put the gap into the hit region too,
> leaving an eight-point band at every zone boundary where a drop does nothing
> and nothing explains why. So `rect(in:)` is the zone's share of the screen and
> the thing hit-testing asks about — it tiles, edge to edge — and `frame(in:)`
> is what the window is given. The overlay draws `frame` and the drop sets
> `frame`, which is what the fix was actually for. There is a test that fails if
> the gap ever moves into `rect(in:)`.
>
> **(i) landed as content only.** The first launch now writes the hand-written
> example, comments and ASCII diagram and all, and the reader turns on
> `allowsJSON5` to read it back. The file is still called `layout.json` and
> still lives in Application Support, so it is currently a `.json` that is not
> JSON — which §4 rightly calls a lie. Moving and renaming it is the migration
> piece's job, because that is the piece that has to not lose anybody's file.
>
> **`save()` is gone rather than fixed.** It serialized the `Codable` structs,
> which is a writer that destroys every comment in the file the first time
> anything calls it — and nothing did. Rule 4 in §10 says the writer renders
> from the tree; until `LayoutSyntax` exists there is no writer that obeys that,
> so there is no writer. `LayoutFile.write` (atomic, symlink-safe) is the
> primitive it will be built on.

### a) `Zone.id` is written to the file, contradicting the README

`Zone.swift:11` (`var id: UUID = UUID()`) plus the `CodingKeys` in the extension
at `Zone.swift:29-31` — Swift synthesizes `encode(to:)` over those same keys, so
`save()` serializes it. Not theoretical: the layout file on this machine
contains three UUIDs the user never typed. And because they are regenerated on
every reload they are useless as identity for the editor anyway.

**Remove `id` from the on-disk schema. This goes first**, because once the
editor exists, changing the schema becomes a migration.

The in-memory identity the editor needs is a separate thing — see §5.

### b) `save()` is not atomic, and the obvious fix breaks dotfiles

`Zone.swift:135` writes with `try? data.write(to: url)`, no `.atomic`. Once a
file watcher exists, a half-written file is a parse error; a crash mid-write
loses the layouts.

But adding `.atomic` on its own introduces a worse bug, verified with all three
variants:

```
[A plain ] still a symlink: true  | real file: PLAIN
[B atomic] still a symlink: false | real file: ORIGINAL   <-- repo left stale
[C resolv] still a symlink: true  | real file: ATOMIC-RESOLVED
```

`.atomic` writes to a temporary file and renames over the target, **replacing
the symlink with a regular file**. Someone whose config is symlinked from a
dotfiles repo silently ends up with a stale repo copy and a broken link, with no
error anywhere. The fix is `resolvingSymlinksInPath()` before every write —
case C.

`URLResourceValues.canonicalPath` does **not** work: verified, it resolves
`/var`→`/private/var` but returns the link's own path, not the target's.

This needs a comment in the code and a test, because the bug does not exist
today and will be introduced the day somebody "improves" the write path.

Also: `save()` returns a `Bool` that `createIfMissing()` (`Zone.swift:122-125`)
discards. Let the error surface.

### c) Fallback goes to the factory layout instead of the last good one

`Zone.swift:139`: `layout = ZoneStore.read(url) ?? .threeColumns`. One line,
large payoff, and a prerequisite for the editor's `invalid` state.

### d) `Layout` is not `Equatable`

`Zone.swift:58`. `Zone` already is (`Zone.swift:10`). Without it there is no
change detection, no undo coalescing, and no "this external change is
semantically identical" shortcut.

### e) The preview lies about where the window will land

`OverlayController.swift:90` draws `box.rect.insetBy(dx: 8, dy: 8)`, but
`Zone.rect(in:)` (`Zone.swift:19-24`) applies no inset and
`DragMonitor.swift:194` calls `window.setFrame(target.rect)` with the full rect.
The gap already exists, hardcoded, on the wrong side. Fix it together with
`defaults.gap` in Stage 1: the inset comes from config and is applied in
`rect(in:)`, not in the drawing code.

### f) `ZoneStore` mixes four responsibilities

Path resolution (`Zone.swift:83-87`), I/O (`:105-136`), in-memory state (`:89`)
and hit-testing (`:148-153`). The path being a `let` initializer makes it
impossible to write a single test against a temporary directory — which is
exactly what the conflict cases need, and those are unreliable to test by hand.

### g) The overlay re-reads the singleton on every `mouseDragged`

`OverlayController.swift:22` and `:30` remap the whole array and force
`needsDisplay` dozens of times per second, inside the event tap callback. Today
that is only a `tapDisabledByTimeout` candidate — and the detector for that
already exists at `DragMonitor.swift:121-123`, which is worth noting: the
instrument was built before the bug. **Once the file watcher is live it becomes
a correctness bug**, because it lets you draw layout N's zones and snap into
N+1's. Capture an immutable snapshot at `DragMonitor.swift:138-149`.

### h) Two fragile identities, both of which bite with an external monitor

`OverlayController.swift:9` keys a dictionary by `NSScreen`. AppKit replaces
those instances on display reconfiguration, so stale entries are never evicted
and the comparison at `:18` measures dead objects. Use `displayID` — the
`NSScreenNumber` in `deviceDescription`, verified available.

`OverlayController.swift:36` identifies the active zone with `rectCG == active`.
It works today because both rects come from the same computation, but it breaks
with duplicate zones — and with a config file, people **will** duplicate zones —
and with any rounding the gap introduces.

### i) `createIfMissing()` writes `JSONEncoder` output

`Zone.swift:122-125`. Writing on first launch is right; *what* it writes is not.
The first thing a user sees when they open that file is the strongest
documentation this project will ever ship, and today it is alphabetized JSON
where `height` comes before `name`, with UUIDs in it. It should be the
hand-written example from §4, as a string literal. The "the file is the truth"
story starts there or it does not start.

### Also missing

No CI, no tests. `Zone.rect(in:)` and `zone(under:in:)` are pure and testable
today.

> Both landed with the fixes above: 25 tests in `Tests/ZonasTests/`, and
> `.github/workflows/ci.yml` runs `swift build` and `swift test` on every push.
> A test target links against the executable target directly, `main.swift` and
> all, so the app did not have to be cut into a library to get under test.
>
> The symlink test was verified the way §4 verifies things — by breaking the
> writer on purpose and watching it fail — and it fails for both halves of the
> bug: the link turned into a regular file, and the real file left stale.

---

## 4. The format decision

**JSON5, extension `.json5`, canonical writer with comment custody.**

### Why JSON5 and not TOML

TOML was the favourite going in, on the strength of AeroSpace's precedent. It
lost on two concrete counts.

**Zero dependencies.** `JSONDecoder.allowsJSON5` is in Foundation. Comments,
unquoted keys, single quotes, trailing commas and `.25` all decode with nothing
added to `Package.swift`. Verified compiling and running against macOS 14.
`TOMLDecoder` is decode-only, and `TOMLKit` wraps toml++ — C++ interop in an
executable that has to be signed and notarized.

**And toml++ discards comments when parsing anyway**, so it does not even solve
the round-trip: the custom writer has to be written either way.

**The syntax does not suit this data.** A zone is four numbers and a name. In
TOML that is `[[layouts.zones]]` at five lines each — twelve zones become sixty
lines in which the geometry is invisible — or inline tables, which are JSON5
with worse rules, since TOML 1.0 forbids newlines inside them and forbids the
trailing comma. A nested, ordered, homogeneous array is JSON's home ground.

**"Plain JSON without comments for v1" was rejected outright.** A config file
without comments is not a config file, it is a dump, and it contradicts the
whole thesis. The real objection behind that suggestion — that accepting `//` on
read and dropping it on write is worse than not accepting it at all — is
correct, and is exactly why comment custody is mandatory rather than optional.

**`.json5` and not `.json`**: a file containing `.25` and unquoted keys that
calls itself `.json` lies to every tool in the world.

### The round-trip: canonical writer, not surgical splicing

The alternative was to splice edited values back into the original text,
preserving everything untouched. It loses because the zone table is aligned into
columns — that alignment is what makes the file read like a table and makes
changing one zone a one-line diff — and **alignment is unsustainable under
splicing.** Replace `0.25` with `0.3333` and the columns rot; every edit leaves
the file slightly uglier. Splicing also cannot express add, delete or reorder
without ad-hoc text surgery, which is a new class of bug per operation.

The social contract is `gofmt`'s: the format is canonical, and `zonas fmt` makes
it canonical **when you ask**, so the one large reformat is a deliberate,
reviewable act rather than a surprise.

One component, `LayoutSyntax`, does five jobs: JSON5 tokenizer → ordered tree
where each node carries its comments (leading, trailing, blank-line-before) →
from which come (a) the typed model, (b) the canonical render, (c) survival of
unknown keys, (d) line numbers for schema errors, (e) the tree migrations run
against.

**The writer must render from the tree, not from the `Codable` structs.** If it
serializes the typed model, any key that version of the app does not know about
vanishes silently. The tree keeps it. This also makes migrations fifteen lines
over a loose tree instead of historical structs living forever.

**Shipped 2026-08-04** as `LayoutSyntax` and `LayoutParser`, with the schema
layer next to it in `LayoutSchema`. The prototype this was measured on lived in
`docs/prototypes/` and is deleted; the measurements it produced are now tests,
which is strictly better because they run on every push instead of once. The
hand-written example it was measured against is
`Tests/ZonasTests/Fixtures/example.json5`, and it has since grown a comment in
every position the format allows — see below for why that mattered.

The prototype's five checks are now `LayoutSyntaxTests`:

```
1. Foundation JSON5 accepts the output ....... theOutputIsStillJSON5
2. Idempotent: render(parse(render(x))) ...... renderingIsIdempotent
3. Comments in / comments out ................ noCommentIsLost
4. Unknown keys survive a round trip ......... unknownKeysSurvive
5. Errors name the line .................. LayoutSyntaxErrorTests
```

### The test that is a merge condition

The writer was then **broken on purpose** — trailing-comment handling for arrays
removed — to see which test caught it:

```
2. Idempotent ................................ STABLE byte for byte   <-- still passes
3. Comments 14 in / 12 out ................... LOST: ["// the work one", "// keep it last"]
```

**Idempotency does not catch comment loss.** The conservation test does, and it
is five lines: harvest the comments from the original, harvest them from the
render, the difference must be empty. Without it in CI, the canonical-writer
design is not recommended at all.

> **Two things learned re-running this against the real implementation, and
> both are the same lesson.**
>
> **A test that exists is not a test that bites.** With the writer broken
> exactly as above, the conservation test *passed* — because the example file
> had no comment sitting on an array element, so there was nothing in that
> position to lose. The fixture now carries a comment in every position the
> format allows, and with that, breaking the writer reproduces the table above
> against `LayoutSyntaxTests`, verbatim, down to the two comment texts.
>
> **Comparing sets is not conservation.** Harvesting into a `Set`, which is the
> obvious implementation, calls it survived when one of two identical comments
> is dropped — and the same comment appearing twice in a real config file is
> ordinary. `LayoutSyntax.lost(from:to:)` counts repeats.

### What it does not preserve, said before someone discovers it

Blank-line grouping beyond one boolean per node, and comments floating where
there is no node to attach them to (they attach to the following node, by a
deterministic rule). ASCII diagrams **do** survive — the lexer keeps the text
verbatim. The document preamble needs its own document-level slot.

### The boundary

**The file carries only what you would want in git.** Which layout is currently
active, the editor window's position, snapshots — `UserDefaults`, never the
file. MacsyZones gets this wrong, keeping `currentLayoutName` in the same JSON
it rewrites on every launch.

---

## 5. The editor

> **Started 2026-08-04, as the narrow editor.** §7's "legitimate fallback" was
> taken deliberately rather than after running out of days: split zones and move
> edges, no layout management. It is being built in five stretches, and the
> first one has landed (`218a82a`).
>
> | Stretch | What it is | |
> |---|---|---|
> | 1 | The window: one per screen, dimmed desktop, zones drawn, **no editing** | **done** |
> | 2 | Click to split, ⇧ rotates the axis, hover preview, ⌘Z | **done** |
> | 3 | Edge dragging with collinear coalescence, ⌥ to break it | **done** |
> | 4 | Rational snapping, px+fraction labels, delete | **done** |
> | 5 | The write path through `LayoutSyntax`, undo, conflict banner | **done** |
>
> **All five have landed.** The narrow editor is complete: click a zone to cut
> it, drag a divider to move everything collinear with it, ⌥ for one side and
> off the grid, ⌫ or the ✕ to delete, ⌘Z, Revert, and the file written as you
> go. What is deliberately *not* in it is §5's numeric panel, its templates and
> its layout management — those belong to the wider editor, and the file is
> where they live in the meantime.
>
> **Stretch 1 offering no editing was the point, not a shortfall.** Everything
> difficult about an editor is in the window — the coordinate space, the levels,
> the Spaces, the keyboard, the app's own event tap — and none of it is easier
> to debug underneath a drag gesture. What it found is written up under
> "What stretch 1 established" below, and the tap suspension in particular
> turned out to have a second half that this section did not know about.
>
> Note that the write path is stretch **5**, not stretch 2. Everything before it
> edits an in-memory document and shows it; nothing touches the file. That
> ordering is Rule 1 read the strict way: the syntax exists, so the editor may
> be built against it, but the editor becomes a *writer* last, when there is
> something worth writing and the conflict question has an answer.

### Full-screen over the real desktop

One window per screen, exactly `screen.visibleFrame`. The strong argument is not
visual: at 1:1, **one editor point equals one point of the space the zones live
in**. There is no scaling arithmetic anywhere, and the fraction↔point conversion
is the same line that already exists in `Zone.rect(in:)`. Less code, not more.
And `visibleFrame` already discounts the menu bar, the Dock and the notch, so
the notch is handled without writing anything.

A scaled editor lies. At 3.56:1 it lies unusably.

Behind it goes **the real desktop dimmed to 40%** — a translucent fill, not a
screenshot. A screenshot would need Screen Recording permission, which would be
an adoption disaster for an app that already fights for Accessibility.

**The highest-value reuse in the existing code:** `OverlayController` already
draws zones full-screen, per screen, with `Coords` solved. The editor is that
same code with `ignoresMouseEvents = false`, hit-testing and handles. The deltas
are keyboard (needs an `NSWindow` subclass with `canBecomeKey → true`), focus
while `.accessory` (`NSApp.activate()` before `makeKeyAndOrderFront`; do **not**
switch to `.regular`, it bounces the Dock), Spaces (**no** `.canJoinAllSpaces`,
unlike the drag overlay — the editor stays on the active Space), and
**suspending `DragMonitor`'s event tap while the editor is open**, or Shift
inside the editor fires the drag overlay and the two fight.

Levels: the editor goes at `.floating` (3), *below* the menu bar, so you can see
the strip you are excluding. The drag overlay stays at `.popUpMenu` (101)
because it has to cover the window being moved.

### What stretch 1 established

Everything above held. Four things it did not say, all found by running it
rather than by testing it:

**The shared piece is the geometry, not the window.** `Coords.cgToView(_:filling:)`
turns a CG rectangle into the coordinates of a view covering one screen's usable
area, and `Layout.viewFrames(in:)` is the whole of what the overlay and the
editor have in common. Extracting it improved it: flipping against the desktop's
ceiling and then subtracting the window's origin uses `primaryMaxY` twice with
opposite signs, so it cancels, and the function has no global in it at all —
which is why it now has tests that state an answer instead of asking the
machine. The *window* is not shared, and should not be: the four lines where the
two differ are level, Spaces, mouse events and key-ness, which is all of them.

**Suspending the tap has a second half.** Disabling it is not enough, because
the system then delivers `tapDisabledByUserInput` — measured at 48 ms — and the
recovery path that exists to keep the app from going permanently deaf turns it
straight back on. `DragMonitor.isSuspended` is what the recovery path consults.
`start()` consults it too: the editor does not need the Accessibility permission
to draw, so it can be open when the permission watchdog finally succeeds, and
that is the one door into a live tap that does not go through `setEnabled`.

**Do not fill the zones.** The overlay fills each with white at 8% and is right
to; over the editor's scrim the same fill is additive where the scrim is
multiplicative, giving `0.36·b + 0.10` instead of `0.4·b`. On a dark desktop
(b ≈ 0.13) that is *brighter than not dimming at all*, which is exactly what the
first build did and looked like. Zones tile the screen, so a per-zone fill is
not a highlight — it is a second scrim with the opposite sign. Outline and label
carry it. The fill is reserved for stretch 2, where there is a zone to single
out and it will earn its keep.

**Both ways out have to hop a run loop turn.** Escape and Done are both called
while AppKit is delivering an event to the window or to a button inside it, and
closing releases the last reference to that window. Deallocating an `NSWindow`
in the middle of its own `keyDown` is a crash that depends on the autorelease
pool, which means it happens on somebody else's machine and not on this one.

Showing the Dock is the cheap way to exercise display reconfiguration without
unplugging anything: it fires `didChangeScreenParametersNotification` and takes
the ultrawide's `visibleFrame` from 5120 × 1410 to 5120 × 1320.

### What stretch 2 established

The gesture works as designed, including the part that sounded like a flourish:
the default axis really does turn itself round, watched live — two clicks at the
same cursor position cut a zone horizontally and then cut the piece below it
vertically, because by the second click that piece was wider than it was tall.

**The preview is the whole layout, not a line over the current one.** The
candidate goes through the same `split` and the same `viewFrames` as the real
thing, so the two pieces are named and measured where they will be. This is only
affordable because `EditorDocument` is a value type: the view builds a candidate
per mouse move and cannot promote it by accident. Sweeping the cursor across
5120 points at 120 Hz costs 12% of one core, so the redraw-per-move stays.

**`acceptsFirstMouse` has to be true.** A click on an unfocused window normally
only focuses it, and AppKit swallows it — so leaving the editor and coming back
made the first click do nothing. That default is right almost everywhere and
wrong here, because the cut line follows the cursor while the window is
unfocused (`.activeAlways` tracking): the user can see what the click will do,
so swallowing it prevents no surprise and creates a did-that-work?.

**Splitting made the conflict banner necessary, three stretches before the
write path.** Following the file was free while the editor held nothing of its
own. Now an untouched editor follows it and an edited one stops and says so.
The part that is easy to get wrong: undoing back to the start makes the document
untouched again, and *that* has to re-read the file on the spot rather than at
the next save — otherwise the warning clears while the stale version is still on
screen, which is the lie the warning existed to prevent.

**A modifier does not arrive as a `keyDown`.** ⇧ rotating the cut with the mouse
standing still needs `flagsChanged`, forwarded from the window because the window
is the responder certain to see a key event whatever holds focus. Worth knowing
for testing too: posting a synthetic keyDown for the shift key proves nothing,
the posted event has to be of type `.flagsChanged`.

Refusing a cut that would leave a sliver beats clamping one, because clamping
puts a zone where you did not click. The threshold is about aim rather than
about useful window sizes — comfortably more than the eight points the drag
threshold already calls a steady hand — and it explains itself by the cut line
simply not being drawn inside the band.

### What stretch 3 established

**The AppKit argument is real and was measured.** A divider on the laptop was
grabbed, the cursor taken two thousand points onto the ultrawide — right out of
the window that owned the gesture — brought back and released, and the line
ended where the mouse came up. That is the case SwiftUI's `DragGesture` drops
without calling `onEnded`. If anyone ever proposes porting this view, that is
the experiment to run first.

**The sliver band and the grab radius are the same number, and should be.** A
click within forty points of a boundary cannot mean "split" — it would leave a
sliver — and it obviously means "move this line". Sharing the number means every
point of the editor does something, and it costs nothing: a horizontal cut is
decided by the cursor's *y* alone, so giving up the outer forty points of *x*
gives up no cut you could not make forty points along.

**Reach and tolerance are different numbers.** Reach is about aim and is tens of
points; the coalescence tolerance is about what counts as one line and is a
rounding error. On the ultrawide a comfortable reach is already wider than the
tolerance, so one shared number would either make dividers unclickable or glue
unrelated dividers together. They are separate parameters on
`edge(along:near:across:within:tolerance:)` for that reason.

**One undo step per gesture, not per event.** The document is only touched on
the way up; the preview during the drag runs against a copy. Four drags, four
⌘Z, back to the original pixel columns.

⌥ is read live rather than at `mouseDown`, so it can be pressed half way through
a drag and the line shrinks to one side under your hand. And the cursor turning
into a resize arrow is the only thing that tells a divider you can hold from a
cut you can make — both are otherwise an accent line under the pointer.

### What stretch 4 established

**The grid is exactly the file's vocabulary, and that is the whole design.**
`LayoutSchema.fraction` reads `"1/3"` as `Double(1) / Double(3)`, and
`Fraction` produces the same expression, so a value dragged into place and a
value read off disk are the same bits. A grid that did not line up with the
format would put `0.3333333333333333` into somebody's dotfiles and the thesis
with it. There is a test that walks every fraction in the grid against what the
parser would produce for the same string.

**⌥ means "no assistance", and carries both jobs.** It breaks the coalescence
*and* turns the grid off. They belong together — everything else in the editor
is trying to help you land on a number worth writing down, and ⌥ is how you say
you had something else in mind. The cost is that "coalesced but off the grid"
is unreachable; that is the weakest of the four combinations and the numeric
panel (§5, not in the narrow editor) is where it would belong.

**§5's delete rule does not work as written.** "The neighbour sharing the
longest edge" compares a fraction of the screen's height against a fraction of
its width, which needs an aspect ratio — and supplying one does not rescue it:
deleting the top-left zone of this desk's layout offers 1280 points of shared
edge against 720 on the ultrawide, and 432 against 542 on the laptop. The same
delete would absorb into a different neighbour depending on the monitor, for one
layout drawn on both. The rule is now **whether the neighbour lines up with the
victim along the shared edge**, which compares like with like, gives the same
answer on every screen, and picks the zone in the same column or row — the one
anybody would point at. Longest shared edge is the tie-break, file order after
that.

**And §5's "click a zone and press ⌫" has nothing to select with**, because a
click already means "split here". ⌫ acts on the zone under the cursor, which is
the rule the rest of the editor already follows. The ✕ takes priority inside its
own rectangle — an explicit control beats an implicit band — which it has to,
because it lives in a corner and corners are edge-grab territory. The third way
§5 lists, dragging a divider onto its neighbour to collapse the zone between,
is **not implemented**: it fights the clamp, and it needs a visual language for
"this is about to vanish" that nothing else here has yet.

A delete can leave a hole, and it is allowed rather than prevented. Zones are
not required to tile, a hole is dimmed desktop with no outline and therefore
visible the instant it appears, and you close it by dragging. Refusing the
delete instead would let the editor into states it could not get out of.

### What stretch 5 established

**Rule 2 needs one exception for an editor, and exactly one.** A writer that
never loses a comment cannot delete a zone; a writer that deletes zones cannot
make `fmt`'s promise. The difference is the comments attached to the elements
being removed, so `LayoutWriter.survivors` computes that list and everything not
on it still has to survive. Anything else going missing refuses the write, with
`fmt`'s message: this is a bug in Zonas, not in your file.

**Breaking the writer found a bug older than the editor.** A comment attached to
a key *inside* a zone was dropped by the renderer — an inlined row has nowhere
to put one — so the conservation check fired and `zonas fmt` refused to write
such a file at all. An array whose rows carry comments now renders block style.
Annotating one zone costs the whole table its alignment, and that is the right
way round: alignment is a convenience, the comment is somebody's sentence.

**A value that has not changed is not rewritten.** The first version turned
every number in the file into the writer's preferred spelling on the first drag
— a zone nobody had touched went from `0.75` to `"3/4"`. `LayoutSyntax` promises
`.25` stays `.25`, and restyling the untouched half of the file breaks that
promise from the other end.

**Four states where the editor must not write**, and they are most of the work:
while the file does not parse (the store would hand over the last good layout,
and saving it over a half-typed file destroys the thing being fixed); while a
conflict is unanswered (writing answers it "keep mine" without anybody
choosing); for its own echo, compared **as bytes**, because a six-decimal value
reads back a hair different and "is the layout equal" would say no to our own
file; and twice for the same content, which is what lets Revert restore the
original **byte for byte** by writing the source text back rather than
re-rendering it.

`sourceText` is the file as it was when the session adopted it, and every write
applies the whole document to *that* — never to the last thing written. It is
what `rid` indexes into, and the only copy that still holds the comments of
zones that have since been deleted.

The reformat notice is §4 being kept honest by §5: a file that is not canonical
says so in the bar **before the first edit**, while ⎋ is still an answer.

Estimate: 400–600 lines of AppKit on a base that already knows half of it.

**AppKit, not SwiftUI**, for a concrete reason: in AppKit the view that received
`mouseDown` keeps receiving `mouseDragged` even when the cursor leaves its
bounds. SwiftUI's `DragGesture` on macOS is interrupted without calling
`onEnded` when the cursor exits the frame. Dragging a divider across 5120 px,
that is fatal — and a zone editor is almost entirely dragging things fast and
far.

### The interaction

**Primary gesture: a click splits a zone in two.** Hovering shows the cut line
following the cursor; **⇧ rotates the axis**. It is FancyZones' Grid gesture,
proven, and Shift is already this app's vocabulary. The default axis is
perpendicular to the longest side, so on 5120×1440 a full-width zone splits
vertically, and once the columns are taller than they are wide the default flips
by itself. Consequence: **the five-zone ultrawide template is five clicks with
no modifier.**

**There is no tree.** Splitting suggests one, but a tree does not fit in the
file, which is a flat list of rectangles — and putting it there would make the
file nested and horrible to hand-write, while reconstructing it on load is
ambiguous and fragile. Instead: **coalescence of collinear edges.** Grabbing an
edge gathers every edge within 0.5% of the same coordinate, on the same axis,
with overlapping extent, and moves them together. It is *derived* state,
recomputed from the file on open, discarded on close. It feels like i3 without
being i3, and **the one-pixel gap becomes impossible by construction**. **⌥
breaks coalescence** and moves a single edge, which is how you create a gap or
an overlap deliberately.

**⌘ + drag** draws a free zone on top, overlapping. This is not a nice-to-have:
without it the editor would be *less expressive than the file*, since
`zone(under:in:)` already implements smallest-wins precisely to support
overlaps. **⌥⇥** cycles the selection through the zones containing the cursor,
smallest first, so a covered zone can be reached.

**Deleting, three ways on purpose.** The number one complaint about FancyZones
is that deletion is undiscoverable — there is an issue literally titled "how to
remove a zone". The cause is that `Delete` acts on the *divider*, not the zone,
and only from the keyboard. So: click + `⌫`, with the area absorbed by the
neighbour sharing the longest edge; a **✕** on hover; and dragging a divider
onto its neighbour collapses the zone between them.

**Typing numbers.** Double-clicking the label opens an inline panel: name, and
`x y w h` with ⇥. It accepts `1/3`, `0.25`, `25%`, `1280px`, `1/2 - 1/16` — **and
the file accepts exactly the same.** Snapping uses denominators 2, 3, 4, 5, 6,
8, 10, 12, 16 — the same ones the format can write — prioritising other zones'
edges, then rational lines, then screen edges. **⌥ turns snapping off** for
1 pt resolution. You snap to the grid and the file is written as `1/3`, not
`0.3333333333333333`.

**Every zone always shows pixels above and its fraction below** — accent colour
when the fraction is clean, grey decimal when it is not. At a glance you see
whether your layout is tidy: it is the file thesis made visible inside the GUI.

**Holding `Space`** hides all chrome and leaves thin outlines over the undimmed
desktop. **There is no separate preview: the screen is the preview**, which
removes the entire family of "the editor and reality disagree" bugs by removing
the object that was wrong.

One floating HUD bar: layout name, templates, Revert, Done, and a contextual
help line that changes with what you are touching. It costs nothing and is the
direct antidote to the discoverability disaster.

**No OK/Cancel** — the file has been written as you go. The safety nets are the
snapshot taken on open (Revert), a backup ring, and ⌘Z.

**Templates are JSON5 files in `Resources/`, in exactly the format a user hand-
writes**, with a "View as text" button that copies to the clipboard. They are
the format's documentation and cannot drift from it, because they are it.

### Identity without `id`

Identity is stable **in memory**, not in the file. The editor holds
`EditZone { let rid: Int; var name; var x, y, w, h }`; `rid` is minted on load,
drives selection, dragging, undo and comment custody, and **never reaches the
file**. This works because the file is not the authority on identity *during* an
editing session — the in-memory document is. Between sessions there is nothing
to track: nobody needs undo across a relaunch.

In the file the handle is `name`, unique within its layout, validated with a
line number. That is not awkward: the overlay already draws the name over the
zone (`OverlayController.swift:118`), so two zones called "Left" are already a
UX bug. Making `name` required also deletes `init(from:)`
(`Zone.swift:44-54`) — twenty-five lines that exist only because of `id`.

---

## 6. The bet

One feature, and it is the only one on the list where the file is not a
convenient input but **the only reasonable one**: when you configure, the
monitor is not plugged in. A GUI can only offer a dropdown of what is attached
right now; the file describes the world as it will be.

> **Your window layout is a file that lives in your dotfiles and knows which
> monitor it is on — including the ones you do not have plugged in right now.**

This is the office-dock / home-dock / laptop-alone story, which is the most
common multi-monitor reality on a Mac. MacsyZones solves it by remembering a
selection indexed by position in the screens array, which breaks silently when
monitors are reordered. That is not a feature-list bullet: **it is a
demonstrable "we are better" that you prove by unplugging something.** And it
costs ~150 lines on top of multi-layout, which makes it defensible as a bet
rather than a two-month plan.

The two rejected candidates: live reload (edit in vim, zones move) is **table
stakes for the thesis, not the bet** — it is the GIF, it is what makes the
tagline credible, but it is not a reason to migrate. And "the format is pretty"
is not a feature, it is a precondition.

**Mandatory corollary:** `zonas monitors` / *Copy Screen Info* in the menu.
AeroSpace has `list-monitors` and FancyZones has `get-monitors` for exactly this
reason — without it the user does not know what string to write, and the whole
feature is unusable. Config-first does not mean guess.

---

## 7. The staged plan

A "day" is a real, focused working day. With a job in the way, roughly half a
calendar week. **Every stage ships on its own.**

### Stage 1 — "The file is really the truth" · 8 days · **complete except the GIF**

| Piece | Days | |
|---|---|---|
| Model cleanup (all of §3) | 1 | **done** |
| `LayoutSyntax`: tokenizer + tree + canonical writer, **with tests 1–6** | 3 | **done** |
| `LayoutFile` + `LayoutWatcher` (two sources, retry, symlinks) + `LayoutStore` `@MainActor` | 1.5 | **done**, except `@MainActor` |
| Migration `layout.json` v0 → `zonas.json5` v1 with backup; XDG paths with an ambiguity error | 1 | **done** |
| `gap`/`margin`/`modifier` actually honoured (fixes the lying preview) | 0.5 | **done** |
| Icon in alerts + `zonas check` / `fmt` / `monitors` | 0.5 | **done** |
| README split into user and contributor + demo GIF | 0.5 | split **done**; GIF pending |

**`$XDG_CONFIG_HOME` was implemented and then removed**, which is the only
reason the problem was found. A GUI app on macOS is launched by Finder or
launchd and never sees a shell's exports, so honouring the variable means the
app reads `~/.config` while `zonas check` in a terminal reads somewhere else —
silently, and with only one of the two files existing, so the ambiguity error
this piece was supposed to ship cannot catch it. The supported answer for
keeping the file elsewhere is a symlink, which is resolved by the filesystem
rather than by an environment the two do not share, and which the writer and the
watcher already handle properly. The ambiguity error went with it: it existed to
guard a hazard that no longer exists.

**v1 is flat, and that was a decision.** §4's example shows
`version`/`defaults`/`layouts`/`screens`, but `layouts[]` belongs to Stage 3 and
`defaults` to the piece after this one. Introducing the nesting now would make
everybody write `layouts: [ { … } ]` to have *one* layout, which is the exact
objection §4 raises against TOML: structure that hides the geometry and buys
nothing yet. So v1 is `{ version, name, zones }`, and Stage 3 adds `layouts: [
… ]` as an **alternative** form rather than a replacement. The simple case stays
simple and there is no second migration to write.

**The backup is the old file itself**, untouched, in the place muscle memory
already knows. That is a better backup than a `.bak` beside the new one, and
nothing in the migration path can corrupt it because nothing in the migration
path writes to it.

**What migrating taught, which no test had:** running it against a real v0 file
showed the `id` UUIDs coming across, because preserving unknown keys is the rule
and `id` looked like one. It is not: it is a key this project deliberately
removed in §3a, and carrying it across means the first thing a migrating user
sees in their new file is four UUIDs they never typed — the exact complaint §3a
was answering. Dropping keys a migration knows about, while preserving keys from
the future, is the distinction that makes a migration different from a copy.

`LayoutStore` is **not** `@MainActor`. The watcher hops to the main queue before
touching it, which is the guarantee in practice; the compiler-enforced version
belongs with a Swift 6 language mode migration, which is a piece of its own and
is not on this list yet.

The demo GIF is worth its own line, because the thing to film only started
working today: editing the file in vim and watching the zones move. That is the
pitch in five seconds, and until the watcher landed there was nothing to record.

**Ships:** you edit `~/.config/zonas/zonas.json5` in vim, save, and the zones
change — with comments, with `1/3` ratios, with errors that name the line, with
the file in your dotfiles repo and symlinked without the app breaking it.

**Why this is publishable and not scaffolding:** for the dotfiles segment the
editor is not a gap. AeroSpace has 22,133 stars in three years with no
configuration GUI at all, against Amethyst's 16,201 in thirteen years doing the
same thing with one. Publishing here is not publishing an incomplete version: it
is publishing the complete product for the segment where the differentiator is
strongest. **The editor comes later to widen the audience, not to make it
viable.**

### Stage 2 — Distribution · 3 days · parallel with 3 and 4

Notarization, stapling, DMG, GitHub release, Homebrew cask, and the
**first-launch window**.

The first-launch window is the highest leverage per day in the whole plan. Today
a stranger installs, sees a dimmed icon, drags with Shift, nothing happens, and
uninstalls: no UI tells them the permission is missing or what the gesture is,
and they will not read the log. Budget 2 days for notarization, not 1.

Most of the scripting for this already exists uncommitted — see §1.

### Stage 3 — The bet · 4 days

Multiple layouts, `screens` rules by name/glob/`builtin`/`minWidth`, *Copy Screen
Info*, and switching layout by pressing a number during a drag (a second
`.keyDown` tap **enabled only while a modifier drag is in progress** — which
also avoids the uncomfortable question of an open-source project listening to
the whole keyboard all the time).

Keep "which layout goes on which monitor" separate from "re-snap windows on
plug/unplug". The second is another feature, it is expensive and fragile, and
macOS has already moved your windows before you find out. Do not put them in the
same promise.

### Stage 4 — Window robustness · 4 days · **before the editor**

Subrole filtering in `AXWindow.at`, per-app minimum sizes, Electron and Java
(`AXEnhancedUserInterface` has to be turned off during the move in
Chrome/Electron), fullscreen, a bundle-ID exclusion list.

**The ordering argument is strong:** a beautiful editor for an app that cannot
move your Chrome window is worse than the reverse. The editor is used once a
month; snapping is used a hundred times a day. This is also the stage that
prevents the "doesn't work with my app" bucket of issues, which is what sinks a
new repo's reputation.

### Stage 5 — The visual editor · 12 days

| Piece | Days |
|---|---|
| Interactive overlay mode: handles, edge coalescence, split, ⌘-drag | 5 |
| Rational snapping, keyboard nudge, numeric panel, px+fraction labels | 2 |
| The write path through `LayoutSyntax` + undo + conflict banner | 3 |
| Aspect-ratio templates and per-screen assignment from the editor | 2 |

The 8–10 days usually estimated assume an editor that serializes. The editor
that **respects the file** is strictly harder, and that difficulty is the price
of the principle. Worth paying, but budget it rather than discover it.

**Legitimate fallback if 12 days do not fit:** ship a **narrower and excellent**
editor — split and move edges only, no layout management (that stays in the
file). 6–7 days, and it is not behind MacsyZones at what people actually do.

> **Taken, 2026-08-04, and not as a fallback.** The narrow editor is being built
> now, out of order and before stages 2–4, in the five stretches listed at the
> top of §5. The ordering argument in stage 4 below — that an editor for an app
> which cannot move your Chrome window is worse than the reverse — still stands
> and is not being contradicted: what moved is the *editor*, not the release.
> Nothing here ships before window robustness does.
>
> It moved because §5 was the largest pile of undischarged design risk left in
> the document, and every day it stayed on paper was a day the plan was
> confident about things nobody had run. Stretch 1 alone contradicted this
> section twice, in ways written up at the end of §5. Finding that out now is
> worth more than finding it out after stages 2 through 4 have been built on top
> of it.

> **The narrow editor shipped, 2026-08-04**, in the five stretches listed at the
> top of §5. Every one of them contradicted this document somewhere, and all of
> those are written up there rather than here. What is still open from the full
> twelve-day plan: the numeric panel and its expression parser, templates,
> ⌘-drag for free overlapping zones, ⌥⇥ to reach a covered zone, holding Space
> to hide the chrome, and per-screen assignment — which needs Stage 3 first.

### Total: ~31 days plus 20% slack ≈ 37 days

The editor is a third of the project, not the project. A release every 3–4 weeks.

### Critical path

```
format frozen ──▶ multi-layout ──▶ LayoutSyntax.render ──▶ editor
  (Stage 1)        (Stage 3)          (Stage 1)           (Stage 5)
```

---

## 8. How to tell it went wrong

"Both worlds" does not degrade gradually. **It collapses into one**, always by
the same route: the editor accumulates a capability the file does not have, and
from then on the file is a dump with better PR.

**S1 — the headline signal is a sentence.** The first time someone asks *"and
how do I do that from the file?"* and the honest answer is *"you can't"*, it has
already drifted. The rule that prevents it, and it is also the scope rule that
avoids designing every feature twice: **the file syntax is written first,
always, and the editor is a client of that syntax. Never the other way round.**

The inverse asymmetry is healthy and should be stated in the README: everything
you can do in the editor is expressible in the file, and everything the editor
writes stays readable — but not every key has a GUI. Per-app rules, monitor
globs, hooks: file only, and that is fine. The converse is exactly what turns
preference panes into junk drawers.

**S2 — the comment conservation test is a merge condition**, not a
nice-to-have. See §4.

---

## 9. Context worth having

### Competitive reality

**MacsyZones** is free, open source, has a visual editor and uses the same Shift
gesture: 871 stars, 17,635 downloads on its last release, actively developed.
**SnapZones** — $3.99 on the Mac App Store, launched January 2025, identical
interaction — was abandoned five weeks later and has no ratings after eighteen
months.

Demand signal, stated plainly: the three Hacker News posts for FancyZones clones
on macOS scored 1, 1 and 4 points. Rectangle has 29,617 stars; MacsyZones, the
leader in "custom zones", has 871. A factor of 34 between "I want to move
windows" and "I want to draw zones".

**Apple is not the threat.** Three OS releases without going past halves and
quarters. Two to four years of runway.

### If selling ever comes up

The Mac App Store is closed to this: Apple DTS confirmed in October 2025 that a
sandboxed app cannot use the Accessibility APIs. Magnet and BetterSnapTool are
grandfathered from before 2012. Direct distribution is the only channel, which
is what the Developer ID and the notarization work already set up.

Realistic first-year revenue at $9–12 with no existing audience: **$0–1,500**.
Against a Uruguayan tax floor of $3,200–5,000/year if formalizing from scratch,
that is 300–470 sales just to cover the paperwork.

None of which argues against building it. It argues against building it *for the
money*.

### The cheapest experiment available

Install MacsyZones (`brew install --cask macsyzones`) and use it for a week on
the ultrawide, doing real work. Then answer two questions:

1. What does Zonas do that this does not, that matters to someone other than me?
2. When you define zones with its visual editor, does it feel good — or do you
   think "I would write this faster in a file, and take it to my other machine"?

If the answer to (2) is the second one, the bet in §6 is confirmed and the
editor drops off the critical path. If it is the first, the file framing is an
excuse and it is much better to know that before building on it.

### Unresolved

~~macOS 26 showed a *"Support Ending for Intel-based Apps"* notification while
universal binaries were being tested.~~

**Settled 2026-08-04, by measurement: ship universal.** A universal build was
installed and launched on this Apple Silicon machine, and `vmmap` on the live
process says:

```
Path:         /Applications/Zonas.app/Contents/MacOS/Zonas
Version:      0.1.0 (23)
Code Type:    ARM64
```

It runs the arm64 slice natively. It is not an Intel-based app by any definition
the notification could be using, so shipping universal cannot be what shows that
warning to an Apple Silicon user. The notification seen during the release
research almost certainly came from launching one of the x86_64-only
intermediate builds that `release.sh` produces on the way to the `lipo`.

The reasoning that made this worth checking still stands and is worth keeping:
worse than not supporting Intel would have been telling every Apple Silicon user
that your app is about to stop working.

---

## 10. Rules for whoever picks this up

1. **The file syntax is written first. Always.** The editor is a client of it.
2. **The comment conservation test is a merge condition.** Idempotency does not
   catch that bug class — this was proven, not assumed.
3. **The file carries only what belongs in git.** Runtime state goes to
   `UserDefaults`.
4. **The writer renders from the tree, never from the `Codable` structs**, or
   unknown keys vanish silently.
5. **Nothing outside `/Applications` may talk to `SMAppService`**, not even to
   read `status`. BTM keeps one entry per bundle id and rewrites its path to
   whoever asked last. The guard is in `LaunchAtLogin.isInstalledCopy` and it has
   already earned its keep.
6. **Never sign ad-hoc when a real identity exists.** See §2.
7. **When the permission "gets lost", check the signature before anything else.**
   The app logs its own fingerprint at startup for exactly this.
