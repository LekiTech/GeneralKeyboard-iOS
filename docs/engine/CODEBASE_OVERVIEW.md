> **Imported engine document, rewrite pending.** Copied unchanged from
> AvarKeyboard-iOS `docs/` at commit d249496 (Phase 2 of General Keyboard).
> The behavior it describes is the General Keyboard engine's behavior, but
> file names, targets and examples still refer to the Lezgi and Avar
> projects (`AvarKeyboardExtension/`, `AvarCoreTests`, `avar_words.sqlite`,
> Lezgi words). In this package the same code lives under
> `Sources/GeneralKeyboard/`, the tests under `Tests/GeneralKeyboardTests/`,
> and language data comes from the installed `KeyboardDefinition`. The
> rewrite is tracked in GENERAL_KEYBOARD_PROGRESS.md. The sticker pack
> and messenger export described here originally were removed from the
> products in 2026-10, and their entries from this file.

# Codebase Overview

A practical map of the project for future developers and AI agents. It
describes the implementation as it is today — see
[LOCAL_SUGGESTIONS_ROADMAP.md](LOCAL_SUGGESTIONS_ROADMAP.md) for what is
planned but not built (roadmap Stages 1–5 are implemented; Stage 6+ are
not).

## Keyboard definition boundary (General Keyboard, Phase 1)

Since 2026-10-13 every Avar-specific value reaches the engine through one
`KeyboardDefinition` (`KeyboardDefinition.swift`), bound to
`AvarDefinition.definition`. Engine files spell no language data; this is
tested (`DefinitionTests.testEngineFilesSpellNoLanguageData`).

| File | Holds |
|---|---|
| `KeyboardDefinition.swift` | Engine types: `KeyboardDefinition`, `LanguageData`, `LayoutCapabilities` / `LayoutStyleSpec` / open `LayoutStyle` ids, `KeyLabels`, `TextConventions`, `KeyboardStrings`, `BundleInfo` |
| `NormalizationProfile.swift` | Script/language data of the canonical form; built-in `dagestanianCyrillicV1` |
| `AvarDefinition.swift` | Assembles the Avar definition; binds `KeyboardDefinition.current` |
| `AvarLayout.swift` | Both Avar styles: rows, number/symbol pages, callouts, metrics, settings names |
| `AvarStrings.swift` | Every native UI string, key names, return labels, emoji section titles |
| `AvarIdentity.swift` | App Group id, compiled into the keyboard and the container app |

`KeyboardLayout.swift` keeps the engine side (key types, metrics type,
case rules, widths, fonts) and reads per-style data from the definition.
Characterization tests (`CharacterizationTests`, `ViewSnapshotTests` with
reference images in `Tests/AvarCoreTests/Snapshots/`) pin the persisted
state and every rendered screen of the released 1.0.0 build.

## Project rule: documentation stays current

Any future code change must update documentation when relevant:

- If behavior changes, update the relevant docs.
- If suggestion logic changes, update the suggestion sections here.
- If learning/bigram/storage logic changes, update this overview and the
  local suggestions roadmap.
- If a new class/file is added, document what it does and how it fits in.
- If a roadmap stage is implemented, update the roadmap checkboxes.
- Documentation must describe the current implementation — it must not
  drift behind the code.

## Targets

| Target | Path | What it is |
|---|---|---|
| **LezgiKeyboard** (app) | `LezgiKeyboard/LezgiKeyboard/` | Container app: onboarding screen |
| **LezgiChalKeyboard** (keyboard extension) | `LezgiKeyboard/LezgiChalKeyboard/` | The keyboard itself — everything below is about this target |

Supporting directories: `scripts/` holds the generators (`gen_emoji.py`
for `EmojiData.swift`); `docs/` holds this file and the roadmap.

## Main app files

| File | Responsibility |
|---|---|
| `ContentView.swift` | Onboarding screen: header, install card (visible without scrolling — the button must never require a scroll), feature cards |

## Keyboard extension files

