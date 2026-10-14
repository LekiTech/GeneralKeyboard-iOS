> **Imported engine document, rewrite pending.** Copied unchanged from
> AvarKeyboard-iOS `docs/` at commit d249496 (Phase 2 of General Keyboard).
> The behavior it describes is the General Keyboard engine's behavior, but
> file names, targets and examples still refer to the Lezgi and Avar
> projects (`AvarKeyboardExtension/`, `AvarCoreTests`, `avar_words.sqlite`,
> Lezgi words). In this package the same code lives under
> `Sources/GeneralKeyboard/`, the tests under `Tests/GeneralKeyboardTests/`,
> and language data comes from the installed `KeyboardDefinition`. The
> rewrite is tracked in GENERAL_KEYBOARD_PROGRESS.md.

# Storage Baseline — as released (Phase 1A)

What the shipping keyboard actually does with its databases, written down
before any of the contribution work changes it. Every statement here is
either read out of the source or pinned by a test in
`Tests/AvarCoreTests/LearnedWordsBaselineTests.swift`. When a later phase
changes one of these behaviors, that change must be deliberate and named in
its commit.

## 1. Databases, locations, lifecycle

| | Bundled dictionary | Learned store |
|---|---|---|
| File | `lezgi_words.sqlite` (952 KB, 20 356 rows) | `learned.sqlite` |
| Location | app bundle, inside the extension | extension's **own** container, `Application Support` |
| Access | read-only, `SQLITE_OPEN_READONLY` | read-write, `WAL` |
| Shared with the containing app | no | no |
| Opened | once per `WordSuggestions` init | once per `LearnedWords` init |
| Lifetime | tied to `KeyboardModel`, i.e. the extension process | same |

Both handles are opened eagerly when `KeyboardModel` is constructed and
closed in `deinit`. The extension process is created and destroyed around
text-entry sessions, so both opens happen on the critical path of showing
the keyboard. Neither database is ever read into memory: all access is by
prepared statement with `LIMIT`.

`WordSuggestions` keeps one long-lived prepared statement for the prefix
query and re-`reset`s it; every other query prepares and finalizes per call.

## 2. Schema

**Bundled** — `words(word TEXT PRIMARY KEY ASC)`. One column, no metadata,
no version marker, no score. This is the artifact Phase 2 has to extend.

**Learned** — three tables, no indexes beyond the primary keys:

- `meta(key TEXT PRIMARY KEY, value INTEGER NOT NULL)`
- `user_word(word TEXT PRIMARY KEY, count INTEGER NOT NULL DEFAULT 0, picked INTEGER NOT NULL DEFAULT 0, last_used INTEGER NOT NULL)`
- `user_bigram(prev TEXT NOT NULL, word TEXT NOT NULL, count INTEGER NOT NULL DEFAULT 0, last_used INTEGER NOT NULL, PRIMARY KEY(prev, word))`

The composite primary key `(prev, word)` covers the `prev = ?` lookup, and
`user_word`'s primary key covers `word LIKE 'prefix%'`. No additional index
is currently needed; Phase 2 must re-check this once static bigrams join
the ranking query.

`meta` keys in production: `schema_version` (**always 1** — the row is
written with `INSERT OR IGNORE` at creation and never updated),
`total_events`, `filters_version` (1), `palochka_fixed` (1), and the five
quality counters `m_opportunities`, `m_accepted`, `m_typed_manually`,
`m_ignored`, `m_corrected`.

**Consequence for Phase 3:** every database in the field is at
`schema_version = 1`. There is exactly one upgrade path to write.

## 3. Learning semantics

`learn(word, previous:picked:)` lowercases the word, applies the
learnability filter, then upserts:

- typed completion → `count += 1`
- suggestion tap → `picked += 1`
- either way → `last_used = now`
- if `previous` is also learnable → `user_bigram(prev, word).count += 1`

**Rejection conditions** (all verified by test): more than 64 characters;
fewer than 2 Lezgi letters, where a digraph tail (`ӏ`, `ь`, `ъ`) does not
count as its own letter, so a lone `цӏ` is rejected; any digit; any of
`@`, `/`, `.`.

