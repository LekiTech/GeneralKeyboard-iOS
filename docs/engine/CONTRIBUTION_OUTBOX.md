> **Imported engine document, rewrite pending.** Copied unchanged from
> AvarKeyboard-iOS `docs/` at commit d249496 (Phase 2 of General Keyboard).
> The behavior it describes is the General Keyboard engine's behavior, but
> file names, targets and examples still refer to the Lezgi and Avar
> projects (`AvarKeyboardExtension/`, `AvarCoreTests`, `avar_words.sqlite`,
> Lezgi words). In this package the same code lives under
> `Sources/GeneralKeyboard/`, the tests under `Tests/GeneralKeyboardTests/`,
> and language data comes from the installed `KeyboardDefinition`. The
> rewrite is tracked in GENERAL_KEYBOARD_PROGRESS.md.

# The contribution outbox

Status: **structurally present, functionally inert.**
`Contribution.isEnabled == false` in every build shipped so far, and there
is no exporter, no App Group write, no networking, and no background task
anywhere in the target. This document describes what the queue *is*, so
that the phase which turns it on has a specification to be checked against
rather than a blank page.

---

## 1. Why a queue at all

The long-term goal is an Avar corpus improved by the people who actually
write Avar. That needs contributions, and contributions need a place to
accumulate between the moment someone types a word and the moment a batch
is offered for review — a place that survives the extension being killed
mid-sentence, which iOS does routinely.

The queue lives in `learned.sqlite`, in the keyboard's own sandbox. Not the
App Group: the App Group is an export bridge for a later phase, and putting
a queue there would mean writing user data outside the extension before
anyone has agreed to anything.

## 2. What may be in it, and what may not

| May hold | May never hold |
|---|---|
| A canonical token | Raw keystrokes |
| A canonical token pair | Sentences, or any span of text |
| `typed` / `picked` / `confirmations` counters | Field contents, passwords, clipboard |
| A batch UUID, per batch, discarded on acknowledgement | Keystroke timings |
| | Device or person identifiers, accounts, ad IDs |

This is enforced structurally rather than by review: the table has exactly
three TEXT columns — `kind` (an enum), `key` (canonical tokens), and
`batch_id` (a UUID) — and everything else is an integer. There is no column
a sentence could fit into.
`ContributionOutboxTests.testEveryColumnIsATokenOrAnInteger` fails if a
fourth text column ever appears, so widening the surface has to be a
deliberate act that deletes an assertion.

## 3. Schema (`schema_version` 2)

```sql
CREATE TABLE outbox(
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    kind          TEXT NOT NULL,           -- word_delta | candidate | bigram_delta
    key           TEXT NOT NULL,           -- canonical token, or prev + U+001F + word
    typed_delta   INTEGER NOT NULL DEFAULT 0,
    picked_delta  INTEGER NOT NULL DEFAULT 0,
    confirmations INTEGER NOT NULL DEFAULT 0,
    first_seen    INTEGER NOT NULL,
    updated_at    INTEGER NOT NULL,
    batch_id      TEXT NOT NULL DEFAULT ''  -- '' means unclaimed
);
CREATE UNIQUE INDEX idx_outbox_aggregate ON outbox(kind, key, batch_id);
CREATE INDEX        idx_outbox_unclaimed ON outbox(batch_id, id);
```

`batch_id` is `NOT NULL DEFAULT ''` rather than nullable for a reason worth
recording: **SQLite treats NULLs as distinct inside a UNIQUE index.** With a
nullable column, `(kind, key, NULL)` would never collide with itself, the
upsert would insert a fresh row per event, and the "aggregated queue" would
quietly become a per-keystroke log — precisely the artifact this design
exists to make impossible. The sentinel is what makes aggregation
aggregate.

## 4. Aggregation keys

One row per `(kind, key, batch_id)`, counters accumulated in place.

| Kind | Key | Meaning |
|---|---|---|
| `word_delta` | canonical word | a word already in the bundled dictionary |
| `candidate` | canonical word | a word absent from the dictionary |
| `bigram_delta` | `prev` + U+001F + `word` | an ordered pair, both sides canonical |

U+001F (unit separator) cannot occur in any VALID token — canonicalization
alone does not strip it; `isValidToken`'s rejection of control and format
characters is the gate, and every key half must pass that gate to enter the
queue. That is what makes the bigram key unambiguous — pinned by
`testASeparatorBearingTokenCanNeverBeAValidKeyHalf` and
`testBigramEncodingIsInjective`.

The consequence that matters: **the queue grows with the number of distinct
words a person uses, never with the number of keystrokes.** A hundred
typings of `кӏвал` are one row with `typed = 100`. Typing rhythm, sentence
length, and message boundaries are not merely unrecorded — they are
unrepresentable.