| File | Responsibility |
|---|---|
| `LezgiKeyboardLayout.swift` | **Single source of truth for the layout**: key rows (`LayoutVariant`: «ъ» next to the space bar or in the top row), long-press callouts (digraphs like `цӏ`, `къ`, `уь`), case rules, labels. Palochka is the Cyrillic `ӏ` (U+04CF) everywhere — typed text and dictionary alike |
| `KeyboardViewController.swift` | UIKit bridge (`UIInputViewController`): hosts the SwiftUI view, wires closures, forwards `textDidChange`, owns the `textDocumentProxy` |
| `KeyboardModel.swift` | The brain: pages/shift state, key handling, composed-word tracking, suggestion generation and capitalization, learning hooks |
| `KeyboardView.swift` | SwiftUI rendering: key grid, suggestion bar (with inline learned-word delete), emoji page, preview bubbles, callouts |
| `SettingsPanelView.swift` | Slide-up in-keyboard settings panel (gear key): layout variant, input behavior page, learned-words dictionary with per-word and delete-all, about page |
| `KeyboardSettings.swift` | User-adjustable behavior (Phase 2): suggestion toggles, key behaviors, learning speed, callout delay. Loaded from / saved to the extension's `UserDefaults`; defaults reproduce the pre-settings behavior |
| `WordSuggestions.swift` | Read-only prefix lookup + random idle words in the bundled `lezgi_words.sqlite` (20k+ words) |
| `LearnedWords.swift` | On-device learning store (`learned.sqlite`): word frequencies, bigrams, cleanup — roadmap Stages 1–3 |
| `EmojiData.swift` | Generated emoji catalog; regenerate with `scripts/gen_emoji.py`, never edit by hand |
| `Info.plist` | `RequestsOpenAccess = false` (never change casually — see Privacy), `PrimaryLanguage = lez` |

## Keyboard height

The keyboard is a fixed 250pt (36 suggestion bar + 8 gap + 4×43 key rows
+ 3×11 row gaps = 249, with 1pt slack): a 999-priority height constraint
created in `setupKeyboard()` plus `.frame(height: 250)` on the SwiftUI
root. The inter-row spacing lives in two places that must stay in sync:
the key-grid `VStack` in `KeyboardView.body` and `RowView.rowSpacing`
(the expanded hit zones tile the row gaps with it).

## Key tap flow

1. `KeyboardView` renders rows from `model.rows(needsGlobe:)` and reports
   presses through the `onKey` closure.
2. `KeyboardViewController.onKey` calls `model.handleKey(cap, proxy:)`,
   which inserts/deletes text through `textDocumentProxy` and updates
   shift/page state, `composedWord`, and the learning hooks.
3. The controller then refreshes suggestions (`model.updateSuggestions`).
4. When the host app confirms the edit, `textDidChange` fires:
   `syncComposedWord` → `updateShiftFromContext` → `updateSuggestions`.

## composedWord / prefix handling

`documentContextBeforeInput` **lags behind fast typing** (it round-trips
through the host app), so the model keeps its own `composedWord` buffer:

- updated synchronously on every keystroke (characters append — including
  multi-character digraphs; backspace removes one character; space, return,
  separators, and accepted suggestions clear it);
- backspacing the single trailing space of a completed word **resumes
  composing that whole word** (extracted from the pre-delete context) — the
  bar switches from next-word predictions to suggestions for the full word;
  only this exact transition resumes, all other deletions are unchanged;
- resynced from the settled context on every `textDidChange`;
- `wordPrefix(proxy:)` returns `""` when the context ends with a separator —
  a completed word is never treated as a prefix being typed.

`updateSuggestions` uses `composedWord` as the prefix. A suggestion tap
deletes `max(context prefix length, composedWord length)` characters, then
inserts the word plus a space — so it replaces only the active prefix and
never touches the previous completed word (empty prefix ⇒ nothing deleted).

## Suggestion flow

`KeyboardModel.updateSuggestions(proxy:)`:

1. Prefix = `composedWord`; empty prefix ⇒ next-word suggestions (below),
   or fallback words when there are none.
2. Learned candidates come first: `LearnedWords.suggestions(for:previous:)`.
3. Dictionary candidates (`WordSuggestions`, `LIKE prefix%` ordered by
   length) fill the remaining slots; duplicates are removed by
   case-insensitive comparison (dictionary and typed text share the same
   Cyrillic palochka `ӏ`).
4. Top 3 go through `displayForm` (capitalization) and into `suggestions`;
   the learned subset is remembered in `learnedDisplayWords` so the view
   knows which entries support long-press deletion.
