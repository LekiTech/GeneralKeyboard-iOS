//
//  Migrations.swift
//  GeneralKeyboard
//
//  The learned store's migration registry: one monotonic sequence, one
//  step at a time, each step in its own transaction.
//
//  The keyboard extension can be killed at any moment, including mid-
//  migration, and the database it is migrating belongs to a user who has
//  been typing into it since release. Both facts drive every rule here:
//
//  * one transaction per step, so a step either happened or did not;
//  * `schema_version` moves inside the same transaction as the step it
//    describes, so the marker can never disagree with the data;
//  * a database newer than this build is never written to;
//  * data steps are idempotent, so an interrupted run is safe to retry.
//

import Foundation
import SQLite3

private let SQLITE_TRANSIENT_MIG = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum MigrationOutcome: Equatable {
    /// Schema is at the target version; the store is fully usable.
    case ready
    /// The database was written by a newer build. It is left untouched and
    /// the store must operate read-only rather than risk corrupting data
    /// this code does not understand.
    case databaseFromFuture(found: Int, supported: Int)
    /// A step failed; the transaction was rolled back. The caller keeps
    /// working at whatever version it reached — no data is lost, and the
    /// next launch retries.
    case failed(step: String)
}

enum Migrations {

    /// The schema this build understands. Bumped together with a new step.
    static let targetSchemaVersion = 2

    // MARK: - Registry

    /// Schema changes. Each entry brings the database from `version - 1` to
    /// `version`; they are applied in ascending order, one transaction each.
    static let schemaSteps: [SchemaStep] = [
        SchemaStep(version: 2, name: "contribution outbox", apply: createOutbox),
    ]

    /// Content fixes that are not schema changes. Each is idempotent and
    /// gated by its own `meta` marker, so a partially-applied run simply
    /// repeats. They run after the schema is at target.
    static let dataSteps: [DataStep] = [
        DataStep(marker: "filters_version", version: 1, name: "purge unlearnable words",
                 apply: purgeUnlearnableWords),
        DataStep(marker: "palochka_fixed", version: 1, name: "latin i to palochka",
                 apply: migrateLatinPalochka),
        DataStep(marker: "normalization_version", version: Normalization.version,
                 name: "canonicalize learned data", apply: canonicalizeLearnedData),
    ]

    struct SchemaStep: Sendable {
        let version: Int
        let name: String
        let apply: @Sendable (OpaquePointer?) -> Bool
    }

    struct DataStep: Sendable {
        /// `meta` key holding the version this step has been applied at.
        let marker: String
        /// The version the step brings the data to.
        let version: Int
        let name: String
        let apply: @Sendable (OpaquePointer?) -> Bool
    }

    // MARK: - Runner

    static func run(on db: OpaquePointer?) -> MigrationOutcome {
        let current = SQL.int(db, "SELECT value FROM meta WHERE key = 'schema_version'")

        if current > targetSchemaVersion {
            // A downgrade: the user installed a newer build, then rolled
            // back. Writing here could destroy data the newer schema holds.
            return .databaseFromFuture(found: current, supported: targetSchemaVersion)
        }

        for step in schemaSteps.sorted(by: { $0.version < $1.version })
        where step.version > current {
            guard SQL.exec(db, "BEGIN IMMEDIATE") else { return .failed(step: step.name) }
            guard step.apply(db),
                  SQL.exec(db, "INSERT OR REPLACE INTO meta(key, value) VALUES('schema_version', \(step.version))"),
                  SQL.exec(db, "COMMIT")
            else {
                SQL.exec(db, "ROLLBACK")
                return .failed(step: step.name)
            }
        }

        for step in dataSteps
        where SQL.int(db, "SELECT value FROM meta WHERE key = '\(step.marker)'") < step.version {
            guard SQL.exec(db, "BEGIN IMMEDIATE") else { return .failed(step: step.name) }
            guard step.apply(db),
                  SQL.exec(db, "INSERT OR REPLACE INTO meta(key, value) VALUES('\(step.marker)', \(step.version))"),
                  SQL.exec(db, "COMMIT")
            else {
                SQL.exec(db, "ROLLBACK")
                return .failed(step: step.name)
            }
        }

        return .ready
    }

    // MARK: - Schema step 2: contribution outbox