Learning is triggered from four places: a word terminator, space, return,
and the host clearing the field (the "sent without a trailing space" case).
A suggestion tap learns with `picked: true`.

## 4. Ranking, as released

Learned candidates:

```
(count + 3·picked)
  × (last_used within 14 days ? 2 : 1)
  × (1 + min(bigram count with the previous word, 4))
ORDER BY … DESC, last_used DESC
```

Gates: `count + picked >= minVisibleUses` (learning speed: 1 fast — the
product default, 3 normal, 5 conservative) and `LENGTH(word) >= 2`.

Next-word candidates: `count × (recent ? 2 : 1)`, gated at `count >= 2`.

**Candidate precedence** (`KeyboardModel.updateSuggestions`): learned
candidates first, then bundled-dictionary candidates ordered by
`LENGTH(word)`, deduplicated case-insensitively, capped at 3. The two
sources are never mixed numerically — the merge is ordering only. This is
the precedent Phase 2's static bigrams and base scores must follow.

The unknown-word literal is prepended when the composed word is absent from
**both** sources (`WordSuggestions.contains` and `LearnedWords.isRecognized`,
each with its own normalization), and the view renders it in «…».

## 5. Maintenance

`maintain()` runs synchronously at the end of every `learn`:

- `total_events += 1`
- every **2000** events: halve `count` and `picked`, delete rows that fall
  to zero, halve bigram counts, delete zeroed pairs, reset the counter,
  `prune()`. (A synchronous `VACUUM` used to run here; it was removed —
  see docs/VACUUM_PROPOSAL.md.)
- otherwise every **200** events: `prune()`

`prune()` trims to `maxWords = 5000` / `maxBigrams = 10000`, deleting the
lowest `count + 3·picked` first.

A tested consequence worth stating plainly: a word used exactly once is
**deleted** by the next decay pass, because 1/2 = 0. Decay is not a gentle
discount, it is a forgetting mechanism.

## 6. Work on the typing path (measured by reading the call graph)

Per keystroke, `updateSuggestions` issues up to **four** synchronous SQLite
queries: learned prefix lookup, bundled prefix lookup, and — for the
unknown-word literal — `contains` plus `isRecognized`. On an empty prefix it
issues the next-word query instead, plus a random-words query when the bar
falls back to idle.

Per completed word, `learn` adds an upsert, a bigram upsert, and the
`maintain()` bookkeeping.

**Resolved:** a synchronous `VACUUM` used to run inline here every 2000
learn events, rewriting the whole file and holding the write lock on
whichever keystroke triggered it — the only unbounded operation in the
input path. It was removed after measurement showed the file plateaus
without it (docs/VACUUM_PROPOSAL.md). The `VACUUM` in `reset()` stays: it
follows an explicit user action that empties both tables, where compaction
is both wanted and off the typing path.

Nothing else in the input path touches the disk. There is no background
queue: all database work happens on the main thread inside the extension.

## 7. Test coverage after Phase 1

Covered (22 tests): schema and WAL, persistence across reopen, the whole
learnability filter, lowercasing, count/picked semantics and the 3× pick
weight, the visibility threshold and the fast default, the bigram gate and
its ranking boost, `isRecognized`, saved-words filtering and ordering,
deletion cascading to pairs, reset preserving metrics, metric counters,
decay (2000 events, halving, one-off removal), and a performance guard on
the prefix lookup.

Known gaps, deliberately left for later phases:

- **`prune()` at the 5000/10000 caps** — reaching them in a test takes
  thousands of inserts and decay fires first; needs injectable limits, which
  is a production-code change and belongs to Phase 3.
- **`WordSuggestions`** — its initializer resolves the bundled database
  through `Bundle(for:)`, which does not resolve inside the SwiftPM test
  module. Phase 2 gives it the same optional-path treatment `LearnedWords`
  just received, and the dictionary gets covered then.
- **`migrateLatinPalochka` / `purgeUnlearnableWords`** — both are one-shot
  data migrations gated by `meta` flags; Phase 3 re-expresses them as
  idempotent registry steps and tests them against a synthetic pre-migration
  database.
- **Concurrency** — there is none to test today (single-threaded, main
  thread only), which is itself worth re-verifying if any phase introduces a
  background queue.