5. A typed word unknown to **both** sources — `WordSuggestions.contains`
   fails and `LearnedWords.isRecognized` fails (exact lookups with the
   same normalization and visibility threshold as the prefix queries) —
   is prepended as a literal candidate, exactly as typed, capped with two
   matches. `unrecognizedTyped` marks it and the view alone renders the
   «…» around it (native-style "will learn this" hint); the stored value,
   tap insertion, learning, and deletion counts all use the raw word.
   Recognized words change nothing.

The suggestion bar shows 3 cells; long-press on a *learned* suggestion shows
an inline Lezgi confirmation row («“слово” чӏурдани?» — Ваъ / Чӏурун) that
deletes the record from `learned.sqlite` only. **Never present UIKit alerts
from the keyboard extension** — the restricted environment kills the
keyboard and iOS switches to another one.

## Local quality metrics (Stage 6)

Five plain counters in `learned.sqlite`'s meta table (`LearnedWords.Metric`),
maintained by `KeyboardModel`: `m_opportunities` (completed words that had
predictive candidates — the quoted literal alone does not count; one per
word, not per refresh), `m_accepted` (predictions taken from the bar),
`m_typed_manually` (manual completions, including literal taps and
host-clear sends), `m_ignored` (manual completions that had predictions
available), `m_corrected` (accepted word edited again before any other
word completed — event-based, no timeout). Acceptance rate =
`accepted / (accepted + ignored)`. Read via the DEBUG-only startup log
(Console.app, category "kb-metrics"). Never transmitted, never affects
ranking or learning, survives a learned-data reset. Purpose: a baseline
so every future ranking change is judged by numbers, one change at a time.

## Learned words (learned.sqlite, Stages 1–2)

- Location: the **keyboard extension's own sandbox container**
  (`Application Support/learned.sqlite`, WAL). The containing app cannot
  read it (no App Group without Full Access); deleting the app deletes it.
- Schema: `user_word(word, count, picked, last_used)`,
  `user_bigram(prev, word, count, last_used)`, `meta(key, value)` with
  `schema_version`, `total_events`, `filters_version`.
- Learn events: a word is recorded when completed (space / return /
  sentence punctuation typed after it), when picked from the bar
  (`picked` counter — a stronger signal), and when the host app commits it
  by clearing the field (see "Immediate send" below). Words are stored
  lowercase.
- Filters (`isLearnable`): at least 2 *Lezgi letters* — digraph tails
  (`ӏ`, `ь`, `ъ`, derived from `LezgiLayout.callouts`) do not count as
  letters, so a lone `цӏ` is rejected; no digits; no `@ / .`; max 64
  characters. Bumping `filtersVersion` purges old records that no longer
  pass.
- Visibility threshold: `count + picked >= minVisibleUses`, user-adjustable
  via the settings panel's learning speed (1 / 3 / 5). The product default
  is **fast (1)** — words surface from the first use; the stricter
  thresholds remain the typo-protection option.
- Ranking score: `(count + 3·picked) × 2 if used in the last 14 days ×
  (1 + min(bigram count, 4))`.
- Cleanup: every 2000 learn events all counters are halved (integer
  division — one-off words vanish) and the file is VACUUMed; every 200
  events row caps are enforced (5000 words, 10000 bigrams, lowest-ranked
  rows deleted). Deleting a word also deletes every pair referencing it.

## Local bigrams (Stage 3)

- Stored as `(prev, word, count, last_used)` — two words and a counter,
  never sentences.
- `previousWord(proxy:)` finds the word before the one being typed using
  the same tokenizer as `wordPrefix`, after cutting the context at the last
  sentence boundary (`.` `!` `?` or newline) — **bigrams never cross a
  sentence**. If the host truncates the context, it returns nil and the
  pair is simply skipped.
- Bigrams *rank* prefix suggestions (multiplier above) and produce
  next-word suggestions (below); they never add candidates to prefix
  suggestions. For picked suggestions the previous word is captured
  **before** the prefix is replaced.

## Next-word suggestions (Stage 4)

With no active prefix, the bar suggests likely next words from the learned
bigrams of the last completed word:

- `lastCompletedWord` is tracked synchronously in `KeyboardModel` (the
  proxy context lags): set when a word is completed or a suggestion is
  accepted, cleared by `.` `!` `?`, double-space period, and return — so
  next-word suggestions never cross a sentence boundary — and resynced from
  the settled context on `textDidChange`. After a comma or a plain space
  the last word stays available.