**Key validity is enforced at the door.** A word key must be a single
canonical, valid token; a bigram key must survive `decodeBigramKey`, the
exact inverse of the encoder — exactly two halves, each canonical and
valid. Since `Normalization.isValidToken` rejects every control (Cc) and
format (Cf) character, no valid token can carry the U+001F separator, which
makes the encoding injective: the separator's position in a well-formed key
is unique, and two different pairs can never encode to the same string.
Non-canonical keys are refused rather than repaired — by the time a word
reaches contribution recording it has already passed the canonical write
path, so a non-canonical key is an upstream bug that repair would mask.

**All counters saturate.** Deltas are clamped to `[0, 10⁹]` in Swift before
they reach SQL (the first INSERT takes values raw, so it needs its own
bound), and every accumulation arm is `MIN(x + delta, 10⁹)`. A malformed
database with a counter at `Int64.max` cannot overflow either: SQLite falls
back to REAL arithmetic on integer overflow, and the MIN brings the value
straight back into range. The same ceiling guards the migration's collision
merges.

## 4a. Event semantics

`Contribution.commitEvents` is the executable definition; this table is its
prose twin. Future `base_score` work will consume these counters, so none
of this is implicit.

| The user… | Events |
|---|---|
| manually commits a dictionary word | `word_delta(typed+1)` |
| accepts a dictionary word from the bar | `word_delta(picked+1)` — **not** also typed |
| manually commits an unknown word | `candidate(typed+1)`, one confirmation |
| accepts an unknown (learned) word from the bar | `candidate(picked+1)`, one confirmation |
| commits a word right after another **dictionary** word | additionally `bigram_delta(typed+1)` |
| commits after an **unknown** word, or an unknown word after anything | word event only — unknown words never enter pair context; a pair of names identifies more than either name alone |
| commits an invalid or non-canonical token | nothing, not even the bigram |
| corrects or deletes a committed word | nothing — counters are monotonic; a decrement would need exactly the keystroke-level observation this design refuses to make |

`typed` and `picked` partition the commits, so `typed + picked` is the
total commit count and `picked / (typed + picked)` is an acceptance rate. A
bigram's delta is always `typed = 1`: it records that the pair occurred;
how the second word was entered is the word event's business.

Events fire once per commit, at the same moment `learn()` fires, with the
same token and the same `previous`. The wiring call is
`recordCommit(word:previous:picked:wordIsInDictionary:previousIsInDictionary:)`,
already written and gated; the typing path does not call it yet.

## 5. The gate

Collection requires **all three**, checked together in
`isContributionActive`:

1. `Contribution.isEnabled` — a build-time `let`, currently `false`;
2. `hasContributionConsent` — a `meta` row, absent (and therefore false) on
   every database in the field;
3. `!isReadOnly` — a database from a future schema is never written.

Consent alone collects nothing; the flag alone collects nothing. Both are
tested (`testRecordingIsANoOpWhileTheFlagIsOff`,
`testRecordingIsANoOpWithoutConsent`).

**No historical backfill.** Granting consent starts collection at that
moment; nothing already in `user_word` or `user_bigram` is swept in.
Whatever someone typed before agreeing was typed without an agreement, and
it stays where it is. Pinned by
`testGrantingConsentDoesNotSweepInExistingLearnedData` and, for the upgrade
path, `testTheOutboxStartsEmptyOnAnUpgradedDatabase`.

**Withdrawal empties the queue**, including rows already claimed by a batch
that was never acknowledged.

## 6. Unknown words are held to a higher bar

`candidate` rows carry the sensitive material — names, places, private
coinages, a friend's nickname. They accumulate in the queue like anything
else, but they are **not eligible to enter a batch** until
`confirmations >= Contribution.candidateMinimumConfirmations` (3). A word
typed once, by one person, in one context, never becomes exportable.

Dictionary words are not subject to this bar: their existence is already
public knowledge, and only the counter is new.

## 7. Capacity and retention

| Bound | Value | Behavior |
|---|---|---|
| `maxRows` | 2000 | over capacity, evict lowest `confirmations`, oldest first |
| `retention` | 180 days | rows untouched for longer are dropped |

Pruning runs on write, so it costs nothing when nobody is typing. **Claimed
rows are never pruned** — they belong to a batch that may still be
acknowledged (`testClaimedRowsAreNeverPruned`).

Eviction order is deliberate: under pressure what survives is what the
person actually reuses, not what they happened to type most recently.

## 8. Batch lifecycle

```
enqueue ──► unclaimed ──claim──► batch_id=UUID ──ack──► deleted
                 ▲                     │
                 └──── release ────────┘   (crash, or an upload with no answer)
```

* **Claim** moves up to `limit` eligible rows into a fresh UUID. The UUID is
  generated at claim time, never reused, and disappears on
  acknowledgement — it is **not** a device identifier. It exists so a server
  can recognize a retry of the same batch.
* **Events during an in-flight batch start a fresh unclaimed row**, because
  `batch_id` is part of the uniqueness key. The claimed snapshot never moves
  underneath the exporter that read it, and the new event is not lost
  (`testEventsDuringAnInFlightBatchStartAFreshRow`).
