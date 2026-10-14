> **Imported engine document, rewrite pending.** Copied unchanged from
> AvarKeyboard-iOS `docs/` at commit d249496 (Phase 2 of General Keyboard).
> The behavior it describes is the General Keyboard engine's behavior, but
> file names, targets and examples still refer to the Lezgi and Avar
> projects (`AvarKeyboardExtension/`, `AvarCoreTests`, `avar_words.sqlite`,
> Lezgi words). In this package the same code lives under
> `Sources/GeneralKeyboard/`, the tests under `Tests/GeneralKeyboardTests/`,
> and language data comes from the installed `KeyboardDefinition`. The
> rewrite is tracked in GENERAL_KEYBOARD_PROGRESS.md.

# Bundled artifact contract (Phase 2)

The two read-only databases the keyboard ships with, the canonical
normalization they share with everything else, and the identity rule that
future contribution batches depend on.

Built by `scripts/build_dictionaries.py`, which is the only sanctioned way
to produce them. Never edit an artifact by hand.

## 1. Artifacts

### `avar_words.sqlite`

```
words(word TEXT PRIMARY KEY, base_score INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID
meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)
```

`WITHOUT ROWID` is deliberate: the primary-key B-tree *is* the table, so a
prefix scan reads `base_score` inline — no second lookup, no duplicate
index, and the file shrank from 952 KB to **452 KB**, which matters in a
process with an undocumented and unforgiving memory ceiling.

**`base_score` is opaque to the runtime.** It orders dictionary candidates
among themselves and is never added to, multiplied with, or compared
against personal learning counters. Production ships **0 for every word**
until a reviewed corpus exists, which makes the ordering degrade exactly to
the released behavior (shortest first).

### `avar_bigrams.sqlite`

```
bigrams(prev TEXT NOT NULL, word TEXT NOT NULL, weight INTEGER NOT NULL,
        PRIMARY KEY(prev, word)) WITHOUT ROWID
meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)
```

**Ships with corpus-derived pairs since content_version 2** — adjacent-token
pairs from the av-ru dictionary's 36,845 Avar example sentences, kept when
seen at least twice, both tokens contract-valid, and the suggested `word` is
a row of the words artifact (see `scripts/build_dictionaries.py` and
docs/AVAR_DATA_BRIEFING.md). An empty artifact remains a fully supported
state the runtime must degrade cleanly to, with a regression test proving
equivalence.

Kept as a separate file from the word list, as approved: it changes on a
different cadence, a future corpus update should not force the word list to
be rebuilt, and an empty or missing bigram artifact must never be able to
take the dictionary down with it.

### `meta` — artifact metadata (both files)

| Key | Meaning |
|---|---|
| `artifact` | `avar_words` / `avar_bigrams` — guards against loading the wrong file |
| `schema_version` | shape of the tables; bump when columns change |
| `content_version` | data revision; bump on every content change |
| `normalization_version` | which canonical form the rows are in |
| `min_reader_schema` | oldest runtime that can read this artifact correctly |
| `row_count` | sanity check against a truncated copy |
| `generated_at` | build timestamp, UTC |

Compatibility rule: the runtime reads an artifact when
`min_reader_schema ≤ its own supported schema`. A newer artifact than the
code understands is treated as **absent** rather than parsed optimistically
— a wrong reading of the dictionary is worse than no dictionary.

## 2. Canonical normalization contract

One definition, mirrored in exactly two places that must change together:
`scripts/build_dictionaries.py` (`normalize`) and `Normalization.swift`
(`Normalization.canonical`). Bumping the rules means bumping
`NORMALIZATION_VERSION`, rebuilding both artifacts, and migrating learned
data.

Applies to: bundled words, static bigrams, learned words, learned bigrams,
future outbox rows, and future server-side processing. One form everywhere,
so a word is the same word in all six places.

**Steps, in order:**

1. **Unicode NFC.** A decomposed «й» (и + combining breve) and the
   precomposed U+0439 must not be two different words.
2. **Trim** surrounding whitespace.
3. **Lowercase.** This also maps the uppercase palochka Ӏ (U+04C0) to the
   canonical ӏ (U+04CF).
4. **Palochka repair**, only inside tokens that contain Cyrillic: `I`, `l`,
   `i`, `І` (U+0406), `і` (U+0456) and `Ӏ` (U+04C0) all become **ӏ (U+04CF)**.
   The Cyrillic guard keeps genuine Latin borrowings intact. The digit `1`
   and the pipe `|` are deliberately NOT lookalikes: the keyboard types real
   digits, and repairing «гаф1» into «гафӏ» would turn a token the learned
   store must refuse into one it accepts.
5. **Latin homoglyph repair**, again only inside otherwise-Cyrillic tokens:
   `a c e o p x y k m t b h` → their Cyrillic twins.
6. **NFC again**, which makes the function idempotent by construction:
   `canonical(canonical(x)) == canonical(x)`.

**Validity of a token** (canonical form assumed): non-empty; ≤64 code
points (Swift counts unicode scalars, Python counts code points — the same
number, deliberately, where grapheme counting would quietly diverge on
combining marks); no internal whitespace; no digits; none of `@ / .`; no
Latin letters left after repair; no control (Cc) or format (Cf)
characters — controls include U+001F, the contribution outbox's bigram-key
separator, and formats are the invisibles (ZWJ, bidi marks) that would let
two identical-looking tokens be distinct rows; at least two Avar letters,
where a digraph tail (`ӏ`, `ь`, `ъ`) extends the previous letter rather
than counting as its own, so a lone `цӏ` is one letter and therefore
invalid.