- Candidates come from `LearnedWords.nextWords(after:)`: pairs for that
  word with `count >= 2` (a one-off pair never surfaces), ranked by count
  with the usual 14-day recency boost.
- They are learned data, so long-press deletion applies (it removes the
  learned word and its pairs). Tapping one inserts it without deleting
  anything (the prefix is empty) and reinforces the pair.
- Accepting any suggestion refreshes the bar in the tap handler itself —
  hosts do not send `textDidChange` for the keyboard's own edits — so
  next-word suggestions chain immediately after the accepted word.
- No last word or no confident pairs ⇒ the random dictionary fallback
  below; typing any letter switches the bar back to normal prefix
  suggestions.

## Capitalization

One shared `displayForm(word, prefix:proxy:)` covers learned, dictionary,
and fallback suggestions:

- Caps Lock → whole word uppercased.
- Non-empty prefix → the prefix dictates case: first letter uppercase →
  capitalized; fully uppercase prefix (2+ chars) → uppercased; lowercase →
  as stored. The shift state alone never capitalizes mid-sentence.
- Empty prefix (fallback words) → capitalized only at a sentence start
  (`isCursorAtSentenceStart`: empty field, new line, after `.` `!` `?`)
  and only when the field's `autocapitalizationType` allows it.

The inserted text always matches the displayed form; storage stays
lowercase.

## Random fallback suggestions

When nothing is being typed and there are no next-word suggestions, the
bar shows 3 random dictionary words
(`WordSuggestions.randomWords`), kept in `fallbackWords` and re-rolled on
every *transition* into this idle state — keyboard appearance, or erasing
the typed prefix — never continuously while the bar stays idle
(`KeyboardModel.barWasIdle`); their display form is recomputed on every
context change so they follow the capitalization rules. Tapping one inserts it
without deleting anything; long-press does nothing (they are not learned
records). There are no hardcoded placeholder words.

## Suggestion bar UI

The bar deliberately does not copy Apple (project philosophy: keys feel
native, the bar is best-in-class): cells are content-sized and spread
evenly with flexible gaps, no separators — the press capsule is the only
affordance; empty slots are dropped entirely. Text is 18pt (chosen by
on-device comparison); overlong words shrink to 0.85 before truncating.
`MorphingWordText` mimics a per-glyph morph: a word extended/shortened
while typing animates (retained letters slide, the changed letter fades),
a completely different candidate snaps instantly — layout follows the same
rule because the morph's `withAnimation` transaction propagates through
layout and swaps run with animations disabled. Taps dispatch by measured
cell frames to the nearest cell midpoint (`suggestionCellFrames`), so the
whole bar stays tappable.

## Resetting learned data (Stage 5)

Reset lives in the **in-keyboard settings panel** (`SettingsPanelView`),
off the typing path — the suggestion bar itself has no reset control.

The gear key in the bottom row (`KeyCap.settings`, between «123» and the
emoji key) opens the panel: a slide-up SwiftUI overlay inside the fixed
250pt keyboard with a header (back / title) and stacked pages — home,
layout variant, input («Кхьин»), theme («Тема»), learned-words dictionary
(«Гафарган»), about. The
dictionary page shows the saved words — `KeyboardModel.savedWords()`:
learned words past the visibility threshold that are absent from the
bundled dictionary (checked with `WordSuggestions.contains`). The
learning store also keeps records for dictionary words as internal
frequency/bigram signals; those are never listed, and the counter
derives from the same filtered array as the list. The `×` on a row deletes
one word immediately (`delete(_:)`, pairs included; the bundled dictionary
is never touched), and «Вири чирнавай гафар чӏурун» opens an **in-panel
confirmation sheet** (dim + card, «Чӏурун» / «Ваъ») — only its explicit
destructive button calls `LearnedWords.reset()`, which wipes `user_word`,
`user_bigram`, and the event counter, clears `lastCompletedWord`, and
refreshes suggestions immediately. No UIKit alerts, no modal presentation —
everything stays inside the SwiftUI keyboard view.

