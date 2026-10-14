//
//  MigrationTests.swift
//
//  The migration registry against databases shaped like the ones users
//  actually have: schema_version 1, written since release, possibly
//  holding values that predate the canonical contract.
//
//  Every test builds its database with raw SQL first — deliberately
//  bypassing LearnedWords, because the point is to simulate rows that the
//  current write path would no longer produce.
//

import XCTest
import SQLite3
@testable import GeneralKeyboard
@testable import GeneralKeyboardBridge
import GeneralKeyboardReference

final class MigrationTests: GKTestCase {

    private var dir: URL!
    private var path: String!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = dir.appendingPathComponent("learned.sqlite").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Building a pre-migration database

    /// Recreates the released schema exactly, with no migration markers —
    /// i.e. a database as it existed before this phase.
    private func makeLegacyDatabase(schemaVersion: Int = 1,
                                    words: [(String, Int, Int, Int64)] = [],
                                    bigrams: [(String, String, Int, Int64)] = [],
                                    markers: [String: Int] = [:]) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &db,
                                       SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        SQL.exec(db, """
            CREATE TABLE meta(key TEXT PRIMARY KEY, value INTEGER NOT NULL);
            CREATE TABLE user_word(word TEXT PRIMARY KEY, count INTEGER NOT NULL DEFAULT 0,
                                   picked INTEGER NOT NULL DEFAULT 0, last_used INTEGER NOT NULL);
            CREATE TABLE user_bigram(prev TEXT NOT NULL, word TEXT NOT NULL,
                                     count INTEGER NOT NULL DEFAULT 0, last_used INTEGER NOT NULL,
                                     PRIMARY KEY(prev, word));
            """)
        SQL.exec(db, "INSERT INTO meta VALUES('schema_version', \(schemaVersion))")
        SQL.exec(db, "INSERT INTO meta VALUES('total_events', 0)")
        for (key, value) in markers {
            SQL.exec(db, "INSERT INTO meta VALUES('\(key)', \(value))")
        }
        for (word, count, picked, used) in words {
            SQL.run(db, "INSERT INTO user_word VALUES(?1, \(count), \(picked), \(used))", word)
        }
        for (prev, word, count, used) in bigrams {
            SQL.run(db, "INSERT INTO user_bigram VALUES(?1, ?2, \(count), \(used))", prev, word)
        }
    }

    private func open() throws -> LearnedWords {
        try XCTUnwrap(LearnedWords(directory: dir))
    }

    private func rawQuery(_ sql: String) -> [String] {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        return SQL.strings(db, sql)
    }

    private func rawInt(_ sql: String) -> Int {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        return SQL.int(db, sql)
    }

    // MARK: - A released database migrates cleanly

    func testProductionSchemaVersionOneUpgradesWithoutDataLoss() throws {
        let now = Int64(Date().timeIntervalSince1970)
        try makeLegacyDatabase(
            words: [("хайи", 5, 2, now), ("кӏвал", 3, 0, now)],
            bigrams: [("зи", "хайи", 4, now)],
            markers: ["filters_version": 1, "palochka_fixed": 1])

        let store = try open()

        XCTAssertEqual(store.migrationOutcome, .ready)
        XCTAssertFalse(store.isReadOnly)
        XCTAssertTrue(store.isRecognized("хайи"))
        XCTAssertTrue(store.isRecognized("кӏвал"))
        XCTAssertEqual(rawInt("SELECT count FROM user_word WHERE word='хайи'"), 5)
        XCTAssertEqual(rawInt("SELECT picked FROM user_word WHERE word='хайи'"), 2)
        XCTAssertEqual(rawInt("SELECT COUNT(*) FROM user_bigram"), 1)
        XCTAssertEqual(rawInt("SELECT value FROM meta WHERE key='normalization_version'"),
                       Normalization.version, "The new marker is recorded")
    }

    func testMarkersFromTheReleasedBuildAreNotRerun() throws {
        // filters_version and palochka_fixed are already 1 in the field; a
        // migration must not repeat historical work on every launch.
        let now = Int64(Date().timeIntervalSince1970)
        try makeLegacyDatabase(words: [("хайи", 1, 0, now)],
                               markers: ["filters_version": 1, "palochka_fixed": 1])
        _ = try open()
        XCTAssertEqual(rawInt("SELECT value FROM meta WHERE key='filters_version'"), 1)
        XCTAssertEqual(rawInt("SELECT value FROM meta WHERE key='palochka_fixed'"), 1)
    }

    // MARK: - Normalization migration

    func testUkrainianIIsCanonicalized() throws {
        let now = Int64(Date().timeIntervalSince1970)
        try makeLegacyDatabase(words: [("чіукі", 4, 1, now)],
                               markers: ["filters_version": 1, "palochka_fixed": 1])
        _ = try open()
        XCTAssertEqual(rawQuery("SELECT word FROM user_word"), ["чӏукӏ"])
        XCTAssertEqual(rawInt("SELECT count FROM user_word WHERE word='чӏукӏ'"), 4)
    }

    func testLatinHomoglyphsAreCanonicalized() throws {
        let now = Int64(Date().timeIntervalSince1970)
        try makeLegacyDatabase(words: [("кӏapax", 2, 0, now)],
                               markers: ["filters_version": 1, "palochka_fixed": 1])
        _ = try open()
        XCTAssertEqual(rawQuery("SELECT word FROM user_word"), ["кӏарах"])
    }

    func testDecomposedUnicodeIsCanonicalized() throws {
        let now = Int64(Date().timeIntervalSince1970)
        // «йис» stored decomposed, as pasted host text can be.
        try makeLegacyDatabase(words: [("\u{0438}\u{0306}ис", 3, 0, now)],
                               markers: ["filters_version": 1, "palochka_fixed": 1])
        _ = try open()
        let stored = rawQuery("SELECT word FROM user_word")
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(Array(stored[0].unicodeScalars), Array("йис".unicodeScalars))
    }

    // MARK: - Collisions

    func testWordCollisionMergesCountersAndKeepsNewestTimestamp() throws {
        let older = Int64(1_000_000)
        let newer = Int64(2_000_000)
        // Two byte-distinct rows that canonicalize to the same word.
        try makeLegacyDatabase(
            words: [("чӏукӏ", 3, 1, older), ("чіукі", 4, 2, newer)],
            markers: ["filters_version": 1, "palochka_fixed": 1])

        _ = try open()

        XCTAssertEqual(rawQuery("SELECT word FROM user_word"), ["чӏукӏ"], "One row survives")
        XCTAssertEqual(rawInt("SELECT count FROM user_word WHERE word='чӏукӏ'"), 7, "3 + 4")
        XCTAssertEqual(rawInt("SELECT picked FROM user_word WHERE word='чӏукӏ'"), 3, "1 + 2")
        XCTAssertEqual(rawInt("SELECT last_used FROM user_word WHERE word='чӏукӏ'"), Int(newer),
                       "The newer timestamp wins")
    }

    func testMergedCountersRestoreVisibility() throws {
        // Neither row alone reaches a threshold of 5; merged they do. The
        // merge must not lose that — the two rows were always one word.
        let now = Int64(Date().timeIntervalSince1970)
        try makeLegacyDatabase(words: [("чӏукӏ", 3, 0, now), ("чіукі", 3, 0, now)],
                               markers: ["filters_version": 1, "palochka_fixed": 1])
        let store = try open()
        store.minVisibleUses = 5
        XCTAssertTrue(store.isRecognized("чӏукӏ"), "3 + 3 clears a threshold of 5")
    }

    func testBigramCollisionMergesBothSides() throws {
        let older = Int64(1_000_000)
        let newer = Int64(2_000_000)
        try makeLegacyDatabase(
            words: [("зи", 5, 0, newer), ("чӏукӏ", 5, 0, newer)],
            bigrams: [("зи", "чӏукӏ", 2, older), ("зи", "чіукі", 3, newer)],
            markers: ["filters_version": 1, "palochka_fixed": 1])

        _ = try open()

        XCTAssertEqual(rawInt("SELECT COUNT(*) FROM user_bigram"), 1)
        XCTAssertEqual(rawInt("SELECT count FROM user_bigram WHERE prev='зи' AND word='чӏукӏ'"), 5)
        XCTAssertEqual(rawInt("SELECT last_used FROM user_bigram WHERE prev='зи' AND word='чӏукӏ'"),
                       Int(newer))
    }

    func testRowsThatBecomeInvalidAreRemovedWithTheirPairs() throws {
        let now = Int64(Date().timeIntervalSince1970)
        // "цi" canonicalizes to "цӏ" — a lone digraph, one letter,
        // which the contract forbids storing.
        try makeLegacyDatabase(
            words: [("цi", 4, 0, now), ("хайи", 2, 0, now)],
            bigrams: [("цi", "хайи", 3, now)],
            markers: ["filters_version": 1, "palochka_fixed": 1])

        _ = try open()

        XCTAssertEqual(rawQuery("SELECT word FROM user_word"), ["хайи"])
        XCTAssertEqual(rawInt("SELECT COUNT(*) FROM user_bigram"), 0,
                       "A pair referencing a word that can no longer exist goes with it")
    }

    // MARK: - Idempotence and restart safety

    func testMigrationIsIdempotentAcrossRepeatedOpens() throws {
        let now = Int64(Date().timeIntervalSince1970)
        try makeLegacyDatabase(words: [("чіукі", 4, 1, now)],
                               markers: ["filters_version": 1, "palochka_fixed": 1])
        for _ in 0..<3 { _ = try open() }
        XCTAssertEqual(rawQuery("SELECT word FROM user_word"), ["чӏукӏ"])
        XCTAssertEqual(rawInt("SELECT count FROM user_word WHERE word='чӏукӏ'"), 4,
                       "Counters must not be re-merged on every launch")
    }

    func testInterruptedMigrationRetriesCleanly() throws {
        // Simulates a kill after the data was rewritten but before the
        // marker was recorded — the marker moves inside the same
        // transaction, so this state is only reachable by construction.
        let now = Int64(Date().timeIntervalSince1970)
        try makeLegacyDatabase(words: [("чӏукӏ", 4, 1, now)],
                               markers: ["filters_version": 1, "palochka_fixed": 1])
        // No normalization_version marker: the step will run again over
        // already-canonical data.
        _ = try open()
        XCTAssertEqual(rawInt("SELECT count FROM user_word WHERE word='чӏукӏ'"), 4,
                       "Re-running over canonical data changes nothing")
        XCTAssertEqual(rawInt("SELECT value FROM meta WHERE key='normalization_version'"),
                       Normalization.version)
    }

    func testWorkIsPreservedWhenAStepIsRetriedAfterPartialProgress() throws {
        // Two dirty rows; open once (both migrate), then clear the marker
        // and open again — the second run must be a no-op, not a doubling.
        let now = Int64(Date().timeIntervalSince1970)
        try makeLegacyDatabase(words: [("чіукі", 2, 0, now), ("кӏapax", 3, 0, now)],
                               markers: ["filters_version": 1, "palochka_fixed": 1])
        _ = try open()

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        SQL.exec(db, "DELETE FROM meta WHERE key='normalization_version'")
        sqlite3_close(db)

        _ = try open()
        XCTAssertEqual(rawInt("SELECT count FROM user_word WHERE word='чӏукӏ'"), 2)
        XCTAssertEqual(rawInt("SELECT count FROM user_word WHERE word='кӏарах'"), 3)
    }

    func testCollisionMergeSaturatesRatherThanOverflows() throws {
        // Both rows near Int64.max: the sum overflows 64-bit integers, which
        // SQLite handles by falling back to REAL — and the merge's MIN with
        // the ceiling brings the result straight back into range instead of
        // storing a float or trapping.
        let huge = 9_223_372_036_854_775_000
        let now = Int64(Date().timeIntervalSince1970)
        try makeLegacyDatabase(
            words: [("чіукі", huge, huge, now), ("чӏукӏ", huge, huge, now)],
            bigrams: [("чіукі", "чӏукӏ", huge, now), ("чӏукӏ", "чӏукӏ", huge, now)],
            markers: ["filters_version": 1, "palochka_fixed": 1])

        let store = try open()

        XCTAssertEqual(store.migrationOutcome, .ready)
        XCTAssertEqual(rawInt("SELECT count FROM user_word WHERE word='чӏукӏ'"), 1_000_000_000)
        XCTAssertEqual(rawInt("SELECT picked FROM user_word WHERE word='чӏукӏ'"), 1_000_000_000)
        XCTAssertEqual(rawInt("SELECT count FROM user_bigram WHERE prev='чӏукӏ'"), 1_000_000_000)
    }

    // MARK: - A database from the future

    func testDatabaseFromTheFutureIsNeverWritten() throws {
        let now = Int64(Date().timeIntervalSince1970)
        try makeLegacyDatabase(schemaVersion: 99,
                               words: [("хайи", 5, 0, now)],
                               markers: ["filters_version": 1, "palochka_fixed": 1])

        let store = try open()

        XCTAssertEqual(store.migrationOutcome,
                       .databaseFromFuture(found: 99, supported: Migrations.targetSchemaVersion))
        XCTAssertTrue(store.isReadOnly)

        // Reads still work — the user keeps their suggestions.
        XCTAssertTrue(store.isRecognized("хайи"))
        XCTAssertEqual(store.suggestions(for: "хай", previous: nil), ["хайи"])

        // Writes are refused rather than risking data this build cannot model.
        store.learn("цӏийи", previous: nil, picked: false)
        XCTAssertFalse(store.isRecognized("цӏийи"))
        store.delete("хайи")
        XCTAssertTrue(store.isRecognized("хайи"), "delete must be refused too")
        store.reset()
        XCTAssertTrue(store.isRecognized("хайи"), "reset must be refused too")
        XCTAssertEqual(rawInt("SELECT value FROM meta WHERE key='schema_version'"), 99,
                       "The version marker is left exactly as the newer build wrote it")
    }

    // MARK: - The write path stays canonical

    func testNewlyLearnedWordsAreStoredCanonically() throws {
        let store = try open()
        // Host text can carry any of these; the store must canonicalize on
        // the way in, so the migration never has to run again for them.
        store.learn("чіукі", previous: nil, picked: false)
        store.learn("кӏapax", previous: nil, picked: false)
        store.learn("\u{0438}\u{0306}ис", previous: nil, picked: false)

        let stored = rawQuery("SELECT word FROM user_word ORDER BY word")
        XCTAssertEqual(stored, ["йис", "кӏарах", "чӏукӏ"])
        for word in stored {
            XCTAssertEqual(Normalization.canonical(word), word, "\(word) is not canonical")
        }
    }

    func testBigramSidesAreBothCanonicalOnTheWritePath() throws {
        let store = try open()
        store.learn("чіукі", previous: "кӏapax", picked: false)
        store.learn("чіукі", previous: "кӏapax", picked: false)
        XCTAssertEqual(store.nextWords(after: "кӏарах"), ["чӏукӏ"])
        XCTAssertEqual(rawQuery("SELECT prev FROM user_bigram"), ["кӏарах"])
    }

    // MARK: - Schema step 2: the contribution outbox

    func testSchemaStepTwoAddsTheOutboxToAReleasedDatabase() throws {
        let now = Int64(Date().timeIntervalSince1970)
        try makeLegacyDatabase(words: [("хайи", 5, 2, now)],
                               bigrams: [("зи", "хайи", 4, now)],
                               markers: ["filters_version": 1, "palochka_fixed": 1])

        let store = try open()

        XCTAssertEqual(store.migrationOutcome, .ready)
        XCTAssertEqual(rawInt("SELECT value FROM meta WHERE key='schema_version'"), 2)
        XCTAssertEqual(rawInt("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='outbox'"), 1)

        // The user's data is exactly where it was.
        XCTAssertEqual(rawInt("SELECT count FROM user_word WHERE word='хайи'"), 5)
        XCTAssertEqual(rawInt("SELECT picked FROM user_word WHERE word='хайи'"), 2)
        XCTAssertEqual(rawInt("SELECT COUNT(*) FROM user_bigram"), 1)
        XCTAssertTrue(store.isRecognized("хайи"))
    }

    func testTheOutboxStartsEmptyOnAnUpgradedDatabase() throws {
        let now = Int64(Date().timeIntervalSince1970)
        try makeLegacyDatabase(words: [("хайи", 50, 30, now), ("кӏвал", 40, 10, now)],
                               bigrams: [("зи", "хайи", 25, now)],
                               markers: ["filters_version": 1, "palochka_fixed": 1])

        let store = try open()

        XCTAssertEqual(rawInt("SELECT COUNT(*) FROM outbox"), 0,
                       "Years of typing history must not be swept into a queue by an upgrade")
        XCTAssertFalse(store.hasContributionConsent)
    }

    func testTheSchemaStepIsNotRepeatedOnEveryLaunch() throws {
        let now = Int64(Date().timeIntervalSince1970)
        try makeLegacyDatabase(words: [("хайи", 1, 0, now)],
                               markers: ["filters_version": 1, "palochka_fixed": 1])
        let store = try open()
        store.enqueueContribution(kind: .wordDelta, key: "хайи", typedDelta: 3)

        let reopened = try open()

        XCTAssertEqual(reopened.migrationOutcome, .ready)
        XCTAssertEqual(reopened.pendingContributionCount, 1,
                       "A rerun of CREATE TABLE would have been harmless; a rerun that "
                       + "dropped and recreated would not. Neither may happen.")
        XCTAssertEqual(rawInt("SELECT typed_delta FROM outbox"), 3)
        XCTAssertEqual(rawInt("SELECT value FROM meta WHERE key='schema_version'"), 2)
    }

    func testADatabaseAlreadyAtVersionTwoIsLeftAlone() throws {
        let now = Int64(Date().timeIntervalSince1970)
        try makeLegacyDatabase(schemaVersion: 2,
                               words: [("хайи", 5, 0, now)],
                               markers: ["filters_version": 1, "palochka_fixed": 1])

        // Marked as version 2 but without the table — the shape a build that
        // was interrupted mid-step could leave behind. The step is not rerun,
        // so the store must stay usable rather than crash on a missing table.
        let store = try open()
        XCTAssertEqual(store.migrationOutcome, .ready)
        XCTAssertTrue(store.isRecognized("хайи"))
        store.learn("цӏийи", previous: nil, picked: false)
        XCTAssertTrue(store.isRecognized("цӏийи"))
    }
}
