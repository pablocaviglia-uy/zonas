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

- macOS 14 (Sonoma) or later, Apple Silicon or Intel.
- The **Accessibility** permission. It is not optional: without it the app
  cannot move other applications' windows and fails silently.

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

Zones live in **`~/.config/zonas/zonas.json5`**, stored as fractions from 0 to 1
of the screen's usable area — the part left over after the menu bar, the Dock
and, on the machines that have one, the notch. Keeping them relative instead of
in pixels is what makes the same layout work on the laptop screen and on an
external monitor without redrawing it.

Keep the file in your dotfiles repo and symlink it here. Zonas writes through
symlinks without replacing them, and follows the link when it changes.

The file the first launch writes is JSON5, so it can be written the way you
would write it by hand — with comments, without quoting every key, and with a
comma after the last item:

```js
{
  version: 1,  // the format, not the app

  defaults: {
    modifier: "shift",  // shift | control | option | command
    gap: 8,  // points of air between two windows
    margin: 0,  // points between a window and the edge of the screen
  },

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

## When something is wrong

The menu bar icon turns into a warning triangle whenever the layout file cannot
be read, and the menu above the separator says which line to go and look at.
Clicking that line opens the file.

Zonas keeps the zones it was already using while the file is broken, and does
not touch a byte of what you wrote. Saving a fix puts everything back on its
own — there is nothing to restart.

For anything else, **Open Log…** in the menu opens `~/Library/Logs/Zonas.log`,
which records state changes rather than every event: startup, the signature it
is running under, whether the permission was granted, every reload, and every
window that refused the size it was given.

If the Accessibility permission seems to have stopped working after an update,
that has one overwhelmingly likely cause and it is written up in
[CONTRIBUTING.md](CONTRIBUTING.md#when-the-permission-gets-lost).

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

## Contributing

Building, signing, releasing and how the code is laid out are in
[CONTRIBUTING.md](CONTRIBUTING.md). The reasoning behind the design — and the
measurements behind most of it — is in [docs/PLAN.md](docs/PLAN.md).

## License

MIT. See [LICENSE](LICENSE).
