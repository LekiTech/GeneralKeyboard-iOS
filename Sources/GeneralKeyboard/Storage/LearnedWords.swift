//
//  LearnedWords.swift
//  GeneralKeyboard
//
//  Stages 1-3 of docs/LOCAL_SUGGESTIONS_ROADMAP.md: on-device learned word
//  frequency with cleanup limits and bigram context. The store lives in the
//  keyboard extension's own sandbox container — it is not shared with the
//  containing app and nothing ever leaves the device. Only individual words
//  and word pairs are stored, never sentences.
//

import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class LearnedWords {
    /// Internal rather than private so the outbox extension can reach it;
    /// nothing outside this module sees it.
    internal var db: OpaquePointer?

    private static let schemaVersion = 1
    /// Sanity bound so a pathological token cannot bloat a row.
    private static let maxWordLength = 64
    /// A word must be confirmed this many times (typed or picked) before it
    /// starts being suggested, so a typo made once or twice never surfaces.
    /// User-adjustable via the settings panel's learning speed (1/3/5);
    /// only this visibility threshold changes, never the learning itself.
    var minVisibleUses = KeyboardSettings.LearnSpeed.fast.minUses
    /// A pair must be seen this many times before it produces next-word
    /// suggestions, so a one-off combination never surfaces.
    private static let minPairUses = 2
    /// Words used within this window get a recency boost in ranking.
    private static let recencyWindow: TimeInterval = 14 * 24 * 3600
    /// Hard cap on stored words; the lowest-ranked rows are pruned past it,
    /// which also keeps learned.sqlite far under the size target.
    private static let maxWords = 5000
    /// Hard cap on stored word pairs, pruned the same way.
    private static let maxBigrams = 10000
    /// After this many learn events every counter is halved (integer
    /// division), so one-off words vanish and stale habits fade out.
    private static let decayAfterEvents = 2000
    /// How often (in learn events) the row cap is checked.
    private static let pruneCheckEvery = 200
    /// Bumped when the learnability filters tighten; old records that no
    /// longer pass are purged once per bump.
    private static let filtersVersion = 1

    /// Digraph tails (ӏ, ъ, ь for Dagestanian Cyrillic), from the keyboard's
    /// normalization profile. A tail extends the previous letter instead of
    /// counting as its own, so "цӏ" or "къ" is one letter even though it is
    /// two characters.
    private static let digraphTails: Set<Character> = Normalization.digraphTails

    /// Number of letters in a lowercased token, counting digraphs as
    /// single letters.
    private static func letterCount(_ word: String) -> Int {
        word.reduce(0) { digraphTails.contains($1) ? $0 : $0 + 1 }
    }

    /// Opens the learned store. `directory` defaults to the extension's own
    /// Application Support container — the production path, unchanged. Tests
    /// pass a temporary directory to get an isolated database; nothing else
    /// overrides it.
    init?(directory: URL? = nil) {
        guard let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("learned.sqlite").path
        // Peek before opening read-write: on the normal path below, the WAL
        // pragma and the CREATE/INSERT block all write, and a database from
        // a newer build must not be written AT ALL — not even its journal
        // mode. When the peek finds a future version the store keeps the
        // read-only handle, so refusal is enforced by SQLite itself, not
        // just by the isReadOnly guards.
        if let future = Self.openReadOnlyIfFromFuture(path: path) {
            db = future.handle
            migrationOutcome = .databaseFromFuture(found: future.found,
                                                   supported: Migrations.targetSchemaVersion)
            return
        }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        // Second chance for the future check: the peek cannot read a hot
        // WAL whose recovery needs write access, so it falls through to
        // here. Recovery has happened by now (SQLite's own, content-safe);
        // asking again BEFORE the pragma and the schema block keeps every
        // write of OURS away from a database a newer build owns. On this
        // corner path the handle stays read-write, so the isReadOnly
        // guards on every mutation API are the enforcement.
        let found = SQL.int(db, "SELECT value FROM meta WHERE key = 'schema_version'")
        if found > Migrations.targetSchemaVersion {
            migrationOutcome = .databaseFromFuture(found: found,
                                                   supported: Migrations.targetSchemaVersion)
            return
        }
        exec("PRAGMA journal_mode=WAL")
        exec("""
            CREATE TABLE IF NOT EXISTS meta(
                key TEXT PRIMARY KEY,
                value INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS user_word(
                word TEXT PRIMARY KEY,
                count INTEGER NOT NULL DEFAULT 0,
                picked INTEGER NOT NULL DEFAULT 0,
                last_used INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS user_bigram(
                prev TEXT NOT NULL,
                word TEXT NOT NULL,
                count INTEGER NOT NULL DEFAULT 0,
                last_used INTEGER NOT NULL,
                PRIMARY KEY(prev, word)
            );
            INSERT OR IGNORE INTO meta(key, value) VALUES('schema_version', \(Self.schemaVersion));
            INSERT OR IGNORE INTO meta(key, value) VALUES('total_events', 0);
            """)
        // Every schema and content migration goes through the registry —
        // one monotonic sequence, one transaction per step. See
        // Migrations.swift.
        migrationOutcome = Migrations.run(on: db)
    }

    /// Opens `path` read-only just long enough to read `schema_version`.
    /// Returns the still-open handle when the database was written by a
    /// newer build; nil when it is current, absent, or unreadable — the
    /// read-write path then decides, exactly as before.
    ///
    /// The unreadable case matters: a crashed newer build can leave a hot
    /// WAL that a read-only connection cannot recover. The version is then
    /// unknowable without recovery, so the store falls through to the
    /// read-write open, lets SQLite recover the journal (content-safe by
    /// SQLite's own guarantee), and `Migrations.run` still refuses the
    /// future version logically before any schema or data step runs.
    private static func openReadOnlyIfFromFuture(path: String) -> (handle: OpaquePointer?, found: Int)? {
        guard FileManager.default.fileExists(atPath: path),
              let handle = openPeekConnection(path: path) else { return nil }
        let found = SQL.int(handle, "SELECT value FROM meta WHERE key = 'schema_version'")
        guard found > Migrations.targetSchemaVersion else {
            sqlite3_close(handle)
            return nil
        }
        return (handle, found)
    }

    /// One read-only connection, chosen to leave the least possible trace.
    ///
    /// With no -wal file the main file is complete, and immutable=1 reads it
    /// with no locks and no journal side effects at all — a plain read-only
    /// connection to a WAL database would otherwise create the -wal/-shm
    /// pair just to coordinate. Immutable is safe here because this file has
    /// exactly one writer, the extension itself, and every same-build
    /// instance takes this same path. When a -wal IS present its frames are
    /// authoritative and immutable would read around them, so the plain
    /// read-only open is used instead; it may touch the coordination
    /// sidecars, never the database.
    private static func openPeekConnection(path: String) -> OpaquePointer? {
        var handle: OpaquePointer?
        // Immutable only when NEITHER journal exists. immutable=1 skips
        // rollback-journal processing too, so a hot -journal (a future
        // build that switched to DELETE mode and crashed mid-commit) would
        // make it read torn, uncommitted pages. With a -journal present
        // the plain read-only open below either reads the committed state
        // or fails with SQLITE_READONLY_ROLLBACK — and a failed peek falls
        // through to the read-write open, whose recovery rolls the journal
        // back before the second-chance version check.
        if !FileManager.default.fileExists(atPath: path + "-wal"),
           !FileManager.default.fileExists(atPath: path + "-journal"),
           var parts = URLComponents(string: "file://") {
            parts.path = path
            parts.queryItems = [URLQueryItem(name: "immutable", value: "1")]
            if let uri = parts.string,
               sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK {
                return handle
            }
            sqlite3_close(handle)
            handle = nil
        }
        if sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            return handle
        }
        sqlite3_close(handle)
        return nil
    }

    /// Result of the migration run. When the database was written by a
    /// newer build the store keeps serving suggestions but refuses to
    /// write, rather than corrupting data this code does not understand.
    private(set) var migrationOutcome: MigrationOutcome = .ready

    /// True when writes are suppressed because the database is newer than
    /// this build understands.
    var isReadOnly: Bool {
        if case .databaseFromFuture = migrationOutcome { return true }
        return false
    }

    deinit { sqlite3_close(db) }

    /// Words worth learning: no digits, no email/URL fragments, and at least
    /// two letters — a lone digraph like "цӏ" is still one letter.
    /// Separators never reach here (the prefix tokenizer splits on them),
    /// but pasted text can still carry such tokens past a space.
    private func isLearnable(_ word: String) -> Bool {
        guard word.count <= Self.maxWordLength else { return false }
        guard Self.letterCount(word) >= 2 else { return false }
        guard !word.contains(where: \.isNumber) else { return false }
        guard !word.contains("@"), !word.contains("/"), !word.contains(".") else { return false }
        return true
    }

    /// Records a completed word and, when the preceding word of the same
    /// sentence is known, the (previous, word) pair. `picked` marks a word
    /// chosen from the suggestion bar, which is a stronger signal than
    /// plain typing.
    func learn(_ word: String, previous: String?, picked: Bool) {
        // Writes are suppressed for a database from the future.
        guard !isReadOnly else { return }
        // Canonical form on the way in, so the store stays canonical by
        // construction instead of needing the migration re-run forever.
        // Two of the three learn paths read the host app's text, which may
        // carry lookalikes or decomposed Unicode.
        let w = Normalization.canonical(word)
        guard isLearnable(w) else { return }
        let now = Int64(Date().timeIntervalSince1970)
        var stmt: OpaquePointer?
        let sql = """
            INSERT INTO user_word(word, count, picked, last_used) VALUES(?1, ?2, ?3, ?4)
            ON CONFLICT(word) DO UPDATE SET
                count = count + ?2, picked = picked + ?3, last_used = ?4
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, w, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, picked ? 0 : 1)
        sqlite3_bind_int(stmt, 3, picked ? 1 : 0)
        sqlite3_bind_int64(stmt, 4, now)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)

        if let prev = previous.map(Normalization.canonical), isLearnable(prev) {
            var pairStmt: OpaquePointer?
            let pairSQL = """
                INSERT INTO user_bigram(prev, word, count, last_used) VALUES(?1, ?2, 1, ?3)
                ON CONFLICT(prev, word) DO UPDATE SET
                    count = count + 1, last_used = ?3
                """
            if sqlite3_prepare_v2(db, pairSQL, -1, &pairStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(pairStmt, 1, prev, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(pairStmt, 2, w, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(pairStmt, 3, now)
                sqlite3_step(pairStmt)
            }
            sqlite3_finalize(pairStmt)
        }
        maintain()
    }

    /// Most likely follow-ups to `previous` from the bigram table, best
    /// first (Stage 4 next-word suggestions). Recent pairs get the same
    /// boost as recent words.
    func nextWords(after previous: String, limit: Int = 3) -> [String] {
        let prev = Normalization.canonical(previous)
        guard !prev.isEmpty else { return [] }
        var stmt: OpaquePointer?
        let sql = """
            SELECT word FROM user_bigram
            WHERE prev = ?1 AND count >= ?2 AND LENGTH(word) >= 2
            ORDER BY count * (CASE WHEN last_used >= ?3 THEN 2 ELSE 1 END) DESC,
                     last_used DESC
            LIMIT ?4
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, prev, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(Self.minPairUses))
        sqlite3_bind_int64(stmt, 3, Int64(Date().timeIntervalSince1970 - Self.recencyWindow))
        sqlite3_bind_int(stmt, 4, Int32(limit))
        var results: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { results.append(String(cString: c)) }
        }
        return results
    }

    // MARK: - Cleanup (Stage 2)

    /// Counts learn events and runs the periodic cleanup: decay once per
    /// `decayAfterEvents`, a row-cap check once per `pruneCheckEvery`.
    private func maintain() {
        exec("UPDATE meta SET value = value + 1 WHERE key = 'total_events'")
        let events = intValue("SELECT value FROM meta WHERE key = 'total_events'")
        if events >= Self.decayAfterEvents {
            exec("UPDATE user_word SET count = count / 2, picked = picked / 2")
            exec("DELETE FROM user_word WHERE count + picked = 0")
            exec("UPDATE user_bigram SET count = count / 2")
            exec("DELETE FROM user_bigram WHERE count = 0")
            exec("UPDATE meta SET value = 0 WHERE key = 'total_events'")
            prune()
            // No VACUUM here on purpose. It rewrote the whole file on the
            // keystroke that happened to be the 2000th learn event — the
            // only unbounded operation on the interactive path — and bought
            // ~302 KB on a ~6.2 MB database. Measured over 40 000 events,
            // the file plateaus without it and the freelist stays at one
            // page, because decay and prune leave a steady state SQLite
            // already reuses. See docs/VACUUM_PROPOSAL.md and
            // scripts/bench_vacuum.py.
        } else if events % Self.pruneCheckEvery == 0 {
            prune()
        }
    }


    /// Prepares, binds text parameters in order, and steps a one-shot
    /// statement.
    private func run(_ sql: String, _ params: String...) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        for (index, param) in params.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), param, -1, SQLITE_TRANSIENT)
        }
        sqlite3_step(stmt)
    }


    /// Deletes the lowest-ranked rows once the hard caps are exceeded.
    private func prune() {
        let excess = intValue("SELECT COUNT(*) FROM user_word") - Self.maxWords
        if excess > 0 {
            exec("""
                DELETE FROM user_word WHERE word IN (
                    SELECT word FROM user_word
                    ORDER BY count + 3 * picked ASC, last_used ASC
                    LIMIT \(excess)
                )
                """)
        }
        let excessPairs = intValue("SELECT COUNT(*) FROM user_bigram") - Self.maxBigrams
        if excessPairs > 0 {
            exec("""
                DELETE FROM user_bigram WHERE rowid IN (
                    SELECT rowid FROM user_bigram
                    ORDER BY count ASC, last_used ASC
                    LIMIT \(excessPairs)
                )
                """)
        }
    }

    private func intValue(_ sql: String) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Learned words matching the prefix, best first. Picked words weigh more
    /// than merely typed ones, recently used words get a boost, and words
    /// that have followed `previous` before are boosted by the pair counter
    /// (Stage 3 — candidates stay the same, bigrams only affect ranking).
    func suggestions(for prefix: String, previous: String?, limit: Int = 3) -> [String] {
        let p = Normalization.canonical(prefix)
        guard !p.isEmpty else { return [] }
        var stmt: OpaquePointer?
        let sql = """
            SELECT w.word FROM user_word w
            LEFT JOIN user_bigram b ON b.prev = ?5 AND b.word = w.word
            WHERE w.word LIKE ?1 ESCAPE '\\' AND w.count + w.picked >= ?2
                  AND LENGTH(w.word) >= 2
            ORDER BY (w.count + 3 * w.picked)
                     * (CASE WHEN w.last_used >= ?3 THEN 2 ELSE 1 END)
                     * (1 + MIN(IFNULL(b.count, 0), 4)) DESC,
                     w.last_used DESC
            LIMIT ?4
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let pattern = p
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
        sqlite3_bind_text(stmt, 1, pattern, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(minVisibleUses))
        sqlite3_bind_int64(stmt, 3, Int64((Date().timeIntervalSince1970 - Self.recencyWindow)))
        sqlite3_bind_int(stmt, 4, Int32(limit))
        sqlite3_bind_text(stmt, 5, previous.map(Normalization.canonical) ?? "", -1, SQLITE_TRANSIENT)
        var results: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { results.append(String(cString: c)) }
        }
        return results
    }

    /// Whether the word is already learned AND visible — exactly the
    /// recognition rule of `suggestions(for:previous:)`: lowercased match,
    /// `count + picked >= minVisibleUses`, at least 2 characters. Used for
    /// the bar's «unknown word» marker, so a below-threshold word keeps
    /// counting as unknown until it would actually surface as a suggestion.
    func isRecognized(_ word: String) -> Bool {
        let canonical = Normalization.canonical(word)
        var stmt: OpaquePointer?
        let sql = """
            SELECT 1 FROM user_word
            WHERE word = ?1 AND count + picked >= ?2 AND LENGTH(word) >= 2
            LIMIT 1
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, canonical, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(minVisibleUses))
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    // MARK: - Local quality metrics (Stage 6)
    //
    // Plain counters in the meta table: never leave the device, never
    // affect ranking or learning, and survive a learned-data reset — they
    // describe the bar's quality history, not the dictionary. Baseline
    // first, ranking changes later, one at a time.

    enum Metric: String, CaseIterable {
        /// Completed words that had at least one predictive candidate
        /// (beyond the quoted literal) visible while being composed.
        /// Counted once per completed word, not per suggestion refresh.
        case opportunities = "m_opportunities"
        /// Predictive suggestions accepted from the bar.
        case accepted = "m_accepted"
        /// Words completed manually — terminator typed, host send-clear,
        /// or the quoted literal tapped.
        case typedManually = "m_typed_manually"
        /// Manual completions that had predictive candidates available.
        case ignored = "m_ignored"
        /// Accepted suggestions the user went back into before completing
        /// any other word (event-based, no timeout).
        case corrected = "m_corrected"
    }

    func bumpMetric(_ metric: Metric) {
        // The one write that used to skip the isReadOnly guard. On the
        // normal future-schema path the read-only handle would refuse it
        // anyway; on the hot-WAL fallback path (read-write handle, logical
        // refusal only) it would have stamped a metric into a database a
        // newer build owns.
        guard !isReadOnly else { return }
        var stmt: OpaquePointer?
        let sql = """
            INSERT INTO meta(key, value) VALUES(?1, 1)
            ON CONFLICT(key) DO UPDATE SET value = MIN(value + 1, 1000000000)
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, metric.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    /// One line for the DEBUG startup log (Console.app, "kb-metrics").
    func metricsSummary() -> String {
        let value: (Metric) -> Int = { self.intValue(
            "SELECT value FROM meta WHERE key = '\($0.rawValue)'") }
        let accepted = value(.accepted), ignored = value(.ignored)
        let rate = accepted + ignored > 0
            ? String(format: "%.1f%%", 100.0 * Double(accepted) / Double(accepted + ignored))
            : "n/a"
        return "opportunities=\(value(.opportunities)) accepted=\(accepted) "
            + "typedManually=\(value(.typedManually)) ignored=\(ignored) "
            + "corrected=\(value(.corrected)) acceptance=\(rate)"
    }

    /// Learned words for the settings dictionary list, ranked the same way
    /// as suggestions (picked > typed, then recency) and filtered by the
    /// same visibility rule (`count + picked >= minVisibleUses`, ≥ 2
    /// characters): below-threshold rows are internal frequency signals,
    /// not yet user-facing vocabulary. Bundled-dictionary membership is
    /// filtered by the caller, which owns that database handle.
    func topWords(limit: Int) -> [String] {
        var stmt: OpaquePointer?
        let sql = """
            SELECT word FROM user_word
            WHERE count + picked >= ?2 AND LENGTH(word) >= 2
            ORDER BY count + 3 * picked DESC, last_used DESC
            LIMIT ?1
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        sqlite3_bind_int(stmt, 2, Int32(minVisibleUses))
        var results: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { results.append(String(cString: c)) }
        }
        return results
    }

    /// Stage 5: wipes everything learned — words, pairs, and the event
    /// counter. The bundled dictionary is untouched.
    func reset() {
        guard !isReadOnly else { return }
        exec("DELETE FROM user_word")
        exec("DELETE FROM user_bigram")
        exec("UPDATE meta SET value = 0 WHERE key = 'total_events'")
        exec("VACUUM")
    }

    /// Removes a single learned word and every pair that references it
    /// (the bundled dictionary is untouched).
    func delete(_ word: String) {
        guard !isReadOnly else { return }
        let w = Normalization.canonical(word)
        for sql in ["DELETE FROM user_word WHERE word = ?1",
                    "DELETE FROM user_bigram WHERE word = ?1 OR prev = ?1"] {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            sqlite3_bind_text(stmt, 1, w, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }
}