The panel is also where the layout variant lives (`LayoutVariant`,
persisted in the extension's `UserDefaults`): «ъ» next to the space bar
(classic, default) or as the 12th key of the top letter row.

### Input settings («Кхьин», Phase 2)

The panel's input page exposes `KeyboardSettings` — behavior toggles only,
no new features. Titles are Lezgi (never localized); each control carries a
small explanatory subtitle localized via the extension's own
`Localizable.xcstrings` (ru + en, English fallback for other system
languages — the same String Catalog approach the container app uses). All
values persist in the extension's `UserDefaults` and default to the
pre-settings behavior:

- **Theme** («Тема», Phase 3): system / light / dark. Deliberately Theme,
  not Appearance — Appearance becomes its own section only if more visual
  settings ever appear. Applied via `overrideUserInterfaceStyle` on the
  controller's root view (a Combine subscription to `settings.theme`), so
  every `dynamicProvider` color re-resolves live — switching in the panel
  recolors the whole keyboard instantly, nothing closes or reloads.
- **Suggestions**: word suggestions master switch (off ⇒ the bar shows
  nothing at all, including fallback words; learning itself continues),
  next-word suggestions, and the automatic trailing space after accepting
  a suggestion (off ⇒ the accepted word stays the composed prefix).
- **Keys**: double-space → period, spacebar cursor/trackpad mode, the
  «ЛЕЗГ» label on the space bar.
- **Learning speed**: sets `LearnedWords.minVisibleUses` — the visibility
  threshold only (fast 1 / normal 3 / conservative 5); the learning
  algorithm itself never changes.
- **Long press**: the character-callout delay (0.2 / 0.3 / 0.45 s); the
  gear key's own long-press stays fixed.

`KeyboardModel.updateSettings` applies a change, saves it, and syncs
model-side state (threshold, clearing the bar when suggestions turn off),
so every control takes effect immediately. A
**long press on the gear key** additionally opens a quick layout menu
above the key (`LayoutMenuBubble`): a small vertical card with the two
variants (title + subtitle, the current one marked by its accent-tinted
title). Dragging highlights the row under the finger; releasing over a
row applies it, releasing outside the card changes nothing. A regular
tap still opens the full panel.

## Privacy / local-first constraints

- `RequestsOpenAccess = false` — the keyboard never asks for Full Access;
  iOS therefore denies it network access at the OS level.
- No server, no analytics, no uploads; everything learned stays in the
  extension sandbox and dies with the app.
- The user can wipe all learned data at any time from the keyboard itself
  (gear key → settings panel → «Гафарган»).
- Only single words and word pairs are stored — never sentences or message
  text.
- iOS swaps in the system keyboard for secure (password) fields.

### Immediate send

Typing a word and tapping the app's own **Send** button (no trailing
space/punctuation) is covered by a narrow signal in
`KeyboardModel.learnWordCommittedByHostClear` (called first from
`syncComposedWord` on `textDidChange`): messengers clear the field after
sending, the host's edit fires `textDidChange`, and the document turns
completely empty (`proxy.hasText == false`) while `composedWord` still
holds the word — that commits it (with the bigram from
`lastCompletedWord`). Deliberately narrow:

- cursor moves, focus changes, and edits that leave text in the field
  never trigger it;
- the keyboard's own edits cannot trigger it (`composedWord` is cleared
  synchronously by space/punctuation/return/suggestion accept, so no
  double-learning);
- nothing is learned on `viewWillDisappear` — a word left in the field is
  a draft, not a commit;
- the Stage 2 filters and the 3-confirmation visibility threshold apply as
  usual, which also absorbs the rare false positives (a search field's
  clear button, tapping into another empty field).

Remaining limitation: hosts that do **not** clear the field on send (e.g.
a mail composer that closes instead) give no signal, and the word is not
learned there.

Any change that would relax these constraints belongs to roadmap Stage 7
and requires the research listed there first.

## Palochka convention

Everything uses the Cyrillic palochka `ӏ` (U+04CF): the layout inserts it,
`lezgi_words.sqlite` stores it (the dictionary originally used Latin `I`
and was migrated in place — all 2,374 affected rows), and the learned
store performs a one-time on-device migration (`meta` key
`palochka_fixed`) that rewrites any leftover Latin-`i` learned rows and
bigrams, merging counters into existing `ӏ`-form rows. No query
normalization between the two forms exists anymore; purely Latin tokens
without Cyrillic letters are left untouched by the migration.