* **Reading a batch twice yields identical rows in identical order**, which
  is what lets a retried upload be byte-identical and therefore safely
  deduplicated server-side.
* **Acknowledge** deletes the batch's rows. Acknowledging an unknown or
  already-acknowledged id deletes nothing and reports nothing wrong, so a
  duplicate reply after a crash is harmless. The unclaimed sentinel is
  explicitly refused, so an empty id can never mean "every unclaimed row"
  (`testAcknowledgingTheUnclaimedSentinelCannotWipeTheQueue`).
* **Release** returns an abandoned claim to the queue with counters
  intact. The old batch id then names no rows, so a *late acknowledgement*
  of it deletes nothing that has since been re-queued
  (`testALateAcknowledgementOfAReleasedBatchDeletesNothing`), and a late
  *upload* of it cannot double-count. Release is **per batch**
  (`releaseContributionClaim`): once a batch can have a file on disk,
  releasing indiscriminately would let a second claim duplicate rows that
  are already exported. The blanket `releaseStaleContributionClaims()`
  remains only for tests and for a world with no exports anywhere.

The crash case — killed between claim and acknowledgement — is covered end
to end by `testAClaimThatNeverCompletedIsRecoveredOnTheNextLaunch`: nothing
lost, nothing counted twice.

## 8a. The bridge (proof of concept, directory-injected)

The protocol is split along the target boundary so the two sides cannot
drift: `ContributionBridge.swift` (format, directory layout, atomic write,
the app-side inbox) is compiled into BOTH the keyboard extension and the
containing app; `ContributionExporter.swift` (everything touching
`learned.sqlite`) is extension-only. **Every function takes the bridge
directory as a parameter**, so the entire protocol is tested against
temporary directories.

The production directory is the App Group container
**`group.org.lekitech.avarkeyboard`** — this keyboard's OWN group. Every
keyboard in the family gets a dedicated group
(`group.org.lekitech.avarkeyboard`, …); bridges are never shared across
keyboards, and future keyboards use `org.lekitech.*` bundle identifiers
from the start. The released Lezgi bundle identifiers stay exactly as
shipped, permanently.

Both call sites exist and are inert: the keyboard runs a bridge pass at
dismissal (`viewWillDisappear` — never the typing path), gated on the
build flag, consent, a writable store, and Full Access; the app scans for
batches on foregrounding, which is passive — files exist only if the
keyboard's gated exporter ever wrote any, and today it cannot.

```
outbox ──claim──► Contribution/outgoing/<batch>.json     (keyboard writes)
app reads outgoing ──► Contribution/ack/<batch>.ack      (app writes)
keyboard sees ack ──► rows deleted, both files removed
```

* **One writer per file, handoff by rename.** The keyboard writes
  `outgoing/`, the app writes `ack/`; every write goes to `tmp/` first and
  is renamed into place — atomic on one volume, so a half-written file is
  unobservable. No shared writable SQLite anywhere.
* **The gate, again.** `runContributionBridge` requires the build flag,
  consent, a writable store, AND `hasFullAccess` (passed as a parameter so
  policy is testable). An ineligible pass does nothing at all — losing
  Full Access between claim and export freezes the world; the claim
  recovers on the next eligible pass.
* **Format v1**: `{"batch": UUID, "format": 1, "rows": [{kind, key,
  typed, picked, confirmations}]}` — sorted keys, claim order, byte-
  identical on retry, no timestamps (§9), nothing about device or person.
* **Bounds**: at most `maxPendingFiles` (3) exported files — the
  "containing app never opened" cap; at most `maxBatchBytes` (128 KB) per
  file, enforced by halving the claim until it fits; exported files
  ignored past 30 days are withdrawn — file deleted first, then the claim
  released, so the crash between the two steps leaves only an orphan claim,
  which is the already-recoverable state.
* **Recovery**: a claimed batch with no file on disk is released (counters
  intact); a claimed batch WITH a file is left strictly alone — that
  asymmetry is what makes duplication impossible in both directions.
* **The inbox is defensive**: malformed files, id/name mismatches, and
  unknown format versions are neither acknowledged (an ack deletes the
  keyboard's rows) nor deleted (not the app's file to delete). Withdrawal
  of garbage is the keyboard's retention job.

## 9. Timestamps are local

`first_seen` and `updated_at` exist for retention and pruning, nothing
else. **The future export payload contract must not automatically include
them or any other exact event timestamp** — when a word was typed is
tracking-adjacent information the aggregation deliberately avoids, and
whether any time signal at all (say, a coarse batch age) is worth its cost
is a decision that belongs to the export/privacy phase, not here.

## 10. Not in this phase

No exporter, no serialization format, no App Group write, no
`RequestsOpenAccess` change, no networking, no `BGTaskScheduler`, no consent
UI, no server. Each is its own phase with its own review.

`releaseStaleContributionClaims()` is written and tested but is not yet
called on launch — wiring it in belongs with the exporter that creates
claims in the first place.
