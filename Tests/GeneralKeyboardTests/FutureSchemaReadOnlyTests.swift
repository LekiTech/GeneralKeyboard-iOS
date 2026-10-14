//
//  FutureSchemaReadOnlyTests.swift
//
//  A database whose schema_version exceeds this build's target was written
//  by a newer build — after an update-then-rollback, or a container restored
//  onto an older install. "Read-only" for that database must mean the file
//  is byte-identical after use, not merely that learn() declines: the WAL
//  pragma, CREATE IF NOT EXISTS, and marker writes on the normal open path
//  are all mutations too, and all of them must be skipped.
//

import XCTest
import CryptoKit
import SQLite3
@testable import GeneralKeyboard
@testable import GeneralKeyboardBridge
import GeneralKeyboardReference

final class FutureSchemaReadOnlyTests: GKTestCase {

    private var dir: URL!
    private var path: String { dir.appendingPathComponent("learned.sqlite").path }

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("future-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A version-99 database the way a newer build would leave it: released
    /// tables plus tables this build has never heard of, closed cleanly.
    private func makeFutureDatabase(journalMode: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &db,
                                       SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        SQL.exec(db, "PRAGMA journal_mode=\(journalMode)")
        SQL.exec(db, """
            CREATE TABLE meta(key TEXT PRIMARY KEY, value INTEGER NOT NULL);
            CREATE TABLE user_word(word TEXT PRIMARY KEY, count INTEGER NOT NULL DEFAULT 0,
                                   picked INTEGER NOT NULL DEFAULT 0, last_used INTEGER NOT NULL);
            CREATE TABLE user_bigram(prev TEXT NOT NULL, word TEXT NOT NULL,
                                     count INTEGER NOT NULL DEFAULT 0, last_used INTEGER NOT NULL,
                                     PRIMARY KEY(prev, word));
            CREATE TABLE from_the_future(mystery BLOB);
            INSERT INTO meta VALUES('schema_version', 99);
            INSERT INTO meta VALUES('total_events', 12);
            INSERT INTO meta VALUES('filters_version', 7);
            INSERT INTO meta VALUES('palochka_fixed', 7);
            """)
        SQL.run(db, "INSERT INTO user_word VALUES(?1, 5, 2, 1700000000)", "хайи")
        SQL.run(db, "INSERT INTO user_bigram VALUES(?1, ?2, 4, 1700000000)", "зи", "хайи")
        // WAL databases are checkpointed and the -wal removed on a clean
        // close, which is how a production container normally looks.
        sqlite3_close(db)
    }

    private func fileHash() throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func sidecarsPresent() -> [String] {
        ["-wal", "-shm", "-journal"].filter {
            FileManager.default.fileExists(atPath: path + $0)
        }
    }

    /// Opens the store, reads through every public read API, hammers every
    /// mutation API, and closes. Returns the store's outcomes for assertion.
    private func useStoreEveryWay() throws -> (outcome: MigrationOutcome, readOnly: Bool,
                                               suggestions: [String]) {
        let store = try XCTUnwrap(LearnedWords(directory: dir))
        let outcome = store.migrationOutcome
        let readOnly = store.isReadOnly

        // Reads — the user keeps their suggestions.
        let suggestions = store.suggestions(for: "хай", previous: nil)
        _ = store.isRecognized("хайи")
        _ = store.nextWords(after: "зи")
        _ = store.hasContributionConsent
        _ = store.pendingContributionCount
        _ = store.contributionBatch("no-such-batch")

        // Writes — every one of these must be refused.
        store.learn("цӏийи", previous: "зи", picked: false)
        store.learn("цӏийи", previous: nil, picked: true)
        store.delete("хайи")
        store.reset()
        store.bumpMetric(.opportunities)
        store.enqueueContribution(kind: .wordDelta, key: "хайи", typedDelta: 1)
        store.setContributionConsent(true)
        _ = store.claimBatch()
        store.acknowledgeContributionBatch("any")
        store.releaseStaleContributionClaims()
        store.releaseContributionClaim("any")

        return (outcome, readOnly, suggestions)
    }

    // MARK: - Byte-level immutability

    func testAFutureWALDatabaseIsByteIdenticalAfterFullUse() throws {
        try makeFutureDatabase(journalMode: "WAL")
        let before = try fileHash()

        let result = try useStoreEveryWay()

        XCTAssertEqual(result.outcome, .databaseFromFuture(found: 99, supported: Migrations.targetSchemaVersion))
        XCTAssertTrue(result.readOnly)
        XCTAssertEqual(result.suggestions, ["хайи"], "Reads must keep working")
        XCTAssertEqual(try fileHash(), before,
                       "Not one byte may change: no WAL pragma, no CREATE, no markers, "
                       + "no normalization, no consent write")
    }

    func testAFutureDeleteModeDatabaseKeepsItsJournalMode() throws {
        // If the newer build switched journal modes, ours must not switch it
        // back — the header bytes would differ and the hash would catch it,
        // but the journal_mode read makes the failure legible.
        try makeFutureDatabase(journalMode: "DELETE")
        let before = try fileHash()

        _ = try useStoreEveryWay()

        XCTAssertEqual(try fileHash(), before)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(SQL.strings(db, "PRAGMA journal_mode").first, "delete")
    }

    func testAReadOnlyOpenCreatesNoSidecarFiles() throws {
        // Apple's SQLite persists the -wal/-shm across a clean close, so a
        // production container normally has them. A container restored from
        // an iCloud/iTunes backup does not — sidecars are excluded — and
        // opening that restored file must not conjure them back.
        try makeFutureDatabase(journalMode: "WAL")
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
        XCTAssertEqual(sidecarsPresent(), [], "Precondition: the restored-backup shape")

        let result = try useStoreEveryWay()

        XCTAssertEqual(result.suggestions, ["хайи"], "Reads work even without a journal")
        XCTAssertEqual(sidecarsPresent(), [],
                       "A read-only connection must not create journal files")
    }

    func testAnExistingWALIsNotAppendedTo() throws {
        // When the sidecars ARE present (the persist-WAL default), the -wal
        // must gain no frames. The -shm is deliberately not asserted on: it
        // is coordination state readers may touch, and it holds no user data.
        //
        // The comparison happens WHILE the store is still open: a close
        // could checkpoint-and-truncate the WAL, so comparing after close
        // would show empty == empty even if frames had been written.
        try makeFutureDatabase(journalMode: "WAL")
        guard FileManager.default.fileExists(atPath: path + "-wal") else {
            throw XCTSkip("This SQLite build does not persist the WAL across a close")
        }
        let before = try Data(contentsOf: URL(fileURLWithPath: path + "-wal"))

        let store = try XCTUnwrap(LearnedWords(directory: dir))
        XCTAssertTrue(store.isReadOnly)
        store.learn("цӏийи", previous: "зи", picked: false)
        store.delete("хайи")
        store.reset()
        store.bumpMetric(.opportunities)
        store.setContributionConsent(true)
        store.enqueueContribution(kind: .wordDelta, key: "хайи", typedDelta: 1)

        let after = try Data(contentsOf: URL(fileURLWithPath: path + "-wal"))
        XCTAssertEqual(after, before, "No transaction may have written a WAL frame")
        withExtendedLifetime(store) {}
    }

    func testTheFutureTablesAreStillThere() throws {
        try makeFutureDatabase(journalMode: "WAL")
        _ = try useStoreEveryWay()

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(SQL.int(db, "SELECT COUNT(*) FROM sqlite_master WHERE name='from_the_future'"), 1)
        XCTAssertEqual(SQL.int(db, "SELECT value FROM meta WHERE key='schema_version'"), 99)
        XCTAssertEqual(SQL.int(db, "SELECT value FROM meta WHERE key='filters_version'"), 7,
                       "Data-step markers from the future are not ours to touch")
        XCTAssertEqual(SQL.int(db, "SELECT COUNT(*) FROM meta WHERE key='contribution_consent'"), 0,
                       "setContributionConsent must have been refused")
        XCTAssertEqual(SQL.int(db, "SELECT COUNT(*) FROM meta WHERE key='normalization_version'"), 0,
                       "Normalization must not have run")
    }

    func testAJournalFileRoutesThePeekAwayFromImmutable() throws {
        // immutable=1 skips rollback-journal processing, so a database
        // sitting next to a -journal must never be opened immutable — a hot
        // journal would make it read torn, uncommitted pages. With the
        // journal present the peek takes the plain read-only branch, which
        // reads the committed state (or fails safely into the read-write
        // fallback, whose recovery rolls the journal back before the
        // second-chance version check).
        try makeFutureDatabase(journalMode: "DELETE")
        FileManager.default.createFile(atPath: path + "-journal", contents: Data())
        let before = try fileHash()

        let result = try useStoreEveryWay()

        XCTAssertEqual(result.outcome, .databaseFromFuture(found: 99, supported: Migrations.targetSchemaVersion))
        XCTAssertEqual(result.suggestions, ["хайи"], "The committed state, not torn pages")
        XCTAssertEqual(try fileHash(), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "-journal"),
                      "A read-only peek does not clean up journals either")
    }

