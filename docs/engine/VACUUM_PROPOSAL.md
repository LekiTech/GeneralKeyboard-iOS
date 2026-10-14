> **Imported engine document, rewrite pending.** Copied unchanged from
> AvarKeyboard-iOS `docs/` at commit d249496 (Phase 2 of General Keyboard).
> The behavior it describes is the General Keyboard engine's behavior, but
> file names, targets and examples still refer to the Lezgi and Avar
> projects (`AvarKeyboardExtension/`, `AvarCoreTests`, `avar_words.sqlite`,
> Lezgi words). In this package the same code lives under
> `Sources/GeneralKeyboard/`, the tests under `Tests/GeneralKeyboardTests/`,
> and language data comes from the installed `KeyboardDefinition`. The
> rewrite is tracked in GENERAL_KEYBOARD_PROGRESS.md.

# Proposal: remove VACUUM from the typing path

**Recommendation: delete the `VACUUM` call. Change nothing else.**

Not implemented — this document is for review. If approved it lands as its
own commit, never mixed into the migration or outbox work.

## The problem in one line

`LearnedWords.maintain()` runs `VACUUM` synchronously on the keystroke that
happens to be the 2000th learn event. `VACUUM` rewrites the entire database
file and holds the write lock while it does. It is the only unbounded
operation on the interactive input path.

## Measurements

A benchmark reproduced the production schema and the exact maintenance
sequence (decay every 2000 events, prune every 200, then `VACUUM`) at the
hard caps of 5 000 words and 10 000 bigrams, over 20 decay cycles —
40 000 learn events, far more than a heavy user produces in months.

| Regime | Final size | Peak maintenance | Free pages |
|---|---|---|---|
| **A** never VACUUM | 6 168 KB | 0 ms | 1 |
| **B** VACUUM after decay *(today)* | 5 866 KB | **4.6 ms** | 0 |
| **C** `auto_vacuum=INCREMENTAL` | 6 168 KB | 0.1 ms | 0 |

Growth over time, A vs B:

| After decay cycle | No VACUUM | With VACUUM | Difference |
|---|---|---|---|
| 5 | 6 156 KB | 5 862 KB | 294 KB |
| 10 | 6 168 KB | 5 866 KB | 302 KB |
| 15 | 6 168 KB | 5 866 KB | 302 KB |
| 20 | 6 168 KB | 5 866 KB | **302 KB** |

## Answers to the nine questions

**1. What useful effect does VACUUM provide at the caps?**
It reclaims ~302 KB on a ~6.2 MB database — **4.9 %**. That is the entire
benefit. Nothing else changes: row counts, ranking, decay and prune results
are identical with and without it.

**2. Does decay/prune materially grow the file without VACUUM?**
**No.** The gap appears in the first few cycles and then stops: identical at
cycles 10, 15 and 20. The freelist holds **1 page**, so SQLite is already
reusing the space that decay and prune release — the workload is
steady-state (fill to cap, prune back to cap), which is precisely the shape
where the freelist works. Without VACUUM the file reaches a plateau, not a
slow leak.

**3. Worst-case latency of the current synchronous VACUUM?**
4.6 ms measured at full caps on macOS with NVMe storage and a warm page
cache. That is the floor, not the expectation. On device it is a full
6 MB read-plus-write on iPhone flash, from a memory-capped extension, with a
cold cache — realistically tens of milliseconds, and worse on an older
device or under storage pressure. It lands on one unlucky keystroke.
The `MemoryProbe` scaffolding from Phase 1 can measure the real number if we
want it before deciding; the measurement is not needed to justify removal,
because the benefit side is already known to be 4.9 % of disk.

**4. Is VACUUM necessary at all for this database?**
No. Evidence: the file plateaus without it, the freelist stays empty,
correctness does not depend on it, and 302 KB is not a meaningful amount of
storage on any iOS device. It is a nice-to-have paid for on the input path.

**5. Is `incremental_vacuum` / `auto_vacuum` applicable?**
Applicable in principle, not worth it here, and expensive to adopt:

- `auto_vacuum` must be set **before any table is created**. Turning it on
  for the ~existing production databases requires a full `VACUUM` to
  rewrite the file — the exact operation we are removing, now run on every
  installed device during a migration.
- Regime C measured 0.1 ms but reclaimed **nothing** (6 168 KB, same as
  never vacuuming), because there are no free pages to release; the space is
  internal fragmentation, which `incremental_vacuum` does not touch.
- It would also change the file format flag for every future database.

Paying a one-time full VACUUM on every user's device to gain a mechanism
that measurably reclaims zero is a bad trade.

**6. Can maintenance be deferred to idle or to the containing app?**

- **Containing app: impossible.** `learned.sqlite` lives in the extension's
  own container. Without Full Access the app cannot read it, and Apple's
  sandbox permits the keyboard only *read* access to shared containers, so
  the file cannot be moved somewhere the app could reach either.
- **Keyboard idle: unreliable.** The extension is torn down abruptly when
  dismissed, `viewWillDisappear`/`deinit` are not dependably called, and a
  timer-based "idle" moment may never arrive.
- **Next launch: the only sound deferral point** — `viewDidLoad`, before the
  first keystroke, where a stall is hidden by keyboard presentation. This is
  the fallback if we ever decide compaction is worth keeping.

**7. Threading implications of moving the work off the interactive path?**
Significant, which argues against doing it. The store holds a single
connection opened without `SQLITE_OPEN_FULLMUTEX` and used from the main
thread; sharing it with a background queue is undefined behavior. A correct
version needs a second connection (WAL permits one writer plus readers, so
two writers serialize and can return `SQLITE_BUSY`), a busy-timeout policy,
and a lifetime rule for work that outlives the view — inside a process iOS
kills without warning. That is a lot of new failure surface to preserve
4.9 % of disk. **Removal avoids all of it.**

**8. What happens if iOS terminates the extension during maintenance?**
Today: nothing bad. Decay, prune and `VACUUM` each run as autocommit
statements, and SQLite guarantees atomicity — a kill mid-statement rolls
back cleanly, and WAL recovery handles the rest. The current risk is
**latency, not corruption**, and that distinction matters: we are removing a
stall, not fixing a data-loss bug. After removal the property is unchanged
and one fewer long-running statement can be interrupted.

**9. Smallest production-safe change preserving decay and prune semantics?**

Delete one line — the `exec("VACUUM")` inside the decay branch of
`maintain()`. Decay still halves every counter and deletes zeroed rows;
prune still trims to the caps in the same order; `total_events` still resets;
the maintenance cadence is untouched. No schema change, no migration, no new
threading, no behavioral difference visible to the user, and it applies to
every installed database automatically.

If compaction is later judged worth keeping, the follow-up is equally small:
run it at most once per process launch from `viewDidLoad`, gated on
`PRAGMA freelist_count` exceeding a threshold — never from the input path.
The data above says even that is unnecessary.

## Risks of removing it

| Risk | Assessment |
|---|---|
| File grows unboundedly | Measured false — plateaus at +302 KB and stays there through 40 000 events |
| Storage pressure on user devices | 302 KB; the app bundle alone is larger by orders of magnitude |
| Fragmentation hurts query speed | Every query is prefix- or key-bounded with `LIMIT`; the working set is a few pages either way |
| Regression in learning behavior | None — decay and prune are untouched, and the Phase 1 characterization tests cover both |

## What would land, if approved

One commit: remove the `VACUUM` call, add a test asserting that the
maintenance sequence still produces the documented decay and prune results,
and update `docs/STORAGE_BASELINE.md` §5–6 to drop it from the list of
typing-path work. Separate from all Phase 3 commits.