    /// One row per (kind, key, batch): aggregation happens in place, so the
    /// table grows with distinct words rather than with keystrokes. Every
    /// column is a token or an integer — there is deliberately no column a
    /// sentence could fit into.
    ///
    /// `batch_id` participates in the uniqueness key so that a row claimed
    /// by an in-flight batch is frozen: new events start a fresh unclaimed
    /// row instead of mutating data an exporter already read. It is NOT NULL
    /// with an empty-string default because SQLite treats NULLs as distinct
    /// inside a UNIQUE index — a nullable column would defeat the very
    /// aggregation this table exists to perform.
    private static func createOutbox(_ db: OpaquePointer?) -> Bool {
        SQL.exec(db, """
            CREATE TABLE IF NOT EXISTS outbox(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                kind TEXT NOT NULL,
                key TEXT NOT NULL,
                typed_delta INTEGER NOT NULL DEFAULT 0,
                picked_delta INTEGER NOT NULL DEFAULT 0,
                confirmations INTEGER NOT NULL DEFAULT 0,
                first_seen INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                batch_id TEXT NOT NULL DEFAULT ''
            );
            CREATE UNIQUE INDEX IF NOT EXISTS idx_outbox_aggregate
                ON outbox(kind, key, batch_id);
            CREATE INDEX IF NOT EXISTS idx_outbox_unclaimed
                ON outbox(batch_id, id);
            """)
    }

    // MARK: - Data step: purge unlearnable words (historical, frozen)

    /// Deletes rows that no longer pass the learnability filter.
    ///
    /// The rules here are **frozen at the version that shipped**, on
    /// purpose: this is a historical fix keyed to `filters_version = 1`,
    /// and if it drifted along with the live filter it would silently
    /// delete words that a later, stricter rule dislikes. A new filter
    /// generation gets a new marker version, not an edit to this one.
    private static func purgeUnlearnableWords(_ db: OpaquePointer?) -> Bool {
        func wasLearnable(_ word: String) -> Bool {
            guard word.count <= 64 else { return false }
            // Frozen v1 rule: the tails the released builds used, whatever
            // profile the running keyboard has.
            let tails = NormalizationProfile.dagestanianCyrillicV1.digraphTails
            guard word.reduce(0, { tails.contains($1) ? $0 : $0 + 1 }) >= 2 else { return false }
            guard !word.contains(where: \.isNumber) else { return false }
            guard !word.contains("@"), !word.contains("/"), !word.contains(".") else { return false }
            return true
        }
        let stale = SQL.strings(db, "SELECT word FROM user_word").filter { !wasLearnable($0) }
        for word in stale {
            guard SQL.run(db, "DELETE FROM user_word WHERE word = ?1", word),
                  SQL.run(db, "DELETE FROM user_bigram WHERE word = ?1 OR prev = ?1", word)
            else { return false }
        }
        return true
    }

    // MARK: - Data step: Latin i to palochka (historical, superseded)

    /// Rewrites rows whose palochka is a leftover Latin "i". Kept so a
    /// database that never ran it still gets it; the canonicalization step
    /// below is a strict superset and handles every other lookalike.
    private static func migrateLatinPalochka(_ db: OpaquePointer?) -> Bool {
        func fixed(_ word: String) -> String? {
            guard word.contains("i"),
                  word.unicodeScalars.contains(where: {
                      (0x0430...0x044F).contains($0.value) || $0.value == 0x04CF
                  })
            else { return nil }
            return word.replacingOccurrences(of: "i", with: "ӏ")
        }

        for old in SQL.strings(db, "SELECT word FROM user_word WHERE word LIKE '%i%'") {
            guard let new = fixed(old) else { continue }
            guard mergeWord(db, from: old, to: new) else { return false }
        }
        let pairs = SQL.pairs(db, "SELECT prev, word FROM user_bigram WHERE prev LIKE '%i%' OR word LIKE '%i%'")
        for (oldPrev, oldWord) in pairs {
            let newPrev = fixed(oldPrev) ?? oldPrev
            let newWord = fixed(oldWord) ?? oldWord
            guard newPrev != oldPrev || newWord != oldWord else { continue }
            guard mergePair(db, from: (oldPrev, oldWord), to: (newPrev, newWord)) else { return false }
        }
        return true
    }

    // MARK: - Data step: canonicalize learned data

