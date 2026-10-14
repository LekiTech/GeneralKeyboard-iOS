> **Imported engine document, rewrite pending.** Copied unchanged from
> AvarKeyboard-iOS `docs/` at commit d249496 (Phase 2 of General Keyboard).
> The behavior it describes is the General Keyboard engine's behavior, but
> file names, targets and examples still refer to the Lezgi and Avar
> projects (`AvarKeyboardExtension/`, `AvarCoreTests`, `avar_words.sqlite`,
> Lezgi words). In this package the same code lives under
> `Sources/GeneralKeyboard/`, the tests under `Tests/GeneralKeyboardTests/`,
> and language data comes from the installed `KeyboardDefinition`. The
> rewrite is tracked in GENERAL_KEYBOARD_PROGRESS.md.

# Emoji memory audit (Phase 1B)

## Why this audit exists, and what it is not

The plan flagged the emoji page as the most likely way for this keyboard to
be killed by jetsam. That suspicion came from a published measurement on a
third-party keyboard: rendering 1 854 emoji drove dirty memory from 3.7 MB
to **127.6 MB**, and it stayed there after the view was dismissed, because
CoreText caches roughly 65 KB per emoji glyph bitmap in an `NSCache` that
nothing purges on view teardown.

Two things must be said plainly before any of that is applied to us:

1. **There is no documented memory limit for keyboard extensions.** Apple
   publishes none. The famous "48 MB" traces to a jailbreak tutorial editing
   `com.apple.jetsamproperties.N61.plist` — an iPhone 6, 1 GB of RAM, iOS 8/9
   era. The most-cited "source" for it (React Native's App Extensions page)
   attributes the number to an Apple guide that contains no numbers at all.
   Published community figures span 30, 40, 48, 60 and 70 MB with no
   agreement. Apple DTS, asked directly whether official documentation of
   extension limits exists, answered "No", and separately warned: *"You
   should not hard code knowledge about these limits into your code."*
   Extension limits have demonstrably moved between iOS releases.
2. **The 127 MB measurement is one developer's blog post about a different
   keyboard.** It is plausible and specific, but single-source and not
   reproduced here. We do not port fixes based on it. We measure ours.

So this document contains a code review and a measurement procedure — not a
rewrite.

## What the code actually does

`KeyboardView.emojiPage`, `makeEmojiColumns()`, `emojiColumn(_:)`,
`EmojiData` (1 914 emoji in 9 categories, plain string literals).

**Rendering is lazy, and deliberately so.** The grid is a horizontal
`ScrollView` containing a flat `LazyHStack` of small uniform columns of ≤5
emoji. The existing source comment records that the obvious alternative was
already tried and rejected: *"nested lazy containers defeat laziness — every
cell gets created for layout and the keyboard extension hits its memory
limit on device."* So the worst case that produced the 127 MB figure — the
entire catalog rendered at once — is structurally not what we do. Only the
columns near the viewport materialize.

**No image assets are involved.** Emoji are `Text` glyphs at 26 pt, not
`UIImage`s, so the ×8.5 file-size-to-resident expansion measured for PNG
sheets in other keyboards does not apply.

**Nothing retains rendered content across pages.** Switching back to letters
drops the whole `emojiPage` subtree; no `@State` holds views, cells, or
images. `recentEmojis` holds at most 24 strings in `UserDefaults`.

Two findings worth recording, neither of them a leak:

- **`makeEmojiColumns()` runs on every body evaluation of the emoji page.**
  It allocates ~383 `EmojiColumn` structs, each with a 5-element array of
  string references, every time the page re-renders (scroll position change,
  category change, theme change). Strings are shared, so this is allocation
  churn rather than growth — but it is avoidable work that could be hoisted
  into a lazily-initialized static, since the catalog is immutable and only
  the recents group varies.
- **The CoreText glyph cache is the only plausible growth path we have**,
  and it grows with how far the user scrolls, not with catalog size. It is
  invisible to Instruments' allocations view (it lives in CoreText's own
  cache) and shows up only as `phys_footprint`. That is exactly what the new
  probe measures.

**No repository-level retention defect was found.** If the measurement below
shows footprint climbing across open/close cycles and staying high, the
cause is the CoreText cache, and the fix is a separate, deliberate change —
not part of Phase 1.

## Instrumentation added

`MemoryProbe.swift` — entirely inside `#if DEBUG`, so Release builds contain
nothing. It reports `phys_footprint` from `task_vm_info`, which is the
number jetsam actually judges (`resident_size` overstates it by counting
shared pages), and tracks a running peak so a spike that is released before
the next sample still appears.

`KeyboardViewController` samples it at `viewDidLoad` and on every
letters ⇄ emoji page transition. Never per keystroke.

## Device measurement procedure

Do not use the Xcode debugger for this. Attaching extends the extension's
process lifetime and suppresses the very teardown behavior under test.

1. Install a **Debug** build on a physical device. Detach Xcode entirely.
2. On the Mac: `log stream --predicate 'subsystem CONTAINS "AvarKeyboard"' | grep kb-mem`
3. Run the sequence below, letting each step settle ~2 s, and record the
   `footprint` / `peak` pair after each:

| # | Action | What the number means |
|---|---|---|
| 1 | Open the keyboard in Notes | Baseline for letters only |
| 2 | Type ~20 words | Baseline + suggestion machinery |
| 3 | Open emoji, do not scroll | Cost of the first visible columns |
| 4 | Scroll the entire catalog to the end | Worst case for the glyph cache |
| 5 | Return to letters | **The key number** — how much did not come back |
| 6 | Repeat 3–5 five times | Growth per cycle: flat = fine, monotonic climb = CoreText retention |
| 7 | Switch keyboards away and back ten times (globe) | Controller accumulation across sessions |
| 8 | Repeat 1–7 in Messages, Safari, and WhatsApp | Host-dependent teardown; a peer report shows extension instances accumulating in WhatsApp but not in Messages |
| 9 | Note any keyboard that silently reverts to the system keyboard | That is the jetsam kill, and it leaves no crash log |

Devices: at minimum one recent (iPhone 15/16/17) and one older, lower-RAM
device, since limits scale with hardware and old devices fail first.

## How to read the result

- **Flat across cycles** — the emoji page is not our memory problem, and the
  suspicion from the plan is retired with evidence.
- **Climbs and plateaus** — the CoreText cache is filling with the glyphs
  actually rendered. Bounded, and acceptable if the plateau leaves headroom.
- **Climbs monotonically across cycles** — genuine retention. Only then do we
  consider mitigation, as a separate change with its own before/after
  numbers.

Record the numbers in this file when the run is done. Until then this
section is deliberately empty: no measurement has been performed yet, and no
number should be quoted as if it had.

## Result

_(not yet measured — awaiting the device run described above)_
