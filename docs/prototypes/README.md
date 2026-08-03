# Prototypes

Throwaway code from the design session on 2026-08-03, kept because the
measurements in `../PLAN.md` cite it. **None of this is wired into the app.**

| File | What it proves |
|---|---|
| `final.swift` | The one that matters. JSON5 tokenizer + comment-carrying tree + canonical writer + an edit demo. 43 comments in, 43 out, idempotent byte for byte. |
| `cstbug.swift` | `final.swift` with the writer deliberately broken. Run both: idempotency still passes while two comments vanish. This is why the conservation test is a merge condition and not a nice-to-have. |
| `example.json5` | Hand-written config with ASCII diagrams and ratios — the input. |
| `example.canonical.json5` | What the canonical writer produces from it. |
| `j5.swift` | Smallest proof that `JSONDecoder.allowsJSON5` handles comments, unquoted keys and trailing commas with no dependencies. |
| `sym.swift` | Proves `.atomic` replaces a symlink with a regular file, and that `resolvingSymlinksInPath()` is the fix. See PLAN.md §3b. |
| `watch.swift` | File-watching spike. |
| `sys.swift`, `api.swift`, `tgt.swift`, `cst.swift` | API availability checks against the macOS 14 deployment target. |

Run any of them with `swift <file>.swift`.

Delete this directory once the real implementation lands in `Sources/`.