    /// Brings every stored word and pair into the canonical form.
    ///
    /// Necessary because two of the three learn paths read the **host
    /// application's** text (`wordPrefix`, `previousWord`), which is
    /// arbitrary: pasted, autocorrected, or typed with another keyboard.
    /// Nothing normalized it beyond `lowercased()`, and the learnability
    /// filter never rejected Latin letters, so a Ukrainian і used as a
    /// palochka, a Latin homoglyph inside a Cyrillic word, or decomposed
    /// Unicode could all be stored — and could keep arriving, because
    /// `palochka_fixed` was a one-shot patch on an ongoing source.
    ///
    /// Whitespace is deliberately not handled: `wordPrefix` splits on
    /// whitespace, so a stored token cannot contain any. That category is
    /// impossible by construction rather than merely unobserved.
    ///
    /// Idempotent: a row already canonical is skipped, so re-running after
    /// an interrupted attempt is a no-op.
    private static func canonicalizeLearnedData(_ db: OpaquePointer?) -> Bool {
        for old in SQL.strings(db, "SELECT word FROM user_word") {
            // isCanonical compares scalars: Swift's == would call a
            // decomposed row equal to its precomposed form and skip it,
            // while SQLite keeps them as two distinct rows forever.
            guard !Normalization.isCanonical(old) else { continue }
            let new = Normalization.canonical(old)
            if Normalization.isValidToken(new) {
                guard mergeWord(db, from: old, to: new) else { return false }
            } else {
                // The canonical form is not a word we may store (a lone
                // digraph, or Latin that survived repair). Drop it and the
                // pairs that reference it, matching how `delete` behaves.
                guard SQL.run(db, "DELETE FROM user_word WHERE word = ?1", old),
                      SQL.run(db, "DELETE FROM user_bigram WHERE word = ?1 OR prev = ?1", old)
                else { return false }
            }
        }

        for (oldPrev, oldWord) in SQL.pairs(db, "SELECT prev, word FROM user_bigram") {
            guard !Normalization.isCanonical(oldPrev) || !Normalization.isCanonical(oldWord)
            else { continue }
            let newPrev = Normalization.canonical(oldPrev)
            let newWord = Normalization.canonical(oldWord)
            // If either side stops being a storable token the pair carries
            // no meaning any more and is removed rather than half-migrated.
            guard Normalization.isValidToken(newPrev), Normalization.isValidToken(newWord) else {
                guard SQL.run(db, "DELETE FROM user_bigram WHERE prev = ?1 AND word = ?2",
                              oldPrev, oldWord) else { return false }
                continue
            }
            guard mergePair(db, from: (oldPrev, oldWord), to: (newPrev, newWord)) else { return false }
        }
        return true
    }

    // MARK: - Collision-safe merges

    /// Counters are clamped well below Int64 so that a merge can never
    /// overflow. Decay halves everything every 2000 events, so real values
    /// live in the tens; the clamp is insurance, not arithmetic we expect
    /// to need.
    private static let counterCeiling = 1_000_000_000

    /// Moves `from` onto `to`, summing counters and keeping the newer
    /// timestamp. Insert and delete happen in the caller's transaction, so
    /// the merged row and the removal of its source become durable
    /// together — a crash in between cannot leave the count applied twice,
    /// which is what makes a retry safe.
    private static func mergeWord(_ db: OpaquePointer?, from old: String, to new: String) -> Bool {
        SQL.run(db, """
            INSERT INTO user_word(word, count, picked, last_used)
            SELECT ?2, count, picked, last_used FROM user_word WHERE word = ?1
            ON CONFLICT(word) DO UPDATE SET
                count = MIN(count + excluded.count, \(counterCeiling)),
                picked = MIN(picked + excluded.picked, \(counterCeiling)),
                last_used = MAX(last_used, excluded.last_used)
            """, old, new)
        && SQL.run(db, "DELETE FROM user_word WHERE word = ?1", old)
    }

    private static func mergePair(_ db: OpaquePointer?,
                                  from old: (prev: String, word: String),
                                  to new: (prev: String, word: String)) -> Bool {
        SQL.run(db, """
            INSERT INTO user_bigram(prev, word, count, last_used)
            SELECT ?3, ?4, count, last_used FROM user_bigram WHERE prev = ?1 AND word = ?2
            ON CONFLICT(prev, word) DO UPDATE SET
                count = MIN(count + excluded.count, \(counterCeiling)),
                last_used = MAX(last_used, excluded.last_used)
            """, old.prev, old.word, new.prev, new.word)
        && SQL.run(db, "DELETE FROM user_bigram WHERE prev = ?1 AND word = ?2", old.prev, old.word)
    }
}

// MARK: - Minimal SQL helpers

/// Deliberately separate from `LearnedWords`' own helpers: migrations must
/// keep working even as the store's internals change around them.
enum SQL {

    @discardableResult
    static func exec(_ db: OpaquePointer?, _ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    static func int(_ db: OpaquePointer?, _ sql: String) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    static func strings(_ db: OpaquePointer?, _ sql: String) -> [String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { out.append(String(cString: c)) }
        }
        return out
    }

    static func pairs(_ db: OpaquePointer?, _ sql: String) -> [(String, String)] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [(String, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let a = sqlite3_column_text(stmt, 0), let b = sqlite3_column_text(stmt, 1) {
                out.append((String(cString: a), String(cString: b)))
            }
        }
        return out
    }

    @discardableResult
    static func run(_ db: OpaquePointer?, _ sql: String, _ params: String...) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        for (index, param) in params.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), param, -1, SQLITE_TRANSIENT_MIG)
        }
        let step = sqlite3_step(stmt)
        return step == SQLITE_DONE || step == SQLITE_ROW
    }
}