Two footnotes on the Cc/Cf rule. First, trimming: Swift's
`whitespacesAndNewlines` does NOT treat the C0 separators U+001C–U+001F as
whitespace, and Python's bare `str.strip()` does — so the Python half trims
with an explicit Swift-equivalent set (`trim_like_swift`), and a token that
merely *borders* on U+001F stays intact for the validity check to reject.
Second, category assignments come from each platform's Unicode data, which
can differ by a Unicode version; for the characters that matter here (C0
controls, ZWJ/ZWNJ, bidi marks) the categories have been stable for
decades, and any hypothetical drift would surface as a `--check` failure
when artifacts are rebuilt, not as silent runtime disagreement.

### What this found in the shipped dictionary

Running the contract over the released word list surfaced **40 broken
entries** that had been unreachable or subtly wrong:

- trailing whitespace (`'армуд '`) — reachable via prefix match today, and
  tapping it inserted a stray space before the auto-space;
- the Ukrainian `і` (U+0456) used as a palochka (`чіукі` → `чӏукӏ`) —
  untypeable on this keyboard, therefore dead rows;
- Latin homoglyphs inside Cyrillic words (`кӏapax` → `кӏарах`, 5 entries) —
  likewise dead.

All 40 are repaired, 2 collapse into existing rows as duplicates, and
**nothing is dropped**: 20 356 → 20 354.

48 further entries **violate the token contract but are deliberately kept**,
because they are reachable in the released keyboard and removing them would
change suggestions without review:

- 43 single letters / lone digraphs (`а`, `кӏ`, `гь`…) — alphabet rows, not
  words. They sort first today (shortest wins) and dominate the bar for a
  one-letter prefix.
- 5 multi-word phrases (`армуд ар`, `суд –дуван`…) — tapping one inserts a
  phrase where the replacement arithmetic expects a single token.

Both sets are reported by every build. Removing them is a **separate,
reviewed data change**, not a side effect of this phase.

## 3. Stable word identity

**Decision: the normalized word string is the identity.** No numeric IDs.

Contribution batches, learned rows, bigrams and server records all key on
the canonical form from §2. The same word keeps the same identity across
artifact releases because the canonical form is a pure function of the word,
not of a build.

Why not assigned IDs:

- **They buy no privacy.** The server must resolve an ID back to a word to
  use it, so it holds the mapping either way. An ID is indirection, not
  anonymity — and a hash is no better, since a 20 000-word space is trivially
  reversed.
- **Candidate words cannot use them by definition.** An unknown word has no
  ID yet; that is the whole point of contributing it. A scheme with IDs for
  known words and plaintext for new ones is two schemes.
- **Payload size does not justify it.** An Avar word is ~10 bytes UTF-8;
  a batch is a few hundred of them.
- **They introduce a failure mode we would have to operate forever**: an
  append-only ID registry committed to the repo, never regenerated. Lose or
  rebuild it and every historical batch silently misattributes. This is
  exactly the `rowid` / `AUTOINCREMENT` hazard the plan forbade, just moved
  into our own build pipeline.

**This decision is reversible**, which is the other reason to make it now:
adding a `word_id` column later is a purely additive artifact change that
breaks no reader. Choosing IDs today would be the harder thing to undo.

Build-pipeline implication: none beyond determinism. `build_dictionaries.py`
sorts its output and writes fixed page sizes, so the same input produces the
same file, and a diff of two artifact builds shows only real data changes.

## 4. Ranking precedence

Documented in full in `docs/STORAGE_BASELINE.md` §4 and enforced by tests.
The rule that must not be violated: **personal learning and global data are
merged by ordering, never by arithmetic.**

1. **Personal learned candidates come first**, ranked by the released
   formula `(count + 3·picked) × recency × personal-bigram boost`.
2. **Dictionary candidates fill the remaining slots**, ordered by
   `static-bigram weight DESC, base_score DESC, length ASC`.
3. A static bigram can reorder dictionary candidates. It can never promote a
   dictionary word above a personal one, and no static weight is ever added
   to a personal counter.
4. Next-word suggestions with an empty prefix: personal bigrams first; only
   when personal has nothing does the static table contribute. With the
   artifact empty this path is unreachable, which is why the released idle
   behavior is preserved exactly.

## 5. Query cost

Measured with `EXPLAIN QUERY PLAN` against the real artifact.

| Query | Plan before | Plan after |
|---|---|---|
| word prefix | `SCAN words` + temp B-tree | `SEARCH words USING PRIMARY KEY (word>? AND word<?)` + temp B-tree |
| static bigram | — | `SEARCH bigrams USING PRIMARY KEY (prev=? AND word=?)` |

The released keyboard **scans all 20 354 rows on every keystroke**: SQLite
does not apply its LIKE optimization to a `BINARY`-collated column while
`case_sensitive_like` is off, so `word LIKE 'кӏв%'` cannot use the index.
Replacing it with an explicit range (`word >= p AND word < p || char(0x10FFFF)`)
turns the scan into an index search with byte-identical results — LIKE is
case-insensitive only for ASCII, and this dictionary is Cyrillic, so nothing
observable changes.

Every lookup on the typing path is prefix- or key-bounded and carries an
explicit `LIMIT`. No query loads a table.
