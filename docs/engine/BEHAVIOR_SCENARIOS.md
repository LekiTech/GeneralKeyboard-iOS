> **Imported engine document, rewrite pending.** Copied unchanged from
> AvarKeyboard-iOS `docs/` at commit d249496 (Phase 2 of General Keyboard).
> The behavior it describes is the General Keyboard engine's behavior, but
> file names, targets and examples still refer to the Lezgi and Avar
> projects (`AvarKeyboardExtension/`, `AvarCoreTests`, `avar_words.sqlite`,
> Lezgi words). In this package the same code lives under
> `Sources/GeneralKeyboard/`, the tests under `Tests/GeneralKeyboardTests/`,
> and language data comes from the installed `KeyboardDefinition`. The
> rewrite is tracked in GENERAL_KEYBOARD_PROGRESS.md.

# Behavior Scenarios

User-facing behavioral scenarios for the keyboard, written as
Given / When / Then. This is a living document: it describes what the user
experiences, never how the code implements it, so it can survive engine
rewrites and eventually become the foundation for automated behavioral
tests. When a behavior changes intentionally, update its scenario in the
same commit.

## Composing and suggestions

**S1 — Unknown word shows as a quoted literal.**
Given an empty field and a word absent from both the bundled dictionary
and the learned words. When the user types it. Then the first suggestion
cell shows the word exactly as typed, wrapped in «…», and the remaining
cells show dictionary matches for the prefix.

**S2 — Known word shows without quotes.**
Given a word present in the bundled dictionary (or fully learned). When
the user types it. Then no quoted literal appears and candidates display
undecorated.

**S3 — Accepting a suggestion.**
Given a word being composed and a candidate on the bar. When the user taps
the candidate. Then the typed prefix is replaced by the full word plus a
trailing space (with the auto-space setting on), and the bar switches to
next-word predictions for it.

**S4 — Accepting with auto-space off.**
Given the auto-space setting off. When the user taps a candidate. Then the
word is inserted without a trailing space and remains the active
composition, extendable by further typing.

**S18 — Punctuation swallows the automatic space.**
Given a word just accepted from the bar with its automatic trailing space
(predictive suggestion or quoted literal alike). When the next text input
is `.` `,` `?` `!` `;` `:` `)` `]` or `}`. Then the automatic space is
removed and the mark lands right after the word («word.», not «word .»).
Quotes never swallow — after a space they usually OPEN a quotation and
the space must stay. Switching to the
«123»/«#+=» page to reach the mark does NOT cancel the swallow — page
switches, shift, and the gear are not text input. A manually typed space
is never removed; typing any other character, space, return, backspace,
or moving the cursor in between keeps the space; with auto-space off
nothing changes.

**S5 — Suggestions follow the sentence context.**
Given a sentence start (empty field, or after `.` `!` `?` — including
when a closing quote or bracket trails the ender, as in «word?» or
word.). When suggestions appear. Then they are capitalized; with Caps
Lock on they are fully uppercased; mid-sentence they appear as stored.
The same rule capitalizes the next typed letter, and the double-space
period also fires after a closing quote/bracket.

## Learning lifecycle

**S6 — A word becomes learned.**
Given a new word typed to completion as many times as the learning-speed
setting requires (1 / 3 / 5). When the user types its prefix afterwards.
Then the word appears as a suggestion, ranked above dictionary matches,
and its literal stops being quoted.

**S7 — Accepting teaches faster than typing.**
Given a quoted literal tapped on the bar. When the word reaches the
learned threshold (a tap weighs more than a typed completion). Then it
behaves as in S6.

**S8 — Next-word prediction.**
Given a pair of words the user has typed in sequence at least twice. When
the user completes the first word of the pair (prefix empty). Then the
second word appears as a next-word suggestion.

**S9 — Deleting a learned word.**
Given a learned word shown on the bar. When the user long-presses it and
confirms the inline «чӏурдани?» row. Then the word disappears from
suggestions and from the saved-words page, the bundled dictionary is
unaffected, and the word can be learned again from scratch later.

**S10 — Saved words are user vocabulary only.**
Given learned records for both dictionary words and genuinely new words.
When the user opens «Гафарган». Then only new words past the learned
threshold are listed, and the counter always equals the number of listed
words.

## Deletion and editing

**S11 — Deleting the trailing space resumes the word.**
Given a completed word followed by a single space, with the cursor after
the space. When the user presses backspace once. Then the whole word
becomes the active composition again and the bar shows suggestions for the
full word — not for its last letters.

**S12 — Deleting inside a word.**
Given a word being composed. When the user presses backspace. Then one
character is removed and suggestions update for the shortened prefix.

## Idle bar

**S13 — Idle words re-roll on return to idle.**
Given the idle bar showing three random dictionary words. When the user
types something and then erases it completely. Then three different random
words appear; while the bar stays idle the words hold still.

## Return key

**S17 — Action-specific return key.**
Given a text field whose action is Search. When the keyboard appears. Then
the return key shows the magnifying-glass icon instead of a text label.
For other actions (Go, Send, Done, Next, …) the key shows its Lezgi label
on a single line; longer labels widen the key slightly (the space bar
absorbs the difference) rather than shrinking the typography.

## Settings effects

**S14 — Suggestions master switch.**
Given word suggestions off. When the user types. Then the bar shows
nothing at all (no candidates, no idle words), while learning continues in
the background and re-enabling restores suggestions immediately.

**S15 — Double space ends the sentence.**
Given the double-space setting on and a word just typed. When the user
taps space twice quickly. Then the text ends with «. », the next letter is
capitalized, and next-word predictions do not cross the sentence boundary.

**S16 — Theme applies instantly.**
Given the settings panel open. When the user picks Экуь or Мичӏи. Then the
whole keyboard — keys, bar, panel, background — recolors immediately
without closing anything; Системадин returns to the host appearance.