    // MARK: - The handle itself is read-only

    func testTheConnectionRefusesWritesAtTheSQLiteLevel() throws {
        // Defense in depth: even if every isReadOnly guard were deleted,
        // the handle a future database gets cannot write.
        try makeFutureDatabase(journalMode: "WAL")
        let store = try XCTUnwrap(LearnedWords(directory: dir))
        XCTAssertTrue(store.isReadOnly)
        XCTAssertFalse(SQL.exec(store.db, "INSERT INTO meta VALUES('probe', 1)"),
                       "The underlying connection must be SQLITE_OPEN_READONLY")
    }

    // MARK: - Ordinary databases are unaffected by the peek

    func testACurrentVersionDatabaseStillOpensReadWrite() throws {
        let store = try XCTUnwrap(LearnedWords(directory: dir))
        XCTAssertEqual(store.migrationOutcome, .ready)
        store.learn("кӏвал", previous: nil, picked: false)
        XCTAssertTrue(store.isRecognized("кӏвал"))

        let reopened = try XCTUnwrap(LearnedWords(directory: dir))
        XCTAssertEqual(reopened.migrationOutcome, .ready)
        XCTAssertFalse(reopened.isReadOnly,
                       "The peek must wave a version-2 database straight through")
        reopened.learn("хайи", previous: nil, picked: false)
        XCTAssertTrue(reopened.isRecognized("хайи"))
    }

    func testAFreshDirectoryStillCreatesADatabase() throws {
        // The peek must not misfire on a file that does not exist yet.
        let store = try XCTUnwrap(LearnedWords(directory: dir))
        XCTAssertEqual(store.migrationOutcome, .ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }
}
