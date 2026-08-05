# Working on Zonas

A macOS menu bar utility that snaps windows into user-defined zones when you
drag them with Shift held.

**Read `docs/PLAN.md` first.** It is the handoff document: what is done, what is
next, and — the part that matters — *why* each decision went the way it did.
Most of those reasons cost hours to find and none of them are obvious from the
code. Its §10 is a list of rules that must not be broken; check them before
changing anything they touch.

## Language

**Everything is in English: code, comments, documentation, and commit
messages.** The repository is public, and a contributor who cannot read Spanish
should not be locked out of the reasoning.

Commits up to and including `25a76b3` (2026-08-04) are in Spanish. That was the
earlier convention and the history is left alone; match the current one, not the
old one.

## Commit messages

Narrative, and about the *why*. A commit message here explains what changed and
what problem it solves — including the measurement or the failure that prompted
it, when there was one. Read `git log` for the register: full sentences,
paragraphs, no `fix:` prefixes, no bullet lists.

If a decision went against the obvious alternative, say which alternative and
why it lost. That is the part that stops the next person from cheerfully undoing
it.

## Comments

Comments explain **why**, not what. The code already says what it does. A
comment earns its place by recording something that is not visible from the
code: a measurement, a bug that would otherwise be reintroduced, an API that
lies, an alternative that was tried and failed.

## Commands

```bash
swift build          # compile
swift test           # 217 tests; CI runs this on every push
./build.sh           # wrap the binary in a signed .app
./build.sh release -r # ...and install it in /Applications and open it
```

`build.sh` signs with a real Developer ID from the keychain. Never sign ad-hoc —
`docs/PLAN.md` §2 explains what that breaks and why the symptom costs an
afternoon to diagnose.
